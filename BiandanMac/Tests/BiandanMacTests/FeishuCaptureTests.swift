import XCTest
@testable import BiandanMac

/// 飞书聊天截图的规则识别：截止日已过、近期日期不跳到明年、「3号会议室」、消息头。今天是 2026-11-22（周日）。
final class FeishuCaptureTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 22)!

    private func extract(_ raw: [String]) -> [ScheduleCandidate] {
        RuleScheduleExtractor.extract(ChatTimestamp.annotate(raw, today: today), today: today, weekStart: 1, lists: [])
    }

    func testOverdueDeadlineStaysThisYearAndChecked() {
        let found = extract([
            "Jerry，WO-000000000072（ctg项目漏洞修复）要求 11/13 前修复，现在已经超期一周，还是“待处理”。",
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.date, LocalDate(year: 2026, month: 11, day: 13))
        XCTAssertEqual(found.first?.include, true)
        XCTAssertEqual(found.first?.note, "截止日已经过去 9 天，添加后会显示为逾期")
    }

    func testPastMeetingIsThisYearButUnchecked() {
        let found = extract(["11/20 下午3点开会"])
        XCTAssertEqual(found.first?.date, LocalDate(year: 2026, month: 11, day: 20))
        XCTAssertEqual(found.first?.include, false)
    }

    func testFarPastMonthDayIsNextYear() {
        XCTAssertEqual(extract(["1/5 下午3点开会"]).first?.date, LocalDate(year: 2027, month: 1, day: 5))
        XCTAssertEqual(extract(["12/5 下午3点开会"]).first?.date, LocalDate(year: 2026, month: 12, day: 5))
    }

    func testRoomNumberIsNotDate() {
        let found = extract(["明天下午3点开个评审会，在3号会议室"])
        XCTAssertFalse(found.contains { $0.date == LocalDate(year: 2026, month: 12, day: 3) })
        XCTAssertEqual(found.first?.date, LocalDate(year: 2026, month: 11, day: 23))
        XCTAssertEqual(extract(["3号下午开会"]).first?.date, LocalDate(year: 2026, month: 12, day: 3))
    }

    func testSenderHeaderIsNotSchedule() {
        let raw = ["黄彬 10:32", "明天下午3点开个评审会", "Jerry.Law 10:35", "好的"]
        let lines = ChatTimestamp.annotate(raw, today: today)
        XCTAssertTrue(lines[0].isTimestamp)
        XCTAssertEqual(lines[0].sender, "黄彬")
        XCTAssertEqual(lines[2].sender, "Jerry.Law")
        let found = extract(raw)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.start, LocalTime(hour: 15, minute: 0))
    }

    func testScheduleWithTimeIsNotHeader() {
        XCTAssertNil(ChatTimestamp.sender(of: "评审 14:00"))
        XCTAssertNil(ChatTimestamp.sender(of: "开会 10:00"))
        XCTAssertNil(ChatTimestamp.sender(of: "明天 10:00"))
        XCTAssertNil(ChatTimestamp.sender(of: "Standup 09:30"))
        XCTAssertEqual(extract(["评审 14:00"]).count, 1)
    }

    func testSenderHeaderKeepsSeparatorDate() {
        let lines = ChatTimestamp.annotate(["11月20日 15:30", "王五 15:31", "明天上午10点对需求"], today: today)
        XCTAssertEqual(lines[1].messageDate, LocalDate(year: 2026, month: 11, day: 20))
        XCTAssertTrue(ChatTimestamp.promptText(lines).contains("【发送人：王五"))
    }
}
