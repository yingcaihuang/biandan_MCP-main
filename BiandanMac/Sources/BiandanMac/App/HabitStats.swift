import Foundation

/// 一个习惯的打卡汇总。
struct HabitSummary: Identifiable {
    let task: TaskDef
    /// 日期覆盖今天的那一期（优先待完成），没有表示今天不用打卡。
    let current: OccurrenceItem?
    /// 有打卡（完成）记录的日期。
    let checkedDays: Set<LocalDate>
    /// 截至今天连续完成的期数（按排期的执行实例算，今天还没打卡的那一期不算断）。
    let streak: Int
    let best: Int
    /// 连续的单位：天 / 周 / 月 / 年 / 次，跟随重复规则。
    let unit: String
    /// 打卡记录：已完成的实例，按完成时间倒序。
    let records: [OccurrenceItem]

    var id: String { task.id1 }
    var total: Int { records.count }
    var checkedToday: Bool { current?.status == .completed }
    var needsCheckIn: Bool { current?.status == .pending }
    /// 「连续天数」「连续周数」「连续次数」…
    var streakTitle: String { "连续" + unit + "数" }
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
            let runs = streaks(rows, today: today)
            return HabitSummary(task: task, current: current, checkedDays: days,
                                streak: runs.current, best: runs.best, unit: unit(for: task),
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

    /// 按排期的执行实例计算连续：只看开始日不晚于今天的实例，按日期排序。
    /// 已完成算一次；覆盖今天、还没完成的那一期跳过（还来得及打卡）；其余（错过、放弃）都算中断。
    /// 这样每天、每周、每月、只在工作日的习惯都按自己的周期计数。
    static func streaks(_ rows: [OccurrenceItem], today: LocalDate) -> (current: Int, best: Int) {
        let scheduled = rows
            .filter { !$0.task.undated && ($0.occurrence.startDate.map { $0 <= today } ?? false) }
            .sorted { ($0.occurrence.startDate ?? .minSupported, $0.id) < ($1.occurrence.startDate ?? .minSupported, $1.id) }
        func isOpen(_ item: OccurrenceItem) -> Bool {
            item.status == .pending && item.occurrence.overlaps(today, today)
        }
        var best = 0, run = 0
        for item in scheduled {
            if item.status == .completed {
                run += 1
                best = max(best, run)
            } else if !isOpen(item) {
                run = 0
            }
        }
        var current = 0
        for item in scheduled.reversed() {
            if item.status == .completed {
                current += 1
            } else if !isOpen(item) {
                break
            }
        }
        return (current, best)
    }

    /// 连续的单位：每天 → 天；每 1 周 / 月 / 年且每期只有一次 → 周 / 月 / 年；其余（工作日、隔天、一周几次等）→ 次。
    static func unit(for task: TaskDef) -> String {
        switch task.repeatSet {
        case .daily?: return "天"
        case .weeklyPeriod?: return "周"
        case .monthlyPeriod?: return "月"
        case .yearlyPeriod?: return "年"
        case .custom?:
            guard task.loopBaseNumber <= 1, task.unit.filterRaw == 0, task.loopDates.count <= 1 else { return "次" }
            switch task.unit.unit {
            case .day?: return "天"
            case .week?: return "周"
            case .month?, .lunarMonth?: return "月"
            case .year?, .lunarYear?: return "年"
            case nil: return "次"
            }
        default:
            return "次"
        }
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
