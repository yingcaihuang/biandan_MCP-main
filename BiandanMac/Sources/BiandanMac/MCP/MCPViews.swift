import Foundation

// MARK: - 参数读取

/// MCP 工具参数。类型已按 schema 校验，这里只做业务格式检查
/// （对应 Python `calendar_date` / `clock_time` / `business_id`），错误文字与 Python 版一致。
struct MCPArgs: Sendable {
    let raw: JSONObject

    init(_ raw: JSONObject) {
        self.raw = raw
    }

    func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return value != .null
    }

    func string(_ key: String) -> String? {
        if case .string(let value)? = raw[key] { return value }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = raw[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let value)? = raw[key] { return Int(exactly: value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        switch raw[key] {
        case .int(let value)?: return Double(value)
        case .double(let value)?: return value
        default: return nil
        }
    }

    func strings(_ key: String) -> [String]? {
        guard case .array(let values)? = raw[key] else { return nil }
        return values.compactMap { value in
            if case .string(let text) = value { return text }
            return nil
        }
    }

    func object(_ key: String) -> JSONObject? {
        if case .object(let value)? = raw[key] { return value }
        return nil
    }

    func objects(_ key: String) -> [JSONObject]? {
        guard case .array(let values)? = raw[key] else { return nil }
        return values.compactMap { value in
            if case .object(let object) = value { return object }
            return nil
        }
    }

    func date(_ key: String) throws -> LocalDate? {
        try string(key).map(Self.calendarDate)
    }

    func time(_ key: String) throws -> LocalTime? {
        try string(key).map(Self.clockTime)
    }

    func id(_ key: String) throws -> String? {
        try string(key).map(Self.businessID)
    }

    func requiredID(_ key: String) throws -> String {
        guard let value = try id(key) else { throw MCPToolError("\(key) is required.") }
        return value
    }

    func requiredDate(_ key: String) throws -> LocalDate {
        guard let value = try date(key) else { throw MCPToolError("\(key) is required.") }
        return value
    }

    func repeatRule(_ key: String) throws -> RepeatRule? {
        try object(key).map(Self.repeatRule)
    }

    // MARK: 格式检查

    /// 对应 Python `calendar_date`：必须是合法的 YYYY-MM-DD，且写法规范。
    static func calendarDate(_ text: String) throws -> LocalDate {
        guard text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil,
              let date = LocalDate(iso: text), date.iso == text else {
            throw MCPToolError("Use a date in YYYY-MM-DD format.")
        }
        return date
    }

    /// 对应 Python `clock_time`：只接受 HH:MM。
    static func clockTime(_ text: String) throws -> LocalTime {
        guard text.range(of: #"\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z"#, options: .regularExpression) != nil,
              let time = LocalTime(text: text) else {
            throw MCPToolError("Use a local time in HH:MM format.")
        }
        return time
    }

    /// 对应 Python `business_id`。
    static func businessID(_ text: String) throws -> String {
        guard BusinessID.isValid(text) else {
            throw MCPToolError("Use the positive numeric business ID returned by a Biandan tool.")
        }
        return text
    }

    /// 把 MCP 的 `repeat_rule` 转成 RepeatRule；具体取值范围由 `RepeatRule.encode()` 检查（对应 Python `encode_rule`）。
    static func repeatRule(_ object: JSONObject) throws -> RepeatRule {
        let args = MCPArgs(object)
        guard let modeName = args.string("mode"),
              let mode = LoopSet.allCases.first(where: { $0 != LoopSet.none && $0.modeName == modeName }) else {
            throw MCPToolError("Unsupported repeat mode.")
        }
        var unit: LoopUnitKind?
        if let name = args.string("unit") {
            guard let value = LoopUnitKind.allCases.first(where: { $0.modeName == name }) else {
                throw MCPToolError("Invalid repeat unit, interval, day filter or duration.")
            }
            unit = value
        }
        var filter: DayFilter?
        if let name = args.string("day_filter") {
            guard let value = DayFilter.allCases.first(where: { $0.modeName == name }) else {
                throw MCPToolError("Invalid repeat unit, interval, day filter or duration.")
            }
            filter = value
        }
        let rule = RepeatRule(mode: mode, unit: unit, interval: args.int("interval"), dates: args.strings("dates"),
                              dayFilter: filter, durationDays: args.int("duration_days"))
        do {
            _ = try rule.encode()
        } catch {
            throw MCPToolError(error.localizedDescription)
        }
        return rule
    }
}

// MARK: - 返回格式

/// 工具的返回格式，字段与 Python `task_view` / `occurrence_view` / `page_result` 一致。
/// 日期、时刻等字段原样透传云端值（包括 null），与 Python `row.get(...)` 相同。
enum MCPView {
    /// Python `row.get("unitTimeNumber") or 1`。
    static func target(_ attributes: JSONObject) -> Int {
        let value = attributes.int("unitTimeNumber") ?? 0
        return value == 0 ? 1 : value
    }

    /// 子任务目标按位计数，普通目标直接返回次数。
    static func count(_ target: Int) -> Int {
        target >= 100 ? (target / 100).nonzeroBitCount : target
    }

    private static func value(_ attributes: JSONObject, _ key: String) -> JSONValue {
        attributes[key] ?? .null
    }

    private static func split(_ value: Int) -> (quotient: Int, remainder: Int) {
        let remainder = ((value % 100) + 100) % 100
        return ((value - remainder) / 100, remainder)
    }

    /// 对应 Python `view_rule`。
    static func rule(_ attributes: JSONObject) -> JSONValue {
        let mode = attributes.int("loopSet") ?? 0
        guard mode != 0 else { return .null }
        let name = LoopSet(rawValue: mode).map(\.modeName) ?? "unknown"
        let duration = attributes.int("duration") ?? 0
        var data: JSONObject = ["mode": .string(name), "duration_days": .of(duration == 0 ? 1 : duration)]
        if name == "custom" {
            let (selector, unit) = split(attributes.int("loopUnit") ?? 0)
            let interval = attributes.int("loopBaseNumber") ?? 0
            let dates = (attributes.string("loopDate") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
            data["unit"] = .string(LoopUnitKind(rawValue: unit).map(\.modeName) ?? "unknown")
            data["day_filter"] = .string(DayFilter(rawValue: selector).map(\.modeName) ?? "unknown")
            data["interval"] = .of(interval == 0 ? 1 : interval)
            data["dates"] = .array(dates.map { JSONValue.string($0) })
        }
        return .object(data)
    }

    /// 对应 Python `task_view`。
    static func task(_ record: RawRecord) -> JSONObject {
        let a = record.attributes ?? [:]
        let content = TaskContent.decode(a.string("taskContent") ?? "")
        let flags = a.int("isRemind") ?? 0
        let listID = a.truthy("id3") ? (a.identifier("id3") ?? TodoList.defaultID) : TodoList.defaultID
        let latitude = value(a, "latitude")
        let longitude = value(a, "longitude")
        let hasCoordinate = latitude != .null && longitude != .null
            && !(latitude.doubleValue == -1 && longitude.doubleValue == -1)
        let place = a.string("location") ?? ""
        let showsLocation = !place.isEmpty || hasCoordinate || flags & 2 != 0
        return [
            "task_id": .string(a.identifier("id1") ?? ""),
            "title": value(a, "taskTitle"),
            "remark": .string(content.remark),
            "subtasks": .array(content.subtasks.map { JSONValue.string($0) }),
            "target_count": .of(count(target(a))),
            "list_id": .string(listID),
            "important": .bool(a.truthy("isImportant")),
            "urgent": .bool(a.truthy("isUrgency")),
            "collected": .bool(a.truthy("isCollectible")),
            "repeat_type": .of(a.int("loopSet") ?? 0),
            "recurrence": rule(a),
            "is_habit": .bool((a.int("isLoop") ?? 0) >= 2),
            "undated": .bool(a.truthy("haveNoTime")),
            "start_date": value(a, "startTime"),
            "end_date": value(a, "endTime"),
            "start_time": value(a, "validStartTime"),
            "end_time": value(a, "validEndTime"),
            "completed": .bool(a.truthy("isFinish")),
            "time_reminder": flags & 1 != 0
                ? .object(["date": value(a, "remindDate"), "time": value(a, "remindTime")]) : .null,
            "has_location_reminder": .bool(flags & 2 != 0),
            "location": showsLocation
                ? .object(["name": .string(place), "latitude": latitude, "longitude": longitude,
                           "coordinate_system": .string("GCJ-02")]) : .null,
        ]
    }

    /// 对应 Python `occurrence_view`。
    static func occurrence(_ record: RawRecord, task: RawRecord) -> JSONObject {
        let a = record.attributes ?? [:]
        let progress = a.int("completedCount") ?? 0
        let goal = target(task.attributes ?? [:])
        let finished = a.truthy("isFinish")
        let positive = max(progress, 0)
        let bits = positive / 100
        let status = finished ? "completed" : (progress < 0 ? "abandoned" : "pending")
        let indices = goal >= 100 ? (0..<20).filter { bits & (1 << $0) != 0 } : []
        return [
            "occurrence_id": .string(a.identifier("id2") ?? ""),
            "task_id": .string(a.identifier("id1") ?? ""),
            "start_date": value(a, "startTime"),
            "end_date": value(a, "endTime"),
            "start_time": value(a, "validStartTime"),
            "end_time": value(a, "validEndTime"),
            "status": .string(status),
            "completed_at": finished ? value(a, "recentFinishedTime") : .null,
            "completed_count": .of(goal >= 100 ? bits.nonzeroBitCount : positive),
            "target_count": .of(count(goal)),
            "completed_subtask_indices": .array(indices.map { JSONValue.of($0) }),
        ]
    }

    /// 对应 Python `list_lists` 里的单个待办单。
    static func list(_ record: RawRecord) -> JSONObject {
        let a = record.attributes ?? [:]
        let (sort, color) = split(a.int("favoritesColor") ?? 0)
        return [
            "list_id": .string(a.identifier("id3") ?? ""),
            "name": value(a, "favoritesName"),
            "color": .of(color),
            "sort_index": .of(sort),
        ]
    }

    /// 对应 Python `page_result`。
    static func page(_ items: [JSONObject], limit: Int, offset: Int) throws -> JSONObject {
        guard (1...100).contains(limit), offset >= 0 else {
            throw MCPToolError("limit must be 1–100 and offset cannot be negative.")
        }
        let end = offset + limit
        let slice = offset < items.count ? Array(items[offset..<min(end, items.count)]) : []
        return [
            "items": .array(slice.map { JSONValue.object($0) }),
            "total": .of(items.count),
            "next_offset": end < items.count ? .of(end) : .null,
        ]
    }

    /// 写操作读回的最新记录（BiandanService 写后读回时会放进 ChangeSet）。
    static func latest(_ kind: RecordKind, _ identifier: String, in changes: ChangeSet) -> RawRecord? {
        changes.upserted.last { $0.kind == kind && $0.businessID == identifier }
    }

    /// 字符串字段按 Python `str.casefold()` 的近似做法比较（大小写与全半角宽度不敏感）。
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
