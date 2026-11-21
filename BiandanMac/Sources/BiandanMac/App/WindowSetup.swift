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

private final class WindowSetupView: NSView {
    var maximize = false
    var resizable = false
    private weak var configured: NSWindow?

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
