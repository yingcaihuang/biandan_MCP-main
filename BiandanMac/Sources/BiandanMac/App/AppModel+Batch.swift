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
        if flags.contains(.shift) {
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

    // MARK: - 批量操作

    func batchComplete() async {
        let targets = batchItems.filter { $0.status == .pending }
        await batch("完成", targets) { await self.toggleCompletion($0) }
    }

    func batchAbandon() async {
        let targets = batchItems.filter { $0.status == .pending }
        await batch("放弃", targets) { await self.abandon($0) }
    }

    /// 改期到某一天：保留各自的持续天数和时刻；重复任务只改这一次。
    func batchReschedule(to day: LocalDate) async {
        let targets = batchItems.filter { $0.status == .pending }
        await batch("改期", targets) { item in
            var span = 0
            if !item.task.undated, let start = item.occurrence.startDate, let end = item.occurrence.endDate {
                span = max(start.days(to: end), 0)
            }
            await self.reschedule(item, start: day, end: day.adding(days: span), startTime: nil, endTime: nil)
        }
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
        registerUndoNow("批量\(label)（\(steps.count) 项）", undo: plan.undo, redo: plan.redo)
    }
}

enum BatchPlan {
    /// 按任务去重，保留第一次出现的实例。
    static func uniqueTasks(_ items: [OccurrenceItem]) -> [OccurrenceItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.task.id1).inserted }
    }
}
