import XCTest
@testable import BiandanMac

final class ImportSyncStatsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private let today = LocalDate(iso: "2026-11-22")!

    private func log(_ source: String, _ iso: String, ok: Bool, trigger: ImportSyncTrigger = .automatic,
                     ms: Int = 1000, added: Int = 0, updated: Int = 0, removed: Int = 0,
                     message: String = "") -> ImportSyncLog {
        let day = LocalDate(iso: iso)!
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 10))!
        return ImportSyncLog(sourceID: source, sourceName: source == "a" ? "飞书" : "订阅", trigger: trigger,
                             startedAt: date, durationMs: ms, ok: ok, fetched: 7, added: added, updated: updated,
                             removed: removed, failed: 0, message: message)
    }

    func testSummaryCountsSyncsAndSkipsEdits() {
        let logs = [
            log("a", "2026-11-22", ok: true, trigger: .manual, ms: 2000, added: 6),
            log("a", "2026-11-21", ok: true, ms: 1000, updated: 2),
            log("b", "2026-11-21", ok: false, message: "服务器返回错误（HTTP 500）；连续失败 3 次"),
            log("a", "2026-11-20", ok: true, trigger: .edited),
            // 范围外。
            log("a", "2026-09-01", ok: false, message: "网络错误：超时"),
        ]
        let summary = ImportSyncStats.summary(logs, range: .week, today: today, weekStart: 1, calendar: calendar)
        XCTAssertEqual(summary.syncs, 3)
        XCTAssertEqual(summary.successes, 2)
        XCTAssertEqual(summary.failures, 1)
        XCTAssertEqual(summary.edits, 1)
        XCTAssertEqual(summary.added, 6)
        XCTAssertEqual(summary.updated, 2)
        XCTAssertEqual(summary.fetched, 21)
        XCTAssertEqual(summary.averageMs, 1500)
        XCTAssertEqual(summary.sources.map(\.id), ["a", "b"])
        XCTAssertEqual(summary.sources.last?.failures, 1)
        XCTAssertEqual(summary.errors.map(\.title), ["服务器错误（HTTP 500）"])
        XCTAssertEqual(summary.triggers.map(\.title), ["自动", "手动"])
        XCTAssertEqual(summary.recentFailures.count, 1)
        XCTAssertEqual(summary.buckets.count, 7)
        XCTAssertEqual(summary.buckets.last?.successes, 1)
        XCTAssertEqual(summary.buckets.last?.added, 6)
        XCTAssertEqual(summary.buckets[5].failures, 1)
    }

    func testErrorKinds() {
        XCTAssertEqual(ImportSyncStats.errorKind("用户名或密码不对。多数服务要用专用密码"), "账户或密码不对")
        XCTAssertEqual(ImportSyncStats.errorKind("网络错误：请求超时。"), "网络错误")
        XCTAssertEqual(ImportSyncStats.errorKind("这个地址上没有日历（HTTP 404），请核对订阅地址"), "地址或日历不存在")
        XCTAssertEqual(ImportSyncStats.errorKind("服务器返回错误（HTTP 502）"), "服务器错误（HTTP 502）")
        XCTAssertEqual(ImportSyncStats.errorKind("没有日历访问权限，请在系统设置里允许"), "没有权限")
        XCTAssertEqual(ImportSyncStats.errorKind("奇怪的错误"), "其他")
    }

    func testTrendPoints() {
        var bucket = ImportSyncBucket(start: today)
        bucket.successes = 2
        bucket.failures = 1
        bucket.added = 3
        XCTAssertEqual(ImportSyncStats.outcomePoints([bucket], calendar: calendar).map(\.value), [2, 1])
        XCTAssertEqual(ImportSyncStats.changePoints([bucket], calendar: calendar).map(\.series), ["新增", "更新", "放弃"])
        XCTAssertEqual(ImportSyncStats.durationText(850), "850 毫秒")
        XCTAssertEqual(ImportSyncStats.durationText(2300), "2.3 秒")
        XCTAssertEqual(ImportSyncStats.durationText(nil), "—")
    }
}
