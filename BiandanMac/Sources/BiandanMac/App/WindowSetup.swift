import AppKit
import SwiftUI

/// 窗口出现时做一次设置：铺满屏幕可用区域（不进入全屏）、允许拖动改变大小。
struct WindowSetup: NSViewRepresentable {
    var maximize = false
    var resizable = false

    func makeNSView(context: Context) -> NSView {
        let view = WindowSetupView()
        view.maximize = maximize
        view.resizable = resizable
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class WindowSetupView: NSView {
    var maximize = false
    var resizable = false
    private weak var configured: NSWindow?

    /// 只用来拿到窗口，不参与命中测试：否则它在 AppKit 层叠到分栏上面时会吞掉所有鼠标点击
    /// （按钮、日期 / 时刻选择点不动，键盘照常，回车能保存）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== configured else { return }
        configured = window
        if resizable { window.styleMask.insert(.resizable) }
        guard maximize else { return }
        // 等 SwiftUI 按默认尺寸摆好窗口后再铺满，避免被它的布局覆盖。
        DispatchQueue.main.async { [weak window] in
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true, animate: false)
        }
    }
}
