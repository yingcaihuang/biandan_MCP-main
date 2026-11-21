import Foundation
import XCTest
@testable import BiandanMac

final class ListSectionTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, start: String, end: String, undated: Bool = false,
                      important: Bool = false) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string("任务 \(id)"), "taskContent": .string(""), "id3": .int(1),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(undated ? 1 : 0),
            "isImportant": .int(important ? 1 : 0), "validStartTime": .string("00:00:00"),
            "validEndTime": .string("23:59:00"), "unitTimeNumber": .int(1),
        ])
    }

    private func occurrence(_ id: String, start: String, end: String, finishedAt: String? = nil) -> RawRecord {
        record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string(id), "startTime": .string(start), "endTime": .string(end),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "completedCount": .int(finishedAt == nil ? 0 : 1), "isFinish": .int(finishedAt == nil ? 0 : 1),
            "recentFinishedTime": .string(finishedAt ?? ""),
        ])
    }

    private func snapshot() -> DataSnapshot {
        let tasks = [
            task("1", start: "2026-11-21", end: "2026-11-21"),
            task("2", start: "2026-11-18", end: "2026-11-18"),
            task("3", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("4", start: "2026-11-21", end: "2026-11-21", important: true),
            task("5", start: "2026-11-10", end: "2026-11-10"),
            task("6", start: "2026-11-16", end: "2026-11-16"),
        ]
        let occurrences = [
            occurrence("1", start: "2026-11-21", end: "2026-11-21"),
            occurrence("2", start: "2026-11-18", end: "2026-11-18"),
            occurrence("3", start: "1970-01-01", end: "2100-12-31"),
            occurrence("4", start: "2026-11-21", end: "2026-11-21", finishedAt: "2026-11-21 08:00:00"),
            occurrence("5", start: "2026-11-10", end: "2026-11-10", finishedAt: "2026-11-10 09:00:00"),
            occurrence("6", start: "2026-11-16", end: "2026-11-16", finishedAt: "2026-11-16 09:00:00"),
        ]
        return DataSnapshot(lists: [], tasks: tasks, occurrences: occurrences, focus: [], lastPulledAt: nil)
    }

    func testPendingThenUndatedThenOverdue() {
        var query = OccurrenceQuery()
        query.includeUndated = true
        let items = snapshot().items(query)
        let sections = OccurrenceListView.sections(items, mode: .all, today: today)
        XCTAssertEqual(sections.map(\.id), ["1-2026-11-21", "9", OccurrenceListView.overdueKey])
        XCTAssertEqual(sections.last?.title, "已过期")
        XCTAssertEqual(sections.last?.items.map(\.id), ["2"])
    }

    func testCompletedQueryWindows() throws {
        let data = snapshot()
        let base = OccurrenceQuery()
        let todayQuery = try XCTUnwrap(ListCompletion.query(from: base, item: .today, today: today))
        XCTAssertEqual(data.items(todayQuery).map(\.id), ["4"])
        let weekQuery = try XCTUnwrap(ListCompletion.query(from: base, item: .all, today: today))
        XCTAssertEqual(Set(data.items(weekQuery).map(\.id)), ["4", "6"])

        var important = base
        important.important = true
        let importantQuery = try XCTUnwrap(ListCompletion.query(from: important, item: .important, today: today))
        XCTAssertEqual(data.items(importantQuery).map(\.id), ["4"])

        for item in [SidebarItem.completed, .abandoned, .calendar, .quadrant, .undated, .focus] {
            XCTAssertNil(ListCompletion.query(from: base, item: item, today: today), "\(item)")
        }
        XCTAssertEqual(ListCompletion.title(for: .today), "已完成")
        XCTAssertEqual(ListCompletion.title(for: .all), "近 7 天已完成")
    }

    func testTodayProgress() {
        // 今天待办 1、逾期待办 1（11/18）、今天已完成 1；11/10、11/16 完成的不算，无日期不算。
        let items = snapshot().items(OccurrenceQuery(status: .all))
        let progress = TodayProgress.make(items, today: today)
        XCTAssertEqual(progress, TodayProgress(done: 1, total: 3, overdue: 1))
        XCTAssertEqual(progress.percentText, "33%")
        XCTAssertEqual(TodayProgress(done: 0, total: 0).ratio, 0)
        XCTAssertEqual(Greeting.subtitle(TodayProgress(done: 0, total: 0)), "今天还没有安排，享受轻松的一天")
        XCTAssertEqual(Greeting.subtitle(TodayProgress(done: 3, total: 3)), "今天的 3 项待办都完成了")
        XCTAssertEqual(Greeting.subtitle(progress), "今天还有 2 项待办（含 1 项逾期），已完成 1 项")
        XCTAssertEqual(Greeting.subtitle(TodayProgress(done: 1, total: 2)), "今天还有 1 项待办，已完成 1 项")
    }

    /// 今天完成逾期任务、提前完成以后的任务，都计入完成；以后的待办不计入分母。
    func testTodayProgressCountsWorkDoneToday() {
        let data = DataSnapshot(lists: [], tasks: [
            task("1", start: "2026-11-18", end: "2026-11-18"),
            task("2", start: "2026-11-25", end: "2026-11-25"),
            task("3", start: "2026-11-27", end: "2026-11-27"),
        ], occurrences: [
            occurrence("1", start: "2026-11-18", end: "2026-11-18", finishedAt: "2026-11-21 09:00:00"),
            occurrence("2", start: "2026-11-25", end: "2026-11-25", finishedAt: "2026-11-21 10:00:00"),
            occurrence("3", start: "2026-11-27", end: "2026-11-27"),
        ], focus: [], lastPulledAt: nil)
        let progress = TodayProgress.make(data.items(OccurrenceQuery(status: .all)), today: today)
        XCTAssertEqual(progress, TodayProgress(done: 2, total: 2))
        XCTAssertEqual(progress.percentText, "100%")
    }

    func testYearDayCounts() {
        let items = snapshot().items(OccurrenceQuery(status: .all))
        let counts = CalendarYear.dayCounts(items, year: 2026)
        XCTAssertEqual(counts[today], 2)
        XCTAssertEqual(counts[LocalDate(year: 2026, month: 11, day: 18)!], 1)
        XCTAssertEqual(counts[LocalDate(year: 2026, month: 11, day: 10)!], 1)
        XCTAssertNil(counts[LocalDate(year: 2026, month: 11, day: 19)!])
        XCTAssertTrue(CalendarYear.dayCounts(items, year: 2025).isEmpty)
    }

    func testGreetingByHour() {
        XCTAssertEqual(Greeting.text(hour: 7), "早上好")
        XCTAssertEqual(Greeting.text(hour: 12), "中午好")
        XCTAssertEqual(Greeting.text(hour: 15), "下午好")
        XCTAssertEqual(Greeting.text(hour: 21), "晚上好")
        XCTAssertEqual(Greeting.text(hour: 2), "晚上好")
    }
}
