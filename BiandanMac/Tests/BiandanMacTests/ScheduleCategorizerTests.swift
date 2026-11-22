import XCTest
@testable import BiandanMac

/// 识别日程时按情景选分类。
final class ScheduleCategorizerTests: XCTestCase {
    private let lists: [(id: String, name: String)] = [
        (id: "1", name: "未分类"), (id: "7", name: "工作"), (id: "8", name: "健身"),
    ]

    private func suggest(_ title: String, source: String = "", allowNew: Bool = true) -> CandidateCategory? {
        ScheduleCategorizer.suggest(title: title, source: source, lists: lists, allowNew: allowNew)?.category
    }

    func testSceneMatchesExistingList() {
        // 「打球」属于运动，已有的「健身」是运动的别名。
        XCTAssertEqual(suggest("打球"), .existing("8"))
        XCTAssertEqual(suggest("去腾讯开会"), .existing("7"))
        XCTAssertEqual(suggest("项目周会"), .existing("7"))
        XCTAssertEqual(suggest("参加腾讯开发大会"), .existing("7"))
    }

    func testListNameInText() {
        XCTAssertEqual(suggest("整理一下", source: "明天把工作周报交了"), .existing("7"))
    }

    func testSuggestNewList() {
        XCTAssertEqual(suggest("打游戏"), .new(name: "娱乐", colorIndex: 6))
        XCTAssertEqual(suggest("晚上吃饭"), .new(name: "生活", colorIndex: 2))
        // 「家长会」比「会议」类的词更具体。
        XCTAssertEqual(suggest("开家长会"), .new(name: "家庭", colorIndex: 3))
    }

    func testBuiltInScenes() {
        // 截图里的例子：开户、转数快一类归到财务。
        XCTAssertEqual(suggest("把我香港账户开通数转快"), .new(name: "财务", colorIndex: 12))
        XCTAssertEqual(suggest("还信用卡"), .new(name: "财务", colorIndex: 12))
        XCTAssertEqual(suggest("去续签港澳通行证"), .new(name: "办事", colorIndex: 15))
        XCTAssertEqual(suggest("参加同学婚礼"), .new(name: "社交", colorIndex: 9))
        XCTAssertEqual(suggest("取快递"), .new(name: "购物", colorIndex: 16))
        // 「宠物医院」比「医院」更具体。
        XCTAssertEqual(suggest("带猫去宠物医院"), .new(name: "宠物", colorIndex: 10))
    }

    func testMissingScenes() {
        let names = ScheduleCategorizer.missingScenes(existing: ["未分类", "工作", "健身"]).map(\.name)
        XCTAssertFalse(names.contains("工作"))
        XCTAssertFalse(names.contains("运动"))
        XCTAssertTrue(names.contains("财务"))
        XCTAssertEqual(names.count, ScheduleCategorizer.scenes.count - 2)
    }

    func testNoAutoCreate() {
        XCTAssertNil(suggest("打游戏", allowNew: false))
        // 关掉自动新建时，已有分类照样会选。
        XCTAssertEqual(suggest("打球", allowNew: false), .existing("8"))
    }

    private func pick(_ title: String, source: String? = nil, location: String = "") -> CandidateCategory? {
        ScheduleCategorizer.suggest(title: title, source: source ?? title, location: location, lists: [],
                                    allowNew: true)?.category
    }

    func testRuleSentenceGetsCategory() {
        let today = LocalDate(year: 2026, month: 11, day: 20)!
        let lines = ChatTimestamp.annotate(["非常重要 后天晚上，19:10 在杭州西湖区文三社区举行数字街区看 Rokid 新品"],
                                           today: today)
        let rules = PriorityCue.apply(RuleScheduleExtractor.extract(lines, today: today, weekStart: 1, lists: []))
        let found = ScheduleCategorizer.apply(rules, lists: [], fallback: TodoList.defaultID, allowNew: true)
        XCTAssertEqual(found.first?.category, .new(name: "工作", colorIndex: 7))
        XCTAssertEqual(found.first?.categoryReason?.contains("举行"), true)
    }

    func testWeakHintsNeedSupport() {
        XCTAssertNil(pick("看新品"))
        XCTAssertEqual(pick("看新品", source: "在园区举行看新品"), .new(name: "工作", colorIndex: 7))
        XCTAssertEqual(pick("抢购新品"), .new(name: "购物", colorIndex: 16))
    }

    func testPlaceHints() {
        XCTAssertEqual(pick("见张主任", source: "周三上午见张主任", location: "市第一人民医院"), .new(name: "健康", colorIndex: 1))
        XCTAssertEqual(pick("接人", source: "周五晚上8点去接人", location: "萧山机场"), .new(name: "出行", colorIndex: 5))
        XCTAssertNil(pick("碰一下", source: "明天下午碰一下", location: "文三社区"))
    }

    func testMoreSceneWords() {
        XCTAssertEqual(pick("去健身房撸铁"), .new(name: "运动", colorIndex: 4))
        XCTAssertEqual(pick("论文答辩"), .new(name: "学习", colorIndex: 8))
        XCTAssertEqual(pick("拜访客户"), .new(name: "工作", colorIndex: 7))
        XCTAssertEqual(pick("吃年夜饭"), .new(name: "家庭", colorIndex: 3))
        XCTAssertEqual(pick("交电费"), .new(name: "生活", colorIndex: 2))
        XCTAssertEqual(pick("看演唱会"), .new(name: "娱乐", colorIndex: 6))
        XCTAssertEqual(pick("改签高铁"), .new(name: "出行", colorIndex: 5))
        XCTAssertEqual(pick("去医院复查"), .new(name: "健康", colorIndex: 1))
    }

    func testHigherScoreWins() {
        // 「婚礼」是情景词，「举行」只是弱线索。
        XCTAssertEqual(pick("参加婚礼", source: "周六中午在酒店举行婚礼"), .new(name: "社交", colorIndex: 9))
    }

    func testNoScene() {
        XCTAssertNil(suggest("随便写点东西"))
    }

    func testApplyUsesFallback() {
        var a = ScheduleCandidate(title: "打球")
        a.source = "下下周五下午3点打球 时间为2小时"
        let b = ScheduleCandidate(title: "随便写点东西")
        let result = ScheduleCategorizer.apply([a, b], lists: lists, fallback: "1", allowNew: true)
        XCTAssertEqual(result[0].category, .existing("8"))
        XCTAssertNotNil(result[0].categoryReason)
        XCTAssertEqual(result[1].category, .existing("1"))
        XCTAssertNil(result[1].categoryReason)
    }
}
