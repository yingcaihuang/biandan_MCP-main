import Foundation

/// 登录进度。浏览器回调页轮询它，实时显示第 3、4 步；只含状态、说明和条数，不含任何凭据。
final class LoginProgress: @unchecked Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case exchanging, syncing, done, failed
    }

    struct Counts: Sendable, Equatable {
        var lists = 0
        var tasks = 0
        var occurrences = 0
        var focus = 0
    }

    struct Snapshot: Sendable, Equatable {
        var phase: Phase
        var detail: String
        var counts: Counts?
        var error: String?
        /// 失败发生在第几步（3 换取令牌，4 首次同步）。
        var failedStep: Int?

        static let initial = Snapshot(phase: .exchanging, detail: "正在用授权码换取华为令牌…",
                                      counts: nil, error: nil, failedStep: nil)

        var isFinal: Bool { phase == .done || phase == .failed }
    }

    private let lock = NSLock()
    private var state = Snapshot.initial

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// 更新进度；进入完成或失败后不再被覆盖（迟到的同步进度消息会被忽略）。
    func update(_ phase: Phase, detail: String, counts: Counts? = nil, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !state.isFinal else { return }
        let failedStep: Int? = phase == .failed ? (state.phase == .syncing ? 4 : 3) : nil
        state = Snapshot(phase: phase, detail: detail, counts: counts, error: error, failedStep: failedStep)
    }

    func json() -> Data {
        let s = snapshot
        var object: [String: Any] = ["phase": s.phase.rawValue, "detail": s.detail]
        object["error"] = s.error ?? NSNull()
        object["failedStep"] = s.failedStep ?? NSNull()
        if let c = s.counts {
            object["counts"] = ["lists": c.lists, "tasks": c.tasks, "occurrences": c.occurrences, "focus": c.focus]
        } else {
            object["counts"] = NSNull()
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }
}
