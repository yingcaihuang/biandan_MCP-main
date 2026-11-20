import Foundation

// MARK: - 云记录

enum RecordKind: String, CaseIterable, Sendable {
    case task = "Task"
    case showTask = "showTask"
    case favorites = "favorites"
    case tomato = "tomato"

    /// 表内业务主键字段。
    var businessKey: String {
        switch self {
        case .task: return "id1"
        case .showTask: return "id2"
        case .favorites: return "id3"
        case .tomato: return "time"
        }
    }
}

enum RecordError: Error, LocalizedError {
    case unexpectedRecord
    case missingID

    var errorDescription: String? {
        switch self {
        case .unexpectedRecord: return "云端返回了无法识别的记录"
        case .missingID: return "云端记录缺少 ID"
        }
    }
}

/// 华为同步接口的一条记录。外层 `id`、`version` 属于传输层，`attributes` 是业务字段。
struct RawRecord: Hashable, Sendable {
    let kind: RecordKind
    let cloudID: String
    var version: Int?
    var createdTime: String?
    var editedTime: String?
    /// nil 表示列表只返回了 ID，需要再取详情。
    var attributes: JSONObject?

    /// 与 Python `normalize_record` 一致：兼容 `recordID`/`id`、`attributes`/`fields` 包装。
    static func normalize(_ row: JSONValue, kind: RecordKind) throws -> RawRecord {
        guard case .object(let object) = row else { throw RecordError.unexpectedRecord }
        let rawID = object["recordID"].flatMap { $0 == .null ? nil : $0 } ?? object["id"]
        guard let identifier = rawID?.identifierString ?? rawID?.stringValue, !identifier.isEmpty else {
            throw RecordError.missingID
        }
        var attributes: JSONObject?
        if case .object(let attrs)? = object["attributes"] {
            attributes = attrs
        } else if case .object(let fields)? = object["fields"] {
            attributes = fields.mapValues { item in
                if case .object(let wrapped) = item, let value = wrapped["value"] { return value }
                return item
            }
        }
        // 云记录长 ID 始终按字符串保存，不做数字归一。
        let cloudID: String
        if case .string(let text)? = rawID { cloudID = text } else { cloudID = identifier }
        return RawRecord(
            kind: kind,
            cloudID: cloudID,
            version: object.int("version"),
            createdTime: object["createdTime"]?.stringValue ?? object["createdTime"].map { $0.displayText },
            editedTime: object["editedTime"]?.stringValue ?? object["editedTime"].map { $0.displayText },
            attributes: attributes
        )
    }

    var businessID: String? { attributes?.identifier(kind.businessKey) }
}

/// 每个模型都带的传输层信息和原始字段，用于「高级」区展示和无损回写。
struct RecordMeta: Hashable, Sendable {
    var cloudID: String
    var version: Int?
    var createdTime: String?
    var editedTime: String?
    var raw: JSONObject

    init(_ record: RawRecord) {
        cloudID = record.cloudID
        version = record.version
        createdTime = record.createdTime
        editedTime = record.editedTime
        raw = record.attributes ?? [:]
    }
}

// MARK: - favorites：待办单（3 列）

struct TodoList: Identifiable, Hashable, Sendable {
    static let defaultID = "1"

    var meta: RecordMeta?
    var id3: String
    var favoritesName: String
    var favoritesColor: Int

    var id: String { id3 }
    var color: ListColor { ListColor(raw: favoritesColor) }
    var isDefault: Bool { id3 == TodoList.defaultID }

    init(record: RawRecord) {
        let a = record.attributes ?? [:]
        meta = RecordMeta(record)
        id3 = a.identifier("id3") ?? ""
        favoritesName = a.string("favoritesName") ?? ""
        favoritesColor = a.int("favoritesColor") ?? 0
    }

    init(id3: String, name: String, color: Int) {
        meta = nil
        self.id3 = id3
        favoritesName = name
        favoritesColor = color
    }

    /// 云端没有 id3=1 的记录时补一条默认分类。
    static let synthesizedDefault = TodoList(id3: defaultID, name: "默认", color: 0)
}

// MARK: - Task：待办定义（26 列）

enum Quadrant: Int, CaseIterable, Sendable {
    case importantUrgent, importantNotUrgent, notImportantUrgent, neither

    init(important: Bool, urgent: Bool) {
        switch (important, urgent) {
        case (true, true): self = .importantUrgent
        case (true, false): self = .importantNotUrgent
        case (false, true): self = .notImportantUrgent
        case (false, false): self = .neither
        }
    }

    var title: String {
        switch self {
        case .importantUrgent: return "重要且紧急"
        case .importantNotUrgent: return "重要但不紧急"
        case .notImportantUrgent: return "不重要但紧急"
        case .neither: return "不重要且不紧急"
        }
    }

    var isImportant: Bool { self == .importantUrgent || self == .importantNotUrgent }
    var isUrgent: Bool { self == .importantUrgent || self == .notImportantUrgent }
}

struct TaskDef: Identifiable, Hashable, Sendable {
    var meta: RecordMeta?

    var id1: String
    var taskTitle: String
    var taskContent: String
    var id3: String
    var isCollectible: Int
    var isImportant: Int
    var isUrgency: Int
    var startTime: String?
    var endTime: String?
    var isLoop: Int
    var haveNoTime: Int
    var unitTimeNumber: Int
    var validStartTime: String
    var validEndTime: String
    var loopSet: Int
    var loopBaseNumber: Int
    var loopUnit: Int
    var loopDate: String
    var duration: Int
    var isRemind: Int
    var remindDate: String?
    var remindTime: String?
    var isFinish: Int
    var latitude: Double
    var longitude: Double
    var location: String

    var id: String { id1 }

    /// 缺字段时使用原生建表默认值。
    init(record: RawRecord) {
        let a = record.attributes ?? [:]
        meta = RecordMeta(record)
        id1 = a.identifier("id1") ?? ""
        taskTitle = a.string("taskTitle") ?? ""
        taskContent = a.string("taskContent") ?? ""
        // 原生模型把 <= 1 归一为 1。
        let list = a.identifier("id3") ?? TodoList.defaultID
        id3 = (Int64(list) ?? 1) <= 1 ? TodoList.defaultID : list
        isCollectible = a.int("isCollectible") ?? 0
        isImportant = a.int("isImportant") ?? 0
        isUrgency = a.int("isUrgency") ?? 0
        startTime = a.string("startTime")
        endTime = a.string("endTime")
        isLoop = a.int("isLoop") ?? 0
        haveNoTime = a.int("haveNoTime") ?? 0
        unitTimeNumber = a.int("unitTimeNumber") ?? 1
        validStartTime = a.string("validStartTime") ?? "00:00:00"
        validEndTime = a.string("validEndTime") ?? "23:59:59"
        loopSet = a.int("loopSet") ?? 0
        loopBaseNumber = a.int("loopBaseNumber") ?? 1
        loopUnit = a.int("loopUnit") ?? 0
        loopDate = a.string("loopDate") ?? ""
        duration = a.int("duration") ?? 0
        isRemind = a.int("isRemind") ?? 0
        remindDate = a.string("remindDate")
        remindTime = a.string("remindTime")
        isFinish = a.int("isFinish") ?? 0
        latitude = a.double("latitude") ?? -1
        longitude = a.double("longitude") ?? -1
        location = a.string("location") ?? ""
    }

    // MARK: 解码后的视图属性

    var content: TaskContent { TaskContent.decode(taskContent) }
    var goal: TaskGoal { TaskGoal(unitTimeNumber: unitTimeNumber) }
    var remindFlags: RemindFlags { RemindFlags(rawValue: isRemind) }
    var loopKind: LoopKind { LoopKind(raw: isLoop) }
    var repeatSet: LoopSet? { LoopSet(rawValue: loopSet) }
    var unit: LoopUnit { LoopUnit(raw: loopUnit) }
    var loopDates: [String] { loopDate.split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    var important: Bool { isImportant != 0 }
    var urgent: Bool { isUrgency != 0 }
    var collected: Bool { isCollectible != 0 }
    var completed: Bool { isFinish != 0 }
    var undated: Bool { haveNoTime != 0 }
    var isHabit: Bool { isLoop >= 2 }
    /// 与 Python 一致：`isLoop` 或 `loopSet` 非零即视为循环。
    var isRepeating: Bool { isLoop != 0 || loopSet != 0 }
    var quadrant: Quadrant { Quadrant(important: important, urgent: urgent) }

    var startDate: LocalDate? { LocalDate(iso: startTime) }
    var endDate: LocalDate? { LocalDate(iso: endTime) }
    var startClock: LocalTime? { LocalTime(text: validStartTime) }
    var endClock: LocalTime? { LocalTime(text: validEndTime) }

    var hasTimeReminder: Bool { remindFlags.contains(.time) }
    var hasLocationReminder: Bool { remindFlags.contains(.location) }
    var hasCoordinate: Bool { !(latitude == -1 && longitude == -1) }
    /// 与 Python `task_view` 的 location 判断一致。
    var hasLocation: Bool { !location.isEmpty || hasCoordinate || hasLocationReminder }

    var searchableText: [String] {
        let decoded = content
        return [taskTitle, decoded.remark] + decoded.subtasks
    }

    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return searchableText.contains { $0.lowercased().contains(needle) }
    }
}

// MARK: - showTask：执行实例（9 列）

enum OccurrenceStatus: String, CaseIterable, Sendable {
    case pending, completed, abandoned

    var title: String {
        switch self {
        case .pending: return "待完成"
        case .completed: return "已完成"
        case .abandoned: return "已放弃"
        }
    }
}

struct Occurrence: Identifiable, Hashable, Sendable {
    var meta: RecordMeta?

    var id2: String
    var id1: String
    var startTime: String?
    var endTime: String?
    var validStartTime: String
    var validEndTime: String
    var completedCount: Int
    var recentFinishedTime: String
    var isFinish: Int

    var id: String { id2 }

    init(record: RawRecord) {
        let a = record.attributes ?? [:]
        meta = RecordMeta(record)
        id2 = a.identifier("id2") ?? ""
        id1 = a.identifier("id1") ?? ""
        startTime = a.string("startTime")
        endTime = a.string("endTime")
        validStartTime = a.string("validStartTime") ?? "00:00:00"
        validEndTime = a.string("validEndTime") ?? "23:59:59"
        completedCount = a.int("completedCount") ?? 0
        recentFinishedTime = a.string("recentFinishedTime") ?? ""
        isFinish = a.int("isFinish") ?? 0
    }

    /// 与 Python `occurrence_view` 一致：已完成优先，其次 `completedCount < 0` 视为放弃。
    var status: OccurrenceStatus {
        if isFinish != 0 { return .completed }
        return completedCount < 0 ? .abandoned : .pending
    }

    var completedAt: String? { status == .completed && !recentFinishedTime.isEmpty ? recentFinishedTime : nil }
    var completedDate: LocalDate? { completedAt.flatMap { LocalDate(iso: String($0.prefix(10))) } }

    var startDate: LocalDate? { LocalDate(iso: startTime) }
    var endDate: LocalDate? { LocalDate(iso: endTime) }
    var startClock: LocalTime? { LocalTime(text: validStartTime) }
    var endClock: LocalTime? { LocalTime(text: validEndTime) }

    func progress(goal: TaskGoal) -> OccurrenceProgress {
        OccurrenceProgress(completedCount: completedCount, goal: goal)
    }

    /// 与日期区间 [start, end] 有交集。
    func overlaps(_ start: LocalDate, _ end: LocalDate) -> Bool {
        guard let first = startDate, let last = endDate else { return false }
        return first <= end && last >= start
    }
}

// MARK: - tomato：专注记录（6 列）

struct FocusRecord: Identifiable, Hashable, Sendable {
    var meta: RecordMeta?

    var time: String
    var date: String
    var goodCount: Int
    var badCount: Int
    var minutes: Double
    var log: String

    var id: String { time }

    init(record: RawRecord) {
        let a = record.attributes ?? [:]
        meta = RecordMeta(record)
        time = a.identifier("time") ?? ""
        date = a.string("date") ?? ""
        goodCount = a.int("goodCount") ?? 0
        badCount = a.int("badCount") ?? 0
        minutes = a.double("minutes") ?? 0
        log = a.string("log") ?? ""
    }

    var parsedLog: FocusLog { FocusLog(raw: log) }
    var localDate: LocalDate? { LocalDate(iso: date) }

    /// `time` 是开始时间的毫秒时间戳。
    var startedAt: Date? {
        guard let ms = Int64(time) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    var endedAt: Date? { startedAt?.addingTimeInterval(minutes * 60) }
}
