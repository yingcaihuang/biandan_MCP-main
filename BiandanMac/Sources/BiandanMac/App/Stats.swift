import Foundation

/// 统计页的时间范围。超过一个月按周汇总。
enum StatsRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7, month = 30, quarter = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .quarter: return "近 90 天"
        }
    }

    var bucketDays: Int { self == .quarter ? 7 : 1 }
}

/// 趋势图的一根柱子：一天或一周。
struct StatsBucket: Identifiable, Hashable, Sendable {
    let start: LocalDate
    var completed: Int
    var focusMinutes: Double

    var id: LocalDate { start }
}

struct StatsQuadrantRow: Identifiable, Hashable, Sendable {
    let quadrant: Quadrant
    let count: Int
    var id: Int { quadrant.rawValue }
}

struct StatsListRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let count: Int
}

struct StatsSummary: Sendable {
    let range: StatsRange
    let start: LocalDate
    let end: LocalDate
    let buckets: [StatsBucket]
    /// 范围内完成的实例数（按完成日期）。
    let completed: Int
    /// 范围内到期（结束日期落在范围里）的实例数，及其中已完成、已放弃的数量。
    let dueTotal: Int
    let dueCompleted: Int
    let dueAbandoned: Int
    /// 当前逾期的待办实例。
    let overdue: Int
    let focusMinutes: Double
    let focusCount: Int
    /// 待完成任务按象限、分类分布（按任务去重）。
    let quadrants: [StatsQuadrantRow]
    let lists: [StatsListRow]

    var days: Int { start.days(to: end) + 1 }
    var onTimeRate: Double? { dueTotal == 0 ? nil : Double(dueCompleted) / Double(dueTotal) }
    var dailyAverage: Double { days > 0 ? Double(completed) / Double(days) : 0 }
}

/// 由快照计算统计（纯计算）。
enum StatsCalculator {
    static let listLimit = 8

    static func summary(_ snapshot: DataSnapshot, range: StatsRange, today: LocalDate, weekStart: Int) -> StatsSummary {
        let end = today
        var start = today.adding(days: -(range.rawValue - 1))
        // 按周汇总时，从那一周的第一天开始，每根柱子正好一周。
        if range.bucketDays == 7 {
            start = start.adding(days: -floorMod(start.weekday - weekStart, 7))
        }
        var buckets: [StatsBucket] = []
        var day = start
        while day <= end {
            buckets.append(StatsBucket(start: day, completed: 0, focusMinutes: 0))
            day = day.adding(days: range.bucketDays)
        }
        func bucketIndex(_ value: LocalDate) -> Int? {
            guard value >= start, value <= end else { return nil }
            return start.days(to: value) / range.bucketDays
        }

        var query = OccurrenceQuery(status: .all)
        query.includeUndated = true
        let items = snapshot.items(query)

        var completed = 0
        for item in items {
            if let done = item.occurrence.completedDate, let index = bucketIndex(done) {
                buckets[index].completed += 1
                completed += 1
            }
        }

        let focus = snapshot.focus(from: start, to: end)
        var focusMinutes = 0.0
        for record in focus {
            focusMinutes += record.minutes
            if let date = record.localDate, let index = bucketIndex(date) {
                buckets[index].focusMinutes += record.minutes
            }
        }

        let due = items.filter { item in
            guard !item.task.undated, let last = item.occurrence.endDate ?? item.occurrence.startDate else { return false }
            return last >= start && last <= end
        }

        let pending = items.filter { $0.status == .pending }
        let overdue = pending.filter { $0.isOverdue(today: today) }.count

        let quadrants = Quadrant.allCases.map { quadrant in
            StatsQuadrantRow(quadrant: quadrant,
                             count: Set(pending.filter { $0.task.quadrant == quadrant }.map(\.task.id1)).count)
        }
        let byList = Dictionary(grouping: pending) { $0.task.id3 }
        let lists = byList.map { id, rows in
            StatsListRow(id: id, name: snapshot.list(id)?.displayName ?? "未分类", count: Set(rows.map(\.task.id1)).count)
        }
        .sorted { ($0.count, $1.name) > ($1.count, $0.name) }

        return StatsSummary(range: range, start: start, end: end, buckets: buckets, completed: completed,
                            dueTotal: due.count,
                            dueCompleted: due.filter { $0.status == .completed }.count,
                            dueAbandoned: due.filter { $0.status == .abandoned }.count,
                            overdue: overdue, focusMinutes: focusMinutes, focusCount: focus.count,
                            quadrants: quadrants, lists: Array(lists.prefix(listLimit)))
    }

    /// 「2 小时 5 分」「45 分钟」
    static func durationText(_ minutes: Double) -> String {
        let total = Int(minutes)
        if total < 60 { return "\(total) 分钟" }
        return total % 60 == 0 ? "\(total / 60) 小时" : "\(total / 60) 小时 \(total % 60) 分"
    }
}
