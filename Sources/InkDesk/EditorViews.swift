import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum InkTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.48, green: 0.73, blue: 0.64, alpha: 1)
        }
        return NSColor(srgbRed: 0.16, green: 0.37, blue: 0.32, alpha: 1)
    })
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.14, green: 0.15, blue: 0.15, alpha: 1)
        }
        return NSColor(srgbRed: 0.92, green: 0.93, blue: 0.91, alpha: 1)
    })
    static let separator = Color.primary.opacity(0.08)
}

struct InkDeskRootView: View {
    @EnvironmentObject private var store: AppState

    var body: some View {
        HSplitView {
            InkSidebar()
                .frame(minWidth: 210, idealWidth: 228, maxWidth: 275)
            VStack(spacing: 0) {
                sectionHeader
                Divider()
                switch store.section {
                case .layout: EditorView()
                case .todos: TodoPanel()
                case .ai: AISettingsPanel()
                case .device: DevicePanel()
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(InkTheme.accent).frame(width: 5, height: 5)
                    Text(store.status).lineLimit(1)
                    Spacer()
                    Text("800 × 480 · 黑白墨水屏").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .frame(height: 30)
                .background(.bar)
            }
            .frame(minWidth: 780)
        }
        .tint(InkTheme.accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!store.undoAvailable).help("撤销 ⌘Z")
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!store.redoAvailable).help("重做 ⇧⌘Z")
                Divider()
                Menu {
                    Button("导入项目…", systemImage: "square.and.arrow.down", action: store.importProject)
                    Button("导出项目…", systemImage: "square.and.arrow.up", action: store.exportProject)
                    Divider()
                    Button("导出 PNG 图片…", systemImage: "photo", action: store.exportPNG)
                    Button("导出设备位图…", systemImage: "square.grid.3x3", action: store.exportBitmap)
                    Divider()
                    Button("打开数据文件夹", systemImage: "folder", action: store.openDataFolder)
                } label: { Image(systemName: "ellipsis.circle") }
                .help("项目与导出")
                Button("立即同步", systemImage: "arrow.triangle.2.circlepath", action: store.publish)
                    .help("将当前编辑页面加入待同步画面")
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sectionHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).font(.title2.weight(.semibold))
                Text(headerSubtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if store.section == .layout {
                Menu {
                    Button("新建页面", systemImage: "plus", action: store.addPage)
                    Button("复制当前页面", systemImage: "doc.on.doc", action: store.duplicatePage)
                    Button("删除当前页面", systemImage: "trash", role: .destructive) { store.deletePage(store.currentPage.id) }
                        .disabled(store.project.pages.count <= 1)
                } label: {
                    Label("页面", systemImage: "rectangle.on.rectangle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerTitle: String {
        switch store.section {
        case .layout: return store.currentPage.name
        case .todos: return "整理要做的事"
        case .ai: return "AI 工作助手"
        case .device: return "你的桌面墨水屏"
        }
    }

    private var headerSubtitle: String {
        switch store.section {
        case .layout: return "拖入组件，排出属于你的桌面。"
        case .todos: return "任务、项目与截止日期，都在一处。"
        case .ai: return "连接你自己的服务，把想法变成清晰的下一步。"
        case .device: return "预览画面，配对 E1001，并同步最新内容。"
        }
    }
}

private struct InkSidebar: View {
    @EnvironmentObject private var store: AppState
    @State private var renamingPageID: UUID?
    @State private var pageName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2).foregroundStyle(InkTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("InkDesk").font(.title3.weight(.bold))
                    Text("留一点专注在桌上").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 22)
            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { section in
                    Button { store.section = section } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol).frame(width: 20)
                            Text(section.rawValue).fontWeight(store.section == section ? .semibold : .regular)
                            Spacer()
                            if section == .todos {
                                Text("\(store.project.todos.filter { !$0.completed }.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(store.section == section ? InkTheme.accent : Color.primary)
                        .background(store.section == section ? InkTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 10)
            Divider().padding(.vertical, 18)
            HStack {
                Text("页面").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: store.addPage) {
                    Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).help("新建页面")
            }.padding(.horizontal, 20).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.project.pages) { page in
                        Button {
                            store.selectPage(page.id)
                            store.section = .layout
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "rectangle").font(.callout)
                                Text(page.name).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(page.widgets.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .foregroundStyle(store.currentPage.id == page.id ? InkTheme.accent : Color.primary)
                            .background(store.currentPage.id == page.id ? InkTheme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重命名…") { pageName = page.name; renamingPageID = page.id }
                            Button("复制页面") { store.selectPage(page.id); store.duplicatePage() }
                            Button("删除页面", role: .destructive) { store.deletePage(page.id) }
                                .disabled(store.project.pages.count <= 1)
                        }
                    }
                    if store.section == .layout {
                        Divider().padding(.vertical, 14)
                        Text("组件库").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.bottom, 5)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(WidgetKind.allCases) { kind in
                                VStack(spacing: 8) {
                                    Image(systemName: kind.symbol).font(.system(size: 20, weight: .regular))
                                        .foregroundStyle(InkTheme.accent)
                                    Text(kind.title).font(.caption).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).frame(height: 70)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.paletteDragKind == kind ? InkTheme.accent : InkTheme.separator, lineWidth: store.paletteDragKind == kind ? 2 : 1))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { store.addWidget(kind) }
                                .accessibilityElement(children: .ignore)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("添加\(kind.title)组件")
                                .accessibilityHint("点击添加，或拖入画布定位")
                                .accessibilityAction { store.addWidget(kind) }
                                .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                                    .onChanged { _ in store.paletteDragKind = kind }
                                    .onEnded { value in
                                        defer { store.paletteDragKind = nil }
                                        let rect = store.editorCanvasRect
                                        guard rect.width > 0, rect.height > 0, rect.contains(value.location) else { return }
                                        let x = (value.location.x - rect.minX) / rect.width * 800
                                        let y = (value.location.y - rect.minY) / rect.height * 480
                                        let grid = max(1, store.project.gridSize)
                                        let point = CGPoint(
                                            x: store.project.snapToGrid ? (x / grid).rounded() * grid : x,
                                            y: store.project.snapToGrid ? (y / grid).rounded() * grid : y
                                        )
                                        store.addWidget(kind, at: point)
                                    })
                                .help("点击添加，或拖入画布")
                            }
                        }
                        Text("点击添加 · 拖入定位").font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.top, 8)
                    }
                }.padding(.horizontal, 11).padding(.bottom, 15)
            }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Image(systemName: "externaldrive").foregroundStyle(.secondary)
                Text("项目自动保存在本机").font(.caption2).foregroundStyle(.secondary)
            }.padding(18)
        }
        .background(.regularMaterial)
        .alert("重命名页面", isPresented: Binding(get: { renamingPageID != nil }, set: { if !$0 { renamingPageID = nil } })) {
            TextField("页面名称", text: $pageName)
            Button("取消", role: .cancel) { renamingPageID = nil }
            Button("保存") {
                guard let id = renamingPageID, let index = store.project.pages.firstIndex(where: { $0.id == id }) else { return }
                let name = pageName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.checkpoint(); store.project.pages[index].name = name; store.save() }
                renamingPageID = nil
            }
        }
    }
}

struct EditorView: View {
    @EnvironmentObject private var store: AppState
    @State private var showGrid = true

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Label("画布", systemImage: "rectangle.dashed").font(.callout.weight(.medium))
                    Text("\(store.currentPage.widgets.count) 个组件").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("网格", isOn: $showGrid).toggleStyle(.checkbox).font(.caption)
                    Toggle("吸附", isOn: Binding(get: { store.project.snapToGrid }, set: { store.checkpoint(); store.project.snapToGrid = $0 }))
                        .toggleStyle(.checkbox).font(.caption)
                }.padding(.horizontal, 20).frame(height: 46).background(.bar)
                GeometryReader { geometry in
                    let scale = max(0.25, min((geometry.size.width - 64) / 800, (geometry.size.height - 88) / 480, 1.5))
                    VStack(spacing: 15) {
                        Spacer(minLength: 12)
                        CanvasSurface(showGrid: showGrid)
                            .frame(width: 800, height: 480)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: 800 * scale, height: 480 * scale, alignment: .topLeading)
                            .background(GeometryReader { proxy in
                                Color.clear
                                    .onAppear { store.editorCanvasRect = proxy.frame(in: .global) }
                                    .onChange(of: proxy.frame(in: .global)) { _, rect in store.editorCanvasRect = rect }
                            })
                            .overlay {
                                if let kind = store.paletteDragKind {
                                    Rectangle().stroke(InkTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                                        .overlay(alignment: .top) {
                                            Label("松开以添加\(kind.title)", systemImage: kind.symbol)
                                                .font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                                                .foregroundStyle(InkTheme.accent)
                                                .background(.regularMaterial, in: Capsule()).padding(12)
                                        }.allowsHitTesting(false)
                                }
                            }
                            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
                        HStack(spacing: 16) {
                            Text("\(Int(scale * 100))%")
                            Text("拖动组件移动 · 右下角调整大小")
                            Text("Delete 删除")
                        }.font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.background(InkTheme.canvas)
            }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            WidgetInspector().frame(minWidth: 270, idealWidth: 290, maxWidth: 340)
        }
    }
}

private struct CanvasSurface: View {
    @EnvironmentObject private var store: AppState
    var showGrid: Bool
    @State private var dragOrigin: InkWidget?
    @State private var resizeOrigin: InkWidget?
    @FocusState private var canvasFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.onTapGesture { store.selectedWidgetID = nil; canvasFocused = true }
            ScreenContent(page: store.currentPage, todos: store.project.todos)
                .allowsHitTesting(false)
            if showGrid {
                Canvas { context, size in
                    let step = max(4, store.project.gridSize)
                    var path = Path()
                    for x in stride(from: 0.0, through: 800.0, by: step) {
                        for y in stride(from: 0.0, through: 480.0, by: step) {
                            path.addEllipse(in: CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3))
                        }
                    }
                    context.fill(path, with: .color(.gray.opacity(0.22)))
                }.allowsHitTesting(false)
            }
            ForEach(store.currentPage.widgets) { widget in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .frame(width: widget.width, height: widget.height)
                    .overlay {
                        if store.selectedWidgetID == widget.id {
                            Rectangle().stroke(InkTheme.accent, lineWidth: 2)
                                .background(InkTheme.accent.opacity(0.03))
                        }
                    }
                    .position(x: widget.x + widget.width / 2, y: widget.y + widget.height / 2)
                    .onTapGesture { store.selectedWidgetID = widget.id; canvasFocused = true }
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("inkCanvas"))
                        .onChanged { value in
                            if dragOrigin == nil { store.checkpoint(); canvasFocused = true; store.selectedWidgetID = widget.id; dragOrigin = widget }
                            guard let original = dragOrigin, original.id == widget.id else { return }
                            store.updateWidget(widget.id) { item in
                                item.x = snapped(original.x + value.translation.width)
                                item.y = snapped(original.y + value.translation.height)
                            }
                        }
                        .onEnded { _ in dragOrigin = nil; store.save() })
                    .contextMenu {
                        Button("复制组件", systemImage: "doc.on.doc") { store.selectedWidgetID = widget.id; store.duplicateWidget() }
                        Button("上移一层", systemImage: "square.2.layers.3d.top.filled") { store.selectedWidgetID = widget.id; store.moveLayer(up: true) }
                        Button("下移一层", systemImage: "square.2.layers.3d.bottom.filled") { store.selectedWidgetID = widget.id; store.moveLayer(up: false) }
                        Divider()
                        Button("删除组件", systemImage: "trash", role: .destructive) { store.selectedWidgetID = widget.id; store.deleteSelectedWidget() }
                    }
            }
            if let widget = store.selectedWidget {
                RoundedRectangle(cornerRadius: 2).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(InkTheme.accent, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .position(x: widget.x + widget.width - 1, y: widget.y + widget.height - 1)
                    .help("拖动调整组件大小")
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("inkCanvas"))
                        .onChanged { value in
                            if resizeOrigin == nil { store.checkpoint(); resizeOrigin = widget }
                            guard let original = resizeOrigin else { return }
                            store.updateWidget(widget.id) { item in
                                item.width = min(800 - original.x, snapped(original.width + value.translation.width))
                                item.height = min(480 - original.y, snapped(original.height + value.translation.height))
                            }
                        }
                        .onEnded { _ in resizeOrigin = nil; store.save() })
            }
        }
        .frame(width: 800, height: 480)
        .coordinateSpace(name: "inkCanvas")
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onDeleteCommand { if canvasFocused { store.deleteSelectedWidget() } }
        .clipped()
        .onDrop(of: [UTType.text], isTargeted: nil) { providers, location in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
            // This modifier belongs to the original 800 × 480 surface, before its visual scale.
            let point = CGPoint(x: snapped(location.x), y: snapped(location.y))
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let value = object as? String, let kind = WidgetKind(rawValue: value) else { return }
                Task { @MainActor in
                    store.addWidget(kind, at: point)
                    canvasFocused = true
                }
            }
            return true
        }
    }

    private func snapped(_ value: Double) -> Double {
        let grid = max(1, store.project.gridSize)
        return store.project.snapToGrid ? (value / grid).rounded() * grid : value
    }
}

private struct WidgetInspector: View {
    @EnvironmentObject private var store: AppState
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("组件属性").font(.callout.weight(.semibold))
                Spacer()
                if store.selectedWidget != nil {
                    Button(action: store.duplicateWidget) {
                        Image(systemName: "doc.on.doc").frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("复制组件")
                    Button(action: store.deleteSelectedWidget) {
                        Image(systemName: "trash").frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("删除组件")
                }
            }.padding(.horizontal, 17).frame(height: 46).background(.bar)
            Divider()
            if let widget = store.selectedWidget {
                ScrollView {
                    VStack(alignment: .leading, spacing: 21) {
                        HStack(spacing: 10) {
                            Image(systemName: widget.kind.symbol).font(.title2).foregroundStyle(InkTheme.accent)
                                .frame(width: 40, height: 40).background(InkTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(widget.kind.title).font(.headline)
                                Text("在画布上拖动或输入尺寸").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        InspectorGroup("基础") {
                            TextField("标题", text: store.binding(for: \.title, fallback: ""))
                                .textFieldStyle(.roundedBorder).focused($focusedField, equals: "title")
                            HStack {
                                numericField("X", keyPath: \.x, fallback: 0, field: "x")
                                numericField("Y", keyPath: \.y, fallback: 0, field: "y")
                            }
                            HStack {
                                numericField("宽度", keyPath: \.width, fallback: 300, field: "width")
                                numericField("高度", keyPath: \.height, fallback: 180, field: "height")
                            }
                        }
                        InspectorGroup("样式") {
                            HStack { Text("字号"); Spacer(); Text("\(Int(widget.fontSize)) pt").foregroundStyle(.secondary).monospacedDigit() }
                            Slider(value: store.binding(for: \.fontSize, fallback: 22), in: 12...72, step: 1) { editing in if editing { store.checkpoint() } }
                            HStack { Text("内边距"); Spacer(); Text("\(Int(widget.padding)) px").foregroundStyle(.secondary).monospacedDigit() }
                            Slider(value: store.binding(for: \.padding, fallback: 16), in: 0...48, step: 1) { editing in if editing { store.checkpoint() } }
                            Toggle("显示边框", isOn: discrete(\.border, fallback: true))
                            Toggle("反色（黑底白字）", isOn: discrete(\.inverted, fallback: false))
                        }
                        widgetOptions(widget)
                        InspectorGroup("对齐与图层") {
                            HStack(spacing: 0) {
                                alignButton("left", "align.horizontal.left", "靠左")
                                alignButton("centerX", "align.horizontal.center", "水平居中")
                                alignButton("right", "align.horizontal.right", "靠右")
                                Divider().frame(height: 18)
                                alignButton("top", "align.vertical.top", "靠上")
                                alignButton("centerY", "align.vertical.center", "垂直居中")
                                alignButton("bottom", "align.vertical.bottom", "靠下")
                            }
                            HStack {
                                Button("下移一层", systemImage: "arrow.down") { store.moveLayer(up: false) }
                                Button("上移一层", systemImage: "arrow.up") { store.moveLayer(up: true) }
                            }.controlSize(.small)
                        }
                        Text("画面使用黑白显示，颜色与图片会在同步时转换为墨水屏位图。")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(17)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("选择一个组件").font(.headline)
                    Text("点击画布中的组件来编辑\n或从左侧组件库添加内容。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: focusedField) { _, field in if field != nil { store.checkpoint() } }
        .onChange(of: store.selectedWidgetID) { _, _ in focusedField = nil }
    }

    @ViewBuilder private func widgetOptions(_ widget: InkWidget) -> some View {
        switch widget.kind {
        case .clock:
            InspectorGroup("时间显示") {
                Picker("显示内容", selection: discrete(\.dateStyle, fallback: "日期和时间")) {
                    Text("日期和时间").tag("日期和时间")
                    Text("仅日期").tag("只显示日期")
                    Text("仅时间").tag("只显示时间")
                }
                Toggle("显示生成时的秒数", isOn: discrete(\.showSeconds, fallback: false))
                Text("时钟画面每 5 分钟更新，设备按检查间隔获取新画面。秒数显示的是生成画面时的快照。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .todo, .progress:
            InspectorGroup("任务范围") {
                TextField("项目（留空显示全部）", text: store.binding(for: \.projectFilter, fallback: ""))
                    .textFieldStyle(.roundedBorder).focused($focusedField, equals: "project")
                Toggle("隐藏已完成任务", isOn: discrete(\.hideCompleted, fallback: false))
                Button("管理待办", systemImage: "checklist") { store.section = .todos }
            }
        case .note:
            InspectorGroup("便签内容") {
                TextEditor(text: store.binding(for: \.text, fallback: ""))
                    .font(.body).frame(minHeight: 130).focused($focusedField, equals: "text")
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(InkTheme.separator))
            }
        case .ai:
            InspectorGroup("AI 指令") {
                TextEditor(text: store.binding(for: \.prompt, fallback: ""))
                    .font(.callout).frame(minHeight: 100).focused($focusedField, equals: "prompt")
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button {
                        Task { await store.generateAI(for: widget.id) }
                    } label: {
                        Label(store.generatingWidgetID == widget.id ? "生成中…" : "生成内容", systemImage: "sparkles")
                    }.buttonStyle(.borderedProminent).disabled(store.isGenerating)
                    Button("设置") { store.section = .ai }
                }
                Text("生成内容可继续编辑").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: store.binding(for: \.aiResult, fallback: ""))
                    .font(.callout).frame(minHeight: 90).focused($focusedField, equals: "aiResult")
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                if let date = widget.aiUpdatedAt {
                    Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .image:
            InspectorGroup("图片") {
                if let data = widget.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                        .frame(maxWidth: .infinity).background(Color.white, in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Label("还没有图片", systemImage: "photo").foregroundStyle(.secondary)
                }
                Button("选择图片…", systemImage: "folder") { store.importImage(for: widget.id) }
                if widget.imageData != nil {
                    Button("移除图片", role: .destructive) { store.checkpoint(); store.updateWidget(widget.id) { $0.imageData = nil } }
                }
                Text("支持 PNG、JPEG 等图片。可在设备页调整黑白转换效果。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .qr:
            InspectorGroup("二维码内容") {
                TextField("网址或文字", text: store.binding(for: \.qrContent, fallback: ""), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...6).focused($focusedField, equals: "qr")
                Text("尽量保持正方形，并为二维码留出白色边缘。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numericField(_ label: String, keyPath: WritableKeyPath<InkWidget, Double>, fallback: Double, field: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: store.binding(for: keyPath, fallback: fallback), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).focused($focusedField, equals: field)
        }
    }

    private func discrete<T>(_ keyPath: WritableKeyPath<InkWidget, T>, fallback: T) -> Binding<T> {
        let binding = store.binding(for: keyPath, fallback: fallback)
        return Binding(get: { binding.wrappedValue }, set: { store.checkpoint(); binding.wrappedValue = $0 })
    }

    private func alignButton(_ edge: String, _ symbol: String, _ label: String) -> some View {
        Button { store.alignSelected(edge) } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity)
                .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label)
    }
}

struct InspectorGroup<Content: View>: View {
    var title: String
    var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }.font(.callout)
    }
}
