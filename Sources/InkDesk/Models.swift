import Foundation

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, todo, note, ai, progress, image, qr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: return "日期时间"
        case .todo: return "Todo 清单"
        case .note: return "文字便签"
        case .ai: return "AI 卡片"
        case .progress: return "任务进度"
        case .image: return "图片"
        case .qr: return "二维码"
        }
    }
    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .todo: return "checklist"
        case .note: return "note.text"
        case .ai: return "sparkles"
        case .progress: return "chart.bar.fill"
        case .image: return "photo"
        case .qr: return "qrcode"
        }
    }
}

struct InkWidget: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: WidgetKind
    var title: String
    var x: Double = 24
    var y: Double = 24
    var width: Double = 300
    var height: Double = 180
    var fontSize: Double = 22
    var padding: Double = 16
    var border: Bool = true
    var inverted: Bool = false
    var text: String = ""
    var projectFilter: String = ""
    var hideCompleted: Bool = false
    var prompt: String = "根据提供的待办和笔记，给出简短、明确的下一步工作建议。控制在 100 字以内。"
    var aiResult: String = "点击生成，让 AI 给出下一步建议。"
    var aiUpdatedAt: Date?
    var imageData: Data?
    var qrContent: String = "https://example.com"
    var showSeconds: Bool = false
    var dateStyle: String = "日期和时间"

    mutating func clamp() {
        width = min(800, max(80, width.isFinite ? width : 300))
        height = min(480, max(60, height.isFinite ? height : 180))
        x = min(800 - width, max(0, x.isFinite ? x : 0))
        y = min(480 - height, max(0, y.isFinite ? y : 0))
        fontSize = min(72, max(12, fontSize.isFinite ? fontSize : 22))
        padding = min(48, max(0, padding.isFinite ? padding : 16))
    }
}

struct InkPage: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var widgets: [InkWidget] = []
}

struct TodoItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var project: String = "工作"
    var priority: Int = 1
    var dueDate: Date?
    var completed: Bool = false
    var createdAt = Date()
    var completedAt: Date?
}

enum APIStyle: String, Codable, CaseIterable, Identifiable {
    case chatCompletions, responses
    var id: String { rawValue }
    var title: String { self == .chatCompletions ? "Chat Completions" : "Responses" }
}

struct AIConfiguration: Codable, Equatable {
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-v4-pro"
    var style: APIStyle = .responses
    var maxTokens = 1200
}

struct DeviceConfiguration: Codable, Equatable {
    var port: Int = 8765
    var token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var autoSync = true
    var pollSeconds = 30
    var threshold: Double = 0.6
    var dither = false
    var startOnLaunch = false
}

struct DeviceEvent: Codable, Equatable {
    var id: String
    var revision: Int
    var targetPageID: UUID? = nil
    var focusedTaskID: UUID? = nil
}

struct InkProject: Codable, Equatable {
    var formatVersion = 1
    var pages: [InkPage]
    var todos: [TodoItem]
    var ai = AIConfiguration()
    var device = DeviceConfiguration()
    var snapToGrid = true
    var gridSize: Double = 8
    var selectedPageID: UUID
    var deviceEventLedger: [DeviceEvent]? = []

    static func sample() -> InkProject {
        var clock = InkWidget(kind: .clock, title: "今天", x: 24, y: 24, width: 260, height: 140)
        clock.border = false
        var todo = InkWidget(kind: .todo, title: "今天要做", x: 308, y: 24, width: 468, height: 268)
        todo.fontSize = 23
        var note = InkWidget(kind: .note, title: "今日重点", x: 24, y: 188, width: 260, height: 268)
        note.text = "把一个想法，变成能放在桌上的工具。"
        let ai = InkWidget(kind: .ai, title: "下一步建议", x: 308, y: 316, width: 468, height: 140)
        let page = InkPage(name: "工作桌面", widgets: [clock, todo, note, ai])
        return InkProject(pages: [page], todos: [
            TodoItem(title: "设计我的墨水屏桌面"),
            TodoItem(title: "连接 E1001", priority: 2),
            TodoItem(title: "生成第一张 AI 卡片", project: "AI")
        ], selectedPageID: page.id)
    }

    mutating func validate() throws {
        guard formatVersion == 1, !pages.isEmpty, pages.count <= 24,
              todos.count <= 5000, pages.allSatisfy({ $0.widgets.count <= 100 }) else {
            throw InkError.message("项目格式不受支持，或内容超过允许的数量。")
        }
        guard Set(pages.map(\.id)).count == pages.count,
              Set(todos.map(\.id)).count == todos.count else {
            throw InkError.message("项目包含重复的页面或任务 ID。")
        }
        for i in pages.indices {
            guard Set(pages[i].widgets.map(\.id)).count == pages[i].widgets.count else {
                throw InkError.message("项目包含重复组件 ID。")
            }
            for j in pages[i].widgets.indices { pages[i].widgets[j].clamp() }
        }
        if !pages.contains(where: { $0.id == selectedPageID }) { selectedPageID = pages[0].id }
        device.port = min(65535, max(1024, device.port))
        device.pollSeconds = min(3600, max(5, device.pollSeconds))
        device.threshold = min(0.95, max(0.05, device.threshold))
        ai.maxTokens = min(16000, max(128, ai.maxTokens))
        gridSize = min(40, max(1, gridSize.isFinite ? gridSize : 8))
    }
}

enum InkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum AppSection: String, CaseIterable, Identifiable {
    case layout = "布局", todos = "待办", ai = "AI", device = "设备"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .layout: return "rectangle.3.group"; case .todos: return "checklist"; case .ai: return "sparkles"; case .device: return "display" }
    }
}

struct FramePayload: Codable {
    var pageID: UUID
    var revision: Int
    var pngData: Data
    var bitmapData: Data
    var hash: String
    var generatedAt: Date
    var taskIDs: [UUID]
}
