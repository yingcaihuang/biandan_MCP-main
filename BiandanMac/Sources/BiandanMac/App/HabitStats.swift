import Foundation

/// 一个习惯的打卡汇总。
struct HabitSummary: Identifiable {
    let task: TaskDef
    /// 日期覆盖今天的那一期（优先待完成），没有表示今天不用打卡。
    let current: OccurrenceItem?
    /// 有打卡（完成）记录的日期。
    let checkedDays: Set<LocalDate>
    /// 截至今天的连续打卡天数；今天还没打卡时从昨天往回数。
    let streak: Int
    let best: Int
    /// 打卡记录：已完成的实例，按完成时间倒序。
    let records: [OccurrenceItem]

    var id: String { task.id1 }
    var total: Int { records.count }
    var checkedToday: Bool { current?.status == .completed }
    var needsCheckIn: Bool { current?.status == .pending }
}

enum HabitStats {
    static func summaries(_ items: [OccurrenceItem], today: LocalDate) -> [HabitSummary] {
        let grouped = Dictionary(grouping: items.filter { $0.task.isHabit }) { $0.task.id1 }
        return grouped.values.compactMap { rows -> HabitSummary? in
            guard let task = rows.first?.task else { return nil }
            let records = rows.filter { $0.status == .completed }.sorted {
                ($0.occurrence.completedAt ?? "") > ($1.occurrence.completedAt ?? "")
            }
            let days = Set(records.compactMap { $0.occurrence.completedDate })
            let current = rows.filter { $0.occurrence.overlaps(today, today) }.min { rank($0) < rank($1) }
            return HabitSummary(task: task, current: current, checkedDays: days,
                                streak: streak(days: days, today: today), best: bestStreak(days: days),
                                records: records)
        }
        .sorted { lhs, rhs in
            if lhs.needsCheckIn != rhs.needsCheckIn { return lhs.needsCheckIn }
            if lhs.task.taskTitle != rhs.task.taskTitle { return lhs.task.taskTitle < rhs.task.taskTitle }
            return lhs.task.id1 < rhs.task.id1
        }
    }

    private static func rank(_ item: OccurrenceItem) -> Int {
        switch item.status {
        case .pending: return 0
        case .completed: return 1
        case .abandoned: return 2
        }
    }

    static func streak(days: Set<LocalDate>, today: LocalDate) -> Int {
        var day = days.contains(today) ? today : today.adding(days: -1)
        var count = 0
        while days.contains(day) {
            count += 1
            day = day.adding(days: -1)
        }
        return count
    }

    static func bestStreak(days: Set<LocalDate>) -> Int {
        var best = 0, run = 0
        var previous: LocalDate?
        for day in days.sorted() {
            if let previous, previous.days(to: day) == 1 { run += 1 } else { run = 1 }
            best = max(best, run)
            previous = day
        }
        return best
    }
}

extension AppModel {
    var habitSummaries: [HabitSummary] {
        var query = OccurrenceQuery(status: .all)
        query.habit = true
        query.text = searchText
        return HabitStats.summaries(snapshot.items(query), today: today)
    }
}
