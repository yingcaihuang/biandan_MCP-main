import XCTest
@testable import BiandanMac

/// 概率极低但清晰度被界面上的时间抬高、以及已经发生 / 取消的事：这些情况也要拦下。
final class DecisionVerdictFloorTests: XCTestCase {
    private func answers(_ p: Double, _ c: Double?, status: String? = nil) -> DecisionAnswers {
        var value = DecisionAnswers(hasSchedule: p)
        value.clarity = c
        value.status = status
        return value
    }

    private func outcome(_ value: DecisionAnswers, _ sensitivity: DecisionSensitivity) -> DecisionOutcome {
        DecisionGate.verdict(value, sensitivity: sensitivity).outcome
    }

    func testBalancedFloor() {
        // 公证工具界面：概率 3%、清晰度 2.1、已经发生的事（之前被放行，AI 找到 0 条）。
        XCTAssertEqual(outcome(answers(0.03, 2.1, status: "past"), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.08, 2.2, status: "planned"), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.06, 1.7, status: "none"), .balanced), .block)
        // 事项、时间都明确时不靠概率下限拦。
        XCTAssertEqual(outcome(answers(0.08, 3.2), .balanced), .pass)
        // AI 真找到日程的那些都要放行。
        XCTAssertEqual(outcome(answers(0.60, 1.6, status: "past"), .balanced), .pass)
        XCTAssertEqual(outcome(answers(0.73, 3.5, status: "planned"), .balanced), .pass)
    }

    func testBalancedSettledStatus() {
        XCTAssertEqual(outcome(answers(0.12, 2.0, status: "none"), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.12, 2.0, status: "cancelled"), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.12, 2.0, status: "planned"), .balanced), .pass)
        XCTAssertEqual(outcome(answers(0.20, 2.0, status: "past"), .balanced), .pass)
    }

    func testLooseAndStrict() {
        XCTAssertEqual(outcome(answers(0.08, 2.2), .loose), .pass)
        XCTAssertEqual(outcome(answers(0.04, 2.2), .loose), .block)
        XCTAssertEqual(outcome(answers(0.12, 2.0, status: "none"), .loose), .pass)
        XCTAssertEqual(outcome(answers(0.12, 2.5), .strict), .block)
        XCTAssertEqual(outcome(answers(0.20, 3.5), .strict), .pass)
    }

    func testReasonMentionsFloor() {
        let verdict = DecisionGate.verdict(answers(0.03, 2.1, status: "past"), sensitivity: .balanced)
        XCTAssertTrue(verdict.reason.contains("低于 10%"), verdict.reason)
    }
}
