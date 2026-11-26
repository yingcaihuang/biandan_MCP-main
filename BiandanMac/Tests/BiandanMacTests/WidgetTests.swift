import XCTest
@testable import BiandanMac

/// 写给小组件的 widget.json 和 biandan:// 链接。今天是 2026-11-22。
final class WidgetTests: XCTestCase {
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

    /// d 今天全天；b 明天 15:00–15:30（工作、重要）；x 今天到后天跨 3 天、9:00 开始；
    /// c 无日期；a 今天已完成；o 前天逾期；f 4 天后（超出 3 天不写）。
    private func snapshot() -> DataSnapshot {
        DataSnapshot(lists: [
            record(.favorites, "f1", ["id3": .string("1001"), "favoritesName": .string("工作"), "favoritesColor": .int(101)]),
        ], tasks: [
            task("d", title: "开会", start: "2026-11-22", end: "2026-11-22"),
            task("b", title: "面试", list: "1001", start: "2026-11-23", end: "2026-11-23", from: "15:00:00",
                 to: "15:30:00", important: true),
            task("x", title: "出差", start: "2026-11-22", end: "2026-11-24", from: "09:00:00", to: "18:00:00"),
            task("c", title: "读书", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("a", title: "已完成", start: "2026-11-22", end: "2026-11-22"),
            task("o", title: "逾期了", start: "2026-11-20", end: "2026-11-20", urgent: true),
            task("f", title: "以后", start: "2026-11-26", end: "2026-11-26"),
        ], occurrences: [
            occurrence("d", start: "2026-11-22", end: "2026-11-22"),
            occurrence("b", start: "2026-11-23", end: "2026-11-23", from: "15:00:00", to: "15:30:00"),
            occurrence("x", start: "2026-11-22", end: "2026-11-24", from: "09:00:00", to: "18:00:00"),
            occurrence("c", start: "1970-01-01", end: "2100-12-31"),
            occurrence("a", start: "2026-11-22", end: "2026-11-22", done: true),
            occurrence("o", start: "2026-11-20", end: "2026-11-20"),
            occurrence("f", start: "2026-11-26", end: "2026-11-26"),
        ], focus: [], lastPulledAt: nil)
    }

    func testPayload() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let payload = WidgetPayload.build(snapshot: snapshot(), today: today, signedIn: true, now: now)
        XCTAssertTrue(payload.signedIn)
        XCTAssertEqual(payload.overdue, 1)
        XCTAssertEqual(payload.generatedAt, now)
        XCTAssertEqual(payload.items.map { "\($0.day) \($0.id)" }, [
            "2026-11-22 od", "2026-11-22 ox", "2026-11-23 ox", "2026-11-23 ob", "2026-11-24 ox",
        ], "已完成、无日期、逾期、3 天以后的不写；同一天全天在前")

        let byKey = Dictionary(uniqueKeysWithValues: payload.items.map { ("\($0.day) \($0.id)", $0) })
        XCTAssertNil(byKey["2026-11-22 od"]?.start, "全天没有时刻")
        XCTAssertNotNil(byKey["2026-11-22 ox"]?.start, "跨天日程开始那天带时刻")
        XCTAssertNil(byKey["2026-11-23 ox"]?.start, "跨天日程后面几天按全天")
        let interview = byKey["2026-11-23 ob"]
        XCTAssertEqual(interview?.list, "工作")
        XCTAssertEqual(interview?.quadrant, Quadrant.importantNotUrgent.rawValue)
        if let start = interview?.start, let end = interview?.end {
            XCTAssertEqual(end.timeIntervalSince(start), 1800)
            XCTAssertEqual(WidgetShared.dayString(start), "2026-11-23")
        } else {
            XCTFail("面试应带开始和结束时刻")
        }
        XCTAssertEqual(byKey["2026-11-22 od"]?.list, "未分类")

        XCTAssertEqual(payload.items(on: "2026-11-23").map(\.id), ["ox", "ob"])
        XCTAssertEqual(payload.items(on: "2026-11-25"), [])
    }

    func testSignedOutAndRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let signedOut = WidgetPayload.build(snapshot: snapshot(), today: today, signedIn: false, now: now)
        XCTAssertFalse(signedOut.signedIn)
        XCTAssertTrue(signedOut.items.isEmpty)
        XCTAssertEqual(signedOut.overdue, 0)

        let payload = WidgetPayload.build(snapshot: snapshot(), today: today, signedIn: true, now: now)
        let decoded = try WidgetShared.decode(WidgetShared.encode(payload))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.version, WidgetSnapshot.currentVersion)
    }

    func testLinks() {
        XCTAssertEqual(WidgetShared.url(.occurrence("o123"), scheme: "biandan").absoluteString, "biandan://occurrence/o123")
        XCTAssertEqual(WidgetShared.url(.open, scheme: "biandan-dev").absoluteString, "biandan-dev://open")
        XCTAssertEqual(WidgetShared.parse(URL(string: "biandan://occurrence/o123")!, scheme: "biandan"), .occurrence("o123"))
        XCTAssertEqual(WidgetShared.parse(URL(string: "BIANDAN://open")!, scheme: "biandan"), .open)
        XCTAssertEqual(WidgetShared.parse(URL(string: "biandan://occurrence/")!, scheme: "biandan"), .open)
        XCTAssertNil(WidgetShared.parse(URL(string: "biandan-dev://open")!, scheme: "biandan"), "开发版的链接不归正式版")
        XCTAssertNil(WidgetShared.parse(URL(string: "biandan://delete/o1")!, scheme: "biandan"))
        XCTAssertNil(WidgetShared.parse(URL(string: "https://example.com")!, scheme: "biandan"))
        // 往返
        let id = "o-1_2.3"
        XCTAssertEqual(WidgetShared.parse(WidgetShared.url(.occurrence(id), scheme: "biandan"), scheme: "biandan"), .occurrence(id))
    }

    func testIntentWhen() {
        XCTAssertEqual(IntentSupport.when(today, LocalTime(hour: 14, minute: 30), today: today), "今天 14:30")
        XCTAssertEqual(IntentSupport.when(today.adding(days: 1), nil, today: today), "明天")
        XCTAssertEqual(IntentSupport.when(LocalDate(iso: "2026-12-05"), nil, today: today), "12月5日")
        XCTAssertEqual(IntentSupport.when(nil, nil, today: today), "无日期")
    }
}
