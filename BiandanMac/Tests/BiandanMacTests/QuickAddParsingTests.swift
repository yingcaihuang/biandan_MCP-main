import XCTest
@testable import BiandanMac

/// 快速添加的日期、时刻、分类、重复写法。今天是 2026-11-20（周五），一周从周一开始。
final class QuickAddParsingTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    private func parse(_ text: String) -> QuickAddDraft {
        QuickAddParser.parse(text, today: today, weekStart: 1,
                             lists: [(id: "7", name: "工作"), (id: "8", name: "生活")])
    }

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> LocalDate {
        LocalDate(year: year, month: month, day: day)!
    }

    private func clock(_ hour: Int, _ minute: Int = 0) -> LocalTime {
        LocalTime(hour: hour, minute: minute)!
    }

    func testWeekdays() {
        XCTAssertEqual(parse("开会 周五").date, today)
        XCTAssertEqual(parse("开会 周一").date, day(11, 23))
        XCTAssertEqual(parse("开会 星期日").date, day(11, 22))
        XCTAssertEqual(parse("开会 下周三").date, day(11, 25))
        XCTAssertEqual(parse("开会 本周一").date, day(11, 16))
        XCTAssertEqual(parse("开会 下下周一").date, day(11, 30))
        XCTAssertEqual(parse("周一例会").title, "周一例会")
        XCTAssertFalse(parse("周一例会").dateSet)
    }

    func testDates() {
        XCTAssertEqual(parse("交材料 11月30日").date, day(11, 30))
        XCTAssertEqual(parse("交材料 1月5日").date, day(1, 5, 2027))
        XCTAssertEqual(parse("交材料 12/1").date, day(12, 1))
        XCTAssertEqual(parse("交材料 25号").date, day(11, 25))
        XCTAssertEqual(parse("交材料 10号").date, day(12, 10))
        XCTAssertEqual(parse("交材料 31号").date, day(12, 31))
        XCTAssertEqual(parse("交材料 2027-02-03").date, day(2, 3, 2027))
        XCTAssertEqual(parse("交材料 2月30日").title, "交材料 2月30日")
    }

    func testTimes() {
        let combined = parse("开会 明天下午3点")
        XCTAssertEqual(combined.title, "开会")
        XCTAssertEqual(combined.date, day(11, 21))
        XCTAssertEqual(combined.startTime, clock(15))
        XCTAssertNil(combined.endTime)
        XCTAssertEqual(parse("开会 下午 3点半").startTime, clock(15, 30))
        XCTAssertEqual(parse("开会 9点").startTime, clock(9))
        XCTAssertEqual(parse("开会 3点").startTime, clock(15))
        XCTAssertEqual(parse("开会 早上6点").startTime, clock(6))
        XCTAssertEqual(parse("开会 今晚8点").startTime, clock(20))
        XCTAssertEqual(parse("开会 今晚8点").date, today)
        XCTAssertEqual(parse("开会 十点一刻").startTime, clock(10, 15))
        XCTAssertEqual(parse("开会 周五15:00").date, today)
        let range = parse("开会 15:30-16:45")
        XCTAssertEqual(range.startTime, clock(15, 30))
        XCTAssertEqual(range.endTime, clock(16, 45))
        XCTAssertEqual(parse("开会 下午2点到4点").endTime, clock(16))
        XCTAssertEqual(parse("3点开会").title, "3点开会")
        XCTAssertNil(parse("3点开会").startTime)
        XCTAssertNil(parse("开会 25:00").startTime)
    }

    func testListTag() {
        let exact = parse("周报 @工作")
        XCTAssertEqual(exact.listID, "7")
        XCTAssertEqual(exact.title, "周报")
        XCTAssertEqual(parse("周报 @生").listID, "8")
        let unknown = parse("周报 @出差")
        XCTAssertNil(unknown.listID)
        XCTAssertEqual(unknown.title, "周报 @出差")
    }

    func testRepeats() throws {
        let daily = parse("跑步 每天")
        XCTAssertEqual(daily.repeatRule, RepeatRule(mode: .daily, durationDays: 1))
        XCTAssertEqual(daily.date, today)
        XCTAssertEqual(daily.repeatText, "每天")

        let weekly = parse("健身 每周一三五8点")
        XCTAssertEqual(weekly.repeatRule, RepeatRule(mode: .custom, unit: .week, interval: 1, dates: ["1", "3", "5"],
                                                     dayFilter: .all, durationDays: 1))
        XCTAssertEqual(weekly.date, today, "今天是周五，正好在规则里")
        XCTAssertEqual(weekly.startTime, clock(8))
        XCTAssertEqual(weekly.repeatText, "每周一、三、五")

        let monthly = parse("交房租 每月15号")
        XCTAssertEqual(monthly.repeatRule?.dates, ["15"])
        XCTAssertEqual(monthly.date, day(12, 15))
        XCTAssertEqual(parse("还款 每月最后一天").date, day(11, 30))

        let biweekly = parse("周会 每两周")
        XCTAssertEqual(biweekly.repeatRule?.interval, 2)
        XCTAssertEqual(biweekly.repeatRule?.dates, ["5"])

        let yearly = parse("生日 每年3月5日")
        XCTAssertEqual(yearly.repeatRule?.dates, ["03-05"])
        XCTAssertEqual(yearly.date, day(3, 5, 2027))

        XCTAssertEqual(parse("站会 工作日 9:30").repeatRule?.mode, .workdays)
        XCTAssertEqual(parse("打扫 每周末").repeatRule?.dates, ["6", "0"])

        let habit = parse("早起 #习惯")
        XCTAssertTrue(habit.habit)
        XCTAssertEqual(habit.repeatRule?.mode, .daily)

        XCTAssertEqual(parse("每天都要开心").title, "每天都要开心")
        XCTAssertNil(parse("每天都要开心").repeatRule)

        let input = try XCTUnwrap(QuickAddParser.input(weekly, preset: NewTaskPreset()))
        XCTAssertEqual(input.startDate, today)
        XCTAssertEqual(input.endDate, today.adding(days: 364))
        XCTAssertEqual(input.startTime, clock(8))
        XCTAssertEqual(input.endTime, clock(8, 30))
        XCTAssertEqual(input.reminderDate, today)
        XCTAssertEqual(input.reminderTime, clock(8))
    }

    func testTimeWithoutDateUsesToday() throws {
        let input = try XCTUnwrap(QuickAddParser.input(parse("开会 无日期 23:45"), preset: NewTaskPreset()))
        XCTAssertEqual(input.startDate, today)
        XCTAssertEqual(input.endTime, clock(23, 59), "默认 30 分钟，不跨过当天")
    }

    func testChineseNumbers() {
        XCTAssertEqual(QuickAddParser.number("十"), 10)
        XCTAssertEqual(QuickAddParser.number("十五"), 15)
        XCTAssertEqual(QuickAddParser.number("二十三"), 23)
        XCTAssertEqual(QuickAddParser.number("两"), 2)
        XCTAssertNil(QuickAddParser.number("百"))
    }
}
