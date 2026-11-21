import XCTest
@testable import BiandanMac

final class CaptureTimingTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "biandan.test.timing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testTimingText() {
        let stages = [
            CaptureStageTiming(stage: .capture, ms: 200),
            CaptureStageTiming(stage: .ocr, ms: 900),
            CaptureStageTiming(stage: .model, ms: 5300, interrupted: true, warm: false),
            CaptureStageTiming(stage: .rules, ms: 12),
        ]
        XCTAssertEqual(CaptureTimingLog.text(stages),
                       "截图 200 毫秒 · 文字识别 900 毫秒 · 端侧模型 5.3 秒（已中断） · 规则识别 12 毫秒")
        XCTAssertEqual(CaptureTimingLog.text([CaptureStageTiming(stage: .model, ms: 1500, warm: true)]),
                       "端侧模型 1.5 秒（已预热）")
    }

    func testLogKeepsNewestAndAverages() {
        let defaults = suite()
        for (index, warm) in [false, true, true].enumerated() {
            let record = CaptureTimingRecord(date: Date(), source: "model",
                                             stages: [CaptureStageTiming(stage: .model, ms: (index + 1) * 1000, warm: warm)],
                                             totalMs: 1000)
            CaptureTimingLog.append(record, defaults: defaults, keep: 2)
        }
        let records = CaptureTimingLog.records(defaults)
        XCTAssertEqual(records.map { $0.stages[0].ms }, [2000, 3000])
        let averages = CaptureTimingLog.modelAverages(records)
        XCTAssertNil(averages.cold)
        XCTAssertEqual(averages.warm, 2500)
        XCTAssertTrue(CaptureTimingLog.summary(defaults).contains("已预热 2.5 秒"))
    }

    func testStateStagesAndSkip() {
        let defaults = suite()
        let state = SchedulePreviewState()
        state.resetTiming()
        state.loading = true
        state.lines = [CaptureLine(text: "明天下午3点开会", messageDate: LocalDate(iso: "2026-11-22")!)]
        state.enter(.ocr)
        state.enter(.model, warm: false)
        XCTAssertTrue(state.canSkipToRules)
        state.enter(.rules, interruptPrevious: true)
        XCTAssertFalse(state.canSkipToRules)
        state.finishTiming(source: "rules", defaults: defaults)
        XCTAssertEqual(state.timings.map(\.stage), [.ocr, .model, .rules])
        XCTAssertEqual(state.timings[1].warm, false)
        XCTAssertTrue(state.timings[1].interrupted)
        XCTAssertNil(state.stage)
        XCTAssertEqual(CaptureTimingLog.records(defaults).count, 1)
    }
}
