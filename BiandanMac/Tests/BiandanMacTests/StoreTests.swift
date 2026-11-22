import XCTest
@testable import BiandanMac

final class StoreTests: XCTestCase {
    private func record(_ kind: RecordKind, _ cloudID: String, version: Int = 1, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: version, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, _ title: String, version: Int = 1, extra: JSONObject = [:]) -> RawRecord {
        record(.task, "c\(id)", version: version,
               ["id1": .int(Int64(id)!), "taskTitle": .string(title), "id3": .int(1)].merging(extra) { _, new in new })
    }

    func testApplyDiffAndDelete() throws {
        let store = try LocalStore()
        var report = try store.apply([.task: [task("1", "a"), task("2", "b")]])
        XCTAssertEqual(report.changes[.task], StoreChange(inserted: 2, updated: 0, deleted: 0, unchanged: 0))

        report = try store.apply([.task: [task("1", "a"), task("2", "b")]])
        XCTAssertEqual(report.changes[.task], StoreChange(inserted: 0, updated: 0, deleted: 0, unchanged: 2))
        XCTAssertFalse(report.hasChanges)

        report = try store.apply([.task: [task("1", "a2", version: 2)]])
        XCTAssertEqual(report.changes[.task], StoreChange(inserted: 0, updated: 1, deleted: 1, unchanged: 0))

        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot.tasks["1"]?.taskTitle, "a2")
        XCTAssertNil(snapshot.tasks["2"])
        XCTAssertTrue(snapshot.lists.contains { $0.isDefault })
        XCTAssertNotNil(snapshot.lastPulledAt)
    }

    func testUnknownFieldsArePreserved() throws {
        let store = try LocalStore()
        _ = try store.apply([.task: [task("7", "x", extra: ["futureField": .string("keep")])]])
        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot.tasks["7"]?.meta?.raw["futureField"], .string("keep"))
    }

    func testUntouchedKindsAreKept() throws {
        let store = try LocalStore()
        _ = try store.apply([.favorites: [record(.favorites, "f5", ["id3": .int(5), "favoritesName": .string("工作"),
                                                                    "favoritesColor": .int(301)])]])
        // 只传了 task 表，favorites 不应被当作「云端已删除」。
        _ = try store.apply([.task: [task("1", "a")]])
        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot.list("5")?.favoritesName, "工作")
        XCTAssertEqual(snapshot.list("5")?.color.colorIndex, 1)
    }

    func testWipe() throws {
        let store = try LocalStore()
        _ = try store.apply([.task: [task("1", "a")]])
        try store.wipe()
        XCTAssertTrue(try store.loadSnapshot().tasks.isEmpty)
    }

    // MARK: - 快照查询

    private func occurrence(_ id: String, task: String, start: String?, end: String?, count: Int = 0,
                            finish: Int = 0, finishedAt: String = "") -> RawRecord {
        var attributes: JSONObject = ["id2": .string(id), "id1": .string(task), "completedCount": .int(Int64(count)),
                                      "isFinish": .int(Int64(finish)), "recentFinishedTime": .string(finishedAt)]
        if let start { attributes["startTime"] = .string(start) }
        if let end { attributes["endTime"] = .string(end) }
        return record(.showTask, "o\(id)", attributes)
    }

    private func sampleSnapshot() -> DataSnapshot {
        let tasks = [
            task("1", "今天的事", extra: ["startTime": .string("2026-11-20"), "endTime": .string("2026-11-20"),
                                       "isImportant": .int(1), "isUrgency": .int(1)]),
            task("2", "无日期", extra: ["haveNoTime": .int(1), "isCollectible": .int(1)]),
            task("3", "昨天完成", extra: ["startTime": .string("2026-11-18"), "endTime": .string("2026-11-18")]),
            task("4", "逾期", extra: ["startTime": .string("2026-11-10"), "endTime": .string("2026-11-12")]),
            task("5", "放弃的无日期", extra: ["haveNoTime": .int(1)]),
        ]
        let occurrences = [
            occurrence("11", task: "1", start: "2026-11-20", end: "2026-11-20"),
            occurrence("22", task: "2", start: "1970-01-01", end: "2100-12-31"),
            occurrence("33", task: "3", start: "2026-11-18", end: "2026-11-18", count: 1, finish: 1,
                       finishedAt: "2026-11-19 08:00:00"),
            occurrence("44", task: "4", start: "2026-11-10", end: "2026-11-12"),
            occurrence("55", task: "5", start: "1970-01-01", end: "2100-12-31", count: -1),
            occurrence("99", task: "404", start: "2026-11-20", end: "2026-11-20"),
        ]
        return DataSnapshot(lists: [], tasks: tasks, occurrences: occurrences, focus: [], lastPulledAt: nil)
    }

    func testOccurrenceQueries() {
        let snapshot = sampleSnapshot()
        let today = LocalDate(iso: "2026-11-20")!

        XCTAssertEqual(snapshot.items(OccurrenceQuery(start: today, end: today)).map(\.id), ["11"])

        var withUndated = OccurrenceQuery(start: today, end: today)
        withUndated.includeUndated = true
        XCTAssertEqual(Set(snapshot.items(withUndated).map(\.id)), ["11", "22"])

        let completed = OccurrenceQuery(start: LocalDate(iso: "2026-11-19")!, end: nil, status: .completed)
        XCTAssertEqual(snapshot.items(completed).map(\.id), ["33"])

        var important = OccurrenceQuery(status: .all)
        important.important = true
        XCTAssertEqual(snapshot.items(important).map(\.id), ["11"])

        var text = OccurrenceQuery(status: .all)
        text.text = "逾期"
        XCTAssertEqual(snapshot.items(text).map(\.id), ["44"])
        XCTAssertTrue(snapshot.items(text)[0].isOverdue(today: today))

        XCTAssertTrue(snapshot.warnings.contains { $0.contains("找不到所属任务") })
    }

    func testSidebarCounts() {
        let counts = sampleSnapshot().counts(today: LocalDate(iso: "2026-11-20")!)
        XCTAssertEqual(counts.today, 1)
        XCTAssertEqual(counts.allPending, 3)
        XCTAssertEqual(counts.undated, 1)
        XCTAssertEqual(counts.collected, 1)
        XCTAssertEqual(counts.overdue, 1)
        XCTAssertEqual(counts.perList["1"], 3)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.abandoned, 1)
    }

    /// 逾期单独放在「逾期」里：其它待办视图和侧栏数字不算，日历和统计照算。
    func testOverdueSeparated() {
        let snapshot = sampleSnapshot()
        let today = LocalDate(iso: "2026-11-20")!
        let counts = snapshot.counts(today: today)
        XCTAssertEqual(counts.overdue, 1)
        XCTAssertEqual(counts.activePending, counts.allPending - 1)
        XCTAssertEqual(counts.activeList("1"), (counts.perList["1"] ?? 0) - 1)
        var all = OccurrenceQuery(status: .all)
        all.includeUndated = true
        let items = snapshot.items(all)
        XCTAssertEqual(OverdueFilter.apply(items, for: .overdue, today: today).map(\.id), ["44"])
        XCTAssertFalse(OverdueFilter.apply(items, for: .all, today: today).contains { $0.id == "44" })
        XCTAssertFalse(OverdueFilter.apply(items, for: .today, today: today).contains { $0.id == "44" })
        XCTAssertTrue(OverdueFilter.apply(items, for: .calendar, today: today).contains { $0.id == "44" })
    }

    /// 侧栏「已完成」「已放弃」的数字要和点进去看到的条数一致。
    func testCompletedAbandonedCountsMatchViews() {
        let snapshot = sampleSnapshot()
        let counts = snapshot.counts(today: LocalDate(iso: "2026-11-20")!)
        XCTAssertEqual(counts.completed, snapshot.items(OccurrenceQuery(status: .completed)).count)
        // 与 AppModel.query(for: .abandoned) 一致：含无日期任务。
        var abandoned = OccurrenceQuery(status: .abandoned)
        abandoned.includeUndated = true
        let abandonedItems = snapshot.items(abandoned)
        XCTAssertEqual(abandonedItems.map(\.id), ["55"])
        XCTAssertEqual(counts.abandoned, abandonedItems.count)
    }
}
