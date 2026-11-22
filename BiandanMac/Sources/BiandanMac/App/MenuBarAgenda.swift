import AppKit
import Foundation

// MARK: - 菜单栏：现在该做什么、还剩多久。只看今天的定时日程（全天、无日期的不算）。

struct AgendaSlot: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
}

struct AgendaFocus: Equatable, Sendable {
    var current: AgendaSlot?
    var next: AgendaSlot?
}

enum MenuBarAgenda {
    /// 进行中的日程快结束、下一场马上开始时，菜单栏优先提醒下一场。
    static let imminentMinutes = 10
    /// 没有进行中的日程时，下一场在这么多分钟内显示倒计时，再远就显示开始时刻。
    static let countdownMinutes = 60
    static let titleLimit = 6

    static func focus(_ slots: [AgendaSlot], now: Date) -> AgendaFocus {
        let sorted = slots.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let current = sorted.filter { $0.start <= now && now < $0.end }.min { $0.end < $1.end }
        let next = sorted.first { $0.start > now }
        return AgendaFocus(current: current, next: next)
    }

    /// 向上取整的分钟数（还剩 7 分 10 秒算 8 分钟）。
    static func minutes(_ from: Date, _ to: Date) -> Int {
        max(Int((to.timeIntervalSince(from) / 60).rounded(.up)), 0)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    static func short(_ title: String, limit: Int = titleLimit) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > limit else { return name }
        return String(name.prefix(limit)) + "…"
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 菜单栏图标旁的文字：「设计评审 · 8 分钟后」「设计评审 · 剩 50 分钟」「14:30 设计评审」；没有日程时为 nil。
    static func menuBarText(_ focus: AgendaFocus, now: Date, calendar: Calendar = .current) -> String? {
        if let next = focus.next {
            let wait = minutes(now, next.start)
            if wait <= imminentMinutes || (focus.current == nil && wait <= countdownMinutes) {
                return [short(next.title), " · ", "\(wait) 分钟后"].joined()
            }
        }
        if let current = focus.current {
            return [short(current.title), " · 剩 ", duration(minutes(now, current.end))].joined()
        }
        if let next = focus.next {
            return [clock(next.start, calendar: calendar), " ", short(next.title)].joined()
        }
        return nil
    }

    /// 「还剩 25 分钟 · 到 15:30」
    static func runningDetail(_ slot: AgendaSlot, now: Date, calendar: Calendar = .current) -> String {
        ["还剩 ", duration(minutes(now, slot.end)), " · 到 ", clock(slot.end, calendar: calendar)].joined()
    }

    /// 「14:30 开始 · 8 分钟后」
    static func upcomingDetail(_ slot: AgendaSlot, now: Date, calendar: Calendar = .current) -> String {
        [clock(slot.start, calendar: calendar), " 开始 · ", duration(minutes(now, slot.start)), "后"].joined()
    }

    static func progress(_ slot: AgendaSlot, now: Date) -> Double {
        let total = slot.end.timeIntervalSince(slot.start)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(slot.start) / total, 0), 1)
    }

    static func moment(_ day: LocalDate, _ time: LocalTime, calendar: Calendar = .current) -> Date {
        let base = day.date(calendar: calendar)
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: base) ?? base
    }

    /// 待完成、有具体时刻的一次执行 → 时间段；全天、无日期的返回 nil。没写结束时刻按 30 分钟。
    static func slot(_ item: OccurrenceItem, calendar: Calendar = .current) -> AgendaSlot? {
        let occurrence = item.occurrence
        guard item.status == .pending, !item.task.undated, let day = occurrence.startDate,
              let startClock = occurrence.startClock else { return nil }
        if occurrence.validStartTime.hasPrefix("00:00") && occurrence.validEndTime.hasPrefix("23:59") { return nil }
        let begin = moment(day, startClock, calendar: calendar)
        let lastDay = occurrence.endDate ?? day
        var finish = occurrence.endClock.map { moment(lastDay, $0, calendar: calendar) } ?? begin.addingTimeInterval(1800)
        if finish <= begin { finish = begin.addingTimeInterval(1800) }
        let title = item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle
        return AgendaSlot(id: item.id, title: title, start: begin, end: finish)
    }
}

@MainActor
extension AppModel {
    /// 今天待完成的定时日程。
    func agendaSlots() -> [AgendaSlot] {
        snapshot.items(OccurrenceQuery())
            .filter { $0.occurrence.overlaps(today, today) }
            .compactMap { MenuBarAgenda.slot($0) }
    }

    func agendaFocus(now: Date) -> AgendaFocus {
        MenuBarAgenda.focus(agendaSlots(), now: now)
    }

    func menuBarCountdownText(now: Date) -> String? {
        MenuBarAgenda.menuBarText(agendaFocus(now: now), now: now)
    }
}

/// 菜单栏的时钟：每 30 秒走一次，菜单栏文字和面板跟着刷新。
@MainActor
@Observable
final class MenuBarClock {
    static let shared = MenuBarClock()
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    private init() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() { now = Date() }
}
