import Foundation

/// 一条识别出的日程归到哪个分类：已有分类，或点「添加选中」时再新建的分类。
enum CandidateCategory: Equatable {
    case existing(String)
    case new(name: String, colorIndex: Int)
}

// MARK: - 按情景选分类
//
// 先看原文有没有直接提到已有分类名；没有就按情景词打分：
// - 情景词（「开会」「打球」「开户」）3 分，出现在标题里再加 1 分；
// - 弱线索（「举行」「新品」，单独出现说明不了什么）1 分；
// - 地点里的场所词（「医院」「机场」「写字楼」）2 分。
// 同一个词只算一次，至少 2 分才算数，取得分最高的情景。
// 已有对应分类（名字里含情景名或别名，例如「健身」对应运动）就用它，否则建议新建（设置里可以关掉）。
// 内置的常用分类也会列在分类选择里，没建过的可以直接选，添加时再新建。
enum ScheduleCategorizer {
    struct Scene {
        let name: String
        let aliases: [String]
        let keywords: [String]
        /// ListColor.palette 的序号：1–8 鲜亮（红橙黄绿湖蓝浅蓝深蓝紫），9–16 柔和（同序）。
        let colorIndex: Int
        /// 弱线索：要和别的线索一起出现才算数。
        var hints: [String] = []
        /// 地点里出现这些词时加分。
        var places: [String] = []
    }

    /// 内置常用分类，也是分类选择里「常用分类」的顺序。
    static let scenes: [Scene] = [
        Scene(name: "工作", aliases: ["工作", "公司", "会议", "项目", "办公"],
              keywords: ["开会", "会议", "周会", "例会", "晨会", "站会", "评审", "复盘", "汇报", "述职", "面试", "项目",
                         "需求", "上线", "发版", "客户", "对接", "培训", "加班", "出差", "周报", "日报", "月报", "报告",
                         "方案", "合同", "签约", "提案", "排期", "OKR", "KPI", "PPT",
                         "大会", "发布会", "峰会", "展会", "研讨会", "沙龙", "论坛",
                         "新品发布", "产品发布", "体验会", "交流会", "分享会", "宣讲会", "说明会", "推介会", "博览会",
                         "交易会", "展销会", "开幕式", "路演", "团建", "年会", "招聘", "拜访客户", "客户拜访", "考察",
                         "调研", "验收", "交付", "立项", "迭代", "版本", "测试", "部署", "代码", "开发", "访谈", "约谈",
                         "1on1", "一对一", "工作坊", "黑客松", "开发者", "董事会", "股东会", "季度会", "月会", "全员会",
                         "入职", "离职", "交接", "值班", "打卡", "绩效", "预算评审", "投标", "招标", "谈判"],
              colorIndex: 7,
              hints: ["举行", "举办", "召开", "新品", "产品", "发布", "参观", "体验", "活动", "科技", "智能", "技术",
                      "展台", "展位", "签到", "同事", "领导", "老板", "部门", "团队"],
              places: ["公司", "大厦", "园区", "写字楼", "会议室", "办公室", "科技园", "产业园", "孵化器", "会展中心",
                       "展览中心", "博览中心", "国际会议中心", "工位", "腾讯会议", "飞书会议", "钉钉会议", "zoom"]),
        Scene(name: "财务", aliases: ["财务", "理财", "金融", "账单", "记账", "银行"],
              keywords: ["账户", "账号开通", "开户", "销户", "银行", "转账", "汇款", "转数快", "信用卡", "还款", "还信用卡",
                         "房贷", "车贷", "贷款", "报税", "个税", "退税", "发票", "报销", "保险", "续保", "理财", "基金",
                         "股票", "证券", "港卡", "换汇", "结汇", "工资", "发薪", "对账", "记账", "账单", "存款", "定期",
                         "还贷", "花呗", "借呗", "白条", "缴税", "分红", "年终奖", "收款", "付款", "打款", "预算", "利息"],
              colorIndex: 12,
              places: ["银行", "营业厅", "证券营业部"]),
        Scene(name: "办事", aliases: ["办事", "证件", "政务", "手续"],
              keywords: ["护照", "签证", "续签", "身份证", "驾照", "驾驶证", "港澳通行证", "通行证", "社保", "公积金",
                         "户口", "居住证", "办证", "年检", "营业执照", "公证", "盖章", "办手续", "政务", "预约办理",
                         "补办", "挂失", "落户", "结婚登记", "领证", "过户", "备案", "审批", "开证明", "提取公积金"],
              colorIndex: 15,
              hints: ["办理", "手续", "证明", "材料"],
              places: ["政务中心", "政务大厅", "行政服务中心", "市民中心", "派出所", "车管所", "民政局", "税务局",
                       "出入境", "公证处", "社保中心", "街道办"]),
        Scene(name: "学习", aliases: ["学习", "课程", "读书"],
              keywords: ["上课", "课程", "考试", "学习", "作业", "读书", "讲座", "复习", "网课", "背单词", "考证", "论文",
                         "公开课", "研学", "考研", "雅思", "托福", "四六级", "答辩", "开题", "选课", "开学", "毕业",
                         "自习", "补习", "家教", "辅导", "练琴", "钢琴课", "英语课", "直播课", "听课", "预习", "刷题"],
              colorIndex: 8,
              hints: ["课", "老师", "教材", "笔记"],
              places: ["学校", "大学", "学院", "教室", "图书馆", "自习室", "培训中心", "考场", "教学楼"]),
        Scene(name: "运动", aliases: ["运动", "健身", "锻炼", "体育"],
              keywords: ["打球", "篮球", "足球", "羽毛球", "乒乓", "网球", "排球", "球赛", "跑步", "健身", "游泳", "瑜伽",
                         "爬山", "徒步", "骑行", "锻炼", "滑雪", "攀岩", "飞盘", "普拉提", "马拉松",
                         "健身房", "私教", "撸铁", "夜跑", "晨跑", "跳绳", "太极", "高尔夫", "台球", "保龄球", "冲浪",
                         "潜水", "划船", "拳击", "搏击", "举铁", "拉伸", "广场舞", "匹克球", "橄榄球"],
              colorIndex: 4,
              places: ["健身房", "体育馆", "体育中心", "球馆", "球场", "游泳馆", "操场", "运动场", "滑雪场", "岩馆"]),
        Scene(name: "健康", aliases: ["健康", "医疗", "就医"],
              keywords: ["医院", "看病", "体检", "牙医", "看牙", "洗牙", "复诊", "挂号", "吃药", "打针", "疫苗", "门诊",
                         "复查", "看医生", "化验", "抽血", "拍片", "B超", "核磁", "胃镜", "理疗", "针灸", "推拿", "按摩",
                         "心理咨询", "中医", "拿药", "配药", "配眼镜", "眼科", "口腔", "产检", "输液", "住院", "出院", "手术"],
              colorIndex: 1,
              hints: ["医生", "主任", "药"],
              places: ["医院", "诊所", "卫生院", "门诊", "社区卫生", "口腔", "药店", "体检中心", "急诊"]),
        Scene(name: "生活", aliases: ["生活", "日常", "家务"],
              keywords: ["吃饭", "约饭", "午饭", "晚饭", "早饭", "买菜", "理发", "缴费", "交费", "水电", "物业", "房租",
                         "搬家", "洗车", "做饭", "打扫", "维修", "保洁", "电费", "水费", "燃气", "宽带", "话费", "装修",
                         "开锁", "修手机", "修电脑", "美甲", "做头发", "剪头发", "洗衣", "干洗", "取衣服", "倒垃圾",
                         "早餐", "午餐", "晚餐", "夜宵", "下午茶", "外卖", "收拾", "换季"],
              colorIndex: 2,
              places: ["菜市场", "理发店", "洗衣店", "物业中心", "营业厅"]),
        Scene(name: "购物", aliases: ["购物", "买买买", "剁手"],
              keywords: ["购物", "网购", "逛街", "超市", "下单", "抢购", "秒杀", "双十一", "退货", "快递", "取件",
                         "采购", "拼单", "团购", "预售", "付尾款", "尾款", "618", "开售", "发售", "开抢", "换货", "退款",
                         "代购", "囤货", "直播间"],
              colorIndex: 16,
              hints: ["买", "新品", "首发", "上新", "优惠", "折扣"],
              places: ["商场", "超市", "购物中心", "奥莱", "专卖店", "旗舰店", "快递柜", "驿站"]),
        Scene(name: "社交", aliases: ["社交", "朋友", "人情"],
              keywords: ["聚会", "聚餐", "约会", "婚礼", "喜酒", "请客", "拜访", "见面", "见个面", "同学会", "派对", "送礼",
                         "饭局", "喝酒", "喝茶", "喝咖啡", "叙旧", "拜年", "探望", "看望", "满月酒", "生日会", "团聚",
                         "相亲", "接风", "送别", "轰趴", "串门"],
              colorIndex: 9,
              hints: ["朋友", "同学", "老友", "兄弟", "闺蜜"],
              places: ["餐厅", "饭店", "酒楼", "酒吧", "咖啡馆", "茶馆", "火锅"]),
        Scene(name: "家庭", aliases: ["家庭", "家人", "孩子"],
              keywords: ["家长会", "接孩子", "送孩子", "爸妈", "父母", "回家", "带娃", "纪念日", "生日",
                         "接娃", "送娃", "幼儿园", "兴趣班", "年夜饭", "家宴", "回老家", "陪孩子", "亲子", "开家长"],
              colorIndex: 3,
              hints: ["老婆", "老公", "儿子", "女儿", "宝宝", "奶奶", "爷爷", "外婆", "外公", "亲戚", "妈妈", "爸爸"],
              places: ["幼儿园", "老家"]),
        Scene(name: "出行", aliases: ["出行", "旅行", "旅游", "差旅"],
              keywords: ["机票", "航班", "高铁", "火车", "动车", "旅行", "旅游", "酒店", "接机", "送机", "登机", "打车",
                         "自驾", "值机", "飞机", "起飞", "落地", "返程", "订票", "抢票", "改签", "退票", "租车", "度假",
                         "签证面签", "入住", "退房", "接站", "送站"],
              colorIndex: 5,
              hints: ["出发", "行李", "车次"],
              places: ["机场", "航站楼", "火车站", "高铁站", "汽车站", "客运站", "码头", "服务区"]),
        Scene(name: "娱乐", aliases: ["娱乐", "游戏", "休闲"],
              keywords: ["打游戏", "游戏", "开黑", "唱歌", "KTV", "演唱会", "电影", "看剧", "桌游", "剧本杀", "展览", "话剧",
                         "音乐节", "音乐会", "脱口秀", "livehouse", "漫展", "密室", "露营", "野餐", "看展", "博物馆",
                         "美术馆", "游乐园", "迪士尼", "环球影城", "演出", "追剧", "综艺"],
              colorIndex: 6,
              places: ["电影院", "影城", "剧院", "大剧院", "体育场", "博物馆", "美术馆", "游乐园", "乐园", "KTV"]),
        Scene(name: "宠物", aliases: ["宠物", "猫", "狗"],
              keywords: ["宠物", "猫粮", "狗粮", "遛狗", "铲屎", "驱虫", "宠物医院", "洗澡美容", "猫砂", "绝育", "打疫苗针",
                         "喂猫", "喂狗", "撸猫"],
              colorIndex: 10,
              places: ["宠物医院", "宠物店"]),
    ]

    private struct Hit {
        let scene: Int
        let weight: Int
        let strong: Bool
    }

    private struct Term {
        let word: String
        let key: String
        let hits: [Hit]
    }

    /// 原文里的词：情景词 3 分，弱线索 1 分。从长到短，「家长会」先于「会议」，「宠物医院」先于「医院」。
    private static let textTerms: [Term] = terms { scene in
        scene.keywords.map { (word: $0, weight: 3, strong: true) } + scene.hints.map { (word: $0, weight: 1, strong: false) }
    }
    /// 地点里的场所词，2 分。
    private static let placeTerms: [Term] = terms { scene in scene.places.map { (word: $0, weight: 2, strong: false) } }

    /// 至少这么多分才归类：一个情景词、一个场所词，或两个弱线索。
    static let threshold = 2

    private static func terms(_ words: (Scene) -> [(word: String, weight: Int, strong: Bool)]) -> [Term] {
        var table: [String: (word: String, hits: [Hit])] = [:]
        for (index, scene) in scenes.enumerated() {
            for item in words(scene) {
                let key = item.word.lowercased()
                var entry = table[key] ?? (word: item.word, hits: [])
                if !entry.hits.contains(where: { $0.scene == index }) {
                    entry.hits.append(Hit(scene: index, weight: item.weight, strong: item.strong))
                }
                table[key] = entry
            }
        }
        let list = table.map { Term(word: $0.value.word, key: $0.key, hits: $0.value.hits) }
        return list.sorted { left, right in
            if left.key.count != right.key.count { return left.key.count > right.key.count }
            return left.key < right.key
        }
    }

    private struct Tally {
        var score = 0
        var longest = 0
        var words: [(word: String, points: Int)] = []
    }

    /// 给各情景打分，返回得分最高、且过了门槛的情景和命中的词（分高的在前）。
    static func bestScene(title: String, source: String, location: String) -> (scene: Scene, words: [String])? {
        var tallies: [Int: Tally] = [:]
        func credit(_ term: Term, _ hit: Hit, bonus: Int) {
            var tally = tallies[hit.scene] ?? Tally()
            guard !tally.words.contains(where: { $0.word == term.word }) else { return }
            let points = hit.weight + bonus
            tally.score += points
            tally.longest = max(tally.longest, term.key.count)
            tally.words.append((word: term.word, points: points))
            tallies[hit.scene] = tally
        }
        let lowerTitle = title.lowercased()
        var text = (title + "\n" + source).lowercased()
        for term in textTerms {
            guard text.contains(term.key) else { continue }
            let inTitle = lowerTitle.contains(term.key)
            for hit in term.hits { credit(term, hit, bonus: hit.strong && inTitle ? 1 : 0) }
            // 命中的词挖掉，短词不再重复计分（「宠物医院」里的「医院」）。
            text = text.replacingOccurrences(of: term.key, with: "｜")
        }
        var place = location.lowercased()
        for term in placeTerms {
            guard place.contains(term.key) else { continue }
            for hit in term.hits { credit(term, hit, bonus: 0) }
            place = place.replacingOccurrences(of: term.key, with: "｜")
        }
        let passed = tallies.filter { $0.value.score >= threshold }
        let ranked = passed.sorted { left, right in
            if left.value.score != right.value.score { return left.value.score > right.value.score }
            if left.value.longest != right.value.longest { return left.value.longest > right.value.longest }
            return left.key < right.key
        }
        guard let best = ranked.first else { return nil }
        let words = best.value.words.sorted { $0.points > $1.points }.map(\.word)
        return (scenes[best.key], words)
    }

    /// 已有分类里有没有对应这个情景的（名字里含情景名或别名）。
    private static func list(for scene: Scene, in named: [(id: String, name: String)]) -> (id: String, name: String)? {
        let names = [scene.name] + scene.aliases
        return named.first { list in names.contains { list.name.contains($0) } }
    }

    /// 给一条日程挑分类；挑不出来返回 nil。reason 显示在卡片里。
    static func suggest(title: String, source: String, location: String = "", lists: [(id: String, name: String)],
                        allowNew: Bool) -> (category: CandidateCategory, reason: String)? {
        let text = (title + "\n" + source).lowercased()
        let named = lists.filter { $0.id != TodoList.defaultID && !$0.name.isEmpty }
        if let hit = named.filter({ $0.name.count >= 2 && text.contains($0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) {
            return (.existing(hit.id), "原文提到「\(hit.name)」，归到这个分类")
        }
        guard let found = bestScene(title: title, source: source, location: location) else { return nil }
        let scene = found.scene
        let words = found.words.prefix(3).map { "「" + $0 + "」" }.joined()
        if let list = list(for: scene, in: named) {
            return (.existing(list.id), ["按", words, "归到「", list.name, "」"].joined())
        }
        guard allowNew else { return nil }
        return (.new(name: scene.name, colorIndex: scene.colorIndex),
                ["按", words, "建议新建分类「", scene.name, "」，点「添加选中」时才会新建"].joined())
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
            } else if let found = suggest(title: candidate.title, source: candidate.source,
                                          location: candidate.location, lists: lists, allowNew: allowNew) {
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
