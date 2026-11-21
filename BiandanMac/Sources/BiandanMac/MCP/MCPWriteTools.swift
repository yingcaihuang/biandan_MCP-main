import Foundation

// MARK: - 变更记录

/// 一次 MCP 写操作累计的变化。可能跨多次业务调用（例如批量操作、写后读回），
/// 中途失败时也要把已经发生的变化带回 App 更新本地缓存。
final class MCPChangeLog: @unchecked Sendable {
    var changes = ChangeSet()
}

extension ChangeSet {
    mutating func mcpMerge(_ other: ChangeSet) {
        upserted.append(contentsOf: other.upserted)
        removed.append(contentsOf: other.removed)
    }
}

/// 写入类 MCP 工具，对应 Python `BiandanTools` 的写方法。
/// 这里不套 `run`：直接调用现有业务方法（它们各自在 `run` 里排队执行），避免重入死锁。
extension BiandanService {
    // MARK: 步骤

    /// 执行一步业务调用，成功或失败都把变化记进 log。
    func mcpStep<T>(_ log: MCPChangeLog, _ body: () async throws -> (T, ChangeSet)) async throws -> T {
        do {
            let (value, changes) = try await body()
            log.changes.mcpMerge(changes)
            return value
        } catch let failure as MCPCallFailure {
            log.changes.mcpMerge(failure.changes)
            throw failure.underlying
        } catch let failure as OperationFailure {
            log.changes.mcpMerge(failure.changes)
            // 取回原始错误（ServiceError / AuthError 等），保留附加信息。
            throw failure.source
        }
    }

    /// 只返回 ChangeSet 的业务调用。
    func mcpChange(_ log: MCPChangeLog, _ body: () async throws -> ChangeSet) async throws {
        _ = try await mcpStep(log) { (true, try await body()) }
    }

    /// 给错误加上附加字段（对应 Python ToolError 的 details）；需要重新登录时补上 action。
    static func mcpAnnotate(_ error: Error, _ details: JSONObject) -> MCPToolError {
        if let failure = error as? MCPToolError {
            return MCPToolError(failure.message, details: details.merging(failure.details) { _, new in new })
        }
        if let failure = error as? ServiceError {
            // 只取原始文字；「可能已写入」用字段表达，不拼进中文说明。
            var extra = details
            if failure.mayHaveWritten { extra["may_have_written"] = .bool(true) }
            return MCPToolError(failure.message, details: extra)
        }
        var extra = details
        if let failure = error as? OperationFailure, failure.needsSignIn {
            extra["action"] = .string(MCPDispatcher.signInAction)
        } else if let auth = error as? AuthError, auth == .reauthorizationRequired || auth == .notSignedIn {
            extra["action"] = .string(MCPDispatcher.signInAction)
        }
        return MCPToolError(error.localizedDescription, details: extra)
    }

    // MARK: 写后读回

    /// 读回任务最新版本，返回 task_view。
    func mcpTaskRead(_ taskID: String, _ log: MCPChangeLog) async throws -> JSONObject {
        try await mcpStep(log) { try await mcpRead("biandan_get_task", MCPArgs(["task_id": .string(taskID)])) }
    }

    /// 读回一次性任务和它唯一的执行实例，对应 Python reschedule_task / clear_schedule 的返回。
    func mcpTaskPair(_ taskID: String, _ log: MCPChangeLog) async throws -> JSONObject {
        try await mcpStep(log) {
            try await mcpGuarded {
                let task = try await fresh(try await require(.task, taskID))
                let rows = try await taskOccurrences(taskID)
                guard rows.count == 1 else {
                    throw MCPToolError("The task no longer has exactly one occurrence.")
                }
                let occurrence = try await fresh(rows[0])
                return ["task": .object(MCPView.task(task)),
                        "occurrence": .object(MCPView.occurrence(occurrence, task: task))]
            }
        }
    }

    func mcpOccurrenceRead(_ occurrenceID: String, _ log: MCPChangeLog) async throws -> JSONObject {
        try await mcpStep(log) {
            try await mcpRead("biandan_get_occurrence", MCPArgs(["occurrence_id": .string(occurrenceID)]))
        }
    }

    // MARK: 新建任务

    /// MCP 参数 → CreateTaskInput（batch_add_tasks 共用）。
    func mcpTaskInput(_ args: MCPArgs) throws -> CreateTaskInput {
        var input = CreateTaskInput(title: args.string("title") ?? "")
        input.remark = args.string("remark") ?? ""
        if let listID = try args.id("list_id") { input.listID = listID }
        input.important = args.bool("important") ?? false
        input.urgent = args.bool("urgent") ?? false
        input.startDate = try args.date("start_date")
        input.endDate = try args.date("end_date")
        input.startTime = try args.time("start_time")
        input.endTime = try args.time("end_time")
        input.subtasks = args.strings("subtasks") ?? []
        input.targetCount = args.int("target_count")
        input.reminderDate = try args.date("reminder_date")
        input.reminderTime = try args.time("reminder_time")
        input.repeatRule = try args.repeatRule("repeat_rule")
        input.habit = args.bool("habit") ?? false
        if let place = args.object("location") {
            let location = MCPArgs(place)
            input.location = LocationInput(name: location.string("name"), latitude: location.double("latitude"),
                                           longitude: location.double("longitude"), remind: location.bool("remind"))
        }
        input.weekStart = args.int("week_start") ?? 0
        input.chinaMakeup = args.bool("china_makeup") ?? false
        input.operationID = try args.id("operation_id")
        // 与 Python create_task 相同的组合检查，错误文字保持一致。
        if input.startDate == nil, ["end_date", "start_time", "end_time", "reminder_time", "repeat_rule"].contains(where: args.has) {
            throw MCPToolError("Provide start_date for a scheduled task or a time reminder.")
        }
        if (input.repeatRule != nil && input.endDate == nil) || (input.habit && input.repeatRule == nil) {
            throw MCPToolError("Repeating tasks require end_date; habits require a repeat rule.")
        }
        if (input.reminderDate == nil) != (input.reminderTime == nil) {
            throw MCPToolError("Provide both reminder_date and reminder_time, or neither.")
        }
        if !input.subtasks.isEmpty && input.targetCount != nil {
            throw MCPToolError("Choose either subtasks or a numeric target.")
        }
        return input
    }

    /// 对应 Python create_task。operation_id 由这一层先定好，失败时返回给客户端用于重试。
    func mcpCreateTask(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        var input = try mcpTaskInput(args)
        let operationID = input.operationID ?? BusinessID.generate(now: clock())
        input.operationID = operationID
        let request = input
        do {
            let result = try await mcpStep(log) { try await createTask(request) }
            return ["task_id": .string(result.taskID), "occurrence_id": .string(result.occurrenceID),
                    "operation_id": .string(operationID), "occurrences_created": .of(result.occurrencesCreated)]
        } catch {
            throw Self.mcpAnnotate(error, [
                "operation_id": .string(operationID),
                "recovery": .string("Re-run with the same operation_id and identical inputs after checking the record."),
            ])
        }
    }

    // MARK: 编辑任务

    func mcpUpdateTask(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        guard ["title", "remark", "important", "urgent", "collected"].contains(where: args.has) else {
            throw MCPToolError("Provide at least one field to change.")
        }
        if let title = args.string("title"), title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPToolError("A task title is required.")
        }
        try await mcpChange(log) {
            try await updateTask(taskID, title: args.string("title"), remark: args.string("remark"),
                                 important: args.bool("important"), urgent: args.bool("urgent"),
                                 collected: args.bool("collected"))
        }
        return try await mcpTaskRead(taskID, log)
    }

    func mcpMoveTask(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let listID = try args.requiredID("list_id")
        try await mcpChange(log) { try await moveTask(taskID, to: listID) }
        return try await mcpTaskRead(taskID, log)
    }

    func mcpRescheduleTask(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let start = try args.requiredDate("start_date")
        let end = try args.date("end_date")
        let startTime = try args.time("start_time")
        let endTime = try args.time("end_time")
        do {
            try await mcpChange(log) {
                try await rescheduleTask(taskID, start: start, end: end, startTime: startTime, endTime: endTime)
            }
        } catch {
            throw Self.mcpAnnotate(error, ["task_id": .string(taskID),
                                           "recovery": .string("Re-read and retry the same scheduling operation.")])
        }
        return try await mcpTaskPair(taskID, log)
    }

    func mcpClearSchedule(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        do {
            try await mcpChange(log) { try await clearSchedule(taskID) }
        } catch {
            throw Self.mcpAnnotate(error, ["task_id": .string(taskID),
                                           "recovery": .string("Retry clearing the same schedule.")])
        }
        return try await mcpTaskPair(taskID, log)
    }

    func mcpSetLocation(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let clear = args.bool("clear") ?? false
        let values = ["name", "latitude", "longitude", "remind"]
        if clear, values.contains(where: args.has) {
            throw MCPToolError("clear cannot be combined with location or reminder values.")
        }
        if !clear, !values.contains(where: args.has) {
            throw MCPToolError("Provide a location, coordinates or reminder setting.")
        }
        if args.has("latitude") != args.has("longitude") {
            throw MCPToolError("Provide latitude and longitude together.")
        }
        try await mcpChange(log) {
            try await setLocation(taskID, name: args.string("name"), latitude: args.double("latitude"),
                                  longitude: args.double("longitude"), remind: args.bool("remind"), clear: clear)
        }
        return try await mcpTaskRead(taskID, log)
    }

    func mcpSetTimeReminder(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let enabled = args.bool("enabled") ?? true
        let date = try args.date("reminder_date")
        let time = try args.time("reminder_time")
        if enabled, date == nil || time == nil {
            throw MCPToolError("Provide both reminder_date and reminder_time to enable a reminder.")
        }
        if !enabled, date != nil || time != nil {
            throw MCPToolError("Omit date and time when disabling a reminder.")
        }
        try await mcpChange(log) { try await setTimeReminder(taskID, date: date, time: time, enabled: enabled) }
        return try await mcpTaskRead(taskID, log)
    }

    func mcpEditTaskGoal(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let subtasks = args.strings("subtasks")
        let target = args.int("target_count")
        guard (subtasks == nil) != (target == nil) else {
            throw MCPToolError("Choose either subtasks or target_count.")
        }
        do {
            try await mcpChange(log) { try await editTaskGoal(taskID, subtasks: subtasks, targetCount: target) }
        } catch {
            throw Self.mcpAnnotate(error, ["task_id": .string(taskID),
                                           "recovery": .string("Retry with the same goal and task ID.")])
        }
        return try await mcpTaskRead(taskID, log)
    }

    // MARK: 删除与重复规则

    func mcpDeleteTask(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let scope = args.string("scope").flatMap(DeleteScope.init(rawValue:))
        let occurrenceID = try args.id("occurrence_id")
        let fromDate = try args.date("from_date")
        let preview = args.bool("preview") ?? false
        if (occurrenceID != nil) != (scope == .occurrence) || (fromDate != nil && scope != .futurePending) {
            throw MCPToolError("occurrence requires occurrence_id; from_date only applies to future_pending.")
        }
        let plan: DeletePlan
        do {
            plan = try await mcpStep(log) {
                try await deleteTask(taskID, scope: scope, occurrenceID: occurrenceID, fromDate: fromDate, preview: preview)
            }
        } catch {
            throw Self.mcpAnnotate(error, preview ? [:] : [
                "task_id": .string(taskID),
                "recovery": .string("Re-read the task and retry the same deletion scope."),
            ])
        }
        var result: JSONObject = [
            "task_id": .string(plan.taskID),
            "title": plan.title.map { JSONValue.string($0) } ?? .null,
            "scope": .string(plan.scope.rawValue),
            "occurrence_ids": .array(plan.occurrenceIDs.map { JSONValue.string($0) }),
            "deletes_task_definition": .bool(plan.deletesTaskDefinition),
        ]
        result[preview ? "preview" : "deleted"] = .bool(true)
        return result
    }

    func mcpUpdateRecurrence(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        guard let rule = try args.repeatRule("repeat_rule") else { throw MCPToolError("repeat_rule is required.") }
        let fromDate = try args.date("from_date")
        let start = try args.date("start_date")
        let end = try args.date("end_date")
        let startTime = try args.time("start_time")
        let endTime = try args.time("end_time")
        let habit = args.bool("habit")
        let weekStart = args.int("week_start") ?? 0
        let chinaMakeup = args.bool("china_makeup") ?? false
        let preview = args.bool("preview") ?? false
        let plan: RecurrencePlan
        do {
            plan = try await mcpStep(log) {
                try await updateRecurrence(taskID, rule: rule, fromDate: fromDate, start: start, end: end,
                                           startTime: startTime, endTime: endTime, habit: habit,
                                           weekStart: weekStart, chinaMakeup: chinaMakeup, preview: preview)
            }
        } catch {
            var details: JSONObject = [:]
            if !preview {
                details = ["task_id": .string(taskID),
                           "recovery": .string("Re-read, then retry using the same rule and from_date.")]
                if let fromDate { details["from_date"] = .string(fromDate.iso) }
            }
            throw Self.mcpAnnotate(error, details)
        }
        var result: JSONObject = [
            "task_id": .string(taskID), "from_date": .string(plan.fromDate.iso), "created": .of(plan.created),
            "rescheduled": .of(plan.rescheduled), "removed": .of(plan.removed),
            "protected_dates": .of(plan.protectedDates),
        ]
        if preview {
            result["preview"] = .bool(true)
        } else {
            result["task"] = .object(try await mcpTaskRead(taskID, log))
        }
        return result
    }

    /// 对应 Python reschedule_occurrence：循环中的当次另存为一次性任务时，额外返回 series_task_id。
    func mcpRescheduleOccurrence(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let occurrenceID = try args.requiredID("occurrence_id")
        let start = try args.requiredDate("start_date")
        let end = try args.date("end_date")
        let startTime = try args.time("start_time")
        let endTime = try args.time("end_time")
        let before = try await mcpOccurrenceRead(occurrenceID, log)
        let seriesID: String? = {
            if case .object(let task)? = before["task"] { return task["task_id"]?.stringValue }
            return nil
        }()
        do {
            _ = try await mcpStep(log) {
                try await rescheduleOccurrence(occurrenceID, start: start, end: end, startTime: startTime, endTime: endTime)
            }
        } catch {
            var details: JSONObject = ["occurrence_id": .string(occurrenceID),
                                       "recovery": .string("Retry rescheduling the same occurrence.")]
            if let seriesID { details["task_id"] = .string(seriesID) }
            throw Self.mcpAnnotate(error, details)
        }
        var result = try await mcpOccurrenceRead(occurrenceID, log)
        if case .object(let task)? = result["task"], let seriesID, task["task_id"]?.stringValue != seriesID {
            result["series_task_id"] = .string(seriesID)
        }
        return result
    }
}
