import AppKit
import Foundation

extension Notification.Name {
    /// 点击时间提醒通知：userInfo["occurrenceID"] 为要选中的执行实例。
    static let biandanOpenOccurrence = Notification.Name("biandan.openOccurrence")
}

/// 时间提醒通知、菜单栏数据与主窗口唤起。
extension AppModel {
    // MARK: 时间提醒

    /// 按当前快照重新排定提醒。未启用或已退出登录时清除全部便单提醒；启动时读取凭据期间不处理。
    func scheduleReminders() {
        guard ReminderScheduler.isAvailable, authState != .checking else { return }
        let requests = remindersEnabled && authState == .signedIn
            ? ReminderPlanner.plan(snapshot, now: Date()) : []
        reminders.schedule(requests) { [weak self] count in
            self?.scheduledReminderCount = count
        }
    }

    func refreshReminderStatus() async {
        reminderStatus = await reminders.status()
    }

    /// 设置页开关变化：打开时请求系统授权，再排定。
    func remindersToggled() {
        if remindersEnabled {
            Task {
                reminderStatus = await reminders.requestAuthorization()
                scheduleReminders()
            }
        } else {
            scheduleReminders()
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 监听通知点击（由 AppDelegate 转发），主窗口关闭时也能处理。
    func installReminderObserver() {
        guard revealObserver == nil else { return }
        revealObserver = NotificationCenter.default.addObserver(
            forName: .biandanOpenOccurrence, object: nil, queue: .main
        ) { [weak self] note in
            let id = note.userInfo?["occurrenceID"] as? String
            MainActor.assumeIsolated { self?.revealOccurrence(id) }
        }
    }

    // MARK: 主窗口

    /// 打开（或切到）主窗口并激活应用。
    func showMainWindow() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 打开主窗口并在列表中选中某次执行。
    func revealOccurrence(_ id: String?) {
        showMainWindow()
        guard let id, authState == .signedIn, snapshot.item(occurrenceID: id) != nil else { return }
        sidebarSelection = .all
        viewMode = .list
        selectedOccurrenceID = id
        showInspector = true
    }

    // MARK: 菜单栏

    /// 菜单栏图标旁的数字：今天 + 逾期的待办数。
    var menuBarBadge: Int {
        let counts = snapshot.counts(today: today, weekStart: weekStart)
        return counts.today + counts.overdue
    }

    /// 菜单栏列表：逾期在前，然后是今天的待办（不含无日期）。
    func menuBarItems(limit: Int = 12) -> (items: [OccurrenceItem], total: Int) {
        let pending = snapshot.items(OccurrenceQuery())
        let overdue = pending.filter { $0.isOverdue(today: today) }
        let current = pending.filter { $0.occurrence.overlaps(today, today) }
        let all = overdue + current
        return (Array(all.prefix(limit)), all.count)
    }
}
