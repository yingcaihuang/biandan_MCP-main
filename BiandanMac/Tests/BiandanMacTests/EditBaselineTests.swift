import XCTest
@testable import BiandanMac

/// 检查器编辑区：同一任务来了新版本时按分区合并草稿。
final class EditBaselineTests: XCTestCase {
    private func day(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_796_000_000 + offset * 86_400) }

    private func baseline(title: String = "参加腾讯分享会", remark: String = "",
                          start: Double = 0, end: Double = 0,
                          remindOn: Bool = false, location: String = "",
                          target: Int = 1) -> EditBaseline {
        EditBaseline(
            text: .init(title: title, remark: remark),
            schedule: .init(hasDate: true, hasTime: false, startDay: day(start), endDay: day(end),
                            startClock: day(start), endClock: day(end)),
            reminder: .init(on: remindOn, at: day(start)),
            location: .init(name: location, latitude: "", longitude: "", remind: false),
            goal: .init(checklist: false, targetCount: target, subtasks: []))
    }

    func testUntouchedDraftTakesNewVersion() {
        let old = baseline()
        let new = baseline(title: "新标题", end: 1, remindOn: true, location: "深圳", target: 3)
        XCTAssertEqual(EditBaseline.merge(draft: old, old: old, new: new), new)
    }

    func testEditedSectionKeepsDraftOthersUpdate() {
        let old = baseline()
        var draft = old
        draft.schedule.endDay = day(1)          // 改了结束日期，还没保存
        let new = baseline(title: "云端改了标题", location: "深圳")
        let merged = EditBaseline.merge(draft: draft, old: old, new: new)
        XCTAssertEqual(merged.schedule, draft.schedule, "改过的时间分区保留草稿")
        XCTAssertEqual(merged.text, new.text, "没改过的标题跟着新版本")
        XCTAssertEqual(merged.location, new.location, "没改过的地点跟着新版本")
    }

    func testEditedTitleIsKept() {
        let old = baseline()
        var draft = old
        draft.text.title = "我正在改的标题"
        let new = baseline(title: "云端标题", end: 2)
        let merged = EditBaseline.merge(draft: draft, old: old, new: new)
        XCTAssertEqual(merged.text.title, "我正在改的标题")
        XCTAssertEqual(merged.schedule, new.schedule)
    }

    func testTitleWhitespaceOnlyCountsAsUntouched() {
        // 和「保存」按钮一致：只多了首尾空白不算改动。
        let old = baseline()
        var draft = old
        draft.text.title = "参加腾讯分享会 "
        let new = baseline(title: "云端标题")
        XCTAssertEqual(EditBaseline.merge(draft: draft, old: old, new: new).text, new.text)
    }

    func testRemarkEditKeepsWholeTextSection() {
        let old = baseline()
        var draft = old
        draft.text.remark = "带上电脑"
        let new = baseline(title: "云端标题")
        XCTAssertEqual(EditBaseline.merge(draft: draft, old: old, new: new).text, draft.text)
    }

    func testVersionBumpAloneDoesNotChangeBaseline() {
        func make(version: Int) -> (TaskDef, Occurrence) {
            let task = TaskDef(record: RawRecord(kind: .task, cloudID: "t4", version: version, createdTime: nil,
                                                 editedTime: nil, attributes: [
                "id1": .string("4"), "taskTitle": .string("参加腾讯分享会"),
                "startTime": .string("2026-12-08"), "endTime": .string("2026-12-08"),
                "validStartTime": .string("10:30:00"), "validEndTime": .string("11:30:00"),
            ]))
            let occurrence = Occurrence(record: RawRecord(kind: .showTask, cloudID: "o4", version: version,
                                                          createdTime: nil, editedTime: nil, attributes: [
                "id1": .string("4"), "id2": .string("4"),
                "startTime": .string("2026-12-08"), "endTime": .string("2026-12-08"),
                "validStartTime": .string("10:30:00"), "validEndTime": .string("11:30:00"),
            ]))
            return (task, occurrence)
        }
        let (t1, o1) = make(version: 1)
        let (t2, o2) = make(version: 2)
        XCTAssertEqual(EditBaseline(task: t1, occurrence: o1), EditBaseline(task: t2, occurrence: o2),
                       "只有版本号变化时原值不变，编辑区不动草稿")
    }
}
