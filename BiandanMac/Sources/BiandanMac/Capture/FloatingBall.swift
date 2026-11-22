import AppKit
import SwiftUI

// MARK: - 桌面浮窗球
//
// 单击：框选屏幕区域识别日程；右键：菜单（剪贴板识别、快速添加、隐藏）；可以把文字或图片拖到球上识别。
// 不抢焦点：点球之后微信、飞书等仍是前台应用。拖动松手后吸附到屏幕左右边缘，并记住位置。

@Observable
final class FloatingBallState {
    var busy = false
    var targeted = false
    var pressed = false
    var hovering = false
    /// AI 决策判断中：光弧换成青色。
    var decisionBusy = false
    /// AI 决策的结果角标，几秒后消失。
    var badge: DecisionOutcome?
}

final class FloatingBallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingBallController {
    static let shared = FloatingBallController()
    private static let originKey = "biandan.floatingBall.origin"
    /// 窗口比光球（44）大一圈，给外发光留出空间。
    static let size: CGFloat = 64

    private var panel: FloatingBallPanel?
    private let state = FloatingBallState()
    private weak var model: AppModel?
    private var screenObserver: NSObjectProtocol?
    private var warmupScheduled = false

    /// 球当前的位置（隐藏时为 nil），确认卡片据此摆在球旁边。
    var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    func apply(model: AppModel) {
        self.model = model
        if model.showFloatingBall {
            show()
            scheduleWarmup()
        } else {
            FloatingBallMenuController.shared.close()
            panel?.orderOut(nil)
        }
    }

    func setBusy(_ busy: Bool) {
        state.busy = busy
        if !busy { state.decisionBusy = false }
    }

    private var badgeTask: Task<Void, Never>?

    func setDecisionBusy(_ on: Bool) {
        state.decisionBusy = on
    }

    /// 识别结束后在球的右上角显示 AI 决策的结果，约 6 秒后消失；鼠标移上去能看到说明。
    func showDecision(_ record: DecisionRecord?) {
        state.decisionBusy = false
        badgeTask?.cancel()
        guard let record else {
            state.badge = nil
            panel?.contentView?.toolTip = FloatingBallView.defaultTip
            return
        }
        state.badge = record.outcome
        let decider = record.decisionModel ?? DecisionSettings.model
        let saved: String = record.savedUSD.map { " · 省 " + AIUsageFormat.cost($0) } ?? ""
        switch record.outcome {
        case .block: panel?.contentView?.toolTip = [decider, " 判断没有日程 · 没有调用 ", record.aiModel, saved].joined()
        case .pass: panel?.contentView?.toolTip = [decider, " 判断有日程 · 已交给 ", record.aiModel, " 提取"].joined()
        case .failed: panel?.contentView?.toolTip = [decider, " 没判断成功 · 照常调用 ", record.aiModel].joined()
        }
        badgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            self.state.badge = nil
            self.panel?.contentView?.toolTip = FloatingBallView.defaultTip
        }
    }

    /// 提前加载文字识别和端侧模型，第一次识别不用等。「总是用 AI」时不用端侧模型，只预热文字识别。
    func warmUpRecognizer() {
        ModelWarmup.shared.warmOCROnce()
        guard model?.aiExtractionMode != .always else { return }
        ModelWarmup.shared.prewarm()
    }

    /// 启动后等便单自己的同步先跑一会儿，再在后台预热。
    private func scheduleWarmup() {
        guard !warmupScheduled else { return }
        warmupScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.warmUpRecognizer()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { panel.setFrameOrigin(restoredOrigin()) }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> FloatingBallPanel {
        let size = Self.size
        let panel = FloatingBallPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let view = FloatingBallView(frame: NSRect(x: 0, y: 0, width: size, height: size), state: state)
        view.onClick = { [weak self] in self?.captureRegion() }
        view.onDoubleClick = { [weak self] in self?.captureFullScreen() }
        view.onMenu = { [weak self] event, view in self?.showMenu(event, in: view) }
        view.onMoved = { [weak self] in self?.snap() }
        view.onDropText = { [weak self] text in
            guard let self, let model = self.model else { return }
            ScheduleCaptureFlow.fromText(text, model: model, anchor: self.frame)
        }
        view.onDropImage = { [weak self] image in
            guard let self, let model = self.model else { return }
            ScheduleCaptureFlow.fromImage(image, model: model, anchor: self.frame)
        }
        panel.contentView = view

        // 显示器插拔、分辨率变化后，球如果跑到屏幕外就放回默认位置。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !Self.isOnScreen(panel.frame) { panel.setFrameOrigin(self.restoredOrigin()) }
            }
        }
        return panel
    }

    private func captureRegion() {
        guard let model else { return }
        ScheduleCaptureFlow.startRegion(model: model, anchor: frame)
    }

    /// 截取小球所在的整块屏幕。
    private func captureFullScreen() {
        guard let model else { return }
        ScheduleCaptureFlow.startFullScreen(model: model, anchor: frame)
    }

    /// 右键：主题菜单面板（和任务卡片的右键菜单同一套样式），贴在球旁边弹出。
    private func showMenu(_ event: NSEvent, in view: NSView) {
        guard let model, let anchor = frame else { return }
        let actions = FloatingBallMenu.Actions(
            region: { [weak self] in self?.captureRegion() },
            fullScreen: { [weak self] in self?.captureFullScreen() },
            clipboard: { [weak self] in ScheduleCaptureFlow.fromClipboard(model: model, anchor: self?.frame) },
            quickAdd: { QuickAddPanelController.shared.show(model: model) },
            hide: { model.showFloatingBall = false })
        FloatingBallMenuController.shared.show(model: model, anchor: anchor, actions: actions)
    }

    /// 松手后吸附到最近的左右边缘，并保存位置。
    private func snap() {
        guard let panel else { return }
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let x = center.x < area.midX ? area.minX + 2 : area.maxX - frame.width - 2
        let y = min(max(frame.minY, area.minY + 2), area.maxY - frame.height - 2)
        let target = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        panel.setFrame(target, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromPoint(target.origin), forKey: Self.originKey)
    }

    private func restoredOrigin() -> NSPoint {
        if let text = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(text)
            if Self.isOnScreen(NSRect(origin: origin, size: NSSize(width: Self.size, height: Self.size))) { return origin }
        }
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - Self.size - 2, y: area.midY - Self.size / 2)
    }

    private static func isOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(rect) }
    }
}

/// 球的 AppKit 外壳：自己处理点击、拖动、右键和拖入；画面交给 SwiftUI。
final class FloatingBallView: NSView {
    static let defaultTip = "单击框选识别日程 · 双击截取整个屏幕 · 右键更多 · 可把文字或图片拖进来"
    var onClick: (() -> Void)?
    /// 双击：截取整块屏幕。
    var onDoubleClick: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onMoved: (() -> Void)?
    var onDropText: ((String) -> Void)?
    var onDropImage: ((CGImage) -> Void)?

    private let state: FloatingBallState
    private var pressLocation: NSPoint?
    private var pressOrigin: NSPoint = .zero
    private var dragging = false
    /// 单击要等过了双击间隔才执行，期间来了第二下就取消，改为双击。
    private var pendingClick: DispatchWorkItem?

    init(frame: NSRect, state: FloatingBallState) {
        self.state = state
        super.init(frame: frame)
        let hosting = NSHostingView(rootView: FloatingBallVisual(state: state).preferredColorScheme(.light))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.string, .fileURL, .tiff, .png])
        toolTip = Self.defaultTip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 只有圆形区域响应，并且整块由自己处理（不交给里面的 SwiftUI 视图）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let distance = hypot(local.x - bounds.midX, local.y - bounds.midY)
        return distance <= 24 ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        state.hovering = true
        FloatingBallController.shared.warmUpRecognizer()
    }
    override func mouseExited(with event: NSEvent) { state.hovering = false }

    override func mouseDown(with event: NSEvent) {
        pressLocation = NSEvent.mouseLocation
        pressOrigin = window?.frame.origin ?? .zero
        dragging = false
        state.pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !dragging && hypot(dx, dy) < 3 { return }
        dragging = true
        state.pressed = false
        window.setFrameOrigin(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        state.pressed = false
        let wasPressed = pressLocation != nil
        pressLocation = nil
        if dragging {
            dragging = false
            pendingClick?.cancel()
            pendingClick = nil
            onMoved?()
        } else if wasPressed {
            if event.clickCount >= 2 {
                pendingClick?.cancel()
                pendingClick = nil
                onDoubleClick?()
            } else {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingClick = nil
                    self?.onClick?()
                }
                pendingClick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event, self)
    }

    // MARK: 拖入文字 / 图片

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        state.targeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        state.targeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        state.targeted = false
        let pasteboard = sender.draggingPasteboard
        if let image = ScheduleCaptureFlow.image(from: pasteboard) {
            onDropImage?(image)
            return true
        }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDropText?(text)
            return true
        }
        return false
    }
}

/// 小球的画面：类似 Siri 的流动光球，配色取自应用图标（深橙、橙、琥珀、亮黄、蜜桃）。
/// 平时缓慢流动；悬停时变亮、加快；识别中转得更快并加一圈光弧；拖入时放大并显示「＋」。
/// 系统开启「减弱动态效果」时静止。
struct FloatingBallVisual: View {
    let state: FloatingBallState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let decisionColor = Color(hex: 0x22D3EE)

    var body: some View {
        let lit = state.targeted || state.hovering
        let scale: CGFloat = state.targeted ? 1.12 : (state.pressed ? 0.92 : 1)
        // 平时降低刷新率省电；悬停、识别中再提高。
        let interval: Double = (lit || state.busy) ? 1.0 / 60 : 1.0 / 24
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion)) { context in
            SiriOrb(time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                    speed: state.busy ? 3.2 : (lit ? 1.8 : 1),
                    lit: lit, busy: state.busy, targeted: state.targeted,
                    arcColor: state.decisionBusy ? Self.decisionColor : .white)
        }
        .frame(width: SiriOrb.diameter, height: SiriOrb.diameter)
        .scaleEffect(scale)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: scale)
        .frame(width: FloatingBallController.size, height: FloatingBallController.size)
        .overlay(alignment: .topTrailing) {
            if let badge = state.badge {
                DecisionBadge(outcome: badge).padding(7)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: state.badge)
    }
}

/// 球右上角的 AI 决策角标：绿色漏斗是拦下了，蓝色箭头是交给了 AI，灰色是没判断成功。
private struct DecisionBadge: View {
    let outcome: DecisionOutcome

    var body: some View {
        let icon: String = outcome == .block ? "line.3.horizontal.decrease" : (outcome == .pass ? "arrow.up.right" : "exclamationmark")
        let tint: Color = outcome == .block ? Color(hex: 0x34C759) : (outcome == .pass ? Color(hex: 0x2F80ED) : Color(hex: 0x8E8E93))
        Image(systemName: icon)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(tint))
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .transition(.scale.combined(with: .opacity))
    }
}

private struct SiriOrb: View {
    static let diameter: CGFloat = 44

    let time: Double
    let speed: Double
    let lit: Bool
    let busy: Bool
    let targeted: Bool
    let arcColor: Color

    private struct Blob {
        let color: Color
        let size: CGFloat
        let radius: CGFloat
        let rate: Double
        let phase: Double
    }

    /// 取自应用图标：便签的深橙到浅橙渐变、勾选圆的琥珀到亮黄、折角的蜜桃色。
    private enum IconPalette {
        static let deepOrange = Color(hex: 0xF76E19)
        static let orange = Color(hex: 0xFA8B36)
        static let lightOrange = Color(hex: 0xFCA45E)
        static let amber = Color(hex: 0xFDB834)
        static let yellow = Color(hex: 0xFFC550)
        static let peach = Color(hex: 0xFDD3B0)
    }

    private static let blobs: [Blob] = [
        Blob(color: IconPalette.deepOrange, size: 26, radius: 10, rate: 0.9, phase: 0),
        Blob(color: IconPalette.yellow, size: 24, radius: 11, rate: -0.7, phase: 2.1),
        Blob(color: IconPalette.peach, size: 20, radius: 9, rate: 1.15, phase: 4.2),
        Blob(color: IconPalette.amber, size: 28, radius: 6, rate: -1.0, phase: 1.0),
    ]

    private static let ring: [Color] = [
        IconPalette.orange, IconPalette.deepOrange, IconPalette.lightOrange,
        IconPalette.amber, IconPalette.yellow, IconPalette.orange,
    ]

    private static let glow = Color(hex: 0xFA8B36)

    var body: some View {
        let spin = Angle.degrees(time * 24 * speed)
        let breath = 1 + 0.08 * sin(time * 2 * speed)
        ZStack {
            colors(spin: spin)
            core(breath: breath)
            highlight
            Circle()
                .strokeBorder(rim(spin: spin), lineWidth: 1.2)
            if busy { busyArc }
            if targeted {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .clipShape(Circle())
        .drawingGroup()
        .shadow(color: Self.glow.opacity(lit ? 0.6 : 0.38), radius: lit ? 7 : 5)
        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
    }

    /// 底色：转动的彩色角向渐变，上面漂着几团模糊色块。
    private func colors(spin: Angle) -> some View {
        ZStack {
            Rectangle()
                .fill(AngularGradient(colors: Self.ring, center: .center, angle: spin))
                .frame(width: Self.diameter * 1.5, height: Self.diameter * 1.5)
            ForEach(Self.blobs.indices, id: \.self) { index in
                blob(Self.blobs[index])
            }
        }
        .blur(radius: 6)
        .saturation(lit ? 1.25 : 1.05)
    }

    private func blob(_ blob: Blob) -> some View {
        let angle = time * speed * blob.rate + blob.phase
        let x = CGFloat(cos(angle)) * blob.radius
        let y = CGFloat(sin(angle * 1.3)) * blob.radius
        return Circle()
            .fill(blob.color)
            .frame(width: blob.size, height: blob.size)
            .offset(x: x, y: y)
            .opacity(0.85)
    }

    /// 中间发亮的核心，跟着呼吸缩放。
    private func core(breath: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [.white.opacity(lit ? 0.85 : 0.7), .white.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: 12))
            .frame(width: 26, height: 26)
            .scaleEffect(CGFloat(breath))
    }

    /// 左上角的玻璃高光。
    private var highlight: some View {
        Ellipse()
            .fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 26, height: 14)
            .offset(x: -4, y: -12)
            .blur(radius: 1)
    }

    private func rim(spin: Angle) -> AngularGradient {
        AngularGradient(colors: [.white.opacity(0.9), .white.opacity(0.15), .white.opacity(0.6),
                                 .white.opacity(0.15), .white.opacity(0.9)],
                        center: .center, angle: -spin)
    }

    /// 识别中：一圈旋转的白色光弧。
    private var busyArc: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(arcColor.opacity(0.95), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 1) * 360))
            .padding(4)
    }
}

// MARK: - 右键菜单（主题面板，替代系统 NSMenu）

/// 菜单面板：不激活便单（微信、飞书仍在前台），但能成为 key 窗口，这样悬停高亮和 Esc 都能用。
final class FloatingBallMenuPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class FloatingBallMenuController {
    static let shared = FloatingBallMenuController()

    private var panel: FloatingBallMenuPanel?
    private var monitors: [Any] = []

    func show(model: AppModel, anchor: NSRect, actions: FloatingBallMenu.Actions) {
        close()
        let panel = FloatingBallMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.close() }

        let root = FloatingBallMenu(actions: actions, close: { [weak self] in self?.close() })
            .environment(model)
            .preferredColorScheme(.light)
        let hosting = NSHostingView(rootView: root)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(Self.frame(for: size, anchor: anchor), display: true)
        panel.alphaValue = 0
        // nonactivatingPanel：成为 key 窗口但不把便单切到前台。
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        installMonitors()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    /// 球在屏幕右半边就往左弹，在左半边就往右弹；顶部和球对齐，不超出屏幕。
    private static func frame(for size: NSSize, anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? anchor
        let gap: CGFloat = 2
        var x = anchor.midX < area.midX ? anchor.maxX + gap : anchor.minX - size.width - gap
        x = min(max(x, area.minX + 4), area.maxX - size.width - 4)
        var y = anchor.maxY - size.height - 6
        y = min(max(y, area.minY + 4), area.maxY - size.height - 4)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 点到别的应用或便单的其他窗口（包括小球本身）时收起。
    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let panel = self.panel, event.window !== panel { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}

/// 小球右键菜单的内容：和任务卡片的右键菜单一样，用米色面板、白色分组卡片和彩色图标行。
struct FloatingBallMenu: View {
    struct Actions {
        var region: @MainActor () -> Void
        var fullScreen: @MainActor () -> Void
        var clipboard: @MainActor () -> Void
        var quickAdd: @MainActor () -> Void
        var hide: @MainActor () -> Void
    }

    let actions: Actions
    let close: () -> Void

    /// 先收起面板，再在下一轮执行（框选时屏幕上不会残留菜单）。
    private func run(_ action: @escaping @MainActor () -> Void) {
        close()
        Task { @MainActor in action() }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ThemedMenuPanel(title: "识别日程", subtitle: "也可以把文字或聊天截图拖到小球上") {
            ThemedMenuGroup {
                ThemedMenuRow(icon: "viewfinder", title: "框选识别日程", detail: "框住屏幕上的聊天记录",
                              tint: Theme.accent) { run(actions.region) }
                ThemedMenuSeparator()
                ThemedMenuRow(icon: "rectangle.dashed", title: "截取整个屏幕识别", detail: "双击小球也可以",
                              tint: Color(hex: 0xF08A3C)) { run(actions.fullScreen) }
                ThemedMenuSeparator()
                ThemedMenuRow(icon: "doc.on.clipboard", title: "识别剪贴板里的日程", detail: "复制的文字或截图",
                              tint: Quadrant.notImportantUrgent.tint) { run(actions.clipboard) }
            }
            ThemedMenuGroup {
                ThemedMenuRow(icon: "plus", title: "全局快速添加…", detail: "一行文字直接新建任务",
                              tint: Theme.done) { run(actions.quickAdd) }
            }
            ThemedMenuGroup {
                ThemedMenuRow(icon: "eye.slash", title: "隐藏小球", detail: "可在「设置 → 通用」里重新打开",
                              tint: Theme.subtext) { run(actions.hide) }
            }
        }
        // 自己的面板窗口没有系统 popover 的底，铺上主题底色、圆角和描边。
        .background(shape.fill(Theme.panel))
        .clipShape(shape)
        .overlay(shape.stroke(Theme.line))
    }
}

/// 带闭包的菜单项。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}
