import CoreGraphics
import XCTest
@testable import BiandanMac

/// 浮窗球识别日程的纯逻辑部分。今天是 2026-11-20（周五）。
final class ScheduleCaptureTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> LocalDate {
        LocalDate(year: year, month: month, day: day)!
    }

    private func clock(_ hour: Int, _ minute: Int = 0) -> LocalTime {
        LocalTime(hour: hour, minute: minute)!
    }

    // MARK: OCR 排版

    func testOCRLinesReadTopToBottomLeftToRight() {
        let fragments = [
            OCRFragment(text: "下午3点", box: CGRect(x: 0.5, y: 0.70, width: 0.2, height: 0.05)),
            OCRFragment(text: "明天", box: CGRect(x: 0.1, y: 0.71, width: 0.2, height: 0.05)),
            OCRFragment(text: "好的", box: CGRect(x: 0.1, y: 0.40, width: 0.2, height: 0.05)),
            OCRFragment(text: "张三", box: CGRect(x: 0.1, y: 0.90, width: 0.2, height: 0.05)),
            OCRFragment(text: "   ", box: CGRect(x: 0.1, y: 0.20, width: 0.2, height: 0.05)),
        ]
        XCTAssertEqual(OCRLayout.lines(fragments), ["张三", "明天 下午3点", "好的"])
    }

    // MARK: 聊天消息时间

    func testChatTimestamps() {
        XCTAssertEqual(ChatTimestamp.date(of: "14:32", today: today), today)
        XCTAssertEqual(ChatTimestamp.date(of: "下午 3:05", today: today), today)
        XCTAssertEqual(ChatTimestamp.date(of: "昨天 14:32", today: today), day(11, 19))
        XCTAssertEqual(ChatTimestamp.date(of: "前天 09:00", today: today), day(11, 18))
        XCTAssertEqual(ChatTimestamp.date(of: "星期三 10:20", today: today), day(11, 18))
        // 和今天同一个星期几：指上周那天。
        XCTAssertEqual(ChatTimestamp.date(of: "周五 10:20", today: today), day(11, 13))
        XCTAssertEqual(ChatTimestamp.date(of: "11月20日 09:15", today: today), today)
        XCTAssertEqual(ChatTimestamp.date(of: "11/18 09:15", today: today), day(11, 18))
        // 不写年份、比今天晚：是去年的。
        XCTAssertEqual(ChatTimestamp.date(of: "12月25日 09:00", today: today), day(12, 25, 2025))
        XCTAssertEqual(ChatTimestamp.date(of: "2026年11月1日 08:00", today: today), day(11, 1))
        XCTAssertNil(ChatTimestamp.date(of: "明天下午3点开会", today: today))
        XCTAssertNil(ChatTimestamp.date(of: "好的", today: today))
    }

    func testAnnotateUsesMessageDate() {
        let lines = ChatTimestamp.annotate(["昨天 14:32", "明天下午3点 开会", "", "14:00", "后天 评审"], today: today)
        XCTAssertEqual(lines.map(\.text), ["昨天 14:32", "明天下午3点 开会", "14:00", "后天 评审"])
        XCTAssertEqual(lines.map(\.messageDate), [day(11, 19), day(11, 19), today, today])
        XCTAssertEqual(lines.map(\.isTimestamp), [true, false, true, false])
        let prompt = ChatTimestamp.promptText(lines)
        XCTAssertTrue(prompt.hasPrefix("【消息时间：2026-11-19 周四】\n明天下午3点 开会"))
    }

    // MARK: 规则识别

    func testRuleExtractorResolvesAgainstMessageDate() {
        let lines = ChatTimestamp.annotate(["昨天 14:32", "明天下午3点 开会", "好的收到", "14:00", "后天 评审"],
                                           today: today)
        let found = RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: [])
        XCTAssertEqual(found.map(\.title), ["开会", "评审"])
        // 昨天发的「明天」= 今天。
        XCTAssertEqual(found[0].date, today)
        XCTAssertEqual(found[0].start, clock(15))
        XCTAssertEqual(found[1].date, day(11, 22))
        XCTAssertTrue(found.allSatisfy(\.include))
    }

    /// 「明天下午 打游戏」：只有时段没有时刻，「下午」不留在标题里，记下来提示补时刻。
    func testRuleExtractorDropsVaguePeriodFromTitle() {
        let lines = ChatTimestamp.annotate(["明天下午 打游戏"], today: today)
        let found = RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: [])
        XCTAssertEqual(found.map(\.title), ["打游戏"])
        XCTAssertEqual(found.first?.date, day(11, 21))
        XCTAssertNil(found.first?.start)
        XCTAssertEqual(found.first?.vagueTime, "下午")
    }

    // MARK: 模型输出

    func testFromModelValidatesFields() {
        let ok = ScheduleCandidate.fromModel(title: "  和腾讯开会 ", startDate: "2026-11-24", startTime: "14:30",
                                             endDate: "", endTime: "15:00", location: "腾讯大厦",
                                             source: "下周二下午两点半去腾讯开会", today: today)!
        XCTAssertEqual(ok.title, "和腾讯开会")
        XCTAssertEqual(ok.date, day(11, 24))
        XCTAssertNil(ok.endDate)
        XCTAssertEqual(ok.start, clock(14, 30))
        XCTAssertEqual(ok.end, clock(15))
        XCTAssertTrue(ok.include)
        XCTAssertNil(ok.note)

        // 日期写法不对 → 当作无日期，提示用户。
        let noDate = ScheduleCandidate.fromModel(title: "评审", startDate: "下周二", startTime: "", endDate: "",
                                                 endTime: "", location: "", source: "", today: today)!
        XCTAssertNil(noDate.date)
        XCTAssertNotNil(noDate.note)

        // 结束早于开始 → 去掉结束；日期已过去 → 默认不勾选。
        let past = ScheduleCandidate.fromModel(title: "复盘", startDate: "2026-11-18", startTime: "16:00",
                                               endDate: "", endTime: "15:00", location: "", source: "", today: today)!
        XCTAssertNil(past.end)
        XCTAssertFalse(past.include)
        XCTAssertNotNil(past.note)

        // 跨天。
        let trip = ScheduleCandidate.fromModel(title: "出差", startDate: "2026-11-24", startTime: "",
                                               endDate: "2026-11-26", endTime: "", location: "", source: "",
                                               today: today)!
        XCTAssertEqual(trip.endDate, day(11, 26))

        XCTAssertNil(ScheduleCandidate.fromModel(title: "  ", startDate: "2026-11-24", startTime: "", endDate: "",
                                                 endTime: "", location: "", source: "", today: today))
    }

    // MARK: 新建参数

    func testCandidateInput() {
        var candidate = ScheduleCandidate(title: "和腾讯开会")
        candidate.date = day(11, 24)
        candidate.start = clock(14, 30)
        candidate.location = "腾讯大厦"
        candidate.source = "下周二下午两点半去腾讯开会"
        let input = candidate.input(listID: "7")!
        XCTAssertEqual(input.listID, "7")
        XCTAssertEqual(input.startDate, day(11, 24))
        XCTAssertEqual(input.endDate, day(11, 24))
        XCTAssertEqual(input.startTime, clock(14, 30))
        // 没写结束：按 30 分钟。
        XCTAssertEqual(input.endTime, clock(15))
        XCTAssertEqual(input.reminderDate, day(11, 24))
        XCTAssertEqual(input.reminderTime, clock(14, 30))
        XCTAssertEqual(input.remark, "地点：腾讯大厦\n原文：下周二下午两点半去腾讯开会")
        // 默认不重要不紧急；选了象限就写进重要 / 紧急。
        XCTAssertFalse(input.important)
        XCTAssertFalse(input.urgent)
        candidate.quadrant = .importantNotUrgent
        let important = candidate.input(listID: "7")!
        XCTAssertTrue(important.important)
        XCTAssertFalse(important.urgent)

        var trip = ScheduleCandidate(title: "出差")
        trip.date = day(11, 24)
        trip.endDate = day(11, 26)
        let tripInput = trip.input(listID: "7")!
        XCTAssertEqual(tripInput.endDate, day(11, 26))
        XCTAssertNil(tripInput.startTime)

        let undated = ScheduleCandidate(title: "买礼物").input(listID: "7")!
        XCTAssertNil(undated.startDate)
        XCTAssertNil(ScheduleCandidate(title: " ").input(listID: "7"))
    }

    func testClockText() {
        XCTAssertEqual(ClockText.parse("9:05"), clock(9, 5))
        XCTAssertEqual(ClockText.parse("14：30"), clock(14, 30))
        XCTAssertEqual(ClockText.parse("14:30:00"), clock(14, 30))
        XCTAssertNil(ClockText.parse(""))
        XCTAssertNil(ClockText.parse("25:00"))
        XCTAssertNil(ClockText.parse("下午"))
    }
}
