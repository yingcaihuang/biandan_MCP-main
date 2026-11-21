import AppKit
import ScreenCaptureKit
import Vision

// MARK: - 框选屏幕区域、截图、OCR（全部在本机处理，图片只在内存里，不存盘、不上传）

enum TextRecognizer {
    /// 识别图片里的文字（简体、繁体中文和英文），按阅读顺序返回每一行。
    static func recognize(_ image: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let fragments = (request.results ?? []).compactMap { observation -> OCRFragment? in
                guard let best = observation.topCandidates(1).first else { return nil }
                return OCRFragment(text: best.string, box: observation.boundingBox)
            }
            return OCRLayout.lines(fragments)
        }.value
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
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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
