import XCTest
@testable import BiandanMac

final class CaptureFalsePositiveTests: XCTestCase {
    private let today = LocalDate(iso: "2026-11-22")!

    func testWeekendNounsAreNotDates() {
        XCTAssertTrue(SentenceScheduleParser.parse("周末时段—全谷价", base: today, weekStart: 1).isEmpty)
        XCTAssertTrue(SentenceScheduleParser.parse("本周末特惠套餐", base: today, weekStart: 1).isEmpty)
        XCTAssertFalse(SentenceScheduleParser.parse("这周末去爬山", base: today, weekStart: 1).isEmpty)
    }

    func testLongUntimedTitleIsUnchecked() {
        let long = "下周一 关于新版本发布计划和市场推广方案以及渠道合作伙伴沟通安排的整体梳理与讨论记录"
        let lines = [CaptureLine(text: long, messageDate: today)]
        let found = RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.include, false)
        let short = RuleScheduleExtractor.extract([CaptureLine(text: "下周一项目评审", messageDate: today)],
                                                  today: today, weekStart: 1, lists: [])
        XCTAssertEqual(short.first?.include, true)
    }

    func testSkippedModelStage() {
        let stages = [CaptureStageTiming(stage: .ocr, ms: 666),
                      CaptureStageTiming(stage: .model, ms: 0, skipped: "这台 Mac 不支持 Apple 智能"),
                      CaptureStageTiming(stage: .rules, ms: 3)]
        XCTAssertEqual(CaptureTimingLog.text(stages),
                       "文字识别 666 毫秒 · 端侧模型不可用（这台 Mac 不支持 Apple 智能） · 规则识别 3 毫秒")
        let record = CaptureTimingRecord(date: Date(), source: "rules", stages: stages, totalMs: 700)
        let averages = CaptureTimingLog.modelAverages([record])
        XCTAssertNil(averages.cold)
        XCTAssertNil(averages.warm)
    }
}
