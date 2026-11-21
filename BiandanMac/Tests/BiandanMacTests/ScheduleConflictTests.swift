import XCTest
@testable import BiandanMac

/// 今天是 2026-11-21。
final class ScheduleConflictTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!

    private func raw(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func item(_ id: String, _ day: String, _ start: String, _ end: String, endDay: String? = nil,
                      done: Bool = false) -> OccurrenceItem {
        let last = endDay ?? day
        let task = TaskDef(record: raw(.task, "t" + id, [
            "id1": .string(id), "taskTitle": .string("任务" + id), "startTime": .string(day), "endTime": .string(last),
            "validStartTime": .string(start), "validEndTime": .string(end),
        ]))
        let occurrence = Occurrence(record: raw(.showTask, "o" + id, [
            "id1": .string(id), "id2": .string(id), "startTime": .string(day), "endTime": .string(last),
            "validStartTime": .string(start), "validEndTime": .string(end),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
        ]))
        return OccurrenceItem(occurrence: occurrence, task: task)
    }

    private var end: LocalDate { today.adding(days: 29) }

    func testOverlapAndTouching() {
        let items = [
            item("a", "2026-11-23", "10:00:00", "11:00:00"),
            item("b", "2026-11-23", "10:30:00", "11:30:00"),
            item("c", "2026-11-23", "11:30:00", "12:00:00"),  // 和 b 首尾相接，不算
            item("d", "2026-11-24", "10:00:00", "11:00:00"),  // 另一天
        ]
        let groups = ScheduleConflicts.groups(items, from: today, to: end)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].day, LocalDate(year: 2026, month: 11, day: 23))
        XCTAssertEqual(groups[0].slots.map(\.item.id), ["a", "b"])
        XCTAssertEqual(ScheduleConflicts.rangeText(groups[0].start, groups[0].end), "10:00–11:30")
    }

    func testChainGroupsTogether() {
        let items = [
            item("a", "2026-11-23", "09:00:00", "10:00:00"),
            item("b", "2026-11-23", "09:30:00", "10:30:00"),
            item("c", "2026-11-23", "10:15:00", "11:00:00"),
        ]
        let groups = ScheduleConflicts.groups(items, from: today, to: end)
        XCTAssertEqual(groups.map(\.slots.count), [3])
    }

    func testIgnoresAllDayCompletedAndPast() {
        let items = [
            item("allday", "2026-11-23", "00:00:00", "23:59:00"),
            item("done", "2026-11-23", "10:00:00", "11:00:00", done: true),
            item("x", "2026-11-23", "10:30:00", "11:30:00"),
            // 今天 9:00–10:00 和 9:30–10:30 都已过去（现在 12:00）
            item("p1", "2026-11-21", "09:00:00", "10:00:00"),
            item("p2", "2026-11-21", "09:30:00", "10:30:00"),
            // 今天 11:30–12:30 和 12:00–13:00 还没结束
            item("n1", "2026-11-21", "11:30:00", "12:30:00"),
            item("n2", "2026-11-21", "12:00:00", "13:00:00"),
        ]
        let groups = ScheduleConflicts.groups(items, from: today, to: end, now: 12 * 60)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].slots.map(\.item.id), ["n1", "n2"])
    }

    func testMultiDaySpan() {
        let items = [
            item("trip", "2026-11-22", "22:00:00", "02:00:00", endDay: "2026-11-23"),
            item("call", "2026-11-23", "01:00:00", "01:30:00"),
        ]
        let groups = ScheduleConflicts.groups(items, from: today, to: end)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].day, LocalDate(year: 2026, month: 11, day: 23))
        XCTAssertEqual(groups[0].start, 0)
    }

    func testOverlappingNewSlot() {
        let day = LocalDate(year: 2026, month: 11, day: 24)!
        let items = [
            item("meeting", "2026-11-24", "10:00:00", "10:30:00"),
            item("later", "2026-11-24", "14:00:00", "15:00:00"),
        ]
        let found = ScheduleConflicts.overlapping(day: day, start: 10 * 60 + 15, end: 10 * 60 + 45, in: items)
        XCTAssertEqual(found.map(\.item.id), ["meeting"])
        XCTAssertTrue(ScheduleConflicts.overlapping(day: day, start: 10 * 60 + 30, end: 11 * 60, in: items).isEmpty,
                      "刚好接在后面不算冲突")
        XCTAssertTrue(ScheduleConflicts.overlapping(day: day, start: 600, end: 630, in: items, excluding: "meeting").isEmpty)
        let message = ScheduleConflicts.message(title: "跟腾讯开会", day: day, start: 615, end: 645,
                                                others: found, today: today)
        XCTAssertEqual(message, "「跟腾讯开会」（11月24日 周二 10:15–10:45）和「任务meeting」时间重叠")
    }
}
