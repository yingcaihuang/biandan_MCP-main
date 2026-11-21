import Foundation

/// 一条识别出的日程归到哪个分类：已有分类，或点「添加选中」时再新建的分类。
enum CandidateCategory: Equatable {
    case existing(String)
    case new(name: String, colorIndex: Int)
}

// MARK: - 按情景选分类
//
// 先看原文有没有直接提到已有分类名；没有就按「开会」「打球」「开户」这类情景词归类：
// 已有对应分类（名字里含情景名或别名，例如「健身」对应运动）就用它，否则建议新建（设置里可以关掉）。
// 内置的常用分类也会列在分类选择里，没建过的可以直接选，添加时再新建。
enum ScheduleCategorizer {
    struct Scene {
        let name: String
        let aliases: [String]
        let keywords: [String]
        /// ListColor.palette 的序号：1–8 鲜亮（红橙黄绿湖蓝浅蓝深蓝紫），9–16 柔和（同序）。
        let colorIndex: Int
    }

    /// 内置常用分类，也是分类选择里「常用分类」的顺序。
    static let scenes: [Scene] = [
        Scene(name: "工作", aliases: ["工作", "公司", "会议", "项目", "办公"],
              keywords: ["开会", "会议", "周会", "例会", "晨会", "站会", "评审", "复盘", "汇报", "述职", "面试", "项目",
                         "需求", "上线", "发版", "客户", "对接", "培训", "加班", "出差", "周报", "日报", "月报", "报告",
                         "方案", "合同", "签约", "提案", "排期", "OKR", "KPI", "PPT",
                         "大会", "发布会", "峰会", "展会", "研讨会", "沙龙", "论坛"],
              colorIndex: 7),
        Scene(name: "财务", aliases: ["财务", "理财", "金融", "账单", "记账", "银行"],
              keywords: ["账户", "账号开通", "开户", "销户", "银行", "转账", "汇款", "转数快", "信用卡", "还款", "还信用卡",
                         "房贷", "车贷", "贷款", "报税", "个税", "退税", "发票", "报销", "保险", "续保", "理财", "基金",
                         "股票", "证券", "港卡", "换汇", "结汇", "工资", "发薪", "对账", "记账", "账单", "存款", "定期"],
              colorIndex: 12),
        Scene(name: "办事", aliases: ["办事", "证件", "政务", "手续"],
              keywords: ["护照", "签证", "续签", "身份证", "驾照", "驾驶证", "港澳通行证", "通行证", "社保", "公积金",
                         "户口", "居住证", "办证", "年检", "营业执照", "公证", "盖章", "办手续", "政务", "预约办理"],
              colorIndex: 15),
        Scene(name: "学习", aliases: ["学习", "课程", "读书"],
              keywords: ["上课", "课程", "考试", "学习", "作业", "读书", "讲座", "复习", "网课", "背单词", "考证", "论文"],
              colorIndex: 8),
        Scene(name: "运动", aliases: ["运动", "健身", "锻炼", "体育"],
              keywords: ["打球", "篮球", "足球", "羽毛球", "乒乓", "网球", "排球", "球赛", "跑步", "健身", "游泳", "瑜伽",
                         "爬山", "徒步", "骑行", "锻炼", "滑雪", "攀岩", "飞盘", "普拉提", "马拉松"],
              colorIndex: 4),
        Scene(name: "健康", aliases: ["健康", "医疗", "就医"],
              keywords: ["医院", "看病", "体检", "牙医", "看牙", "洗牙", "复诊", "挂号", "吃药", "打针", "疫苗", "门诊"],
              colorIndex: 1),
        Scene(name: "生活", aliases: ["生活", "日常", "家务"],
              keywords: ["吃饭", "约饭", "午饭", "晚饭", "早饭", "买菜", "理发", "缴费", "交费", "水电", "物业", "房租",
                         "搬家", "洗车", "做饭", "打扫", "维修", "保洁"],
              colorIndex: 2),
        Scene(name: "购物", aliases: ["购物", "买买买", "剁手"],
              keywords: ["购物", "网购", "逛街", "超市", "下单", "抢购", "秒杀", "双十一", "退货", "快递", "取件"],
              colorIndex: 16),
        Scene(name: "社交", aliases: ["社交", "朋友", "人情"],
              keywords: ["聚会", "聚餐", "约会", "婚礼", "喜酒", "请客", "拜访", "见面", "见个面", "同学会", "派对", "送礼"],
              colorIndex: 9),
        Scene(name: "家庭", aliases: ["家庭", "家人", "孩子"],
              keywords: ["家长会", "接孩子", "送孩子", "爸妈", "父母", "回家", "带娃", "纪念日", "生日"],
              colorIndex: 3),
        Scene(name: "出行", aliases: ["出行", "旅行", "旅游", "差旅"],
              keywords: ["机票", "航班", "高铁", "火车", "动车", "旅行", "旅游", "酒店", "接机", "送机", "登机", "打车",
                         "自驾", "值机"],
              colorIndex: 5),
        Scene(name: "娱乐", aliases: ["娱乐", "游戏", "休闲"],
              keywords: ["打游戏", "游戏", "开黑", "唱歌", "KTV", "演唱会", "电影", "看剧", "桌游", "剧本杀", "展览", "话剧"],
              colorIndex: 6),
        Scene(name: "宠物", aliases: ["宠物", "猫", "狗"],
              keywords: ["宠物", "猫粮", "狗粮", "遛狗", "铲屎", "驱虫", "宠物医院", "洗澡美容"],
              colorIndex: 10),
    ]

    /// 情景词从长到短：「家长会」先于「会议」，「宠物医院」先于「医院」。
    private static let keywords: [(word: String, scene: Scene)] = scenes
        .flatMap { scene in scene.keywords.map { (word: $0, scene: scene) } }
        .sorted { $0.word.count > $1.word.count }

    /// 已有分类里有没有对应这个情景的（名字里含情景名或别名）。
    private static func list(for scene: Scene, in named: [(id: String, name: String)]) -> (id: String, name: String)? {
        let names = [scene.name] + scene.aliases
        return named.first { list in names.contains { list.name.contains($0) } }
    }

    /// 给一条日程挑分类；挑不出来返回 nil。reason 显示在卡片里。
    static func suggest(title: String, source: String, lists: [(id: String, name: String)],
                        allowNew: Bool) -> (category: CandidateCategory, reason: String)? {
        let text = (title + "\n" + source).lowercased()
        let named = lists.filter { $0.id != TodoList.defaultID && !$0.name.isEmpty }
        if let hit = named.filter({ $0.name.count >= 2 && text.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return (.existing(hit.id), "原文提到「\(hit.name)」，归到这个分类")
        }
        guard let found = keywords.first(where: { text.contains($0.word.lowercased()) }) else { return nil }
        let scene = found.scene
        if let list = list(for: scene, in: named) {
            return (.existing(list.id), "按「\(found.word)」归到「\(list.name)」")
        }
        guard allowNew else { return nil }
        return (.new(name: scene.name, colorIndex: scene.colorIndex),
                "按「\(found.word)」建议新建分类「\(scene.name)」，点「添加选中」时才会新建")
    }

    /// 按情景给每条日程设好分类；挑不出来的用 fallback。
    static func apply(_ candidates: [ScheduleCandidate], lists: [(id: String, name: String)], fallback: String,
                      allowNew: Bool) -> [ScheduleCandidate] {
        candidates.map { candidate in
            var result = candidate
            result.category = .existing(fallback)
            result.categoryReason = nil
            if let name = candidate.suggestedCategory,
               let found = resolve(named: name, lists: lists, allowNew: allowNew) {
                result.category = found.category
                result.categoryReason = found.reason
            } else if let found = suggest(title: candidate.title, source: candidate.source, lists: lists,
                                          allowNew: allowNew) {
                result.category = found.category
                result.categoryReason = found.reason
            }
            return result
        }
    }

    /// AI 给出的分类名 → 分类：先找同名的已有分类，再找内置常用分类（已有对应分类就用它，否则按设置建议新建）。
    static func resolve(named raw: String, lists: [(id: String, name: String)],
                        allowNew: Bool) -> (category: CandidateCategory, reason: String)? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "未分类" else { return nil }
        let named = lists.filter { $0.id != TodoList.defaultID && !$0.name.isEmpty }
        if let list = named.first(where: { $0.name == name }) {
            return (.existing(list.id), "AI 归到「\(list.name)」")
        }
        guard let scene = scenes.first(where: { $0.name == name }) else { return nil }
        if let list = list(for: scene, in: named) {
            return (.existing(list.id), "AI 按情景「\(scene.name)」归到「\(list.name)」")
        }
        guard allowNew else { return nil }
        return (.new(name: scene.name, colorIndex: scene.colorIndex),
                "AI 建议新建分类「\(scene.name)」，点「添加选中」时才会新建")
    }

    /// 告诉 AI 的可选分类：已有分类，加上还没建过的内置常用分类。
    static func promptCategories(lists: [(id: String, name: String)]) -> [String] {
        let names = lists.filter { $0.id != TodoList.defaultID && !$0.name.isEmpty && $0.name != "未分类" }.map(\.name)
        return names + missingScenes(existing: names).map(\.name)
    }

    /// 分类选择里「常用分类」：还没有对应分类的内置情景。
    static func missingScenes(existing names: [String]) -> [Scene] {
        let named = names.enumerated().map { (id: String($0.offset), name: $0.element) }.filter { $0.name != "未分类" }
        return scenes.filter { list(for: $0, in: named) == nil }
    }

    /// 手动输入新分类时的颜色：情景分类用情景色，其他按名字挑一个鲜亮色。
    static func colorIndex(for name: String) -> Int {
        if let scene = scenes.first(where: { $0.name == name }) { return scene.colorIndex }
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return sum % 8 + 1
    }
}
