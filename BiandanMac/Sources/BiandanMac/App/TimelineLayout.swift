import Foundation

/// 单日时间条上的一个任务标记。start / end 是 0–1 的位置（0 点 → 24 点）。
struct TimelineMark: Identifiable {
    let item: OccurrenceItem
    let start: Double
    let end: Double
    var lane: Int = 0
    /// 全天任务按提醒时刻标注（空心点），不是开始时间。
    var isReminder = false
    var id: String { item.id }
}

/// 日期时间条上某一天的任务。
struct TimelineDayGroup: Identifiable {
    let index: Int
    let day: LocalDate
    var items: [OccurrenceItem]
    var id: Int { index }
}

/// 完成率卡片下方时间条的定位规则。
enum TimelineLayout {
    /// 标记最多叠 3 层。
    static let maxLanes = 3
    /// 两个圆点在同一层的最小间距（占整条宽度的比例，约 30 分钟）。
    static let minGap = 0.022
    static let hourTicks = [0, 3, 6, 9, 12, 15, 18, 21, 24]

    static func fraction(hour: Int, minute: Int) -> Double {
        min(max(Double(hour * 60 + minute) / 1440, 0), 1)
    }

    static func fraction(of date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return fraction(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    static func isAllDay(_ occurrence: Occurrence) -> Bool {
        occurrence.validStartTime.hasPrefix("00:00") && occurrence.validEndTime.hasPrefix("23:59")
    }

    /// 单日：定时任务按开始–结束时刻定位，跨天的在当天截断；全天任务单独返回。
    static func day(_ items: [OccurrenceItem], day: LocalDate) -> (timed: [TimelineMark], allDay: [OccurrenceItem]) {
        var timed: [TimelineMark] = []
        var allDay: [OccurrenceItem] = []
        for item in items where !item.task.undated && item.occurrence.overlaps(day, day) {
            let occurrence = item.occurrence
            guard let first = occurrence.startDate, let last = occurrence.endDate else { continue }
            if isAllDay(occurrence) {
                // 全天任务设了时间提醒：在提醒时刻标注；否则归入「全天」。
                if item.task.hasTimeReminder, let clock = LocalTime(text: item.task.remindTime) {
                    let at = fraction(hour: clock.hour, minute: clock.minute)
                    timed.append(TimelineMark(item: item, start: at, end: at, isReminder: true))
                } else {
                    allDay.append(item)
                }
                continue
            }
            let start: Double = first < day ? 0 : (occurrence.startClock.map { fraction(hour: $0.hour, minute: $0.minute) } ?? 0)
            let end: Double = last > day ? 1 : (occurrence.endClock.map { fraction(hour: $0.hour, minute: $0.minute) } ?? start)
            if start <= 0 && end >= 1 {
                allDay.append(item)
                continue
            }
            timed.append(TimelineMark(item: item, start: start, end: max(end, start)))
        }
        return (assignLanes(timed), allDay)
    }

    /// 按开始位置分层：同一层的下一个标记要在前一个结束（且至少相隔 minGap）之后，放不下就往上叠，
    /// 超过 maxLanes 层时放进最早空出来的那层。
    static func assignLanes(_ marks: [TimelineMark]) -> [TimelineMark] {
        let sorted = marks.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var laneEnds: [Double] = []
        var result: [TimelineMark] = []
        for var mark in sorted {
            if let lane = laneEnds.firstIndex(where: { $0 <= mark.start }) {
                mark.lane = lane
                laneEnds[lane] = max(mark.end, mark.start + minGap)
            } else if laneEnds.count < maxLanes {
                mark.lane = laneEnds.count
                laneEnds.append(max(mark.end, mark.start + minGap))
            } else {
                let lane = laneEnds.indices.min { laneEnds[$0] < laneEnds[$1] } ?? 0
                mark.lane = lane
                laneEnds[lane] = max(mark.end, mark.start + minGap)
            }
            result.append(mark)
        }
        return result
    }

    /// 日期范围：每个任务放在它在范围内的第一天。
    static func range(_ items: [OccurrenceItem], start: LocalDate, end: LocalDate) -> [TimelineDayGroup] {
        var groups: [Int: TimelineDayGroup] = [:]
        for item in items where !item.task.undated && item.occurrence.overlaps(start, end) {
            guard let first = item.occurrence.startDate else { continue }
            let day = max(first, start)
            let index = start.days(to: day)
            groups[index, default: TimelineDayGroup(index: index, day: day, items: [])].items.append(item)
        }
        return groups.values.sorted { $0.index < $1.index }
    }

    /// 日期刻度：7 天以内每天一个；更长时标 1、5、10、15、20、25 号和最后一天。
    static func rangeTicks(start: LocalDate, end: LocalDate) -> [Int] {
        let count = start.days(to: end) + 1
        if count <= 7 { return Array(0..<max(count, 0)) }
        let days: Set<Int> = [1, 5, 10, 15, 20, 25]
        return (0..<count).filter { days.contains(start.adding(days: $0).day) || $0 == count - 1 }
    }
}
