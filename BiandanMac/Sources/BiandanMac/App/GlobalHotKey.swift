import AppKit
import Carbon.HIToolbox
import Foundation

/// 全局快速添加的快捷键。不用 ⌃Space / ⌃⌥Space：那是系统切换输入法的快捷键。
enum QuickAddHotKey: String, CaseIterable, Identifiable, Sendable {
    case controlOptionN, commandOptionN, controlShiftSpace, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionN: return "⌃⌥N"
        case .commandOptionN: return "⌥⌘N"
        case .controlShiftSpace: return "⌃⇧空格"
        case .off: return "关闭"
        }
    }

    /// Carbon 虚拟键码；关闭时为 nil。
    var keyCode: UInt32? {
        switch self {
        case .controlOptionN, .commandOptionN: return UInt32(kVK_ANSI_N)
        case .controlShiftSpace: return UInt32(kVK_Space)
        case .off: return nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlOptionN: return UInt32(controlKey | optionKey)
        case .commandOptionN: return UInt32(cmdKey | optionKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        case .off: return 0
        }
    }

    /// 注册结果的提示；成功为 nil。
    static func statusText(_ status: OSStatus) -> String? {
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return "这个组合已被其他 App 占用，请换一个。"
        default: return "注册全局快捷键失败（错误 \(status)），请换一个组合。"
        }
    }
}

/// 用 Carbon RegisterEventHotKey 注册全局快捷键：在任何 App 里都能触发，不需要辅助功能权限。
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 注册（先注销旧的）；返回系统状态码。
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4244_4E51), id: 1)  // 'BDNQ'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

extension AppModel {
    /// 按设置注册或注销全局快速添加快捷键，结果写进 quickAddHotKeyStatus。
    func applyQuickAddHotKey() {
        let hotKey = GlobalHotKey.shared
        hotKey.action = { [weak self] in
            guard let self else { return }
            QuickAddPanelController.shared.toggle(model: self)
        }
        guard let code = quickAddHotKey.keyCode else {
            hotKey.unregister()
            quickAddHotKeyStatus = nil
            return
        }
        quickAddHotKeyStatus = QuickAddHotKey.statusText(hotKey.register(keyCode: code, modifiers: quickAddHotKey.modifiers))
    }
}
