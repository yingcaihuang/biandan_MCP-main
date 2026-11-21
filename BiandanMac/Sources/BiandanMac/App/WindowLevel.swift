import AppKit
import SwiftUI

/// 只用来拿到所在窗口的辅助视图：不参与命中测试，鼠标点击、悬停、拖动全部交给 SwiftUI 内容。
/// 挂在窗口上的 NSViewRepresentable 辅助视图都要用它（或同样重写 hitTest），
/// 否则它在 AppKit 层叠到分栏上面时会吞掉点击：按钮和日期 / 时刻选择点不动，键盘照常。
class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 把所在窗口设为浮动（置顶）或普通层级。作为不可见背景视图挂在窗口内容上。
struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        let floating = self.floating
        // 视图刚创建时还没加入窗口，下一轮主线程再设置。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let level: NSWindow.Level = floating ? .floating : .normal
            if window.level != level { window.level = level }
            // 置顶时在所有桌面空间都可见，避免切换桌面后窗口消失。
            if floating {
                window.collectionBehavior.insert(.canJoinAllSpaces)
            } else {
                window.collectionBehavior.remove(.canJoinAllSpaces)
            }
        }
    }
}
