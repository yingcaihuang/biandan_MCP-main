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
        XCTAssertEqual(found[0].title, "开会")
        XCTAssertEqual(found[0].location, "3楼")
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

    func testFuzzyMonthDates() {
        let conf = parse("12月中旬参加腾讯开发大会")
        XCTAssertEqual(conf.map(\.title), ["参加腾讯开发大会"])
        XCTAssertEqual(conf[0].date, day(12, 11))
        XCTAssertEqual(conf[0].vagueDate, "12月中旬")
        XCTAssertNil(conf[0].start)

        XCTAssertEqual(parse("十二月底年会").first?.date, day(12, 31))
        XCTAssertEqual(parse("月底交报告").first?.date, day(11, 30))
        XCTAssertEqual(parse("下个月初去体检").first?.date, day(12, 1))
        XCTAssertEqual(parse("本月下旬出差").first?.date, day(11, 21))
        // 这段时间已经开始还没过完：取当天。
        XCTAssertEqual(parse("这个月中旬开会").first?.date, today)
        // 月份已经过去：算明年。
        XCTAssertEqual(parse("1月上旬去旅行").first?.date, day(1, 1, 2027))
        // 精确日期不算模糊。
        XCTAssertNil(parse("11月24日 14:00 产品评审").first?.vagueDate)
        // 「三个月中」不是日期。
        XCTAssertTrue(parse("三个月中完成").isEmpty)
    }

    func testScreenshotSentenceWithPlaceAndYear() {
        // 截图：编辑器第 3 行，OCR 带上了行号。
        for text in ["阿里开发大会，明年5月15号，下午15:30在杭州西湖区文三社区举行",
                     "3 阿里开发大会，明年5月15号，下午15:30在杭州西湖区文三社区举行"] {
            let found = parse(text)
            XCTAssertEqual(found.map(\.title), ["阿里开发大会"], text)
            XCTAssertEqual(found.first?.date, day(5, 15, 2027))
            XCTAssertEqual(found.first?.start, clock(15, 30))
            XCTAssertEqual(found.first?.location, "杭州西湖区文三社区")
            XCTAssertNil(found.first?.vagueDate)
            XCTAssertFalse(found.first?.source.hasPrefix("3") ?? true)
        }
        let trip = parse("明年5月去旅行")
        XCTAssertEqual(trip.first?.date, day(5, 1, 2027))
        XCTAssertEqual(trip.first?.vagueDate, "明年5月")
        XCTAssertEqual(parse("后年3月中旬搬家").first?.date, day(3, 11, 2028))
        // 数字后面紧跟「点」时不当行号去掉；OCR 多出的空格不影响（没写上下午的 3 点按快速添加规则算下午）。
        XCTAssertNotNil(parse("明天3 点开会").first?.start)
        XCTAssertEqual(parse("明天3 点开会").first?.start, parse("明天3点开会").first?.start)
        XCTAssertEqual(parse("明天3 点开会").first?.title, "开会")
    }

    func testPlaces() {
        XCTAssertEqual(SentenceScheduleParser.extractPlace("在家吃饭")?.place, "家")
        XCTAssertEqual(SentenceScheduleParser.extractPlace("在家吃饭")?.rest, "吃饭")
        XCTAssertEqual(SentenceScheduleParser.extractPlace("在公司见客户")?.rest, "见客户")
        XCTAssertEqual(SentenceScheduleParser.extractPlace("开会，在腾讯滨海大厦")?.place, "腾讯滨海大厦")
        XCTAssertNil(SentenceScheduleParser.extractPlace("现在开会"))
        XCTAssertNil(SentenceScheduleParser.extractPlace("正在吃饭"))
        XCTAssertNil(SentenceScheduleParser.extractPlace("我在想办法"))

        let found = parse("周五下午3点在3楼302会议室开会")
        XCTAssertEqual(found.first?.title, "开会")
        XCTAssertEqual(found.first?.location, "3楼302会议室")
    }

    func testCandidateLocationInput() {
        var candidate = ScheduleCandidate(title: "阿里开发大会")
        candidate.location = "杭州西湖区文三社区"
        XCTAssertEqual(candidate.input(listID: "1")?.location?.name, "杭州西湖区文三社区")
        XCTAssertNil(candidate.input(listID: "1")?.location?.latitude)
        candidate.latitude = 30.28
        candidate.longitude = 120.13
        let input = candidate.input(listID: "1")!
        XCTAssertEqual(input.location?.latitude, 30.28)
        XCTAssertEqual(input.location?.longitude, 120.13)
        XCTAssertNil(input.location?.remind)
        XCTAssertEqual(candidate.locateQuery, "杭州西湖区文三社区")
        candidate.locationQuery = "杭州市西湖区文三社区"
        XCTAssertEqual(candidate.locateQuery, "杭州市西湖区文三社区")
        XCTAssertNil(ScheduleCandidate(title: "买礼物").input(listID: "1")?.location)
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
