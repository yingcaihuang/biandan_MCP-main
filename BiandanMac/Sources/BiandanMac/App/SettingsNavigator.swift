import AppKit
import SwiftUI

/// 设置页里可以直接跳到的位置。
enum SettingsAnchor: String {
    case ai = "settings-ai"
}

/// 从别处（例如识别日程的确认卡片）打开设置，并跳到指定分区和位置。
@MainActor
enum SettingsNavigator {
    /// 记下要去的分区和位置，并把便单切到前台。之后由调用方执行 openSettings()。
    static func prepare(model: AppModel, pane: SettingsPane = .advanced, anchor: SettingsAnchor?) {
        UserDefaults.standard.set(pane.rawValue, forKey: "biandan.settingsPane")
        model.settingsAnchor = anchor
        NSApp.activate()
    }

    /// 在主窗口之外的浮动面板里调用 openSettings() 可能不生效：稍等片刻，设置窗口还没出来就改用菜单命令打开。
    static func ensureOpened() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !settingsWindowVisible else { return }
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static var settingsWindowVisible: Bool {
        NSApp.windows.contains { window in
            window.isVisible && (window.identifier?.rawValue.contains("Settings") ?? false)
        }
    }
}
