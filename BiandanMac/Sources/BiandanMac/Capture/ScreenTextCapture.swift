import AppKit
import OSLog
import ScreenCaptureKit
import Vision

// MARK: - 框选屏幕区域、截图、OCR（全部在本机处理，图片只在内存里，不存盘、不上传）

enum TextRecognizer {
    /// 分条识别时每条的高度（像素）和相邻两条的重叠。
    static let stripHeight = 600
    static let stripOverlap = 80

    /// 识别图片里的文字（简体、繁体中文和英文），按阅读顺序返回每一行。
    /// 整屏大图、深色背景、字又少时，精确识别偶尔整张返回空（同一张图每次都空）：
    /// 这时切成几条横条分别识别再拼回去；还是空就用快速识别兜底。
    static func recognize(_ image: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            var fragments = try fragments(in: image, level: .accurate)
            if fragments.isEmpty && image.height > stripHeight {
                fragments = try stripFragments(image)
                if !fragments.isEmpty { CaptureDebug.logger.notice("整张识别为空，分条识别到 \(fragments.count, privacy: .public) 段") }
            }
            if fragments.isEmpty {
                fragments = try self.fragments(in: image, level: .fast)
                if !fragments.isEmpty { CaptureDebug.logger.notice("精确识别为空，快速识别到 \(fragments.count, privacy: .public) 段") }
            }
            return OCRLayout.lines(fragments)
        }.value
    }

    static func fragments(in image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [OCRFragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = level == .accurate
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation -> OCRFragment? in
            guard let best = observation.topCandidates(1).first,
                  !best.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return OCRFragment(text: best.string, box: observation.boundingBox)
        }
    }

    /// 横条：top 是这条在原图里的起始行（左上角原点，像素），height 是条高；owned 是这条负责的行范围（去掉重叠）。
    struct Strip: Equatable {
        let top: Int
        let height: Int
        let owned: Range<Int>
    }

    static func strips(height: Int, stripHeight: Int = stripHeight, overlap: Int = stripOverlap) -> [Strip] {
        guard height > 0 else { return [] }
        let count = max(Int((Double(height) / Double(stripHeight)).rounded(.up)), 1)
        let step = Int((Double(height) / Double(count)).rounded(.up))
        return (0..<count).map { index in
            let start = index * step
            let end = min(start + step, height)
            let top = max(start - overlap, 0)
            let bottom = min(end + overlap, height)
            return Strip(top: top, height: bottom - top, owned: start..<end)
        }
    }

    /// 横条里的归一化框（左下角原点）→ 整张图的归一化框。
    static func mapBox(_ box: CGRect, strip: Strip, imageHeight: Int) -> CGRect {
        let total = CGFloat(imageHeight)
        let stripBottom = total - CGFloat(strip.top + strip.height)
        let scale = CGFloat(strip.height) / total
        return CGRect(x: box.minX, y: stripBottom / total + box.minY * scale, width: box.width, height: box.height * scale)
    }

    /// 框的中心在哪一行（左上角原点，像素）。
    static func centerRow(_ box: CGRect, imageHeight: Int) -> Int {
        Int(((1 - box.midY) * CGFloat(imageHeight)).rounded(.down))
    }

    private static func stripFragments(_ image: CGImage) throws -> [OCRFragment] {
        var result: [OCRFragment] = []
        for strip in strips(height: image.height) {
            guard let piece = image.cropping(to: CGRect(x: 0, y: strip.top, width: image.width, height: strip.height))
            else { continue }
            for fragment in try fragments(in: piece, level: .accurate) {
                let box = mapBox(fragment.box, strip: strip, imageHeight: image.height)
                // 重叠区里的字两条都会认到，只留中心落在本条负责范围里的那一份。
                guard strip.owned.contains(centerRow(box, imageHeight: image.height)) else { continue }
                result.append(OCRFragment(text: fragment.text, box: box))
            }
        }
        return result
    }
}

enum ScreenCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? { "找不到要截取的屏幕" }
}

@MainActor
enum ScreenRegionCapture {
    /// 截取屏幕上的一块区域。rect 是全局屏幕坐标（左下角原点，单位为点）。截图里不包含便单自己的窗口。
    static func capture(_ rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw ScreenCaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        // sourceRect 是这块屏幕内的坐标，左上角原点。
        config.sourceRect = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        config.width = max(Int(rect.width * scale), 1)
        config.height = max(Int(rect.height * scale), 1)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        CaptureDebug.logger.notice("截图 rect=\(String(describing: rect), privacy: .public) screen=\(String(describing: frame), privacy: .public) scale=\(scale, privacy: .public) display=\(display.displayID, privacy: .public) source=\(String(describing: config.sourceRect), privacy: .public) excluded=\(own.count, privacy: .public) image=\(image.width, privacy: .public)x\(image.height, privacy: .public)")
        return image
    }
}

// MARK: - 框选遮罩

/// 每块屏幕一个半透明遮罩，拖出矩形后回调；Esc 或右键取消。
@MainActor
final class RegionSelector {
    static let shared = RegionSelector()
    private var panels: [SelectionPanel] = []
    private var completion: (((rect: CGRect, screen: NSScreen)?) -> Void)?

    var isActive: Bool { !panels.isEmpty }

    func begin(_ completion: @escaping ((rect: CGRect, screen: NSScreen)?) -> Void) {
        if isActive { finish(nil) }
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        var keyPanel: SelectionPanel?
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let origin = screen.frame.origin
            view.onFinish = { [weak self] rect in
                guard let rect else {
                    self?.finish(nil)
                    return
                }
                self?.finish((rect.offsetBy(dx: origin.x, dy: origin.y), screen))
            }
            panel.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            if NSMouseInRect(mouse, screen.frame, false) { keyPanel = panel }
            panels.append(panel)
        }
        // 成为 key 才收得到 Esc；面板不激活便单，前台还是原来的应用。
        (keyPanel ?? panels.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    private func finish(_ result: (rect: CGRect, screen: NSScreen)?) {
        guard isActive else { return }
        panels.forEach { $0.orderOut(nil) }
        panels = []
        NSCursor.pop()
        let done = completion
        completion = nil
        done?(result)
    }
}

final class SelectionPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

final class SelectionView: NSView {
    /// 选好的矩形（本视图坐标）；nil 表示取消。
    var onFinish: ((CGRect?) -> Void)?
    private var anchor: NSPoint?
    private var selection: NSRect?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        guard let selection, selection.width >= 8, selection.height >= 8 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onFinish?(selection)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            NSColor(Theme.accent).setStroke()
            border.stroke()
        } else {
            drawHint()
        }
    }

    private func drawHint() {
        let hint = "拖动框选要识别日程的区域 · Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.maxY - 140,
                         width: size.width + 32, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        hint.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 8), withAttributes: attributes)
    }
}

// MARK: - 排查：文字识别结果为空时在系统日志里记下截图尺寸和亮度（不存图、不上传）

enum CaptureDebug {
    static let logger = Logger(subsystem: "ai.racore.BiandanMac", category: "capture")

    static func checkEmpty(_ lines: [String], image: CGImage) {
        guard lines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        logger.error("文字识别为空 image=\(image.width, privacy: .public)x\(image.height, privacy: .public) brightness=\(brightness(image), privacy: .public)")
    }

    /// 0（全黑）到 1（全白）；缩到 32×32 取平均。
    static func brightness(_ image: CGImage) -> Double {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
        }
        return Double(total) / Double(side * side * 3 * 255)
    }
}
