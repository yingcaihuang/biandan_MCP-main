import Foundation
import XCTest
@testable import BiandanMac

final class QuickAddTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    func testKeywords() {
        let draft = QuickAddParser.parse("写周报 明天 #重要", today: today)
        XCTAssertEqual(draft.title, "写周报")
        XCTAssertTrue(draft.dateSet)
        XCTAssertEqual(draft.date, today.adding(days: 1))
        XCTAssertEqual(draft.important, true)
        XCTAssertNil(draft.urgent)
    }

    func testEmbeddedWordsStayInTitle() {
        let draft = QuickAddParser.parse("明天的会议 准备材料", today: today)
        XCTAssertEqual(draft.title, "明天的会议 准备材料")
        XCTAssertFalse(draft.dateSet)
    }

    func testUndatedAndFullWidth() {
        let draft = QuickAddParser.parse("读书\u{3000}无日期 ＃紧急", today: today)
        XCTAssertEqual(draft.title, "读书")
        XCTAssertTrue(draft.dateSet)
        XCTAssertNil(draft.date)
        XCTAssertEqual(draft.urgent, true)
    }

    func testInputUsesPresetDefaults() throws {
        var preset = NewTaskPreset()
        preset.listID = "42"
        preset.date = today
        preset.urgent = true
        let plain = try XCTUnwrap(QuickAddParser.input(QuickAddParser.parse("买菜", today: today), preset: preset))
        XCTAssertEqual(plain.listID, "42")
        XCTAssertEqual(plain.startDate, today)
        XCTAssertEqual(plain.endDate, today)
        XCTAssertTrue(plain.urgent)
        XCTAssertFalse(plain.important)
        let undated = try XCTUnwrap(QuickAddParser.input(QuickAddParser.parse("买菜 无日期", today: today), preset: preset))
        XCTAssertNil(undated.startDate)
        XCTAssertNil(QuickAddParser.input(QuickAddParser.parse("  明天 ", today: today), preset: preset))
    }
}
