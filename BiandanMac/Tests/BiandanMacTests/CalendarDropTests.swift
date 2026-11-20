import Foundation
import XCTest
@testable import BiandanMac

final class CalendarDropTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(year: y, month: m, day: day)! }

    func testWindowKeepsDuration() {
        let moved = CalendarDrop.window(start: d(2026, 11, 20), end: d(2026, 11, 22), to: d(2026, 11, 30))
        XCTAssertEqual(moved.start, d(2026, 11, 30))
        XCTAssertEqual(moved.end, d(2026, 12, 2))
        let single = CalendarDrop.window(start: d(2026, 11, 20), end: nil, to: d(2026, 11, 18))
        XCTAssertEqual(single.start, d(2026, 11, 18))
        XCTAssertEqual(single.end, d(2026, 11, 18))
        let inverted = CalendarDrop.window(start: d(2026, 11, 20), end: d(2026, 11, 19), to: d(2026, 11, 25))
        XCTAssertEqual(inverted.end, d(2026, 11, 25))
    }

    func testWeekStart() {
        // 2026-11-20 是周五。
        XCTAssertEqual(CalendarDrop.weekStart(of: d(2026, 11, 20), weekStart: 1), d(2026, 11, 16))
        XCTAssertEqual(CalendarDrop.weekStart(of: d(2026, 11, 20), weekStart: 0), d(2026, 11, 15))
        XCTAssertEqual(CalendarDrop.weekStart(of: d(2026, 11, 22), weekStart: 1), d(2026, 11, 16))
        XCTAssertEqual(CalendarDrop.weekStart(of: d(2026, 11, 22), weekStart: 0), d(2026, 11, 22))
        let week = CalendarView.weekDays(containing: d(2026, 12, 31), weekStart: 1)
        XCTAssertEqual(week.first, d(2026, 12, 28))
        XCTAssertEqual(week.last, d(2027, 1, 3))
    }
}
