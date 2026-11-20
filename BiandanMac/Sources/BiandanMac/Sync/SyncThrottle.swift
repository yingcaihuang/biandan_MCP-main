import Foundation

/// 同步是谁触发的。
enum SyncReason: Sendable {
    /// 用户点「立即同步」、登录后首次同步。
    case manual
    /// 启动时同步。
    case startup
    /// 定时、切回窗口等自动触发。
    case automatic
}

/// 全量拉取节流。云端没有增量接口，每次同步都要分页拉完四张表，数据多时请求几十次。
/// - 手动 / 启动：总是执行；只有云端要求稍后再试（429 Retry-After）时等待。
/// - 自动：距上次成功至少 1 分钟（本地超过 3000 条时 3 分钟）；连续失败按 30 秒起指数退避，最长 30 分钟。
struct SyncThrottle: Equatable, Sendable {
    static let minimumAutoInterval: TimeInterval = 60
    static let largeDataset = 3000
    static let largeMultiplier: Double = 3
    static let baseBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 1800

    enum Decision: Equatable {
        case allow
        /// 自动同步静默跳过。
        case skip
        /// 云端要求等待这么多秒。
        case wait(TimeInterval)
    }

    var lastSuccess: Date?
    var lastFailure: Date?
    var consecutiveFailures = 0
    var retryNotBefore: Date?
    var lastRecordCount = 0

    var autoInterval: TimeInterval {
        lastRecordCount >= Self.largeDataset ? Self.minimumAutoInterval * Self.largeMultiplier : Self.minimumAutoInterval
    }

    /// 当前的失败退避时长；没有失败时为 0。
    var backoff: TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        let exponent = Double(min(consecutiveFailures - 1, 16))
        return min(Self.baseBackoff * pow(2, exponent), Self.maxBackoff)
    }

    func decide(_ reason: SyncReason, now: Date = Date()) -> Decision {
        if let until = retryNotBefore, until > now {
            return reason == .automatic ? .skip : .wait(until.timeIntervalSince(now))
        }
        guard reason == .automatic else { return .allow }
        if consecutiveFailures > 0, let failed = lastFailure, now.timeIntervalSince(failed) < backoff {
            return .skip
        }
        if let success = lastSuccess, now.timeIntervalSince(success) < autoInterval {
            return .skip
        }
        return .allow
    }

    mutating func recordSuccess(at date: Date, records: Int) {
        lastSuccess = date
        lastFailure = nil
        consecutiveFailures = 0
        retryNotBefore = nil
        lastRecordCount = records
    }

    mutating func recordFailure(at date: Date, retryAfter: TimeInterval?) {
        consecutiveFailures += 1
        lastFailure = date
        if let retryAfter, retryAfter > 0 {
            retryNotBefore = date.addingTimeInterval(min(retryAfter, Self.maxBackoff))
        }
    }
}
