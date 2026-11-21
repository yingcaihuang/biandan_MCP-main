import AppKit
import SwiftUI

/// 把所在窗口设为浮动（置顶）或普通层级。作为不可见背景视图挂在窗口内容上。
struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
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
