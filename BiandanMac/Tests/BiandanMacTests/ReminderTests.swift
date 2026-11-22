import Foundation
import XCTest
@testable import BiandanMac

final class ReminderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    /// 一次性任务：开始日期即提醒日期，带一个执行实例。
    private func oneOff(_ id: String, title: String, remind: String?, time: String = "09:00:00",
                        finished: Bool = false, content: String = "") -> (RawRecord, RawRecord) {
        let task = record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string(title), "taskContent": .string(content), "id3": .int(1),
            "startTime": .string("2026-11-21"), "endTime": .string("2026-11-21"),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "isRemind": .int(remind == nil ? 0 : 1), "remindDate": .string(remind ?? "2026-11-21"),
            "remindTime": .string(time), "isFinish": .int(finished ? 1 : 0), "unitTimeNumber": .int(1),
        ])
        let occurrence = record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string(id), "startTime": .string("2026-11-21"),
            "endTime": .string("2026-11-21"), "validStartTime": .string("00:00:00"),
            "validEndTime": .string("23:59:00"), "completedCount": .int(finished ? 1 : 0),
            "isFinish": .int(finished ? 1 : 0), "recentFinishedTime": .string(""),
        ])
        return (task, occurrence)
    }

    private func repeatingOccurrence(_ task: String, _ id: String, day: String, finished: Bool = false) -> RawRecord {
        record(.showTask, "o\(id)", [
            "id1": .string(task), "id2": .string(id), "startTime": .string(day), "endTime": .string(day),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "completedCount": .int(finished ? 1 : 0), "isFinish": .int(finished ? 1 : 0),
            "recentFinishedTime": .string(""),
        ])
    }

    private func sampleSnapshot() -> DataSnapshot {
        let due = oneOff("1", title: "写周报", remind: "2026-11-21", content: "提前准备")
        let past = oneOff("2", title: "已过", remind: "2026-11-21", time: "07:00:00")
        let silent = oneOff("3", title: "没开提醒", remind: nil)
        let done = oneOff("4", title: "已完成", remind: "2026-11-21", finished: true)
        let habit = record(.task, "t5", [
            "id1": .string("5"), "taskTitle": .string("背单词"), "taskContent": .string(""), "id3": .int(1),
            "startTime": .string("2026-11-01"), "endTime": .string("2026-12-31"),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "isLoop": .int(1), "loopSet": .int(4), "isRemind": .int(1), "remindDate": .string("2026-11-01"),
            "remindTime": .string("20:00:00"), "isFinish": .int(0), "unitTimeNumber": .int(1),
        ])
        let habitOccurrences = [
            repeatingOccurrence("5", "51", day: "2026-11-20"),                 // 昨天，已过
            repeatingOccurrence("5", "52", day: "2026-11-21"),                 // 今天 20:00
            repeatingOccurrence("5", "53", day: "2026-11-22"),                 // 明天 20:00
            repeatingOccurrence("5", "54", day: "2026-11-23", finished: true), // 已完成
            repeatingOccurrence("5", "55", day: "2026-12-20"),                 // 超出 14 天
        ]
        return DataSnapshot(lists: [], tasks: [due.0, past.0, silent.0, done.0, habit],
                            occurrences: [due.1, past.1, silent.1, done.1] + habitOccurrences,
                            focus: [], lastPulledAt: nil)
    }

    func testPlanSelectsUpcomingPendingReminders() {
        let plan = ReminderPlanner.plan(sampleSnapshot(), now: at(2026, 11, 21, 8, 0), calendar: calendar)
            .filter { $0.attempt == 1 }
        XCTAssertEqual(plan.map(\.occurrenceID), ["1", "52", "53"])
        XCTAssertEqual(plan.map(\.fireDate), [at(2026, 11, 21, 9, 0), at(2026, 11, 21, 20, 0), at(2026, 11, 22, 20, 0)])
        XCTAssertEqual(plan[0].title, "写周报")
        XCTAssertEqual(plan[0].body, "09:00 · 未分类 · 提前准备")
        XCTAssertEqual(plan[1].body, "20:00 · 未分类")
        XCTAssertTrue(plan.allSatisfy { $0.identifier.hasPrefix(ReminderScheduler.prefix) })
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count)
    }

    func testPlanSkipsEverythingAfterFireTime() {
        let plan = ReminderPlanner.plan(sampleSnapshot(), now: at(2026, 11, 21, 21, 0), calendar: calendar)
            .filter { $0.attempt == 1 }
        XCTAssertEqual(plan.map(\.occurrenceID), ["53"])
    }

    func testPlanLimit() {
        var tasks: [RawRecord] = []
        var occurrences: [RawRecord] = []
        for index in 1...70 {
            let pair = oneOff("\(100 + index)", title: "任务 \(index)", remind: "2026-11-21",
                              time: String(format: "%02d:%02d:00", 9 + index / 60, index % 60))
            tasks.append(pair.0)
            occurrences.append(pair.1)
        }
        let snapshot = DataSnapshot(lists: [], tasks: tasks, occurrences: occurrences, focus: [], lastPulledAt: nil)
        let plan = ReminderPlanner.plan(snapshot, now: at(2026, 11, 21, 8, 0), calendar: calendar)
        XCTAssertEqual(plan.count, ReminderPlanner.limit)
        XCTAssertEqual(plan.first?.occurrenceID, "101")
        XCTAssertEqual(plan.map(\.fireDate), plan.map(\.fireDate).sorted())
    }

    func testFireDate() {
        let day = LocalDate(year: 2026, month: 12, day: 31)!
        let time = LocalTime(text: "23:45")!
        XCTAssertEqual(ReminderPlanner.fireDate(day, time, calendar: calendar), at(2026, 12, 31, 23, 45))
    }

    // MARK: 追加提醒、睡眠补发、默认提醒、补提醒、改期

    func testFollowUpsWhenNotHandled() {
        let chain = ReminderPlanner.plan(sampleSnapshot(), now: at(2026, 11, 21, 8, 0), calendar: calendar)
            .filter { $0.occurrenceID == "1" }
        XCTAssertEqual(chain.map(\.fireDate), [at(2026, 11, 21, 9, 0), at(2026, 11, 21, 9, 15), at(2026, 11, 21, 10, 15)])
        XCTAssertEqual(chain.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(chain.map(\.subtitle), ["", "第 2 次提醒", "最后一次提醒"])
        XCTAssertEqual(Set(chain.map(\.chainKey)).count, 1)
        XCTAssertEqual(Set(chain.map(\.identifier)).count, 3)
        // 第 1 次已经过了、还没处理：只剩追加的。
        let later = ReminderPlanner.plan(sampleSnapshot(), now: at(2026, 11, 21, 9, 5), calendar: calendar)
            .filter { $0.occurrenceID == "1" }
        XCTAssertEqual(later.map(\.attempt), [2, 3])
        // 点过稍后提醒：不再追加。
        let snoozed = ReminderPlanner.plan(sampleSnapshot(), now: at(2026, 11, 21, 9, 5),
                                           acknowledged: [chain[0].chainKey], calendar: calendar)
            .filter { $0.occurrenceID == "1" }
        XCTAssertTrue(snoozed.isEmpty)
    }

    func testMissedWhileAsleep() {
        let plan = ReminderPlanner.plan(sampleSnapshot(), now: at(2026, 11, 21, 8, 0), calendar: calendar)
        // 8:30 睡到 10:30：「写周报」的 9:00、9:15、10:15 都在睡眠中，只补最后一条。
        let missed = ReminderPlanner.missed(plan, since: at(2026, 11, 21, 8, 30), now: at(2026, 11, 21, 10, 30),
                                            delivered: [], acknowledged: [])
        XCTAssertEqual(missed.map(\.occurrenceID), ["1"])
        XCTAssertEqual(missed.first?.attempt, 3)
        // 系统已经把最后一条发出来了：不再补。
        XCTAssertTrue(ReminderPlanner.missed(plan, since: at(2026, 11, 21, 8, 30), now: at(2026, 11, 21, 10, 30),
                                             delivered: [missed[0].identifier], acknowledged: []).isEmpty)
    }

    func testDefaultReminder() {
        let day = LocalDate(year: 2026, month: 11, day: 24)!
        var timed = CreateTaskInput(title: "开会")
        timed.startDate = day
        timed.startTime = LocalTime(hour: 14, minute: 30)
        ReminderPolicy.fillDefault(&timed)
        XCTAssertEqual(timed.reminderDate, day)
        XCTAssertEqual(timed.reminderTime, LocalTime(hour: 14, minute: 30))

        var allDay = CreateTaskInput(title: "打牌")
        allDay.startDate = day
        ReminderPolicy.fillDefault(&allDay)
        XCTAssertEqual(allDay.reminderTime, ReminderPolicy.allDayTime)

        var undated = CreateTaskInput(title: "随手记")
        ReminderPolicy.fillDefault(&undated)
        XCTAssertNil(undated.reminderTime)

        var explicit = CreateTaskInput(title: "提前提醒")
        explicit.startDate = day
        explicit.reminderDate = day.adding(days: -1)
        explicit.reminderTime = LocalTime(hour: 20, minute: 0)
        ReminderPolicy.fillDefault(&explicit)
        XCTAssertEqual(explicit.reminderDate, day.adding(days: -1))
        XCTAssertEqual(explicit.reminderTime, LocalTime(hour: 20, minute: 0))

        // AI 识别出只有日期的日程：当天 9:00 提醒。
        var trip = ScheduleCandidate(title: "去杭州")
        trip.date = day
        XCTAssertEqual(trip.input(listID: "1")?.reminderTime, ReminderPolicy.allDayTime)
    }

    func testBackfill() {
        let today = LocalDate(year: 2026, month: 11, day: 21)!
        XCTAssertEqual(ReminderPolicy.backfill(sampleSnapshot(), today: today),
                       [ReminderPolicy.Backfill(taskID: "3", date: today, time: ReminderPolicy.allDayTime)])
        // 已经过去的不补。
        XCTAssertTrue(ReminderPolicy.backfill(sampleSnapshot(), today: today.adding(days: 1)).isEmpty)
    }

    func testReminderFollowsReschedule() throws {
        let old = LocalDate(year: 2026, month: 11, day: 21)!
        let task = try XCTUnwrap(sampleSnapshot().tasks["1"])
        let moved = ReminderPolicy.shifted(task, oldStart: old, newStart: old.adding(days: 2), newStartTime: nil)
        XCTAssertEqual(moved?.date, old.adding(days: 2))
        XCTAssertEqual(moved?.time, LocalTime(hour: 9, minute: 0))
        XCTAssertNil(ReminderPolicy.shifted(task, oldStart: old, newStart: old, newStartTime: nil))
        // 按开始时刻提醒的：改了开始时刻，提醒时刻跟着走。
        var attributes = oneOff("9", title: "开会", remind: "2026-11-21", time: "10:00:00").0.attributes ?? [:]
        attributes["validStartTime"] = .string("10:00:00")
        let meeting = TaskDef(record: record(.task, "t9", attributes))
        let retimed = ReminderPolicy.shifted(meeting, oldStart: old, newStart: old.adding(days: 1),
                                             newStartTime: LocalTime(hour: 15, minute: 0))
        XCTAssertEqual(retimed?.date, old.adding(days: 1))
        XCTAssertEqual(retimed?.time, LocalTime(hour: 15, minute: 0))
        // 没开提醒的不动。
        XCTAssertNil(ReminderPolicy.shifted(try XCTUnwrap(sampleSnapshot().tasks["3"]), oldStart: old,
                                            newStart: old.adding(days: 1), newStartTime: nil))
    }
}
