import SwiftUI
import AppKit

struct TodoPanel: View {
    @EnvironmentObject private var store: AppState
    @State private var search = ""
    @State private var projectFilter = ""
    @State private var completionFilter = 0
    @State private var selectedTodoID: UUID?
    @State private var newTitle = ""
    @State private var showingNewTask = false

    private var projects: [String] { Array(Set(store.project.todos.map(\.project))).sorted() }
    private var visibleTodos: [TodoItem] {
        store.project.todos.filter { item in
            (projectFilter.isEmpty || item.project == projectFilter) &&
            (completionFilter == 0 || (completionFilter == 1 ? !item.completed : item.completed)) &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.project.localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            if a.priority != b.priority { return a.priority > b.priority }
            if a.dueDate != b.dueDate { return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture) }
            return a.createdAt < b.createdAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TaskStatistic(value: store.project.todos.filter { !$0.completed }.count, label: "待完成", symbol: "circle.dashed")
                TaskStatistic(value: store.project.todos.filter { !$0.completed && ($0.dueDate.map { Calendar.current.isDateInToday($0) } ?? false) }.count, label: "今天截止", symbol: "calendar")
                TaskStatistic(value: store.project.todos.filter(\.completed).count, label: "已完成", symbol: "checkmark.circle")
                Spacer(minLength: 0)
                Button("AI 拆解目标", systemImage: "sparkles") { store.section = .ai }
                Button("新建待办", systemImage: "plus") { showingNewTask = true }.buttonStyle(.borderedProminent)
            }.padding(22)
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索任务或项目", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        Divider().frame(height: 18)
                        Picker("项目", selection: $projectFilter) {
                            Text("所有项目").tag("")
                            ForEach(projects, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(maxWidth: 130)
                    }.padding(.horizontal, 15).frame(height: 42)
                    Divider()
                    HStack {
                        Picker("状态", selection: $completionFilter) {
                            Text("全部").tag(0)
                            Text("待完成").tag(1)
                            Text("已完成").tag(2)
                        }.pickerStyle(.segmented).frame(maxWidth: 265)
                        Spacer()
                        Text("\(visibleTodos.count) 项").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                    if visibleTodos.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "这里还没有任务" : "没有匹配的任务", systemImage: search.isEmpty ? "checklist" : "magnifyingglass", description: Text(search.isEmpty ? "写下第一件要做的事，给今天一个明确的开始。" : "试试其他关键词或筛选条件。"))
                            .frame(maxHeight: .infinity)
                    } else {
                        List(selection: $selectedTodoID) {
                            ForEach(visibleTodos) { item in
                                TodoListRow(item: item).tag(item.id)
                                    .contextMenu {
                                        Button(item.completed ? "标记为待完成" : "完成任务", systemImage: "checkmark.circle") { store.toggleTodo(item.id) }
                                        Button("编辑任务") { selectedTodoID = item.id }
                                        Divider()
                                        Button("删除任务", systemImage: "trash", role: .destructive) { store.deleteTodo(item.id) }
                                    }
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden)
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle").foregroundStyle(InkTheme.accent)
                        TextField("快速添加待办，按回车保存", text: $newTitle)
                            .textFieldStyle(.plain).onSubmit(addQuickTask)
                        Button("添加", action: addQuickTask).disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(15)
                }.frame(minWidth: 400)
                TodoInspector(todoID: selectedTodoID)
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
            }
            HStack {
                Text("调整任务后，画布中的清单和进度组件会自动更新。")
                Spacer()
                Button(action: store.clearCompletedTodos) {
                    Text("清除已完成").padding(.horizontal, 4).padding(.vertical, 4).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(!store.project.todos.contains(where: \.completed))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .sheet(isPresented: $showingNewTask) { NewTodoSheet(defaultProject: projectFilter.isEmpty ? "工作" : projectFilter) }
        .onChange(of: store.project.todos.map(\.id)) { _, ids in if let id = selectedTodoID, !ids.contains(id) { selectedTodoID = nil } }
    }

    private func addQuickTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.addTodo(title: title, project: projectFilter.isEmpty ? "工作" : projectFilter)
        newTitle = ""
    }
}

private struct TaskStatistic: View {
    var value: Int
    var label: String
    var symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(InkTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.title2.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 15).padding(.vertical, 10)
            .frame(minWidth: 110, alignment: .leading)
            .background(InkTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct TodoListRow: View {
    @EnvironmentObject private var store: AppState
    var item: TodoItem

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Button { store.toggleTodo(item.id) } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19)).foregroundStyle(item.completed ? InkTheme.accent : Color.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help(item.completed ? "恢复任务" : "完成任务")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).strikethrough(item.completed).foregroundStyle(item.completed ? Color.secondary : Color.primary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(item.project).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(InkTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .foregroundStyle(!item.completed && due < Calendar.current.startOfDay(for: Date()) ? Color.red : Color.secondary)
                    }
                    if item.priority > 0 {
                        Label(priorityName(item.priority), systemImage: "flag.fill")
                            .foregroundStyle(item.priority == 2 ? Color.orange : Color.secondary)
                    }
                }.font(.caption2)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private func priorityName(_ priority: Int) -> String {
    switch priority { case 2: return "高优先级"; case 1: return "普通"; default: return "低优先级" }
}

private struct TodoInspector: View {
    @EnvironmentObject private var store: AppState
    var todoID: UUID?
    @FocusState private var focusedField: String?
    private var item: TodoItem? { store.project.todos.first { $0.id == todoID } }

    var body: some View {
        Group {
            if let item = item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text("任务详情").font(.headline)
                            Spacer()
                            Button { store.deleteTodo(item.id) } label: {
                                Image(systemName: "trash").frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("删除任务")
                        }
                        InspectorGroup("任务名称") {
                            TextField("任务名称", text: todoBinding(\.title, fallback: ""), axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(2...6).focused($focusedField, equals: "title")
                        }
                        InspectorGroup("项目") {
                            TextField("项目", text: todoBinding(\.project, fallback: "工作"))
                                .textFieldStyle(.roundedBorder).focused($focusedField, equals: "project")
                            let projects = Array(Set(store.project.todos.map(\.project))).sorted()
                            if !projects.isEmpty {
                                Menu("选择已有项目") {
                                    ForEach(projects, id: \.self) { project in
                                        Button(project) { store.checkpoint(); store.updateTodo(item.id) { $0.project = project } }
                                    }
                                }.controlSize(.small)
                            }
                        }
                        InspectorGroup("优先级") {
                            Picker("优先级", selection: todoBinding(\.priority, fallback: 1, checkpoint: true)) {
                                Text("低").tag(0); Text("普通").tag(1); Text("高").tag(2)
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        InspectorGroup("截止日期") {
                            Toggle("设置截止日期", isOn: Binding(get: { self.item?.dueDate != nil }, set: { enabled in
                                store.checkpoint(); store.updateTodo(item.id) { $0.dueDate = enabled ? Date() : nil }
                            }))
                            if item.dueDate != nil {
                                DatePicker("截止", selection: Binding(get: { self.item?.dueDate ?? Date() }, set: { date in
                                    store.checkpoint(); store.updateTodo(item.id) { $0.dueDate = date }
                                }), displayedComponents: .date).labelsHidden()
                            }
                        }
                        Button {
                            store.toggleTodo(item.id)
                        } label: {
                            Label(item.completed ? "恢复为待完成" : "标记为已完成", systemImage: item.completed ? "arrow.uturn.backward" : "checkmark")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("创建于 \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            if let completedAt = item.completedAt {
                                Text("完成于 \(completedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }.padding(20)
                }
            } else {
                VStack(spacing: 11) {
                    Image(systemName: "checklist").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("选择一项任务").font(.headline)
                    Text("编辑项目、优先级和截止日期。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .onChange(of: focusedField) { _, field in if field != nil { store.checkpoint() } }
        .onChange(of: todoID) { _, _ in focusedField = nil }
    }

    private func todoBinding<T>(_ keyPath: WritableKeyPath<TodoItem, T>, fallback: T, checkpoint: Bool = false) -> Binding<T> {
        Binding(get: { item?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let id = todoID else { return }
            if checkpoint { store.checkpoint() }
            store.updateTodo(id) { $0[keyPath: keyPath] = value }
        })
    }
}

private struct NewTodoSheet: View {
    @EnvironmentObject private var store: AppState
    @Environment(\.dismiss) private var dismiss
    var defaultProject: String
    @State private var title = ""
    @State private var project = "工作"
    @State private var priority = 1
    @State private var hasDueDate = false
    @State private var dueDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建待办").font(.title2.weight(.semibold))
            TextField("要做什么？", text: $title, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            TextField("项目", text: $project).textFieldStyle(.roundedBorder)
            Picker("优先级", selection: $priority) { Text("低").tag(0); Text("普通").tag(1); Text("高").tag(2) }.pickerStyle(.segmented)
            Toggle("设置截止日期", isOn: $hasDueDate)
            if hasDueDate { DatePicker("截止日期", selection: $dueDate, displayedComponents: .date) }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") {
                    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cleanProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.addTodo(title: cleanTitle, project: cleanProject.isEmpty ? "工作" : cleanProject, priority: priority, dueDate: hasDueDate ? dueDate : nil)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 430).onAppear { project = defaultProject }
    }
}

struct AISettingsPanel: View {
    @EnvironmentObject private var store: AppState
    @State private var draftAPIKey = ""
    @State private var goal = ""
    @FocusState private var focusedField: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 22) {
                    connectionCard.frame(maxWidth: .infinity, alignment: .topLeading)
                    taskBreakdownCard.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                aiWidgetsCard
            }.padding(24)
        }
        .background(InkTheme.canvas.opacity(0.5))
        .onAppear { draftAPIKey = store.apiKey }
        .onChange(of: focusedField) { _, field in if field != nil && field != "key" && field != "goal" && field != "draft" { store.checkpoint() } }
    }

    private var connectionCard: some View {
        PanelCard(title: "连接 AI 服务", symbol: "network") {
            Text("使用兼容 OpenAI API 的服务。密钥保存在 macOS 钥匙串中。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            InspectorGroup("服务地址") {
                TextField("https://你的服务/v1", text: $store.project.ai.baseURL)
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: "url")
            }
            InspectorGroup("API 方式") {
                Picker("API 方式", selection: Binding(get: { store.project.ai.style }, set: { store.checkpoint(); store.project.ai.style = $0 })) {
                    ForEach(APIStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            InspectorGroup("模型") {
                HStack(spacing: 7) {
                    TextField("模型 ID", text: $store.project.ai.model)
                        .textFieldStyle(.roundedBorder).focused($focusedField, equals: "model")
                    if !store.availableModels.isEmpty {
                        Menu {
                            ForEach(store.availableModels, id: \.self) { model in
                                Button(model) { store.checkpoint(); store.project.ai.model = model }
                            }
                        } label: {
                            Image(systemName: "list.bullet").frame(width: 28, height: 28).contentShape(Rectangle())
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
            InspectorGroup("API 密钥") {
                SecureField("输入服务提供的 API Key", text: $draftAPIKey)
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: "key")
                HStack {
                    Button("保存密钥", systemImage: "key") { store.apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines); store.saveAPIKey() }
                        .disabled(draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("移除") { store.resetAPIKey(); draftAPIKey = "" }.disabled(store.apiKey.isEmpty)
                    Spacer()
                    Text(store.apiKey.isEmpty ? "未设置" : "已设置").font(.caption2).foregroundStyle(.secondary)
                }.controlSize(.small)
            }
            HStack {
                Text("输出 Token 上限").font(.callout)
                Spacer()
                TextField("上限", value: $store.project.ai.maxTokens, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 75).focused($focusedField, equals: "tokens")
                    .onSubmit { store.project.ai.maxTokens = min(16000, max(128, store.project.ai.maxTokens)) }
            }
            Divider()
            HStack {
                Button {
                    Task { await store.testAIConnection() }
                } label: { Label("测试连接与获取模型", systemImage: "bolt.horizontal") }
                    .disabled(store.isGenerating || store.apiKey.isEmpty)
                Spacer()
            }
            if !store.aiConnectionStatus.isEmpty {
                Text(store.aiConnectionStatus).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("生成时会将相关待办与当前页面内容发送给所配置的 AI 服务。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var taskBreakdownCard: some View {
        PanelCard(title: "把目标拆成可执行任务", symbol: "sparkles") {
            Text("写下目标，先预览和调整结果，再加入待办。")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $goal).font(.callout).frame(height: 110)
                .focused($focusedField, equals: "goal").scrollContentBackground(.hidden).padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(InkTheme.separator))
                .overlay(alignment: .topLeading) {
                    if goal.isEmpty { Text("例如：两周内做出能在桌上使用的墨水屏工作助手。").font(.callout).foregroundStyle(.tertiary).padding(13).allowsHitTesting(false) }
                }
            HStack {
                Button {
                    Task { await store.generateTaskBreakdown(goal) }
                } label: { Label(store.isGenerating && store.generatingWidgetID == nil ? "正在拆解…" : "拆解目标", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).disabled(store.isGenerating || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.apiKey.isEmpty)
                if store.isGenerating { ProgressView().controlSize(.small); Button("取消", action: store.cancelAI) }
                Spacer()
            }
            if !store.aiDraft.isEmpty {
                Divider()
                HStack {
                    Text("待办草稿").font(.callout.weight(.semibold))
                    Spacer()
                    Button { store.aiDraft = "" } label: {
                        Text("清空").padding(.horizontal, 4).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                TextEditor(text: $store.aiDraft).font(.callout).frame(height: 160)
                    .focused($focusedField, equals: "draft").scrollContentBackground(.hidden).padding(8)
                    .background(InkTheme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                Button("确认并添加到待办", systemImage: "checklist", action: store.importAIDraftAsTodos)
                    .disabled(store.isGenerating).buttonStyle(.borderedProminent)
                Text("只有点击确认后，草稿才会变成任务。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var aiWidgetsCard: some View {
        PanelCard(title: "页面中的 AI 卡片", symbol: "rectangle.on.rectangle") {
            let cards = store.project.pages.flatMap { page in page.widgets.filter { $0.kind == .ai }.map { (page, $0) } }
            if cards.isEmpty {
                HStack {
                    Text("添加 AI 卡片，让建议出现在墨水屏上。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加 AI 卡片", systemImage: "plus") { store.addWidget(.ai); store.section = .layout }
                }
            } else {
                ForEach(cards, id: \.1.id) { pair in
                    let page = pair.0
                    let widget = pair.1
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(widget.title).font(.callout.weight(.semibold))
                                Text(page.name).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("编辑") { store.selectPage(page.id); store.selectedWidgetID = widget.id; store.section = .layout }
                            Button {
                                store.selectPage(page.id)
                                Task { await store.generateAI(for: widget.id) }
                            } label: { Label(store.generatingWidgetID == widget.id ? "生成中…" : "生成", systemImage: "sparkles") }
                                .disabled(store.isGenerating || store.apiKey.isEmpty)
                        }
                        Text(widget.aiResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if widget.id != cards.last?.1.id { Divider().padding(.top, 4) }
                    }.padding(.vertical, 3)
                }
            }
        }
    }
}

struct DevicePanel: View {
    @EnvironmentObject private var store: AppState
    @State private var showToken = false
    @State private var selectedPreview: SyncPreview = .pending
    @FocusState private var focusedField: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                queueStatusCard
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                        previewCard
                        conversionCard
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 22) {
                        connectionCard
                        syncCard
                    }.frame(width: 310)
                }
            }.padding(24)
        }
        .background(InkTheme.canvas.opacity(0.5))
        .onChange(of: focusedField) { _, field in if field != nil { store.checkpoint() } }
        .onAppear {
            if store.pendingFrame == nil && !store.isSyncEditPending {
                if store.inFlightFrame != nil { selectedPreview = .inFlight }
                else if store.displayedFrame != nil { selectedPreview = .displayed }
            }
        }
    }

    private var queueStatusCard: some View {
        PanelCard(title: "同步状态", symbol: "arrow.triangle.2.circlepath") {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: syncSymbol).font(.system(size: 25, weight: .medium))
                    .foregroundStyle(syncColor).frame(width: 48, height: 48)
                    .background(syncColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.syncPhase).font(.title3.weight(.semibold))
                    Text(store.syncStatus).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 14)
                Button(action: store.publish) {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        .padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(.borderedProminent)
                    .help("将当前编辑页面立即加入待同步画面")
            }
            Divider()
            HStack(spacing: 20) {
                SyncStatusCount(title: "待同步", value: store.isSyncEditPending ? "等待编辑完成" : store.pendingFrame == nil ? "0 张" : "1 张", symbol: "tray")
                SyncStatusCount(title: "当前同步", value: store.inFlightFrame == nil ? "0 张" : canRetrySync ? "1 张 · 待重试" : "1 张", symbol: "arrow.up.doc")
                SyncStatusCount(title: "设备显示", value: store.displayedFrame == nil ? "未确认" : "已确认", symbol: "display")
                Spacer(minLength: 0)
                Button(action: store.cancelPendingSync) {
                    Label("取消待同步", systemImage: "xmark.circle").contentShape(Rectangle())
                }.disabled(store.pendingFrame == nil && !store.isSyncEditPending)
                    .help("只取消待同步画面；页面编辑和正在同步的画面会保留")
                if canRetrySync {
                    Button(action: store.retrySync) {
                        Label("重试同步", systemImage: "arrow.clockwise").contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent)
                }
            }.controlSize(.small)
            if store.inFlightFrame != nil && (store.pendingFrame != nil || store.isSyncEditPending) {
                Text("本次画面完成同步后，设备才接收最新编辑。继续修改只会更新待同步的那一张。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.isSyncEditPending {
                Text("等待编辑完成：停止修改约 2 秒后准备最新画面。也可点击“立即同步”。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewCard: some View {
        PanelCard(title: "画面预览", symbol: "rectangle.on.rectangle") {
            Picker("预览画面", selection: $selectedPreview) {
                ForEach(SyncPreview.allCases) { preview in Text(preview.rawValue).tag(preview) }
            }.pickerStyle(.segmented).labelsHidden()
            if selectedPreview == .pending && store.isSyncEditPending {
                Label("等待编辑完成", systemImage: "pencil.line")
                    .font(.callout.weight(.medium)).foregroundStyle(InkTheme.accent)
            }
            if let frame = previewFrame {
                FramePNGThumbnail(pngData: frame.pngData)
                HStack {
                    Text(previewPageName(frame)).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text("第 \(frame.revision) 张画面").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    if selectedPreview == .displayed, let date = store.lastDisplayConfirmedAt {
                        Label("设备确认于 \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle")
                    } else {
                        Text("准备于 \(frame.generatedAt.formatted(date: .omitted, time: .shortened))")
                    }
                    Spacer()
                }.font(.caption2).foregroundStyle(.secondary)
            } else {
                SyncPreviewPlaceholder(title: emptyPreviewTitle, description: emptyPreviewDescription, symbol: emptyPreviewSymbol)
            }
            HStack {
                Text(previewExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Menu("导出当前编辑页") {
                    Button("PNG 图片…", action: store.exportPNG)
                    Button("设备位图…", action: store.exportBitmap)
                }.fixedSize().controlSize(.small)
            }
            if store.displayedFrame == nil {
                Text("确认显示需要设备使用支持显示确认的新固件。收到屏幕刷新完成的确认之前，InkDesk 不会将画面标为已显示。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewFrame: FramePayload? {
        switch selectedPreview {
        case .pending: return store.pendingFrame
        case .inFlight: return store.inFlightFrame
        case .displayed: return store.displayedFrame
        }
    }

    private var emptyPreviewTitle: String {
        switch selectedPreview {
        case .pending: return store.isSyncEditPending ? "等待编辑完成" : "暂无待同步画面"
        case .inFlight: return "当前没有正在同步的画面"
        case .displayed: return "设备显示未确认"
        }
    }

    private var emptyPreviewDescription: String {
        switch selectedPreview {
        case .pending: return store.isSyncEditPending ? "最新编辑完成后，黑白画面会出现在这里。" : "继续编辑或点击“立即同步”，准备新的设备画面。"
        case .inFlight: return "设备开始接收新画面后，可在这里查看。"
        case .displayed: return "收到设备刷新完成的确认后，才会显示已确认画面。"
        }
    }

    private var emptyPreviewSymbol: String {
        switch selectedPreview {
        case .pending: return store.isSyncEditPending ? "pencil.line" : "tray"
        case .inFlight: return "arrow.up.doc"
        case .displayed: return "display"
        }
    }

    private var previewExplanation: String {
        switch selectedPreview {
        case .pending: return store.isSyncEditPending && store.pendingFrame != nil ? "这是已准备的待同步画面，最新编辑完成后会替换它。" : "待同步只保留最新的一张画面。"
        case .inFlight: return canRetrySync ? "本次同步尚未完成，可点击“重试同步”。" : "本次同步的画面会保持不变，继续编辑会准备下一张。"
        case .displayed: return "这里显示设备最后一次确认刷新完成的画面。"
        }
    }

    private var canRetrySync: Bool { store.syncPhase == "同步失败" || store.syncPhase == "等待重试" }
    private var syncColor: Color { canRetrySync ? .orange : store.syncPhase == "未同步" ? .secondary : InkTheme.accent }
    private var syncSymbol: String {
        switch store.syncPhase {
        case "等待编辑完成": return "pencil.line"
        case "等待设备": return "clock.arrow.circlepath"
        case "传输中": return "arrow.up.doc"
        case "设备刷新中": return "display"
        case "已确认显示": return "checkmark.circle"
        case "同步失败", "等待重试": return "exclamationmark.triangle"
        default: return "display"
        }
    }

    private func previewPageName(_ frame: FramePayload) -> String {
        store.project.pages.first(where: { $0.id == frame.pageID })?.name ?? "原页面画面"
    }

    private var conversionCard: some View {
        PanelCard(title: "黑白转换", symbol: "circle.lefthalf.filled") {
            HStack {
                Text("黑白阈值").font(.callout)
                Spacer()
                Text("\(Int(store.project.device.threshold * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $store.project.device.threshold, in: 0.05...0.95, step: 0.01) { editing in
                if editing { store.checkpoint() }
            }
            HStack { Text("保留更多白色"); Spacer(); Text("保留更多黑色") }.font(.caption2).foregroundStyle(.secondary)
            Toggle("图片使用抖动处理", isOn: Binding(get: { store.project.device.dither }, set: { store.checkpoint(); store.project.device.dither = $0 }))
            Text("抖动用细小黑白点保留图片层次；文字界面通常直接使用阈值即可。修改后点击同步，或由已启用的自动同步更新。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionCard: some View {
        PanelCard(title: "局域网连接", symbol: "wifi") {
            DeviceServerControls(server: store.server)
            Divider()
            InspectorGroup("Mac 地址") {
                if store.localAddresses.isEmpty {
                    Text("未找到可用的局域网地址").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(store.localAddresses, id: \.self) { address in
                        Text(address).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Text("端口").font(.callout)
                Spacer()
                TextField("端口", value: $store.project.device.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 85).focused($focusedField, equals: "port")
                    .disabled(store.server.isRunning)
                    .onSubmit { store.project.device.port = min(65535, max(1024, store.project.device.port)) }
            }
            InspectorGroup("设备配对密钥") {
                HStack {
                    Group {
                        if showToken { Text(store.project.device.token).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
                        else { Text("••••••••••••••••••••••••").font(.caption.monospaced()) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye").frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(showToken ? "隐藏密钥" : "显示密钥")
                }.padding(9).background(InkTheme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button("复制连接信息", systemImage: "doc.on.doc", action: store.copyConnectionInfo)
                    Spacer()
                    Button("重置密钥", action: store.rotateDeviceToken).controlSize(.small)
                }.controlSize(.small)
            }
            if let seen = store.deviceLastSeen {
                Label("最近设备请求：\(seen.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(InkTheme.accent)
            } else {
                Label("尚未收到设备请求", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
            Text("将 Mac 地址、端口和配对密钥填入 E1001 固件配置。Mac 与设备需连接同一局域网，并允许 InkDesk 的传入连接。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var syncCard: some View {
        PanelCard(title: "同步设置", symbol: "arrow.triangle.2.circlepath") {
            Toggle("内容修改后自动同步", isOn: deviceToggle(\.autoSync))
            Text("停止编辑约 2 秒后准备最新画面；连续修改会合并到同一张待同步画面。开启后，时钟每 5 分钟更新。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("打开 App 时启动服务", isOn: deviceToggle(\.startOnLaunch))
            HStack {
                Text("设备检查间隔").font(.callout)
                Spacer()
                Stepper("\(store.project.device.pollSeconds) 秒", value: Binding(get: { store.project.device.pollSeconds }, set: { store.checkpoint(); store.project.device.pollSeconds = $0 }), in: 5...3600, step: 5)
                    .fixedSize().font(.callout.monospacedDigit())
            }
            Text("Mac 需要保持运行并与设备在同一网络。设备会按设定间隔检查新画面；物理刷新由墨水屏完成。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceToggle(_ keyPath: WritableKeyPath<DeviceConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { store.project.device[keyPath: keyPath] }, set: { store.checkpoint(); store.project.device[keyPath: keyPath] = $0 })
    }
}

private enum SyncPreview: String, CaseIterable, Identifiable {
    case pending = "待同步"
    case inFlight = "本次同步"
    case displayed = "已确认"
    var id: String { rawValue }
}

private struct SyncStatusCount: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(InkTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption.weight(.medium)).monospacedDigit()
            }
        }
    }
}

private struct DeviceServerControls: View {
    @EnvironmentObject private var store: AppState
    @ObservedObject var server: DeviceServer

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(server.isRunning ? InkTheme.accent : Color.secondary.opacity(0.45)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.isRunning ? "同步服务已启动" : "同步服务未启动").font(.callout.weight(.semibold))
                Text(server.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(server.isRunning ? "停止" : "启动") {
                if server.isRunning { store.stopServer() } else { store.startServer() }
            }.controlSize(.small)
        }
    }
}

struct FramePNGThumbnail: View {
    var pngData: Data

    var body: some View {
        Group {
            if let image = FramePNGImageCache.image(for: pngData) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                SyncPreviewPlaceholder(title: "无法显示预览", description: "请重新准备画面。", symbol: "photo")
            }
        }
        .frame(maxWidth: .infinity).aspectRatio(800.0 / 480.0, contentMode: .fit)
        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(InkTheme.separator))
    }
}

private enum FramePNGImageCache {
    private static let imageCost = 800 * 480 * 4
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 6 * imageCost
        return cache
    }()

    static func image(for pngData: Data) -> NSImage? {
        // NSData equality compares the immutable PNG content, including across frame copies.
        let key = pngData as NSData
        if let image = cache.object(forKey: key) { return image }
        guard let image = NSImage(data: pngData) else { return nil }
        cache.setObject(image, forKey: key, cost: imageCost)
        return image
    }
}

private struct SyncPreviewPlaceholder: View {
    var title: String
    var description: String
    var symbol: String

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(title).font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(800.0 / 480.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(InkTheme.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(InkTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

struct PanelCard<Content: View>: View {
    var title: String
    var symbol: String
    var content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(InkTheme.accent)
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(InkTheme.separator))
    }
}
