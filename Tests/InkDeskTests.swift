import Foundation
import SwiftUI
import AppKit

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw InkError.message(message) }
}

@MainActor func runInkDeskTests() async throws {
    try await runServiceTests()
    try testClockPublishingBoundary()
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("inkdesk-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: path) }
    let store = AppState(dataDirectory: path, loadKey: false)
    let original = store.project
    store.addWidget(.qr)
    try require(store.currentPage.widgets.count == original.pages[0].widgets.count + 1, "组件添加失败")
    store.undo()
    try require(store.project == original, "撤销未恢复原始项目")
    store.redo()
    try require(store.currentPage.widgets.count == original.pages[0].widgets.count + 1, "重做失败")
    if let id = store.selectedWidgetID { store.updateWidget(id) { $0.x = -200; $0.y = 1000; $0.width = 900 } }
    try require(store.selectedWidget?.x == 0 && store.selectedWidget?.width == 800, "组件边界约束失败")
    store.addTodo(title: "验证数据持久化", project: "测试", priority: 2)
    store.save()
    let reload = AppState(dataDirectory: path, loadKey: false)
    try require(reload.project == store.project, "项目重启后未恢复")
    try testPairingTokenSurvivesHistory(dataDirectory: path.appendingPathComponent("token-history", isDirectory: true))
    try testUnreadableProjectRecovery(dataDirectory: path.appendingPathComponent("unreadable-project", isDirectory: true))
    var invalid = store.project; invalid.formatVersion = 999
    do { try invalid.validate(); throw InkError.message("不兼容项目没有被拒绝") }
    catch InkError.message(let text) where text.contains("格式不受支持") {}
    let rendered = try FrameRenderer.render(page: store.currentPage, todos: store.project.todos, configuration: store.project.device, revision: 1)
    try require(rendered.bitmapData.count == 48000, "设备位图大小错误")
    try require(rendered.pngData.starts(with: [137,80,78,71,13,10,26,10]), "PNG 格式错误")
    let gray = [UInt8](repeating: 255, count: 800 * 480)
    let provider = CGDataProvider(data: Data(gray) as CFData)!
    let whiteImage = CGImage(width: 800, height: 480, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 800,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let blank = try FrameRenderer.monochrome(whiteImage, threshold: 0.6, dither: false)
    try require(blank.bitmap.allSatisfy { $0 == 255 }, "白色位图极性错误")
    var pixels = gray; pixels[0] = 0; pixels[800 * 479 + 799] = 0
    let fixtureProvider = CGDataProvider(data: Data(pixels) as CFData)!
    let fixture = CGImage(width: 800, height: 480, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 800,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: fixtureProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let packed = try FrameRenderer.monochrome(fixture, threshold: 0.6, dither: false)
    try require(packed.bitmap[0] == 0x7f && packed.bitmap[47999] == 0xfe, "位图方向或 MSB 位序错误")
    let dithered = try FrameRenderer.monochrome(fixture, threshold: 0.6, dither: true)
    try require(dithered.bitmap.count == 48000, "抖动位图大小错误")
    store.publish(); store.stopServer()
    guard let frame = store.frame, let firstTask = frame.taskIDs.first else { throw InkError.message("发布帧或任务映射缺失") }
    let unauthorized = store.handleRequest(HTTPRequest(method: "GET", path: "/api/manifest", headers: [:], body: Data()))
    try require(unauthorized.status == 401, "设备接口未验证配对密钥")
    let auth = ["authorization": "Bearer " + store.project.device.token]
    let manifest = store.handleRequest(HTTPRequest(method: "GET", path: "/api/manifest", headers: auth, body: Data()))
    let json = try JSONSerialization.jsonObject(with: manifest.body) as! [String: Any]
    try require(json["hash"] as? String == frame.hash, "清单哈希与位图不匹配")
    let event = UUID().uuidString
    let body = try JSONSerialization.data(withJSONObject: ["eventID": event, "action": "toggle_task", "pageID": frame.pageID.uuidString, "taskID": firstTask.uuidString])
    let request = HTTPRequest(method: "POST", path: "/api/action", headers: auth, body: body)
    let before = store.project.todos.first { $0.id == firstTask }!.completed
    try require(store.handleRequest(request).status == 200, "设备任务操作失败")
    try require(store.project.todos.first { $0.id == firstTask }!.completed != before, "任务状态没有改变")
    _ = store.handleRequest(request)
    try require(store.project.todos.first { $0.id == firstTask }!.completed != before, "重复设备事件被执行两次")
    store.save()
    let restarted = AppState(dataDirectory: path, loadKey: false)
    _ = restarted.handleRequest(request)
    try require(restarted.project.todos.first { $0.id == firstTask }!.completed != before, "重启后重复事件改变了任务")
    try require(restarted.project.deviceEventLedger?.contains(where: { $0.id == event }) == true, "设备事件未持久化")
    let etag = store.handleRequest(HTTPRequest(method: "GET", path: "/api/frame.bin", headers: auth.merging(["if-none-match": "\"\(store.frame!.hash)\""]) { _, new in new }, body: Data()))
    try require(etag.status == 304, "未变化的画面未返回 304")
    try testHiddenCompletedDeviceFocus(dataDirectory: path.appendingPathComponent("hidden-focus", isDirectory: true))
    try testOffscreenDeviceFocus(dataDirectory: path.appendingPathComponent("offscreen-focus", isDirectory: true))
    try testFrameSyncQueue()
    try testSyncProtocol(dataDirectory: path.appendingPathComponent("sync-protocol", isDirectory: true))
    try testSyncActionContexts(dataDirectory: path.appendingPathComponent("sync-actions", isDirectory: true))
    try testSyncActionPersistenceFailure(dataDirectory: path.appendingPathComponent("sync-failure", isDirectory: true))
    try await testEditSyncCoalescing(dataDirectory: path.appendingPathComponent("sync-edits", isDirectory: true))
    try await testSyncCrashReconciliation(dataDirectory: path.appendingPathComponent("sync-crash", isDirectory: true))
    let checkFile = path.appendingPathComponent("verified-screen.png")
    try rendered.pngData.write(to: checkFile)
    print("Layout, undo/redo, persistence and recovery, frame packing, task focus, immutable sync queue, leases, ACKs, restart recovery, edit merging and action rollback: passed")
}

@MainActor private func testClockPublishingBoundary() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_100)
    let initial = AppState.clockRefreshBucket(at: start)
    try require(AppState.clockRefreshBucket(at: start.addingTimeInterval(60)) == initial, "时钟仍在一分钟后自动更新")
    try require(AppState.clockRefreshBucket(at: start.addingTimeInterval(299.999)) == initial, "时钟在五分钟边界前提前更新")
    let next = AppState.clockRefreshBucket(at: start.addingTimeInterval(300))
    try require(next != initial, "时钟没有在 300 秒边界更新")
    try require(AppState.clockRefreshBucket(at: start.addingTimeInterval(599.999)) == next, "同一个五分钟周期重复更新时钟")
    try require(AppState.clockRefreshBucket(at: start.addingTimeInterval(600)) != next, "下一个五分钟边界没有更新时钟")
}

@MainActor private func testPairingTokenSurvivesHistory(dataDirectory: URL) throws {
    let store = AppState(dataDirectory: dataDirectory, loadKey: false)
    let count = store.currentPage.widgets.count
    let originalToken = store.project.device.token
    store.addWidget(.note)
    store.rotateDeviceToken()
    let afterRotation = store.project.device.token
    try require(afterRotation != originalToken, "配对密钥未重置")
    store.undo()
    try require(store.currentPage.widgets.count == count && store.project.device.token == afterRotation, "编辑撤销回滚了新配对密钥")
    // Rotate again while redo is pending: its stored snapshot now contains an obsolete token.
    store.rotateDeviceToken()
    let beforeRedo = store.project.device.token
    try require(beforeRedo != afterRotation, "第二次配对密钥未重置")
    store.redo()
    try require(store.currentPage.widgets.count == count + 1 && store.project.device.token == beforeRedo, "编辑重做恢复了旧配对密钥")
}

@MainActor private func testUnreadableProjectRecovery(dataDirectory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    let projectURL = dataDirectory.appendingPathComponent("project.json")
    let corrupt = Data("{unreadable project; retain these exact bytes}".utf8)
    try corrupt.write(to: projectURL)
    let store = AppState(dataDirectory: dataDirectory, loadKey: false)
    let afterLoad = try Data(contentsOf: projectURL)
    try require(store.errorMessage != nil && afterLoad == corrupt, "读取损坏项目时覆盖了原文件")
    // A read-only directory permits reading the original but prevents creating its recovery copy.
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dataDirectory.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path) }
    store.save()
    let afterFailedBackup = try Data(contentsOf: projectURL)
    try require(afterFailedBackup == corrupt, "备份失败后仍覆盖了损坏项目原文")
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
    store.save()
    let backups = try manager.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("project-unreadable-") && $0.pathExtension == "json" }
    try require(backups.count == 1, "重新保存损坏项目时没有生成唯一恢复备份")
    let backupData = try Data(contentsOf: backups[0])
    try require(backupData == corrupt, "损坏项目备份未保留原始字节")
    let saved = try JSONDecoder().decode(InkProject.self, from: Data(contentsOf: projectURL))
    try require(saved == store.project, "成功备份后未保存有效项目")
}

@MainActor private func deviceTestManifest(_ store: AppState) throws -> [String: Any] {
    let response = store.handleRequest(HTTPRequest(method: "GET", path: "/api/manifest",
        headers: ["authorization": "Bearer " + store.project.device.token], body: Data()))
    try require(response.status == 200, "焦点测试无法读取设备清单")
    guard let manifest = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
        throw InkError.message("焦点测试设备清单格式错误")
    }
    return manifest
}

@MainActor private func deviceTestAction(_ store: AppState, action: String, taskID: UUID?) throws {
    guard let pageID = store.frame?.pageID else { throw InkError.message("焦点测试没有发布页面") }
    var object: [String: Any] = ["eventID": UUID().uuidString, "action": action, "pageID": pageID.uuidString]
    if let taskID { object["taskID"] = taskID.uuidString }
    let response = store.handleRequest(HTTPRequest(method: "POST", path: "/api/action",
        headers: ["authorization": "Bearer " + store.project.device.token],
        body: try JSONSerialization.data(withJSONObject: object)))
    try require(response.status == 200, "焦点测试设备操作失败：\(action)")
}

@MainActor private func deviceTestStore(dataDirectory: URL, widget: InkWidget, todos: [TodoItem]) -> AppState {
    let store = AppState(dataDirectory: dataDirectory, loadKey: false)
    let page = InkPage(name: "任务焦点回归", widgets: [widget])
    var project = InkProject(pages: [page], todos: todos, selectedPageID: page.id)
    project.device.autoSync = false
    store.project = project
    store.publish()
    store.stopServer()
    return store
}

@MainActor private func testHiddenCompletedDeviceFocus(dataDirectory: URL) throws {
    var widget = InkWidget(kind: .todo, title: "未完成任务", x: 20, y: 20, width: 600, height: 220)
    widget.hideCompleted = true
    let selected = TodoItem(title: "完成后应从设备清单隐藏")
    let remaining = TodoItem(title: "仍未完成的任务")
    let store = deviceTestStore(dataDirectory: dataDirectory, widget: widget, todos: [selected, remaining])
    defer { store.stopServer() }
    try deviceTestAction(store, action: "next_task", taskID: selected.id)
    let before = try deviceTestManifest(store)
    try require(before["focusedTaskID"] as? String == selected.id.uuidString, "设备没有聚焦目标任务")
    try deviceTestAction(store, action: "toggle_task", taskID: selected.id)
    let after = try deviceTestManifest(store)
    try require(store.project.todos.first(where: { $0.id == selected.id })?.completed == true, "焦点任务没有完成")
    guard let taskIDs = after["taskIDs"] as? [String] else { throw InkError.message("清单缺少任务 ID") }
    try require(!taskIDs.contains(selected.id.uuidString) && taskIDs.contains(remaining.id.uuidString), "隐藏已完成任务后设备任务映射未更新")
    try require(after["focusedTaskID"] is NSNull, "已隐藏的完成任务仍残留设备焦点")
    try deviceTestAction(store, action: "next_task", taskID: nil)
    let resumed = try deviceTestManifest(store)
    try require(resumed["focusedTaskID"] as? String == remaining.id.uuidString, "清除隐藏任务焦点后无法聚焦剩余任务")
}

@MainActor private func testOffscreenDeviceFocus(dataDirectory: URL) throws {
    let widget = InkWidget(kind: .todo, title: "大量任务", x: 20, y: 20, width: 760, height: 180, fontSize: 22)
    let todos = (1...30).map { TodoItem(title: "待办任务 \($0)") }
    guard let target = todos.last else { throw InkError.message("分页测试没有目标任务") }
    let store = deviceTestStore(dataDirectory: dataDirectory, widget: widget, todos: todos)
    defer { store.stopServer() }
    guard let firstFrame = store.frame else { throw InkError.message("分页测试没有初始画面") }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var changedTodos = todos
    changedTodos[changedTodos.count - 1].title = "焦点后页的可见文字已改变"
    let unselectedChanged = try FrameRenderer.render(page: store.currentPage, todos: changedTodos,
        configuration: store.project.device, revision: firstFrame.revision, date: date)
    // Changing a task's title does not affect the initial frame: the task starts outside the visible rows.
    try require(firstFrame.bitmapData == unselectedChanged.bitmapData, "分页测试目标任务没有位于初始屏幕后方")
    try deviceTestAction(store, action: "next_task", taskID: target.id)
    let manifest = try deviceTestManifest(store)
    try require(manifest["focusedTaskID"] as? String == target.id.uuidString, "无法聚焦屏幕后方的任务")
    guard let focused = store.frame else { throw InkError.message("分页焦点没有产生画面") }
    try require(focused.hash != firstFrame.hash && focused.bitmapData != firstFrame.bitmapData, "屏幕后方任务获得焦点后画面没有翻页")
    let focusedChanged = try FrameRenderer.render(page: store.currentPage, todos: changedTodos,
        configuration: store.project.device, revision: focused.revision, focusedTaskID: target.id, date: date)
    // A second change to the late task's title changes pixels only after focus brings that row into view.
    try require(focusedChanged.bitmapData != focused.bitmapData, "后页任务焦点变化但目标文字仍未渲染为可见")
}

@MainActor private func syncFixture(_ text: String, page: InkPage, revision: Int, taskID: UUID? = nil) throws -> QueuedSyncFrame {
    var changed = page
    changed.widgets[0].text = text
    var frame = try FrameRenderer.render(page: changed, todos: [], configuration: DeviceConfiguration(), revision: revision,
        date: Date(timeIntervalSince1970: 1_700_000_100))
    if let taskID { frame.taskIDs = [taskID] }
    return QueuedSyncFrame(frame: frame, metadata: SyncFrameMetadata(pages: [SyncPageSummary(id: page.id, name: page.name)],
        focusedTaskID: taskID, pollSeconds: 30))
}

private func expectStaleACK(_ body: () throws -> Void) throws {
    do { try body(); throw InkError.message("过期或不匹配回执未被拒绝") }
    catch FrameSyncError.staleTransfer {}
}

@MainActor private func testFrameSyncQueue() throws {
    let page = InkPage(name: "队列回归", widgets: [InkWidget(kind: .note, title: "固定画面")])
    let taskID = UUID()
    let a = try syncFixture("初始内容", page: page, revision: 1)
    let b = try syncFixture("设备领取内容", page: page, revision: 2, taskID: taskID)
    let c = try syncFixture("中间编辑应合并", page: page, revision: 3)
    let d = try syncFixture("最终编辑应保留", page: page, revision: 4)
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let token = "test-pairing-not-a-production-secret"
    var queue = FrameSyncQueue(pairingToken: token)
    try queue.stage(a); try queue.stage(b)
    try require(queue.pending?.frame.hash == b.frame.hash, "待同步没有只保留最新画面")
    let claimed = queue.claim(now: now)!
    try queue.stage(c); try queue.stage(d)
    try require(queue.inFlight?.id == claimed.id && queue.inFlight?.content.frame.hash == b.frame.hash,
        "编辑替换了已经领取的不可变画面")
    try require(queue.inFlight?.content.metadata.focusedTaskID == taskID && queue.pending?.metadata.focusedTaskID == nil,
        "领取清单焦点被后续编辑改变")
    try require(queue.pending?.frame.hash == d.frame.hash, "忙碌期间没有只保留最新编辑")
    try expectStaleACK {
        try queue.acknowledge(id: claimed.id, pageID: b.frame.pageID, revision: b.frame.revision + 1,
            hash: b.frame.hash, state: .displayed, now: now)
    }
    try queue.acknowledge(id: claimed.id, pageID: b.frame.pageID, revision: b.frame.revision,
        hash: b.frame.hash, state: .downloaded, now: now.addingTimeInterval(10))
    try require(queue.confirmed == nil && queue.inFlight?.state == .downloaded, "下载回执被误当作显示完成")
    try queue.acknowledge(id: claimed.id, pageID: b.frame.pageID, revision: b.frame.revision,
        hash: b.frame.hash, state: .refreshing, now: now.addingTimeInterval(20))
    try require(queue.confirmed == nil && queue.inFlight?.state == .refreshing, "刷新开始被误当作显示完成")
    let encodedActive = try queue.encoded(now: now.addingTimeInterval(20))
    var restored = try FrameSyncQueue(data: encodedActive, pairingToken: token, now: now.addingTimeInterval(30))
    try require(restored.inFlight?.id == claimed.id && restored.pending?.frame.hash == d.frame.hash && restored.maximumRevision == 4,
        "重启没有恢复不可变传输、最新待同步和版本")
    let completedAt = now.addingTimeInterval(40)
    try restored.acknowledge(id: claimed.id, pageID: b.frame.pageID, revision: b.frame.revision,
        hash: b.frame.hash, state: .displayed, now: completedAt)
    try require(restored.confirmed?.content.frame.hash == b.frame.hash && restored.pending?.frame.hash == d.frame.hash,
        "显示确认丢失最新待同步，或确认了错误画面")
    try restored.acknowledge(id: claimed.id, pageID: b.frame.pageID, revision: b.frame.revision,
        hash: b.frame.hash, state: .displayed, now: now.addingTimeInterval(50))
    try require(restored.lastDisplayConfirmedAt == completedAt, "重复回执修改了实际确认时间")
    let savedConfirmed = try restored.encoded(now: now.addingTimeInterval(50))
    let confirmedReload = try FrameSyncQueue(data: savedConfirmed, pairingToken: token, now: now.addingTimeInterval(60))
    try require(confirmedReload.confirmed?.id == claimed.id && confirmedReload.lastDisplayConfirmedAt == completedAt,
        "重启丢失已确认显示记录")
    restored.cancelPending()
    try require(restored.claim(now: now.addingTimeInterval(70))?.id == claimed.id && restored.inFlight == nil,
        "轮询已确认画面重复创建忙碌传输")
    try require(String(data: savedConfirmed, encoding: .utf8)?.contains(token) == false, "同步状态写入了配对原文")
    do { _ = try FrameSyncQueue(data: savedConfirmed, pairingToken: "another-pair", now: now); throw InkError.message("旧配对状态没有被拒绝") }
    catch FrameSyncError.pairingChanged {}
    var tampered = try JSONSerialization.jsonObject(with: savedConfirmed) as! [String: Any]
    var pending = tampered["pending"] as! [String: Any]
    var frameObject = pending["frame"] as! [String: Any]
    frameObject["bitmapData"] = Data(repeating: 255, count: 48_000).base64EncodedString()
    pending["frame"] = frameObject; tampered["pending"] = pending
    do {
        _ = try FrameSyncQueue(data: JSONSerialization.data(withJSONObject: tampered), pairingToken: token, now: now)
        throw InkError.message("重启接受了与 SHA256 不符的位图")
    } catch FrameSyncError.invalid {}

    var leased = FrameSyncQueue(pairingToken: token)
    try leased.stage(a)
    let expiredID = leased.claim(now: now)!.id
    try leased.stage(d)
    try require(!leased.expireLease(now: now.addingTimeInterval(179.999)), "租约在 180 秒前过期")
    try require(leased.expireLease(now: now.addingTimeInterval(180)) && leased.pending?.frame.hash == d.frame.hash,
        "租约过期没有保留最新画面")
    try expectStaleACK {
        try leased.acknowledge(id: expiredID, pageID: a.frame.pageID, revision: a.frame.revision,
            hash: a.frame.hash, state: .displayed, now: now.addingTimeInterval(181))
    }
    let retry = leased.claim(now: now.addingTimeInterval(182))!
    try require(retry.id != expiredID && retry.content.frame.hash == d.frame.hash, "租约重试领取了旧帧或重用了过期 ID")
    try leased.acknowledge(id: retry.id, pageID: d.frame.pageID, revision: d.frame.revision,
        hash: d.frame.hash, state: .failed, error: "BUSY 超时", now: now.addingTimeInterval(183))
    try require(leased.confirmed == nil && leased.pending?.frame.hash == d.frame.hash && leased.retryReason == .failed,
        "刷新失败被伪装成成功，或丢失可重试画面")
    try leased.acknowledge(id: retry.id, pageID: d.frame.pageID, revision: d.frame.revision,
        hash: d.frame.hash, state: .failed, now: now.addingTimeInterval(184))
    try expectStaleACK {
        try leased.acknowledge(id: retry.id, pageID: d.frame.pageID, revision: d.frame.revision,
            hash: d.frame.hash, state: .displayed, now: now.addingTimeInterval(184))
    }
    leased.cancelPending()
    let failedReload = try FrameSyncQueue(data: leased.encoded(now: now.addingTimeInterval(185)), pairingToken: token,
        now: now.addingTimeInterval(186))
    try require(failedReload.maximumRevision == d.frame.revision, "取消失败帧后重启回退已使用版本")
    var oversized = a
    oversized.metadata.pages = (0..<24).map { SyncPageSummary(id: $0 == 0 ? page.id : UUID(), name: String(repeating: "长", count: 1300)) }
    do { try leased.stage(oversized); throw InkError.message("超出固件 64 KiB 上限的清单被接受") }
    catch FrameSyncError.invalid {}
}

@MainActor private func syncRequest(_ store: AppState, method: String, path: String, object: [String: Any]? = nil) throws -> HTTPResponse {
    store.handleRequest(HTTPRequest(method: method, path: path, headers: ["authorization": "Bearer " + store.project.device.token],
        body: try object.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()))
}

@MainActor private func syncManifest(_ store: AppState) throws -> [String: Any] {
    let response = try syncRequest(store, method: "GET", path: "/api/sync/manifest")
    try require(response.status == 200, "无法领取现代同步清单")
    return try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
}

private func statusObject(_ manifest: [String: Any], state: String) -> [String: Any] {
    ["transferID": manifest["transferID"]!, "pageID": manifest["pageID"]!, "revision": manifest["revision"]!,
     "hash": manifest["hash"]!, "state": state]
}

@MainActor private func makeNoteSyncStore(_ directory: URL) -> AppState {
    let store = AppState(dataDirectory: directory, loadKey: false)
    var widget = InkWidget(kind: .note, title: "同步回归")
    widget.text = "设备最初领取的内容"
    let page = InkPage(name: "同步回归页面", widgets: [widget])
    var project = InkProject(pages: [page], todos: [], selectedPageID: page.id)
    project.device.autoSync = false
    store.project = project; store.publish(); store.stopServer()
    return store
}

@MainActor private func testSyncProtocol(dataDirectory: URL) throws {
    let store = makeNoteSyncStore(dataDirectory)
    defer { store.stopServer() }
    try require(store.pendingFrame != nil && store.displayedFrame == nil, "发布帧被误显示为硬件确认")
    _ = try deviceTestManifest(store)
    try require(store.syncLastContact == nil && store.displayedFrame == nil, "旧接口诊断流量冒充现代确认")
    let unclaimed = try syncRequest(store, method: "GET", path: "/api/sync/frame.bin")
    try require(unclaimed.status == 409 && store.inFlightFrame == nil, "下载接口自行领取了待同步帧")
    let first = try syncManifest(store)
    let old = store.inFlightFrame!
    try require(first["frameURL"] as? String == "/api/sync/frame.bin" && store.pendingFrame == nil && store.syncLastContact != nil,
        "现代协议清单或领取状态无效")
    store.updateWidget(store.currentPage.widgets[0].id) { $0.text = "传输期间的最新内容" }
    store.publish(); store.stopServer()
    try require(store.pendingFrame?.hash != old.hash && store.inFlightFrame?.hash == old.hash,
        "手动同步覆盖了忙碌设备领取的帧")
    let pinned = try syncManifest(store)
    try require(pinned["transferID"] as? String == first["transferID"] as? String && pinned["hash"] as? String == old.hash,
        "重复领取改变了固定的清单")
    let bytes = try syncRequest(store, method: "GET", path: "/api/sync/frame.bin")
    try require(bytes.status == 200 && bytes.body == old.bitmapData, "固定清单与下载位图不一致")
    var mismatch = statusObject(first, state: "displayed"); mismatch["revision"] = old.revision + 1
    let rejected = try syncRequest(store, method: "POST", path: "/api/sync/status", object: mismatch)
    try require(rejected.status == 409 && store.displayedFrame == nil, "错版回执确认了屏幕")
    var invalid = statusObject(first, state: "displayed"); invalid["revision"] = true
    let invalidResponse = try syncRequest(store, method: "POST", path: "/api/sync/status", object: invalid)
    try require(invalidResponse.status == 400, "布尔型版本被接受为整数")
    for state in ["downloaded", "refreshing"] {
        let response = try syncRequest(store, method: "POST", path: "/api/sync/status", object: statusObject(first, state: state))
        try require(response.status == 200 && store.displayedFrame == nil, "非完成回执更新了已显示预览")
    }
    let confirmed = try syncRequest(store, method: "POST", path: "/api/sync/status", object: statusObject(first, state: "displayed"))
    let ack = try JSONSerialization.jsonObject(with: confirmed.body) as! [String: Any]
    try require(confirmed.status == 200 && ack["ok"] as? Bool == true && ack["transferID"] as? String == first["transferID"] as? String,
        "显示回执没有返回同一传输 ID")
    try require(store.displayedFrame?.hash == old.hash && store.pendingFrame != nil && store.inFlightFrame == nil,
        "完成回执没有确认固定帧，或覆盖了待同步")
    let confirmationTime = store.lastDisplayConfirmedAt
    let duplicate = try syncRequest(store, method: "POST", path: "/api/sync/status", object: statusObject(first, state: "displayed"))
    try require(duplicate.status == 200 && store.lastDisplayConfirmedAt == confirmationTime, "重复显示回执没有保持幂等")
    store.cancelPendingSync()
    let legacy = try deviceTestManifest(store)
    let legacyBytes = try syncRequest(store, method: "GET", path: "/api/frame.bin")
    try require(legacy["hash"] as? String == old.hash && legacyBytes.body == old.bitmapData, "取消待同步后旧接口仍提供被取消的帧")
    let idle = try syncManifest(store)
    try require(idle["transferID"] as? String == first["transferID"] as? String && store.inFlightFrame == nil,
        "已确认画面轮询不断重建传输状态")
    let restarted = AppState(dataDirectory: dataDirectory, loadKey: false)
    try require(restarted.displayedFrame?.hash == old.hash && restarted.lastDisplayConfirmedAt == confirmationTime,
        "应用重启丢失已确认预览")
    let resumedDuplicate = try syncRequest(restarted, method: "POST", path: "/api/sync/status", object: statusObject(first, state: "displayed"))
    try require(resumedDuplicate.status == 200, "重启后已完成回执失去幂等性")
    restarted.publish(); restarted.stopServer()
    let active = try syncManifest(restarted)
    let activeReload = AppState(dataDirectory: dataDirectory, loadKey: false)
    let recovered = try syncManifest(activeReload)
    try require(active["transferID"] as? String == recovered["transferID"] as? String && activeReload.inFlightFrame != nil,
        "应用重启替换了有效领取帧")
    let previousMaximum = activeReload.inFlightFrame!.revision
    activeReload.publish(); activeReload.stopServer()
    try require((activeReload.pendingFrame?.revision ?? 0) > previousMaximum, "重启后新发布版本没有递增")
}

@MainActor private func testSyncActionContexts(dataDirectory: URL) throws {
    var widget = InkWidget(kind: .todo, title: "已显示任务", width: 680, height: 300)
    widget.hideCompleted = true
    let shownTask = TodoItem(title: "显示帧仍有此任务")
    let secondTask = TodoItem(title: "另一个任务")
    let store = deviceTestStore(dataDirectory: dataDirectory, widget: widget, todos: [shownTask, secondTask])
    defer { store.stopServer() }
    let shown = try syncManifest(store)
    let confirmedResponse = try syncRequest(store, method: "POST", path: "/api/sync/status", object: statusObject(shown, state: "displayed"))
    try require(confirmedResponse.status == 200, "动作上下文测试无法确认初始画面")
    let shownPage = store.currentPage.id
    store.toggleTodo(shownTask.id); store.publish(); store.stopServer()
    let newTransfer = try syncManifest(store)
    let pinned = store.inFlightFrame!
    try require(!pinned.taskIDs.contains(shownTask.id) && store.displayedFrame?.taskIDs.contains(shownTask.id) == true,
        "上下文回归未形成旧屏幕和新传输的任务差异")
    let futurePage = InkPage(name: "未来页面", widgets: [InkWidget(kind: .note, title: "稍后显示")])
    store.project.pages.append(futurePage); store.selectPage(futurePage.id); store.publish(); store.stopServer()
    try require(store.pendingFrame?.pageID == futurePage.id, "上下文回归未形成未来页面待同步")
    let event = UUID().uuidString
    let toggle: [String: Any] = ["eventID": event, "action": "toggle_task", "pageID": shownPage.uuidString, "taskID": shownTask.id.uuidString]
    let response = try syncRequest(store, method: "POST", path: "/api/action", object: toggle)
    try require(response.status == 200 && store.project.todos.first(where: { $0.id == shownTask.id })?.completed == false,
        "未来 pending 或新传输过滤阻止了真实显示帧上的任务操作")
    try require(store.pendingFrame?.pageID == shownPage && store.inFlightFrame?.hash == pinned.hash,
        "实际屏幕动作覆盖了领取帧，或没有立即排队结果")
    let after = try syncManifest(store)
    try require(after["transferID"] as? String == newTransfer["transferID"] as? String && after["focusedTaskID"] is NSNull,
        "按键更新全局焦点后改变了不可变清单焦点")
    let ledger = store.project.deviceEventLedger!.last!
    try require(ledger.id == event && ledger.targetPageID == shownPage && ledger.focusedTaskID == shownTask.id,
        "接受事件没有保存可恢复的页面与焦点")
    let pendingRevision = store.pendingFrame!.revision
    let duplicate = try syncRequest(store, method: "POST", path: "/api/action", object: toggle)
    try require(duplicate.status == 200 && store.pendingFrame?.revision == pendingRevision &&
        store.project.todos.first(where: { $0.id == shownTask.id })?.completed == false, "重复动作没有保持幂等")
    let focus: [String: Any] = ["eventID": UUID().uuidString, "action": "next_task", "pageID": shownPage.uuidString,
        "taskID": secondTask.id.uuidString]
    let focusResponse = try syncRequest(store, method: "POST", path: "/api/action", object: focus)
    try require(focusResponse.status == 200, "传输期间的第二个 FIFO 动作没有被接受")
    let latest = try deviceTestManifest(store)
    try require(latest["focusedTaskID"] as? String == secondTask.id.uuidString && store.inFlightFrame?.hash == pinned.hash,
        "连续动作没有保持最新焦点或替换了传输帧")
}

@MainActor private func testSyncActionPersistenceFailure(dataDirectory: URL) throws {
    let widget = InkWidget(kind: .todo, title: "保存失败回归", width: 680, height: 300)
    let todo = TodoItem(title: "失败动作不能进入同步文件")
    let store = deviceTestStore(dataDirectory: dataDirectory, widget: widget, todos: [todo])
    defer { store.stopServer() }
    let before = store.project
    let beforeFrame = store.pendingFrame!
    let savedQueue = try Data(contentsOf: store.syncStorageURL)
    let action: [String: Any] = ["eventID": UUID().uuidString, "action": "toggle_task", "pageID": beforeFrame.pageID.uuidString,
        "taskID": todo.id.uuidString]
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dataDirectory.path)
    let failed = try syncRequest(store, method: "POST", path: "/api/action", object: action)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
    try require(failed.status == 503 && store.project == before && store.pendingFrame?.hash == beforeFrame.hash,
        "项目保存失败没有回滚动作和排队状态")
    let afterQueue = try Data(contentsOf: store.syncStorageURL)
    try require(afterQueue == savedQueue, "未接受的任务变化进入了持久化队列")

    // Exercise the second file failing after project+ledger have been atomically saved.
    try FileManager.default.removeItem(at: store.syncStorageURL)
    try FileManager.default.createDirectory(at: store.syncStorageURL, withIntermediateDirectories: false)
    defer {
        try? FileManager.default.removeItem(at: store.syncStorageURL)
        try? savedQueue.write(to: store.syncStorageURL, options: .atomic)
    }
    let queueFailed = try syncRequest(store, method: "POST", path: "/api/action", object: action)
    let persistedProject = try JSONDecoder().decode(InkProject.self, from: Data(contentsOf: store.storageURL))
    try require(queueFailed.status == 503 && store.project == before && persistedProject == before && store.pendingFrame?.hash == beforeFrame.hash,
        "队列文件写入失败没有回滚已保存的项目事件")
}

@MainActor private func testEditSyncCoalescing(dataDirectory: URL) async throws {
    let store = makeNoteSyncStore(dataDirectory)
    defer { store.stopServer() }
    let first = try syncManifest(store)
    _ = try syncRequest(store, method: "POST", path: "/api/sync/status", object: statusObject(first, state: "displayed"))
    let initialRevision = store.displayedFrame!.revision
    let initialHash = store.displayedFrame!.hash
    store.project.device.autoSync = true
    let widgetID = store.currentPage.widgets[0].id
    store.updateWidget(widgetID) { $0.text = "拖动或输入的中间编辑" }
    try require(store.isSyncEditPending && store.pendingFrame == nil, "编辑没有进入两秒合并等待")
    try await Task.sleep(nanoseconds: 900_000_000)
    store.updateWidget(widgetID) { $0.text = "停止编辑后唯一要显示的最终内容" }
    try await Task.sleep(nanoseconds: 1_400_000_000)
    try require(store.isSyncEditPending && store.pendingFrame == nil && store.displayedFrame?.hash == initialHash,
        "编辑等待没有从最后一次修改计时，或提前冒充显示")
    try await Task.sleep(nanoseconds: 900_000_000)
    let expected = try FrameRenderer.render(page: store.currentPage, todos: store.project.todos, configuration: store.project.device, revision: 0)
    try require(!store.isSyncEditPending && store.pendingFrame?.hash == expected.hash && store.pendingFrame?.revision == initialRevision + 1,
        "连续编辑没有合并为一个最新待同步帧")
    let coalescedRevision = store.pendingFrame!.revision
    store.project.deviceEventLedger?.append(DeviceEvent(id: UUID().uuidString, revision: coalescedRevision))
    try require(!store.isSyncEditPending && store.pendingFrame?.revision == coalescedRevision, "仅更新事件账本触发了重新渲染")
    store.updateWidget(widgetID) { $0.text = "此编辑应被取消" }
    try require(store.isSyncEditPending, "取消测试没有编辑等待")
    store.cancelPendingSync()
    try require(!store.isSyncEditPending && store.pendingFrame == nil && store.frame?.hash == initialHash,
        "取消没有清除编辑等待并恢复旧接口画面")
    store.save()
    let cancelledRestart = AppState(dataDirectory: dataDirectory, loadKey: false)
    try require(cancelledRestart.project.device.autoSync && !cancelledRestart.isSyncEditPending && cancelledRestart.pendingFrame == nil,
        "autoSync 开启时重启重新排队了明确取消的编辑")
    try await Task.sleep(nanoseconds: 2_200_000_000)
    try require(store.pendingFrame == nil && store.frame?.hash == initialHash, "取消的编辑 debounce 稍后重新排队")
    store.updateWidget(widgetID) { $0.text = "手动立即发布" }
    store.publish(); store.stopServer()
    let manualRevision = store.pendingFrame!.revision
    try require(!store.isSyncEditPending && manualRevision > coalescedRevision, "手动同步没有立即取消合并并排队")
    try await Task.sleep(nanoseconds: 2_200_000_000)
    try require(store.pendingFrame?.revision == manualRevision, "手动发布后遗留 debounce 重复排队")
}

@MainActor private func testSyncCrashReconciliation(dataDirectory: URL) async throws {
    let widget = InkWidget(kind: .todo, title: "崩溃恢复", width: 680, height: 300)
    let todo = TodoItem(title: "已经保存但还没有排队的完成动作")
    let store = deviceTestStore(dataDirectory: dataDirectory, widget: widget, todos: [todo])
    defer { store.stopServer() }
    let first = try syncManifest(store)
    let oldFrame = store.inFlightFrame!
    let acceptedEvent = UUID().uuidString
    var accepted = store.project
    accepted.todos[0].completed = true
    accepted.deviceEventLedger?.append(DeviceEvent(id: acceptedEvent, revision: oldFrame.revision + 1,
        targetPageID: oldFrame.pageID, focusedTaskID: todo.id))
    try JSONEncoder().encode(accepted).write(to: store.storageURL, options: .atomic)
    // sync-state.json deliberately remains the old active transfer, simulating the
    // crash between the project/event write and the queue write with autoSync off.
    let restarted = AppState(dataDirectory: dataDirectory, loadKey: false)
    try require(restarted.isSyncEditPending && restarted.inFlightFrame?.hash == oldFrame.hash,
        "接受动作的跨文件崩溃没有恢复意图，或覆盖领取帧")
    let duplicate: [String: Any] = ["eventID": acceptedEvent, "action": "toggle_task", "pageID": oldFrame.pageID.uuidString,
        "taskID": todo.id.uuidString]
    let duplicateResponse = try syncRequest(restarted, method: "POST", path: "/api/action", object: duplicate)
    try require(duplicateResponse.status == 200 && restarted.project.todos[0].completed, "崩溃恢复重复动作再次切换了任务")
    try await Task.sleep(nanoseconds: 2_200_000_000)
    let expected = try FrameRenderer.render(page: restarted.currentPage, todos: restarted.project.todos,
        configuration: restarted.project.device, revision: 0, focusedTaskID: todo.id)
    try require(restarted.pendingFrame?.hash == expected.hash && restarted.inFlightFrame?.hash == oldFrame.hash,
        "已经接受的任务动作没有恢复为最新待同步，或替换固定传输")
    let recoveredManifest = try syncManifest(restarted)
    try require(recoveredManifest["transferID"] as? String == first["transferID"] as? String, "崩溃恢复改变了有效领取 ID")
    restarted.cancelPendingSync()
    let cancelledRestart = AppState(dataDirectory: dataDirectory, loadKey: false)
    try require(!cancelledRestart.isSyncEditPending && cancelledRestart.pendingFrame == nil,
        "已取消的动作被较旧 ledger 版本在重启后重新排队")

    // Navigation/focus is not stored in the editor's selected page. Recover its
    // recorded target independently of autoSync and without changing the old lease.
    let target = InkPage(name: "设备导航目标", widgets: [InkWidget(kind: .todo, title: "目标页面", width: 680, height: 300)])
    var navigated = cancelledRestart.project
    navigated.pages.append(target)
    let watermark = try FrameSyncQueue(data: Data(contentsOf: cancelledRestart.syncStorageURL), pairingToken: navigated.device.token).maximumRevision
    navigated.deviceEventLedger?.append(DeviceEvent(id: UUID().uuidString, revision: watermark + 1,
        targetPageID: target.id, focusedTaskID: todo.id))
    try JSONEncoder().encode(navigated).write(to: cancelledRestart.storageURL, options: .atomic)
    let navigationRestart = AppState(dataDirectory: dataDirectory, loadKey: false)
    try require(navigationRestart.isSyncEditPending && navigationRestart.currentPage.id != target.id, "崩溃导航没有恢复设备目标或改变了编辑选页")
    try await Task.sleep(nanoseconds: 2_200_000_000)
    try require(navigationRestart.pendingFrame?.pageID == target.id && navigationRestart.inFlightFrame?.pageID == oldFrame.pageID,
        "已接受导航目标没有排队，或替换了有效旧帧")
}
