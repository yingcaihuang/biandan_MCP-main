import XCTest
@testable import BiandanMac

/// 菜单栏「现在该做什么、还剩多久」和倒计时文字。今天是 2026-11-22。
final class MenuBarAgendaTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: hour, minute: minute))!
    }

    private func slot(_ id: String, _ title: String, _ start: (Int, Int), _ end: (Int, Int)) -> AgendaSlot {
        AgendaSlot(id: id, title: title, start: at(start.0, start.1), end: at(end.0, end.1))
    }

    private var day: [AgendaSlot] {
        [slot("b", "周会同步", (16, 0), (16, 45)), slot("a", "设计评审", (14, 30), (15, 30))]
    }

    private func text(_ now: Date) -> String? {
        MenuBarAgenda.menuBarText(MenuBarAgenda.focus(day, now: now), now: now, calendar: calendar)
    }

    func testFocusAndText() {
        let before = MenuBarAgenda.focus(day, now: at(14, 22))
        XCTAssertNil(before.current)
        XCTAssertEqual(before.next?.id, "a")
        XCTAssertEqual(text(at(14, 22)), "设计评审 · 8 分钟后")

        let during = MenuBarAgenda.focus(day, now: at(14, 40))
        XCTAssertEqual(during.current?.id, "a")
        XCTAssertEqual(during.next?.id, "b")
        XCTAssertEqual(text(at(14, 40)), "设计评审 · 剩 50 分钟")

        XCTAssertEqual(text(at(15, 52)), "周会同步 · 8 分钟后")
        XCTAssertEqual(text(at(13, 0)), "14:30 设计评审")
        XCTAssertNil(text(at(17, 0)))
    }

    func testImminentNextBeatsCurrent() {
        let slots = [slot("long", "深度工作", (13, 0), (17, 0)), slot("next", "周会同步", (16, 0), (16, 45))]
        let now = at(15, 55)
        let focus = MenuBarAgenda.focus(slots, now: now)
        XCTAssertEqual(focus.current?.id, "long")
        XCTAssertEqual(MenuBarAgenda.menuBarText(focus, now: now, calendar: calendar), "周会同步 · 5 分钟后")
        XCTAssertEqual(MenuBarAgenda.menuBarText(focus, now: at(15, 0), calendar: calendar), "深度工作 · 剩 2 小时")
    }

    func testDetailsAndFormat() {
        let review = slot("a", "设计评审", (14, 30), (15, 30))
        XCTAssertEqual(MenuBarAgenda.runningDetail(review, now: at(15, 5), calendar: calendar), "还剩 25 分钟 · 到 15:30")
        XCTAssertEqual(MenuBarAgenda.upcomingDetail(review, now: at(13, 25), calendar: calendar), "14:30 开始 · 1 小时 5 分后")
        XCTAssertEqual(MenuBarAgenda.progress(review, now: at(15, 0)), 0.5, accuracy: 0.001)
        XCTAssertEqual(MenuBarAgenda.duration(120), "2 小时")
        XCTAssertEqual(MenuBarAgenda.short("季度经营分析复盘会议"), "季度经营分析…")
        XCTAssertEqual(MenuBarAgenda.short("评审"), "评审")
    }
}
