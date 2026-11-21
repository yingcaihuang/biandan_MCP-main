import AppKit
import SwiftUI

// MARK: - 识别流程：取文字（框选 OCR / 剪贴板 / 拖入）→ 提取日程 → 确认卡片 → 确认后新建

@MainActor
enum ScheduleCaptureFlow {
    static let screenRecordingSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// 框选屏幕区域识别。
    static func startRegion(model: AppModel, anchor: NSRect?) {
        guard !RegionSelector.shared.isActive else { return }
        guard ensureScreenPermission(model: model, anchor: anchor) else { return }
        RegionSelector.shared.begin { result in
            guard let result else { return }
            begin(model: model, anchor: anchor)
            Task { @MainActor in
                do {
                    let image = try await ScreenRegionCapture.capture(result.rect, on: result.screen)
                    let lines = try await TextRecognizer.recognize(image)
                    await finish(lines: lines, model: model)
                } catch {
                    fail("截图或识别失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 识别剪贴板：有文字用文字，否则有图片就做 OCR。
    static func fromClipboard(model: AppModel, anchor: NSRect?) {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fromText(text, model: model, anchor: anchor)
        } else if let image = image(from: pasteboard) {
            fromImage(image, model: model, anchor: anchor)
        } else {
            begin(model: model, anchor: anchor)
            fail("剪贴板里没有文字或图片。先在聊天里选中文字按 ⌘C，再点「识别剪贴板里的日程」。")
        }
    }

    static func fromText(_ text: String, model: AppModel, anchor: NSRect?) {
        begin(model: model, anchor: anchor)
        Task { @MainActor in
            await finish(lines: text.components(separatedBy: .newlines), model: model)
        }
    }

    static func fromImage(_ image: CGImage, model: AppModel, anchor: NSRect?) {
        begin(model: model, anchor: anchor)
        Task { @MainActor in
            do {
                await finish(lines: try await TextRecognizer.recognize(image), model: model)
            } catch {
                fail("文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    static func image(from pasteboard: NSPasteboard) -> CGImage? {
        guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: 步骤

    /// 第一次框选时系统会弹出授权；还没授权时在卡片里说明怎么打开。
    private static func ensureScreenPermission(model: AppModel, anchor: NSRect?) -> Bool {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() { return true }
        begin(model: model, anchor: anchor)
        SchedulePreviewController.shared.state.needsScreenPermission = true
        fail("框选识别需要「屏幕录制」权限：在「系统设置 → 隐私与安全性 → 屏幕录制」里打开「便单」，然后重新打开便单。识别剪贴板和拖入文字不需要这个权限。")
        return false
    }

    private static func begin(model: AppModel, anchor: NSRect?) {
        let controller = SchedulePreviewController.shared
        controller.reset()
        controller.state.listID = model.snapshot.lists.first?.id3 ?? TodoList.defaultID
        controller.state.loading = true
        FloatingBallController.shared.setBusy(true)
        controller.present(model: model, anchor: anchor)
    }

    private static func finish(lines: [String], model: AppModel) async {
        let state = SchedulePreviewController.shared.state
        let annotated = ChatTimestamp.annotate(lines, today: model.today)
        state.recognizedText = annotated.map(\.text).joined(separator: "\n")
        guard annotated.contains(where: { !$0.isTimestamp }) else {
            fail("没有识别到文字，换一块区域再试试。")
            return
        }
        let lists = model.snapshot.lists.map { (id: $0.id3, name: $0.displayName) }
        let extraction = await ScheduleExtractor.extract(annotated, today: model.today, weekStart: model.weekStart,
                                                         lists: lists)
        state.candidates = ScheduleCategorizer.apply(extraction.candidates, lists: lists, fallback: state.listID,
                                                     allowNew: model.autoCreateCaptureCategory)
        state.source = extraction.source
        state.note = extraction.note
        state.loading = false
        FloatingBallController.shared.setBusy(false)
    }

    private static func fail(_ message: String) {
        let state = SchedulePreviewController.shared.state
        state.error = message
        state.loading = false
        FloatingBallController.shared.setBusy(false)
    }
}

// MARK: - 确认卡片的状态与窗口

@Observable
final class SchedulePreviewState {
    var candidates: [ScheduleCandidate] = []
    var source: ScheduleExtractionSource?
    var note: String?
    var recognizedText = ""
    var error: String?
    var needsScreenPermission = false
    var listID = TodoList.defaultID
    var loading = false
    var saving = false
    var result: String?
}

/// 能接收键盘输入、但不激活便单的浮动面板。点到别处不收起（方便回到聊天里核对），Esc 或「取消」关闭。
final class SchedulePreviewPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class SchedulePreviewController {
    static let shared = SchedulePreviewController()
    let state = SchedulePreviewState()
    private var panel: SchedulePreviewPanel?
    private var anchor: NSRect?

    func reset() {
        state.candidates = []
        state.source = nil
        state.note = nil
        state.recognizedText = ""
        state.error = nil
        state.needsScreenPermission = false
        state.loading = false
        state.saving = false
        state.result = nil
    }

    func present(model: AppModel, anchor: NSRect?) {
        self.anchor = anchor
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        if let hosting = panel.contentView {
            place(panel, size: hosting.fittingSize)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(_ model: AppModel) -> SchedulePreviewPanel {
        let panel = SchedulePreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.hide() }
        let root = SchedulePreviewView(state: state,
                                       onClose: { [weak self] in self?.hide() },
                                       onResize: { [weak self] size in self?.resize(to: size) })
            .environment(model)
            .preferredColorScheme(.light)
        panel.contentView = NSHostingView(rootView: root)
        return panel
    }

    /// 内容高度变化时保持顶边不动。
    private func resize(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        if let area = (panel.screen ?? NSScreen.main)?.visibleFrame, frame.minY < area.minY + 8 {
            frame.origin.y = area.minY + 8
        }
        panel.setFrame(frame, display: true)
    }

    /// 有球时摆在球旁边（球在右边就放左边），否则放在鼠标所在屏幕的上方。
    private func place(_ panel: NSPanel, size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else {
            panel.center()
            return
        }
        var origin: CGPoint
        if let anchor {
            let x = anchor.midX > area.midX ? anchor.minX - size.width - 8 : anchor.maxX + 8
            origin = CGPoint(x: x, y: anchor.maxY - size.height)
        } else {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.18 - size.height)
        }
        origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
        origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
