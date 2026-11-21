import AppKit
import SwiftUI
import XCTest
@testable import BiandanMac

/// 时间条上的冲突标注。今天是 2026-11-21，现在 10:00。
final class TimelineConflictTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!
    private let now = 10 * 60

    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func row(_ id: String, _ day: String, _ from: String, _ to: String,
                     done: Bool = false) -> (RawRecord, RawRecord) {
        let task = record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string("任务 \(id)"), "taskContent": .string(""), "id3": .int(1),
            "startTime": .string(day), "endTime": .string(day), "haveNoTime": .int(0),
            "validStartTime": .string(from), "validEndTime": .string(to), "unitTimeNumber": .int(1),
        ])
        let occurrence = record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string(id), "startTime": .string(day), "endTime": .string(day),
            "validStartTime": .string(from), "validEndTime": .string(to),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? day + " 09:00:00" : ""),
        ])
        return (task, occurrence)
    }

    private func sample() -> [OccurrenceItem] {
        let rows = [
            row("a", "2026-11-21", "13:00:00", "14:00:00"),
            row("b", "2026-11-21", "13:30:00", "15:00:00"),
            row("c", "2026-11-21", "14:30:00", "16:00:00"),
            row("x", "2026-11-21", "13:15:00", "13:45:00", done: true),  // 已完成，不算
            row("d", "2026-11-21", "08:00:00", "09:00:00"),             // 今天已结束，不算
            row("e", "2026-11-21", "08:30:00", "09:30:00"),
            row("f", "2026-11-23", "10:00:00", "11:00:00"),
            row("g", "2026-11-23", "10:30:00", "11:30:00"),
            row("h", "2026-11-19", "10:00:00", "11:00:00"),             // 已过去的日子，不算
            row("i", "2026-11-19", "10:30:00", "11:30:00"),
            row("j", "2026-11-21", "18:00:00", "19:00:00"),             // 不冲突
        ]
        return DataSnapshot(lists: [], tasks: rows.map(\.0), occurrences: rows.map(\.1), focus: [], lastPulledAt: nil)
            .items(OccurrenceQuery(status: .all))
    }

    func testTodaySpansAndPartners() {
        let conflicts = ScheduleConflicts.timeline(sample(), from: today, to: today, today: today, now: now)
        XCTAssertEqual(conflicts.groups.count, 1, "上午那组已结束，只剩下午一组")
        XCTAssertEqual(conflicts.spans(on: today), [MinuteSpan(start: 810, end: 840), MinuteSpan(start: 870, end: 900)],
                       "a∩b 13:30–14:00、b∩c 14:30–15:00 两段分开标")
        XCTAssertTrue(conflicts.isConflicting("a"))
        XCTAssertTrue(conflicts.isConflicting("b"))
        XCTAssertTrue(conflicts.isConflicting("c"))
        XCTAssertFalse(conflicts.isConflicting("x"), "已完成的不算")
        XCTAssertFalse(conflicts.isConflicting("d"), "今天已结束的不算")
        XCTAssertFalse(conflicts.isConflicting("j"))
        XCTAssertEqual(ScheduleConflicts.tooltipText(conflicts.partners["a"] ?? []), "与「任务 b」冲突 13:30–14:00")
        XCTAssertEqual(ScheduleConflicts.tooltipText(conflicts.partners["b"] ?? []), "与「任务 a」等 2 项时间冲突")
        XCTAssertNil(ScheduleConflicts.tooltipText([]))
    }

    func testRangeSkipsPastDays() {
        let week = ScheduleConflicts.timeline(sample(), from: today, to: today.adding(days: 6), today: today, now: now)
        XCTAssertEqual(week.days, [today, LocalDate(year: 2026, month: 11, day: 23)!])
        let month = ScheduleConflicts.timeline(sample(), from: LocalDate(year: 2026, month: 11, day: 1)!,
                                               to: LocalDate(year: 2026, month: 11, day: 30)!, today: today, now: now)
        XCTAssertFalse(month.days.contains(LocalDate(year: 2026, month: 11, day: 19)!), "已过去的日子不标冲突")
        XCTAssertTrue(ScheduleConflicts.timeline(sample(), from: LocalDate(year: 2026, month: 11, day: 1)!,
                                                 to: LocalDate(year: 2026, month: 11, day: 20)!,
                                                 today: today, now: now).isEmpty)
    }

    func testOverlapSpansMerge() {
        // 三项同时重叠时，两两重叠的部分合并成一段。
        let rows = [row("p", "2026-11-23", "10:00:00", "12:00:00"),
                    row("q", "2026-11-23", "10:30:00", "11:30:00"),
                    row("r", "2026-11-23", "11:00:00", "12:30:00")]
        let items = DataSnapshot(lists: [], tasks: rows.map(\.0), occurrences: rows.map(\.1), focus: [],
                                 lastPulledAt: nil).items(OccurrenceQuery(status: .all))
        let day = LocalDate(year: 2026, month: 11, day: 23)!
        let conflicts = ScheduleConflicts.timeline(items, from: day, to: day, today: today, now: now)
        XCTAssertEqual(conflicts.spans(on: day), [MinuteSpan(start: 630, end: 720)])
    }

    /// 渲染到 /tmp/biandan-timeline-conflict-<range>.png，用来目测红色斜纹和红环。
    @MainActor
    func testRenderConflictStrips() throws {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 21; parts.hour = 10
        let date = try XCTUnwrap(Calendar.current.date(from: parts))
        for range in [ProgressRange.today, .next7] {
            let strip = SummaryTimelineStrip(items: sample(), range: range, today: today, now: date,
                                             tint: { TimelineStyle.fallbackTint($0) })
                .frame(width: 640)
                .padding(16)
                .background(Theme.card)
            let renderer = ImageRenderer(content: strip.environment(\.colorScheme, .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "渲染失败")
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/biandan-timeline-conflict-\(range.rawValue).png"))
            XCTAssertGreaterThan(image.size.height, 30)
        }
    }
}
