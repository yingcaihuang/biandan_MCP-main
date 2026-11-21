import XCTest
@testable import BiandanMac

final class SidebarDropTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, start: String, end: String, undated: Bool = false, repeating: Bool = false,
                      collected: Bool = false, important: Bool = false) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string("任务 \(id)"), "taskContent": .string(""), "id3": .string("1"),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(undated ? 1 : 0),
            "isLoop": .int(repeating ? 1 : 0), "loopSet": .int(repeating ? Int64(LoopSet.daily.rawValue) : 0),
            "isCollectible": .int(collected ? 1 : 0), "isImportant": .int(important ? 1 : 0),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"), "unitTimeNumber": .int(1),
        ])
    }

    private func occurrence(_ id: String, start: String, end: String, done: Bool = false) -> RawRecord {
        record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string("o" + id), "startTime": .string(start), "endTime": .string(end),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? start + " 08:00:00" : ""),
        ])
    }

    /// a 今天的一次性；b 逾期的一次性；c 今天的重复；d 无日期；e 已完成、已收藏且重要。
    private func items() -> [OccurrenceItem] {
        let data = DataSnapshot(lists: [], tasks: [
            task("a", start: "2026-11-21", end: "2026-11-21"),
            task("b", start: "2026-11-18", end: "2026-11-18"),
            task("c", start: "2026-11-01", end: "2026-12-31", repeating: true),
            task("d", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("e", start: "2026-11-25", end: "2026-11-25", collected: true, important: true),
        ], occurrences: [
            occurrence("a", start: "2026-11-21", end: "2026-11-21"),
            occurrence("b", start: "2026-11-18", end: "2026-11-18"),
            occurrence("c", start: "2026-11-21", end: "2026-11-21"),
            occurrence("d", start: "1970-01-01", end: "2100-12-31"),
            occurrence("e", start: "2026-11-25", end: "2026-11-25", done: true),
        ], focus: [], lastPulledAt: nil)
        var query = OccurrenceQuery(status: .all)
        query.includeUndated = true
        return data.items(query)
    }

    private func tasks(_ target: SidebarItem) -> Set<String> {
        Set(BatchPlan.sidebarTargets(target, items(), today: today).map(\.task.id1))
    }

    func testSidebarTargets() {
        XCTAssertEqual(items().count, 5)
        XCTAssertEqual(tasks(.today), ["b", "d"], "已经在今天的、已完成的跳过")
        XCTAssertEqual(tasks(.undated), ["a", "b"], "只清一次性、有日期、未完成的")
        XCTAssertEqual(tasks(.collected), ["a", "b", "c", "d"])
        XCTAssertEqual(tasks(.important), ["a", "b", "c", "d"])
        XCTAssertEqual(tasks(.list("1")), [])
        XCTAssertEqual(tasks(.list("9")).count, 5)
        XCTAssertEqual(tasks(.completed), [])
    }

    func testExpandToSelection() {
        XCTAssertEqual(BatchPlan.expand(["a"], selection: ["x", "y"]), ["a"])
        XCTAssertEqual(BatchPlan.expand(["x"], selection: ["y", "x"]), ["x", "y"])
        XCTAssertEqual(BatchPlan.expand(["a", "a", "b"], selection: []), ["a", "b"])
        XCTAssertTrue(SidebarItem.today.acceptsDrop)
        XCTAssertFalse(SidebarItem.completed.acceptsDrop)
    }
}
