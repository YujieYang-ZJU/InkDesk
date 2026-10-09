import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Network

@MainActor final class AppState: ObservableObject {
    @Published var project: InkProject
    @Published var section: AppSection = .layout
    @Published var selectedWidgetID: UUID?
    @Published var status = "就绪"
    @Published var errorMessage: String?
    @Published var isGenerating = false
    @Published var aiDraft = ""
    @Published var availableModels: [String] = []
    @Published var aiConnectionStatus = "尚未测试"
    @Published var frame: FramePayload?
    @Published var deviceLastSeen: Date?
    @Published private(set) var pendingFrame: FramePayload?
    @Published private(set) var inFlightFrame: FramePayload?
    @Published private(set) var displayedFrame: FramePayload?
    @Published private(set) var syncPhase = "未同步"
    @Published private(set) var syncStatus = "尚未排队；设备显示内容未确认。"
    @Published private(set) var lastDisplayConfirmedAt: Date?
    @Published private(set) var syncLastContact: Date?
    @Published private(set) var isSyncEditPending = false
    @Published var generatingWidgetID: UUID?
    @Published var undoAvailable = false
    @Published var redoAvailable = false
    @Published var apiKey = ""
    var editorCanvasRect: CGRect = .zero
    @Published var paletteDragKind: WidgetKind?
    let server = DeviceServer()
    let storageURL: URL
    let syncStorageURL: URL
    private var syncQueue: FrameSyncQueue
    private var subscriptions = Set<AnyCancellable>()
    private var undoStack: [InkProject] = []
    private var redoStack: [InkProject] = []
    private var generationTask: Task<String, Error>?
    private var revision = 0
    private var focusedTaskID: UUID?
    private var devicePageID: UUID?
    private var clockTimer: Timer?
    private var lastClockBucket: Int?
    private var projectRecoveryBackup: URL?
    private var loading = true
    private var editSyncTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var lastRenderSignature: Data?
    private var applyingDeviceAction = false
    private var syncPersistenceError: String?

    static func clockRefreshBucket(at date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 300))
    }

    init(dataDirectory: URL? = nil, loadKey: Bool = true) {
        let directory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkDesk", isDirectory: true)
        storageURL = directory.appendingPathComponent("project.json")
        syncStorageURL = directory.appendingPathComponent("sync-state.json")
        var loaded = InkProject.sample()
        var loadError: String?
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                loaded = try JSONDecoder().decode(InkProject.self, from: data)
                try loaded.validate()
            } catch {
                let backup = directory.appendingPathComponent("project-unreadable-\(UUID().uuidString).json")
                projectRecoveryBackup = backup
                loadError = "无法读取已保存项目：\(error.localizedDescription)。重新保存前会将原文件备份为 \(backup.lastPathComponent)。"
            }
        }
        project = loaded
        syncQueue = FrameSyncQueue(pairingToken: loaded.device.token)
        if FileManager.default.fileExists(atPath: syncStorageURL.path), loadError == nil {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: syncStorageURL.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 20 * 1024 * 1024 else {
                    throw InkError.message("同步状态文件超过允许大小。")
                }
                syncQueue = try FrameSyncQueue(data: Data(contentsOf: syncStorageURL), pairingToken: loaded.device.token)
            } catch { loadError = "同步状态无法恢复：\(error.localizedDescription)" }
        }
        frame = syncQueue.latestContent?.frame
        devicePageID = syncQueue.latestContent?.frame.pageID
        focusedTaskID = syncQueue.latestContent?.metadata.focusedTaskID
        revision = syncQueue.maximumRevision
        let recoveredMaximum = syncQueue.maximumRevision
        let recoverAcceptedAction = loaded.deviceEventLedger?.last(where: { event in
            event.revision > recoveredMaximum && event.targetPageID.map { target in loaded.pages.contains(where: { $0.id == target }) } == true
        })
        if let event = recoverAcceptedAction, let pageID = event.targetPageID,
           loaded.pages.contains(where: { $0.id == pageID }) {
            devicePageID = pageID; focusedTaskID = event.focusedTaskID
            revision = max(revision, event.revision - 1)
        }
        errorMessage = loadError
        selectedWidgetID = loaded.pages.first(where: { $0.id == loaded.selectedPageID })?.widgets.first?.id
        if loadKey {
            Task { [weak self] in
                do {
                    let key = try await Task.detached(priority: .userInitiated) { try KeychainStore.read() }.value
                    if self?.apiKey.isEmpty == true { self?.apiKey = key ?? "" }
                } catch { self?.errorMessage = "读取 API 密钥失败：\(error.localizedDescription)" }
            }
        }
        server.handler = { [weak self] request in self?.handleRequest(request) ?? .json(["error": "应用不可用"], status: 503) }
        server.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.updateSyncPresentation() }
        }.store(in: &subscriptions)
        $project.dropFirst().sink { [weak self] incoming in
            guard let self else { return }
            self.projectWillChange(to: incoming)
        }.store(in: &subscriptions)
        loading = false
        lastRenderSignature = renderSignature(for: project)
        lastClockBucket = Self.clockRefreshBucket(at: Date())
        updateSyncPresentation()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recoverExpiredTransfer(at: Date())
                let bucket = Self.clockRefreshBucket(at: Date())
                if bucket != self.lastClockBucket {
                    self.lastClockBucket = bucket
                    if self.project.device.autoSync, !self.isSyncEditPending, let page = self.publishedPage, page.widgets.contains(where: { $0.kind == .clock }) {
                        self.refreshFrame(selectEditorPage: false)
                    }
                }
            }
        }
        // Keep clock/lease checks running while a native menu is tracking input.
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
        if project.device.startOnLaunch { startServer() }
        if loadError == nil { save() }
        // Reconcile the two durable files after a crash between an accepted event
        // save and its queue commit. Staging cannot alter a restored active transfer.
        if loadError == nil, recoverAcceptedAction != nil, devicePageID != nil { scheduleEditSync() }
    }

    var currentPage: InkPage { project.pages.first(where: { $0.id == project.selectedPageID }) ?? project.pages[0] }
    var selectedWidget: InkWidget? { currentPage.widgets.first { $0.id == selectedWidgetID } }
    private var publishedPage: InkPage? { project.pages.first { $0.id == devicePageID } }
    var localAddresses: [String] {
        var addresses = [String]()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&pointer) == 0, let first = pointer {
            defer { freeifaddrs(pointer) }
            var next: UnsafeMutablePointer<ifaddrs>? = first
            while let interface = next {
                defer { next = interface.pointee.ifa_next }
                guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                      String(cString: interface.pointee.ifa_name) != "lo0" else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: host))
                }
            }
        }
        return addresses.isEmpty ? ["127.0.0.1"] : addresses
    }

    func binding<T>(for keyPath: WritableKeyPath<InkWidget, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.selectedWidget?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let id = self.selectedWidgetID else { return }
            self.updateWidget(id) { $0[keyPath: keyPath] = value }
        })
    }

    func checkpoint() {
        if undoStack.last != project { undoStack.append(project) }
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll(); updateUndoState()
    }
    func undo() {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        guard let last = undoStack.popLast() else { return }
        let ledger = project.deviceEventLedger
        let deviceToken = project.device.token
        redoStack.append(project); project = last; project.deviceEventLedger = ledger; project.device.token = deviceToken; repairSelection(); updateUndoState()
    }
    func redo() {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        guard let next = redoStack.popLast() else { return }
        let ledger = project.deviceEventLedger
        let deviceToken = project.device.token
        undoStack.append(project); project = next; project.deviceEventLedger = ledger; project.device.token = deviceToken; repairSelection(); updateUndoState()
    }
    private func updateUndoState() { undoAvailable = !undoStack.isEmpty; redoAvailable = !redoStack.isEmpty }
    private func repairSelection() {
        if !currentPage.widgets.contains(where: { $0.id == selectedWidgetID }) { selectedWidgetID = currentPage.widgets.first?.id }
    }
    func updateWidget(_ id: UUID, _ mutate: (inout InkWidget) -> Void) {
        guard let page = project.pages.firstIndex(where: { $0.id == project.selectedPageID }),
              let index = project.pages[page].widgets.firstIndex(where: { $0.id == id }) else { return }
        mutate(&project.pages[page].widgets[index]); project.pages[page].widgets[index].clamp()
    }
    func addWidget(_ kind: WidgetKind, at point: CGPoint? = nil) {
        guard currentPage.widgets.count < 100 else { errorMessage = "每页最多 100 个组件。"; return }
        checkpoint()
        var widget = InkWidget(kind: kind, title: kind.title)
        if let point { widget.x = point.x; widget.y = point.y }
        else { widget.x = Double(24 + (currentPage.widgets.count % 5) * 24); widget.y = widget.x }
        if kind == .clock { widget.height = 140; widget.border = false }
        if kind == .qr { widget.width = 200; widget.height = 230; widget.title = "扫码查看" }
        if kind == .image { widget.width = 300; widget.height = 240 }
        widget.clamp()
        if let index = project.pages.firstIndex(where: { $0.id == project.selectedPageID }) { project.pages[index].widgets.append(widget) }
        selectedWidgetID = widget.id
    }
    func selectPage(_ id: UUID) {
        guard project.pages.contains(where: { $0.id == id }) else { return }
        project.selectedPageID = id; selectedWidgetID = currentPage.widgets.first?.id
    }
    func addPage() {
        guard project.pages.count < 24 else { errorMessage = "最多支持 24 个页面。"; return }
        checkpoint(); let page = InkPage(name: "新页面 \(project.pages.count + 1)")
        project.pages.append(page); selectPage(page.id)
    }
    func deletePage(_ id: UUID) {
        guard project.pages.count > 1 else { errorMessage = "请保留至少一个页面。"; return }
        checkpoint(); project.pages.removeAll { $0.id == id }
        if project.selectedPageID == id { selectPage(project.pages[0].id) }
        if devicePageID == id { devicePageID = project.selectedPageID; focusedTaskID = nil; refreshFrame(selectEditorPage: false) }
    }
    func duplicatePage() {
        guard project.pages.count < 24 else { errorMessage = "最多支持 24 个页面。"; return }
        checkpoint(); var page = currentPage; page.id = UUID(); page.name += " 副本"
        for i in page.widgets.indices { page.widgets[i].id = UUID() }
        project.pages.append(page); selectPage(page.id)
    }
    func duplicateWidget() {
        guard var widget = selectedWidget, currentPage.widgets.count < 100 else { return }
        checkpoint(); widget.id = UUID(); widget.x += 16; widget.y += 16; widget.clamp()
        if let index = project.pages.firstIndex(where: { $0.id == project.selectedPageID }) { project.pages[index].widgets.append(widget) }
        selectedWidgetID = widget.id
    }
    func deleteSelectedWidget() {
        guard let id = selectedWidgetID, let index = project.pages.firstIndex(where: { $0.id == project.selectedPageID }) else { return }
        checkpoint(); project.pages[index].widgets.removeAll { $0.id == id }; selectedWidgetID = nil
    }
    func moveLayer(up: Bool) {
        guard let pi = project.pages.firstIndex(where: { $0.id == project.selectedPageID }),
              let wi = project.pages[pi].widgets.firstIndex(where: { $0.id == selectedWidgetID }) else { return }
        let destination = up ? wi + 1 : wi - 1
        guard project.pages[pi].widgets.indices.contains(destination) else { return }
        checkpoint(); project.pages[pi].widgets.swapAt(wi, destination)
    }
    func alignSelected(_ edge: String) {
        guard let id = selectedWidgetID else { return }
        checkpoint(); updateWidget(id) { widget in
            switch edge {
            case "left": widget.x = 0
            case "right": widget.x = 800 - widget.width
            case "top": widget.y = 0
            case "bottom": widget.y = 480 - widget.height
            case "centerX": widget.x = (800 - widget.width) / 2
            case "centerY": widget.y = (480 - widget.height) / 2
            default: break
            }
        }
    }

    func save() {
        guard !loading else { return }
        do { try persistProject() } catch { errorMessage = "保存失败：\(error.localizedDescription)" }
    }
    private func persistProject() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let backup = projectRecoveryBackup {
            try FileManager.default.copyItem(at: storageURL, to: backup)
            projectRecoveryBackup = nil
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: storageURL, options: .atomic)
    }

    private struct RenderTodo: Encodable {
        var id: UUID
        var title: String
        var project: String
        var completed: Bool
    }
    private struct RenderSignature: Encodable {
        var page: InkPage?
        var pages: [SyncPageSummary]
        var todos: [RenderTodo]
        var threshold: Double
        var dither: Bool
        var pollSeconds: Int
    }
    /// Only fields used by rasterization or the device menu belong here. Ledger writes,
    /// editor selection, AI configuration, and task timestamps must not refresh the screen.
    private func renderSignature(for value: InkProject) -> Data? {
        var page = value.pages.first { $0.id == devicePageID }
        if page != nil {
            for i in page!.widgets.indices {
                page!.widgets[i].prompt = ""
                page!.widgets[i].aiUpdatedAt = nil
            }
        }
        let usesTodos = page?.widgets.contains { $0.kind == .todo || $0.kind == .progress } ?? false
        let signature = RenderSignature(page: page, pages: value.pages.map { SyncPageSummary(id: $0.id, name: $0.name) },
            todos: usesTodos ? value.todos.map { RenderTodo(id: $0.id, title: $0.title, project: $0.project, completed: $0.completed) } : [],
            threshold: value.device.threshold, dither: value.device.dither, pollSeconds: value.device.pollSeconds)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(signature)
    }

    private func projectWillChange(to incoming: InkProject) {
        guard !loading, !applyingDeviceAction else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.save()
        }
        if !syncQueue.isPaired(with: incoming.device.token) {
            resetQueueForPairing(incoming.device.token)
        }
        let signature = renderSignature(for: incoming)
        let changed = signature != lastRenderSignature
        lastRenderSignature = signature
        if !incoming.device.autoSync {
            cancelEditCoalescing()
        } else if changed, devicePageID != nil {
            scheduleEditSync()
        }
    }

    private func scheduleEditSync() {
        editSyncTask?.cancel(); isSyncEditPending = true
        updateSyncPresentation()
        editSyncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.editSyncTask = nil; self.isSyncEditPending = false
            self.refreshFrame(selectEditorPage: false)
        }
    }

    private func cancelEditCoalescing() {
        editSyncTask?.cancel(); editSyncTask = nil; isSyncEditPending = false
        updateSyncPresentation()
    }

    private func resetQueueForPairing(_ token: String) {
        cancelEditCoalescing()
        syncQueue = FrameSyncQueue(pairingToken: token)
        frame = nil; devicePageID = nil; focusedTaskID = nil; revision = 0
        syncLastContact = nil; syncPersistenceError = nil
        updateSyncPresentation()
    }

    private func ensureQueuePairing() {
        if !syncQueue.isPaired(with: project.device.token) { resetQueueForPairing(project.device.token) }
    }

    /// Save before advertising a transition. A failed disk write never acknowledges a
    /// claim or display confirmation that would disappear on the next launch.
    private func commitQueue(_ next: FrameSyncQueue, at now: Date = Date()) throws {
        let data = try next.encoded(now: now)
        try FileManager.default.createDirectory(at: syncStorageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: syncStorageURL, options: .atomic)
        syncQueue = next; syncPersistenceError = nil
        updateSyncPresentation()
    }

    private func recoverExpiredTransfer(at now: Date) {
        guard let transfer = syncQueue.inFlight, now >= transfer.leaseExpiresAt else { return }
        var next = syncQueue
        guard next.expireLease(now: now) else { return }
        do { try commitQueue(next, at: now) }
        catch { recordSyncPersistenceFailure(error) }
    }

    private func recordSyncPersistenceFailure(_ error: Error) {
        syncPersistenceError = "同步状态保存失败：\(error.localizedDescription)"
        errorMessage = syncPersistenceError
        updateSyncPresentation()
    }

    private func updateSyncPresentation() {
        let pending = syncQueue.pending?.frame
        let active = syncQueue.inFlight?.content.frame
        let displayed = syncQueue.confirmed?.content.frame
        if !Self.sameFrameIdentity(pendingFrame, pending) { pendingFrame = pending }
        if !Self.sameFrameIdentity(inFlightFrame, active) { inFlightFrame = active }
        if !Self.sameFrameIdentity(displayedFrame, displayed) { displayedFrame = displayed }
        if lastDisplayConfirmedAt != syncQueue.lastDisplayConfirmedAt { lastDisplayConfirmedAt = syncQueue.lastDisplayConfirmedAt }
        let stopped = !server.isRunning ? "同步服务已停止；" : ""
        let phase: String
        let message: String
        if let syncPersistenceError {
            phase = "同步失败"; message = stopped + syncPersistenceError
        } else if let transfer = syncQueue.inFlight {
            phase = transfer.state == .refreshing ? "设备刷新中" : "传输中"
            let stage = transfer.state == .refreshing ? "设备报告正在刷新" : transfer.state == .downloaded ? "设备已下载画面" : "设备已领取画面"
            message = stopped + stage + "，等待显示完成回执（租约 180 秒）。" + (isSyncEditPending ? "新编辑将在停止修改 2 秒后排队。" : "")
        } else if isSyncEditPending {
            phase = "等待编辑完成"; message = stopped + "停止修改 2 秒后保留最新画面；尚未确认新画面显示。"
        } else if syncQueue.retryReason == .failed {
            phase = "同步失败"; message = stopped + (syncQueue.failureMessage ?? "设备报告刷新失败；最新画面已保留，等待重试。")
        } else if syncQueue.retryReason == .expired {
            phase = "等待重试"; message = stopped + "180 秒内未收到显示确认；最新画面已保留，等待重新领取。"
        } else if syncQueue.pending != nil {
            phase = "等待设备"; message = stopped + "最新画面已排队，等待设备领取；尚未确认显示。"
        } else if syncQueue.confirmed != nil {
            phase = "已确认显示"; message = stopped + "已收到设备完成刷新回执；预览为最近一次确认画面。"
        } else {
            phase = "未同步"; message = stopped + "尚未排队；设备显示内容未确认。"
        }
        if syncPhase != phase { syncPhase = phase }
        if syncStatus != message { syncStatus = message }
    }

    private static func sameFrameIdentity(_ lhs: FramePayload?, _ rhs: FramePayload?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.pageID == rhs.pageID && lhs.revision == rhs.revision && lhs.hash == rhs.hash &&
                lhs.generatedAt == rhs.generatedAt && lhs.taskIDs == rhs.taskIDs
        default: return false
        }
    }
    func exportProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "我的桌面.inkdesk"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var exported = project
                exported.device.token = ""
                exported.device.startOnLaunch = false
                exported.deviceEventLedger = []
                try encoder.encode(exported).write(to: url, options: .atomic)
                status = "项目已导出（不包含 API 密钥和设备配对密钥）"
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func importProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 30_000_000 else { throw InkError.message("项目文件超过 30 MB。") }
                var imported = try JSONDecoder().decode(InkProject.self, from: data); try imported.validate()
                imported.device.token = project.device.token
                imported.device.startOnLaunch = project.device.startOnLaunch
                imported.deviceEventLedger = project.deviceEventLedger
                checkpoint(); project = imported; repairSelection(); save()
                status = "已导入项目"
            } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
        }
    }
    func exportPNG() { exportFrame(bitmap: false) }
    func exportBitmap() { exportFrame(bitmap: true) }
    private func exportFrame(bitmap: Bool) {
        do {
            let output = try FrameRenderer.render(page: currentPage, todos: project.todos, configuration: project.device, revision: revision)
            let panel = NSSavePanel(); panel.nameFieldStringValue = currentPage.name + (bitmap ? ".bin" : ".png")
            if !bitmap { panel.allowedContentTypes = [.png] }
            if panel.runModal() == .OK, let url = panel.url {
                try (bitmap ? output.bitmapData : output.pngData).write(to: url, options: .atomic)
                status = "已导出 \(bitmap ? "48,000 字节黑白帧" : "800×480 黑白 PNG")"
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func importImage(for id: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 10_000_000, let image = NSImage(data: data) else { throw InkError.message("请选择 10 MB 以内的图片。") }
                let size = image.size
                guard size.width > 0, size.height > 0 else { throw InkError.message("图片尺寸无效。") }
                let scale = min(1, 1200 / max(size.width, size.height))
                let resized = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))
                resized.lockFocus(); image.draw(in: CGRect(origin: .zero, size: resized.size)); resized.unlockFocus()
                guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { throw InkError.message("无法转换图片。") }
                checkpoint(); updateWidget(id) { $0.imageData = png }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func openDataFolder() { NSWorkspace.shared.open(storageURL.deletingLastPathComponent()) }

    func addTodo(title: String, project group: String = "工作", priority: Int = 1, dueDate: Date? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, project.todos.count < 5000 else { return }
        checkpoint(); project.todos.append(TodoItem(title: String(title.prefix(500)), project: group, priority: priority, dueDate: dueDate))
    }
    func updateTodo(_ id: UUID, _ mutate: (inout TodoItem) -> Void) {
        guard let index = project.todos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&project.todos[index])
    }
    func toggleTodo(_ id: UUID) {
        guard let index = project.todos.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(); project.todos[index].completed.toggle()
        project.todos[index].completedAt = project.todos[index].completed ? Date() : nil
    }
    func deleteTodo(_ id: UUID) { checkpoint(); project.todos.removeAll { $0.id == id } }
    func clearCompletedTodos() { checkpoint(); project.todos.removeAll( where: \.completed) }

    func saveAPIKey() {
        do {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw InkError.message("请先输入 API Key。") }
            try KeychainStore.save(value); apiKey = value; status = "API 密钥已保存到本机钥匙串"
        } catch { errorMessage = error.localizedDescription }
    }
    func resetAPIKey() {
        do { try KeychainStore.delete(); apiKey = ""; aiConnectionStatus = "密钥已移除" }
        catch { errorMessage = error.localizedDescription }
    }
    func testAIConnection() async {
        guard !isGenerating else { return }
        isGenerating = true; aiConnectionStatus = "正在测试…"
        defer { isGenerating = false; generationTask = nil }
        do {
            let configuration = project.ai; let key = apiKey
            let task = Task { try await AIClient().complete(configuration: configuration, apiKey: key, system: "你是连接测试助手。", prompt: "仅回复：连接成功") }
            generationTask = task
            let response = try await task.value
            aiConnectionStatus = "连接成功：\(String(response.prefix(80)))"
            do { availableModels = try await AIClient().listModels(configuration: configuration, apiKey: key) }
            catch { status = "生成连接已验证，服务商未提供可用模型列表" }
        } catch {
            aiConnectionStatus = error is CancellationError ? "已取消" : "测试失败"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }
    private func aiContext() -> String {
        let tasks = project.todos.prefix(100).map { "\($0.completed ? "已完成" : "待办")｜\($0.project)｜优先级\($0.priority)｜\($0.title)" }.joined(separator: "\n")
        let notes = currentPage.widgets.filter { $0.kind == .note }.map { $0.title + "：" + $0.text }.joined(separator: "\n")
        return "当前任务：\n\(tasks)\n当前页面笔记：\n\(notes)"
    }
    func generateAI(for id: UUID) async {
        guard !isGenerating, let widget = currentPage.widgets.first(where: { $0.id == id }), widget.kind == .ai else { return }
        let pageID = currentPage.id
        isGenerating = true; generatingWidgetID = id; status = "AI 正在生成…"
        defer { isGenerating = false; generatingWidgetID = nil; generationTask = nil }
        do {
            let configuration = project.ai; let key = apiKey; let prompt = widget.prompt + "\n\n" + aiContext()
            let task = Task { try await AIClient().complete(configuration: configuration, apiKey: key, system: "你是桌面工作助手。使用简体中文，忠实依据用户提供的任务与笔记，直接给出简洁内容，不使用 Markdown 标题。", prompt: prompt) }
            generationTask = task; let result = try await task.value
            guard let pi = project.pages.firstIndex(where: { $0.id == pageID }), let wi = project.pages[pi].widgets.firstIndex(where: { $0.id == id }) else { status = "原组件已删除，生成结果未写入"; return }
            checkpoint(); project.pages[pi].widgets[wi].aiResult = result; project.pages[pi].widgets[wi].aiUpdatedAt = Date()
            status = "AI 卡片已更新"
        } catch {
            status = error is CancellationError ? "已取消生成" : "AI 生成失败"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }
    func generateTaskBreakdown(_ goal: String) async {
        guard !isGenerating, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isGenerating = true; status = "正在拆解任务…"
        defer { isGenerating = false; generationTask = nil }
        do {
            let configuration = project.ai; let key = apiKey
            let task = Task { try await AIClient().complete(configuration: configuration, apiKey: key,
                system: "把目标拆解为 3 到 8 条具体、可执行的待办。每行一项，只输出任务文字，不加编号、解释或 Markdown。",
                prompt: goal) }
            generationTask = task; aiDraft = try await task.value; status = "拆解完成，请检查后加入 Todo"
        } catch {
            status = error is CancellationError ? "已取消生成" : "任务拆解失败"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }
    func importAIDraftAsTodos() {
        let lines = aiDraft.split(separator: "\n").map { line -> String in
            String(line).replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.)、])\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        checkpoint()
        for title in lines.prefix(min(50, 5000 - project.todos.count)) { project.todos.append(TodoItem(title: String(title.prefix(500)), project: "AI 拆解")) }
        aiDraft = ""; status = "已把生成结果加入 Todo"; section = .todos
    }
    func cancelAI() { generationTask?.cancel() }

    func publish() {
        cancelEditCoalescing()
        refreshFrame(selectEditorPage: true, force: true)
        if !server.isRunning { startServer() }
    }

    func cancelPendingSync() {
        cancelEditCoalescing()
        var next = syncQueue; next.cancelPending()
        do {
            try commitQueue(next)
            let fallback = syncQueue.inFlight?.content ?? syncQueue.confirmed?.content
            frame = fallback?.frame; devicePageID = fallback?.frame.pageID; focusedTaskID = fallback?.metadata.focusedTaskID
            lastRenderSignature = renderSignature(for: project)
            status = "已取消待同步画面；正在传输的画面会继续完成"
        } catch { recordSyncPersistenceFailure(error) }
    }

    func retrySync() {
        cancelEditCoalescing()
        ensureQueuePairing()
        if syncQueue.pending == nil, syncQueue.inFlight == nil {
            refreshFrame(selectEditorPage: devicePageID == nil, force: true)
        } else {
            var next = syncQueue; next.prepareRetry()
            do { try commitQueue(next); status = "等待设备重新领取最新画面" }
            catch { recordSyncPersistenceFailure(error) }
        }
        if !server.isRunning { startServer() }
    }

    private func makeSyncContent(pageID: UUID, focus: UUID?, force: Bool = false) throws -> QueuedSyncFrame {
        guard let page = project.pages.first(where: { $0.id == pageID }) else { throw InkError.message("要同步的页面不存在。") }
        var output = try FrameRenderer.render(page: page, todos: project.todos, configuration: project.device,
            revision: revision + 1, focusedTaskID: focus)
        guard output.taskIDs.count <= 96 else {
            throw InkError.message("设备每页最多操作 96 项任务。请在 Todo 组件中按项目过滤或隐藏已完成任务，再发布。")
        }
        let metadata = SyncFrameMetadata(pages: project.pages.map { SyncPageSummary(id: $0.id, name: $0.name) },
            focusedTaskID: focus.flatMap { output.taskIDs.contains($0) ? $0 : nil }, pollSeconds: project.device.pollSeconds)
        var content = QueuedSyncFrame(frame: output, metadata: metadata)
        if !force, let latest = syncQueue.latestContent, latest.representsSameContent(as: content) {
            output.revision = latest.frame.revision; content.frame = output
        }
        return content
    }

    private func stageSyncContent(_ content: QueuedSyncFrame, force: Bool = false) throws {
        var next = syncQueue
        let changed = try next.stage(content, force: force)
        if changed { try commitQueue(next) }
        // Legacy endpoints advertise the latest queued raster, never proof of display.
        frame = syncQueue.latestContent?.frame
        devicePageID = content.frame.pageID; focusedTaskID = content.metadata.focusedTaskID
        revision = max(revision, max(content.frame.revision, syncQueue.maximumRevision))
        lastRenderSignature = renderSignature(for: project)
        updateSyncPresentation()
    }

    private func refreshFrame(selectEditorPage: Bool, force: Bool = false) {
        ensureQueuePairing()
        let pageID = selectEditorPage ? currentPage.id : devicePageID
        guard let pageID else { updateSyncPresentation(); return }
        do {
            // Project edits must be durable before their raster enters a separate file.
            try persistProject()
            let content = try makeSyncContent(pageID: pageID, focus: selectEditorPage ? nil : focusedTaskID, force: force)
            try stageSyncContent(content, force: force)
            if selectEditorPage { status = "最新画面已排队，等待设备确认显示" }
        } catch { recordSyncPersistenceFailure(error) }
    }
    func startServer() {
        guard !server.isRunning else { return }
        guard (1024...65535).contains(project.device.port) else { errorMessage = "端口必须在 1024–65535 之间。"; return }
        if frame == nil { refreshFrame(selectEditorPage: true) }
        do { try server.start(port: UInt16(project.device.port)); status = "同步服务已启动"; updateSyncPresentation() }
        catch { errorMessage = "同步服务无法启动：\(error.localizedDescription)"; updateSyncPresentation() }
    }
    func stopServer() { server.stop(); deviceLastSeen = nil; status = "同步服务已停止"; updateSyncPresentation() }
    func rotateDeviceToken() {
        project.device.token = UUID().uuidString.replacingOccurrences(of: "-", with: ""); project.deviceEventLedger = []
        ensureQueuePairing()
        save()
        do { try commitQueue(syncQueue) } catch { recordSyncPersistenceFailure(error) }
    }
    func copyConnectionInfo() {
        let address = localAddresses.first ?? "127.0.0.1"
        let text = "Mac 地址：http://\(address):\(project.device.port)\n设备配对密钥：\(project.device.token)\n轮询间隔：\(project.device.pollSeconds) 秒"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status = "设备连接信息已复制"
    }

    func handleRequest(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        if path == "/health", request.method == "GET" { return .json(["ok": true, "app": "InkDesk", "protocol": 1]) }
        guard request.headers["authorization"] == "Bearer " + project.device.token else { return .json(["error": "需要设备配对密钥"], status: 401) }
        deviceLastSeen = Date()
        ensureQueuePairing()
        if ["/api/sync/manifest", "/api/sync/frame.bin", "/api/sync/status"].contains(path) {
            syncLastContact = Date()
            return handleSyncRequest(request, path: path)
        }
        if request.method == "GET", path == "/api/manifest" {
            guard let frame else { return .json(["error": "尚未发布画面"], status: 503) }
            let content = syncQueue.latestContent ?? QueuedSyncFrame(frame: frame, metadata: SyncFrameMetadata(
                pages: project.pages.map { SyncPageSummary(id: $0.id, name: $0.name) }, focusedTaskID: focusedTaskID,
                pollSeconds: project.device.pollSeconds))
            return .json(manifest(for: content, frameURL: "/api/frame.bin"))
        }
        if request.method == "GET", path == "/api/frame.bin" || path == "/api/frame.png" {
            guard let frame else { return .json(["error": "尚未发布画面"], status: 503) }
            let tag = "\"\(frame.hash)\""
            if request.headers["if-none-match"] == tag { return HTTPResponse(status: 304, contentType: "application/octet-stream", body: Data(), headers: ["ETag": tag]) }
            return HTTPResponse(status: 200, contentType: path.hasSuffix(".png") ? "image/png" : "application/octet-stream",
                                body: path.hasSuffix(".png") ? frame.pngData : frame.bitmapData,
                                headers: ["ETag": tag, "X-InkDesk-Revision": String(frame.revision), "Cache-Control": "no-store"])
        }
        if request.method == "POST", path == "/api/action" { return handleAction(request.body) }
        return .json(["error": "接口不存在"], status: 404)
    }

    private func manifest(for content: QueuedSyncFrame, frameURL: String, transferID: UUID? = nil) -> [String: Any] {
        content.manifest(frameURL: frameURL, transferID: transferID)
    }

    private func handleSyncRequest(_ request: HTTPRequest, path: String) -> HTTPResponse {
        let now = Date()
        if request.method == "GET", path == "/api/sync/manifest" {
            var next = syncQueue
            guard let transfer = next.claim(now: now) else { return .json(["error": "尚未排队画面"], status: 503) }
            do {
                // Repeated polls of a known completed frame do not create a new transfer.
                if next.inFlight?.id != syncQueue.inFlight?.id || next.retryReason != syncQueue.retryReason {
                    try commitQueue(next, at: now)
                }
                return .json(manifest(for: transfer.content, frameURL: "/api/sync/frame.bin", transferID: transfer.id))
            } catch { recordSyncPersistenceFailure(error); return .json(["error": "传输无法持久化，请重试"], status: 503) }
        }
        if request.method == "GET", path == "/api/sync/frame.bin" {
            recoverExpiredTransfer(at: now)
            // Fetching bytes never claims a pending frame. The preceding manifest owns
            // the transfer; an expired claim must be obtained again before download.
            guard let transfer = syncQueue.inFlight ?? (syncQueue.pending == nil ? syncQueue.confirmed : nil) else {
                return .json(["error": "请先领取有效同步清单"], status: 409)
            }
            guard transfer.state == .displayed || now < transfer.leaseExpiresAt else { return .json(["error": "传输已过期，请重新领取"], status: 409) }
            if let requestedID = request.headers["x-inkdesk-transfer-id"], requestedID != transfer.id.uuidString {
                return .json(["error": "传输 ID 已改变，请重新领取"], status: 409)
            }
            let frame = transfer.content.frame
            // Always return all verified bytes; no 304 shortcut can imply a physical refresh.
            return HTTPResponse(status: 200, contentType: "application/octet-stream", body: frame.bitmapData,
                headers: ["ETag": "\"\(frame.hash)\"", "X-InkDesk-Revision": String(frame.revision),
                          "X-InkDesk-Transfer-ID": transfer.id.uuidString, "Cache-Control": "no-store"])
        }
        if request.method == "POST", path == "/api/sync/status" {
            guard request.body.count <= 4096,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = (object["transferID"] as? String).flatMap(UUID.init(uuidString:)),
                  let pageID = (object["pageID"] as? String).flatMap(UUID.init(uuidString:)),
                  let revisionNumber = object["revision"] as? NSNumber,
                  CFGetTypeID(revisionNumber) != CFBooleanGetTypeID(),
                  revisionNumber.doubleValue.isFinite, revisionNumber.doubleValue.rounded() == revisionNumber.doubleValue,
                  revisionNumber.doubleValue >= 0, revisionNumber.doubleValue < Double(Int.max - 1),
                  let hash = object["hash"] as? String,
                  let state = (object["state"] as? String).flatMap(SyncTransferState.init(rawValue:)), state != .claimed,
                  object["error"] == nil || object["error"] is String else {
                return .json(["error": "回执格式无效"], status: 400)
            }
            var next = syncQueue
            // Device error strings are untrusted and may contain the pairing credential.
            // Redact it before showing a bounded message; it never enters sync-state.json.
            let deviceError = (object["error"] as? String).map {
                String($0.replacingOccurrences(of: project.device.token, with: "[已隐藏]").unicodeScalars
                    .filter { !CharacterSet.controlCharacters.contains($0) }.prefix(300).map(String.init).joined())
            }
            do {
                try next.acknowledge(id: id, pageID: pageID, revision: revisionNumber.intValue, hash: hash,
                    state: state, error: deviceError, now: now)
                try commitQueue(next, at: now)
                return .json(["ok": true, "transferID": id.uuidString])
            } catch FrameSyncError.staleTransfer {
                // Persist any lease expiry that the rejected late ACK discovered.
                if next.inFlight?.id != syncQueue.inFlight?.id {
                    do { try commitQueue(next, at: now) } catch { recordSyncPersistenceFailure(error) }
                }
                return .json(["error": "传输已过期或画面不匹配，请重新领取"], status: 409)
            } catch {
                recordSyncPersistenceFailure(error)
                return .json(["error": "回执无法持久化，请重试"], status: 503)
            }
        }
        return .json(["error": "接口不存在"], status: 404)
    }
    private func handleAction(_ data: Data) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["eventID"] as? String, UUID(uuidString: event) != nil,
              let action = json["action"] as? String,
              let sentPage = json["pageID"] as? String, UUID(uuidString: sentPage) != nil else {
            return .json(["error": "操作格式无效"], status: 400)
        }
        if let cached = project.deviceEventLedger?.first(where: { $0.id == event }) { return .json(["ok": true, "revision": cached.revision]) }
        // A physical button refers to the screen the device owns, even when a newer
        // pending frame advertises another page. Legacy clients use the latest frame.
        let contexts = [syncQueue.confirmed?.content, syncQueue.inFlight?.content, syncQueue.latestContent].compactMap { $0 }
            .filter { $0.frame.pageID == UUID(uuidString: sentPage) }
        let explicitTaskID = (json["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let taskAction = ["next_task", "previous_task", "toggle_task"].contains(action)
        let matchingContext = taskAction && explicitTaskID != nil
            ? contexts.first(where: { $0.frame.taskIDs.contains(explicitTaskID!) }) : contexts.first
        guard let context = matchingContext else {
            return .json(["error": "页面已改变，请刷新"], status: 409)
        }
        let actionFrame = context.frame
        guard project.pages.contains(where: { $0.id == actionFrame.pageID }) else {
            return .json(["error": "显示页面已删除，请同步最新画面"], status: 409)
        }
        let pages = project.pages
        let previousProject = project
        let previousPage = devicePageID
        let previousFocus = focusedTaskID
        let previousFrame = self.frame
        let previousRevision = revision
        let previousQueue = syncQueue
        let previousUndo = undoStack, previousRedo = redoStack
        let initialFocus = devicePageID == actionFrame.pageID ? focusedTaskID : context.metadata.focusedTaskID
        applyingDeviceAction = true
        defer { applyingDeviceAction = false }
        devicePageID = actionFrame.pageID; focusedTaskID = initialFocus
        func reject(_ message: String, status: Int) -> HTTPResponse {
            devicePageID = previousPage; focusedTaskID = previousFocus
            return .json(["error": message], status: status)
        }
        switch action {
        case "next_page", "previous_page":
            if let index = pages.firstIndex(where: { $0.id == actionFrame.pageID }) {
                let next = (index + (action == "next_page" ? 1 : pages.count - 1)) % pages.count
                devicePageID = pages[next].id; focusedTaskID = nil
            }
        case "next_task", "previous_task":
            guard !actionFrame.taskIDs.isEmpty else { return reject("此页面没有任务", status: 422) }
            if let target = explicitTaskID, actionFrame.taskIDs.contains(target) {
                focusedTaskID = target
            } else {
                let index = focusedTaskID.flatMap { actionFrame.taskIDs.firstIndex(of: $0) }
                let next = index.map { ($0 + (action == "next_task" ? 1 : actionFrame.taskIDs.count - 1)) % actionFrame.taskIDs.count } ?? 0
                focusedTaskID = actionFrame.taskIDs[next]
            }
        case "toggle_task":
            let id = (json["taskID"] as? String).flatMap(UUID.init(uuidString:)) ?? focusedTaskID
            guard let id, actionFrame.taskIDs.contains(id), project.todos.contains(where: { $0.id == id }) else { return reject("任务不存在或不在此页面", status: 422) }
            toggleTodo(id); focusedTaskID = id
        case "exit_task": focusedTaskID = nil
        case "refresh": break
        default: return reject("未知操作", status: 400)
        }
        var projectWasSaved = false
        do {
            let content = try makeSyncContent(pageID: devicePageID!, focus: focusedTaskID)
            var ledger = project.deviceEventLedger ?? []
            ledger.append(DeviceEvent(id: event, revision: content.frame.revision,
                targetPageID: content.frame.pageID, focusedTaskID: content.metadata.focusedTaskID))
            if ledger.count > 2048 { ledger.removeFirst(ledger.count - 2048) }
            project.deviceEventLedger = ledger
            // Persist accepted mutations and deduplication before publishing any raster.
            try persistProject(); projectWasSaved = true
            try stageSyncContent(content)
            cancelEditCoalescing(); saveTask?.cancel()
            return .json(["ok": true, "revision": content.frame.revision])
        }
        catch {
            project = previousProject; devicePageID = previousPage; focusedTaskID = previousFocus; self.frame = previousFrame; revision = previousRevision
            syncQueue = previousQueue; undoStack = previousUndo; redoStack = previousRedo; updateUndoState()
            if projectWasSaved {
                do { try persistProject() }
                catch { errorMessage = "设备操作回滚无法保存：\(error.localizedDescription)" }
            }
            lastRenderSignature = renderSignature(for: project)
            errorMessage = "设备操作未保存：\(error.localizedDescription)"
            updateSyncPresentation()
            return .json(["error": "操作无法持久化，请重试"], status: 503)
        }
    }
}
