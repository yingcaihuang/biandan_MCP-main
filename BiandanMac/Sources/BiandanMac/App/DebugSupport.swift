import Foundation

/// 排查用开关。正式版恒为 false。
enum DebugFlags {
    /// BIANDAN_DEBUG_OFFLINE=1：不读钥匙串、不联网、不启 MCP、不排提醒，只用本地库进主界面。
    /// 用于自己启动、测量界面布局：每次 swift build 签名都不同，读钥匙串会弹授权框。
    static var offline: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BIANDAN_DEBUG_OFFLINE"] == "1"
        #else
        return false
        #endif
    }
}

#if DEBUG
extension AppModel {
    /// 仅 Debug：设了环境变量 BIANDAN_DEBUG_SELECT=标题片段 时，启动后自动选中第一个匹配的待办并打开检查器，
    /// 方便不用手动点击就复现、测量检查器的布局。只改选中状态，不写数据。
    @MainActor
    func debugAutoSelect() async {
        guard let key = ProcessInfo.processInfo.environment["BIANDAN_DEBUG_SELECT"], !key.isEmpty else { return }
        for _ in 0..<60 {
            if let item = snapshot.items(OccurrenceQuery()).first(where: { $0.task.taskTitle.contains(key) }) {
                selectedFocusID = nil
                selectedOccurrenceID = item.id
                showInspector = true
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
#endif
