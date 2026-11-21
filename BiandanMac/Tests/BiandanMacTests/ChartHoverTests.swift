import SwiftUI
import XCTest
@testable import BiandanMac

final class ChartHoverTests: XCTestCase {
    func testTipPlacementFlipsAndClamps() {
        XCTAssertEqual(ChartHover.tipX(10, width: 100, limit: 400, clamp: true), 24)
        // 右边放不下：放到左边。
        XCTAssertEqual(ChartHover.tipX(350, width: 100, limit: 400, clamp: true), 236)
        // 两边都放不下：贴着右边界收进来。
        XCTAssertEqual(ChartHover.tipX(60, width: 380, limit: 400, clamp: true), 20)
        XCTAssertEqual(ChartHover.tipX(350, width: 100, limit: 400, clamp: false), 364)
        XCTAssertEqual(ChartHover.tipY(10, height: 60, limit: 200, clamp: true), 0)
        XCTAssertEqual(ChartHover.tipY(190, height: 60, limit: 200, clamp: true), 140)
        XCTAssertEqual(ChartHover.tipY(100, height: 60, limit: 200, clamp: true), 70)
    }

    func testSeriesTip() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let other = date.addingTimeInterval(86_400)
        let points = [
            AIChartPoint(id: "a", date: date, series: "成功", value: 3),
            AIChartPoint(id: "b", date: date, series: "失败", value: 1),
            AIChartPoint(id: "c", date: other, series: "成功", value: 9),
        ]
        let tip = ChartHover.seriesTip(points, at: date, series: ["成功", "失败"], colors: [.green, .red], days: 1,
                                       total: true, share: true) { "\(Int($0)) 次" }
        XCTAssertEqual(tip.rows.map(\.name), ["成功", "失败"])
        XCTAssertTrue(tip.rows[0].value.hasPrefix("3 次（"))
        XCTAssertTrue(tip.rows[1].value.hasPrefix("1 次（"))
        XCTAssertEqual(tip.footer, "合计 4 次")
        XCTAssertEqual(ChartHover.distinctDates(points), [date, other])

        let single = ChartHover.seriesTip(points, at: other, series: ["成功"], colors: [], days: 1, total: true) {
            "\(Int($0))"
        }
        XCTAssertNil(single.footer)
        XCTAssertEqual(single.rows.first?.value, "9")
    }

    func testTitles() {
        let day = LocalDate(iso: "2026-11-16")!
        XCTAssertEqual(ChartHover.title(day, days: 1), day.shortTitle)
        XCTAssertEqual(ChartHover.title(day, days: 7),
                       day.shortTitle + " – " + LocalDate(iso: "2026-11-22")!.shortTitle)
    }
}
