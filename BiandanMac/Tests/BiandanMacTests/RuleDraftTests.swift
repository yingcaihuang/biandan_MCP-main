import XCTest
@testable import BiandanMac

/// 编辑器草稿与云端字段之间的往返。
final class RuleDraftTests: XCTestCase {
    private func task(_ attributes: JSONObject) -> TaskDef {
        TaskDef(record: RawRecord(kind: .task, cloudID: "t", version: 1, createdTime: nil, editedTime: nil,
                                  attributes: attributes))
    }

    func testCustomWeeklyHabitRoundTrip() throws {
        let source = task(["id1": .string("9"), "isLoop": .int(2), "loopSet": .int(1), "loopUnit": .int(201),
                           "loopBaseNumber": .int(2), "loopDate": .string("1,3"), "duration": .int(1)])
        let draft = RuleDraft(task: source, fallbackStart: LocalDate(iso: "2026-11-23")!)
        XCTAssertTrue(draft.habit)
        XCTAssertEqual(draft.weekdays, [1, 3])
        let encoded = try draft.rule.encode()
        XCTAssertEqual(encoded.loopSet, 1)
        XCTAssertEqual(encoded.loopUnit, 201)
        XCTAssertEqual(encoded.loopBaseNumber, 2)
        XCTAssertEqual(encoded.loopDate, "1,3")
    }

    func testPresetModes() throws {
        let daily = task(["id1": .string("9"), "isLoop": .int(1), "loopSet": .int(4), "duration": .int(3)])
        let encoded = try RuleDraft(task: daily, fallbackStart: LocalDate(iso: "2026-11-23")!).rule.encode()
        XCTAssertEqual(encoded.loopSet, 4)
        XCTAssertEqual(encoded.duration, 3)
        XCTAssertEqual(encoded.loopUnit, 0)

        var period = RuleDraft(start: LocalDate(iso: "2026-11-23")!)
        period.mode = .monthlyPeriod
        XCTAssertEqual(try period.rule.encode().loopSet, 7)
    }

    func testDefaultDraftUsesStartWeekday() throws {
        let draft = RuleDraft(start: LocalDate(iso: "2026-11-24")!)   // 周二
        XCTAssertEqual(try draft.rule.encode().loopDate, "2")
        XCTAssertEqual(draft.monthDays, [24])
    }
}
