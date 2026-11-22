import XCTest
@testable import BiandanMac

/// AI 决策的显示与误识别修复：页码不是日期、灵敏度门槛、拦下说明写明模型名。今天是 2026-11-22（周日）。
final class DecisionDisplayTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 22)!

    func testPageCounterIsNotDate() {
        let lines = ChatTimestamp.annotate(["页面：1/1 | 字数：6 | 拼写检查：打开、 | AI 校对 · 本地备份开 150%～"], today: today)
        XCTAssertTrue(RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: []).isEmpty)
        XCTAssertTrue(DecisionHints.collect(lines, ruleCandidates: 0).dateWords.isEmpty)
        let paged = SentenceScheduleParser.parse("第 3/10 页 明天看完", base: today, weekStart: 1)
        XCTAssertFalse(paged.contains { $0.date == LocalDate(year: 2027, month: 3, day: 10) })
        XCTAssertTrue(SentenceScheduleParser.parse("Page 2/5 下午3点", base: today, weekStart: 1)
            .allSatisfy { $0.date != LocalDate(year: 2027, month: 2, day: 5) })
        let real = SentenceScheduleParser.parse("12/5 下午3点开会", base: today, weekStart: 1)
        XCTAssertEqual(real.first?.date, LocalDate(year: 2026, month: 12, day: 5))
    }

    func testSensitivityLimits() {
        XCTAssertEqual(DecisionSensitivity.loose.probabilityLimit, 0.15)
        XCTAssertEqual(DecisionSensitivity.balanced.probabilityLimit, 0.30)
        XCTAssertEqual(DecisionSensitivity.strict.clarityLimit, 2.0)
    }

    func testNoteNamesBothModels() {
        var record = DecisionRecord(date: Date(), trigger: .always, sensitivity: .balanced, aiModel: "deepseek-flash")
        record.decisionModel = DecisionSettings.model
        record.region = "北京"
        record.outcome = .block
        record.reason = "有日程的概率只有 2%，清晰度 0.2/4"
        let note = DecisionGate.blockedNote(record)
        XCTAssertTrue(note.hasPrefix("decision-model-preview"))
        XCTAssertTrue(note.contains("deepseek-flash"))
    }

    func testOldRecordsStillDecode() throws {
        let json = #"[{"id":"7B0E0B4E-6E1A-4D7B-9C3B-1F0F1C6E2A11","date":"2026-11-22T02:00:00Z","trigger":"always","sensitivity":"balanced","aiModel":"deepseek-flash","outcome":"block","reason":"x","durationMs":200,"inputTokens":10,"inputCharacters":20,"costUSD":0}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([DecisionRecord].self, from: Data(json.utf8))
        XCTAssertNil(records.first?.decisionModel)
        XCTAssertNil(records.first?.region)
    }
}
