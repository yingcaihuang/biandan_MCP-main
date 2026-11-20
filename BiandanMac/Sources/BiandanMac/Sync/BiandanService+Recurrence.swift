import Foundation

/// 修改重复规则的影响，对应 Python update_recurrence 的 preview 返回。
struct RecurrencePlan: Sendable, Equatable {
    var fromDate: LocalDate
    var created: Int
    var rescheduled: Int
    var removed: Int
    var protectedDates: Int
}

/// 新规则与现有实例的对比结果（纯计算，不访问网络）。
struct RecurrenceDiff: Sendable {
    var insert: [JSONObject]
    var patches: [(RawRecord, JSONObject)]
    var prune: [RawRecord]
    var protectedDays: Set<String>
}

extension BiandanService {
    /// 截止日前、已完成、有进度或已放弃的实例保留；其余按新规则新增、改期或移除。
    static func diffRecurrence(taskID: String, existing: [RawRecord], target targetIn: [String: JSONObject],
                               cutoff: LocalDate, undated: Bool) throws -> RecurrenceDiff {
        var target = targetIn
        var planned: [String: RawRecord] = [:]
        var protectedDays = Set<String>()
        for entry in existing {
            let fields = entry.attributes ?? [:]
            let day = fields.string("startTime") ?? ""
            if fields.truthy("isFinish") || fields.truthy("completedCount") || (day < cutoff.iso && !undated) {
                protectedDays.insert(day)
            } else {
                if planned[day] != nil {
                    throw ServiceError("有多个待完成实例在同一天，请先处理后再修改重复规则。")
                }
                planned[day] = entry
            }
        }
        for day in protectedDays { target.removeValue(forKey: day) }
        let days = target.keys.sorted()
        let insert = days.filter { planned[$0] == nil }
            .compactMap { target[$0] }
            .map { newOccurrence(taskID: taskID, window: $0, repeating: true) }
        let prune = planned.keys.sorted().filter { target[$0] == nil }.compactMap { planned[$0] }
        var patches: [(RawRecord, JSONObject)] = []
        for day in days {
            guard let record = planned[day], let slot = target[day] else { continue }
            let current = record.attributes ?? [:]
            if slot.contains(where: { !AttributeMatch.matches(current[$0.key], $0.value, key: $0.key) }) {
                patches.append((record, slot))
            }
        }
        return RecurrenceDiff(insert: insert, patches: patches, prune: prune, protectedDays: protectedDays)
    }

    private static func clock(_ text: String?, fallback: String) -> LocalTime? {
        LocalTime(text: String((text ?? fallback).prefix(5)))
    }

    /// 修改重复规则或把任务转为重复任务。`preview` 时只返回影响，不写入。
    func updateRecurrence(_ taskID: String, rule: RepeatRule, fromDate: LocalDate? = nil,
                          start: LocalDate? = nil, end: LocalDate? = nil,
                          startTime: LocalTime? = nil, endTime: LocalTime? = nil, habit: Bool? = nil,
                          weekStart: Int = 0, chinaMakeup: Bool = false,
                          preview: Bool = false) async throws -> (RecurrencePlan, ChangeSet) {
        try await run {
            var task = try await fresh(try await require(.task, taskID))
            let row = task.attributes ?? [:]
            let cutoff = fromDate ?? today()
            let undated = row.truthy("haveNoTime")
            if undated && (start == nil || end == nil) {
                throw ServiceError("把无日期任务改成重复任务时，需要设置开始和截止日期。")
            }
            guard let seriesStart = start ?? LocalDate(iso: row.string("startTime")),
                  let seriesEnd = end ?? LocalDate(iso: row.string("endTime")) else {
                throw ServiceError("任务缺少有效的起止日期。")
            }
            let window = try Self.dateWindow(
                start: seriesStart, end: seriesEnd,
                startTime: startTime ?? Self.clock(row.string("validStartTime"), fallback: "00:00"),
                endTime: endTime ?? Self.clock(row.string("validEndTime"), fallback: "23:59"))
            let isHabit = habit ?? ((row.int("isLoop") ?? 0) >= 2)
            let encoded = try rule.encode()
            var changes = window
            changes.merge(encoded.attributes) { _, new in new }
            changes["isLoop"] = .of(isHabit ? 2 : 1)
            changes["haveNoTime"] = .of(0)

            let input = RecurrenceInput(start: seriesStart, end: seriesEnd,
                                        validStartTime: window.string("validStartTime") ?? "00:00:00",
                                        validEndTime: window.string("validEndTime") ?? "23:59:00", rule: encoded)
            var target: [String: JSONObject] = [:]
            for slot in try Recurrence.windows(input, weekStart: weekStart, chinaMakeup: chinaMakeup,
                                               fromDate: cutoff, allowEmpty: true) {
                target[slot.start.iso] = slot.attributes
            }
            let diff = try Self.diffRecurrence(taskID: taskID, existing: try await taskOccurrences(taskID),
                                               target: target, cutoff: cutoff, undated: undated)
            if diff.insert.isEmpty && diff.patches.isEmpty && target.isEmpty && diff.protectedDays.isEmpty {
                throw ServiceError("修改后这个任务一个实例都没有了，请调整日期，或直接删除任务。")
            }
            let plan = RecurrencePlan(fromDate: cutoff, created: diff.insert.count, rescheduled: diff.patches.count,
                                      removed: diff.prune.count, protectedDates: diff.protectedDays.count)
            if preview { return plan }
            do {
                let ids = Set(diff.insert.compactMap { $0.string("id2") })
                let indexed = ids.isEmpty ? [:] : try await occurrenceIndex(ids)
                if indexed.values.contains(where: { $0.attributes?.identifier("id1") != taskID }) {
                    throw ServiceError("生成的执行实例 ID 已被其他任务占用。")
                }
                for entry in diff.insert {
                    let id2 = entry.string("id2") ?? ""
                    try await ensureRecord(.showTask, id2, expected: entry, existing: indexed[id2])
                }
                for (record, slot) in diff.patches {
                    try await patch(record, slot)
                }
                task = try await patch(task, changes)
                for record in diff.prune {
                    try await deleteRecord(record)
                }
                try await reconcileTask(task, try await taskOccurrences(taskID))
            } catch {
                throw ServiceError(error.localizedDescription, mayHaveWritten: true,
                                   recovery: "请同步后用同样的规则和起始日期重试。")
            }
            return plan
        }
    }

    /// 只改重复任务的这一次：复制出一个一次性任务，把这个实例挂过去（保留实例 ID 和持续天数）。
    /// 返回脱离后新任务的 ID。
    func rescheduleOccurrence(_ occurrenceID: String, start: LocalDate, end: LocalDate? = nil,
                              startTime: LocalTime? = nil, endTime: LocalTime? = nil) async throws -> (String, ChangeSet) {
        try await run {
            let instance = try await fresh(try await require(.showTask, occurrenceID))
            let row = instance.attributes ?? [:]
            guard let taskID = row.identifier("id1") else { throw ServiceError("实例缺少所属任务。") }
            let task = try await fresh(try await require(.task, taskID))
            guard Self.isRepeating(task.attributes ?? [:]) else {
                throw ServiceError("一次性任务请直接修改任务时间。")
            }
            guard !row.truthy("isFinish"), (row.int("completedCount") ?? 0) >= 0 else {
                throw ServiceError("只能改期待完成的实例。")
            }
            guard let oldStart = LocalDate(iso: row.string("startTime")),
                  let oldEnd = LocalDate(iso: row.string("endTime")) else {
                throw ServiceError("实例缺少有效的日期。")
            }
            let last = end ?? start.adding(days: oldStart.days(to: oldEnd))
            let changes = try Self.dateWindow(
                start: start, end: last,
                startTime: startTime ?? Self.clock(row.string("validStartTime"), fallback: "00:00"),
                endTime: endTime ?? Self.clock(row.string("validEndTime"), fallback: "23:59"))
            let detachedID = BusinessID.detachedTaskID(occurrenceID: occurrenceID)
            var clone = task.attributes ?? [:]
            clone.merge(changes) { _, new in new }
            clone.merge(["id1": .string(detachedID), "isLoop": .of(0), "haveNoTime": .of(0), "loopSet": .of(0),
                         "loopUnit": .of(0), "loopBaseNumber": .of(1), "loopDate": .string(""),
                         "duration": .of(0), "isFinish": .of(0)]) { _, new in new }
            do {
                let existing = try await find(.task, detachedID, required: false)
                try await ensureRecord(.task, detachedID, expected: clone, existing: existing)
                let others = try await taskOccurrences(taskID).filter { $0.cloudID != instance.cloudID }
                try await reconcileTask(task, others)
                var reparent = changes
                reparent["id1"] = .string(detachedID)
                _ = try await patch(instance, reparent, reparent: true)
            } catch {
                throw ServiceError(error.localizedDescription, mayHaveWritten: true, recovery: "请同步后重试改期这一次。")
            }
            return detachedID
        }
    }
}
