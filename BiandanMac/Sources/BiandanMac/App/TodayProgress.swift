import Foundation

/// 今日完成率 = 已完成 / (已完成 + 待完成)，不含已放弃和无日期。
/// - 已完成：今天完成的（不论原定哪天），以及原定今天、已提前完成的。
/// - 待完成：今天到期的，加上已逾期仍未完成的。以后的待办不计入。
/// 这样今天完成任何一件事（包括逾期和提前做的）圆环都会变化。
struct TodayProgress: Equatable, Sendable {
    var done: Int
    var total: Int
    /// 待完成里已逾期的数量。
    var overdue: Int = 0

    var pending: Int { total - done }
    var ratio: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var percentText: String { "\(Int((ratio * 100).rounded()))%" }

    /// `items` 传全部有日期的实例（任意状态）。
    static func make(_ items: [OccurrenceItem], today: LocalDate) -> TodayProgress {
        var done = 0, pending = 0, overdue = 0
        for item in items where !item.task.undated {
            switch item.status {
            case .completed:
                if item.occurrence.completedDate == today || item.occurrence.overlaps(today, today) { done += 1 }
            case .pending:
                if item.occurrence.overlaps(today, today) {
                    pending += 1
                } else if let end = item.occurrence.endDate, end < today {
                    pending += 1
                    overdue += 1
                }
            case .abandoned:
                break
            }
        }
        return TodayProgress(done: done, total: done + pending, overdue: overdue)
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
        if progress.overdue > 0 {
            return "今天还有 \(progress.pending) 项待办（含 \(progress.overdue) 项逾期），已完成 \(progress.done) 项"
        }
        return "今天还有 \(progress.pending) 项待办，已完成 \(progress.done) 项"
    }
}

extension AppModel {
    var todayProgress: TodayProgress {
        // 不按日期预筛（含逾期、提前完成的），由 make 按今天判断。
        return TodayProgress.make(snapshot.items(OccurrenceQuery(status: .all)), today: today)
    }
}
