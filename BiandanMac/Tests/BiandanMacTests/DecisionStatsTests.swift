import XCTest
@testable import BiandanMac

/// AI 决策统计的各个维度：概率、清晰度、用时、时段、内容类型、失败原因、临界判断、P95、服务端用时、少发字数。
final class DecisionStatsTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 22)!

    private func record(_ outcome: DecisionOutcome, p: Double?, kind: String? = nil, ms: Int, hour: Int,
                        error: String? = nil) -> DecisionRecord {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: hour, minute: 5))!
        var item = DecisionRecord(date: date, trigger: .always, sensitivity: .balanced, aiModel: "deepseek-flash")
        item.outcome = outcome
        item.durationMs = ms
        item.inputCharacters = 100
        item.inputTokens = 80
        if outcome != .failed { item.serverMs = 60 }
        if let p { item.answers = DecisionAnswers(hasSchedule: p, clarity: p * 4, kind: kind, status: "none") }
        if outcome == .block {
            item.savedUSD = 0.0001
            item.savedMs = 800
        }
        item.error = error
        return item
    }

    func testDimensions() {
        let records = [
            record(.block, p: 0.02, kind: "interface", ms: 180, hour: 9),
            record(.block, p: 0.25, kind: "code", ms: 260, hour: 9),
            record(.pass, p: 0.93, kind: "chat", ms: 420, hour: 14),
            record(.pass, p: 0.35, kind: "chat", ms: 90, hour: 14),
            record(.failed, p: nil, ms: 3000, hour: 20, error: "判断超时"),
        ]
        let s = DecisionStats.summary(records, range: .month, today: today, weekStart: 1)
        XCTAssertEqual(s.calls, 5)
        XCTAssertEqual(s.probabilityBins[0].blocked, 1)
        XCTAssertEqual(s.probabilityBins[1].blocked, 1)
        XCTAssertEqual(s.probabilityBins[2].passed, 1)
        XCTAssertEqual(s.probabilityBins[5].passed, 1)
        XCTAssertEqual(s.clarityBins.reduce(0) { $0 + $1.total }, 4)
        XCTAssertEqual(s.kinds.first?.id, "chat")
        XCTAssertEqual(s.kinds.first?.passed, 2)
        XCTAssertEqual(s.hours[9].blocked, 2)
        XCTAssertEqual(s.hours[20].failed, 1)
        XCTAssertEqual(s.latencyBins[0].passed, 1)
        XCTAssertEqual(s.latencyBins.last?.failed, 1)
        XCTAssertEqual(s.errors.first?.title, "超时")
        XCTAssertEqual(s.topError, "超时")
        XCTAssertEqual(s.borderline, 2)
        XCTAssertEqual(s.savedCharacters, 200)
        XCTAssertEqual(s.serverAverageMs, 60)
        XCTAssertEqual(s.p95Ms, 420)
        XCTAssertEqual(s.medianMs, 260)
        XCTAssertEqual(s.sensitivities.map(\.id), ["balanced"])
        XCTAssertEqual(s.triggers.first?.total, 5)
        XCTAssertEqual(s.buckets.last?.savedCharacters, 200)
        XCTAssertEqual(s.buckets.last?.total, 5)
        let insights = DecisionStats.insights(s)
        XCTAssertTrue(insights.contains { $0.contains("临界判断 2 次") })
        XCTAssertTrue(insights.contains { $0.contains("网络往返") })
    }

    func testTipsAndKPIs() {
        let block = record(.block, p: 0.02, kind: "interface", ms: 180, hour: 9)
        let tip = DecisionTips.record(block)
        XCTAssertTrue(tip.rows.contains { $0.name == "有日程概率" && $0.value == "2%" })
        XCTAssertTrue(tip.rows.contains { $0.name == "本来要调用" && $0.value == "deepseek-flash" })
        let s = DecisionStats.summary([block], range: .month, today: today, weekStart: 1)
        let items = DecisionKPIs.items(s)
        XCTAssertGreaterThanOrEqual(items.count, 12)
        XCTAssertTrue(items.allSatisfy { !$0.help.isEmpty })
        let failedOnly = DecisionTips.outcomeRows(passed: 0, blocked: 0, failed: 3)
        XCTAssertEqual(failedOnly.map(\.name), ["失败"])
    }
}
