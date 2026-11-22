import XCTest
@testable import BiandanMac

/// 快速添加接 AI：AI 结果和本机标记合并、网址邮箱进备注；备注里的链接识别。
final class QuickAddAITests: XCTestCase {
    let today = LocalDate(iso: "2026-11-22")!

    private var preset: NewTaskPreset {
        var preset = NewTaskPreset()
        preset.date = today
        return preset
    }

    func testRulesMovesLinkToRemark() {
        let text = "产研周例会 https://vc-jp.larksuite.com/j/411775911"
        var draft = QuickAddDraft(title: text)
        draft.today = today
        let input = QuickAddAI.rulesInput(draft, preset: preset, text: text)
        XCTAssertEqual(input?.title, "产研周例会")
        XCTAssertEqual(input?.remark, "https://vc-jp.larksuite.com/j/411775911")
    }

    func testMergeKeepsExplicitMarks() throws {
        let text = "后天上午10点到11点产研周例会 视频会议 https://vc-jp.larksuite.com/j/411775911 @工作 #重要"
        let candidate = try XCTUnwrap(ScheduleCandidate.fromModel(
            title: "产研周例会", startDate: "2026-11-24", startTime: "10:00", endDate: "", endTime: "11:00",
            location: "", source: text, today: today))
        var draft = QuickAddDraft(title: "产研周例会")
        draft.listID = "work"
        draft.important = true
        draft.today = today
        let input = try XCTUnwrap(QuickAddAI.merge(candidate, draft: draft, preset: preset, text: text))
        XCTAssertEqual(input.title, "产研周例会")
        XCTAssertEqual(input.listID, "work")
        XCTAssertTrue(input.important)
        XCTAssertEqual(input.startDate, LocalDate(iso: "2026-11-24"))
        XCTAssertEqual(input.startTime, LocalTime(hour: 10, minute: 0))
        XCTAssertEqual(input.endTime, LocalTime(hour: 11, minute: 0))
        XCTAssertEqual(input.remark, "https://vc-jp.larksuite.com/j/411775911")
        XCTAssertFalse(input.remark.contains("原文"))
    }

    func testMergeWithoutDateUsesPreset() throws {
        let candidate = try XCTUnwrap(ScheduleCandidate.fromModel(
            title: "买牛奶", startDate: "", startTime: "", endDate: "", endTime: "", location: "", source: "",
            today: today))
        var draft = QuickAddDraft(title: "买牛奶")
        draft.today = today
        let input = try XCTUnwrap(QuickAddAI.merge(candidate, draft: draft, preset: preset, text: "买牛奶"))
        XCTAssertEqual(input.startDate, today)
        XCTAssertEqual(input.remark, "")
    }

    func testDetectLinks() {
        let links = NoteLinks.detect("视频会议: https://vc-jp.larksuite.com/j/411775911 有问题发 blender.huang@racore.ai，安装包 Biandan.app")
        XCTAssertEqual(links.map(\.text), ["https://vc-jp.larksuite.com/j/411775911", "blender.huang@racore.ai"])
        XCTAssertEqual(links.last?.url.absoluteString, "mailto:blender.huang@racore.ai")
        XCTAssertEqual(links.last?.isEmail, true)
        XCTAssertEqual(NoteLinks.detect("会议链接 https://a.example.com/j/1请准时").first?.text, "https://a.example.com/j/1")
        XCTAssertTrue(NoteLinks.detect("版本 1.2.0，打包 Biandan.app").isEmpty)
    }

    func testAttributedAndStrip() {
        let value = NoteLinks.attributed("见 https://x.example.com/a")
        XCTAssertEqual(value.runs.compactMap(\.link).first?.absoluteString, "https://x.example.com/a")
        let split = NoteLinks.strip("视频会议: https://x.example.com/a")
        XCTAssertEqual(split.rest, "视频会议")
        XCTAssertEqual(split.links, ["https://x.example.com/a"])
    }
}
