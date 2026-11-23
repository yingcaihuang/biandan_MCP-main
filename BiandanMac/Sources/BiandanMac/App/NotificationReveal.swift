import Foundation

// MARK: - 点通知打开对应的日程
//
// 点通知时先把要打开的位置记进 ReminderInbox：应用可能刚被通知拉起，登录状态还没读完、数据还没加载。
// 登录后、每次同步完都会再处理一次；本机找不到这条时等同步完再试，超过 2 分钟就不再自动跳转。
// 按日程现在的状态切到能看到它的分类（逾期 / 已完成 / 已放弃 / 全部待办），清掉搜索，选中、打开详情并滚到这一条。

/// 点通知要打开的位置。
enum RevealTarget: Equatable, Sendable {
    case occurrence(String)
    case importer
}

/// 让列表滚到这一条；token 不同，同一条也能再滚一次。
struct RevealRequest: Equatable {
    let id: String
    let token = UUID()
}

enum RevealPlan {
    /// 点通知后最多等这么久（登录、同步），过了就不再自动跳转，免得很久以后界面突然切走。
    static let maxWait: TimeInterval = 120

    /// 能看到这条日程的侧栏分类：逾期的只在「逾期」里，已放弃的不在「全部待办」里。
    static func sidebar(status: OccurrenceStatus, overdue: Bool) -> SidebarItem {
        switch status {
        case .completed: return .completed
        case .abandoned: return .abandoned
        case .pending: return overdue ? .overdue : .all
        }
    }

    static func isExpired(since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return true }
        return now.timeIntervalSince(since) > maxWait
    }
}

extension ReminderInbox {
    static func reveal(_ target: RevealTarget, at date: Date = Date()) {
        pendingReveal = target
        pendingRevealAt = date
    }
}

extension AppModel {
    /// 打开主窗口并定位到某次执行（通知点击、菜单栏都用这个）。
    func revealOccurrence(_ id: String?) {
        showMainWindow()
        guard let id else { return }
        ReminderInbox.reveal(.occurrence(id))
        drainPendingReveal()
    }

    /// 处理记下的跳转。登录前不处理；本机找不到这条时，同步完（afterSync）还找不到就放弃。
    func drainPendingReveal(afterSync: Bool = false) {
        guard let target = ReminderInbox.pendingReveal else { return }
        if RevealPlan.isExpired(since: ReminderInbox.pendingRevealAt) {
            ReminderInbox.pendingReveal = nil
            return
        }
        guard authState == .signedIn else { return }
        switch target {
        case .importer:
            ReminderInbox.pendingReveal = nil
            showMainWindow()
            sidebarSelection = .importer
        case .occurrence(let id):
            guard let item = snapshot.item(occurrenceID: id) else {
                if afterSync {
                    ReminderInbox.pendingReveal = nil
                    operationError = "找不到通知里的这条日程，可能已经被删除。"
                }
                return
            }
            ReminderInbox.pendingReveal = nil
            showMainWindow()
            focusOccurrence(item)
        }
    }

    /// 切到能看到这条的分类，清掉搜索，选中、打开详情并滚到这一条。
    func focusOccurrence(_ item: OccurrenceItem) {
        searchText = ""
        multiSelection = []
        selectedFocusID = nil
        sidebarSelection = RevealPlan.sidebar(status: item.status, overdue: item.isOverdue(today: today))
        viewMode = .list
        selectedOccurrenceID = item.id
        showInspector = true
        revealRequest = RevealRequest(id: item.id)
        let id = item.id
        // 刚切换分类、主窗口刚打开时列表还没排好，稍后再滚一次；之后清掉，免得以后切回列表又跳过去。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.selectedOccurrenceID == id else { return }
            self.revealRequest = RevealRequest(id: id)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.revealRequest?.id == id { self.revealRequest = nil }
        }
    }
}
