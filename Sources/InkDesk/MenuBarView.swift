import SwiftUI
import AppKit

struct InkDeskMenuBarView: View {
    @EnvironmentObject private var store: AppState
    @Environment(\.openWindow) private var openWindow
    let delegate: InkDeskDelegate

    var body: some View {
        Group {
            Text("InkDesk").font(.headline)
            Label(store.server.isRunning ? "同步服务运行中" : "同步服务已停止",
                  systemImage: store.server.isRunning ? "wifi" : "wifi.slash")
            Text("同步：\(store.syncPhase)")
            Text("待同步 \(store.pendingFrame == nil ? 0 : 1) 张 · 本次同步 \(store.inFlightFrame == nil ? 0 : 1) 张")
            if store.isSyncEditPending {
                Text("等待编辑完成").font(.caption)
            }
            if let confirmedAt = store.lastDisplayConfirmedAt, store.displayedFrame != nil {
                Text("最近确认：\(confirmedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            } else {
                Text("设备显示未确认").font(.caption)
            }
            Divider()
            Button("打开 InkDesk", systemImage: "macwindow") {
                delegate.showMainWindow { openWindow(id: "main") }
            }
            Button("立即同步当前页", systemImage: "arrow.triangle.2.circlepath", action: store.publish)
            Button(store.server.isRunning ? "停止同步服务" : "启动同步服务",
                   systemImage: store.server.isRunning ? "stop.circle" : "play.circle") {
                if store.server.isRunning { store.stopServer() }
                else { store.startServer() }
            }
            Divider()
            Button("退出 InkDesk", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }
    }
}
