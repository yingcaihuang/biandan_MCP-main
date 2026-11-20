import Foundation
import XCTest
@testable import BiandanMac

final class HolidayTests: XCTestCase {
    override func tearDown() {
        ChinaMakeup.resetRemote()
        super.tearDown()
    }

    private func d(_ y: Int, _ m: Int, _ day: Int) -> LocalDate { LocalDate(year: y, month: m, day: day)! }

    func testBuiltin2027() {
        XCTAssertEqual(ChinaMakeup.lastYear, 2027)
        XCTAssertEqual(ChinaMakeup.coverageEnd, d(2027, 12, 31))
        XCTAssertEqual(ChinaMakeup.builtinDays.filter { $0.year == 2027 }.count, 23)
        XCTAssertTrue(ChinaMakeup.days.contains(d(2027, 2, 14)))   // 周日补班
        XCTAssertTrue(ChinaMakeup.days.contains(d(2027, 6, 9)))    // 端午周三放假
        XCTAssertFalse(ChinaMakeup.days.contains(d(2027, 2, 6)))   // 周六本来就休
    }

    func testParseHolidayCN() throws {
        let json = #"""
        {"year": 2028, "papers": ["https://www.gov.cn/x.htm", "https://evil.example/y"],
         "days": [
           {"name": "元旦", "date": "2028-01-01", "isOffDay": true},
           {"name": "元旦", "date": "2028-01-02", "isOffDay": true},
           {"name": "春节", "date": "2028-01-29", "isOffDay": false},
           {"name": "春节", "date": "2028-01-31", "isOffDay": false}
         ]}
        """#
        let cached = try HolidayUpdater.parse(Data(json.utf8), year: 2028)
        // 2028-01-01 周六放假不翻转；01-02 周日不翻转；01-29 周六上班翻转；01-31 周一上班不翻转。
        XCTAssertEqual(cached.days, ["2028-01-29"])
        XCTAssertEqual(cached.papers, ["https://www.gov.cn/x.htm"])
        XCTAssertThrowsError(try HolidayUpdater.parse(Data(json.utf8), year: 2029))
        XCTAssertThrowsError(try HolidayUpdater.parse(Data(#"{"year":2028,"days":[]}"#.utf8), year: 2028))
    }

    func testFlipDaysMatchesBuiltin2026() {
        // 用 2026 年官方安排换算，应与内置的 2026 年数据一致。
        let off = ["2026-01-01", "2026-01-02", "2026-01-03", "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18",
                   "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23", "2026-04-04", "2026-04-05",
                   "2026-04-06", "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05", "2026-06-19",
                   "2026-06-20", "2026-06-21", "2026-09-25", "2026-09-26", "2026-09-27", "2026-10-01", "2026-10-02",
                   "2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"]
        let work = ["2026-01-04", "2026-02-14", "2026-02-28", "2026-05-09", "2026-09-20", "2026-10-10"]
        let entries = off.map { (LocalDate(iso: $0)!, true) } + work.map { (LocalDate(iso: $0)!, false) }
        let flips = ChinaMakeup.flipDays(year: 2026, entries: entries.map { (date: $0.0, isOffDay: $0.1) })
        XCTAssertEqual(flips, ChinaMakeup.builtinDays.filter { $0.year == 2026 })
    }

    func testRemoteYearsMustBeContiguous() {
        XCTAssertEqual(ChinaMakeup.install([2029: [d(2029, 1, 1)]]), 2027)   // 缺 2028，不计入
        XCTAssertFalse(ChinaMakeup.days.contains(d(2029, 1, 1)))
        XCTAssertEqual(ChinaMakeup.install([2028: [d(2028, 1, 29)]]), 2029)  // 补上 2028 后连到 2029
        XCTAssertTrue(ChinaMakeup.days.contains(d(2029, 1, 1)))
        XCTAssertEqual(ChinaMakeup.install([2027: [d(2027, 3, 3)]]), 2029)   // 不允许覆盖内置年份
        XCTAssertFalse(ChinaMakeup.days.contains(d(2027, 3, 3)))
    }

    func testWorkdays2027SpringFestival() throws {
        let row: [String: Any] = ["duration": 1, "startTime": "2027-02-01", "endTime": "2027-02-20",
                                  "loopBaseNumber": 1, "loopDate": "", "loopSet": LoopSet.workdays.rawValue,
                                  "loopUnit": 0, "validStartTime": "09:00:00", "validEndTime": "10:00:00"]
        guard case .object(let attributes) = JSONValue(any: row) else { return XCTFail("row") }
        let task = TaskDef(record: RawRecord(kind: .task, cloudID: "t", version: 1, createdTime: nil,
                                             editedTime: nil, attributes: attributes))
        let days = try Recurrence.windows(RecurrenceInput(task: task), chinaMakeup: true).map(\.start.iso)
        XCTAssertEqual(days, ["2027-02-01", "2027-02-02", "2027-02-03", "2027-02-04", "2027-02-14",
                              "2027-02-15", "2027-02-16", "2027-02-17", "2027-02-18", "2027-02-19"])
        // 不开调休时按普通周末：2 月 1–5、8–12、15–19 共 15 天。
        XCTAssertEqual(try Recurrence.windows(RecurrenceInput(task: task), chinaMakeup: false).count, 15)
    }

    func testCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = HolidayUpdater.CachedYear(year: 2028, days: ["2028-01-29"], papers: [], fetchedAt: Date())
        try JSONEncoder().encode(cached).write(to: directory.appendingPathComponent("makeup-2028.json"))
        XCTAssertEqual(HolidayUpdater.loadCache(directory: directory), 2028)
        XCTAssertTrue(ChinaMakeup.days.contains(d(2028, 1, 29)))
    }
}
