import XCTest
@testable import BiandanMac

/// AI 决策：接口地址、请求结构、返回解析、拦截阈值、省钱估算和统计。不发真实请求。今天是 2026-11-22（周日）。
final class DecisionGateTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 22)!
    /// 周日中午（UTC 04:00），非高峰。
    private let offPeak = ISO8601DateFormatter().date(from: "2026-11-22T04:00:00Z")!

    func testEndpoint() {
        let full = "https://llm-abc.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/systemone"
        XCTAssertEqual(DecisionSettings.endpoint(workspace: "llm-3vtt9m9ke5ezhzn0", region: .beijing)?.absoluteString,
                       "https://llm-3vtt9m9ke5ezhzn0.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/systemone")
        XCTAssertEqual(DecisionSettings.endpoint(workspace: "llm-abc", region: .singapore)?.absoluteString,
                       "https://llm-abc.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/systemone")
        XCTAssertEqual(DecisionSettings.endpoint(workspace: full + "/", region: .singapore)?.absoluteString, full)
        XCTAssertEqual(DecisionSettings.endpoint(workspace: "https://llm-abc.cn-beijing.maas.aliyuncs.com/compatible-mode",
                                                 region: .beijing)?.absoluteString, full)
        XCTAssertEqual(DecisionSettings.endpoint(workspace: "https://llm-abc.cn-beijing.maas.aliyuncs.com",
                                                 region: .beijing)?.absoluteString, full)
        XCTAssertNil(DecisionSettings.endpoint(workspace: "", region: .beijing))
        XCTAssertNil(DecisionSettings.endpoint(workspace: "llm abc", region: .beijing))
        XCTAssertNil(DecisionSettings.endpoint(workspace: "http://example.com", region: .beijing))
    }

    func testReadyAndKey() {
        XCTAssertEqual(DecisionKeyStore.normalize("  Bearer sk-123 "), "sk-123")
        XCTAssertEqual(DecisionKeyStore.normalize("sk-456"), "sk-456")
        func settings(enabled: Bool, key: String?) -> DecisionSettings {
            DecisionSettings(enabled: enabled, workspace: "llm-a", region: .beijing, sensitivity: .balanced, apiKey: key)
        }
        XCTAssertTrue(settings(enabled: true, key: "sk").isReady)
        XCTAssertFalse(settings(enabled: true, key: nil).isReady)
        XCTAssertFalse(settings(enabled: false, key: "sk").isReady)
    }

    func testRequestBody() throws {
        let lines = ChatTimestamp.annotate(["非常重要 后天晚上，19:10 在杭州西湖区文三社区举行数字街区看 Rokid 新品"], today: today)
        let hints = DecisionHints.collect(lines, ruleCandidates: 1)
        XCTAssertTrue(hints.dateWords.contains("后天"))
        XCTAssertTrue(hints.timeWords.contains("19:10"))
        XCTAssertTrue(hints.eventWords.contains("举行"))
        let prepared = DecisionGate.prepare(lines)
        let body = DecisionGate.body(text: prepared.text, today: today, source: .region, hints: hints, lineCount: 1,
                                     truncated: false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
        XCTAssertEqual(body["model"] as? String, "decision-model-preview")
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual((state["today"] as? String)?.hasPrefix("2026-11-22"), true)
        XCTAssertEqual(state["input_source"] as? String, "框选截图 OCR")
        XCTAssertEqual((state["text"] as? String)?.contains("Rokid"), true)
        XCTAssertEqual((state["task"] as? String)?.contains("不执行"), true)
        let local = try XCTUnwrap(state["local_hints"] as? [String: Any])
        XCTAssertEqual(local["rule_candidates"] as? Int, 1)
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), ["has_schedule", "clarity", "content_kind", "event_status"])
        XCTAssertEqual((questions["has_schedule"] as? [String: Any])?["type"] as? String, "noul")
        XCTAssertEqual(((questions["clarity"] as? [String: Any])?["criteria"] as? [String])?.count, 5)
        XCTAssertEqual(((questions["content_kind"] as? [String: Any])?["criteria"] as? [String: String])?["other"] != nil, true)
    }

    func testTimestampLinesAreNotHints() {
        let lines = ChatTimestamp.annotate(["func main() {}", "Line 3, Column 23"], today: today)
        let hints = DecisionHints.collect(lines, ruleCandidates: 0)
        XCTAssertTrue(hints.dateWords.isEmpty)
        XCTAssertTrue(hints.eventWords.isEmpty)
    }

    func testParseResponse() throws {
        let json = """
        {"model": "decision-model-preview", "request_id": "x", "answers": {
          "has_schedule": {"type": "noul", "noul": 0.93},
          "clarity": {"type": "score", "score": 3.6, "confidence": 0.81, "legend": {"0": "a"}, "probabilities": {"0": 0.0}},
          "content_kind": {"type": "choice", "choice": "chat", "confidence": 0.9, "probabilities": {"chat": 0.9}},
          "event_status": {"type": "choice", "choice": "planned", "confidence": 0.8}
        }, "usage": {"input_tokens": 812}, "latency_ms": 61.5}
        """
        let reply = try DecisionGate.parse(Data(json.utf8))
        XCTAssertEqual(reply.answers.hasSchedule, 0.93, accuracy: 0.0001)
        XCTAssertEqual(reply.answers.clarity ?? 0, 3.6, accuracy: 0.0001)
        XCTAssertEqual(reply.answers.kind, "chat")
        XCTAssertEqual(reply.answers.status, "planned")
        XCTAssertEqual(reply.inputTokens, 812)
        XCTAssertEqual(reply.serverMs ?? 0, 61.5, accuracy: 0.001)
        XCTAssertEqual(reply.answers.summary, "有日程 93% · 清晰度 3.6/4 · 聊天记录")
        XCTAssertThrowsError(try DecisionGate.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try DecisionGate.parse(Data(#"{"answers": {}}"#.utf8)))
    }

    func testVerdictThresholds() {
        func answers(_ p: Double, _ c: Double?, kind: String? = nil, confidence: Double? = nil,
                     status: String? = nil) -> DecisionAnswers {
            var value = DecisionAnswers(hasSchedule: p)
            value.clarity = c
            value.kind = kind
            value.kindConfidence = confidence
            value.status = status
            return value
        }
        func outcome(_ value: DecisionAnswers, _ sensitivity: DecisionSensitivity) -> DecisionOutcome {
            DecisionGate.verdict(value, sensitivity: sensitivity).outcome
        }
        XCTAssertEqual(outcome(answers(0.1, 0.5), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.93, 3.6), .balanced), .pass)
        XCTAssertEqual(outcome(answers(0.2, 1.6), .balanced), .pass)
        XCTAssertEqual(outcome(answers(0.4, 2.5, kind: "code", confidence: 0.9), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.4, 2.5, kind: "code", confidence: 0.6), .balanced), .pass)
        XCTAssertEqual(outcome(answers(0.2, 0.5), .loose), .pass)
        XCTAssertEqual(outcome(answers(0.1, 0.5), .loose), .block)
        XCTAssertEqual(outcome(answers(0.4, 1.8), .strict), .block)
        XCTAssertEqual(outcome(answers(0.45, 2.5, status: "past"), .strict), .block)
        XCTAssertEqual(outcome(answers(0.45, 2.5, status: "past"), .balanced), .pass)
        // 没给清晰度时按概率折算。
        XCTAssertEqual(outcome(answers(0.05, nil), .balanced), .block)
        XCTAssertEqual(outcome(answers(0.6, nil), .strict), .pass)
    }

    func testSavingsWithoutHistory() {
        // 系统提示词 1600 + 正文 100 字 × 0.7 = 1670 输入 token，30 输出 token，按 Flash 非高峰价。
        let saved = DecisionSavings.estimate(characters: 100, model: "deepseek-flash", host: "api.deepseek.com",
                                             history: [], at: offPeak)
        XCTAssertEqual(saved.cost ?? 0, 0.0002685, accuracy: 1e-9)
        XCTAssertEqual(saved.ms, DecisionSavings.fallbackMs)
        XCTAssertNil(DecisionSavings.estimate(characters: 100, model: "qwen-max", host: "dashscope.aliyuncs.com",
                                              history: [], at: offPeak).cost)
    }

    func testSavingsFromHistory() {
        var first = AIUsageRecord(date: offPeak, model: "deepseek-flash", host: "api.deepseek.com", trigger: .always)
        first.success = true
        first.costUSD = 0.0003
        first.inputCharacters = 1000
        first.durationMs = 900
        var second = first
        second.id = UUID()
        second.durationMs = 1100
        var probe = first
        probe.id = UUID()
        probe.trigger = .test
        probe.costUSD = 1
        let saved = DecisionSavings.estimate(characters: 500, model: "deepseek-flash", host: "api.deepseek.com",
                                             history: [first, second, probe], at: offPeak)
        XCTAssertEqual(saved.cost ?? 0, 0.00015, accuracy: 1e-12)
        XCTAssertEqual(saved.ms, 1000)
    }

    func testStatsSummary() {
        let base = today.date(calendar: .current).addingTimeInterval(10 * 3600)
        func make(_ outcome: DecisionOutcome, saved: Double? = nil, override: Int? = nil) -> DecisionRecord {
            var record = DecisionRecord(date: base, trigger: .fallback, sensitivity: .balanced, aiModel: "deepseek-flash")
            record.outcome = outcome
            record.savedUSD = saved
            record.savedMs = saved == nil ? nil : 900
            record.overrideEvents = override
            record.durationMs = 60
            return record
        }
        let records = [make(.pass), make(.block, saved: 0.0003), make(.block, saved: 0.0002, override: 2),
                       make(.block, saved: 0.0001, override: 0), make(.failed)]
        let summary = DecisionStats.summary(records, range: .month, today: today, weekStart: 1)
        XCTAssertEqual(summary.calls, 5)
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.blocked, 3)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.blockRate ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(summary.saved, 0.0006, accuracy: 1e-12)
        XCTAssertEqual(summary.savedMs, 2700)
        XCTAssertEqual(summary.overrides, 2)
        XCTAssertEqual(summary.falseBlocks, 1)
        XCTAssertEqual(summary.falseBlockRate ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.averageMs ?? 0, 60, accuracy: 0.001)
        XCTAssertFalse(DecisionStats.insights(summary).isEmpty)
        XCTAssertTrue(records[2].falseBlock)
        XCTAssertFalse(records[3].falseBlock)
    }

    func testBlockedNote() {
        var record = DecisionRecord(date: offPeak, trigger: .fallback, sensitivity: .balanced, aiModel: "deepseek-flash")
        record.outcome = .block
        record.reason = "有日程的概率只有 8%，清晰度 0.4/4"
        record.savedUSD = 0.0003
        let note = DecisionGate.blockedNote(record)
        XCTAssertTrue(note.contains("没有调用 deepseek-flash"))
        XCTAssertTrue(note.contains("约省 $0.0003"))
    }
}
