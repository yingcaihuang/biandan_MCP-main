import XCTest
@testable import BiandanMac

/// ICS 解析与导入规划。本机时区固定为上海，今天是 2026-11-21（周六），导入范围 10-22 ～ 明年 11-21。
final class ICSImportTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 21)!
    private var shanghai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> LocalDate {
        LocalDate(year: year, month: month, day: day)!
    }

    private func clock(_ hour: Int, _ minute: Int = 0) -> LocalTime {
        LocalTime(hour: hour, minute: minute)!
    }

    private func ics(_ events: String...) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "X-WR-CALNAME:飞书日历"] + events + ["END:VCALENDAR"])
            .joined(separator: "\r\n")
    }

    private func parse(_ text: String) -> ICSImportResult {
        ICSImport.parse(text, today: today, calendar: shanghai)
    }

    func testTimedEventsAndTimeZones() {
        let result = parse(ics(
            "BEGIN:VEVENT\r\nUID:a\r\nDTSTART;TZID=Asia/Shanghai:20261201T150000\r\nDTEND;TZID=Asia/Shanghai:20261201T163000\r\nSUMMARY:项目评审\r\nLOCATION:3楼大会议室\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:b\r\nDTSTART:20261201T070000Z\r\nDURATION:PT2H\r\nSUMMARY:UTC 时间\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:c\r\nDTSTART;TZID=China Standard Time:20261202T090000\r\nSUMMARY:没有结束\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:d\r\nDTSTART;TZID=/mozilla.org/20050126_1/Asia/Tokyo:20261203T100000\r\nDTEND;TZID=/mozilla.org/20050126_1/Asia/Tokyo:20261203T110000\r\nSUMMARY:东京\r\nEND:VEVENT"))
        XCTAssertEqual(result.name, "飞书日历")
        XCTAssertEqual(result.events.map(\.key), ["a", "b", "c", "d"])
        let a = result.events[0]
        XCTAssertEqual(a.startDate, day(12, 1))
        XCTAssertEqual(a.startTime, clock(15))
        XCTAssertEqual(a.endTime, clock(16, 30))
        XCTAssertEqual(a.location, "3楼大会议室")
        XCTAssertEqual(result.events[1].startTime, clock(15))
        XCTAssertEqual(result.events[1].endTime, clock(17))
        // 没有结束：默认 30 分钟。
        XCTAssertEqual(result.events[2].startTime, clock(9))
        XCTAssertEqual(result.events[2].endTime, clock(9, 30))
        // 东京 10:00 = 上海 9:00。
        XCTAssertEqual(result.events[3].startTime, clock(9))
        XCTAssertEqual(result.events[3].endTime, clock(10))
    }

    func testAllDayAndCrossDay() {
        let result = parse(ics(
            "BEGIN:VEVENT\r\nUID:trip\r\nDTSTART;VALUE=DATE:20261205\r\nDTEND;VALUE=DATE:20261208\r\nSUMMARY:出差\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:one\r\nDTSTART;VALUE=DATE:20261210\r\nSUMMARY:纪念日\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:night\r\nDTSTART:20261211T220000\r\nDTEND:20261212T013000\r\nSUMMARY:通宵发版\r\nEND:VEVENT"))
        XCTAssertEqual(result.events[0].startDate, day(12, 5))
        XCTAssertEqual(result.events[0].endDate, day(12, 7))
        XCTAssertTrue(result.events[0].isAllDay)
        XCTAssertEqual(result.events[1].endDate, day(12, 10))
        XCTAssertEqual(result.events[2].startDate, day(12, 11))
        XCTAssertEqual(result.events[2].endDate, day(12, 12))
        XCTAssertEqual(result.events[2].endTime, clock(1, 30))
    }

    func testFoldingEscapingAlarmAndGeo() {
        let event = [
            "BEGIN:VEVENT", "UID:f", "DTSTART:20261201T100000",
            "SUMMARY:项目\\, 评审", "DESCRIPTION:第一行\\n第二", " 行接续", "GEO:30.27;120.13",
            "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:提醒不算备注", "TRIGGER:-PT15M", "END:VALARM",
            "END:VEVENT",
        ].joined(separator: "\r\n")
        let found = parse(ics(event)).events
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "项目, 评审")
        XCTAssertEqual(found[0].notes, "第一行\n第二行接续")
        XCTAssertEqual(found[0].latitude, 30.27)
        XCTAssertEqual(found[0].longitude, 120.13)
    }

    func testSimpleRepeatMapsToRule() {
        let result = parse(ics(
            "BEGIN:VEVENT\r\nUID:standup\r\nDTSTART;TZID=Asia/Shanghai:20261102T093000\r\nDTEND;TZID=Asia/Shanghai:20261102T094500\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE\r\nSUMMARY:站会\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:old\r\nDTSTART:20240101T100000\r\nRRULE:FREQ=WEEKLY\r\nSUMMARY:老周会\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:rent\r\nDTSTART;VALUE=DATE:20261205\r\nRRULE:FREQ=MONTHLY\r\nSUMMARY:交房租\r\nEND:VEVENT"))
        XCTAssertEqual(result.events.count, 3)
        let standup = result.events[0]
        XCTAssertEqual(standup.startDate, day(11, 2))
        XCTAssertEqual(standup.repeatRule, RepeatRule(mode: .custom, unit: .week, interval: 1, dates: ["1", "3"]))
        XCTAssertEqual(standup.repeatText, "每周一、三")
        // 很早开始的重复：首次挪到范围起点（10-22）之后的第一个周一。
        XCTAssertEqual(result.events[1].startDate, day(10, 26))
        XCTAssertEqual(result.events[2].repeatRule?.unit, .month)
        XCTAssertEqual(result.events[2].repeatRule?.dates, ["5"])
    }

    func testCountExdateAndOverrideExpand() {
        let result = parse(ics(
            "BEGIN:VEVENT\r\nUID:daily\r\nDTSTART:20261201T090000\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEXDATE:20261202T090000\r\nSUMMARY:训练营\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:weekly\r\nDTSTART;TZID=Asia/Shanghai:20261207T100000\r\nDTEND;TZID=Asia/Shanghai:20261207T110000\r\nRRULE:FREQ=WEEKLY;COUNT=2\r\nSUMMARY:周会\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:weekly\r\nRECURRENCE-ID;TZID=Asia/Shanghai:20261214T100000\r\nDTSTART;TZID=Asia/Shanghai:20261215T110000\r\nDTEND;TZID=Asia/Shanghai:20261215T120000\r\nSUMMARY:改期后的周会\r\nEND:VEVENT"))
        let daily = result.events.filter { $0.key.hasPrefix("daily#") }
        XCTAssertEqual(daily.map(\.startDate), [day(12, 1), day(12, 3)])
        XCTAssertNil(daily[0].repeatRule)
        let weekly = result.events.filter { $0.key.hasPrefix("weekly#") }
        XCTAssertEqual(weekly.map(\.key), ["weekly#2026-12-07", "weekly#2026-12-14"])
        XCTAssertEqual(weekly[1].title, "改期后的周会")
        XCTAssertEqual(weekly[1].startDate, day(12, 15))
        XCTAssertEqual(weekly[1].startTime, clock(11))
        XCTAssertEqual(weekly[0].endTime, clock(11))
    }

    func testMonthlyOrdinalWeekday() {
        let result = parse(ics(
            "BEGIN:VEVENT\r\nUID:review\r\nDTSTART;VALUE=DATE:20261127\r\nRRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=2\r\nSUMMARY:月度复盘\r\nEND:VEVENT"))
        XCTAssertEqual(result.events.map(\.startDate), [day(11, 27), day(12, 25)])
        XCTAssertEqual(result.events.first?.repeatText, "每月最后一个周五（按次导入）")
    }

    func testWindowCancelledAndSkipped() {
        let result = parse(ics(
            "BEGIN:VEVENT\r\nUID:past\r\nDTSTART:20250101T100000\r\nSUMMARY:去年\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:gone\r\nDTSTART:20261201T100000\r\nSTATUS:CANCELLED\r\nSUMMARY:取消了\r\nEND:VEVENT",
            "BEGIN:VEVENT\r\nUID:nostart\r\nSUMMARY:没开始时间\r\nEND:VEVENT"))
        XCTAssertEqual(result.events.map(\.key), ["gone"])
        XCTAssertTrue(result.events[0].cancelled)
        XCTAssertEqual(result.skipped, 2)
    }

    func testRuleParsingAndDuration() {
        let rule = ICSRule("FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU,-1FR;UNTIL=20271231T000000Z", calendar: shanghai)!
        XCTAssertEqual(rule.interval, 2)
        XCTAssertEqual(rule.byDay, [ICSWeekday(ordinal: 2, weekday: 2), ICSWeekday(ordinal: -1, weekday: 5)])
        XCTAssertEqual(rule.until, day(12, 31, 2027))
        XCTAssertFalse(rule.unsupported)
        XCTAssertTrue(ICSRule("FREQ=MONTHLY;BYSETPOS=-1;BYDAY=MO", calendar: shanghai)!.unsupported)
        XCTAssertTrue(ICSRule("FREQ=HOURLY", calendar: shanghai)!.unsupported)
        XCTAssertNil(ICSRule("INTERVAL=2", calendar: shanghai))
        XCTAssertEqual(ICSDate.duration("PT1H30M"), 5_400)
        XCTAssertEqual(ICSDate.duration("P1W"), 604_800)
        XCTAssertEqual(ICSDate.duration("-PT15M"), -900)
        XCTAssertNil(ICSDate.duration("1H"))
    }

    func testInput() {
        let event = parse(ics(
            "BEGIN:VEVENT\r\nUID:a\r\nDTSTART;TZID=Asia/Shanghai:20261201T150000\r\nDTEND;TZID=Asia/Shanghai:20261201T163000\r\nSUMMARY:项目评审\r\nDESCRIPTION:带上电脑\r\nLOCATION:腾讯滨海大厦\r\nEND:VEVENT")).events[0]
        let input = event.input(listID: "9", sourceName: "飞书日历")
        XCTAssertEqual(input.title, "项目评审")
        XCTAssertEqual(input.listID, "9")
        XCTAssertEqual(input.remark, "带上电脑\n来自「飞书日历」")
        XCTAssertEqual(input.startDate, day(12, 1))
        XCTAssertEqual(input.startTime, clock(15))
        XCTAssertEqual(input.endTime, clock(16, 30))
        XCTAssertEqual(input.location?.name, "腾讯滨海大厦")
        XCTAssertNil(input.location?.remind)
        XCTAssertNil(input.reminderTime)
    }

    func testPlanner() {
        var a = ImportedEvent(key: "a", title: "A", notes: "", location: "", startDate: day(12, 1), endDate: day(12, 1))
        let b = ImportedEvent(key: "b", title: "B", notes: "", location: "", startDate: day(12, 2), endDate: day(12, 2))
        var c = ImportedEvent(key: "c", title: "C", notes: "", location: "", startDate: day(12, 3), endDate: day(12, 3))
        let links = [
            ImportLink(sourceID: "s", key: "a", taskID: "t1", fingerprint: a.fingerprint, startDay: day(12, 1), abandoned: false),
            ImportLink(sourceID: "s", key: "c", taskID: "t3", fingerprint: c.fingerprint, startDay: day(12, 3), abandoned: false),
            ImportLink(sourceID: "s", key: "gone", taskID: "t4", fingerprint: "x", startDay: day(12, 9), abandoned: false),
            ImportLink(sourceID: "s", key: "old", taskID: "t5", fingerprint: "x", startDay: day(9, 1), abandoned: false),
        ]
        a.title = "A 改过"
        c.cancelled = true
        let plan = ImportPlanner.plan([a, b, c], links: links, removeMissing: true, from: day(10, 22))
        XCTAssertEqual(plan.added.map(\.key), ["b"])
        XCTAssertEqual(plan.updated.map(\.key), ["a"])
        // c 被取消，gone 外部删除；old 已经滑出导入范围，不算删除。
        XCTAssertEqual(plan.removed.map(\.key), ["c", "gone"])

        let once = ImportPlanner.plan([b], links: links, removeMissing: false, from: day(10, 22))
        XCTAssertTrue(once.removed.isEmpty)
    }

    func testStoreRoundTrip() throws {
        let store = try LocalStore()
        let source = ImportSource(id: "s1", kind: .file, name: "飞书日历", listID: "9", address: "feishu.ics",
                                  createdAt: Date(timeIntervalSince1970: 1_800_000_000), lastSyncAt: nil,
                                  lastCount: 0, enabled: true)
        try store.saveImportSource(source)
        var updated = source
        updated.lastCount = 5
        updated.lastSyncAt = Date(timeIntervalSince1970: 1_800_000_100)
        try store.saveImportSource(updated)
        XCTAssertEqual(try store.importSources(), [updated])

        let link = ImportLink(sourceID: "s1", key: "a", taskID: "t1", fingerprint: "f", startDay: day(12, 1),
                              abandoned: false)
        try store.saveImportLink(link)
        var changed = link
        changed.abandoned = true
        try store.saveImportLink(changed)
        XCTAssertEqual(try store.importLinks(sourceID: "s1"), [changed])
        try store.deleteImportSource("s1")
        XCTAssertTrue(try store.importSources().isEmpty)
        XCTAssertTrue(try store.importLinks(sourceID: "s1").isEmpty)
    }
}
