import Foundation

// MARK: - 输入与结果类型

enum DeleteScope: String, CaseIterable, Sendable {
    case occurrence
    case futurePending = "future_pending"
    case series

    var title: String {
        switch self {
        case .occurrence: return "仅本次"
        case .futurePending: return "本次及之后未完成的"
        case .series: return "整个系列"
        }
    }
}

/// 删除前的预览结果，对应 Python delete_task 的 preview 返回。
/// 批量新建期间的查重索引：业务 ID → 云端记录（同一 ID 有多条时用于报重复）。
struct CreateIndex: Sendable {
    var tasks: [String: [RawRecord]] = [:]
    var occurrences: [String: [RawRecord]] = [:]
}

/// 批量新建一条的结果：taskID 有值表示成功，否则 error 是原因。
struct BatchCreateResult: Sendable {
    var taskID: String? = nil
    var error: String? = nil
}

/// 批量新建的整体结果：逐条结果按输入顺序；needsSignIn 表示中途登录失效。
struct BatchCreateOutcome: Sendable {
    var results: [BatchCreateResult]
    var needsSignIn: Bool
}

/// 批量删除一项的结果：error 为 nil 表示成功，plan 是实际删除的范围。
struct BatchDeleteResult: Sendable {
    var error: String? = nil
    var plan: DeletePlan? = nil
}

/// 批量删除的一项：重复任务要给范围，一次性任务 scope 为 nil。
struct BatchDeleteTarget: Sendable {
    var taskID: String
    var scope: DeleteScope?
    var occurrenceID: String?
    var fromDate: LocalDate?
}

struct DeletePlan: Sendable {
    var taskID: String
    var title: String?
    var scope: DeleteScope
    var occurrenceIDs: [String]
    var deletesTaskDefinition: Bool
}

struct LocationInput: Sendable {
    var name: String?
    var latitude: Double?
    var longitude: Double?
    var remind: Bool?
}

/// 新建任务的参数，对应 Python create_task。
struct CreateTaskInput: Sendable {
    var title: String
    var remark = ""
    var listID = TodoList.defaultID
    var important = false
    var urgent = false
    /// nil 表示无日期任务。
    var startDate: LocalDate?
    var endDate: LocalDate?
    var startTime: LocalTime?
    var endTime: LocalTime?
    var subtasks: [String] = []
    var targetCount: Int?
    var reminderDate: LocalDate?
    var reminderTime: LocalTime?
    var repeatRule: RepeatRule?
    var habit = false
    var location: LocationInput?
    var weekStart = 0
    var chinaMakeup = false
    /// 重试同一笔创建时传入原任务 ID。
    var operationID: String?

    init(title: String) {
        self.title = title
    }
}

struct CreateTaskResult: Sendable {
    var taskID: String
    var occurrenceID: String
    var occurrencesCreated: Int
}

enum ProgressAction: String, Sendable {
    case complete, reopen, abandon, restore, uncheckSubtask, setCount
}

// MARK: - 任务操作

extension BiandanService {
    static func isRepeating(_ attributes: JSONObject) -> Bool {
        attributes.truthy("isLoop") || attributes.truthy("loopSet")
    }

    private func formatted(_ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: clock())
    }

    /// 对应 Python reconcile_task：还有未完成且未放弃的实例时，任务为未完成。
    @discardableResult
    func reconcileTask(_ task: RawRecord, _ instances: [RawRecord]) async throws -> (RawRecord, Bool) {
        let summary = !instances.isEmpty && !instances.contains { row in
            let a = row.attributes ?? [:]
            return !a.truthy("isFinish") && (a.int("completedCount") ?? 0) >= 0
        }
        let updated = try await patch(task, ["isFinish": .of(summary ? 1 : 0)])
        return (updated, summary)
    }

    static func newOccurrence(taskID: String, window: JSONObject, repeating: Bool) -> JSONObject {
        var occurrence = window
        let start = window.string("startTime") ?? ""
        occurrence["id1"] = .string(taskID)
        occurrence["id2"] = .string(repeating ? BusinessID.occurrenceID(taskID: taskID, startDate: start) : taskID)
        occurrence["completedCount"] = .of(0)
        occurrence["recentFinishedTime"] = .string("")
        occurrence["isFinish"] = .of(0)
        return occurrence
    }

    func occurrenceIndex(_ identifiers: Set<String>) async throws -> [String: RawRecord] {
        var matches: [String: RawRecord] = [:]
        for row in try await cloud.listAll(.showTask) {
            guard let id = row.attributes?.identifier("id2"), identifiers.contains(id) else { continue }
            if matches[id] != nil { throw ServiceError("有多个执行实例使用了同一个 ID \(id)。") }
            matches[id] = row
        }
        return matches
    }

    // MARK: 新建

    /// 新建前查重：批量新建期间查索引，否则照常按 ID 查任务、完整拉取执行实例表。
    func existingForCreate(_ taskID: String,
                           occurrenceIDs: Set<String>) async throws -> (RawRecord?, [String: RawRecord]) {
        guard let index = createIndex else {
            let stored = try await find(.task, taskID, required: false)
            return (stored, try await occurrenceIndex(occurrenceIDs))
        }
        let tasks = index.tasks[taskID] ?? []
        if tasks.count > 1 { throw ServiceError("有多条 task 记录使用了同一个 ID \(taskID)。") }
        var matches: [String: RawRecord] = [:]
        for id in occurrenceIDs {
            let rows = index.occurrences[id] ?? []
            if rows.count > 1 { throw ServiceError("有多个执行实例使用了同一个 ID \(id)。") }
            if let row = rows.first { matches[id] = row }
        }
        return (tasks.first, matches)
    }

    /// 把这次读回的新记录记进查重索引，同一批里后面的新建也能查到。
    func rememberCreated() {
        guard createIndex != nil else { return }
        for record in pending.upserted {
            switch record.kind {
            case .task:
                if let id = record.attributes?.identifier("id1") { createIndex?.tasks[id] = [record] }
            case .showTask:
                if let id = record.attributes?.identifier("id2") { createIndex?.occurrences[id] = [record] }
            default:
                break
            }
        }
    }

    func createTask(_ input: CreateTaskInput) async throws -> (CreateTaskResult, ChangeSet) {
        try await run { try await createTaskBody(input) }
    }

    /// 批量新建（导入用）：整批一次调用完成，最多 BatchConcurrency.limit 条同时写云端，查重索引和分类核对只做一次。
    /// 单条失败记下原因继续；登录失效或被取消时剩下的不再写、标记为没处理，已经建好的照常返回，
    /// 调用方据此保存对应关系，不会因为整批失败而在下次同步时重复新建。
    func createTasks(_ inputs: [CreateTaskInput],
                     progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> (BatchCreateOutcome, ChangeSet) {
        try await run {
            try? await beginBulkCreate()
            listCheckCache = [:]
            bulkStop = nil
            bulkSignIn = false
            progressDone = 0
            defer {
                endBulkCreate()
                listCheckCache = nil
            }
            for listID in Set(inputs.map(\.listID)) { _ = try? await validateList(listID) }
            let total = inputs.count
            let results = try await BatchConcurrency.map(inputs) { _, input in
                await self.createOne(input, total: total, progress: progress)
            }
            return BatchCreateOutcome(results: results, needsSignIn: bulkSignIn)
        }
    }

    /// 批量新建的一条：不抛错，结果里写明成功的任务 ID 或失败原因。
    private func createOne(_ input: CreateTaskInput, total: Int,
                           progress: (@Sendable (Int, Int) async -> Void)?) async -> BatchCreateResult {
        var result = BatchCreateResult()
        if let reason = bulkStop ?? (Task.isCancelled ? "已取消，没有写入" : nil) {
            result.error = reason
        } else {
            do {
                result.taskID = try await createTaskBody(input).taskID
            } catch {
                if ServiceError.needsSignIn(error) {
                    bulkSignIn = true
                    bulkStop = "登录已失效，没有写入"
                } else if error is CancellationError || Task.isCancelled {
                    bulkStop = bulkStop ?? "已取消，没有写入"
                }
                result.error = error.localizedDescription
            }
        }
        progressDone += 1
        await progress?(progressDone, total)
        return result
    }

    /// 不加锁的新建主体，供 createTask 和 createTasks 调用（调用方已在 run 内）。
    func createTaskBody(_ input: CreateTaskInput) async throws -> CreateTaskResult {
        do {
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ServiceError("请填写任务标题。") }
            let subtasks = input.subtasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard subtasks.count <= 20, !subtasks.contains(where: \.isEmpty) else {
                throw ServiceError("子任务最多 20 项，且不能为空。")
            }
            let undated = input.startDate == nil
            if undated && (input.endDate != nil || input.startTime != nil || input.endTime != nil
                           || input.reminderTime != nil || input.repeatRule != nil) {
                throw ServiceError("设置时间、提醒或重复规则时需要开始日期。")
            }
            if (input.repeatRule != nil && input.endDate == nil) || (input.habit && input.repeatRule == nil) {
                throw ServiceError("重复任务需要结束日期；习惯需要重复规则。")
            }
            if (input.reminderDate == nil) != (input.reminderTime == nil) {
                throw ServiceError("提醒日期和时刻需要一起设置。")
            }
            if !subtasks.isEmpty && input.targetCount != nil {
                throw ServiceError("子任务和目标次数只能二选一。")
            }
            if let count = input.targetCount, !(1...99).contains(count) {
                throw ServiceError("目标次数应在 1–99 之间。")
            }
            let start = input.startDate ?? .undatedStart
            let end = undated ? LocalDate.maxSupported : (input.endDate ?? start)
            let window = try Self.dateWindow(start: start, end: end, startTime: input.startTime, endTime: input.endTime)
            let taskID = input.operationID ?? nextTaskID()
            guard BusinessID.isValid(taskID) else { throw ServiceError("任务 ID 无效。") }
            let listValue = try await validateList(input.listID)

            var task = window
            let fields: JSONObject = [
                "id1": .string(taskID), "taskTitle": .string(title),
                "taskContent": .string(TaskContent(remark: input.remark, subtasks: subtasks).encoded()),
                "id3": .of(listValue), "isCollectible": .of(0),
                "isImportant": .of(input.important ? 1 : 0), "isUrgency": .of(input.urgent ? 1 : 0),
                "isLoop": .of(0), "haveNoTime": .of(undated ? 1 : 0),
                "unitTimeNumber": .of(subtasks.isEmpty ? (input.targetCount ?? 1) : TaskGoal(subtaskCount: subtasks.count).raw),
                "loopSet": .of(0), "loopBaseNumber": .of(1), "loopUnit": .of(0), "loopDate": .string(""), "duration": .of(0),
                "isRemind": .of(input.reminderTime != nil ? 1 : 0),
                "remindDate": .string(input.reminderDate?.iso ?? start.iso),
                "remindTime": .string(input.reminderTime.map(Self.clockText) ?? "00:00:00"),
                "isFinish": .of(0), "latitude": .of(-1), "longitude": .of(-1), "location": .string(""),
            ]
            task.merge(fields) { _, new in new }
            if let location = input.location {
                let changes = try Self.locationChanges(task, name: location.name, latitude: location.latitude,
                                                       longitude: location.longitude, remind: location.remind, clear: false)
                task.merge(changes) { _, new in new }
            }

            var windows = [window]
            if let rule = input.repeatRule {
                let encoded = try rule.encode()
                task.merge(encoded.attributes) { _, new in new }
                task["isLoop"] = .of(input.habit ? 2 : 1)
                let recurrence = RecurrenceInput(start: start, end: end,
                                                 validStartTime: window.string("validStartTime") ?? "00:00:00",
                                                 validEndTime: window.string("validEndTime") ?? "23:59:00",
                                                 rule: encoded)
                windows = try Recurrence.windows(recurrence, weekStart: input.weekStart,
                                                 chinaMakeup: input.chinaMakeup).map(\.attributes)
            }
            let repeating = input.repeatRule != nil
            let occurrences = windows.map { Self.newOccurrence(taskID: taskID, window: $0, repeating: repeating) }

            var stage = "任务"
            do {
                let (stored, indexed) = try await existingForCreate(
                    taskID, occurrenceIDs: Set(occurrences.compactMap { $0.string("id2") }))
                if !indexed.isEmpty && stored == nil {
                    throw ServiceError("生成的执行实例 ID 已被占用。")
                }
                if indexed.values.contains(where: { $0.attributes?.identifier("id1") != taskID }) {
                    throw ServiceError("生成的执行实例 ID 属于其他任务。")
                }
                try await ensureRecord(.task, taskID, expected: task, existing: stored)
                stage = "执行实例"
                for entry in occurrences {
                    let id2 = entry.string("id2") ?? ""
                    try await ensureRecord(.showTask, id2, expected: entry, existing: indexed[id2])
                }
                rememberCreated()
            } catch {
                var failure = ServiceError("\(stage)写入失败：\(error.localizedDescription)", mayHaveWritten: true,
                                           recovery: "可同步后用同一任务 ID（\(taskID)）重试。")
                // 保留原始错误的「需要重新登录」「临时失败」标记，批量新建据此停下。
                failure.signInRequired = ServiceError.needsSignIn(error)
                failure.transient = OutboxPolicy.isTransient(error)
                throw failure
            }
            return CreateTaskResult(taskID: taskID, occurrenceID: occurrences.first?.string("id2") ?? taskID,
                                    occurrencesCreated: occurrences.count)
        }
    }

    // MARK: 删除

    private struct DeleteWork {
        var plan: DeletePlan
        var task: RawRecord?
        var chosen: [RawRecord]
        var deleteParent: Bool
    }

    private func planDelete(_ taskID: String, scope: DeleteScope?, occurrenceID: String?, fromDate: LocalDate?,
                            expectedList: String?) async throws -> DeleteWork {
        let task = try await find(.task, taskID, required: false)
        let instances = try await taskOccurrences(taskID)
        let attributes = task?.attributes ?? [:]
        let repeating = task != nil && Self.isRepeating(attributes)
        if let expectedList, task == nil || attributes.identifier("id3") != expectedList {
            throw ServiceError("这个任务已不属于正在删除的分类。")
        }
        if repeating && scope == nil {
            throw ServiceError("删除重复任务需要选择范围：仅本次、本次及之后未完成的，或整个系列。")
        }
        if (occurrenceID != nil) != (scope == .occurrence) || (fromDate != nil && scope != .futurePending) {
            throw ServiceError("「仅本次」需要指定实例；起始日期只用于「本次及之后」。")
        }
        var deleteParent = scope == nil || scope == .series || (!repeating && scope == .occurrence)
        var chosen = instances
        if scope == .occurrence, let occurrenceID {
            guard BusinessID.isValid(occurrenceID) else { throw ServiceError("无效的实例 ID。") }
            chosen = instances.filter { $0.attributes?.identifier("id2") == occurrenceID }
            if chosen.isEmpty && task != nil && !repeating && !instances.isEmpty {
                throw ServiceError("指定的实例不属于这个任务。")
            }
        }
        // 删掉重复任务的最后一个实例时连任务一起删，免得留下没有实例、哪里都看不到的空任务。
        if repeating && scope == .occurrence && !chosen.isEmpty && chosen.count == instances.count {
            deleteParent = true
        }
        if scope == .futurePending {
            let start: (String, String) = fromDate.map { ($0.iso, "00:00:00") }
                ?? (today().iso, formatted("HH:mm:ss"))
            chosen = instances.filter { row in
                let a = row.attributes ?? [:]
                return !a.truthy("isFinish") && (a.string("startTime") ?? "", a.string("validStartTime") ?? "") >= start
            }
            deleteParent = !chosen.isEmpty && chosen.count == instances.count
        }
        if deleteParent && scope == .occurrence && chosen.count != instances.count {
            throw ServiceError("还有其他实例，请选择删除整个系列。")
        }
        let plan = DeletePlan(taskID: taskID, title: attributes.string("taskTitle"), scope: scope ?? .series,
                              occurrenceIDs: chosen.compactMap { $0.attributes?.identifier("id2") },
                              deletesTaskDefinition: task != nil && deleteParent)
        return DeleteWork(plan: plan, task: task, chosen: chosen, deleteParent: deleteParent)
    }

    /// 删除任务或部分实例；`preview` 时只返回影响范围，不写入。
    func deleteTask(_ taskID: String, scope: DeleteScope?, occurrenceID: String? = nil, fromDate: LocalDate? = nil,
                    preview: Bool = false) async throws -> (DeletePlan, ChangeSet) {
        try await run {
            if preview {
                return try await planDelete(taskID, scope: scope, occurrenceID: occurrenceID, fromDate: fromDate,
                                            expectedList: nil).plan
            }
            return try await deleteTaskBody(taskID, scope: scope, occurrenceID: occurrenceID, fromDate: fromDate,
                                            expectedList: nil)
        }
    }

    /// 批量删除：整批只拉一次执行实例表，逐项删除，逐项返回结果（nil 表示成功，否则是失败原因），
    /// 一项失败不影响其他项；登录失效时整批中断。最后统一核对一次孤儿实例。
    func deleteTasks(_ targets: [BatchDeleteTarget],
                     progress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> ([BatchDeleteResult], ChangeSet) {
        try await run {
            try await loadOccurrenceCache()
            defer { occurrenceCache = nil }
            progressDone = 0
            let total = targets.count
            // 同一任务的几项按顺序做（免得版本冲突），不同任务最多 BatchConcurrency.limit 个同时写云端。
            let groups = BatchConcurrency.groups(targets.map(\.taskID))
            let outcomes = try await BatchConcurrency.map(groups) { _, indices in
                try await self.deleteGroup(indices, of: targets, total: total, progress: progress)
            }
            var results = [BatchDeleteResult](repeating: BatchDeleteResult(), count: total)
            var removed = Set<String>()
            for outcome in outcomes.joined() {
                results[outcome.index] = BatchDeleteResult(error: outcome.error, plan: outcome.plan)
                if let id = outcome.removedTask { removed.insert(id) }
            }
            // 核对失败不影响已经返回的逐项结果；残留的实例下次同步后可以再删。
            try? await sweepOrphanOccurrences(of: removed)
            return results
        }
    }

    struct DeleteOutcome: Sendable {
        var index: Int
        var error: String? = nil
        var removedTask: String? = nil
        var plan: DeletePlan? = nil
    }

    /// 批量删除里同一任务的几项，按顺序删。单项失败记下原因继续；登录失效、取消时整批中断。
    private func deleteGroup(_ indices: [Int], of targets: [BatchDeleteTarget], total: Int,
                             progress: (@Sendable (Int, Int) async -> Void)?) async throws -> [DeleteOutcome] {
        var out: [DeleteOutcome] = []
        for index in indices {
            let target = targets[index]
            var outcome = DeleteOutcome(index: index)
            do {
                let plan = try await deleteTaskBody(target.taskID, scope: target.scope,
                                                    occurrenceID: target.occurrenceID, fromDate: target.fromDate,
                                                    expectedList: nil)
                if plan.deletesTaskDefinition { outcome.removedTask = target.taskID }
                outcome.plan = plan
            } catch {
                if ServiceError.needsSignIn(error) || error is CancellationError || Task.isCancelled { throw error }
                outcome.error = error.localizedDescription
            }
            out.append(outcome)
            progressDone += 1
            await progress?(progressDone, total)
        }
        return out
    }

    /// 不加锁的删除主体，供 deleteTask 和 deleteList 调用（调用方已在 run 内）。
    @discardableResult
    func deleteTaskBody(_ taskID: String, scope: DeleteScope?, occurrenceID: String?, fromDate: LocalDate?,
                        expectedList: String?) async throws -> DeletePlan {
        let work = try await planDelete(taskID, scope: scope, occurrenceID: occurrenceID, fromDate: fromDate,
                                        expectedList: expectedList)
        do {
            for row in work.chosen {
                try await deleteRecord(row)
            }
            if let task = work.task {
                let remaining = try await taskOccurrences(taskID)
                if work.deleteParent {
                    if !remaining.isEmpty { throw ServiceError("删除过程中出现了新的实例。") }
                    try await deleteRecord(task)
                } else if !remaining.isEmpty {
                    try await reconcileTask(task, remaining)
                }
            }
        } catch {
            throw ServiceError(wrapping: error, mayHaveWritten: true, recovery: "请同步后用同样的范围重试。")
        }
        return work.plan
    }

    // MARK: 改期 / 清除日期

    /// 只适用于待完成的一次性任务；未给时刻时保留原时段，提醒时间不随改期变化。
    func rescheduleTask(_ taskID: String, start: LocalDate, end: LocalDate? = nil,
                        startTime: LocalTime? = nil, endTime: LocalTime? = nil) async throws -> ChangeSet {
        try await run {
            let task = try await fresh(try await require(.task, taskID))
            guard !Self.isRepeating(task.attributes ?? [:]) else {
                throw ServiceError("重复任务请改期单次实例或修改重复规则。")
            }
            let instances = try await taskOccurrences(taskID)
            guard instances.count == 1 else { throw ServiceError("改期要求任务恰好有一个执行实例。") }
            let instance = try await fresh(instances[0])
            let a = instance.attributes ?? [:]
            guard !a.truthy("isFinish"), (a.int("completedCount") ?? 0) >= 0 else {
                throw ServiceError("只能改期待完成的任务。")
            }
            let currentStart = LocalTime(text: String((a.string("validStartTime") ?? "00:00:00").prefix(5)))
            let currentEnd = LocalTime(text: String((a.string("validEndTime") ?? "23:59:00").prefix(5)))
            let window = try Self.dateWindow(start: start, end: end, startTime: startTime ?? currentStart,
                                             endTime: endTime ?? currentEnd)
            var taskDone = false
            do {
                try await patch(task, window.merging(["haveNoTime": .of(0)]) { _, new in new })
                taskDone = true
                try await patch(instance, window)
            } catch {
                throw ServiceError(wrapping: error, mayHaveWritten: taskDone, recovery: "请同步后重试改期。")
            }
        }.1
    }

    /// 清除一次性任务的日期和时间提醒，保留地点提醒。
    func clearSchedule(_ taskID: String) async throws -> ChangeSet {
        try await run {
            let task = try await fresh(try await require(.task, taskID))
            let a = task.attributes ?? [:]
            guard !Self.isRepeating(a) else { throw ServiceError("重复任务需要日期。") }
            let instances = try await taskOccurrences(taskID)
            guard instances.count == 1 else { throw ServiceError("清除日期要求任务恰好有一个执行实例。") }
            let window = try Self.dateWindow(start: .undatedStart, end: .maxSupported, startTime: nil, endTime: nil)
            do {
                try await patch(instances[0], window)
                let flags = a.int("isRemind") ?? 0
                try await patch(task, window.merging(["haveNoTime": .of(1), "isRemind": .of(flags & ~1)]) { _, new in new })
            } catch {
                throw ServiceError(wrapping: error, mayHaveWritten: true, recovery: "请同步后重试。")
            }
        }.1
    }

    // MARK: 完成目标

    /// 改目标：二选一传完整子任务列表或目标次数。有历史进度时禁止在两种模式间切换，也禁止调整子任务顺序。
    func editTaskGoal(_ taskID: String, subtasks: [String]? = nil, targetCount: Int? = nil) async throws -> ChangeSet {
        try await run {
            guard (subtasks == nil) != (targetCount == nil) else { throw ServiceError("子任务和目标次数只能二选一。") }
            var task = try await fresh(try await require(.task, taskID))
            let a = task.attributes ?? [:]
            let content = TaskContent.decode(a.string("taskContent") ?? "")
            let rawPrevious = a.int("unitTimeNumber") ?? 1
            let previousTarget = rawPrevious == 0 ? 1 : rawPrevious
            let titles = (subtasks ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard titles.count <= 20, !titles.contains(where: \.isEmpty) else {
                throw ServiceError("子任务最多 20 项，且不能为空。")
            }
            if let targetCount, !(1...99).contains(targetCount) { throw ServiceError("目标次数应在 1–99 之间。") }
            let target = titles.isEmpty ? (targetCount ?? 1) : TaskGoal(subtaskCount: titles.count).raw
            let instances = try await taskOccurrences(taskID)
            let hasProgress = instances.contains { row in
                let o = row.attributes ?? [:]
                return (o.int("completedCount") ?? 0) > 0 || o.truthy("isFinish")
            }
            if hasProgress && (previousTarget >= 100) != (target >= 100) {
                throw ServiceError("已有进度时不能在「次数」和「子任务」之间切换。")
            }
            if hasProgress && !titles.isEmpty {
                for (index, title) in titles.enumerated() where content.subtasks.contains(title) {
                    if index >= content.subtasks.count || content.subtasks[index] != title {
                        throw ServiceError("已有进度时不要调整子任务顺序，请原位修改标题。")
                    }
                }
            }
            do {
                for item in instances {
                    let o = item.attributes ?? [:]
                    var progress = o.int("completedCount") ?? 0
                    // 保留已完成的历史进度和明确放弃的状态。
                    if o.truthy("isFinish") || progress < 0 { continue }
                    progress = target >= 100 ? ((progress / 100) & (target / 100)) * 100 : min(progress, target)
                    var flags: JSONObject = ["completedCount": .of(progress), "isFinish": .of(progress >= target ? 1 : 0)]
                    if progress >= target { flags["recentFinishedTime"] = .string(nowStamp()) }
                    try await patch(item, flags)
                }
                let encoded = TaskContent(remark: content.remark, subtasks: titles, attachments: content.attachments).encoded()
                task = try await patch(task, ["taskContent": .string(encoded), "unitTimeNumber": .of(target)])
                try await reconcileTask(task, try await taskOccurrences(taskID))
            } catch {
                throw ServiceError(wrapping: error, mayHaveWritten: true, recovery: "请用同样的目标重试。")
            }
        }.1
    }

    // MARK: 进度

    /// 完成当次：补齐子任务或次数。`completedAt` 用于补记完成时间。
    func completeOccurrence(_ occurrenceID: String, completedAt: (LocalDate, LocalTime)? = nil) async throws -> (Bool, ChangeSet) {
        try await run { try await updateProgress(occurrenceID, completedAt: completedAt) }
    }

    /// 勾选或取消勾选某个子任务（索引从 0 开始）。
    func setSubtask(_ occurrenceID: String, index: Int, checked: Bool) async throws -> (Bool, ChangeSet) {
        try await run {
            try await updateProgress(occurrenceID, subtaskIndex: index, action: checked ? .complete : .uncheckSubtask)
        }
    }

    /// 撤销完成、放弃、恢复，或写入绝对次数。
    func changeProgress(_ occurrenceID: String, action: ProgressAction, count: Int? = nil,
                        completedAt: (LocalDate, LocalTime)? = nil) async throws -> (Bool, ChangeSet) {
        guard (count != nil) == (action == .setCount) else {
            throw ServiceError("只有「记录次数」需要次数。")
        }
        guard completedAt == nil || action == .setCount else {
            throw ServiceError("完成时间只能用于「记录次数」。")
        }
        return try await run {
            try await updateProgress(occurrenceID, action: action, count: count, completedAt: completedAt)
        }
    }

    /// 对应 Python update_progress。返回父任务汇总是否已完成。
    private func updateProgress(_ occurrenceID: String, subtaskIndex: Int? = nil, action: ProgressAction = .complete,
                                count: Int? = nil, completedAt: (LocalDate, LocalTime)? = nil) async throws -> Bool {
        let composed = completedAt.map { "\($0.0.iso) \(Self.clockText($0.1))" } ?? nowStamp()
        var occurrence = try await fresh(try await require(.showTask, occurrenceID))
        guard let taskID = occurrence.attributes?.identifier("id1") else { throw ServiceError("实例缺少所属任务。") }
        var task = try await fresh(try await require(.task, taskID))
        let t = task.attributes ?? [:]
        let rawTarget = t.int("unitTimeNumber") ?? 1
        let target = rawTarget == 0 ? 1 : rawTarget
        let previous = occurrence.attributes?.int("completedCount") ?? 0
        var progress = target
        if let subtaskIndex {
            let subtasks = TaskContent.decode(t.string("taskContent") ?? "").subtasks
            guard target >= 100, subtaskIndex >= 0, subtaskIndex < min(subtasks.count, 20) else {
                throw ServiceError("子任务序号无效。")
            }
            let mask = 1 << subtaskIndex
            guard (target / 100) & mask != 0 else { throw ServiceError("这个子任务不在完成目标里。") }
            let bits = max(previous, 0) / 100
            progress = (action == .uncheckSubtask ? (bits & ~mask) : (bits | mask)) * 100
        }
        switch action {
        case .reopen: progress = 0
        case .abandon: progress = -1
        case .restore: progress = previous < 0 ? 0 : previous
        case .setCount:
            guard target < 100, let count, (0...target).contains(count) else {
                throw ServiceError("次数应在 0 到目标次数之间，且只适用于按次数完成的任务。")
            }
            progress = count
        case .complete, .uncheckSubtask:
            break
        }
        var changes: JSONObject = ["isFinish": .of(progress >= target ? 1 : 0)]
        if previous != progress || completedAt != nil {
            changes["completedCount"] = .of(progress)
            changes["recentFinishedTime"] = .string(composed)
        }
        do {
            occurrence = try await patch(occurrence, changes)
            // 更新后重新读取所有兄弟实例，按原生规则汇总。
            var refreshed = try await taskOccurrences(taskID)
            guard refreshed.contains(where: { $0.attributes?.identifier("id2") == occurrenceID }) else {
                throw ServiceError("刷新后的云端列表里找不到刚更新的实例。")
            }
            let updated = occurrence
            refreshed = refreshed.map { $0.cloudID == updated.cloudID ? updated : $0 }
            let (latest, summary) = try await reconcileTask(task, refreshed)
            task = latest
            return summary
        } catch {
            throw ServiceError(wrapping: error, mayHaveWritten: true, recovery: "请重试同一操作以修正汇总状态。")
        }
    }
}
