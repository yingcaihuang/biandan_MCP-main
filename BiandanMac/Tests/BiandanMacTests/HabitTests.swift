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

    private func habitTask(_ id: String, loopSet: Int, base: Int = 1, unit: Int = 0) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string("习惯 \(id)"), "taskContent": .string(""), "id3": .int(1),
            "startTime": .string("2026-10-01"), "endTime": .string("2026-12-31"), "haveNoTime": .int(0),
            "isLoop": .int(2), "loopSet": .int(Int64(loopSet)), "loopBaseNumber": .int(Int64(base)),
            "loopUnit": .int(Int64(unit)), "validStartTime": .string("00:00:00"),
            "validEndTime": .string("23:59:00"), "unitTimeNumber": .int(1),
        ])
    }

    private func span(task id: String, _ start: String, _ end: String, done: Bool = false) -> RawRecord {
        let id2 = id + start.replacingOccurrences(of: "-", with: "")
        return record(.showTask, "o\(id2)", [
            "id1": .string(id), "id2": .string(id2), "startTime": .string(start), "endTime": .string(end),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? start + " 08:00:00" : ""),
        ])
    }

    /// 每周习惯按周计数：本周还没打卡不算断，漏掉的那周才中断；以后的周不计入。
    func testWeeklyHabitCountsByPeriod() throws {
        let data = DataSnapshot(lists: [], tasks: [habitTask("w", loopSet: LoopSet.weeklyPeriod.rawValue)], occurrences: [
            span(task: "w", "2026-10-19", "2026-10-25", done: true),
            span(task: "w", "2026-10-26", "2026-11-01"),
            span(task: "w", "2026-11-02", "2026-11-08", done: true),
            span(task: "w", "2026-11-09", "2026-11-15", done: true),
            span(task: "w", "2026-11-16", "2026-11-22"),
            span(task: "w", "2026-11-23", "2026-11-29"),
        ], focus: [], lastPulledAt: nil)
        let habit = try XCTUnwrap(HabitStats.summaries(data.items(OccurrenceQuery(status: .all)), today: today).first)
        XCTAssertEqual(habit.streak, 2)
        XCTAssertEqual(habit.best, 2)
        XCTAssertEqual(habit.unit, "周")
        XCTAssertEqual(habit.streakTitle, "连续周数")
        XCTAssertTrue(habit.needsCheckIn)
    }

    /// 今天已经打卡时计入当前连续；放弃算中断。
    func testStreakIncludesTodayAndBreaksOnAbandon() {
        let rows = DataSnapshot(lists: [], tasks: [habitTask("d", loopSet: LoopSet.daily.rawValue)], occurrences: [
            span(task: "d", "2026-11-18", "2026-11-18", done: true),
            record(.showTask, "od19", [
                "id1": .string("d"), "id2": .string("d19"), "startTime": .string("2026-11-19"),
                "endTime": .string("2026-11-19"), "validStartTime": .string("00:00:00"),
                "validEndTime": .string("23:59:00"), "completedCount": .int(-1), "isFinish": .int(0),
                "recentFinishedTime": .string(""),
            ]),
            span(task: "d", "2026-11-20", "2026-11-20", done: true),
            span(task: "d", "2026-11-21", "2026-11-21", done: true),
        ], focus: [], lastPulledAt: nil).items(OccurrenceQuery(status: .all))
        let runs = HabitStats.streaks(rows, today: today)
        XCTAssertEqual(runs.current, 2)
        XCTAssertEqual(runs.best, 2)
        XCTAssertEqual(HabitStats.streaks([], today: today).current, 0)
    }

    func testStreakUnit() {
        func unit(_ raw: RawRecord) -> String { HabitStats.unit(for: TaskDef(record: raw)) }
        XCTAssertEqual(unit(habitTask("a", loopSet: LoopSet.daily.rawValue)), "天")
        XCTAssertEqual(unit(habitTask("b", loopSet: LoopSet.monthlyPeriod.rawValue)), "月")
        XCTAssertEqual(unit(habitTask("c", loopSet: LoopSet.workdays.rawValue)), "次")
        XCTAssertEqual(unit(habitTask("d", loopSet: LoopSet.custom.rawValue, base: 1, unit: 1)), "周")
        XCTAssertEqual(unit(habitTask("e", loopSet: LoopSet.custom.rawValue, base: 2, unit: 0)), "次")
    }
}
