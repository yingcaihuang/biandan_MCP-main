import XCTest
@testable import BiandanMac

/// 修改重复规则时的实例对比，语义对应 Python update_recurrence。
final class RecurrenceDiffTests: XCTestCase {
    private func d(_ iso: String) -> LocalDate { LocalDate(iso: iso)! }

    private func occurrence(_ day: String, start: String = "19:00:00", progress: Int = 0, finish: Int = 0) -> RawRecord {
        RawRecord(kind: .showTask, cloudID: "c\(day)", version: 1, createdTime: nil, editedTime: nil, attributes: [
            "id1": .string("100"), "id2": .string(BusinessID.occurrenceID(taskID: "100", startDate: day)),
            "startTime": .string(day), "endTime": .string(day),
            "validStartTime": .string(start), "validEndTime": .string("21:00:00"),
            "completedCount": .int(Int64(progress)), "isFinish": .int(Int64(finish)), "recentFinishedTime": .string(""),
        ])
    }

    private func target(from: String) throws -> [String: JSONObject] {
        // 每周一、周四 20:00–21:00，系列 11/23–12/6。
        let rule = try RepeatRule(mode: .custom, unit: .week, dates: ["1", "4"]).encode()
        let input = RecurrenceInput(start: d("2026-11-23"), end: d("2026-12-06"),
                                    validStartTime: "20:00:00", validEndTime: "21:00:00", rule: rule)
        let windows = try Recurrence.windows(input, fromDate: d(from), allowEmpty: true)
        var result: [String: JSONObject] = [:]
        for window in windows { result[window.start.iso] = window.attributes }
        return result
    }

    func testWeeklyRuleChange() throws {
        let slots = try target(from: "2026-11-24")
        XCTAssertEqual(slots.keys.sorted(), ["2026-11-26", "2026-11-30", "2026-12-03"])
        // 原规则每周一、三 19:00；11/23 已完成。
        let existing = [occurrence("2026-11-23", progress: 1, finish: 1), occurrence("2026-11-25"),
                        occurrence("2026-11-30"), occurrence("2026-12-02")]
        let diff = try BiandanService.diffRecurrence(taskID: "100", existing: existing, target: slots,
                                                     cutoff: d("2026-11-24"), undated: false)
        XCTAssertEqual(diff.insert.compactMap { $0.string("startTime") }, ["2026-11-26", "2026-12-03"])
        XCTAssertEqual(diff.insert.first?.string("id2"), BusinessID.occurrenceID(taskID: "100", startDate: "2026-11-26"))
        XCTAssertEqual(diff.prune.compactMap { $0.attributes?.string("startTime") }, ["2026-11-25", "2026-12-02"])
        XCTAssertEqual(diff.patches.count, 1, "11/30 时刻从 19:00 改到 20:00")
        XCTAssertEqual(diff.patches.first?.1.string("validStartTime"), "20:00:00")
        XCTAssertEqual(diff.protectedDays, ["2026-11-23"])
    }

    func testProgressAndAbandonedAreProtected() throws {
        let slots = try target(from: "2026-11-20")
        let existing = [occurrence("2026-11-23", progress: -1), occurrence("2026-11-26", start: "20:00:00", progress: 1)]
        let diff = try BiandanService.diffRecurrence(taskID: "100", existing: existing, target: slots,
                                                     cutoff: d("2026-11-20"), undated: false)
        XCTAssertEqual(diff.protectedDays, ["2026-11-23", "2026-11-26"])
        XCTAssertEqual(diff.insert.compactMap { $0.string("startTime") }, ["2026-11-30", "2026-12-03"])
        XCTAssertTrue(diff.prune.isEmpty)
        XCTAssertTrue(diff.patches.isEmpty)
    }

    func testDuplicatePendingDayThrows() throws {
        let slots = try target(from: "2026-11-20")
        var second = occurrence("2026-11-30")
        second = RawRecord(kind: .showTask, cloudID: "dup", version: 1, createdTime: nil, editedTime: nil,
                           attributes: second.attributes)
        XCTAssertThrowsError(try BiandanService.diffRecurrence(
            taskID: "100", existing: [occurrence("2026-11-30"), second], target: slots,
            cutoff: d("2026-11-20"), undated: false))
    }
}
