import Foundation
import XCTest
@testable import BiandanMac

final class HabitTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, title: String, loop: Int) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string(title), "taskContent": .string(""), "id3": .int(1),
            "startTime": .string("2026-11-01"), "endTime": .string("2026-12-31"), "haveNoTime": .int(0),
            "isLoop": .int(Int64(loop)), "loopSet": .int(1), "validStartTime": .string("00:00:00"),
            "validEndTime": .string("23:59:00"), "unitTimeNumber": .int(1),
        ])
    }

    private func iso(_ day: Int) -> String { String(format: "2026-11-%02d", day) }

    private func occurrence(task id: String, day: Int, done: Bool = false, abandoned: Bool = false) -> RawRecord {
        let id2 = id + String(format: "%02d", day)
        return record(.showTask, "o\(id2)", [
            "id1": .string(id), "id2": .string(id2), "startTime": .string(iso(day)), "endTime": .string(iso(day)),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "completedCount": .int(abandoned ? -1 : (done ? 1 : 0)), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? iso(day) + " 08:00:00" : ""),
        ])
    }

    private func snapshot() -> DataSnapshot {
        let tasks = [task("1", title: "跑步", loop: 2), task("2", title: "阅读", loop: 2), task("9", title: "周报", loop: 1)]
        let occurrences = [
            occurrence(task: "1", day: 15, done: true), occurrence(task: "1", day: 16, done: true),
            occurrence(task: "1", day: 17, done: true), occurrence(task: "1", day: 18, abandoned: true),
            occurrence(task: "1", day: 19, done: true), occurrence(task: "1", day: 20, done: true),
            occurrence(task: "1", day: 21),
            occurrence(task: "2", day: 21, done: true),
            occurrence(task: "9", day: 21, done: true),
        ]
        return DataSnapshot(lists: [], tasks: tasks, occurrences: occurrences, focus: [], lastPulledAt: nil)
    }

    func testSummaries() throws {
        let items = snapshot().items(OccurrenceQuery(status: .all))
        let habits = HabitStats.summaries(items, today: today)
        XCTAssertEqual(habits.map(\.id), ["1", "2"])

        let run = try XCTUnwrap(habits.first)
        XCTAssertEqual(run.streak, 2)
        XCTAssertEqual(run.best, 3)
        XCTAssertEqual(run.total, 5)
        XCTAssertTrue(run.needsCheckIn)
        XCTAssertFalse(run.checkedToday)
        XCTAssertEqual(run.current?.id, "121")
        XCTAssertEqual(run.records.first?.id, "120")

        let read = habits[1]
        XCTAssertEqual(read.streak, 1)
        XCTAssertEqual(read.best, 1)
        XCTAssertTrue(read.checkedToday)
        XCTAssertFalse(read.needsCheckIn)
    }

    func testStreakHelpers() {
        let yesterday = today.adding(days: -1)
        let before = today.adding(days: -2)
        XCTAssertEqual(HabitStats.streak(days: [yesterday, before], today: today), 2)
        XCTAssertEqual(HabitStats.streak(days: [today, yesterday, before], today: today), 3)
        XCTAssertEqual(HabitStats.streak(days: [before], today: today), 0)
        XCTAssertEqual(HabitStats.bestStreak(days: []), 0)
        XCTAssertEqual(HabitStats.bestStreak(days: [before, today, today.adding(days: -5)]), 1)
    }
}
