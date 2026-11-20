import Foundation
import XCTest
@testable import BiandanMac

final class UndoTests: XCTestCase {
    func testRestoreProgress() {
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: -1, target: 1),
                       [.changeProgress(id: "1", action: .abandon, count: nil)])
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 1, target: 1), [.completeOccurrence(id: "1")])
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 0, target: 1),
                       [.changeProgress(id: "1", action: .reopen, count: nil)])
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 3, target: 5),
                       [.changeProgress(id: "1", action: .setCount, count: 3)])
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 5, target: 5), [.completeOccurrence(id: "1")])
    }

    func testRestoreSubtaskProgress() {
        // 3 个子任务：目标 0b111×100；之前勾了第 0、2 个。
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 500, target: 700), [
            .changeProgress(id: "1", action: .reopen, count: nil),
            .setSubtask(id: "1", index: 0, checked: true),
            .setSubtask(id: "1", index: 2, checked: true),
        ])
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 700, target: 700), [.completeOccurrence(id: "1")])
        XCTAssertEqual(UndoPlan.restoreProgress("1", previous: 0, target: 700),
                       [.changeProgress(id: "1", action: .reopen, count: nil)])
    }

    private func task(_ attributes: [String: Any]) -> TaskDef {
        guard case .object(let object) = JSONValue(any: attributes) else { fatalError("attributes") }
        return TaskDef(record: RawRecord(kind: .task, cloudID: "c", version: 1, createdTime: nil,
                                         editedTime: nil, attributes: object))
    }

    func testRestoreSchedule() {
        let dated = task(["id1": "9", "startTime": "2026-11-20", "endTime": "2026-11-21", "haveNoTime": 0,
                          "validStartTime": "09:00:00", "validEndTime": "18:00:00",
                          "isRemind": 1, "remindDate": "2026-11-20", "remindTime": "08:30:00"])
        XCTAssertEqual(UndoPlan.restoreSchedule(dated), [
            .rescheduleTask(taskID: "9", start: "2026-11-20", end: "2026-11-21", startTime: "09:00:00", endTime: "18:00:00"),
        ])
        XCTAssertEqual(UndoPlan.restoreSchedule(dated, restoreReminder: true).last,
                       .setTimeReminder(taskID: "9", date: "2026-11-20", time: "08:30:00", enabled: true))
        let undated = task(["id1": "9", "haveNoTime": 1, "startTime": "1970-01-01", "endTime": "2100-12-31"])
        XCTAssertEqual(UndoPlan.restoreSchedule(undated), [.clearSchedule(taskID: "9")])
    }

    func testRecreateFocusKeepsIdentifier() throws {
        let log = #"{"eventId": -1, "eventType": -1, "eventTitle": "读书", "endTime": "x"}"#
        let raw = RawRecord(kind: .tomato, cloudID: "c", version: 1, createdTime: nil, editedTime: nil,
                            attributes: ["time": .int(1_763_600_000_123), "date": .string("2026-11-20"),
                                         "minutes": .int(25), "goodCount": .int(1), "badCount": .int(0),
                                         "log": .string(log)])
        let input = try XCTUnwrap(UndoPlan.recreateFocus(FocusRecord(record: raw), link: nil))
        XCTAssertEqual(FocusCodec.identifier(startedAt: input.startedAt), "1763600000123")
        XCTAssertEqual(input.title, "读书")
        XCTAssertEqual(input.minutes, 25)
    }
}
