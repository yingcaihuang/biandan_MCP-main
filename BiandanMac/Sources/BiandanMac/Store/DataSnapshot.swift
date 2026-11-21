import Foundation

/// 一个执行实例和它所属的任务定义。
struct OccurrenceItem: Identifiable, Hashable, Sendable {
    let occurrence: Occurrence
    let task: TaskDef

    var id: String { occurrence.id2 }
    var status: OccurrenceStatus { occurrence.status }
    var progress: OccurrenceProgress { occurrence.progress(goal: task.goal) }

    func isOverdue(today: LocalDate) -> Bool {
        guard status == .pending, !task.undated, let end = occurrence.endDate else { return false }
        return end < today
    }
}

/// 执行实例查询条件，语义对应 Python `list_occurrences`。
struct OccurrenceQuery: Sendable {
    enum Status: String, CaseIterable, Sendable {
        case pending, completed, abandoned, all
    }

    /// start 为 nil 时不按日期筛选（全部有日期的实例）。end 缺省等于 start。
    var start: LocalDate?
    var end: LocalDate?
    var status: Status = .pending
    var taskID: String?
    var listID: String?
    var important: Bool?
    var urgent: Bool?
    var habit: Bool?
    var repeating: Bool?
    var collected: Bool?
    var text = ""
    var includeUndated = false

    init(start: LocalDate? = nil, end: LocalDate? = nil, status: Status = .pending) {
        self.start = start
        self.end = end
        self.status = status
    }
}

struct SidebarCounts: Sendable, Equatable {
    var today = 0
    var next7Days = 0
    var allPending = 0
    var undated = 0
    var collected = 0
    var important = 0
    var overdue = 0
    var perList: [String: Int] = [:]
    var focusThisWeek = 0
}

/// 内存中的只读数据快照，由 LocalStore 读出，供界面查询。
struct DataSnapshot: Sendable {
    var lists: [TodoList] = [TodoList.synthesizedDefault]
    var tasks: [String: TaskDef] = [:]
    var occurrences: [Occurrence] = []
    var occurrencesByTask: [String: [Occurrence]] = [:]
    var focus: [FocusRecord] = []
    /// 重复业务 ID、孤立实例等数据问题。
    var warnings: [String] = []
    var lastPulledAt: Date?

    static let empty = DataSnapshot()

    init() {}

    init(lists listRecords: [RawRecord], tasks taskRecords: [RawRecord], occurrences occurrenceRecords: [RawRecord],
         focus focusRecords: [RawRecord], lastPulledAt: Date?) {
        self.lastPulledAt = lastPulledAt

        var lists: [TodoList] = []
        var seenLists = Set<String>()
        for list in listRecords.map(TodoList.init(record:)) where !list.id3.isEmpty {
            if seenLists.insert(list.id3).inserted {
                lists.append(list)
            } else {
                warnings.append("多个分类使用了同一个 ID \(list.id3)")
            }
        }
        if !seenLists.contains(TodoList.defaultID) {
            lists.append(.synthesizedDefault)
        }
        self.lists = lists.sorted {
            ($0.color.sortIndex, Int64($0.id3) ?? 0) < ($1.color.sortIndex, Int64($1.id3) ?? 0)
        }

        for task in taskRecords.map(TaskDef.init(record:)) where !task.id1.isEmpty {
            if tasks[task.id1] == nil {
                tasks[task.id1] = task
            } else {
                warnings.append("多个任务使用了同一个 ID \(task.id1)")
            }
        }

        var seenOccurrences = Set<String>()
        var orphans = 0
        for occurrence in occurrenceRecords.map(Occurrence.init(record:)) where !occurrence.id2.isEmpty {
            guard seenOccurrences.insert(occurrence.id2).inserted else {
                warnings.append("多个执行实例使用了同一个 ID \(occurrence.id2)")
                continue
            }
            if tasks[occurrence.id1] == nil { orphans += 1 }
            occurrences.append(occurrence)
            occurrencesByTask[occurrence.id1, default: []].append(occurrence)
        }
        if orphans > 0 {
            warnings.append("有 \(orphans) 个执行实例找不到所属任务")
        }
        for key in occurrencesByTask.keys {
            occurrencesByTask[key]?.sort { ($0.startTime ?? "", $0.validStartTime, $0.id2) < ($1.startTime ?? "", $1.validStartTime, $1.id2) }
        }

        focus = focusRecords.map(FocusRecord.init(record:)).filter { !$0.time.isEmpty }
            .sorted { (Int64($0.time) ?? 0) > (Int64($1.time) ?? 0) }
    }

    // MARK: 查找

    func list(_ id3: String) -> TodoList? {
        lists.first { $0.id3 == id3 }
    }

    func occurrences(ofTask id1: String) -> [Occurrence] {
        occurrencesByTask[id1] ?? []
    }

    func item(occurrenceID: String) -> OccurrenceItem? {
        guard let occurrence = occurrences.first(where: { $0.id2 == occurrenceID }),
              let task = tasks[occurrence.id1] else { return nil }
        return OccurrenceItem(occurrence: occurrence, task: task)
    }

    func occurrence(forFocus record: FocusRecord) -> OccurrenceItem? {
        record.parsedLog.eventID.flatMap { item(occurrenceID: $0) }
    }

    // MARK: 查询

    func items(_ query: OccurrenceQuery) -> [OccurrenceItem] {
        let start = query.start
        let end = query.end ?? query.start
        var result: [OccurrenceItem] = []
        for occurrence in occurrences {
            guard let task = tasks[occurrence.id1] else { continue }
            if let taskID = query.taskID, task.id1 != taskID { continue }
            if let listID = query.listID, task.id3 != listID { continue }
            if let important = query.important, task.important != important { continue }
            if let urgent = query.urgent, task.urgent != urgent { continue }
            if let habit = query.habit, task.isHabit != habit { continue }
            if let repeating = query.repeating, task.isRepeating != repeating { continue }
            if let collected = query.collected, task.collected != collected { continue }
            if !task.matches(query: query.text) { continue }

            let status = occurrence.status
            if query.status != .all && status.rawValue != query.status.rawValue { continue }

            let matches: Bool
            if query.status == .completed {
                // 已完成按实际完成日筛选。
                if let start, let end {
                    let day = String((occurrence.completedAt ?? "").prefix(10))
                    matches = start.iso <= day && day <= end.iso
                } else {
                    matches = true
                }
            } else if task.undated {
                matches = query.includeUndated
            } else if let start, let end {
                matches = (occurrence.startTime ?? "") <= end.iso && (occurrence.endTime ?? "") >= start.iso
            } else {
                matches = true
            }
            if matches {
                result.append(OccurrenceItem(occurrence: occurrence, task: task))
            }
        }
        let byCompletion = query.status == .completed
        result.sort { lhs, rhs in
            let a = byCompletion ? (lhs.occurrence.completedAt ?? "") : (lhs.occurrence.startTime ?? "")
            let b = byCompletion ? (rhs.occurrence.completedAt ?? "") : (rhs.occurrence.startTime ?? "")
            return (a, lhs.occurrence.validStartTime, lhs.id) < (b, rhs.occurrence.validStartTime, rhs.id)
        }
        return result
    }

    func tasks(matching text: String = "", listID: String? = nil) -> [TaskDef] {
        tasks.values.filter { task in
            (listID == nil || task.id3 == listID) && task.matches(query: text)
        }
        .sorted { ($0.completed ? 1 : 0, -(Int64($0.id1) ?? 0)) < ($1.completed ? 1 : 0, -(Int64($1.id1) ?? 0)) }
    }

    func focus(from start: LocalDate?, to end: LocalDate?) -> [FocusRecord] {
        focus.filter { record in
            guard let day = record.localDate else { return start == nil && end == nil }
            if let start, day < start { return false }
            if let end, day > end { return false }
            return true
        }
    }

    // MARK: 侧栏计数

    func counts(today: LocalDate, weekStart: Int = 0) -> SidebarCounts {
        var counts = SidebarCounts()
        let weekEnd = today.adding(days: 6)
        for occurrence in occurrences where occurrence.status == .pending {
            guard let task = tasks[occurrence.id1] else { continue }
            counts.allPending += 1
            counts.perList[task.id3, default: 0] += 1
            if task.collected { counts.collected += 1 }
            if task.important { counts.important += 1 }
            if task.undated {
                counts.undated += 1
                continue
            }
            if occurrence.overlaps(today, today) { counts.today += 1 }
            if occurrence.overlaps(today, weekEnd) { counts.next7Days += 1 }
            if let last = occurrence.endDate, last < today { counts.overdue += 1 }
        }
        let offset = floorMod(today.weekday - weekStart, 7)
        let monday = today.adding(days: -offset)
        counts.focusThisWeek = focus(from: monday, to: monday.adding(days: 6)).count
        return counts
    }
}
