import Foundation

/// MCP 业务工具失败：保留原始错误（含附加字段），并带回已经发生的变化，便于 App 更新本地缓存。
struct MCPCallFailure: Error, LocalizedError, Sendable {
    let underlying: Error
    let changes: ChangeSet

    var errorDescription: String? { underlying.localizedDescription }
}

/// 只读 MCP 工具，对应 Python `BiandanTools` 的查询方法。
/// 整个工具放在一次 `run` 里执行，与界面的写操作排队；读回的最新记录会顺带更新本地缓存。
/// 注意：`run` 不可重入，这里的内部函数都不能调用自带 `run` 的业务方法。
extension BiandanService {
    static let mcpReadTools: Set<String> = [
        "biandan_check_connection", "biandan_list_lists", "biandan_search_tasks", "biandan_get_task",
        "biandan_list_occurrences", "biandan_get_list", "biandan_get_occurrence", "biandan_list_focus",
        "biandan_get_focus",
    ]

    /// 在一次 `run` 里执行；失败时保留原始错误，而不是只留下 OperationFailure 的文字。
    func mcpGuarded(_ body: () async throws -> JSONObject) async throws -> (JSONObject, ChangeSet) {
        var original: Error?
        do {
            return try await run {
                do {
                    return try await body()
                } catch {
                    original = error
                    throw error
                }
            }
        } catch let failure as OperationFailure {
            throw MCPCallFailure(underlying: original ?? failure, changes: failure.changes)
        }
    }

    func mcpRead(_ name: String, _ args: MCPArgs) async throws -> (JSONObject, ChangeSet) {
        try await mcpGuarded {
            switch name {
            case "biandan_check_connection":
                try await cloud.check()
                return ["connected": .bool(true)]
            case "biandan_list_lists":
                return ["items": .array(try await mcpLists().map { JSONValue.object($0) })]
            case "biandan_search_tasks":
                return try await mcpSearchTasks(args)
            case "biandan_get_task":
                let record = try await fresh(try await require(.task, try args.requiredID("task_id")))
                return MCPView.task(record)
            case "biandan_list_occurrences":
                return try await mcpListOccurrences(
                    start: args.string("start_date"), end: args.string("end_date"),
                    status: args.string("status") ?? "pending", taskID: args.string("task_id"),
                    listID: args.string("list_id"), includeUndated: args.bool("include_undated") ?? false,
                    important: args.bool("important"), urgent: args.bool("urgent"),
                    limit: args.int("limit") ?? 30, offset: args.int("offset") ?? 0,
                    query: args.string("query") ?? "", habit: args.bool("habit"),
                    repeating: args.bool("repeating"), collected: args.bool("collected"),
                    timeQuery: args.string("time_query"), includeSummary: args.bool("include_summary") ?? false)
            case "biandan_get_list":
                return try await mcpGetList(args)
            case "biandan_get_occurrence":
                return try await mcpOccurrencePair(try args.requiredID("occurrence_id"))
            case "biandan_list_focus":
                return try await mcpListFocus(args)
            case "biandan_get_focus":
                let record = try await fresh(try await require(.tomato, try args.requiredID("focus_id")))
                return Self.mcpFocusView(record)
            default:
                throw MCPToolError("Unknown Biandan tool.")
            }
        }
    }

    // MARK: 待办单

    /// 对应 Python `list_lists`：没有默认分类时补上「未分类」，按 (sort_index, list_id) 排序。
    func mcpLists() async throws -> [JSONObject] {
        var lists = try await listAll(.favorites).map(MCPView.list)
        if !lists.contains(where: { $0["list_id"] == .string(TodoList.defaultID) }) {
            lists.append(["list_id": .string(TodoList.defaultID), "name": .string("未分类"),
                          "color": .of(0), "sort_index": .of(0)])
        }
        func key(_ item: JSONObject) -> (Int, Int64) {
            (item["sort_index"]?.intValue ?? 0, Int64(item["list_id"]?.stringValue ?? "") ?? 0)
        }
        return lists.sorted { key($0) < key($1) }
    }

    func mcpGetList(_ args: MCPArgs) async throws -> JSONObject {
        let listID = try args.requiredID("list_id")
        guard var item = try await mcpLists().first(where: { $0["list_id"] == .string(listID) }) else {
            throw MCPToolError("No list found with ID \(listID).")
        }
        if args.bool("include_pending") == true {
            item["pending_occurrences"] = .object(try await mcpListOccurrences(
                start: "1900-01-31", end: "2100-12-31", status: "pending", taskID: nil, listID: listID,
                includeUndated: true, important: nil, urgent: nil,
                limit: args.int("limit") ?? 30, offset: args.int("offset") ?? 0, query: "",
                habit: nil, repeating: nil, collected: nil, timeQuery: nil, includeSummary: false))
        }
        return item
    }

    // MARK: 任务

    private static func mcpFlag(_ item: JSONObject, _ key: String) -> Bool {
        item[key] == .bool(true)
    }

    private static func mcpText(_ item: JSONObject, _ key: String) -> String {
        item[key]?.stringValue ?? ""
    }

    private static func mcpMismatch(_ wanted: Bool?, _ actual: Bool) -> Bool {
        wanted != nil && wanted != actual
    }

    /// 标题、备注、子任务里是否包含关键词（needle 已折叠）。
    private static func mcpContains(_ item: JSONObject, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let subtasks = (item["subtasks"].flatMap { value -> [JSONValue]? in
            if case .array(let values) = value { return values }
            return nil
        } ?? []).compactMap(\.stringValue)
        let texts = [mcpText(item, "title"), mcpText(item, "remark")] + subtasks
        return texts.contains { MCPView.folded($0).contains(needle) }
    }

    /// 对应 Python `search_tasks`：未完成的在前，同组内任务 ID 大的在前。
    func mcpSearchTasks(_ args: MCPArgs) async throws -> JSONObject {
        let listID = try args.id("list_id")
        let needle = MCPView.folded((args.string("query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        var items: [JSONObject] = []
        for record in try await listAll(.task) {
            let item = MCPView.task(record)
            if let listID, item["list_id"] != .string(listID) { continue }
            if Self.mcpMismatch(args.bool("important"), Self.mcpFlag(item, "important"))
                || Self.mcpMismatch(args.bool("urgent"), Self.mcpFlag(item, "urgent"))
                || Self.mcpMismatch(args.bool("habit"), Self.mcpFlag(item, "is_habit"))
                || Self.mcpMismatch(args.bool("repeating"), (item["repeat_type"]?.intValue ?? 0) != 0)
                || Self.mcpMismatch(args.bool("completed"), Self.mcpFlag(item, "completed"))
                || Self.mcpMismatch(args.bool("collected"), Self.mcpFlag(item, "collected")) {
                continue
            }
            if Self.mcpContains(item, needle) { items.append(item) }
        }
        func key(_ item: JSONObject) -> (Int, Int64) {
            (Self.mcpFlag(item, "completed") ? 1 : 0, -(Int64(Self.mcpText(item, "task_id")) ?? 0))
        }
        items.sort { key($0) < key($1) }
        return try MCPView.page(items, limit: args.int("limit") ?? 30, offset: args.int("offset") ?? 0)
    }

    // MARK: 执行实例

    /// 对应 Python `get_occurrence`：返回实例和所属任务（都读最新版本）。
    func mcpOccurrencePair(_ occurrenceID: String) async throws -> JSONObject {
        let instance = try await fresh(try await require(.showTask, occurrenceID))
        guard let taskID = instance.attributes?.identifier("id1") else {
            throw MCPToolError("The occurrence does not reference a task.")
        }
        let task = try await fresh(try await require(.task, taskID))
        return ["task": .object(MCPView.task(task)), "occurrence": .object(MCPView.occurrence(instance, task: task))]
    }

    /// 本地时间 `YYYY-MM-DD HH:MM:SS`，对应 Python `isoformat(sep=" ", timespec="seconds")`。
    private static func mcpStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 对应 Python `list_occurrences`。
    func mcpListOccurrences(start startText: String?, end endText: String?, status: String, taskID: String?,
                            listID: String?, includeUndated: Bool, important: Bool?, urgent: Bool?,
                            limit: Int, offset: Int, query: String, habit: Bool?, repeating: Bool?,
                            collected: Bool?, timeQuery: String?, includeSummary: Bool) async throws -> JSONObject {
        guard ["pending", "completed", "abandoned", "all"].contains(status) else {
            throw MCPToolError("Unsupported occurrence status.")
        }
        let now = clock()
        var startText = startText
        var endText = endText
        var window: (first: String, last: String)?
        if let timeQuery {
            guard startText == nil, endText == nil else {
                throw MCPToolError("Use either time_query or explicit dates.")
            }
            let offsets: [String: (Int, Int)] = ["today": (0, 0), "tomorrow": (1, 1),
                                                 "last7day": (-6, 0), "next7day": (0, 6)]
            if let pair = offsets[timeQuery] {
                let calendar = Calendar.current
                let first = calendar.date(byAdding: .day, value: pair.0, to: now) ?? now
                let last = calendar.date(byAdding: .day, value: pair.1, to: now) ?? now
                startText = LocalDate.today(first).iso
                endText = LocalDate.today(last).iso
            } else {
                // last24hour / next24hour：按具体时刻筛选（Python timedelta(days=1) 即 24 小时）。
                let span: (Double, Double) = timeQuery == "last24hour" ? (-1, 0) : (0, 1)
                let first = now.addingTimeInterval(span.0 * 86_400)
                let last = now.addingTimeInterval(span.1 * 86_400)
                window = (Self.mcpStamp(first), Self.mcpStamp(last))
                startText = LocalDate.today(first).iso
                endText = LocalDate.today(last).iso
            }
        }
        let start = try startText.map(MCPArgs.calendarDate)?.iso ?? LocalDate.today(now).iso
        let end = try endText.map(MCPArgs.calendarDate)?.iso ?? start
        guard end >= start else { throw MCPToolError("end_date cannot be earlier than start_date.") }
        if let taskID { _ = try MCPArgs.businessID(taskID) }
        if let listID { _ = try MCPArgs.businessID(listID) }

        var tasks: [String: (record: RawRecord, view: JSONObject)] = [:]
        for record in try await listAll(.task) {
            let view = MCPView.task(record)
            let identifier = Self.mcpText(view, "task_id")
            if tasks[identifier] != nil { throw MCPToolError("Multiple tasks share ID \(identifier).") }
            tasks[identifier] = (record, view)
        }
        let needle = MCPView.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var items: [JSONObject] = []
        for occurrence in try await listAll(.showTask) {
            let identifier = occurrence.attributes?.identifier("id1") ?? ""
            guard let entry = tasks[identifier], taskID == nil || identifier == taskID else { continue }
            let summary = entry.view
            if let listID, summary["list_id"] != .string(listID) { continue }
            if Self.mcpMismatch(important, Self.mcpFlag(summary, "important"))
                || Self.mcpMismatch(urgent, Self.mcpFlag(summary, "urgent"))
                || Self.mcpMismatch(habit, Self.mcpFlag(summary, "is_habit"))
                || Self.mcpMismatch(repeating, (summary["repeat_type"]?.intValue ?? 0) != 0)
                || Self.mcpMismatch(collected, Self.mcpFlag(summary, "collected")) {
                continue
            }
            guard Self.mcpContains(summary, needle) else { continue }
            var item = MCPView.occurrence(occurrence, task: entry.record)
            let state = Self.mcpText(item, "status")
            if status != "all" && state != status { continue }
            let undated = Self.mcpFlag(summary, "undated")
            var matches: Bool
            if status == "completed" {
                let day = String(Self.mcpText(item, "completed_at").prefix(10))
                matches = start <= day && day <= end
            } else if undated {
                matches = includeUndated
            } else {
                matches = Self.mcpText(item, "start_date") <= end && Self.mcpText(item, "end_date") >= start
            }
            if matches, let window, status == "completed" || !undated {
                let first: String
                let last: String
                if status == "completed" {
                    first = Self.mcpText(item, "completed_at")
                    last = first
                } else {
                    let startClock = Self.mcpText(item, "start_time")
                    let endClock = Self.mcpText(item, "end_time")
                    first = Self.mcpText(item, "start_date") + " " + (startClock.isEmpty ? "00:00:00" : startClock)
                    last = Self.mcpText(item, "end_date") + " " + (endClock.isEmpty ? "23:59:59" : endClock)
                }
                matches = first <= window.last && last >= window.first
            }
            if matches {
                item["title"] = summary["title"] ?? .null
                item["list_id"] = summary["list_id"] ?? .null
                items.append(item)
            }
        }
        let sortField = status == "completed" ? "completed_at" : "start_date"
        func key(_ item: JSONObject) -> (String, String, String) {
            (Self.mcpText(item, sortField), Self.mcpText(item, "start_time"), Self.mcpText(item, "occurrence_id"))
        }
        items.sort { key($0) < key($1) }
        var result = try MCPView.page(items, limit: limit, offset: offset)
        if includeSummary {
            var counts: JSONObject = [:]
            for state in ["pending", "completed", "abandoned"] {
                counts[state] = .of(items.filter { Self.mcpText($0, "status") == state }.count)
            }
            result["summary"] = .object(counts)
        }
        return result
    }

    // MARK: 专注记录

    /// 对应 Python `focus_view`。
    static func mcpFocusView(_ record: RawRecord) -> JSONObject {
        let a = record.attributes ?? [:]
        let log = JSONValue.parseObject(a.string("log") ?? "") ?? [:]
        let identifier = a.identifier("time") ?? ""
        let started = Date(timeIntervalSince1970: Double(Int64(identifier) ?? 0) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return [
            "focus_id": .string(identifier),
            "date": a["date"] ?? .null,
            "minutes": a["minutes"] ?? .of(0),
            "good_count": a["goodCount"] ?? .of(0),
            "bad_count": a["badCount"] ?? .of(0),
            "title": log["eventTitle"] ?? .string(""),
            "occurrence_id": mcpLinkedOccurrence(log["eventId"]),
            "started_at": .string(formatter.string(from: started)),
        ]
    }

    /// Python：`str(linked) if linked and linked != -1 else None`。
    private static func mcpLinkedOccurrence(_ value: JSONValue?) -> JSONValue {
        guard let value, value.isTruthy else { return .null }
        switch value {
        case .int(let number):
            return number == -1 ? .null : .string(String(number))
        case .double(let number):
            return number == -1 ? .null : .string(value.identifierString ?? String(number))
        case .string(let text):
            return .string(text)
        default:
            return .null
        }
    }

    /// Python `sum(...)`：全是整数时返回整数，否则返回小数。
    private static func mcpSum(_ values: [JSONValue]) -> JSONValue {
        var allIntegers = true
        var integerTotal: Int64 = 0
        var total = 0.0
        for value in values {
            switch value {
            case .int(let number):
                integerTotal += number
                total += Double(number)
            case .double(let number):
                allIntegers = false
                total += number
            default:
                break
            }
        }
        return allIntegers ? .int(integerTotal) : .double(total)
    }

    /// 对应 Python `list_focus`：按开始时刻倒序。
    func mcpListFocus(_ args: MCPArgs) async throws -> JSONObject {
        let occurrenceID = try args.id("occurrence_id")
        let start = try args.date("start_date")?.iso
        let end = try args.date("end_date")?.iso
        if let start, let end, end < start {
            throw MCPToolError("end_date cannot precede start_date.")
        }
        var results: [JSONObject] = []
        for record in try await listAll(.tomato) {
            let item = Self.mcpFocusView(record)
            if let occurrenceID, item["occurrence_id"] != .string(occurrenceID) { continue }
            let day = Self.mcpText(item, "date")
            if let start, day < start { continue }
            if let end, day > end { continue }
            results.append(item)
        }
        results.sort { (Int64(Self.mcpText($0, "focus_id")) ?? 0) > (Int64(Self.mcpText($1, "focus_id")) ?? 0) }
        var page = try MCPView.page(results, limit: args.int("limit") ?? 30, offset: args.int("offset") ?? 0)
        if args.bool("include_summary") == true {
            var summary: JSONObject = [:]
            for key in ["minutes", "good_count", "bad_count"] {
                summary[key] = Self.mcpSum(results.map { $0[key] ?? .null })
            }
            page["summary"] = .object(summary)
        }
        return page
    }
}
