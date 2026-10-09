import SwiftUI
import AppKit

@main enum InkDeskLauncher {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            do {
                try await runInkDeskTests()
                print("InkDesk: all checks passed")
                exit(0)
            } catch {
                fputs("InkDesk check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if arguments.contains("--store-api-key") {
            do {
                guard let key = readLine(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InkError.message("没有接收到密钥。") }
                try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                print("API credential stored in macOS Keychain.")
                exit(0)
            } catch { fputs("Credential could not be stored: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if arguments.contains("--api-smoke-test") || arguments.contains("--api-smoke-test-stdin") {
            do {
                let supplied = arguments.contains("--api-smoke-test-stdin") ? readLine() : try KeychainStore.read()
                guard let key = supplied, !key.isEmpty else { throw InkError.message("请先保存 API Key。") }
                var config = AIConfiguration(); config.maxTokens = 512
                if arguments.contains("--responses") { config.style = .responses }
                let result = try await AIClient().complete(configuration: config, apiKey: key, system: "你是接口连接测试助手。", prompt: "只回复：InkDesk 连接成功")
                print("Provider verified. Model: \(config.model). Response: \(result)")
                exit(0)
            } catch { fputs("Provider check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        InkDeskApplication.main()
    }
}

struct InkDeskApplication: App {
    @StateObject private var store = AppState()
    @NSApplicationDelegateAdaptor(InkDeskDelegate.self) private var delegate
    var body: some Scene {
        Window("InkDesk", id: "main") {
            InkDeskMainWindowContent(store: store, delegate: delegate)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建页面") { store.addPage(); store.section = .layout }.keyboardShortcut("n")
                Button("导入项目…") { store.importProject() }.keyboardShortcut("o")
                Button("导出项目…") { store.exportProject() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { store.undo() }.keyboardShortcut("z").disabled(!store.undoAvailable)
                Button("重做") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.redoAvailable)
            }
            CommandMenu("桌面") {
                Button("发布到设备") { store.publish() }.keyboardShortcut(.return, modifiers: [.command])
                Button("导出黑白 PNG…") { store.exportPNG() }
                Button("导出设备位图…") { store.exportBitmap() }
                Divider()
                Button("复制组件") { store.duplicateWidget() }.keyboardShortcut("d").disabled(store.selectedWidget == nil || store.section != .layout)
            }
        }
        MenuBarExtra("InkDesk", systemImage: "display") {
            InkDeskMenuBarView(delegate: delegate).environmentObject(store)
                .onAppear { delegate.attach(store: store) }
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct InkDeskMainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    let store: AppState
    let delegate: InkDeskDelegate

    var body: some View {
        InkDeskRootView().environmentObject(store)
            .frame(minWidth: 1120, minHeight: 720)
            .background(InkDeskMainWindowAccessor { [weak delegate] window in
                delegate?.observeMainWindow(window)
            })
            .onAppear {
                delegate.attach(store: store, openWindow: { openWindow(id: "main") })
            }
    }
}

/// The view belongs only to the main Window scene. Keep SwiftUI's window delegate
/// intact and observe this exact NSWindow instead of guessing from keyWindow.
private struct InkDeskMainWindowAccessor: NSViewRepresentable {
    let foundWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> InkDeskWindowHookView {
        let view = InkDeskWindowHookView()
        view.foundWindow = foundWindow
        return view
    }

    func updateNSView(_ view: InkDeskWindowHookView, context: Context) {
        view.foundWindow = foundWindow
        if let window = view.window { foundWindow(window) }
    }
}

private final class InkDeskWindowHookView: NSView {
    var foundWindow: (@MainActor (NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { foundWindow?(window) }
    }
}

@MainActor final class InkDeskDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppState?
    private weak var mainWindow: NSWindow?
    private var mainWindowOpener: (() -> Void)?
    private var windowObservers: [NSObjectProtocol] = []
    private var mainWindowClosed = false
    private var isMainWindowStowed = false
    private var isStowing = false
    private var isRestoring = false
    private var isTerminating = false

    func attach(store: AppState, openWindow: (() -> Void)? = nil) {
        self.store = store
        if let openWindow { mainWindowOpener = openWindow }
    }

    func observeMainWindow(_ window: NSWindow) {
        guard !isTerminating, mainWindow !== window else { return }
        removeWindowObservers()
        mainWindow = window; mainWindowClosed = false
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            let observer = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] notification in
                MainActor.assumeIsolated {
                    guard let self, let window, self.mainWindow === window, !self.isTerminating else { return }
                    if notification.name == NSWindow.willCloseNotification {
                        self.mainWindowClosed = true
                        self.stowMainWindow(window, closing: true)
                    } else if notification.name == NSWindow.didMiniaturizeNotification {
                        self.stowMainWindow(window, closing: false)
                    } else if self.isMainWindowStowed {
                        // Native deminiaturize completion can arrive after the stow
                        // call returns. It must not bring the hidden window back.
                        if !self.isStowing {
                            window.orderOut(nil)
                            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
                        }
                    } else if !self.isStowing, !self.isRestoring {
                        self.mainWindowClosed = false
                        if notification.name == NSWindow.didDeminiaturizeNotification {
                            self.showMainWindow(openWindow: {})
                        } else if NSApp.activationPolicy() != .regular {
                            NSApp.setActivationPolicy(.regular)
                        }
                    }
                }
            }
            windowObservers.append(observer)
        }
    }

    private func stowMainWindow(_ window: NSWindow, closing: Bool) {
        guard !isStowing, !isTerminating, mainWindow === window else { return }
        isStowing = true; isMainWindowStowed = true
        defer { isStowing = false }
        // Undo the native minimize state while ignoring its key-window callbacks:
        // a minimized Dock thumbnail must not survive the menu bar transition.
        if !closing, window.isMiniaturized { window.deminiaturize(nil) }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow(openWindow: () -> Void) {
        guard !isTerminating else { return }
        isRestoring = true; isMainWindowStowed = false
        defer { isRestoring = false }
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow, !mainWindowClosed {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // Let SwiftUI reopen a closed Window scene or create its replacement.
            openWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTerminating else { return false }
        guard let opener = mainWindowOpener else { return true }
        showMainWindow(openWindow: opener)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        removeWindowObservers()
        store?.save(); store?.stopServer(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
