import AppKit
import Foundation

/// 多选与批量操作。整批操作合并成一步撤销（⌘Z 一次撤回）；删除不可撤销。
extension AppModel {
    /// 当前多选的执行实例（按 ID 排序，保证批量执行顺序稳定）。
    var batchItems: [OccurrenceItem] {
        multiSelection.sorted().compactMap { snapshot.item(occurrenceID: $0) }
    }

    /// 卡片点击：⇧ 连选，⌘ 加入 / 移出多选，否则恢复单选。
    /// 点击后让窗口接管键盘焦点（离开搜索框、侧栏），方向键、空格才会作用到任务上。
    func tapSelect(_ item: OccurrenceItem) {
        let flags = NSEvent.modifierFlags
        if selectionMode && !flags.contains(.shift) {
            // 选择模式：点一下勾选 / 取消，不带入原来的单选。
            if multiSelection.contains(item.id) {
                multiSelection.remove(item.id)
            } else {
                multiSelection.insert(item.id)
            }
            selectionAnchor = item.id
            selectedOccurrenceID = item.id
            selectedFocusID = nil
        } else if flags.contains(.shift) {
            rangeSelect(to: item)
        } else if flags.contains(.command) {
            toggleMultiSelect(item)
            selectionAnchor = item.id
        } else {
            multiSelection = []
            selectionAnchor = item.id
            selectedOccurrenceID = item.id
            selectedFocusID = nil
        }
        if let window = NSApp.keyWindow, !(window.firstResponder is NSWindow) {
            window.makeFirstResponder(nil)
        }
    }

    func toggleMultiSelect(_ item: OccurrenceItem) {
        // 第一次 ⌘ 点击时，把原来单选的那项也带进多选。
        if multiSelection.isEmpty, let current = selectedOccurrenceID, current != item.id {
            multiSelection.insert(current)
        }
        if multiSelection.contains(item.id) {
            multiSelection.remove(item.id)
        } else {
            multiSelection.insert(item.id)
        }
        selectedOccurrenceID = item.id
        selectedFocusID = nil
    }

    func clearMultiSelection() {
        multiSelection = []
    }

    /// 把当前内容区显示的任务全部加入多选（与键盘顺序同一范围）。
    func selectAllVisible() {
        multiSelection.formUnion(keyboardOrder.map(\.id))
    }

    /// 当前视图里的任务是否已经全部选中。
    var allVisibleSelected: Bool {
        let ids = keyboardOrder.map(\.id)
        return !ids.isEmpty && ids.allSatisfy(multiSelection.contains)
    }

    /// 批量栏的「全选 / 全不选」。
    func toggleSelectAllVisible() {
        if allVisibleSelected {
            multiSelection.subtract(keyboardOrder.map(\.id))
        } else {
            selectAllVisible()
        }
    }

    func enterSelectionMode() {
        selectionMode = true
    }

    /// 退出选择模式并清空多选（「完成」按钮、Esc、批量栏的 ×、切换左侧视图）。
    func exitSelectionMode() {
        selectionMode = false
        multiSelection = []
    }

    // MARK: - 批量操作

    func batchComplete() async {
        let targets = batchItems.filter { $0.status == .pending }
        await batch("完成", targets) { await self.toggleCompletion($0) }
    }

    /// 已完成的撤销完成、已放弃的恢复，都回到待完成；待完成的跳过。
    func batchReopen() async {
        let targets = batchItems.filter { $0.status != .pending }
        await batch("标记未完成", targets) { await self.toggleCompletion($0) }
    }

    func batchAbandon() async {
        let targets = batchItems.filter { $0.status == .pending }
        await batch("放弃", targets) { await self.abandon($0) }
    }

    /// 改期到某一天：保留各自的持续天数和时刻；重复任务只改这一次。
    func batchReschedule(to day: LocalDate) async {
        let targets = batchItems.filter { $0.status == .pending }
        await batch("改期", targets) { await self.rescheduleKeepingSpan($0, to: day) }
    }

    /// 改到某一天，保留原来的持续天数和时刻。
    func rescheduleKeepingSpan(_ item: OccurrenceItem, to day: LocalDate) async {
        var span = 0
        if !item.task.undated, let start = item.occurrence.startDate, let end = item.occurrence.endDate {
            span = max(start.days(to: end), 0)
        }
        await reschedule(item, start: day, end: day.adding(days: span), startTime: nil, endTime: nil)
    }

    // MARK: - 拖放

    /// 拖到侧栏的「今天」「无日期」「收藏」「重要待办」或某个分类。拖的卡片在多选里时整批处理。
    @discardableResult
    func dropOnSidebar(_ ids: [String], _ target: SidebarItem) async -> Bool {
        let items = BatchPlan.expand(ids, selection: multiSelection).compactMap { snapshot.item(occurrenceID: $0) }
        let targets = BatchPlan.sidebarTargets(target, items, today: today)
        guard !targets.isEmpty else { return false }
        switch target {
        case .today:
            let day = today
            await batch("改到今天", targets) { await self.rescheduleKeepingSpan($0, to: day) }
        case .undated:
            await batch("清除日期", targets) { await self.clearSchedule($0.task.id1) }
        case .collected:
            await batch("收藏", targets) { await self.updateTask($0.task.id1, collected: true) }
        case .important:
            await batch("设为重要", targets) { await self.updateTask($0.task.id1, important: true) }
        case .list(let listID):
            await batch("更换分类", targets) { await self.moveTask($0.task.id1, to: listID) }
        default:
            return false
        }
        return true
    }

    /// 拖到四象限的某一格。拖的卡片在多选里时整批移动。
    func dropOnQuadrant(_ ids: [String], _ quadrant: Quadrant) async {
        let items = BatchPlan.expand(ids, selection: multiSelection).compactMap { snapshot.item(occurrenceID: $0) }
        let targets = BatchPlan.uniqueTasks(items).filter { $0.task.quadrant != quadrant }
        await batch("移到「\(quadrant.title)」", targets) { await self.moveToQuadrant(occurrenceID: $0.id, quadrant) }
    }

    /// 象限和分类是任务级字段：同一任务的多个实例只改一次。
    func batchMoveToQuadrant(_ quadrant: Quadrant) async {
        let targets = BatchPlan.uniqueTasks(batchItems).filter { $0.task.quadrant != quadrant }
        await batch("移到「\(quadrant.title)」", targets) { await self.moveToQuadrant(occurrenceID: $0.id, quadrant) }
    }

    func batchMove(to listID: String) async {
        let targets = BatchPlan.uniqueTasks(batchItems).filter { $0.task.id3 != listID }
        await batch("更换分类", targets) { await self.moveTask($0.task.id1, to: listID) }
    }

    /// 逐个删除：重复任务只删这一次，一次性任务连同定义删除。全部成功返回 true。
    func batchDelete() async -> Bool {
        var allOK = true
        for item in batchItems {
            guard authState == .signedIn else { return false }
            let ok = await deleteTask(item, scope: .occurrence)
            if !ok { allOK = false }
        }
        multiSelection = multiSelection.filter { snapshot.item(occurrenceID: $0) != nil }
        return allOK
    }

    /// 依次执行，期间暂存各步撤销，最后合并登记成一步。
    private func batch(_ label: String, _ items: [OccurrenceItem],
                       _ action: (OccurrenceItem) async -> Void) async {
        guard !items.isEmpty else { return }
        undoCollector = []
        for item in items {
            guard authState == .signedIn else { break }
            await action(item)
        }
        let steps = undoCollector ?? []
        undoCollector = nil
        guard !steps.isEmpty else { return }
        let plan = UndoPlan.combine(steps)
        let name = steps.count == 1 ? label : "批量\(label)（\(steps.count) 项）"
        registerUndoNow(name, undo: plan.undo, redo: plan.redo)
    }
}

enum BatchPlan {
    /// 拖动的卡片在多选里时换成整个多选，否则就是拖动的这些（去重）。
    static func expand(_ ids: [String], selection: Set<String>) -> [String] {
        if ids.contains(where: selection.contains) { return selection.sorted() }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 拖到侧栏时真正要改的实例：已经满足条件的跳过；任务级字段按任务去重。
    static func sidebarTargets(_ target: SidebarItem, _ items: [OccurrenceItem], today: LocalDate) -> [OccurrenceItem] {
        switch target {
        case .today:
            return items.filter { $0.status == .pending && ($0.task.undated || $0.occurrence.startDate != today) }
        case .undated:
            return uniqueTasks(items.filter { $0.status == .pending && !$0.task.isRepeating && !$0.task.undated })
        case .collected:
            return uniqueTasks(items).filter { !$0.task.collected }
        case .important:
            return uniqueTasks(items).filter { !$0.task.important }
        case .list(let listID):
            return uniqueTasks(items).filter { $0.task.id3 != listID }
        default:
            return []
        }
    }

    /// 按任务去重，保留第一次出现的实例。
    static func uniqueTasks(_ items: [OccurrenceItem]) -> [OccurrenceItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.task.id1).inserted }
    }
}
