import XCTest
@testable import BiandanMac

/// 写进 Spotlight 的日程。今天是 2026-11-22。
final class SpotlightTests: XCTestCase {
    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, title: String, list: String = "1", start: String, end: String,
                      from: String = "00:00:00", to: String = "23:59:00", undated: Bool = false,
                      important: Bool = false, urgent: Bool = false) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string(title), "id3": .string(list),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(undated ? 1 : 0),
            "isLoop": .int(0), "loopSet": .int(0), "validStartTime": .string(from), "validEndTime": .string(to),
            "unitTimeNumber": .int(1), "isImportant": .int(important ? 1 : 0), "isUrgency": .int(urgent ? 1 : 0),
        ])
    }

    private func occurrence(_ id: String, start: String, end: String, from: String = "00:00:00",
                            to: String = "23:59:00", done: Bool = false) -> RawRecord {
        record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string("o" + id), "startTime": .string(start), "endTime": .string(end),
            "validStartTime": .string(from), "validEndTime": .string(to),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? start + " 08:00:00" : ""),
        ])
    }

    private let today = LocalDate(iso: "2026-11-22")!

    func testEntries() {
        let snapshot = DataSnapshot(lists: [
            record(.favorites, "f1", ["id3": .string("1001"), "favoritesName": .string("工作"), "favoritesColor": .int(101)]),
        ], tasks: [
            task("b", title: "面试", list: "1001", start: "2026-11-22", end: "2026-11-22", from: "14:30:00", to: "15:30:00",
                 important: true, urgent: true),
            task("o", title: "交报销", start: "2026-11-20", end: "2026-11-20"),
            task("c", title: "读书", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("a", title: "已完成", start: "2026-11-22", end: "2026-11-22"),
            task("f", title: "太远了", start: "2027-01-30", end: "2027-01-30"),
        ], occurrences: [
            occurrence("b", start: "2026-11-22", end: "2026-11-22", from: "14:30:00", to: "15:30:00"),
            occurrence("o", start: "2026-11-20", end: "2026-11-20"),
            occurrence("c", start: "1970-01-01", end: "2100-12-31"),
            occurrence("a", start: "2026-11-22", end: "2026-11-22", done: true),
            occurrence("f", start: "2027-01-30", end: "2027-01-30"),
        ], focus: [], lastPulledAt: nil)
        let entries = SpotlightIndex.entries(snapshot: snapshot, today: today)
        XCTAssertEqual(entries.map(\.id), ["oo", "ob", "oc"], "已完成和 30 天以后的不写；逾期在前、无日期在最后")
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        XCTAssertEqual(byID["oo"]?.detail, "逾期 · 11月20日 · 未分类")
        XCTAssertEqual(byID["ob"]?.detail, "今天 14:30 · 工作 · 重要且紧急")
        XCTAssertEqual(byID["oc"]?.detail, "无日期 · 未分类")
        XCTAssertNil(byID["oc"]?.start)
        XCTAssertEqual(byID["ob"]?.keywords, ["便单", "工作", "重要且紧急"])
        XCTAssertNotNil(byID["ob"]?.start)
    }
}
