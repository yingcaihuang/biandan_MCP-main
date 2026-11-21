import Foundation

extension AppModel {
    private var nowMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// 今天起 30 天内的日程冲突（侧栏计数和冲突页共用）。
    var scheduleConflicts: [ScheduleConflictGroup] {
        let end = today.adding(days: ScheduleConflicts.horizonDays - 1)
        let items = snapshot.items(OccurrenceQuery(start: today, end: end))
        return ScheduleConflicts.groups(items, from: today, to: end, now: nowMinutes)
    }

    /// 实例 ID → 和它直接冲突的日程（卡片角标用）。
    var conflictIndex: [String: [ConflictPartner]] {
        ScheduleConflicts.partners(scheduleConflicts)
    }

    /// 从冲突浮层跳到另一项：选中它、打开检查器，列表 / 四象限滚动过去。
    /// 它不在当前视图里（被分类、搜索或四象限范围筛掉）时，切到「全部待办」列表再定位。
    func jumpToOccurrence(_ id: String) {
        guard snapshot.item(occurrenceID: id) != nil else { return }
        let current = sidebarSelection ?? .all
        var visible = true
        if current != .conflicts && effectiveMode != .calendar {
            if effectiveMode == .quadrant {
                visible = quadrantItems().values.contains { group in group.contains { $0.id == id } }
            } else {
                visible = items(for: current).contains { $0.id == id }
            }
        }
        if !visible {
            searchText = ""
            sidebarSelection = .all
            viewMode = .list
        }
        multiSelection = []
        selectionAnchor = id
        selectedFocusID = nil
        selectedOccurrenceID = id
        showInspector = true
        keyboardScrollTarget = nil
        let delay = visible ? 40 : 300
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            self?.keyboardScrollTarget = id
        }
    }

    /// 新建参数的第一天时间段和哪些已有日程交叉。没写时刻或是全天时不检查。
    func conflicts(for input: CreateTaskInput, excluding: String? = nil) -> [ScheduleSlot] {
        guard let day = input.startDate, let start = input.startTime else { return [] }
        let from = ScheduleConflicts.minutes(start)
        let to = input.endTime.map(ScheduleConflicts.endMinutes) ?? from
        if from == 0 && to >= 1440 { return [] }
        let items = snapshot.items(OccurrenceQuery(start: day, end: day))
        return ScheduleConflicts.overlapping(day: day, start: from, end: to, in: items, excluding: excluding)
    }

    /// 快速添加回车前的冲突提示。
    func quickAddConflictText(_ draft: QuickAddDraft, preset: NewTaskPreset? = nil) -> String? {
        guard let input = QuickAddParser.input(draft, preset: preset ?? makeNewTaskPreset()) else { return nil }
        let found = conflicts(for: input)
        guard let first = found.first else { return nil }
        let name = ScheduleConflicts.shortTitle(first.item)
        return found.count == 1 ? "⚠︎ 与「\(name)」时间冲突" : "⚠︎ 与「\(name)」等 \(found.count) 项时间冲突"
    }

    /// 新建成功后检查冲突，有冲突就在底部弹出提醒。
    func noteConflicts(for input: CreateTaskInput, createdID: String?) {
        let found = conflicts(for: input, excluding: createdID)
        guard !found.isEmpty, let day = input.startDate, let start = input.startTime else { return }
        let from = ScheduleConflicts.minutes(start)
        let to = input.endTime.map(ScheduleConflicts.endMinutes) ?? from
        conflictNotice = ConflictNotice(message: ScheduleConflicts.message(title: input.title, day: day, start: from,
                                                                           end: to, others: found, today: today))
    }
}
