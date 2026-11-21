import Foundation

/// 日历显示范围。
enum CalendarScope: String, CaseIterable, Identifiable {
    case month, week, day

    var id: String { rawValue }
    var title: String {
        switch self {
        case .month: return "月"
        case .week: return "周"
        case .day: return "日"
        }
    }
}

/// 日历翻页与跳转：月视图翻一个月，周视图翻 7 天，日视图翻 1 天。
enum CalendarNavigation {
    static func step(scope: CalendarScope, month: LocalDate, focus: LocalDate,
                     direction: Int) -> (month: LocalDate, focus: LocalDate) {
        switch scope {
        case .month:
            return (month.adding(months: direction).firstOfMonth, focus)
        case .week:
            let next = focus.adding(days: 7 * direction)
            return (next.firstOfMonth, next)
        case .day:
            let next = focus.adding(days: direction)
            return (next.firstOfMonth, next)
        }
    }
}

extension AppModel {
    /// 打开某一天的单日视图。
    func showDay(_ day: LocalDate) {
        calendarFocus = day
        calendarMonth = day.firstOfMonth
        calendarScope = .day
    }

    /// 跳到某一天，保持当前的月 / 周 / 日范围。
    func jumpCalendar(to day: LocalDate) {
        calendarFocus = day
        calendarMonth = day.firstOfMonth
    }
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
