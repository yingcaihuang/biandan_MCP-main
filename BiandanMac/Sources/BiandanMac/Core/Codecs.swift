import Foundation

// MARK: - taskContent：备注、子任务、附件

/// `taskContent` 的结构化形式，解码规则与 Python `decode_content` 一致。
/// 外层是字符串数组：首元素是备注或附件包，后续元素是子任务；附件包解码后为 `[备注, [文件引用]]`。
struct TaskContent: Hashable, Sendable {
    var remark: String
    var subtasks: [String]
    var attachments: [String]

    init(remark: String = "", subtasks: [String] = [], attachments: [String] = []) {
        self.remark = remark
        self.subtasks = subtasks
        self.attachments = attachments
    }

    static func decode(_ raw: String) -> TaskContent {
        guard let outer = parseJSON(raw) as? [Any], let strings = stringArray(outer) else {
            // 无法按合法结构解码的旧内容按纯文本显示。
            return TaskContent(remark: raw)
        }
        let first = strings.first ?? ""
        let subtasks = Array(strings.dropFirst())
        if let inner = parseJSON(first) as? [Any], inner.count == 2,
           let note = inner[0] as? String,
           let filesAny = inner[1] as? [Any], let files = stringArray(filesAny) {
            return TaskContent(remark: note, subtasks: subtasks, attachments: files)
        }
        return TaskContent(remark: first, subtasks: subtasks)
    }

    /// 按原生 `JSON.stringify` 的紧凑格式编码。
    func encoded() -> String {
        let first = attachments.isEmpty ? remark : Self.jsonString([remark, attachments] as [Any])
        return Self.jsonString([first] + subtasks)
    }

    private static func parseJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 只有每个元素都是字符串时才返回，NSNumber 不会被当作字符串。
    private static func stringArray(_ values: [Any]) -> [String]? {
        var result: [String] = []
        for value in values {
            guard let string = value as? String, !(value is NSNumber) else { return nil }
            result.append(string)
        }
        return result
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - favoritesColor：排序 × 100 + 颜色

struct ListColor: Hashable, Sendable {
    var sortIndex: Int
    var colorIndex: Int

    init(sortIndex: Int, colorIndex: Int) {
        self.sortIndex = sortIndex
        self.colorIndex = colorIndex
    }

    init(raw: Int) {
        sortIndex = floorDiv(raw, 100)
        colorIndex = floorMod(raw, 100)
    }

    var raw: Int { sortIndex * 100 + colorIndex }

    /// 原生色板：0 默认色；1–8 鲜亮、9–16 柔和、17–24 莫兰迪；每组依次为红、橙、黄、绿、湖蓝、浅蓝、深蓝、紫。
    /// 色值是 Mac 端自选的近似值，写入云端只用索引。
    static let palette: [UInt32] = [
        0xB9B09C,
        0xE5483A, 0xF08A24, 0xF5C518, 0x5DB65A, 0x2BB5B0, 0x4BA9E0, 0x3C64D8, 0x8E5BD6,
        0xE8928A, 0xF2B57F, 0xF2DA85, 0x9ED19A, 0x86D2CE, 0x9BCDEB, 0x93A8E8, 0xBFA3E8,
        0xB57B74, 0xBE9677, 0xC2B27E, 0x8FA889, 0x7FA3A1, 0x8BA3B5, 0x7D86A6, 0x9C8AA8,
    ]

    static let groupNames = ["鲜亮", "柔和", "莫兰迪"]
    static let hueNames = ["红", "橙", "黄", "绿", "湖蓝", "浅蓝", "深蓝", "紫"]

    var hex: UInt32 {
        ListColor.palette.indices.contains(colorIndex) ? ListColor.palette[colorIndex] : ListColor.palette[0]
    }
}

// MARK: - unitTimeNumber：完成目标

enum TaskGoal: Hashable, Sendable {
    /// 普通模式，目标次数 1–99。
    case count(Int)
    /// 子任务模式，存储为 位掩码 × 100。
    case checklist(mask: Int)

    /// 非正数归一为 1，与原生模型一致。
    init(unitTimeNumber raw: Int?) {
        let value = raw ?? 1
        if value >= 100 {
            self = .checklist(mask: value / 100)
        } else {
            self = .count(max(value, 1))
        }
    }

    init(subtaskCount: Int) {
        self = subtaskCount > 0 ? .checklist(mask: (1 << subtaskCount) - 1) : .count(1)
    }

    var raw: Int {
        switch self {
        case .count(let n): return n
        case .checklist(let mask): return mask * 100
        }
    }

    var isChecklist: Bool {
        if case .checklist = self { return true }
        return false
    }

    /// 展示用的目标数：次数或子任务项数（置位数）。
    var targetCount: Int {
        switch self {
        case .count(let n): return n
        case .checklist(let mask): return mask.nonzeroBitCount
        }
    }

    /// 子任务索引 i 是否属于目标。
    func includes(subtask index: Int) -> Bool {
        guard case .checklist(let mask) = self, (0..<20).contains(index) else { return false }
        return mask & (1 << index) != 0
    }
}

/// 执行实例的进度，规则与 Python `occurrence_view` 一致。
struct OccurrenceProgress: Hashable, Sendable {
    let completedCount: Int
    let targetCount: Int
    let completedSubtaskIndices: [Int]

    init(completedCount raw: Int, goal: TaskGoal) {
        let progress = max(raw, 0)
        switch goal {
        case .count(let n):
            completedCount = progress
            targetCount = n
            completedSubtaskIndices = []
        case .checklist(let mask):
            let bits = progress / 100
            completedCount = bits.nonzeroBitCount
            targetCount = mask.nonzeroBitCount
            completedSubtaskIndices = (0..<20).filter { bits & (1 << $0) != 0 }
        }
    }

    var fraction: Double {
        targetCount > 0 ? min(Double(completedCount) / Double(targetCount), 1) : 0
    }
}

// MARK: - isRemind：位 0 时间提醒，位 1 地点提醒

struct RemindFlags: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let time = RemindFlags(rawValue: 1)
    static let location = RemindFlags(rawValue: 2)
}

// MARK: - isLoop / loopSet / loopUnit

enum LoopKind: Int, CaseIterable, Sendable {
    case once = 0
    case repeating = 1
    case habit = 2

    /// 原生展示以 `>= 2` 判断习惯。
    init(raw: Int) {
        if raw >= 2 { self = .habit } else if raw == 1 { self = .repeating } else { self = .once }
    }

    var title: String {
        switch self {
        case .once: return "不重复"
        case .repeating: return "重复"
        case .habit: return "习惯"
        }
    }
}

enum LoopSet: Int, CaseIterable, Sendable {
    case none = 0, custom, workdays, daysOff, daily, ebbinghaus, weeklyPeriod, monthlyPeriod, yearlyPeriod

    /// 与 Python `MODES` 的键对应。
    var modeName: String {
        switch self {
        case .none: return "none"
        case .custom: return "custom"
        case .workdays: return "workdays"
        case .daysOff: return "days_off"
        case .daily: return "daily"
        case .ebbinghaus: return "ebbinghaus"
        case .weeklyPeriod: return "weekly_period"
        case .monthlyPeriod: return "monthly_period"
        case .yearlyPeriod: return "yearly_period"
        }
    }

    var title: String {
        switch self {
        case .none: return "仅一次"
        case .custom: return "自定义"
        case .workdays: return "工作日"
        case .daysOff: return "休息日"
        case .daily: return "每天"
        case .ebbinghaus: return "艾宾浩斯"
        case .weeklyPeriod: return "每周"
        case .monthlyPeriod: return "每月"
        case .yearlyPeriod: return "每年"
        }
    }

    var isPeriod: Bool { self == .weeklyPeriod || self == .monthlyPeriod || self == .yearlyPeriod }
}

enum LoopUnitKind: Int, CaseIterable, Sendable {
    case day = 0, week, month, year, lunarMonth, lunarYear

    var modeName: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        case .lunarMonth: return "lunar_month"
        case .lunarYear: return "lunar_year"
        }
    }

    var title: String {
        switch self {
        case .day: return "天"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        case .lunarMonth: return "农历月"
        case .lunarYear: return "农历年"
        }
    }
}

enum DayFilter: Int, CaseIterable, Sendable {
    case all = 0, daysOff, workdays

    var modeName: String {
        switch self {
        case .all: return "all"
        case .daysOff: return "days_off"
        case .workdays: return "workdays"
        }
    }

    var title: String {
        switch self {
        case .all: return "全部"
        case .daysOff: return "只保留休息日"
        case .workdays: return "只保留工作日"
        }
    }
}

/// `loopUnit = 单位 + 100 × 筛选类型`。未知编码保留原值，读取时按 nil 处理。
struct LoopUnit: Hashable, Sendable {
    var unitRaw: Int
    var filterRaw: Int

    init(raw: Int) {
        filterRaw = floorDiv(raw, 100)
        unitRaw = floorMod(raw, 100)
    }

    init(unit: LoopUnitKind, filter: DayFilter) {
        unitRaw = unit.rawValue
        filterRaw = filter.rawValue
    }

    var unit: LoopUnitKind? { LoopUnitKind(rawValue: unitRaw) }
    var filter: DayFilter? { DayFilter(rawValue: filterRaw) }
    var raw: Int { unitRaw + filterRaw * 100 }
}

// MARK: - tomato.log

/// 专注记录 `log`：兼容空串、旧纯文本和 JSON。保留原始对象，修改时不丢未知键。
struct FocusLog: Hashable, Sendable {
    var object: JSONObject
    /// 不是 JSON 对象时的原始文本（例如 `Date.toString()`）。
    var plainText: String?

    init(raw: String?) {
        let text = raw ?? ""
        if let parsed = JSONValue.parseObject(text) {
            object = parsed
            plainText = nil
        } else {
            object = [:]
            plainText = text.isEmpty ? nil : text
        }
    }

    var eventID: String? {
        guard let id = object.identifier("eventId"), id != "-1" else { return nil }
        return id
    }

    var eventTitle: String { object.string("eventTitle") ?? "" }
    var eventType: Int? { object.int("eventType") }
    var endTime: String? { object.string("endTime") ?? plainText }
}
