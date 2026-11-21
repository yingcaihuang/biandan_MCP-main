import AppKit
import SwiftUI

/// 主窗口的键盘操作。用本地按键监听而不是菜单快捷键：不带修饰键的菜单快捷键会抢走输入框里的空格和方向键。
/// 只处理主窗口自己的按键；焦点在输入框或侧栏、窗口上有弹窗时一律放行。
struct MainKeyMonitor: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView(frame: .zero)
        view.model = model
        return view
    }

    func updateNSView(_ nsView: KeyMonitorView, context: Context) {
        nsView.model = model
    }
}

final class KeyMonitorView: NSView {
    weak var model: AppModel?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window else { return event }
                return self.handle(event, in: window) ? nil : event
            }
        }
    }

    private enum Key {
        static let space: UInt16 = 49, delete: UInt16 = 51, forwardDelete: UInt16 = 117
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53
        static let down: UInt16 = 125, up: UInt16 = 126
    }

    /// 返回 true 表示已处理（吞掉按键）。
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let model, model.authState == .signedIn else { return false }
        if window.attachedSheet != nil || !window.sheets.isEmpty { return false }
        if let responder = window.firstResponder,
           responder is NSText || responder is NSTextField || responder is NSTableView {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch event.keyCode {
        case Key.down, Key.up:
            guard flags.isSubset(of: [.shift]), !model.keyboardOrder.isEmpty else { return false }
            model.moveSelection(by: event.keyCode == Key.down ? 1 : -1, extend: flags.contains(.shift))
            return true
        case Key.space:
            guard flags.isEmpty, model.hasKeyboardTarget else { return false }
            Task { await model.keyboardToggleCompletion() }
            return true
        case Key.delete, Key.forwardDelete:
            guard flags.isSubset(of: [.command]), model.hasKeyboardTarget else { return false }
            model.keyboardDelete()
            return true
        case Key.returnKey, Key.enter:
            guard flags.isEmpty, model.multiSelection.isEmpty, model.selectedItem != nil else { return false }
            model.keyboardEditTitle()
            return true
        case Key.escape:
            guard flags.isEmpty, !model.multiSelection.isEmpty else { return false }
            model.clearMultiSelection()
            return true
        default:
            if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "a",
               !model.keyboardOrder.isEmpty {
                model.selectAllVisible()
                return true
            }
            return false
        }
    }
}
