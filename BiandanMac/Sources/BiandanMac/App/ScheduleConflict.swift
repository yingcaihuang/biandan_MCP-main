import Foundation

/// 一个执行实例在某一天占用的时间段（当天的分钟数，0–1440）。
struct ScheduleSlot: Hashable, Sendable {
    let item: OccurrenceItem
    let day: LocalDate
    let start: Int
    let end: Int

    /// 有交叉才算；首尾刚好相接（13:00–14:00 与 14:00–15:00）不算。
    func overlaps(start other: Int, end otherEnd: Int) -> Bool { start < otherEnd && other < end }
}

/// 同一天里时间段互相交叉的一组日程（A 和 B 交叉、B 和 C 交叉时三项算一组）。
struct ScheduleConflictGroup: Identifiable, Hashable, Sendable {
    let day: LocalDate
    let slots: [ScheduleSlot]

    var id: String { day.iso + "|" + slots.map(\.item.id).joined(separator: ",") }
    var start: Int { slots.map(\.start).min() ?? 0 }
    var end: Int { slots.map(\.end).max() ?? 0 }
}

/// 新建日程和已有日程时间重叠时，底部弹出的提醒。
struct ConflictNotice: Equatable, Sendable {
    let id = UUID()
    let message: String
}

/// 日程冲突检测（纯计算）：只看待完成、带具体时刻的日程，全天任务和无日期任务不算。
enum ScheduleConflicts {
    /// 冲突页和侧栏计数检查今天起多少天。
    static let horizonDays = 30

    static func minutes(_ time: LocalTime) -> Int { time.hour * 60 + time.minute }

    /// 结束时刻 23:59 按当天结束（24:00）算。
    static func endMinutes(_ time: LocalTime) -> Int {
        time.hour == 23 && time.minute == 59 ? 1440 : minutes(time)
    }

    static func timeText(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }

    static func rangeText(_ start: Int, _ end: Int) -> String {
        end - start <= 1 ? timeText(start) : timeText(start) + "–" + timeText(end)
    }

    static func dayText(_ day: LocalDate, today: LocalDate) -> String {
        switch today.days(to: day) {
        case 0: return "今天 " + day.shortTitle
        case 1: return "明天 " + day.shortTitle
        case 2: return "后天 " + day.shortTitle
        default: return day.shortTitle
        }
    }

    static func shortTitle(_ item: OccurrenceItem) -> String {
        let title = item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle
        return title.count > 16 ? String(title.prefix(15)) + "…" : title
    }

    /// 实例在 [from, to] 里每天占用的时间段。跨天的日程按天截断，整天被占满的那天不算（同全天任务）。
    static func slots(_ item: OccurrenceItem, from: LocalDate, to: LocalDate) -> [ScheduleSlot] {
        let occurrence = item.occurrence
        guard item.status == .pending, !item.task.undated, !TimelineLayout.isAllDay(occurrence),
              let first = occurrence.startDate, let last = occurrence.endDate, first <= last,
              let startClock = occurrence.startClock, let endClock = occurrence.endClock else { return [] }
        var result: [ScheduleSlot] = []
        var day = max(first, from)
        let stop = min(last, to)
        var guardCount = 0
        while day <= stop, guardCount < 62 {
            guardCount += 1
            let current = day
            day = day.adding(days: 1)
            var start = current == first ? minutes(startClock) : 0
            var end = current == last ? endMinutes(endClock) : 1440
            if current != first && end == 0 { continue }
            // 没有时长（开始 = 结束）或结束早于开始时，按 1 分钟算。
            if end <= start {
                end = min(start + 1, 1440)
                start = end - 1
            }
            if start == 0 && end >= 1440 { continue }
            result.append(ScheduleSlot(item: item, day: current, start: start, end: end))
        }
        return result
    }

    /// 按天找出互相交叉的日程组。now 是当前分钟数：今天（from 那天）已经结束的时段不再提示。
    static func groups(_ items: [OccurrenceItem], from: LocalDate, to: LocalDate, now: Int? = nil) -> [ScheduleConflictGroup] {
        var byDay: [LocalDate: [ScheduleSlot]] = [:]
        for item in items {
            for slot in slots(item, from: from, to: to) {
                if let now, slot.day == from, slot.end <= now { continue }
                byDay[slot.day, default: []].append(slot)
            }
        }
        var result: [ScheduleConflictGroup] = []
        for day in byDay.keys.sorted() {
            let sorted = (byDay[day] ?? []).sorted { ($0.start, $0.end, $0.item.id) < ($1.start, $1.end, $1.item.id) }
            var current: [ScheduleSlot] = []
            var currentEnd = Int.min
            for slot in sorted {
                if !current.isEmpty && slot.start < currentEnd {
                    current.append(slot)
                    currentEnd = max(currentEnd, slot.end)
                } else {
                    if current.count > 1 { result.append(ScheduleConflictGroup(day: day, slots: current)) }
                    current = [slot]
                    currentEnd = slot.end
                }
            }
            if current.count > 1 { result.append(ScheduleConflictGroup(day: day, slots: current)) }
        }
        return result
    }

    /// 和某一天的 [start, end) 时间段交叉的已有日程。
    static func overlapping(day: LocalDate, start: Int, end: Int, in items: [OccurrenceItem],
                            excluding: String? = nil) -> [ScheduleSlot] {
        let end = max(end, start + 1)
        return items.filter { $0.id != excluding }
            .flatMap { slots($0, from: day, to: day) }
            .filter { $0.overlaps(start: start, end: end) }
            .sorted { ($0.start, $0.item.id) < ($1.start, $1.item.id) }
    }

    /// 「『跟腾讯开会』（后天 11月23日 周一 13:00–13:30）和『公司例会』时间重叠」
    static func message(title: String, day: LocalDate, start: Int, end: Int, others: [ScheduleSlot],
                        today: LocalDate) -> String {
        let name = title.count > 16 ? String(title.prefix(15)) + "…" : (title.isEmpty ? "（无标题）" : title)
        let first = others.first.map { shortTitle($0.item) } ?? ""
        let with = others.count > 1 ? "「\(first)」等 \(others.count) 项" : "「\(first)」"
        return "「\(name)」（\(dayText(day, today: today)) \(rangeText(start, max(end, start + 1)))）和\(with)时间重叠"
    }
}
