import CryptoKit
import Foundation

/// 业务 ID（id1 / id2 / id3 / time）规则，与 Python 参考实现一致。
enum BusinessID {
    /// JavaScript 安全整数上限 2^53 - 1。
    static let maxSafe: Int64 = 9_007_199_254_740_991

    static func isValid(_ value: String) -> Bool {
        guard value.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
              let number = Int64(value) else {
            return false
        }
        return number <= maxSafe
    }

    /// 新建业务 ID，对应 Python 的 `time.time_ns() // 1000`（微秒时间戳）。
    static func generate(now: Date = Date()) -> String {
        String(Int64(now.timeIntervalSince1970 * 1_000_000))
    }

    /// 循环实例 ID：2^51 + SHA-256("task:date") 前 8 字节（大端）mod 2^51。
    static func occurrenceID(taskID: String, startDate: String) -> String {
        let digest = SHA256.hash(data: Data("\(taskID):\(startDate)".utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        let base: UInt64 = 1 << 51
        return String(base + value % base)
    }

    /// 改期循环中某一次时，脱离系列后新任务的 ID。
    static func detachedTaskID(occurrenceID: String) -> String {
        self.occurrenceID(taskID: occurrenceID, startDate: "detached")
    }
}
