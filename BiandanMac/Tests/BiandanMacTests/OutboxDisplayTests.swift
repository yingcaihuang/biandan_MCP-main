import XCTest
@testable import BiandanMac

final class OutboxDisplayTests: XCTestCase {
    func testTargets() {
        XCTAssertEqual(OutboxCommand.completeOccurrence(id: "o1").target, .occurrence("o1"))
        XCTAssertEqual(OutboxCommand.rescheduleOccurrence(id: "o2", start: "2026-11-21", startTime: nil, endTime: nil).target,
                       .occurrence("o2"))
        XCTAssertEqual(OutboxCommand.moveTask(taskID: "t1", listID: "3").target, .task("t1"))
        XCTAssertEqual(OutboxCommand.clearSchedule(taskID: "t2").target, .task("t2"))
        XCTAssertEqual(OutboxCommand.updateList(listID: "5", name: "工作", colorIndex: nil, sortIndex: nil).target, .list("5"))
        XCTAssertEqual(OutboxCommand.deleteFocus(id: "f").target, .focus)
    }

    func testTimeAndDetail() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 13, minute: 40)))
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(OutboxDisplay.time(iso.string(from: now.addingTimeInterval(-600)), now: now), "13:30")
        XCTAssertEqual(OutboxDisplay.time(iso.string(from: now.addingTimeInterval(-2 * 86_400 - 600)), now: now),
                       "11月19日 13:30")
        XCTAssertEqual(OutboxDisplay.time("abc", now: now), "abc")

        var entry = try XCTUnwrap(OutboxEntry.make(label: "改期", command: .clearSchedule(taskID: "t"),
                                                   now: now.addingTimeInterval(-600)))
        XCTAssertEqual(entry.payload?.label, "改期")
        XCTAssertEqual(OutboxDisplay.detail(entry, now: now), "入队 13:30 · 已尝试 0 次 · 待同步")
        entry.state = OutboxEntry.failed
        entry.attempts = 3
        XCTAssertEqual(OutboxDisplay.detail(entry, now: now), "入队 13:30 · 已尝试 3 次 · 已放弃")
    }
}
