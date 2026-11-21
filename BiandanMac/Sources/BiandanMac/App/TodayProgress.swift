import Foundation

/// 今日完成率：日期覆盖今天的执行实例中已完成的比例（不含已放弃和无日期）。
struct TodayProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    var pending: Int { total - done }
    var ratio: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var percentText: String { "\(Int((ratio * 100).rounded()))%" }

    static func make(_ items: [OccurrenceItem]) -> TodayProgress {
        let relevant = items.filter { $0.status != .abandoned && !$0.task.undated }
        let done = relevant.filter { $0.status == .completed }.count
        return TodayProgress(done: done, total: relevant.count)
    }
}

enum Greeting {
    static func text(hour: Int) -> String {
        switch hour {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        default: return "晚上好"
        }
    }

    static func subtitle(_ progress: TodayProgress) -> String {
        if progress.total == 0 { return "今天还没有安排，享受轻松的一天" }
        if progress.pending == 0 { return "今天的 \(progress.total) 项待办都完成了" }
        return "今天还有 \(progress.pending) 项待办，已完成 \(progress.done) 项"
    }
}

extension AppModel {
    var todayProgress: TodayProgress {
        let query = OccurrenceQuery(start: today, end: today, status: .all)
        return TodayProgress.make(snapshot.items(query))
    }
}
