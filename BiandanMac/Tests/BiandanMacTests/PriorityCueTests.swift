import XCTest
@testable import BiandanMac

/// 识别日程时的四象限：原文里的「重要」「紧急」线索，规则识别和 AI 识别都要用上。今天是 2026-11-20（周五）。
final class PriorityCueTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    func testDetectImportantAndUrgent() {
        XCTAssertEqual(PriorityCue.detect("非常重要 后天晚上看新品")?.important, true)
        XCTAssertNil(PriorityCue.detect("非常重要 后天晚上看新品")?.urgent)
        XCTAssertEqual(PriorityCue.detect("紧急安排：明天开会")?.urgent, true)
        XCTAssertEqual(PriorityCue.detect("记得明天交报告")?.important, true)
        XCTAssertEqual(PriorityCue.detect("务必准时参加")?.important, true)
        XCTAssertEqual(PriorityCue.detect("ASAP 处理一下")?.urgent, true)
        XCTAssertNil(PriorityCue.detect("明天下午三点开会"))
        XCTAssertNil(PriorityCue.detect("whatsapp 群里聊"))
    }

    func testNegationWins() {
        let cue = PriorityCue.detect("重要但不紧急")
        XCTAssertEqual(cue?.important, true)
        XCTAssertEqual(cue?.urgent, false)
        XCTAssertEqual(PriorityCue.detect("这个不重要，有空再看")?.important, false)
        XCTAssertEqual(PriorityCue.detect("不着急，周五前弄完就行")?.urgent, false)
        let both = PriorityCue.detect("重要且紧急")
        XCTAssertEqual(both?.important, true)
        XCTAssertEqual(both?.urgent, true)
    }

    func testFourQuadrantNames() {
        func quadrant(_ text: String) -> Quadrant? {
            PriorityCue.detect(text).map { Quadrant(important: $0.important ?? false, urgent: $0.urgent ?? false) }
        }
        XCTAssertEqual(quadrant("重要紧急 明天上午开会"), .importantUrgent)
        XCTAssertEqual(quadrant("重要且紧急"), .importantUrgent)
        XCTAssertEqual(quadrant("重要但不紧急"), .importantNotUrgent)
        XCTAssertEqual(quadrant("重要不紧急"), .importantNotUrgent)
        XCTAssertEqual(quadrant("不重要但紧急"), .notImportantUrgent)
        XCTAssertEqual(quadrant("紧急但不重要"), .notImportantUrgent)
        XCTAssertEqual(quadrant("不重要且不紧急"), .neither)
        XCTAssertEqual(quadrant("既不重要也不紧急"), .neither)
        XCTAssertEqual(quadrant("第二象限"), .importantNotUrgent)
        XCTAssertEqual(PriorityCue.detect("不重要且不紧急")?.words, ["不重要且不紧急"])
    }

    func testFourQuadrantNamesInRules() {
        let cases: [(String, Quadrant, String)] = [
            ("重要紧急 明天下午3点开会", .importantUrgent, "开会"),
            ("重要但不紧急 明天下午3点开会", .importantNotUrgent, "开会"),
            ("不重要但紧急，明天上午10点取快递", .notImportantUrgent, "取快递"),
            ("【不重要且不紧急】周六下午2点整理照片", .neither, "整理照片"),
        ]
        for (text, expected, title) in cases {
            let lines = ChatTimestamp.annotate([text], today: today)
            let found = PriorityCue.apply(RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: []))
            XCTAssertEqual(found.first?.quadrant, expected, text)
            XCTAssertEqual(found.first?.title, title, text)
        }
    }

    func testStripTitle() {
        XCTAssertEqual(PriorityCue.stripTitle("非常重要 数字街区看 Rokid 新品"), "数字街区看 Rokid 新品")
        XCTAssertEqual(PriorityCue.stripTitle("【紧急】服务器维护"), "服务器维护")
        XCTAssertEqual(PriorityCue.stripTitle("评审，非常重要"), "评审")
        XCTAssertEqual(PriorityCue.stripTitle("记得交报告"), "交报告")
        XCTAssertEqual(PriorityCue.stripTitle("紧急安排和客户过合同"), "和客户过合同")
        XCTAssertEqual(PriorityCue.stripTitle("重要客户拜访"), "重要客户拜访")
        XCTAssertEqual(PriorityCue.stripTitle("重要"), "重要")
    }

    func testRuleCandidateGetsQuadrant() {
        let lines = ChatTimestamp.annotate(["非常重要 后天晚上，19:10 在杭州西湖区文三社区举行数字街区看 Rokid 新品"], today: today)
        let found = PriorityCue.apply(RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: []))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.title, "数字街区看 Rokid 新品")
        XCTAssertEqual(found.first?.date, LocalDate(year: 2026, month: 11, day: 22))
        XCTAssertEqual(found.first?.start, LocalTime(hour: 19, minute: 10))
        XCTAssertEqual(found.first?.location, "杭州西湖区文三社区")
        XCTAssertEqual(found.first?.quadrant, .importantNotUrgent)
        XCTAssertNotNil(found.first?.quadrantReason)
    }

    func testRuleCandidateUrgent() {
        let lines = ChatTimestamp.annotate(["紧急安排：明天上午10点和客户过合同，非常重要"], today: today)
        let found = PriorityCue.apply(RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: []))
        XCTAssertEqual(found.first?.quadrant, .importantUrgent)
        XCTAssertEqual(found.first?.title, "和客户过合同")
    }

    func testAIFieldsAndTextOverride() throws {
        let content = #"""
        {"events": [
          {"title": "过合同", "startDate": "2026-11-21", "startTime": "10:00", "source": "明天上午10点过合同",
           "important": true, "urgent": "true"},
          {"title": "看新品", "startDate": "2026-11-22", "source": "后天看新品", "important": false, "urgent": false},
          {"title": "整理照片", "startDate": "2026-11-22", "source": "后天整理照片，不急", "urgent": true}
        ]}
        """#
        let found = try AIScheduleExtractor.candidates(fromContent: content, today: today)
        XCTAssertEqual(found.map(\.quadrant), [.importantUrgent, .neither, .notImportantUrgent])
        // 原文明确说了「不急」：以原文为准。
        let applied = PriorityCue.apply(found)
        XCTAssertEqual(applied.map(\.quadrant), [.importantUrgent, .neither, .neither])
    }

    func testPromptMentionsQuadrantFields() {
        let prompt = AIScheduleExtractor.systemPrompt
        XCTAssertTrue(prompt.contains("\"important\""))
        XCTAssertTrue(prompt.contains("\"urgent\""))
        XCTAssertTrue(prompt.contains("紧急安排"))
        XCTAssertTrue(prompt.contains("重要但不紧急"))
        XCTAssertTrue(prompt.contains("不重要且不紧急"))
    }
}
