import Foundation

/// 日历日视图时间轴上的一个日程块。start / end 是当天的分钟数（0–1440），跨天的在当天截断。
struct DayAgendaBlock: Identifiable {
    let item: OccurrenceItem
    let start: Int
    let end: Int
    /// 时间重叠的日程并排：第几列、这一组一共几列。
    var column = 0
    var columns = 1
    /// 从前一天开始 / 到后一天才结束。
    var continuesBefore = false
    var continuesAfter = false
    var id: String { item.id }
    /// 画出来的结束位置：太短的至少按 minMinutes 画，免得看不见。
    var displayEnd: Int { DayAgendaLayout.displayEnd(start: start, end: end) }
}

/// 日视图时间轴的排布规则（纯计算，便于测试）。
enum DayAgendaLayout {
    /// 日程块最少按这么多分钟的高度画。
    static let minMinutes = 30
    /// 时间轴至少显示 8:00–18:00，有更早、更晚的日程（或现在）时往外扩。
    static let defaultFirstHour = 8
    static let defaultLastHour = 18

    static func minutes(_ clock: LocalTime) -> Int {
        let value = clock.hour * 60 + clock.minute
        return value >= 1439 ? 1440 : value
    }

    static func minute(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func displayEnd(start: Int, end: Int) -> Int {
        min(max(end, start + minMinutes), 1440)
    }

    /// 定时日程排成块；没有具体时刻（全天、整天跨过）的单独返回，放在顶部「全天」一栏。
    static func layout(_ items: [OccurrenceItem], day: LocalDate) -> (timed: [DayAgendaBlock], allDay: [OccurrenceItem]) {
        var timed: [DayAgendaBlock] = []
        var allDay: [OccurrenceItem] = []
        for item in items where !item.task.undated && item.occurrence.overlaps(day, day) {
            let occurrence = item.occurrence
            guard let first = occurrence.startDate, let last = occurrence.endDate else { continue }
            if TimelineLayout.isAllDay(occurrence) {
                allDay.append(item)
                continue
            }
            let before = first < day
            let after = last > day
            let start: Int = before ? 0 : (occurrence.startClock.map(minutes) ?? 0)
            var end: Int = after ? 1440 : (occurrence.endClock.map(minutes) ?? start)
            if start <= 0 && end >= 1440 {
                allDay.append(item)
                continue
            }
            end = max(end, start)
            var block = DayAgendaBlock(item: item, start: min(start, 1439), end: end)
            block.continuesBefore = before
            block.continuesAfter = after
            timed.append(block)
        }
        let placed = columns(timed.map { (start: $0.start, end: $0.end) })
        for index in timed.indices {
            timed[index].column = placed[index].column
            timed[index].columns = placed[index].columns
        }
        timed.sort { ($0.start, $0.column, $0.id) < ($1.start, $1.column, $1.id) }
        return (timed, allDay)
    }

    /// 时间重叠的放进同一组并排：每个块放在最左边空出来的那列，整组的列数取这一组用到的列数。结果按输入顺序返回。
    static func columns(_ spans: [(start: Int, end: Int)]) -> [(column: Int, columns: Int)] {
        let order = spans.indices.sorted { a, b in
            let x = spans[a], y = spans[b]
            if x.start != y.start { return x.start < y.start }
            if x.end != y.end { return x.end > y.end }
            return a < b
        }
        var result: [(column: Int, columns: Int)] = Array(repeating: (column: 0, columns: 1), count: spans.count)
        var cluster: [Int] = []
        var columnEnds: [Int] = []
        var clusterEnd = Int.min
        for index in order {
            let span = spans[index]
            let end = displayEnd(start: span.start, end: span.end)
            if !cluster.isEmpty && span.start >= clusterEnd {
                for member in cluster { result[member].columns = columnEnds.count }
                cluster = []
                columnEnds = []
                clusterEnd = Int.min
            }
            if let free = columnEnds.firstIndex(where: { $0 <= span.start }) {
                result[index].column = free
                columnEnds[free] = end
            } else {
                result[index].column = columnEnds.count
                columnEnds.append(end)
            }
            cluster.append(index)
            clusterEnd = max(clusterEnd, end)
        }
        for member in cluster { result[member].columns = max(columnEnds.count, 1) }
        return result
    }

    /// 时间轴显示哪几个小时：first..<last（刻度标 first…last）。
    static func hourRange(_ spans: [(start: Int, end: Int)], now: Int?) -> Range<Int> {
        var first = defaultFirstHour
        var last = defaultLastHour
        for span in spans {
            first = min(first, span.start / 60)
            last = max(last, (displayEnd(start: span.start, end: span.end) + 59) / 60)
        }
        if let now {
            first = min(first, now / 60)
            last = max(last, now / 60 + 1)
        }
        first = min(max(first, 0), 23)
        last = min(max(last, first + 1), 24)
        return first..<last
    }
}
