import XCTest
@testable import BiandanMac

/// 日视图时间轴：重叠的并排、显示的小时范围、时刻换算。
final class DayAgendaLayoutTests: XCTestCase {
    func testOverlappingSideBySide() {
        // 13:00–15:00 和 14:30–15:30 重叠并排，16:00–16:45 独占一行。
        let result = DayAgendaLayout.columns([(start: 780, end: 900), (start: 870, end: 930), (start: 960, end: 1005)])
        XCTAssertEqual(result.map(\.column), [0, 1, 0])
        XCTAssertEqual(result.map(\.columns), [2, 2, 1])
    }

    func testFreedColumnIsReused() {
        // 10:00–12:00、10:00–10:30、11:00–11:30：第三个用第二列（第二个已经结束）。
        let result = DayAgendaLayout.columns([(start: 600, end: 720), (start: 600, end: 630), (start: 660, end: 690)])
        XCTAssertEqual(result.map(\.column), [0, 1, 1])
        XCTAssertEqual(result.map(\.columns), [2, 2, 2])
    }

    func testShortBlocksStillOverlap() {
        // 10:00–10:00（没写结束）按 30 分钟画，和 10:15 的会重叠。
        let result = DayAgendaLayout.columns([(start: 600, end: 600), (start: 615, end: 630)])
        XCTAssertEqual(result.map(\.columns), [2, 2])
    }

    func testHourRange() {
        XCTAssertEqual(DayAgendaLayout.hourRange([], now: nil), 8..<18)
        XCTAssertEqual(DayAgendaLayout.hourRange([(start: 780, end: 900), (start: 1050, end: 1110)], now: nil), 8..<19)
        XCTAssertEqual(DayAgendaLayout.hourRange([(start: 780, end: 900)], now: 1153), 8..<20)
        XCTAssertEqual(DayAgendaLayout.hourRange([(start: 420, end: 450)], now: nil), 7..<18)
        XCTAssertEqual(DayAgendaLayout.hourRange([(start: 1260, end: 1440)], now: nil), 8..<24)
    }

    func testMetricsY() {
        // 每小时 45 点：8:00 在顶部留白处，9:30 往下 1.5 小时。
        let hours = 8..<18
        XCTAssertEqual(DayAgendaMetrics.y(480, hours: hours), DayAgendaMetrics.inset)
        XCTAssertEqual(DayAgendaMetrics.y(570, hours: hours), DayAgendaMetrics.inset + 67.5, accuracy: 0.001)
        XCTAssertEqual(DayAgendaMetrics.height(hours: hours), 10 * 45 + DayAgendaMetrics.inset * 2)
    }

    func testWeekBlocksCascade() {
        // 周视图 120 宽的列里两个重叠：平分只剩约 55，错开叠放后第二块仍有 100 多。
        let split = DayAgendaMetrics.horizontal(column: 1, columns: 2, width: 120, cascade: false)
        let cascade = DayAgendaMetrics.horizontal(column: 1, columns: 2, width: 120, cascade: true)
        XCTAssertLessThan(split.width, 60)
        XCTAssertGreaterThan(cascade.width, 100)
        XCTAssertEqual(cascade.x, 16, accuracy: 0.001)
        // 不重叠时两种方式一样。
        let single = DayAgendaMetrics.horizontal(column: 0, columns: 1, width: 120, cascade: true)
        XCTAssertEqual(single.width, 113, accuracy: 0.001)
    }

    func testMinutes() {
        XCTAssertEqual(DayAgendaLayout.minutes(LocalTime(hour: 13, minute: 30)!), 810)
        XCTAssertEqual(DayAgendaLayout.minutes(LocalTime(hour: 23, minute: 59)!), 1440)
    }
}
