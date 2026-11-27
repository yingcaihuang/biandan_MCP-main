import AppKit
import Foundation
import UserNotifications

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

    /// 逐个删除：重复任务只删这一次，一次性任务连同定义删除。确认框点了就关，删除在后台进行，
    /// 底部显示「正在删除 n/总数」，做完（数量多或有失败时）发系统通知。全部成功返回 true。
    @discardableResult
    func batchDelete(_ items: [OccurrenceItem]? = nil) async -> Bool {
        let targets = items ?? batchItems
        guard !targets.isEmpty, beginBatch("删除", total: targets.count) else { return false }
        // 整批交给服务层一次处理：执行实例表只拉一次，逐项返回结果。
        let requests = targets.map { item -> BatchDeleteTarget in
            let repeating = item.task.isRepeating
            return BatchDeleteTarget(taskID: item.task.id1, scope: repeating ? .occurrence : nil,
                                     occurrenceID: repeating ? item.id : nil, fromDate: nil)
        }
        let reporter = batchProgressReporter()
        let results = await perform("删除任务") { service in
            try await service.deleteTasks(requests, progress: reporter)
        }
        var processed = batchProgress?.done ?? 0
        var failed = 0
        var firstError: String?
        if let results {
            let errors = results.compactMap { $0 }
            failed = errors.count
            firstError = errors.first
        } else {
            // 整批中断（登录失效、读不到实例表等）：已处理之后的都算没成功。
            failed = max(targets.count - processed, 0)
            firstError = operationError
            processed = targets.count
        }
        batchProgress = nil
        if let selected = selectedOccurrenceID, snapshot.item(occurrenceID: selected) == nil {
            selectedOccurrenceID = nil
        }
        multiSelection = multiSelection.filter { snapshot.item(occurrenceID: $0) != nil }
        finishBatch("删除", total: targets.count, processed: processed, failed: failed, error: firstError)
        return failed == 0 && processed == targets.count
    }

    /// 依次执行，期间暂存各步撤销，最后合并登记成一步。
    private func batch(_ label: String, _ items: [OccurrenceItem],
                       _ action: (OccurrenceItem) async -> Void) async {
        guard !items.isEmpty, beginBatch(label, total: items.count) else { return }
        undoCollector = []
        for item in items {
            guard authState == .signedIn else { break }
            await action(item)
            batchProgress?.done += 1
        }
        let processed = batchProgress?.done ?? 0
        batchProgress = nil
        let steps = undoCollector ?? []
        undoCollector = nil
        finishBatch(label, total: items.count, processed: processed, failed: 0, error: nil)
        guard !steps.isEmpty else { return }
        let plan = UndoPlan.combine(steps)
        let name = steps.count == 1 ? label : "批量\(label)（\(steps.count) 项）"
        registerUndoNow(name, undo: plan.undo, redo: plan.redo)
    }

    /// 服务层在后台回报进度，切回主线程更新底部进度条。
    func batchProgressReporter() -> @Sendable (Int, Int) async -> Void {
        { [weak self] done, count in
            await self?.reportBatchProgress(done, total: count)
        }
    }

    /// 服务层回报的进度（删除分类等一次调用里逐条写云端的操作）。
    func reportBatchProgress(_ done: Int, total: Int) {
        guard batchProgress != nil else { return }
        // 并发写入时回调可能乱序到达：进度只往前走。
        batchProgress?.done = max(batchProgress?.done ?? 0, done)
        if total > 0 { batchProgress?.total = total }
    }

    /// 同一时间只跑一批，免得两批操作改同一批任务。
    func beginBatch(_ label: String, total: Int) -> Bool {
        if let running = batchProgress {
            operationError = "上一批「\(running.label)」还没做完（\(running.done)/\(running.total)），请稍后再试"
            return false
        }
        batchProgress = BatchProgress(label: label, total: total)
        return true
    }

    private func finishBatch(_ label: String, total: Int, processed: Int, failed: Int, error: String?) {
        guard let message = BatchNotifier.message(label: label, total: total, processed: processed,
                                                  failed: failed, error: error) else { return }
        BatchNotifier.notify(title: message.title, body: message.body)
    }
}

/// 后台批量操作的进度。
struct BatchProgress: Equatable, Sendable {
    let label: String
    var done = 0
    var total: Int
    var failed = 0
}

/// 删除分类在后台进行时的进度文字和做完后的通知。
enum ListDeleteNotice {
    /// 进度条显示为「正在」+ 这段文字。
    static func label(name: String, deleteTasks: Bool) -> String {
        deleteTasks ? "删除「\(name)」的任务" : "把「\(name)」的任务移回未分类"
    }

    /// 成功且任务少于阈值时不通知；失败一定通知。
    static func message(name: String, deleteTasks: Bool, total: Int, done: Int, ok: Bool,
                        error: String?) -> (title: String, body: String)? {
        if !ok {
            let reason = (error ?? "").isEmpty ? "" : "：\(error ?? "")"
            return ("删除分类没完成", "「\(name)」已处理 \(done)/\(total) 个任务\(reason)。可以同步后再删一次。")
        }
        guard total >= BatchNotifier.threshold else { return nil }
        let body = deleteTasks ? "「\(name)」和其中 \(total) 个任务已删除"
                               : "「\(name)」已删除，\(total) 个任务已移回「未分类」"
        return ("分类已删除", body)
    }
}

/// 批量操作做完后的系统通知。
enum BatchNotifier {
    /// 少于这么多项、又都成功时不通知，免得小操作也弹窗。
    static let threshold = 10

    static func message(label: String, total: Int, processed: Int, failed: Int,
                        error: String?) -> (title: String, body: String)? {
        let interrupted = processed < total
        guard total >= threshold || failed > 0 || interrupted else { return nil }
        var parts = ["成功 \(max(processed - failed, 0)) 项"]
        if failed > 0 {
            var text = "\(failed) 项没成功"
            if let error, !error.isEmpty { text += "（\(error)）" }
            parts.append(text)
        }
        if interrupted { parts.append("\(total - processed) 项因为登录失效没有处理") }
        let title = failed == 0 && !interrupted ? "批量操作已完成" : "批量操作有部分没成功"
        return (title, "\(label) \(total) 项：" + parts.joined(separator: "，"))
    }

    @MainActor
    static func notify(title: String, body: String) {
        // SwiftPM 直接运行时没有 Bundle，不能调用通知中心。
        guard ReminderScheduler.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "biandan.batch.\(UUID().uuidString)", content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
