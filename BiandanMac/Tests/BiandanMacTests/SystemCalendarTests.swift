import EventKit
import XCTest
@testable import BiandanMac

final class SystemCalendarTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    /// 导入范围的最后一天（今天 2026-11-21 + 365 天）。
    private let to = LocalDate(iso: "2027-11-21")!

    private func date(_ iso: String, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        let day = LocalDate(iso: iso)!
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                  hour: hour, minute: minute))!
    }

    /// 每周一 10:00–11:00，从 2026-11-23 起，到导入范围结束。
    private func mondays(skipping skip: Set<String> = []) -> [SystemEventSnapshot] {
        let rule = SystemRecurrence(text: "FREQ=WEEKLY;INTERVAL=1;BYDAY=MO", hasEnd: false)
        var result: [SystemEventSnapshot] = []
        var day = LocalDate(iso: "2026-11-23")!
        while day <= to {
            if !skip.contains(day.iso) {
                result.append(SystemEventSnapshot(uid: "weekly", title: "周会", start: date(day.iso, 10),
                                                  end: date(day.iso, 11), occurrenceDate: date(day.iso, 10),
                                                  recurrence: rule))
            }
            day = day.adding(days: 7)
        }
        return result
    }

    func testCompleteWeeklySeriesBecomesRepeatingTask() {
        let events = SystemEventConverter.convert(mondays(), to: to, calendar: calendar)
        XCTAssertEqual(events.count, 1)
        let event = events.first
        XCTAssertEqual(event?.key, "weekly")
        XCTAssertEqual(event?.repeatRule?.unit, .week)
        XCTAssertEqual(event?.startDate, LocalDate(iso: "2026-11-23"))
        XCTAssertEqual(event?.startTime, LocalTime(hour: 10, minute: 0, second: 0))
        XCTAssertEqual(event?.endTime, LocalTime(hour: 11, minute: 0, second: 0))
        XCTAssertTrue(event?.repeatText?.hasPrefix("每周") == true)
    }

    func testSeriesWithDeletedOccurrenceIsImportedPerOccurrence() {
        let all = mondays()
        let events = SystemEventConverter.convert(mondays(skipping: ["2026-12-07"]), to: to, calendar: calendar)
        XCTAssertEqual(events.count, all.count - 1)
        XCTAssertTrue(events.allSatisfy { $0.key.hasPrefix("weekly#") && $0.repeatRule == nil })
        XCTAssertTrue(events.contains { $0.key == "weekly#2026-11-30" })
        XCTAssertFalse(events.contains { $0.key == "weekly#2026-12-07" })
        XCTAssertTrue(events.first?.repeatText?.hasSuffix("（按次导入）") == true)
    }

    func testMovedOccurrenceKeepsOriginalKey() {
        var items = mondays()
        // 12 月 7 日那次改到 12 月 8 日 14:00。
        if let index = items.firstIndex(where: { $0.start == date("2026-12-07", 10) }) {
            items[index].start = date("2026-12-08", 14)
            items[index].end = date("2026-12-08", 15)
            items[index].detached = true
        }
        let events = SystemEventConverter.convert(items, to: to, calendar: calendar)
        let moved = events.first { $0.key == "weekly#2026-12-07" }
        XCTAssertEqual(moved?.startDate, LocalDate(iso: "2026-12-08"))
        XCTAssertEqual(moved?.startTime, LocalTime(hour: 14, minute: 0, second: 0))
    }

    func testAllDayEnds() {
        let trip = SystemEventSnapshot(uid: "trip", title: "出差", start: date("2026-12-05"), end: date("2026-12-08"),
                                       allDay: true)
        let day = SystemEventSnapshot(uid: "day", title: "纪念日", start: date("2026-12-10"),
                                      end: date("2026-12-10", 23, 59).addingTimeInterval(59), allDay: true)
        let events = SystemEventConverter.convert([trip, day], to: to, calendar: calendar)
        XCTAssertEqual(events.map(\.key), ["trip", "day"])
        XCTAssertEqual(events[0].startDate, LocalDate(iso: "2026-12-05"))
        XCTAssertEqual(events[0].endDate, LocalDate(iso: "2026-12-07"))
        XCTAssertNil(events[0].startTime)
        XCTAssertEqual(events[1].endDate, LocalDate(iso: "2026-12-10"))
    }

    func testTimedEventWithoutDurationAndCancelled() {
        let item = SystemEventSnapshot(uid: "a", title: "电话", start: date("2026-12-01", 9, 30),
                                       end: date("2026-12-01", 9, 30), cancelled: true)
        let event = SystemEventConverter.convert([item], to: to, calendar: calendar).first
        XCTAssertEqual(event?.startTime, LocalTime(hour: 9, minute: 30, second: 0))
        XCTAssertNotNil(event?.endTime)
        XCTAssertEqual(event?.cancelled, true)
    }

    func testRecurrenceRuleText() {
        let lastFriday = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1,
                                          daysOfTheWeek: [EKRecurrenceDayOfWeek(dayOfTheWeek: .friday, weekNumber: -1)],
                                          daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                          daysOfTheYear: nil, setPositions: nil, end: nil)
        let monthly = SystemEventConverter.recurrence(lastFriday)
        XCTAssertEqual(monthly.text, "FREQ=MONTHLY;INTERVAL=1;BYDAY=-1FR")
        XCTAssertFalse(monthly.hasEnd)

        let fiveTimes = EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: EKRecurrenceEnd(occurrenceCount: 5))
        let weekly = SystemEventConverter.recurrence(fiveTimes)
        XCTAssertEqual(weekly.text, "FREQ=WEEKLY;INTERVAL=2")
        XCTAssertTrue(weekly.hasEnd)
    }
}
