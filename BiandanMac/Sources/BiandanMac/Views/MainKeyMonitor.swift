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

/// 从 NSEvent 取出的按键信息（都是可跨线程传递的值，NSEvent 本身不是 Sendable）。
struct KeyPress: Sendable {
    let keyCode: UInt16
    let flagsRaw: UInt
    let characters: String?
    let windowNumber: Int

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        flagsRaw = event.modifierFlags.rawValue
        characters = event.charactersIgnoringModifiers
        windowNumber = event.windowNumber
    }

    /// 去掉数字键盘、fn、大写锁定后的修饰键。
    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: flagsRaw).intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }
}

final class KeyMonitorView: NSView {
    weak var model: AppModel?
    private var monitor: Any?

    /// 只监听按键，不参与命中测试，鼠标点击全部交给 SwiftUI 内容。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let press = KeyPress(event)
            // 本地监听在主线程回调。
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, press.windowNumber == window.windowNumber else { return false }
                return self.handle(press, in: window)
            }
            return handled ? nil : event
        }
    }

    private enum Key {
        static let space: UInt16 = 49, delete: UInt16 = 51, forwardDelete: UInt16 = 117
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, escape: UInt16 = 53
        static let down: UInt16 = 125, up: UInt16 = 126
    }

    /// 返回 true 表示已处理（吞掉按键）。
    private func handle(_ press: KeyPress, in window: NSWindow) -> Bool {
        guard let model, model.authState == .signedIn else { return false }
        if window.attachedSheet != nil || !window.sheets.isEmpty { return false }
        if let responder = window.firstResponder,
           responder is NSText || responder is NSTextField || responder is NSTableView {
            return false
        }
        let flags = press.flags
        switch press.keyCode {
        case Key.down, Key.up:
            guard flags.isSubset(of: [.shift]), !model.keyboardOrder.isEmpty else { return false }
            model.moveSelection(by: press.keyCode == Key.down ? 1 : -1, extend: flags.contains(.shift))
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
            guard flags.isEmpty, !model.multiSelection.isEmpty || model.selectionMode else { return false }
            model.exitSelectionMode()
            return true
        default:
            if flags == [.command], press.characters?.lowercased() == "a", !model.keyboardOrder.isEmpty {
                model.selectAllVisible()
                return true
            }
            return false
        }
    }
}
