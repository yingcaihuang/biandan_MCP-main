import XCTest
@testable import BiandanMac

/// 识别日程的可信度：存疑字段、文字去向、拖到日历的标识。今天是 2026-11-22。
final class CaptureTrustTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 22)!

    func testDragID() {
        let candidate = ScheduleCandidate(title: "评审")
        XCTAssertEqual(ScheduleCandidate.candidateID(fromDrag: candidate.dragID), candidate.id)
        XCTAssertNil(ScheduleCandidate.candidateID(fromDrag: "abc123"))
        XCTAssertNil(ScheduleCandidate.candidateID(fromDrag: ScheduleCandidate.dragPrefix + "not-a-uuid"))
    }

    func testDoubts() {
        var empty = ScheduleCandidate(title: "日程")
        var doubts = empty.doubts(today: today)
        XCTAssertNotNil(doubts[.title])
        XCTAssertNotNil(doubts[.date])

        empty.title = "产品评审"
        empty.date = LocalDate(year: 2026, month: 11, day: 25)
        empty.vagueTime = "下午"
        doubts = empty.doubts(today: today)
        XCTAssertNil(doubts[.title])
        XCTAssertNil(doubts[.date])
        XCTAssertEqual(doubts[.time], "原文只说了「下午」，没写具体时刻")
        empty.start = LocalTime(hour: 15, minute: 0)
        XCTAssertTrue(empty.doubts(today: today).isEmpty)

        var vague = ScheduleCandidate(title: "年会")
        vague.date = LocalDate(year: 2026, month: 12, day: 21)
        vague.vagueDate = "12月下旬"
        XCTAssertEqual(vague.doubts(today: today)[.date], "原文只说了「12月下旬」，日期是估的")

        var past = ScheduleCandidate(title: "开会")
        past.date = LocalDate(year: 2026, month: 11, day: 20)
        XCTAssertEqual(past.doubts(today: today)[.date], "日期已经过去")
        past.note = "截止日已经过去 2 天，添加后会显示为逾期"
        XCTAssertNil(past.doubts(today: today)[.date])

        var place = ScheduleCandidate(title: "吃饭")
        place.date = today
        place.lookup = .notFound
        XCTAssertNotNil(place.doubts(today: today)[.location])

        let long = ScheduleCandidate(title: String(repeating: "很长的一段文字", count: 6))
        XCTAssertEqual(long.doubts(today: today)[.title], "标题很长，可能把整段话当成了标题")
    }

    func testPrivacy() {
        XCTAssertNil(CapturePrivacy.note(source: nil, decision: nil, aiModel: "deepseek-flash"))
        let local = CapturePrivacy.note(source: .rules, decision: nil, aiModel: "deepseek-flash")
        XCTAssertEqual(local?.uploaded, false)
        XCTAssertTrue(local?.text.hasPrefix("本机识别，未上传") == true)
        let ai = CapturePrivacy.note(source: .ai, decision: nil, aiModel: "deepseek-flash")
        XCTAssertEqual(ai?.uploaded, true)
        XCTAssertTrue(ai?.text.contains("deepseek-flash") == true)
        let record = DecisionRecord(date: Date(), trigger: .always, sensitivity: .balanced, aiModel: "deepseek-flash")
        let decided = CapturePrivacy.note(source: .rules, decision: record, aiModel: "deepseek-flash")
        XCTAssertEqual(decided?.uploaded, true)
        XCTAssertTrue(decided?.text.contains("decision-model-preview") == true)
    }
}
