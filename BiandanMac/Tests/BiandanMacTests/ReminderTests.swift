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
}
