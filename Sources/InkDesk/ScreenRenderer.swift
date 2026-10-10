import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

struct ScreenContent: View {
    var page: InkPage
    var todos: [TodoItem]
    var date: Date = Date()
    var focusedTaskID: UUID? = nil
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(page.widgets) { widget in
                WidgetContent(widget: widget, todos: todos, date: date, focusedTaskID: focusedTaskID)
                    .offset(x: widget.x, y: widget.y)
            }
        }
        .frame(width: 800, height: 480)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

struct WidgetContent: View {
    var widget: InkWidget
    var todos: [TodoItem]
    var date: Date
    var focusedTaskID: UUID? = nil
    private var ink: Color { widget.inverted ? .white : .black }
    private var paper: Color { widget.inverted ? .black : .white }
    private var filtered: [TodoItem] {
        todos.filter { (widget.projectFilter.isEmpty || $0.project == widget.projectFilter) && (!widget.hideCompleted || !$0.completed) }
    }
    private var rowLimit: Int { max(1, Int((widget.height - widget.padding * 2 - 54) / (widget.fontSize * 1.2 + 14))) }
    private var visibleStart: Int {
        guard let id = focusedTaskID, let index = filtered.firstIndex(where: { $0.id == id }) else { return 0 }
        return (index / rowLimit) * rowLimit
    }
    private var visibleTodos: [TodoItem] { Array(filtered.dropFirst(visibleStart).prefix(rowLimit)) }
    private var titleFontSize: Double { max(13, widget.fontSize * 0.65) }
    private var progressFontSize: Double { max(28, widget.fontSize * 1.6) }
    private var titleLineHeight: Double { lineHeight(size: titleFontSize, weight: .semibold) }
    private var progressLineHeight: Double { lineHeight(size: progressFontSize, weight: .medium) }
    private var captionLineHeight: Double { lineHeight(size: 16) }
    private func lineHeight(size: Double, weight: NSFont.Weight = .regular) -> Double {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil(Double(font.ascender - font.descender + font.leading))
    }
    private var contentScale: Double {
        guard widget.kind == .progress else { return 1 }
        let titleHeight = widget.title.isEmpty ? 0 : titleLineHeight + 10
        let naturalHeight = widget.padding * 2 + titleHeight + progressLineHeight + 14 + captionLineHeight + 20
        let total = filtered.count
        let done = filtered.filter(\.completed).count
        let countWidth = ("\(done) / \(total)" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: progressFontSize, weight: .medium)
        ]).width
        let caption = total == 0 ? "添加任务后显示进度" : "已完成 \(Int(Double(done) / Double(total) * 100))%"
        let captionWidth = (caption as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
        let naturalWidth = widget.padding * 2 + Double(max(countWidth, captionWidth))
        return min(1, widget.height / naturalHeight, widget.width / naturalWidth)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10 * contentScale) {
            if !widget.title.isEmpty {
                Text(widget.title).font(.system(size: titleFontSize * contentScale, weight: .semibold)).lineLimit(1)
                    .minimumScaleFactor(widget.kind == .progress ? 0.1 : 1)
                    .frame(height: widget.kind == .progress ? titleLineHeight * contentScale : nil, alignment: .leading)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(widget.padding * contentScale)
        // Constrain the content before drawing and clipping so intrinsic text size
        // cannot move the widget's border away from the editor's selection frame.
        .frame(width: widget.width, height: widget.height, alignment: .topLeading)
        .foregroundColor(ink)
        .background(paper)
        .overlay(Rectangle().strokeBorder(ink, lineWidth: widget.border ? 1 : 0))
        .clipped()
        .environment(\.colorScheme, .light)
    }
    @ViewBuilder private var content: some View {
        switch widget.kind {
        case .clock:
            if widget.dateStyle != "只显示日期" {
                Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) + (widget.showSeconds ? ":" + date.formatted(.dateTime.second(.twoDigits)) : ""))
                    .font(.system(size: max(30, widget.fontSize * 2.1), weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            if widget.dateStyle != "只显示时间" {
                Text(date.formatted(.dateTime.year().month().day().weekday(.wide)).description)
                    .font(.system(size: widget.fontSize * 0.7)).lineLimit(2)
            }
        case .todo:
            if filtered.isEmpty { Text("这里还没有任务").font(.system(size: widget.fontSize)) }
            ForEach(visibleTodos) { item in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: item.completed ? "checkmark.square" : "square").font(.system(size: widget.fontSize * 0.8))
                    Text(item.title).strikethrough(item.completed).font(.system(size: widget.fontSize)).lineLimit(1)
                    Spacer(minLength: 0)
                    if item.id == focusedTaskID { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 12)) }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, item.id == focusedTaskID ? 4 : 0)
                .background(item.id == focusedTaskID ? ink : paper)
                .foregroundColor(item.id == focusedTaskID ? paper : ink)
            }
            if filtered.count > rowLimit { Text("\(visibleStart + 1)–\(min(filtered.count, visibleStart + rowLimit)) / \(filtered.count) 项").font(.system(size: 13)) }
        case .note:
            Text(widget.text.isEmpty ? "写下一句话。" : widget.text).font(.system(size: widget.fontSize)).frame(maxWidth: .infinity, alignment: .leading)
        case .ai:
            Text(widget.aiResult).font(.system(size: widget.fontSize)).frame(maxWidth: .infinity, alignment: .leading)
        case .progress:
            let total = filtered.count
            let done = filtered.filter(\.completed).count
            Text("\(done) / \(total)").font(.system(size: progressFontSize * contentScale, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.1)
                .frame(height: progressLineHeight * contentScale, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(ink).frame(width: geometry.size.width * (total == 0 ? 0 : Double(done) / Double(total)))
                    Rectangle().strokeBorder(ink, lineWidth: 1)
                }
            }.frame(height: 14 * contentScale)
            Text(total == 0 ? "添加任务后显示进度" : "已完成 \(Int(Double(done) / Double(total) * 100))%")
                .font(.system(size: 16 * contentScale)).lineLimit(1).minimumScaleFactor(0.1)
                .frame(height: captionLineHeight * contentScale, alignment: .leading)
        case .image:
            if let data = widget.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack { Image(systemName: "photo").font(.system(size: 36)); Text("在属性栏导入图片").font(.system(size: 16)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .qr:
            if let image = QRRenderer.image(for: widget.qrContent) {
                Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .padding(4).background(Color.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Text("请输入二维码内容").font(.system(size: 16)) }
        }
    }
}

enum QRRenderer {
    static let context = CIContext()
    static func image(for string: String) -> CGImage? {
        guard !string.isEmpty, string.utf8.count <= 2048 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let output = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return context.createCGImage(output, from: output.extent)
    }
}

@MainActor enum FrameRenderer {
    static func render(page: InkPage, todos: [TodoItem], configuration: DeviceConfiguration,
                       revision: Int, focusedTaskID: UUID? = nil, date: Date = Date()) throws -> FramePayload {
        let view = ScreenContent(page: page, todos: todos, date: date, focusedTaskID: focusedTaskID)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 800, height: 480)
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw InkError.message("无法生成墨水屏画面。") }
        let output = try monochrome(image, threshold: configuration.threshold, dither: configuration.dither)
        let hash = SHA256.hash(data: output.bitmap).map { String(format: "%02x", $0) }.joined()
        let ids = page.widgets.filter { $0.kind == .todo }.flatMap { widget in
            todos.filter { (widget.projectFilter.isEmpty || $0.project == widget.projectFilter) && (!widget.hideCompleted || !$0.completed) }.map(\.id)
        }
        var seen = Set<UUID>()
        return FramePayload(pageID: page.id, revision: revision, pngData: output.png, bitmapData: output.bitmap,
                            hash: hash, generatedAt: date, taskIDs: ids.filter { seen.insert($0).inserted })
    }

    static func monochrome(_ image: CGImage, threshold: Double, dither: Bool) throws -> (png: Data, bitmap: Data) {
        let width = 800, height = 480
        var gray = [UInt8](repeating: 255, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw InkError.message("无法转换黑白图片。") }
        var packed = [UInt8](repeating: 255, count: width * height / 8)
        var errors = [Double](repeating: 0, count: width + 2)
        var nextErrors = [Double](repeating: 0, count: width + 2)
        let cutoff = min(0.95, max(0.05, threshold)) * 255
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let value = min(255, max(0, Double(gray[index]) + (dither ? errors[x + 1] : 0)))
                let white = value >= cutoff
                gray[index] = white ? 255 : 0
                if !white { packed[index / 8] &= ~(1 << (7 - index % 8)) }
                if dither {
                    let error = value - (white ? 255 : 0)
                    errors[x + 2] += error * 7 / 16
                    nextErrors[x] += error * 3 / 16
                    nextErrors[x + 1] += error * 5 / 16
                    nextErrors[x + 2] += error / 16
                }
            }
            errors = nextErrors
            nextErrors = [Double](repeating: 0, count: width + 2)
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let output = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw InkError.message("无法编码黑白图片。")
        }
        let bitmap = NSBitmapImageRep(cgImage: output)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw InkError.message("PNG 编码失败。") }
        return (png, Data(packed))
    }
}
