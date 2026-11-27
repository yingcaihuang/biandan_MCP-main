import Foundation

/// 写入类 MCP 工具（第二部分）：进度、待办单、专注记录、批量操作，以及工具路由。
/// 与第一部分相同：不套 `run`，直接调用自带 `run` 的业务方法，避免重入死锁。
extension BiandanService {
    // MARK: 路由

    /// 执行一个业务工具（help、local_today 之外）。失败时抛出 MCPCallFailure，带回已发生的变化。
    func mcpExecute(_ name: String, _ raw: JSONObject) async throws -> (JSONObject, ChangeSet) {
        let args = MCPArgs(raw)
        if Self.mcpReadTools.contains(name) {
            return try await mcpRead(name, args)
        }
        let log = MCPChangeLog()
        do {
            let value = try await mcpWrite(name, args, log)
            return (value, log.changes)
        } catch {
            throw MCPCallFailure(underlying: error, changes: log.changes)
        }
    }

    func mcpWrite(_ name: String, _ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        switch name {
        case "biandan_create_task": return try await mcpCreateTask(args, log)
        case "biandan_update_task": return try await mcpUpdateTask(args, log)
        case "biandan_move_task": return try await mcpMoveTask(args, log)
        case "biandan_reschedule_task": return try await mcpRescheduleTask(args, log)
        case "biandan_clear_schedule": return try await mcpClearSchedule(args, log)
        case "biandan_set_location": return try await mcpSetLocation(args, log)
        case "biandan_set_time_reminder": return try await mcpSetTimeReminder(args, log)
        case "biandan_edit_task_goal": return try await mcpEditTaskGoal(args, log)
        case "biandan_delete_task": return try await mcpDeleteTask(args, log)
        case "biandan_update_recurrence": return try await mcpUpdateRecurrence(args, log)
        case "biandan_reschedule_occurrence": return try await mcpRescheduleOccurrence(args, log)
        case "biandan_complete_occurrence": return try await mcpCompleteOccurrence(args, log)
        case "biandan_complete_subtask": return try await mcpCompleteSubtask(args, log)
        case "biandan_change_progress": return try await mcpChangeProgress(args, log)
        case "biandan_create_list": return try await mcpCreateList(args, log)
        case "biandan_update_list": return try await mcpUpdateList(args, log)
        case "biandan_delete_list": return try await mcpDeleteList(args, log)
        case "biandan_create_focus": return try await mcpCreateFocus(args, log)
        case "biandan_update_focus": return try await mcpUpdateFocus(args, log)
        case "biandan_delete_focus": return try await mcpDeleteFocus(args, log)
        case "biandan_batch_add_tasks":
            return await mcpBatch(args.objects("tasks") ?? []) { try await self.mcpCreateTask($0, log) }
        case "biandan_batch_update_tasks":
            return await mcpBatch(args.objects("tasks") ?? []) { try await self.mcpBatchUpdate($0, log) }
        case "biandan_batch_complete_occurrences":
            let items = (args.strings("occurrence_ids") ?? []).map { ["occurrence_id": JSONValue.string($0)] }
            return await mcpBatch(items) { try await self.mcpCompleteOccurrence($0, log) }
        case "biandan_batch_delete_tasks":
            return try await mcpBatchDelete(args, log)
        default:
            throw MCPToolError("Unknown Biandan tool.")
        }
    }

    // MARK: 进度

    /// 对应 Python update_progress 里 completed_at 的格式检查（YYYY-MM-DDTHH:MM）。
    static func mcpCompletedAt(_ text: String?) throws -> (LocalDate, LocalTime)? {
        guard let text else { return nil }
        guard text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}\z"#, options: .regularExpression) != nil else {
            throw MCPToolError("Use a local completion time in YYYY-MM-DDTHH:MM format.")
        }
        return (try MCPArgs.calendarDate(String(text.prefix(10))), try MCPArgs.clockTime(String(text.suffix(5))))
    }

    /// 执行一次进度修改，读回实例，返回 {occurrence, task_completed}。
    private func mcpProgress(_ occurrenceID: String, _ log: MCPChangeLog,
                             _ body: () async throws -> (Bool, ChangeSet)) async throws -> JSONObject {
        let summary: Bool
        do {
            summary = try await mcpStep(log, body)
        } catch {
            throw Self.mcpAnnotate(error, [
                "occurrence_id": .string(occurrenceID),
                "recovery": .string("Re-read and retry the same completion to reconcile the summary."),
            ])
        }
        let pair = try await mcpOccurrenceRead(occurrenceID, log)
        return ["occurrence": pair["occurrence"] ?? .null, "task_completed": .bool(summary)]
    }

    func mcpCompleteOccurrence(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let occurrenceID = try args.requiredID("occurrence_id")
        let completedAt = try Self.mcpCompletedAt(args.string("completed_at"))
        return try await mcpProgress(occurrenceID, log) {
            try await completeOccurrence(occurrenceID, completedAt: completedAt)
        }
    }

    func mcpCompleteSubtask(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let occurrenceID = try args.requiredID("occurrence_id")
        let index = args.int("subtask_index") ?? -1
        return try await mcpProgress(occurrenceID, log) {
            try await setSubtask(occurrenceID, index: index, checked: true)
        }
    }

    func mcpChangeProgress(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let occurrenceID = try args.requiredID("occurrence_id")
        let action = args.string("action") ?? ""
        let index = args.int("subtask_index")
        let count = args.int("count")
        if (index != nil) != (action == "uncheck_subtask") || (count != nil) != (action == "set_count") {
            throw MCPToolError("Supply subtask_index for uncheck_subtask or count for set_count.")
        }
        if args.has("completed_at") && action != "set_count" {
            throw MCPToolError("completed_at applies to set_count or complete_occurrence.")
        }
        let completedAt = try Self.mcpCompletedAt(args.string("completed_at"))
        if action == "uncheck_subtask", let index {
            return try await mcpProgress(occurrenceID, log) {
                try await setSubtask(occurrenceID, index: index, checked: false)
            }
        }
        let mapped: ProgressAction
        switch action {
        case "reopen": mapped = .reopen
        case "abandon": mapped = .abandon
        case "restore": mapped = .restore
        case "set_count": mapped = .setCount
        default: throw MCPToolError("action has an invalid value.")
        }
        return try await mcpProgress(occurrenceID, log) {
            try await changeProgress(occurrenceID, action: mapped, count: count, completedAt: completedAt)
        }
    }

    // MARK: 待办单

    func mcpListRead(_ listID: String, _ log: MCPChangeLog) async throws -> JSONObject {
        try await mcpStep(log) { try await mcpRead("biandan_get_list", MCPArgs(["list_id": .string(listID)])) }
    }

    func mcpCreateList(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let name = args.string("name") ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError("A list name is required.")
        }
        let operationID = try args.id("operation_id") ?? BusinessID.generate(now: clock())
        guard operationID != TodoList.defaultID else { throw MCPToolError("List ID 1 is reserved.") }
        let color = args.int("color") ?? 0
        let sortIndex = args.int("sort_index")
        do {
            _ = try await mcpStep(log) {
                try await createList(name: name, colorIndex: color, sortIndex: sortIndex, operationID: operationID)
            }
        } catch {
            throw Self.mcpAnnotate(error, ["operation_id": .string(operationID),
                                           "recovery": .string("Retry with the same operation_id and inputs.")])
        }
        var result = try await mcpListRead(operationID, log)
        result["operation_id"] = .string(operationID)
        return result
    }

    func mcpUpdateList(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let listID = try args.requiredID("list_id")
        guard listID != TodoList.defaultID else { throw MCPToolError("The default list cannot be edited.") }
        guard ["name", "color", "sort_index"].contains(where: args.has) else {
            throw MCPToolError("Provide a list field to change.")
        }
        if let name = args.string("name"), name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPToolError("A list name is required.")
        }
        try await mcpChange(log) {
            try await updateList(listID, name: args.string("name"), colorIndex: args.int("color"),
                                 sortIndex: args.int("sort_index"))
        }
        return try await mcpListRead(listID, log)
    }

    /// 对应 Python delete_list。业务服务不支持预览，这里先算出受影响的任务。
    func mcpDeleteList(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let listID = try args.requiredID("list_id")
        let mode = args.string("tasks") ?? "move_to_default"
        let preview = args.bool("preview") ?? false
        guard listID != TodoList.defaultID else { throw MCPToolError("The default list cannot be deleted.") }
        var result: JSONObject = try await mcpStep(log) {
            try await mcpGuarded {
                let matches = try await listAll(.task).filter { $0.attributes?.identifier("id3") == listID }
                let affected = matches.map { row -> JSONValue in
                    JSONValue.object(["task_id": .string(row.attributes?.identifier("id1") ?? ""),
                                      "title": row.attributes?["taskTitle"] ?? .null])
                }
                return ["list_id": .string(listID), "task_action": .string(mode), "affected_tasks": .array(affected)]
            }
        }
        if preview {
            result["preview"] = .bool(true)
            return result
        }
        do {
            try await mcpChange(log) { try await deleteList(listID, deleteTasks: mode == "delete_tasks") }
        } catch {
            throw Self.mcpAnnotate(error, ["list_id": .string(listID), "may_have_written": .bool(true),
                                           "recovery": .string("Re-read this list and retry the same action.")])
        }
        result["deleted"] = .bool(true)
        return result
    }

    // MARK: 专注记录

    /// 对应 Python create_focus 的 started_at：本机时间 YYYY-MM-DDTHH:MM，可带秒。
    static func mcpStartedAt(_ text: String) throws -> Date {
        let pattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\z"#
        guard text.range(of: pattern, options: .regularExpression) != nil else {
            throw MCPToolError("Use a local start time in YYYY-MM-DDTHH:MM format.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = text.count == 16 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw MCPToolError("Invalid local focus start time.")
        }
        return date
    }

    func mcpFocusRead(_ focusID: String, _ log: MCPChangeLog) async throws -> JSONObject {
        try await mcpStep(log) { try await mcpRead("biandan_get_focus", MCPArgs(["focus_id": .string(focusID)])) }
    }

    func mcpCreateFocus(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let started = try Self.mcpStartedAt(args.string("started_at") ?? "")
        let minutes = args.double("minutes") ?? 0
        guard FocusCodec.validMinutes(minutes) != nil else {
            throw MCPToolError("Focus duration must be between 1 and 1440 minutes.")
        }
        var link: FocusLink?
        if let occurrenceID = try args.id("occurrence_id") {
            let pair = try await mcpOccurrenceRead(occurrenceID, log)
            guard case .object(let task)? = pair["task"] else {
                throw MCPToolError("The occurrence does not reference a task.")
            }
            link = FocusLink(occurrenceID: occurrenceID, listID: Int(task["list_id"]?.stringValue ?? "") ?? 1,
                             title: task["title"]?.stringValue ?? "")
        }
        let input = FocusInput(startedAt: started, minutes: minutes, title: args.string("title") ?? "",
                               goodCount: args.int("good_count") ?? 0, badCount: args.int("bad_count") ?? 0,
                               link: link)
        let focusID = try await mcpStep(log) { try await createFocus(input) }
        return try await mcpFocusRead(focusID, log)
    }

    func mcpUpdateFocus(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let focusID = try args.requiredID("focus_id")
        guard ["title", "good_count", "bad_count"].contains(where: args.has) else {
            throw MCPToolError("Provide a field to change.")
        }
        try await mcpChange(log) {
            try await updateFocus(focusID, title: args.string("title"), goodCount: args.int("good_count"),
                                  badCount: args.int("bad_count"))
        }
        return try await mcpFocusRead(focusID, log)
    }

    func mcpDeleteFocus(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let focusID = try args.requiredID("focus_id")
        try await mcpChange(log) { try await deleteFocus(focusID) }
        return ["focus_id": .string(focusID), "deleted": .bool(true)]
    }

    // MARK: 批量

    /// 对应 Python 0.4.6 batch_delete_tasks：默认只预览（不写入）。确认删除时参数不对的项单独报错，
    /// 其余整批交给服务层批量删除（实例表只拉一次、有限并发），结果按输入顺序逐项返回。
    func mcpBatchDelete(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let items = args.objects("tasks") ?? []
        guard !items.isEmpty else { throw MCPToolError("Provide at least one delete target in tasks.") }
        let preview = args.bool("preview") ?? true
        if preview {
            let previews = items.map { item -> JSONObject in
                var copy = item
                copy["preview"] = .bool(true)
                return copy
            }
            var result = await mcpBatch(previews) { try await self.mcpDeleteTask($0, log) }
            result["preview"] = .bool(true)
            return result
        }
        var slots = [JSONValue?](repeating: nil, count: items.count)
        var targets: [BatchDeleteTarget] = []
        var positions: [Int] = []
        for (index, item) in items.enumerated() {
            do {
                targets.append(try Self.mcpDeleteTarget(MCPArgs(item)))
                positions.append(index)
            } catch {
                var failure = MCPDispatcher.failure(error)
                failure["ok"] = .bool(false)
                slots[index] = .object(failure)
            }
        }
        if !targets.isEmpty {
            let outcomes: [BatchDeleteResult]
            do {
                outcomes = try await mcpStep(log) { try await deleteTasks(targets) }
            } catch {
                throw Self.mcpAnnotate(error, ["recovery": .string("Re-read the tasks and retry the same targets.")])
            }
            for (offset, outcome) in outcomes.enumerated() {
                let target = targets[offset]
                if let message = outcome.error {
                    slots[positions[offset]] = .object([
                        "ok": .bool(false), "error": .string(message), "task_id": .string(target.taskID),
                        "recovery": .string("Re-read the task and retry the same deletion scope."),
                    ])
                } else if let plan = outcome.plan {
                    var result = Self.mcpPlanJSON(plan)
                    result["deleted"] = .bool(true)
                    slots[positions[offset]] = .object(["ok": .bool(true), "result": .object(result)])
                }
            }
        }
        let results = slots.map { $0 ?? .object(["ok": .bool(false), "error": .string("No result for this target.")]) }
        let succeeded = results.filter { value in
            if case .object(let object) = value, case .bool(true)? = object["ok"] { return true }
            return false
        }.count
        return ["items": .array(results), "succeeded": .of(succeeded), "preview": .bool(false)]
    }

    /// 批量删除的一项：检查参数（和 delete_task 相同的规则），转换成服务层的删除目标。
    static func mcpDeleteTarget(_ args: MCPArgs) throws -> BatchDeleteTarget {
        let taskID = try args.requiredID("task_id")
        let raw = args.string("scope")
        let scope = raw.flatMap(DeleteScope.init(rawValue:))
        if raw != nil && scope == nil {
            throw MCPToolError("scope must be occurrence, future_pending or series.",
                               details: ["task_id": .string(taskID)])
        }
        let occurrenceID = try args.id("occurrence_id")
        let fromDate = try args.date("from_date")
        if (occurrenceID != nil) != (scope == .occurrence) || (fromDate != nil && scope != .futurePending) {
            throw MCPToolError("occurrence requires occurrence_id; from_date only applies to future_pending.",
                               details: ["task_id": .string(taskID)])
        }
        return BatchDeleteTarget(taskID: taskID, scope: scope, occurrenceID: occurrenceID, fromDate: fromDate)
    }

    /// 对应 Python batch：逐项执行，失败项带上错误和附加字段，不影响其他项。
    func mcpBatch(_ items: [JSONObject], _ call: (MCPArgs) async throws -> JSONObject) async -> JSONObject {
        var results: [JSONValue] = []
        var succeeded = 0
        for item in items {
            do {
                let value = try await call(MCPArgs(item))
                results.append(.object(["ok": .bool(true), "result": .object(value)]))
                succeeded += 1
            } catch {
                var failure = MCPDispatcher.failure(error)
                failure["ok"] = .bool(false)
                results.append(.object(failure))
            }
        }
        return ["items": .array(results), "succeeded": .of(succeeded)]
    }

    /// 对应 Python batch_update_tasks 的单项：按需改期、移动、改文字与优先级。
    func mcpBatchUpdate(_ args: MCPArgs, _ log: MCPChangeLog) async throws -> JSONObject {
        let taskID = try args.requiredID("task_id")
        let start = try args.date("start_date")
        if start == nil, ["end_date", "start_time", "end_time"].contains(where: args.has) {
            throw MCPToolError("Provide start_date to reschedule a task.")
        }
        let end = try args.date("end_date")
        let startTime = try args.time("start_time")
        let endTime = try args.time("end_time")
        let listID = try args.id("list_id")
        if let listID {
            _ = try await mcpStep(log) {
                try await mcpGuarded {
                    _ = try await validateList(listID)
                    return [:]
                }
            }
        }
        let hasMetadata = ["title", "remark", "important", "urgent", "collected"].contains(where: args.has)
        if let title = args.string("title"), title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPToolError("A task title is required.")
        }
        do {
            if let start {
                try await mcpChange(log) {
                    try await rescheduleTask(taskID, start: start, end: end, startTime: startTime, endTime: endTime)
                }
            }
            if let listID {
                try await mcpChange(log) { try await moveTask(taskID, to: listID) }
            }
            if hasMetadata {
                try await mcpChange(log) {
                    try await updateTask(taskID, title: args.string("title"), remark: args.string("remark"),
                                         important: args.bool("important"), urgent: args.bool("urgent"),
                                         collected: args.bool("collected"))
                }
            }
        } catch {
            throw Self.mcpAnnotate(error, ["task_id": .string(taskID), "may_have_written": .bool(true),
                                           "recovery": .string("Re-read the task and retry the same fields.")])
        }
        return try await mcpTaskRead(taskID, log)
    }
}
