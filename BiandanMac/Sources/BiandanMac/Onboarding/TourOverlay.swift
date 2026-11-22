import AppKit
import SwiftUI

// MARK: - 功能导览：独立的透明窗口盖住整个主窗口（含标题栏），按屏幕坐标挖洞高亮控件
//
// 每个目标放一个透明的 NSView，直接取它在屏幕上的位置，不经过 SwiftUI 布局换算。
// 遮罩窗口不接收鼠标；本地事件监听只放行落在高亮区域里的点击，其余点击拦下并提示。

enum TourTarget: String, Hashable, CaseIterable {
    case sidebar, rowNext7, summary, quickAdd, modeSwitch, selection, newTask, importer, stats, syncBar, account
    /// 桌面浮窗球（独立面板，不在主窗口里）。
    case floatingBall

    /// 这些控件只在任务视图里有（记录页没有）。
    var needsTaskPage: Bool {
        switch self {
        case .summary, .quickAdd, .modeSwitch, .selection, .newTask: return true
        default: return false
        }
    }
}

/// 需要用户亲手完成的操作；完成后自动进入下一步。
enum TourAction: Equatable {
    case select(SidebarItem)
    case mode(ContentMode)
    case selectionMode
    case addTask
    /// 点浮窗球开始识别（框选或截整屏）。
    case capture
}

@MainActor
final class TourGeometry {
    static let shared = TourGeometry()

    private final class Box {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private var views: [TourTarget: [Box]] = [:]

    func register(_ view: NSView, target: TourTarget) {
        var list = (views[target] ?? []).filter { $0.view != nil && $0.view !== view }
        list.append(Box(view))
        views[target] = list
    }

    /// 用了 SwiftUI 坐标换算（AppKit 视图尺寸不可信）的目标；排查模式里名字后面标「*」。
    private(set) var converted: Set<TourTarget> = []

    /// 同一目标可能登记过多个视图（视图重建）：取还在窗口里、看得见的最新那个。
    private func liveView(_ target: TourTarget) -> TourAnchorView? {
        let candidates = (views[target] ?? []).reversed().compactMap { $0.view as? TourAnchorView }
        return candidates.first { view in
            let visible = view.visibleRect
            let sized = (visible.width > 1 && visible.height > 1)
                || (view.swiftFrame.width > 1 && view.swiftFrame.height > 1)
            return view.window != nil && !view.isHiddenOrHasHiddenAncestor && sized
        }
    }

    /// 目标的可见区域，屏幕坐标（左下角原点）。
    /// 侧栏顶部 / 底部固定区域、标题栏按钮里的定位视图有时会被撑成整列大小：
    /// 这时 AppKit 尺寸和 SwiftUI 量到的对不上，改用 SwiftUI 的坐标换算到屏幕。
    func screenRect(for target: TourTarget) -> CGRect? {
        if target == .floatingBall {
            // 面板 64，光球 44。
            return FloatingBallController.shared.frame?.insetBy(dx: 10, dy: 10)
        }
        guard let view = liveView(target), let window = view.window else { return nil }
        let own = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        let frame = view.swiftFrame
        let matches = abs(view.bounds.width - frame.width) <= 2 && abs(view.bounds.height - frame.height) <= 2
        guard frame.width > 1, frame.height > 1, !matches, let host = Self.host(of: view, fitting: frame) else {
            converted.remove(target)
            return own
        }
        var rect = frame
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        converted.insert(target)
        return window.convertToScreen(host.convert(rect, to: nil))
    }

    /// SwiftUI 的 global 坐标以所在的托管视图为原点：从里往外找第一个装得下这个区域的托管视图。
    private static func host(of view: NSView, fitting frame: CGRect) -> NSView? {
        var current = view.superview
        var nearest: NSView?
        while let candidate = current {
            if String(describing: type(of: candidate)).contains("HostingView") {
                if nearest == nil { nearest = candidate }
                if frame.maxX <= candidate.bounds.width + 2 && frame.maxY <= candidate.bounds.height + 2 {
                    return candidate
                }
            }
            current = candidate.superview
        }
        return nearest
    }

    /// 主窗口：侧栏所在的窗口。
    var hostWindow: NSWindow? { liveView(.sidebar)?.window ?? liveView(.quickAdd)?.window }
}

final class TourAnchorView: NSView {
    /// SwiftUI 量到的位置和大小（global 坐标），用来校验 AppKit 视图的尺寸。
    var swiftFrame: CGRect = .zero

    /// 只用来取位置，不拦鼠标。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct TourAnchorReader: NSViewRepresentable {
    let target: TourTarget
    var frame: CGRect = .zero

    func makeNSView(context: Context) -> TourAnchorView {
        let view = TourAnchorView()
        view.swiftFrame = frame
        TourGeometry.shared.register(view, target: target)
        return view
    }

    func updateNSView(_ nsView: TourAnchorView, context: Context) {
        nsView.swiftFrame = frame
        TourGeometry.shared.register(nsView, target: target)
    }
}

extension View {
    /// 标出功能导览要高亮的位置。
    func tourAnchor(_ target: TourTarget?) -> some View {
        background {
            if let target {
                GeometryReader { proxy in
                    TourAnchorReader(target: target, frame: proxy.frame(in: .global))
                }
            }
        }
    }
}

// MARK: - 摆放

enum TourLayout {
    static let cardWidth: CGFloat = 340
    /// 说明卡片窗口四周留给阴影的边距。
    static let cardInset: CGFloat = 18
    static let margin: CGFloat = 12
    static let gap: CGFloat = 16
    static let holePadding: CGFloat = 5

    /// 屏幕坐标 → 窗口内坐标（左上角原点）。
    static func local(_ screen: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: screen.minX - frame.minX, y: frame.maxY - screen.maxY, width: screen.width, height: screen.height)
    }

    /// 依次尝试右、左、下、上；都放不下或没有目标时放在中间。始终留在容器里。
    static func cardOrigin(hole: CGRect?, card: CGSize, in container: CGSize) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, margin), max(container.width - card.width - margin, margin)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, margin), max(container.height - card.height - margin, margin)) }
        let center = CGPoint(x: clampX((container.width - card.width) / 2),
                             y: clampY((container.height - card.height) / 2))
        guard let hole else { return center }
        if hole.maxX + gap + card.width <= container.width - margin {
            return CGPoint(x: clampX(hole.maxX + gap), y: clampY(hole.midY - card.height / 2))
        }
        if hole.minX - gap - card.width >= margin {
            return CGPoint(x: clampX(hole.minX - gap - card.width), y: clampY(hole.midY - card.height / 2))
        }
        if hole.maxY + gap + card.height <= container.height - margin {
            return CGPoint(x: clampX(hole.midX - card.width / 2), y: hole.maxY + gap)
        }
        if hole.minY - gap - card.height >= margin {
            return CGPoint(x: clampX(hole.midX - card.width / 2), y: hole.minY - gap - card.height)
        }
        return center
    }
}

// MARK: - 控制器：两个子窗口（遮罩、说明卡片）+ 定时取位置 + 事件监听

struct TourDebugRect: Identifiable, Equatable {
    let id: String
    let rect: CGRect
}

@MainActor
@Observable
final class TourFrameState {
    var size: CGSize = .zero
    /// 高亮区域，遮罩窗口内坐标。
    var hole: CGRect?
    var debug: [TourDebugRect] = []
    /// 点到高亮区域外时加 1，卡片晃一下。
    var nudge = 0
}

final class TourPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TourHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class TourController {
    static let shared = TourController()
    /// BIANDAN_DEBUG_TOUR=1 时把所有锚点画出来，方便核对位置。
    static let debug = ProcessInfo.processInfo.environment["BIANDAN_DEBUG_TOUR"] == "1"

    let state = TourFrameState()
    private var dimPanel: TourPanel?
    private var cardPanel: TourPanel?
    private var cardHost: NSView?
    private var ballPanel: TourPanel?
    private var timer: Timer?
    private var monitors: [Any] = []
    private weak var model: AppModel?
    /// 当前高亮区域，屏幕坐标；判断点击是否落在里面。
    private var holeOnScreen: CGRect?

    func start(model: AppModel) {
        self.model = model
        if timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { TourController.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if monitors.isEmpty { installMonitors() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        hidePanels()
        holeOnScreen = nil
        state.hole = nil
    }

    func next() {
        guard let model else { return }
        Onboarding.shared.nextStep(model: model)
    }

    func end() {
        guard let model else { return }
        Onboarding.shared.endTour(model: model)
    }

    func tryCapture() {
        guard let model else { return }
        Onboarding.shared.endTour(model: model)
        ScheduleCaptureFlow.startRegion(model: model, anchor: FloatingBallController.shared.frame)
    }

    // MARK: 定时

    private func tick() {
        let onboarding = Onboarding.shared
        guard let step = onboarding.currentStep, let model else {
            stop()
            return
        }
        guard let window = TourGeometry.shared.hostWindow, window.isVisible, !window.isMiniaturized else {
            hidePanels()
            return
        }
        let dim = dimPanel ?? makeDimPanel()
        let card = cardPanel ?? makeCardPanel()
        attach(dim, card, to: window)

        let frame = window.frame
        if dim.frame != frame { dim.setFrame(frame, display: true) }
        let bounds = CGRect(origin: .zero, size: frame.size)

        var screenHole: CGRect?
        if let target = step.target, var rect = TourGeometry.shared.screenRect(for: target) {
            if let stretch = step.stretch, let wide = TourGeometry.shared.screenRect(for: stretch) {
                // 侧栏的行：横向拉满侧栏宽度，整行都能点。
                rect = CGRect(x: wide.minX + 6, y: rect.minY, width: max(wide.width - 12, rect.width), height: rect.height)
            }
            screenHole = rect.insetBy(dx: -TourLayout.holePadding, dy: -TourLayout.holePadding)
        }
        var localHole: CGRect?
        if let screenHole {
            let clipped = TourLayout.local(screenHole, in: frame).intersection(bounds)
            if !clipped.isNull && clipped.width >= 4 && clipped.height >= 4 { localHole = clipped }
        }
        // 浮窗球在主窗口之外的独立面板里：不挖洞、不放行主窗口点击，单独画一圈光环，卡片靠着它摆。
        var placementHole = localHole
        if step.target == .floatingBall, let screenHole {
            localHole = nil
            placementHole = TourLayout.local(screenHole, in: frame)
            showBallRing(screenHole)
        } else {
            hideBallRing()
        }
        holeOnScreen = localHole == nil ? nil : screenHole
        if state.size != frame.size { state.size = frame.size }
        if state.hole != localHole { state.hole = localHole }
        if Self.debug { updateDebug(frame: frame) }

        let fitting = cardHost?.fittingSize ?? .zero
        let inset = TourLayout.cardInset
        let cardSize = CGSize(width: TourLayout.cardWidth, height: max(fitting.height - inset * 2, 120))
        let origin = TourLayout.cardOrigin(hole: placementHole, card: cardSize, in: frame.size)
        let cardFrame = CGRect(x: frame.minX + origin.x, y: frame.maxY - origin.y - cardSize.height,
                               width: cardSize.width, height: cardSize.height).insetBy(dx: -inset, dy: -inset)
        if card.frame != cardFrame { card.setFrame(cardFrame, display: true) }

        onboarding.checkAction(model: model)
    }

    private func updateDebug(frame: CGRect) {
        let rects: [TourDebugRect] = TourTarget.allCases.compactMap { target in
            TourGeometry.shared.screenRect(for: target).map { rect in
                let mark = TourGeometry.shared.converted.contains(target) ? "*" : ""
                return TourDebugRect(id: target.rawValue + mark, rect: TourLayout.local(rect, in: frame))
            }
        }
        if state.debug != rects { state.debug = rects }
    }

    // MARK: 窗口

    private func makePanel(ignoresMouse: Bool) -> TourPanel {
        let panel = TourPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = ignoresMouse
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        return panel
    }

    private func makeDimPanel() -> TourPanel {
        let panel = makePanel(ignoresMouse: true)
        panel.contentView = NSHostingView(rootView: TourDimView(state: state))
        dimPanel = panel
        return panel
    }

    private func makeCardPanel() -> TourPanel {
        let panel = makePanel(ignoresMouse: false)
        let host = TourHostingView(rootView: TourCardHost(state: state))
        panel.contentView = host
        cardHost = host
        cardPanel = panel
        return panel
    }

    private func attach(_ dim: TourPanel, _ card: TourPanel, to window: NSWindow) {
        var reordered = false
        for panel in [dim, card] where panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            reordered = true
        }
        if !dim.isVisible { dim.orderFront(nil); reordered = true }
        if !card.isVisible { card.orderFront(nil); reordered = true }
        if reordered { card.order(.above, relativeTo: dim.windowNumber) }
    }

    private func hidePanels() {
        for panel in [dimPanel, cardPanel].compactMap({ $0 }) {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        hideBallRing()
    }

    private func showBallRing(_ rect: CGRect) {
        let panel = ballPanel ?? makeBallPanel()
        let frame = rect.insetBy(dx: -8, dy: -8)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hideBallRing() {
        ballPanel?.orderOut(nil)
    }

    /// 浮窗球在 .floating 层：光环放在它上面一层，不接收鼠标，点击照常落到球上。
    private func makeBallPanel() -> TourPanel {
        let panel = makePanel(ignoresMouse: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TourBallRing())
        ballPanel = panel
        return panel
    }

    // MARK: 事件

    private func installMonitors() {
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            let pass = MainActor.assumeIsolated { TourController.shared.shouldPassMouse(event) }
            return pass ? event : nil
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let pass = MainActor.assumeIsolated { TourController.shared.shouldPassKey(event) }
            return pass ? event : nil
        }
        monitors = [mouse, keys].compactMap { $0 }
    }

    /// 只放行落在高亮区域里、而且这一步需要用户操作的左键点击。
    private func shouldPassMouse(_ event: NSEvent) -> Bool {
        let onboarding = Onboarding.shared
        guard onboarding.isTouring, let window = event.window else { return true }
        if window === cardPanel { return true }
        guard window === TourGeometry.shared.hostWindow else { return true }
        let point = window.convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin
        let wantsClick = onboarding.currentStep?.action != nil && !onboarding.stepCompleted
        if wantsClick, event.type == .leftMouseDown, let hole = holeOnScreen, hole.contains(point) { return true }
        state.nudge += 1
        return false
    }

    private func shouldPassKey(_ event: NSEvent) -> Bool {
        let onboarding = Onboarding.shared
        guard onboarding.isTouring, let model else { return true }
        if event.keyCode == 53 {
            onboarding.endTour(model: model)
            return false
        }
        // 正在输入文字（例如快速添加）时不拦截。
        if NSApp.keyWindow?.firstResponder is NSText { return true }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return true }
        switch event.keyCode {
        case 36, 76, 124:
            onboarding.nextStep(model: model)
            return false
        case 123:
            onboarding.previousStep()
            return false
        default:
            return true
        }
    }
}

// MARK: - 遮罩

private struct TourDimShape: Shape {
    let hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10)) }
        return path
    }
}

struct TourDimView: View {
    let state: TourFrameState
    @State private var pulse = false

    private var showPointer: Bool {
        let onboarding = Onboarding.shared
        return onboarding.currentStep?.action != nil && !onboarding.stepCompleted
    }

    var body: some View {
        let size = state.size
        let hole = state.hole
        ZStack(alignment: .topLeading) {
            TourDimShape(hole: hole)
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
            if let hole {
                ring(hole)
                if showPointer { pointer(hole, size: size) }
            }
            if TourController.debug {
                ForEach(state.debug) { item in TourDebugBox(item: item) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func ring(_ hole: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let glow: Double = pulse ? 0.25 : 0.6
        let width: CGFloat = pulse ? 8 : 4
        return ZStack {
            shape.stroke(Theme.accent.opacity(glow), lineWidth: width)
            shape.stroke(Theme.accent, lineWidth: 2.5)
        }
        .frame(width: hole.width, height: hole.height)
        .offset(x: hole.minX, y: hole.minY)
    }

    /// 高亮区域下方（放不下就上方）的「点这里」。
    private func pointer(_ hole: CGRect, size: CGSize) -> some View {
        let below = hole.maxY + 44 <= size.height
        let y: CGFloat = below ? hole.maxY + 8 : hole.minY - 36
        let x: CGFloat = min(max(hole.midX - 38, 8), max(size.width - 90, 8))
        let bounce: CGFloat = pulse ? (below ? 4 : -4) : 0
        return HStack(spacing: 5) {
            Image(systemName: "hand.tap.fill").font(.system(size: 13, weight: .bold))
            Text("点这里").font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.accent))
        .shadow(color: Color.black.opacity(0.25), radius: 4, y: 2)
        .fixedSize()
        .offset(x: x, y: y + bounce)
    }
}

private struct TourDebugBox: View {
    let item: TourDebugRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().stroke(Color.red, lineWidth: 1.5)
            Text(verbatim: item.id)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .background(Color.red)
        }
        .frame(width: item.rect.width, height: item.rect.height)
        .offset(x: item.rect.minX, y: item.rect.minY)
    }
}

/// 浮窗球周围跳动的光环。
struct TourBallRing: View {
    @State private var pulse = false

    var body: some View {
        let glow: Double = pulse ? 0.2 : 0.65
        let width: CGFloat = pulse ? 8 : 4
        ZStack {
            Circle().stroke(Theme.accent.opacity(glow), lineWidth: width)
            Circle().stroke(Theme.accent, lineWidth: 2.5)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - 说明卡片

struct TourCardHost: View {
    let state: TourFrameState

    var body: some View {
        let onboarding = Onboarding.shared
        if let index = onboarding.tourIndex, let step = onboarding.currentStep {
            let last = index == Onboarding.tourSteps.count - 1
            TourCard(step: step, index: index, count: Onboarding.tourSteps.count,
                     completed: onboarding.stepCompleted, nudge: state.nudge,
                     onBack: { onboarding.previousStep() },
                     onNext: { TourController.shared.next() },
                     onSkip: { TourController.shared.end() },
                     onTry: last ? { TourController.shared.tryCapture() } : nil)
                .frame(width: TourLayout.cardWidth)
                .padding(TourLayout.cardInset)
        }
    }
}

private struct TourShake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct TourCard: View {
    let step: TourStep
    let index: Int
    let count: Int
    let completed: Bool
    let nudge: Int
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void
    let onTry: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 11) {
            header
            Text(verbatim: step.body)
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0x4A453C))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let prompt = step.prompt { TourPromptRow(prompt: prompt, completed: completed) }
            if let tip = step.tip {
                Label {
                    Text(verbatim: tip)
                } icon: {
                    Image(systemName: "keyboard")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(hex: 0x6B5A1E))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.selectionFill))
            }
            TourProgressDots(index: index, count: count)
            buttons
        }
        .padding(16)
        .background(shape.fill(Theme.card))
        .overlay(shape.stroke(Theme.line))
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 5)
        .modifier(TourShake(animatableData: CGFloat(nudge)))
        .animation(.linear(duration: 0.35), value: nudge)
        .animation(.easeInOut(duration: 0.2), value: completed)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: step.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(step.tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(step.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "功能导览 · \(index + 1) / \(count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.subtext)
                Text(verbatim: step.title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.text)
            }
            Spacer(minLength: 0)
            Text("Esc 退出 · ← →")
                .font(.system(size: 10))
                .foregroundStyle(Theme.fieldName)
        }
    }

    private var buttons: some View {
        let last = index == count - 1
        let waiting = step.prompt != nil && !completed
        return HStack(spacing: 8) {
            Button("跳过导览", action: onSkip)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
            Spacer(minLength: 0)
            if let onTry {
                Button("试一试框选识别", action: onTry).buttonStyle(.themed)
            }
            if index > 0 {
                Button("上一步", action: onBack).buttonStyle(.themed)
            }
            if waiting {
                Button(last ? "完成导览" : "跳过这步", action: onNext).buttonStyle(.themed)
            } else {
                Button(last ? "完成" : "下一步", action: onNext).buttonStyle(.themedPrimary)
            }
        }
    }
}

/// 「请你点一下…」；完成后变成「做得好」。
private struct TourPromptRow: View {
    let prompt: String
    let completed: Bool

    var body: some View {
        let icon: String = completed ? "checkmark.circle.fill" : "hand.point.up.left.fill"
        let color: Color = completed ? Theme.done : Theme.accent
        let fill: Color = completed ? Theme.done.opacity(0.12) : Theme.selectionFill
        let text: String = completed ? "做得好！马上进入下一步…" : prompt
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text(verbatim: text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(fill))
        .overlay(shape.stroke(color.opacity(0.45)))
    }
}

struct TourProgressDots: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { item in
                TourDot(state: item == index ? 0 : (item < index ? 1 : 2))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: index)
    }
}

private struct TourDot: View {
    /// 0 当前，1 已过，2 未到。
    let state: Int

    var body: some View {
        let color: Color = state == 0 ? Theme.accent : (state == 1 ? Theme.accent.opacity(0.45) : Theme.line)
        let width: CGFloat = state == 0 ? 16 : 6
        Capsule().fill(color).frame(width: width, height: 6)
    }
}
