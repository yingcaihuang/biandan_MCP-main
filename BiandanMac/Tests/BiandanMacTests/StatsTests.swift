import XCTest
@testable import BiandanMac

final class StatsTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, start: String, end: String, undated: Bool = false, repeating: Bool = false,
                      urgentImportant: Bool = false) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string("任务 \(id)"), "taskContent": .string(""), "id3": .string("1"),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(undated ? 1 : 0),
            "isLoop": .int(repeating ? 1 : 0), "loopSet": .int(repeating ? Int64(LoopSet.daily.rawValue) : 0),
            "isImportant": .int(urgentImportant ? 1 : 0), "isUrgency": .int(urgentImportant ? 1 : 0),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"), "unitTimeNumber": .int(1),
        ])
    }

    private func occurrence(_ task: String, _ id2: String, day: String, done: Bool = false) -> RawRecord {
        record(.showTask, "o\(id2)", [
            "id1": .string(task), "id2": .string(id2), "startTime": .string(day), "endTime": .string(day),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? day + " 08:00:00" : ""),
        ])
    }

    /// a 11-20 完成；b 11-18 逾期（重要且紧急）；c 无日期；d 11-01 完成（范围外）；e 重复，未来 3 次待完成。
    private func snapshot() -> DataSnapshot {
        DataSnapshot(lists: [], tasks: [
            task("a", start: "2026-11-20", end: "2026-11-20"),
            task("b", start: "2026-11-18", end: "2026-11-18", urgentImportant: true),
            task("c", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("d", start: "2026-11-01", end: "2026-11-01"),
            task("e", start: "2026-11-25", end: "2026-12-31", repeating: true),
        ], occurrences: [
            occurrence("a", "a", day: "2026-11-20", done: true),
            occurrence("b", "b", day: "2026-11-18"),
            record(.showTask, "oc", [
                "id1": .string("c"), "id2": .string("c"), "startTime": .string("1970-01-01"),
                "endTime": .string("2100-12-31"), "validStartTime": .string("00:00:00"),
                "validEndTime": .string("23:59:00"), "completedCount": .int(0), "isFinish": .int(0),
                "recentFinishedTime": .string(""),
            ]),
            occurrence("d", "d", day: "2026-11-01", done: true),
            occurrence("e", "e1", day: "2026-11-25"),
            occurrence("e", "e2", day: "2026-11-26"),
            occurrence("e", "e3", day: "2026-11-27"),
        ], focus: [], lastPulledAt: nil)
    }

    func testWeekSummary() {
        let summary = StatsCalculator.summary(snapshot(), range: .week, today: today, weekStart: 1)
        XCTAssertEqual(summary.start, LocalDate(year: 2026, month: 11, day: 15))
        XCTAssertEqual(summary.buckets.count, 7)
        XCTAssertEqual(summary.completed, 1, "11-01 的完成不在范围内")
        XCTAssertEqual(summary.buckets[5].completed, 1)
        XCTAssertEqual(summary.dueTotal, 2)
        XCTAssertEqual(summary.dueCompleted, 1)
        XCTAssertEqual(summary.onTimeRate, 0.5)
        XCTAssertEqual(summary.overdue, 1)
        let quadrants = Dictionary(uniqueKeysWithValues: summary.quadrants.map { ($0.quadrant, $0.count) })
        XCTAssertEqual(quadrants[.importantUrgent], 1)
        XCTAssertEqual(quadrants[.neither], 2, "重复任务的多个实例只算一个任务")
        XCTAssertEqual(summary.lists.map(\.count), [3])
    }

    func testQuarterBucketsByWeek() {
        let summary = StatsCalculator.summary(snapshot(), range: .quarter, today: today, weekStart: 1)
        XCTAssertEqual(summary.start.weekday, 1, "按周汇总从周一开始")
        XCTAssertTrue(summary.buckets.allSatisfy { $0.start.weekday == 1 })
        XCTAssertEqual(summary.buckets.map(\.completed).reduce(0, +), 2)
        XCTAssertLessThanOrEqual(summary.buckets.last?.start ?? today, today)
    }

    func testDurationText() {
        XCTAssertEqual(StatsCalculator.durationText(45), "45 分钟")
        XCTAssertEqual(StatsCalculator.durationText(120), "2 小时")
        XCTAssertEqual(StatsCalculator.durationText(125.6), "2 小时 5 分")
    }
}
