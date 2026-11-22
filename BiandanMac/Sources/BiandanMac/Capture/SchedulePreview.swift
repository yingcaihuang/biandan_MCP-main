import AppKit
import SwiftUI

// MARK: - 识别流程：取文字（框选 OCR / 剪贴板 / 拖入）→ 提取日程 → 确认卡片 → 确认后新建

@MainActor
enum ScheduleCaptureFlow {
    static let screenRecordingSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// 这次的文字从哪里来，告诉 AI 决策。
    private static var captureInput: CaptureInputSource = .region

    /// 框选屏幕区域识别。
    static func startRegion(model: AppModel, anchor: NSRect?) {
        guard !RegionSelector.shared.isActive else { return }
        guard ensureScreenPermission(model: model, anchor: anchor) else { return }
        // 框选要一两秒，正好在后台加载模型。
        FloatingBallController.shared.warmUpRecognizer()
        RegionSelector.shared.begin { result in
            guard let result else { return }
            captureInput = .region
            begin(model: model, anchor: anchor)
            Task { @MainActor in
                do {
                    stage(.capture)
                    let image = try await ScreenRegionCapture.capture(result.rect, on: result.screen)
                    stage(.ocr)
                    let lines = try await TextRecognizer.recognize(image)
                    CaptureDebug.checkEmpty(lines, image: image)
                    await finish(lines: lines, model: model)
                } catch {
                    fail("截图或识别失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 截取整块屏幕识别（双击小球）：截小球所在的屏幕，没有小球时截主屏幕。
    /// 只截可见区域（不含顶部菜单栏和 Dock），免得菜单栏时钟被当成日程；便单自己的窗口不截进去。
    static func startFullScreen(model: AppModel, anchor: NSRect?) {
        guard !RegionSelector.shared.isActive else { return }
        guard ensureScreenPermission(model: model, anchor: anchor) else { return }
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        begin(model: model, anchor: anchor)
        guard let screen else {
            fail("找不到要截取的屏幕")
            return
        }
        captureInput = .fullScreen
        let rect = screen.visibleFrame
        Task { @MainActor in
            do {
                stage(.capture)
                let image = try await ScreenRegionCapture.capture(rect, on: screen)
                stage(.ocr)
                let lines = try await TextRecognizer.recognize(image)
                CaptureDebug.checkEmpty(lines, image: image)
                await finish(lines: lines, model: model)
            } catch {
                fail("截图或识别失败：\(error.localizedDescription)")
            }
        }
    }

    /// 识别剪贴板：有文字用文字，否则有图片就做 OCR。
    static func fromClipboard(model: AppModel, anchor: NSRect?) {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fromText(text, model: model, anchor: anchor, input: .clipboard)
        } else if let image = image(from: pasteboard) {
            fromImage(image, model: model, anchor: anchor, input: .clipboard)
        } else {
            begin(model: model, anchor: anchor)
            fail("剪贴板里没有文字或图片。先在聊天里选中文字按 ⌘C，再点「识别剪贴板里的日程」。")
        }
    }

    static func fromText(_ text: String, model: AppModel, anchor: NSRect?, input: CaptureInputSource = .droppedText) {
        captureInput = input
        begin(model: model, anchor: anchor)
        Task { @MainActor in
            await finish(lines: text.components(separatedBy: .newlines), model: model)
        }
    }

    static func fromImage(_ image: CGImage, model: AppModel, anchor: NSRect?,
                          input: CaptureInputSource = .droppedImage) {
        captureInput = input
        begin(model: model, anchor: anchor)
        Task { @MainActor in
            do {
                stage(.ocr)
                let lines = try await TextRecognizer.recognize(image)
                CaptureDebug.checkEmpty(lines, image: image)
                await finish(lines: lines, model: model)
            } catch {
                fail("文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    static func image(from pasteboard: NSPasteboard) -> CGImage? {
        guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 给有地点、还没坐标的日程在地图上查坐标（设置里可关）。
    static func locatePlaces() {
        let state = SchedulePreviewController.shared.state
        for candidate in state.candidates where candidate.latitude == nil && candidate.lookup == .idle {
            locate(id: candidate.id)
        }
    }

    /// 查一条日程的坐标。查的过程中地点被改了，就丢掉这次的结果。
    static func locate(id: UUID) {
        let state = SchedulePreviewController.shared.state
        guard let index = state.candidates.firstIndex(where: { $0.id == id }) else { return }
        let query = state.candidates[index].locateQuery
        guard !query.isEmpty else { return }
        state.candidates[index].lookup = .locating
        Task { @MainActor in
            let place = await PlaceLocator.locate(query)
            guard let current = state.candidates.firstIndex(where: { $0.id == id }),
                  state.candidates[current].locateQuery == query else { return }
            if let place {
                state.candidates[current].latitude = place.latitude
                state.candidates[current].longitude = place.longitude
                state.candidates[current].placeTitle = place.name
                state.candidates[current].lookup = .found
            } else {
                state.candidates[current].lookup = .notFound
            }
        }
    }

    /// 确认卡片里点「用 AI 识别」：把这次识别到的文字交给 AI 重新提取。
    static func retryWithAI(model: AppModel) {
        let state = SchedulePreviewController.shared.state
        let lines = state.lines
        guard !lines.isEmpty, !state.loading else { return }
        let settings = model.aiExtractionSettings()
        let lists = model.snapshot.lists.map { (id: $0.id3, name: $0.displayName) }
        state.loading = true
        state.error = nil
        state.note = nil
        state.result = nil
        state.usage = nil
        state.candidates = []
        // 手动重跑不经过 AI 决策；如果这次是被拦下后重跑，记下 AI 找到了几条，用来算误拦率。
        let blockedID: UUID? = state.decision?.outcome == .block ? state.decision?.id : nil
        state.decision = nil
        state.resetTiming()
        state.enter(.ai)
        FloatingBallController.shared.setBusy(true)
        Task { @MainActor in
            do {
                let result = try await AIScheduleExtractor.extract(lines, today: model.today, lists: lists,
                                                                   settings: settings, trigger: .manual)
                state.candidates = ScheduleCategorizer.apply(PriorityCue.apply(result.candidates), lists: lists, fallback: state.listID,
                                                             allowNew: model.autoCreateCaptureCategory)
                state.source = .ai
                state.note = result.note(prefix: nil)
                state.usage = result.usage
                if let blockedID { DecisionLog.shared.markOverride(id: blockedID, events: result.candidates.count) }
                state.finishTiming(source: "ai")
                if model.autoLocateCapturePlace { locatePlaces() }
                state.loading = false
                FloatingBallController.shared.setBusy(false)
            } catch {
                fail("AI 识别没成功：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 步骤

    private static func stage(_ next: CaptureStage) {
        SchedulePreviewController.shared.state.enter(next)
    }

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
        controller.state.resetTiming()
        controller.state.model = model
        controller.state.lines = []
        controller.state.usage = nil
        model.refreshAIKeyStatus()
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
        state.lines = annotated
        let lists = model.snapshot.lists.map { (id: $0.id3, name: $0.displayName) }
        let settings = model.aiExtractionSettings()
        let decision = model.decisionSettings()
        let input = captureInput
        let today = model.today
        let weekStart = model.weekStart
        let run = UUID()
        state.runID = run
        let task = Task { @MainActor in
            let extraction = await ScheduleExtractor.extract(annotated, today: today, weekStart: weekStart,
                                                             lists: lists, ai: settings, decision: decision,
                                                             input: input) { stage, warm in
                let current = SchedulePreviewController.shared.state
                guard current.runID == run else { return }
                current.enter(stage, warm: warm)
                FloatingBallController.shared.setDecisionBusy(stage == .decision)
            } onSkip: { stage, reason in
                let current = SchedulePreviewController.shared.state
                guard current.runID == run else { return }
                current.skip(stage, reason: reason)
            }
            guard SchedulePreviewController.shared.state.runID == run else { return }
            apply(extraction, lists: lists, model: model)
        }
        state.extractionTask = task
        await task.value
    }

    /// 端侧模型或 AI 迟迟不返回时点「改用规则识别」：丢掉还在进行的提取，直接用规则识别这次的文字。
    static func useRules() {
        let state = SchedulePreviewController.shared.state
        guard state.canSkipToRules, let model = state.model else { return }
        let skipped = state.stage?.title ?? "端侧模型"
        state.runID = UUID()
        state.extractionTask?.cancel()
        state.extractionTask = nil
        state.enter(.rules, interruptPrevious: true)
        let lists = model.snapshot.lists.map { (id: $0.id3, name: $0.displayName) }
        let candidates = RuleScheduleExtractor.extract(state.lines, today: model.today, weekStart: model.weekStart,
                                                       lists: lists)
        apply(ScheduleExtraction(candidates: candidates, source: .rules, note: skipped + "迟迟没有返回，已改用规则识别"),
              lists: lists, model: model)
    }

    private static func apply(_ extraction: ScheduleExtraction, lists: [(id: String, name: String)], model: AppModel) {
        let state = SchedulePreviewController.shared.state
        state.extractionTask = nil
        state.candidates = ScheduleCategorizer.apply(PriorityCue.apply(extraction.candidates), lists: lists, fallback: state.listID,
                                                     allowNew: model.autoCreateCaptureCategory)
        state.source = extraction.source
        state.note = extraction.note
        state.usage = extraction.usage
        state.decision = extraction.decision
        FloatingBallController.shared.showDecision(extraction.decision)
        state.finishTiming(source: String(describing: extraction.source))
        if model.autoLocateCapturePlace { locatePlaces() }
        state.loading = false
        FloatingBallController.shared.setBusy(false)
    }

    private static func fail(_ message: String) {
        let state = SchedulePreviewController.shared.state
        state.error = message
        state.finishTiming(source: "failed")
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
    /// 识别到的文字（带消息时间），「用 AI 识别」时重新提取用。
    var lines: [CaptureLine] = []
    /// 这次 AI 识别的用量，卡片里用彩色小卡片显示。
    var usage: AIUsageRecord?
    /// 这次 AI 决策的结果（没用到时为 nil）。
    var decision: DecisionRecord?
    var error: String?
    var needsScreenPermission = false
    var listID = TodoList.defaultID
    var loading = false
    var saving = false
    var result: String?
    /// 当前阶段与计时（见 CaptureTiming.swift）。
    var stage: CaptureStage?
    var stageStart = Date()
    var timings: [CaptureStageTiming] = []
    var modelWarm: Bool?
    /// 卡片最高多少（所在屏幕的可见区域减去边距）；内容更高时中间改成滚动。0 表示不限。
    var maxHeight: CGFloat = 0
    @ObservationIgnored var runID = UUID()
    @ObservationIgnored var flowStart = Date()
    @ObservationIgnored var extractionTask: Task<Void, Never>?
    @ObservationIgnored weak var model: AppModel?
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
    /// 这次往上长（底边不动）还是往下长（顶边不动），见 PreviewPlacement.growsUp。
    private var growsUp = false
    private var area: CGRect?
    private var lastSize: CGSize?
    /// 上一次摆好的位置：尺寸变化时以它的顶边（往下长）或底边（往上长）为准。
    private var lastFrame: CGRect?
    private var resizeObserver: NSObjectProtocol?

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
        state.decision = nil
    }

    func present(model: AppModel, anchor: NSRect?) {
        self.anchor = anchor
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        if let hosting = panel.contentView {
            let fitting = hosting.fittingSize
            place(panel, size: fitting.height > 1 ? fitting : (lastSize ?? CGSize(width: 520, height: 200)))
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
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        // 托管视图会按内容自动改窗口尺寸，但它不知道该往上还是往下长（之前会长到 Dock 下面）：
        // 每次尺寸变了都按 growsUp 重新摆一次，再收回可见区域里。
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
        return panel
    }

    /// 内容高度变化时：往下长的保持顶边不动，往上长的保持底边不动，再收回可见区域里（不压菜单栏和 Dock）。
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastSize = size
        apply(size: size, reason: "content")
    }

    /// 窗口尺寸被托管视图改过之后，按原来的锚定边重新摆。
    private func settle() {
        guard let panel else { return }
        apply(size: panel.frame.size, reason: "window")
    }

    private func apply(size: CGSize, reason: String) {
        guard let panel, size.width > 0, size.height > 0,
              let area = area ?? panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let reference = lastFrame ?? panel.frame
        let target = PreviewPlacement.resized(reference, to: size, growsUp: growsUp, area: area)
        lastFrame = target
        guard !PreviewPlacement.same(target, panel.frame) else { return }
        panel.setFrame(target, display: true)
    }

    /// 有球时摆在球旁边（球在右边就放左边；球在下半屏就往上长），否则放在鼠标所在屏幕的上方。
    private func place(_ panel: NSPanel, size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else {
            panel.center()
            return
        }
        self.area = area
        growsUp = PreviewPlacement.growsUp(anchor: anchor, area: area)
        state.maxHeight = PreviewPlacement.maxHeight(in: area)
        let frame = PreviewPlacement.initialFrame(size: size, anchor: anchor, area: area)
        lastFrame = frame
        panel.setFrame(frame, display: true)
    }
}

/// 确认卡片摆在哪里。坐标都是 AppKit 屏幕坐标（左下角原点），area 是屏幕可见区域（不含菜单栏和 Dock）。
enum PreviewPlacement {
    static let margin: CGFloat = 8
    static let gap: CGFloat = 8

    /// 球在下半屏时往上长（底边和球底对齐），否则往下长（顶边和球顶对齐）；没有球时往下长。
    static func growsUp(anchor: CGRect?, area: CGRect) -> Bool {
        guard let anchor else { return false }
        return anchor.midY < area.midY
    }

    /// 卡片最高多少：可见区域上下各留一点边。
    static func maxHeight(in area: CGRect) -> CGFloat {
        max(area.height - margin * 2, 200)
    }

    static func initialFrame(size: CGSize, anchor: CGRect?, area: CGRect) -> CGRect {
        let height = min(size.height, maxHeight(in: area))
        let origin: CGPoint
        if let anchor {
            let x = anchor.midX > area.midX ? anchor.minX - size.width - gap : anchor.maxX + gap
            let y = growsUp(anchor: anchor, area: area) ? anchor.minY : anchor.maxY - height
            origin = CGPoint(x: x, y: y)
        } else {
            origin = CGPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.18 - height)
        }
        return clamp(CGRect(origin: origin, size: CGSize(width: size.width, height: height)), to: area)
    }

    static func resized(_ frame: CGRect, to size: CGSize, growsUp: Bool, area: CGRect) -> CGRect {
        let height = min(size.height, maxHeight(in: area))
        let y = growsUp ? frame.minY : frame.maxY - height
        return clamp(CGRect(x: frame.minX, y: y, width: size.width, height: height), to: area)
    }

    /// 收回可见区域里，四边各留 margin。
    static func clamp(_ frame: CGRect, to area: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(frame.minX, area.minX + margin), area.maxX - frame.width - margin)
        result.origin.y = min(max(frame.minY, area.minY + margin), area.maxY - frame.height - margin)
        return result
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

// MARK: - 候选拖到主窗口日历

@MainActor
extension ScheduleCaptureFlow {
    /// 改到那一天（跨天的保留天数，时刻不变），并勾选上。
    static func moveCandidate(_ id: UUID, to day: LocalDate) {
        let state = SchedulePreviewController.shared.state
        guard let index = state.candidates.firstIndex(where: { $0.id == id }) else { return }
        let today = state.model?.today ?? LocalDate.today()
        var candidate = state.candidates[index]
        if let start = candidate.date, let end = candidate.endDate {
            candidate.endDate = day.adding(days: start.days(to: end))
        } else {
            candidate.endDate = nil
        }
        candidate.date = day
        candidate.vagueDate = nil
        candidate.include = true
        candidate.review(today: today)
        state.candidates[index] = candidate
        let name = candidate.title.isEmpty ? "日程" : candidate.title
        state.result = ["已把「", name, "」改到 ", DateText.title(day, today: today)].joined()
    }
}
