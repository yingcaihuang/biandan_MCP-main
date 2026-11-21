import XCTest
@testable import BiandanMac

/// 规则识别：从整句聊天里找日程。今天是 2026-11-20（周五），一周从周一开始。
final class SentenceScheduleParserTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> LocalDate {
        LocalDate(year: year, month: month, day: day)!
    }

    private func clock(_ hour: Int, _ minute: Int = 0) -> LocalTime {
        LocalTime(hour: hour, minute: minute)!
    }

    private func parse(_ text: String, base: LocalDate? = nil) -> [SentenceScheduleParser.Event] {
        SentenceScheduleParser.parse(text, base: base ?? today, weekStart: 1)
    }

    func testTimeInMiddleOfSentence() {
        let found = parse("我们明天下午三点在3楼开会")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "3楼开会")
        XCTAssertEqual(found[0].date, day(11, 21))
        XCTAssertEqual(found[0].start, clock(15))
    }

    func testNextWeekdayAndHalfHour() {
        let found = parse("下周二下午两点半去腾讯开会")
        XCTAssertEqual(found.map(\.title), ["去腾讯开会"])
        XCTAssertEqual(found[0].date, day(11, 24))
        XCTAssertEqual(found[0].start, clock(14, 30))
    }

    func testTwoEventsInOneSentenceShareDate() {
        let found = parse("明天上午十点评审，下午三点复盘")
        XCTAssertEqual(found.map(\.title), ["评审", "复盘"])
        XCTAssertEqual(found.map(\.date), [day(11, 21), day(11, 21)])
        XCTAssertEqual(found.map(\.start), [clock(10), clock(15)])
    }

    func testTimeRange() {
        let found = parse("周五下午3:00-4:30 项目周会")
        XCTAssertEqual(found.map(\.title), ["项目周会"])
        XCTAssertEqual(found[0].date, today)
        XCTAssertEqual(found[0].start, clock(15))
        XCTAssertEqual(found[0].end, clock(16, 30))
    }

    func testMonthDayAndTonight() {
        let review = parse("11月24日 14:00 产品评审")
        XCTAssertEqual(review.map(\.title), ["产品评审"])
        XCTAssertEqual(review[0].date, day(11, 24))
        XCTAssertEqual(review[0].start, clock(14))

        let dinner = parse("今晚7点吃饭")
        XCTAssertEqual(dinner.map(\.title), ["吃饭"])
        XCTAssertEqual(dinner[0].date, today)
        XCTAssertEqual(dinner[0].start, clock(19))
    }

    func testWeekendAndDayOfMonth() {
        let hike = parse("这周末去爬山")
        XCTAssertEqual(hike.map(\.title), ["去爬山"])
        XCTAssertEqual(hike[0].date, day(11, 21))
        XCTAssertNil(hike[0].start)

        let report = parse("28号交报告")
        XCTAssertEqual(report.map(\.title), ["交报告"])
        XCTAssertEqual(report[0].date, day(11, 28))

        // 「3号楼」不是日期。
        XCTAssertTrue(parse("3号楼开会").isEmpty)
    }

    func testNotTimes() {
        XCTAssertTrue(parse("快一点处理一下").isEmpty)
        XCTAssertTrue(parse("好的收到").isEmpty)
        XCTAssertTrue(parse("第1点：先把需求对齐").isEmpty)
    }

    func testQuestionAndCancel() {
        let ask = parse("明天有空吗？")
        XCTAssertEqual(ask.count, 1)
        XCTAssertTrue(ask[0].question)

        let cancel = parse("会议取消了，明天不开了")
        XCTAssertEqual(cancel.count, 1)
        XCTAssertTrue(cancel[0].cancelled)
    }

    func testVaguePeriod() {
        let found = parse("明天下午 打游戏")
        XCTAssertEqual(found.map(\.title), ["打游戏"])
        XCTAssertNil(found[0].start)
        XCTAssertEqual(found[0].vagueTime, "下午")
    }

    func testRelativeToMessageDate() {
        // 昨天（11/19）发的「明天」= 今天。
        let found = parse("明天下午三点开会", base: day(11, 19))
        XCTAssertEqual(found.first?.date, today)
    }

    // MARK: 整段聊天

    func testMeetingCardWithTopicAndPlace() {
        let lines = ChatTimestamp.annotate([
            "会议主题：Q4 复盘",
            "会议时间：2026年11月25日（周三）10:00-11:00",
            "会议地点：3 楼大会议室",
        ], today: today)
        let found = RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "Q4 复盘")
        XCTAssertEqual(found[0].date, day(11, 25))
        XCTAssertEqual(found[0].start, clock(10))
        XCTAssertEqual(found[0].end, clock(11))
        XCTAssertEqual(found[0].location, "3 楼大会议室")
        XCTAssertTrue(found[0].include)
    }

    func testChatTranscript() {
        let lines = ChatTimestamp.annotate([
            "张三",
            "昨天 14:32",
            "我们明天下午三点在3楼开会，记得带电脑",
            "好的收到",
            "14:00",
            "周日有空吗？一起吃饭",
        ], today: today)
        let found = RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: [])
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].date, today)
        XCTAssertEqual(found[0].start, clock(15))
        XCTAssertTrue(found[0].include)
        // 询问默认不勾选。
        XCTAssertEqual(found[1].date, day(11, 22))
        XCTAssertFalse(found[1].include)
    }

    func testDurationSetsEnd() {
        let ball = parse("下下周五下午3点打球 时间为2小时")
        XCTAssertEqual(ball.map(\.title), ["打球"])
        XCTAssertEqual(ball[0].date, day(12, 4))
        XCTAssertEqual(ball[0].start, clock(15))
        XCTAssertEqual(ball[0].end, clock(17))
        XCTAssertEqual(ball[0].durationMinutes, 120)

        let review = parse("明天上午10点评审，大概一个半小时")
        XCTAssertEqual(review.map(\.title), ["评审"])
        XCTAssertEqual(review[0].end, clock(11, 30))

        let dinner = parse("今晚7点吃饭 90分钟")
        XCTAssertEqual(dinner.map(\.title), ["吃饭"])
        XCTAssertEqual(dinner[0].end, clock(20, 30))

        let meeting = parse("周五下午3点开会半小时")
        XCTAssertEqual(meeting.map(\.title), ["开会"])
        XCTAssertEqual(meeting[0].end, clock(15, 30))

        let mixed = parse("明天下午2点开会1小时20分")
        XCTAssertEqual(mixed[0].end, clock(15, 20))
    }

    func testExplicitRangeWinsOverDuration() {
        let found = parse("下午3点到5点开会，时长1小时")
        XCTAssertEqual(found.map(\.title), ["开会"])
        XCTAssertEqual(found[0].start, clock(15))
        XCTAssertEqual(found[0].end, clock(17))
    }

    func testSingleTimeHasNoEnd() {
        // 只写了开始时刻：结束留空，添加时按默认 30 分钟。
        XCTAssertNil(parse("明天下午三点开会").first?.end)
        // 没写开始时刻时，时长只从标题里去掉。
        let found = parse("明天打球2小时")
        XCTAssertEqual(found.map(\.title), ["打球"])
        XCTAssertNil(found[0].start)
        XCTAssertNil(found[0].end)
    }

    func testChineseNumber() {
        XCTAssertEqual(SentenceScheduleParser.chineseNumber("两"), 2)
        XCTAssertEqual(SentenceScheduleParser.chineseNumber("十五"), 15)
        XCTAssertEqual(SentenceScheduleParser.chineseNumber("二十"), 20)
        XCTAssertEqual(SentenceScheduleParser.chineseNumber("四十五"), 45)
        XCTAssertEqual(SentenceScheduleParser.chineseNumber("90"), 90)
        XCTAssertNil(SentenceScheduleParser.chineseNumber("半"))
    }

    func testCleanTitle() {
        XCTAssertEqual(SentenceScheduleParser.cleanTitle("  记得的会议吧～"), "会议")
        XCTAssertEqual(SentenceScheduleParser.cleanTitle("会议时间：（）"), "")
    }
}
