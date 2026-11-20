import Foundation

/// 日历显示范围。
enum CalendarScope: String, CaseIterable, Identifiable {
    case month, week

    var id: String { rawValue }
    var title: String { self == .month ? "月" : "周" }
}

/// 日历拖动改期的日期计算。
enum CalendarDrop {
    /// 拖到 `day`：开始日改为 `day`，保留原来的持续天数。
    static func window(start: LocalDate, end: LocalDate?, to day: LocalDate) -> (start: LocalDate, end: LocalDate) {
        let span = end.map { max(start.days(to: $0), 0) } ?? 0
        return (day, day.adding(days: span))
    }

    /// `day` 所在那一周的第一天（`weekStart`：0 周日，1 周一）。
    static func weekStart(of day: LocalDate, weekStart: Int) -> LocalDate {
        day.adding(days: -floorMod(day.weekday - weekStart, 7))
    }
}

extension AppModel {
    /// 日历里把实例拖到某一天：一次性任务整体改期（保留时长和时刻，可 ⌘Z 撤销）；
    /// 重复任务只改这一次（脱离系列）。
    func dropOnDay(_ occurrenceID: String, day: LocalDate) async {
        guard let item = snapshot.item(occurrenceID: occurrenceID), !item.task.undated,
              let start = item.occurrence.startDate, start != day else { return }
        let window = CalendarDrop.window(start: start, end: item.occurrence.endDate, to: day)
        await reschedule(item, start: window.start, end: window.end,
                         startTime: item.occurrence.startClock, endTime: item.occurrence.endClock)
    }
}
