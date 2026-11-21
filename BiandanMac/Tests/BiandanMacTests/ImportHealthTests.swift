import XCTest
@testable import BiandanMac

final class ImportHealthTests: XCTestCase {
    func testBackoffSlowsDownThenPauses() {
        XCTAssertNil(ImportBackoff.delayMinutes(failures: 0, interval: 30))
        XCTAssertNil(ImportBackoff.delayMinutes(failures: 2, interval: 30))
        XCTAssertEqual(ImportBackoff.delayMinutes(failures: 3, interval: 30), 60)
        XCTAssertEqual(ImportBackoff.delayMinutes(failures: 4, interval: 30), 120)
        XCTAssertEqual(ImportBackoff.delayMinutes(failures: 20, interval: 30), ImportBackoff.maxDelayMinutes)
        // 「仅手动」时按 5 分钟算基数。
        XCTAssertEqual(ImportBackoff.delayMinutes(failures: 3, interval: 0), 10)
        XCTAssertFalse(ImportBackoff.shouldPause(failures: ImportBackoff.pauseAfter - 1))
        XCTAssertTrue(ImportBackoff.shouldPause(failures: ImportBackoff.pauseAfter))
    }

    func testDeletedTasksAreRestored() {
        let day = LocalDate(iso: "2026-12-01")!
        func event(_ key: String) -> ImportedEvent {
            ImportedEvent(key: key, title: key, notes: "", location: "", latitude: nil, longitude: nil, startDate: day,
                          endDate: day, startTime: nil, endTime: nil, repeatRule: nil, repeatText: nil)
        }
        let a = event("a"), b = event("b"), c = event("c")
        let links = [a, b, c].map {
            ImportLink(sourceID: "s", key: $0.key, taskID: "t-" + $0.key, fingerprint: $0.fingerprint, startDay: day,
                       abandoned: false)
        }
        // b、c 的任务在便单里删掉了；c 在外部也没了。
        let plan = ImportPlanner.plan([a, b], links: links, removeMissing: true, liveTasks: ["t-a"], from: day)
        XCTAssertEqual(plan.unchanged.map(\.key), ["a"])
        XCTAssertEqual(plan.restored.map(\.key), ["b"])
        XCTAssertTrue(plan.added.isEmpty)
        XCTAssertTrue(plan.removed.isEmpty)
        // 不检查任务是否还在时，保持原来的判断。
        let unchecked = ImportPlanner.plan([a, b], links: links, removeMissing: true, from: day)
        XCTAssertEqual(unchecked.unchanged.count, 2)
        XCTAssertEqual(unchecked.removed.map(\.key), ["c"])
    }

    func testSourceHealthFieldsRoundTrip() throws {
        let store = try LocalStore()
        let retry = Date(timeIntervalSince1970: 1_800_000_000)
        let source = ImportSource(id: "s1", kind: .caldav, name: "飞书", listID: "l1", address: "https://x.example.com/",
                                  createdAt: Date(), lastSyncAt: nil, lastCount: 0, enabled: false, failures: 8,
                                  lastError: "HTTP 500", retryAt: retry, autoPaused: true)
        try store.saveImportSource(source)
        let loaded = try XCTUnwrap(store.importSources().first)
        XCTAssertEqual(loaded.failures, 8)
        XCTAssertEqual(loaded.lastError, "HTTP 500")
        XCTAssertEqual(loaded.retryAt, retry)
        XCTAssertTrue(loaded.autoPaused)
        XCTAssertFalse(loaded.enabled)
    }

    func testLogsKeepNewestAndClear() throws {
        let store = try LocalStore()
        for index in 0..<5 {
            let log = ImportSyncLog(sourceID: "s1", sourceName: "飞书", trigger: .automatic, startedAt: Date(),
                                    durationMs: index, ok: index % 2 == 0, fetched: index, added: 0, updated: 0,
                                    removed: 0, failed: 0, message: "m\(index)")
            try store.appendImportLog(log, keep: 3)
        }
        try store.appendImportLog(ImportSyncLog(sourceID: "s2", sourceName: "订阅", trigger: .manual, startedAt: Date(),
                                                durationMs: 9, ok: false, fetched: 0, added: 0, updated: 0,
                                                removed: 0, failed: 0, message: "HTTP 404"), keep: 10)
        // 前 5 条按 keep: 3 只留最新 3 条；第 6 条 keep: 10，不再删除。
        XCTAssertEqual(try store.importLogs(sourceID: "s1").map(\.durationMs), [4, 3, 2])
        XCTAssertEqual(try store.importLogs().count, 4)
        // 再按 keep: 2 写入一条：总数收缩到 2。
        try store.appendImportLog(ImportSyncLog(sourceID: "s1", sourceName: "飞书", trigger: .automatic, startedAt: Date(),
                                                durationMs: 99, ok: true, fetched: 0, added: 0, updated: 0,
                                                removed: 0, failed: 0, message: ""), keep: 2)
        XCTAssertEqual(try store.importLogs().map(\.durationMs), [99, 9])
        try store.clearImportLogs(sourceID: "s1")
        XCTAssertEqual(try store.importLogs().map(\.sourceID), ["s2"])
        XCTAssertTrue(try store.importLogs().first?.copyLine.contains("失败") == true)
    }
}
