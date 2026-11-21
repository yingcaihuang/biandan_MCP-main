import Foundation

/// 新建任务弹窗的预设（从四象限、待办单或日历进入时带上对应值）。
struct NewTaskPreset: Identifiable {
    let id = UUID()
    var listID: String = TodoList.defaultID
    var important = false
    var urgent = false
    var date: LocalDate?
}

typealias SnapshotEdit = (inout DataSnapshot) -> Void

/// 一条等待云端确认的乐观修改。
struct OptimisticEdit {
    let id: UUID
    let apply: SnapshotEdit
}

/// 写操作入口。每个操作都在 BiandanService 里串行执行、写后读回。
/// - 后台操作（background）先在快照里乐观更新，界面立即生效，不显示「正在写入」；
///   成功后用云端读回的记录覆盖，失败则撤掉乐观修改并提示。
/// - 前台操作（新建、删除、保存重复规则）由各自的弹窗显示进度。
/// - 静默操作（silent，只读预览）不计入任何进度，不锁界面。
/// 检查器里的保存全部是后台 + 乐观，界面不会被锁住。
extension AppModel {
    var isBusy: Bool { busyOperations > 0 }
    var isSavingInBackground: Bool { backgroundOperations > 0 }

    @discardableResult
    func perform<T: Sendable>(_ label: String, background: Bool = false, silent: Bool = false,
                              optimistic: SnapshotEdit? = nil,
                              _ operation: @escaping @Sendable (BiandanService) async throws -> (T, ChangeSet)) async -> T? {
        guard authState == .signedIn else {
            operationError = "请先登录华为账号。"
            return nil
        }
        let editID = UUID()
        let hasOptimistic = optimistic != nil
        if let optimistic {
            optimisticEdits.append(OptimisticEdit(id: editID, apply: optimistic))
            optimistic(&snapshot)
        }
        if !silent {
            if background { backgroundOperations += 1 } else { busyOperations += 1 }
        }
        defer {
            if !silent {
                if background { backgroundOperations -= 1 } else { busyOperations -= 1 }
            }
        }
        do {
            let (value, changes) = try await operation(service)
            optimisticEdits.removeAll { $0.id == editID }
            applyLocal(changes, forceReload: hasOptimistic)
            if !background { operationError = nil }
            return value
        } catch let failure as OperationFailure {
            optimisticEdits.removeAll { $0.id == editID }
            applyLocal(failure.changes, forceReload: hasOptimistic)
            if failure.needsSignIn {
                expireSession()
            } else {
                operationError = Self.failureText(label, failure.message, reverted: hasOptimistic)
            }
            return nil
        } catch {
            optimisticEdits.removeAll { $0.id == editID }
            if hasOptimistic { reloadSnapshot() }
            operationError = Self.failureText(label, error.localizedDescription, reverted: hasOptimistic)
            return nil
        }
    }

    @discardableResult
    func performChange(_ label: String, background: Bool = false, optimistic: SnapshotEdit? = nil,
                       _ operation: @escaping @Sendable (BiandanService) async throws -> ChangeSet) async -> Bool {
        let result: Bool? = await perform(label, background: background, optimistic: optimistic) { service in
            let changes = try await operation(service)
            return (true, changes)
        }
        return result ?? false
    }

    static func failureText(_ label: String, _ message: String, reverted: Bool) -> String {
        "\(label)失败" + (reverted ? "，已恢复原状态" : "") + "：\(message)"
    }

    func applyLocal(_ changes: ChangeSet, forceReload: Bool = false) {
        if !changes.isEmpty {
            do {
                try store.applyChanges(changes)
            } catch {
                operationError = "写入本地数据库失败：\(error.localizedDescription)"
            }
        }
        if !changes.isEmpty || forceReload { reloadSnapshot() }
    }

    // MARK: - 乐观更新辅助

    private static func progressStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:00"
        return formatter.string(from: Date())
    }

    private static func target(of task: TaskDef) -> Int {
        task.unitTimeNumber == 0 ? 1 : task.unitTimeNumber
    }

    /// 与 BiandanService.updateProgress 相同的规则：进度变化时更新完成时间，按目标判断是否完成。
    private static func progressEdit(_ id: String, target: Int, _ compute: @escaping (Int) -> Int) -> SnapshotEdit {
        let stamp = progressStamp()
        return { snapshot in
            snapshot.editOccurrence(id) { occurrence in
                let progress = compute(occurrence.completedCount)
                if progress != occurrence.completedCount {
                    occurrence.completedCount = progress
                    occurrence.recentFinishedTime = stamp
                }
                occurrence.isFinish = progress >= target ? 1 : 0
            }
        }
    }

    // MARK: - 执行实例进度（后台 + 乐观）

    /// 点圆圈：待完成 → 完成；已完成 → 撤销；已放弃 → 恢复。都可以 ⌘Z 撤销。
    func toggleCompletion(_ item: OccurrenceItem) async {
        let id = item.id
        let target = Self.target(of: item.task)
        let label: String
        let command: OutboxCommand
        let compute: (Int) -> Int
        switch item.status {
        case .pending:
            label = "完成"
            command = .completeOccurrence(id: id)
            compute = { _ in target }
        case .completed:
            label = "撤销完成"
            command = .changeProgress(id: id, action: .reopen, count: nil)
            compute = { _ in 0 }
        case .abandoned:
            label = "恢复"
            command = .changeProgress(id: id, action: .restore, count: nil)
            compute = { $0 < 0 ? 0 : $0 }
        }
        await progressChange(item, label: label, command, compute)
    }

    func abandon(_ item: OccurrenceItem) async {
        await progressChange(item, label: "放弃本次", .changeProgress(id: item.id, action: .abandon, count: nil), { _ in -1 })
    }

    func reopen(_ item: OccurrenceItem) async {
        await progressChange(item, label: "撤销进度", .changeProgress(id: item.id, action: .reopen, count: nil), { _ in 0 })
    }

    func setSubtask(_ item: OccurrenceItem, index: Int, checked: Bool) async {
        let id = item.id
        let target = Self.target(of: item.task)
        let edit = Self.progressEdit(id, target: target, { previous in
            let bits = max(previous, 0) / 100
            let mask = 1 << index
            return (checked ? (bits | mask) : (bits & ~mask)) * 100
        })
        let label = checked ? "勾选子任务" : "取消勾选"
        let command = OutboxCommand.setSubtask(id: id, index: index, checked: checked)
        if await performQueued(label, optimistic: edit, command) {
            registerUndo(label, undo: [.setSubtask(id: id, index: index, checked: !checked)], redo: [command])
        }
    }

    func setCount(_ item: OccurrenceItem, count: Int) async {
        await progressChange(item, label: "记录次数", .changeProgress(id: item.id, action: .setCount, count: count), { _ in count })
    }

    /// 执行一次进度修改，成功后登记撤销（恢复到修改前的进度）。
    private func progressChange(_ item: OccurrenceItem, label: String, _ command: OutboxCommand,
                                _ compute: @escaping (Int) -> Int) async {
        let target = Self.target(of: item.task)
        let undo = UndoPlan.restoreProgress(item.id, previous: item.occurrence.completedCount, target: target)
        if await performQueued(label, optimistic: Self.progressEdit(item.id, target: target, compute), command) {
            registerUndo(label, undo: undo, redo: [command])
        }
    }

    // MARK: - 任务字段

    /// 拖到另一个象限：改写 isImportant / isUrgency（后台 + 乐观）。
    func moveToQuadrant(occurrenceID: String, _ quadrant: Quadrant) async {
        guard let item = snapshot.item(occurrenceID: occurrenceID), item.task.quadrant != quadrant else { return }
        let taskID = item.task.id1
        let important = quadrant.isImportant
        let urgent = quadrant.isUrgent
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in
                task.isImportant = important ? 1 : 0
                task.isUrgency = urgent ? 1 : 0
            }
        }
        let label = "移到「\(quadrant.title)」"
        let redo = OutboxCommand.updateTask(taskID: taskID, title: nil, remark: nil, important: important,
                                            urgent: urgent, collected: nil)
        let undo = OutboxCommand.updateTask(taskID: taskID, title: nil, remark: nil, important: item.task.isImportant != 0,
                                            urgent: item.task.isUrgency != 0, collected: nil)
        if await performQueued(label, optimistic: edit, redo) {
            registerUndo(label, undo: [undo], redo: [redo])
        }
    }

    func updateTask(_ taskID: String, title: String? = nil, remark: String? = nil, important: Bool? = nil,
                    urgent: Bool? = nil, collected: Bool? = nil) async {
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in
                if let title { task.taskTitle = title.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let remark {
                    var content = task.content
                    content.remark = remark
                    task.taskContent = content.encoded()
                }
                if let important { task.isImportant = important ? 1 : 0 }
                if let urgent { task.isUrgency = urgent ? 1 : 0 }
                if let collected { task.isCollectible = collected ? 1 : 0 }
            }
        }
        let old = snapshot.tasks[taskID]
        let redo = OutboxCommand.updateTask(taskID: taskID, title: title, remark: remark, important: important,
                                            urgent: urgent, collected: collected)
        if await performQueued("保存任务", optimistic: edit, redo), let old {
            let undo = OutboxCommand.updateTask(taskID: taskID, title: title.map { _ in old.taskTitle },
                                                remark: remark.map { _ in old.content.remark },
                                                important: important.map { _ in old.isImportant != 0 },
                                                urgent: urgent.map { _ in old.isUrgency != 0 },
                                                collected: collected.map { _ in old.isCollectible != 0 })
            let onlyCollected = collected != nil && title == nil && remark == nil && important == nil && urgent == nil
            let label = onlyCollected ? (collected == true ? "收藏" : "取消收藏") : "修改任务"
            registerUndo(label, undo: [undo], redo: [redo])
        }
    }

    func moveTask(_ taskID: String, to listID: String) async {
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in task.id3 = listID }
        }
        let oldList = snapshot.tasks[taskID]?.id3
        if await performQueued("更换分类", optimistic: edit, .moveTask(taskID: taskID, listID: listID)),
           let oldList, oldList != listID {
            registerUndo("更换分类", undo: [.moveTask(taskID: taskID, listID: oldList)],
                         redo: [.moveTask(taskID: taskID, listID: listID)])
        }
    }

    func setTimeReminder(_ taskID: String, date: LocalDate?, time: LocalTime?, enabled: Bool) async {
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in
                if enabled, let date, let time {
                    task.remindDate = date.iso
                    task.remindTime = BiandanService.clockText(time)
                    task.isRemind |= 1
                } else {
                    task.isRemind &= ~1
                }
            }
        }
        await performQueued(enabled ? "设置提醒" : "关闭提醒", optimistic: edit,
                            .setTimeReminder(taskID: taskID, date: enabled ? date?.iso : nil,
                                             time: enabled ? time.map(BiandanService.clockText) : nil, enabled: enabled))
    }

    func setLocation(_ taskID: String, name: String?, latitude: Double?, longitude: Double?, remind: Bool?) async {
        // 与 BiandanService.locationChanges 相同的规则；校验不通过时云端会报错，乐观修改随之撤销。
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in
                if let name { task.location = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let latitude, let longitude {
                    task.latitude = latitude
                    task.longitude = longitude
                }
                if let remind {
                    task.isRemind = remind ? (task.isRemind | 2) : (task.isRemind & ~2)
                } else if latitude == -1 && longitude == -1 {
                    task.isRemind &= ~2
                }
            }
        }
        await performQueued("保存地点", optimistic: edit,
                            .setLocation(taskID: taskID, name: name, latitude: latitude, longitude: longitude, remind: remind))
    }

    func clearLocation(_ taskID: String) async {
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in
                task.location = ""
                task.latitude = -1
                task.longitude = -1
                task.isRemind &= ~2
            }
        }
        await performQueued("清除地点", optimistic: edit, .clearLocation(taskID: taskID))
    }

    /// 把任务和实例的日期窗口改成同一组值（乐观更新用，对应 BiandanService.dateWindow）。
    private static func windowEdit(taskID: String?, occurrenceIDs: [String], start: String, end: String,
                                   from: String, to: String, undated: Bool?, clearTimeReminder: Bool = false) -> SnapshotEdit {
        { snapshot in
            if let taskID {
                snapshot.editTask(taskID) { task in
                    task.startTime = start
                    task.endTime = end
                    task.validStartTime = from
                    task.validEndTime = to
                    if let undated { task.haveNoTime = undated ? 1 : 0 }
                    if clearTimeReminder { task.isRemind &= ~1 }
                }
            }
            for id in occurrenceIDs {
                snapshot.editOccurrence(id) { occurrence in
                    occurrence.startTime = start
                    occurrence.endTime = end
                    occurrence.validStartTime = from
                    occurrence.validEndTime = to
                }
            }
        }
    }

    /// 改期：一次性任务直接改任务时间；重复任务只改这一次（脱离系列）。
    func reschedule(_ item: OccurrenceItem, start: LocalDate, end: LocalDate?,
                    startTime: LocalTime?, endTime: LocalTime?) async {
        if item.task.isRepeating {
            await rescheduleOccurrence(item, start: start, startTime: startTime, endTime: endTime)
            return
        }
        let taskID = item.task.id1
        let last = max(end ?? start, start)
        let from = BiandanService.clockText(startTime ?? item.occurrence.startClock ?? .startOfDay)
        let to = BiandanService.clockText(endTime ?? item.occurrence.endClock ?? LocalTime(hour: 23, minute: 59)!)
        let edit = Self.windowEdit(taskID: taskID, occurrenceIDs: [item.id], start: start.iso, end: last.iso,
                                   from: from, to: to, undated: false)
        let redo = OutboxCommand.rescheduleTask(taskID: taskID, start: start.iso, end: end?.iso,
                                                startTime: startTime.map(BiandanService.clockText),
                                                endTime: endTime.map(BiandanService.clockText))
        let undo = UndoPlan.restoreSchedule(item.task)
        if await performQueued("改期", optimistic: edit, redo) {
            registerUndo("改期", undo: undo, redo: [redo])
        }
    }

    func clearSchedule(_ taskID: String) async {
        let ids = (snapshot.occurrencesByTask[taskID] ?? []).map(\.id2)
        let edit = Self.windowEdit(taskID: taskID, occurrenceIDs: ids, start: LocalDate.undatedStart.iso,
                                   end: LocalDate.maxSupported.iso, from: "00:00:00", to: "23:59:00",
                                   undated: true, clearTimeReminder: true)
        let undo = snapshot.tasks[taskID].map { UndoPlan.restoreSchedule($0, restoreReminder: true) } ?? []
        if await performQueued("清除日期", optimistic: edit, .clearSchedule(taskID: taskID)) {
            registerUndo("清除日期", undo: undo, redo: [.clearSchedule(taskID: taskID)])
        }
    }

    func editGoal(_ taskID: String, subtasks: [String]?, targetCount: Int?) async {
        // 与 BiandanService.editTaskGoal 相同的进度换算；校验不通过时云端会报错，乐观修改随之撤销。
        let titles = (subtasks ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let target = titles.isEmpty ? (targetCount ?? 1) : TaskGoal(subtaskCount: titles.count).raw
        let ids = (snapshot.occurrencesByTask[taskID] ?? []).map(\.id2)
        let stamp = Self.progressStamp()
        let edit: SnapshotEdit = { snapshot in
            snapshot.editTask(taskID) { task in
                let content = task.content
                task.taskContent = TaskContent(remark: content.remark, subtasks: titles,
                                               attachments: content.attachments).encoded()
                task.unitTimeNumber = target
            }
            for id in ids {
                snapshot.editOccurrence(id) { occurrence in
                    let previous = occurrence.completedCount
                    if occurrence.isFinish != 0 || previous < 0 { return }
                    let progress = target >= 100 ? ((previous / 100) & (target / 100)) * 100 : min(previous, target)
                    occurrence.completedCount = progress
                    occurrence.isFinish = progress >= target ? 1 : 0
                    if progress >= target { occurrence.recentFinishedTime = stamp }
                }
            }
        }
        await performQueued("修改完成目标", optimistic: edit,
                            .editGoal(taskID: taskID, subtasks: subtasks, targetCount: targetCount))
    }

    // MARK: - 重复任务（P5）

    /// 保存重复规则（也用于把一次性任务转成重复任务）。成功返回影响统计。
    @discardableResult
    func updateRecurrence(_ taskID: String, rule: RepeatRule, fromDate: LocalDate, start: LocalDate, end: LocalDate,
                          startTime: LocalTime?, endTime: LocalTime?, habit: Bool) async -> RecurrencePlan? {
        let week = weekStart
        let makeup = chinaMakeup
        return await perform("保存重复规则") {
            try await $0.updateRecurrence(taskID, rule: rule, fromDate: fromDate, start: start, end: end,
                                          startTime: startTime, endTime: endTime, habit: habit,
                                          weekStart: week, chinaMakeup: makeup)
        }
    }

    /// 预览修改重复规则的影响（不写入）。
    func previewRecurrence(_ taskID: String, rule: RepeatRule, fromDate: LocalDate, start: LocalDate, end: LocalDate,
                           startTime: LocalTime?, endTime: LocalTime?, habit: Bool) async -> RecurrencePlan? {
        let week = weekStart
        let makeup = chinaMakeup
        return await perform("预览重复规则", silent: true) {
            try await $0.updateRecurrence(taskID, rule: rule, fromDate: fromDate, start: start, end: end,
                                          startTime: startTime, endTime: endTime, habit: habit,
                                          weekStart: week, chinaMakeup: makeup, preview: true)
        }
    }

    /// 只改重复任务的这一次（脱离系列，保留实例 ID 和持续天数）。
    @discardableResult
    func rescheduleOccurrence(_ item: OccurrenceItem, start: LocalDate,
                              startTime: LocalTime?, endTime: LocalTime?) async -> Bool {
        let id = item.id
        // 乐观：先把这一次挪到新日期（保留持续天数）；成功后用读回的脱离任务覆盖。
        var last = start
        if let oldStart = item.occurrence.startDate, let oldEnd = item.occurrence.endDate {
            last = start.adding(days: max(oldStart.days(to: oldEnd), 0))
        }
        let from = BiandanService.clockText(startTime ?? item.occurrence.startClock ?? .startOfDay)
        let to = BiandanService.clockText(endTime ?? item.occurrence.endClock ?? LocalTime(hour: 23, minute: 59)!)
        let edit = Self.windowEdit(taskID: nil, occurrenceIDs: [id], start: start.iso, end: last.iso,
                                   from: from, to: to, undated: nil)
        return await performQueued("改期这一次", optimistic: edit,
                                   .rescheduleOccurrence(id: id, start: start.iso,
                                                         startTime: startTime.map(BiandanService.clockText),
                                                         endTime: endTime.map(BiandanService.clockText)))
    }

    // MARK: - 新建 / 删除任务

    /// 成功后选中新任务的第一个实例。
    @discardableResult
    func createTask(_ input: CreateTaskInput) async -> Bool {
        var prepared = input
        prepared.weekStart = weekStart
        prepared.chinaMakeup = chinaMakeup
        let final = prepared
        guard let result = await perform("新建任务", { try await $0.createTask(final) }) else { return false }
        selectedFocusID = nil
        selectedOccurrenceID = result.occurrenceID
        return true
    }

    /// 删除预览：不写入，只返回影响范围。
    func deletePlan(_ item: OccurrenceItem, scope: DeleteScope) async -> DeletePlan? {
        let taskID = item.task.id1
        let occurrenceID = scope == .occurrence ? item.id : nil
        let fromDate = scope == .futurePending ? item.occurrence.startDate : nil
        let effective: DeleteScope? = item.task.isRepeating ? scope : nil
        return await perform("预览删除", silent: true) {
            try await $0.deleteTask(taskID, scope: effective, occurrenceID: effective == .occurrence ? occurrenceID : nil,
                                    fromDate: effective == .futurePending ? fromDate : nil, preview: true)
        }
    }

    @discardableResult
    func deleteTask(_ item: OccurrenceItem, scope: DeleteScope) async -> Bool {
        let taskID = item.task.id1
        let occurrenceID = item.id
        let fromDate = item.occurrence.startDate
        let effective: DeleteScope? = item.task.isRepeating ? scope : nil
        let plan = await perform("删除任务") {
            try await $0.deleteTask(taskID, scope: effective, occurrenceID: effective == .occurrence ? occurrenceID : nil,
                                    fromDate: effective == .futurePending ? fromDate : nil)
        }
        if plan != nil, selectedOccurrenceID == occurrenceID { selectedOccurrenceID = nil }
        return plan != nil
    }

    // MARK: - 待办单

    @discardableResult
    func createList(name: String, colorIndex: Int) async -> String? {
        let identifier = await perform("新建分类") { try await $0.createList(name: name, colorIndex: colorIndex) }
        if let identifier { sidebarSelection = .list(identifier) }
        return identifier
    }

    @discardableResult
    func updateList(_ listID: String, name: String?, colorIndex: Int?, sortIndex: Int? = nil) async -> Bool {
        await performQueued("保存分类",
                            .updateList(listID: listID, name: name, colorIndex: colorIndex, sortIndex: sortIndex))
    }

    @discardableResult
    func deleteList(_ listID: String, deleteTasks: Bool) async -> Bool {
        let ok = await performChange("删除分类") { try await $0.deleteList(listID, deleteTasks: deleteTasks) }
        if ok, sidebarSelection == .list(listID) { sidebarSelection = .all }
        return ok
    }

    /// 侧栏拖动排序：按新顺序写入 sortIndex（只改变化的待办单，默认待办单不参与）。
    func reorderLists(_ ordered: [TodoList]) async {
        for (index, list) in ordered.enumerated() where !list.isDefault && list.color.sortIndex != index + 1 {
            let ok = await updateList(list.id3, name: nil, colorIndex: nil, sortIndex: index + 1)
            if !ok { return }
        }
    }
}
