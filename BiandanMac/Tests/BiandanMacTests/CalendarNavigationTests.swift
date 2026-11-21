import XCTest
@testable import BiandanMac

final class CalendarNavigationTests: XCTestCase {
    private let month = LocalDate(year: 2026, month: 11, day: 1)!
    private let focus = LocalDate(year: 2026, month: 11, day: 30)!

    func testDayStepCrossesMonth() {
        let next = CalendarNavigation.step(scope: .day, month: month, focus: focus, direction: 1)
        XCTAssertEqual(next.focus, LocalDate(year: 2026, month: 12, day: 1)!)
        XCTAssertEqual(next.month, LocalDate(year: 2026, month: 12, day: 1)!)
        let back = CalendarNavigation.step(scope: .day, month: next.month, focus: next.focus, direction: -1)
        XCTAssertEqual(back.focus, focus)
        XCTAssertEqual(back.month, month)
    }

    func testWeekAndMonthStep() {
        let week = CalendarNavigation.step(scope: .week, month: month, focus: focus, direction: -1)
        XCTAssertEqual(week.focus, LocalDate(year: 2026, month: 11, day: 23)!)
        let next = CalendarNavigation.step(scope: .month, month: month, focus: focus, direction: 2)
        XCTAssertEqual(next.month, LocalDate(year: 2027, month: 1, day: 1)!)
        XCTAssertEqual(next.focus, focus)
    }

    func testYearStep() {
        let next = CalendarNavigation.step(scope: .year, month: month, focus: focus, direction: 1)
        XCTAssertEqual(next.month, LocalDate(year: 2027, month: 11, day: 1)!)
        XCTAssertEqual(next.focus, focus)
        XCTAssertEqual(CalendarYear.days(year: 2028).count, 366)
        XCTAssertEqual(CalendarYear.days(year: 2026).count, 365)
    }

    func testScopeTitles() {
        XCTAssertEqual(CalendarScope.allCases.map(\.title), ["年", "月", "周", "日"])
    }
}
