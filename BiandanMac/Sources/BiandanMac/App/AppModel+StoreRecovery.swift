import Foundation
import os

// MARK: - 本机数据库被删后自动恢复
//
// 清理工具、手动删除可能在便单运行时删掉 biandan.sqlite。原来的连接还指着已删除的文件，读写都报
// disk I/O error，同步一直失败。同步前、重新读取本机数据前、窗口重新激活时检查一次：文件没了（或被换成
// 别的文件）就重新建一个空库，再从云端完整拉一遍。云端是全量拉取，日程不会丢；还没写到云端的排队修改
// 也存在这个库里，会跟着丢失，所以提示里写明。

@MainActor
extension AppModel {
    static let storeLogger = Logger(subsystem: "ai.racore.BiandanMac", category: "store")

    /// 数据库文件被删时重新建库并返回 true，调用方接着从云端重新拉取。
    @discardableResult
    func recoverStoreIfDeleted() -> Bool {
        do {
            guard try store.reopenIfDeleted() else { return false }
        } catch {
            Self.storeLogger.error("本机数据库被删除，重新建立失败：\(error.localizedDescription, privacy: .public)")
            operationError = "本机数据库文件被删除，重新建立失败：\(error.localizedDescription)。请退出便单后重新打开。"
            return false
        }
        Self.storeLogger.error("本机数据库文件被删除，已重新建立，从云端重新下载")
        operationError = "本机数据库文件被删除了（可能是清理工具或手动删除），已重新建立，正在从云端重新下载日程。如果有还没写到云端的修改，需要重新做一次。"
        refreshOutboxCounts()
        return true
    }
}
