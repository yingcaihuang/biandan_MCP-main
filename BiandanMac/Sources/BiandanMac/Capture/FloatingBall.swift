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
}

final class FloatingBallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingBallController {
    static let shared = FloatingBallController()
    private static let originKey = "biandan.floatingBall.origin"
    static let size: CGFloat = 56

    private var panel: FloatingBallPanel?
    private let state = FloatingBallState()
    private weak var model: AppModel?
    private var screenObserver: NSObjectProtocol?

    /// 球当前的位置（隐藏时为 nil），确认卡片据此摆在球旁边。
    var frame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    func apply(model: AppModel) {
        self.model = model
        if model.showFloatingBall { show() } else { panel?.orderOut(nil) }
    }

    func setBusy(_ busy: Bool) {
        state.busy = busy
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

    private func showMenu(_ event: NSEvent, in view: NSView) {
        guard let model else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("框选识别日程") { [weak self] in self?.captureRegion() })
        menu.addItem(ClosureMenuItem("识别剪贴板里的日程") { [weak self] in
            ScheduleCaptureFlow.fromClipboard(model: model, anchor: self?.frame)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("全局快速添加…") { QuickAddPanelController.shared.show(model: model) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("隐藏小球") { model.showFloatingBall = false })
        let tip = NSMenuItem(title: "隐藏后可在「设置 → 通用」里重新打开", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
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
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent, NSView) -> Void)?
    var onMoved: (() -> Void)?
    var onDropText: ((String) -> Void)?
    var onDropImage: ((CGImage) -> Void)?

    private let state: FloatingBallState
    private var pressLocation: NSPoint?
    private var pressOrigin: NSPoint = .zero
    private var dragging = false

    init(frame: NSRect, state: FloatingBallState) {
        self.state = state
        super.init(frame: frame)
        let hosting = NSHostingView(rootView: FloatingBallVisual(state: state).preferredColorScheme(.light))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.string, .fileURL, .tiff, .png])
        toolTip = "单击框选识别日程 · 右键更多 · 可把文字或图片拖进来"
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

    override func mouseEntered(with event: NSEvent) { state.hovering = true }
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
            onMoved?()
        } else if wasPressed {
            onClick?()
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

struct FloatingBallVisual: View {
    let state: FloatingBallState

    var body: some View {
        let lit = state.targeted || state.hovering
        let border: Color = lit ? Theme.accent : Theme.line
        let tint: Color = Theme.accent.opacity(lit ? 0.28 : 0.16)
        let scale: CGFloat = state.targeted ? 1.12 : (state.pressed ? 0.92 : 1)
        ZStack {
            icon
        }
        .frame(width: 44, height: 44)
        .floatingSurface(Circle(), border: border, shadowRadius: 4, shadowOpacity: 0.18,
                         glassTint: tint, glassBorder: lit)
        .scaleEffect(scale)
        .animation(.easeOut(duration: 0.12), value: scale)
        .frame(width: FloatingBallController.size, height: FloatingBallController.size)
    }

    @ViewBuilder
    private var icon: some View {
        if state.busy {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
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
