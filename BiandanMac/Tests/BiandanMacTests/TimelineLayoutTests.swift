import AppKit
import SwiftUI
import XCTest
@testable import BiandanMac

final class TimelineLayoutTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func item(_ id: String, start: String, end: String, from: String = "00:00:00", to: String = "23:59:00",
                      done: Bool = false, important: Bool = false, remind: String? = nil) -> (RawRecord, RawRecord) {
        var attributes: JSONObject = [
            "id1": .string(id), "taskTitle": .string("任务 \(id)"), "taskContent": .string(""), "id3": .int(1),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(0),
            "isImportant": .int(important ? 1 : 0), "validStartTime": .string(from),
            "validEndTime": .string(to), "unitTimeNumber": .int(1),
        ]
        if let remind {
            attributes["isRemind"] = .int(1)
            attributes["remindTime"] = .string(remind)
        }
        let task = record(.task, "t\(id)", attributes)
        let occurrence = record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string(id), "startTime": .string(start), "endTime": .string(end),
            "validStartTime": .string(from), "validEndTime": .string(to),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? start + " 09:00:00" : ""),
        ])
        return (task, occurrence)
    }

    private func items(_ rows: [(RawRecord, RawRecord)]) -> [OccurrenceItem] {
        DataSnapshot(lists: [], tasks: rows.map(\.0), occurrences: rows.map(\.1), focus: [], lastPulledAt: nil)
            .items(OccurrenceQuery(status: .all))
    }

    private func sample() -> [OccurrenceItem] {
        items([
            item("1", start: "2026-11-21", end: "2026-11-21", from: "09:00:00", to: "10:30:00", done: true),
            item("2", start: "2026-11-21", end: "2026-11-21", from: "09:10:00", to: "09:10:00"),
            item("3", start: "2026-11-21", end: "2026-11-21", from: "09:20:00", to: "09:20:00", important: true),
            item("4", start: "2026-11-21", end: "2026-11-21"),
            item("5", start: "2026-11-20", end: "2026-11-21", from: "20:00:00", to: "08:00:00"),
            item("6", start: "2026-11-24", end: "2026-11-24", from: "10:00:00", to: "10:00:00"),
            item("7", start: "2026-11-24", end: "2026-11-24"),
            item("8", start: "2026-11-27", end: "2026-11-27", from: "10:30:00", to: "10:30:00"),
            item("9", start: "2026-11-18", end: "2026-11-18"),
        ])
    }

    func testDayLayout() throws {
        let layout = TimelineLayout.day(sample(), day: today)
        XCTAssertEqual(layout.allDay.map(\.id), ["4"])
        let marks = Dictionary(uniqueKeysWithValues: layout.timed.map { ($0.id, $0) })
        XCTAssertEqual(Set(marks.keys), ["1", "2", "3", "5"])
        // 跨天任务从 0 点开始，到 8 点结束。
        let overnight = try XCTUnwrap(marks["5"])
        XCTAssertEqual(overnight.start, 0)
        XCTAssertEqual(overnight.end, 8.0 / 24, accuracy: 0.0001)
        // 9:00、9:10、9:20 挨得太近，分到 3 层。
        XCTAssertEqual(try XCTUnwrap(marks["1"]).start, 9.0 / 24, accuracy: 0.0001)
        XCTAssertEqual(Set(["1", "2", "3"].compactMap { marks[$0]?.lane }), [0, 1, 2])
        XCTAssertEqual(overnight.lane, 0)
    }

    /// 全天任务设了时间提醒：按提醒时刻标空心点，不再算进「全天」。
    func testAllDayReminderIsMarked() throws {
        let layout = TimelineLayout.day(items([
            item("r", start: "2026-11-21", end: "2026-11-21", remind: "19:30:00"),
            item("a", start: "2026-11-21", end: "2026-11-21"),
        ]), day: today)
        XCTAssertEqual(layout.allDay.map(\.id), ["a"])
        let mark = try XCTUnwrap(layout.timed.first)
        XCTAssertEqual(mark.id, "r")
        XCTAssertTrue(mark.isReminder)
        XCTAssertEqual(mark.start, 19.5 / 24, accuracy: 0.0001)
        XCTAssertEqual(mark.end, mark.start)
    }

    func testLaneLimit() {
        let rows = (0..<5).map { index in
            item("\(index)", start: "2026-11-21", end: "2026-11-21",
                 from: String(format: "12:%02d:00", index), to: String(format: "12:%02d:00", index))
        }
        let marks = TimelineLayout.day(items(rows), day: today).timed
        XCTAssertEqual(marks.count, 5)
        XCTAssertTrue(marks.allSatisfy { $0.lane < TimelineLayout.maxLanes })
    }

    func testRangeGroupsAndTicks() {
        let week = ProgressRange.next7.bounds(today: today)
        let groups = TimelineLayout.range(sample(), start: week.start, end: week.end)
        XCTAssertEqual(groups.map(\.index), [0, 3, 6])
        XCTAssertEqual(groups[0].items.count, 5)
        XCTAssertEqual(groups[1].items.map(\.id).sorted(), ["6", "7"])
        XCTAssertEqual(TimelineLayout.rangeTicks(start: week.start, end: week.end), Array(0..<7))

        let month = ProgressRange.month.bounds(today: today)
        XCTAssertEqual(TimelineLayout.rangeTicks(start: month.start, end: month.end), [0, 4, 9, 14, 19, 24, 29])
        XCTAssertEqual(TimelineLayout.range(sample(), start: month.start, end: month.end).first?.day,
                       LocalDate(year: 2026, month: 11, day: 18)!)
    }

    /// 渲染到 /tmp/biandan-timeline-*.png，用于检查外观。
    @MainActor
    func testRenderStrips() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 11, minute: 40))!
        // 示例数据再加两条「全天 + 提醒」任务，检查空心点。
        let data = sample() + items([
            item("10", start: "2026-11-21", end: "2026-11-21", remind: "19:30:00"),
            item("11", start: "2026-11-21", end: "2026-11-21", remind: "15:00:00"),
        ])
        for range in ProgressRange.allCases {
            let strip = SummaryTimelineStrip(items: data, range: range, today: today, now: now,
                                             tint: { TimelineStyle.fallbackTint($0) })
                .frame(width: 760)
                .padding(16)
                .background(Theme.card)
            let renderer = ImageRenderer(content: strip.environment(\.colorScheme, .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "渲染失败")
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/biandan-timeline-\(range.rawValue).png"))
            XCTAssertGreaterThan(image.size.height, 30)
        }
    }
}
