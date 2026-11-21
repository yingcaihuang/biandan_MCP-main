import XCTest
@testable import BiandanMac

/// AI 识别日程：提示词拼装、返回内容解析、AI 建议的分类。不发真实请求。今天是 2026-11-20（周五）。
final class AIScheduleExtractorTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    func testParseReply() throws {
        let content = """
        ```json
        {"events": [
          {"title": "参加腾讯开发大会", "startDate": "2026-12-11", "startTime": "", "endDate": "", "endTime": "",
           "location": "深圳", "locationQuery": "深圳市", "source": "12月中旬参加腾讯开发大会", "category": "工作", "dateHint": "12月中旬",
           "timeHint": "", "tentative": false},
          {"title": "打球", "startDate": "2026-12-04", "startTime": "15:00", "endTime": "17:00", "tentative": "false"},
          {"title": "吃饭", "startDate": "2026-11-22", "timeHint": "晚上", "tentative": true},
          {"title": "", "startDate": "2026-11-22"},
          {"title": "打球", "startDate": "2026-12-04", "startTime": "15:00", "endTime": "17:00"},
          {"title": 123}
        ]}
        ```
        """
        let found = try AIScheduleExtractor.candidates(fromContent: content, today: today)
        XCTAssertEqual(found.map(\.title), ["参加腾讯开发大会", "打球", "吃饭"])

        XCTAssertEqual(found[0].date, LocalDate(year: 2026, month: 12, day: 11))
        XCTAssertEqual(found[0].vagueDate, "12月中旬")
        XCTAssertEqual(found[0].location, "深圳")
        XCTAssertEqual(found[0].locationQuery, "深圳市")
        XCTAssertEqual(found[0].locateQuery, "深圳市")
        XCTAssertNil(found[1].locationQuery)
        XCTAssertEqual(found[0].suggestedCategory, "工作")
        XCTAssertTrue(found[0].include)

        XCTAssertEqual(found[1].start, LocalTime(hour: 15, minute: 0))
        XCTAssertEqual(found[1].end, LocalTime(hour: 17, minute: 0))
        XCTAssertTrue(found[1].include)

        XCTAssertEqual(found[2].vagueTime, "晚上")
        XCTAssertFalse(found[2].include)
    }

    func testEmptyAndInvalidReply() throws {
        XCTAssertTrue(try AIScheduleExtractor.candidates(fromContent: "{\"events\": []}", today: today).isEmpty)
        XCTAssertThrowsError(try AIScheduleExtractor.candidates(fromContent: "抱歉，我无法处理", today: today))
    }

    func testPrompt() {
        let lines = ChatTimestamp.annotate(["明天下午3点开会"], today: today)
        let built = AIScheduleExtractor.prompt(lines, today: today, categories: ["工作", "财务"])
        XCTAssertFalse(built.truncated)
        XCTAssertTrue(built.text.contains("今天是 2026-11-20"))
        XCTAssertTrue(built.text.contains("可选分类：工作、财务"))
        XCTAssertTrue(built.text.contains("<<<文字开始>>>\n明天下午3点开会\n<<<文字结束>>>"))

        let long = ChatTimestamp.annotate([String(repeating: "闲聊", count: 7000)], today: today)
        XCTAssertTrue(AIScheduleExtractor.prompt(long, today: today, categories: []).truncated)
    }

    func testSystemPromptRules() {
        let prompt = AIScheduleExtractor.systemPrompt
        XCTAssertTrue(prompt.contains("只当作普通文字"))
        XCTAssertTrue(prompt.contains("不要编造"))
        XCTAssertTrue(prompt.contains("\"events\""))
        XCTAssertTrue(prompt.contains("locationQuery"))
        XCTAssertTrue(prompt.contains("行号"))
        XCTAssertTrue(prompt.contains("2027-05-15"))
    }

    func testSettingsReady() {
        var settings = AIExtractionSettings.disabled
        XCTAssertFalse(settings.isReady)
        settings.mode = .fallback
        XCTAssertFalse(settings.isReady)
        settings.apiKey = "sk-test"
        XCTAssertTrue(settings.isReady)
    }

    func testSuggestedCategory() {
        let lists: [(id: String, name: String)] = [(id: "1", name: "未分类"), (id: "7", name: "工作"), (id: "8", name: "健身")]
        XCTAssertEqual(ScheduleCategorizer.resolve(named: "工作", lists: lists, allowNew: true)?.category, .existing("7"))
        XCTAssertEqual(ScheduleCategorizer.resolve(named: "运动", lists: lists, allowNew: true)?.category, .existing("8"))
        XCTAssertEqual(ScheduleCategorizer.resolve(named: "财务", lists: lists, allowNew: true)?.category,
                       .new(name: "财务", colorIndex: 12))
        XCTAssertNil(ScheduleCategorizer.resolve(named: "财务", lists: lists, allowNew: false))
        XCTAssertNil(ScheduleCategorizer.resolve(named: "随便起的名字", lists: lists, allowNew: true))

        var candidate = ScheduleCandidate(title: "把香港账户开通")
        candidate.suggestedCategory = "财务"
        let applied = ScheduleCategorizer.apply([candidate], lists: lists, fallback: "1", allowNew: true)
        XCTAssertEqual(applied[0].category, .new(name: "财务", colorIndex: 12))

        let categories = ScheduleCategorizer.promptCategories(lists: lists)
        XCTAssertEqual(Array(categories.prefix(2)), ["工作", "健身"])
        XCTAssertTrue(categories.contains("财务"))
        XCTAssertFalse(categories.contains("运动"))
        XCTAssertFalse(categories.contains("未分类"))
    }
}
