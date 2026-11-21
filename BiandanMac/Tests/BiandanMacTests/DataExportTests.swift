import XCTest
@testable import BiandanMac

final class DataExportTests: XCTestCase {
    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 3, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, title: String, start: String, end: String,
                      from: String = "00:00:00", to: String = "23:59:00", undated: Bool = false) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string(title), "taskContent": .string(""), "id3": .string("1"),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(undated ? 1 : 0),
            "isLoop": .int(0), "loopSet": .int(0), "validStartTime": .string(from), "validEndTime": .string(to),
            "unitTimeNumber": .int(1),
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

    /// a 全天（标题带逗号）；b 15:00–15:30；c 无日期；d 已完成。
    private func snapshot() -> DataSnapshot {
        DataSnapshot(lists: [], tasks: [
            task("a", title: "开会, 准备", start: "2026-11-22", end: "2026-11-22"),
            task("b", title: "面试", start: "2026-11-23", end: "2026-11-23", from: "15:00:00", to: "15:30:00"),
            task("c", title: "读书", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("d", title: "已完成", start: "2026-11-20", end: "2026-11-20"),
        ], occurrences: [
            occurrence("a", start: "2026-11-22", end: "2026-11-22"),
            occurrence("b", start: "2026-11-23", end: "2026-11-23", from: "15:00:00", to: "15:30:00"),
            occurrence("c", start: "1970-01-01", end: "2100-12-31"),
            occurrence("d", start: "2026-11-20", end: "2026-11-20", done: true),
        ], focus: [], lastPulledAt: nil)
    }

    func testCSV() {
        XCTAssertEqual(DataExport.csvField("普通"), "普通")
        XCTAssertEqual(DataExport.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(DataExport.csvField("说\"好\""), "\"说\"\"好\"\"\"")
        XCTAssertEqual(DataExport.csvField("两\n行"), "\"两\n行\"")

        let csv = DataExport.occurrencesCSV(snapshot())
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}标题,分类,"))
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 5, "表头 + 4 个实例")
        XCTAssertTrue(csv.contains("\"开会, 准备\""))
        XCTAssertTrue(csv.contains("15:00,15:30"))

        let focus = DataExport.focusCSV(snapshot())
        XCTAssertEqual(focus.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 1)
    }

    func testCalendar() {
        let ics = DataExport.calendar(snapshot(), now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.hasSuffix("END:VCALENDAR\r\n"))
        XCTAssertEqual(ics.components(separatedBy: "BEGIN:VEVENT").count - 1, 2, "无日期、已完成的不导出")
        XCTAssertTrue(ics.contains("DTSTART;VALUE=DATE:20261122"))
        XCTAssertTrue(ics.contains("DTEND;VALUE=DATE:20261123"), "全天事件的结束日期不含当天")
        XCTAssertTrue(ics.contains("DTSTART:20261123T150000"))
        XCTAssertTrue(ics.contains("DTEND:20261123T153000"))
        XCTAssertTrue(ics.contains("SUMMARY:开会\\, 准备"))
        XCTAssertTrue(ics.contains("UID:oa@biandan"))
        XCTAssertTrue(ics.contains("DTSTAMP:19700101T000000Z"))
    }

    func testFoldAndEscape() {
        XCTAssertEqual(DataExport.icsText("a;b,c\\d\ne"), "a\\;b\\,c\\\\d\\ne")
        let long = "DESCRIPTION:" + String(repeating: "便单测试", count: 30)
        let folded = DataExport.fold(long)
        for line in folded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 75)
        }
        XCTAssertEqual(folded.replacingOccurrences(of: "\r\n ", with: ""), long)
        XCTAssertEqual(DataExport.fold("SHORT"), "SHORT")
    }

    func testBackupJSONKeepsRawFields() throws {
        let data = try DataExport.backupJSON(snapshot(), exportedAt: Date(timeIntervalSince1970: 0))
        let root = try JSONValue.parseObject(data)
        XCTAssertEqual(root.string("format"), "biandan-backup")
        guard case .object(let tables)? = root["tables"],
              case .array(let tasks)? = tables[RecordKind.task.rawValue],
              case .array(let occurrences)? = tables[RecordKind.showTask.rawValue],
              case .array(let lists)? = tables[RecordKind.favorites.rawValue] else {
            return XCTFail("备份结构不对")
        }
        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(occurrences.count, 4)
        XCTAssertEqual(lists.count, 0, "本地补出来的默认分类没有云端记录，不写进备份")
        guard case .object(let first)? = tasks.first, case .object(let attributes)? = first["attributes"] else {
            return XCTFail("缺少原始字段")
        }
        XCTAssertEqual(first["version"], .int(3))
        XCTAssertEqual(attributes.string("taskTitle"), "开会, 准备")
    }

    func testBackupRetention() {
        let names = (1...9).map { String(format: "biandan-backup-2026-11-%02d.json", $0) } + ["notes.txt"]
        XCTAssertEqual(LocalBackup.stale(names, limit: 7),
                       ["biandan-backup-2026-11-02.json", "biandan-backup-2026-11-01.json"])
        XCTAssertEqual(LocalBackup.stale(["notes.txt"], limit: 7), [])
        XCTAssertEqual(LocalBackup.fileName(LocalDate(year: 2026, month: 11, day: 21)!), "biandan-backup-2026-11-21.json")
        XCTAssertEqual(ExportFormat.calendarICS.fileName(LocalDate(year: 2026, month: 11, day: 21)!), "便单日历-2026-11-21.ics")
    }
}
