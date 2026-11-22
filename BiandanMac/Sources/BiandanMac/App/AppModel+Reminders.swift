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
        // 开发版遇到正式版也在运行时不排，免得同一条提醒弹两次。
        let active = remindersEnabled && authState == .signedIn && !ReminderScheduler.yieldsToRelease
        let requests = active
            ? ReminderPlanner.plan(snapshot, now: Date(), acknowledged: ReminderAcknowledgements.all()) : []
        reminders.schedule(requests) { [weak self] count in
            self?.scheduledReminderCount = count
        }
        // 稍后提醒只保留仍待完成的实例。
        var query = OccurrenceQuery()
        query.includeUndated = true
        let keep: Set<String> = remindersEnabled && authState == .signedIn
            ? Set(snapshot.items(query).map(\.id)) : []
        ReminderSnooze.prune(keeping: keep)
    }

    /// 重新读取系统通知授权（设置页打开、切回应用、点「重新检查」时调用）。
    func refreshReminderStatus() async {
        reminderStatus = await reminders.status()
        reminderCheckedAt = Date()
    }

    /// 向系统申请通知权限，并按结果给出下一步提示。
    func requestReminderAuthorization() async {
        let before = reminderStatus
        reminderStatus = await reminders.requestAuthorization()
        reminderCheckedAt = Date()
        switch reminderStatus {
        case .authorized:
            reminderNotice = "已获得通知授权。可以点「发送测试通知」确认能正常弹出。"
            scheduleReminders()
        case .silenced:
            reminderNotice = "已授权，但提醒样式为「无」，通知不会弹出。请按下面的步骤在系统设置中改为「横幅」。"
            scheduleReminders()
        case .denied:
            reminderNotice = before == .denied
                ? "系统不会再次弹出授权窗口，请按下面的步骤在系统设置中打开通知。"
                : "系统授权窗口中选择了「不允许」，可按下面的步骤在系统设置中重新打开。"
        case .notDetermined, .unavailable:
            break
        }
    }

    /// 发送测试通知，校验授权和提醒样式。
    func sendTestReminder() async {
        if let error = await reminders.sendTest() {
            reminderNotice = "测试通知发送失败：\(error)"
        } else {
            reminderNotice = "已发送测试通知，约 2 秒后应弹出横幅。没看到时，请检查是否开启了专注模式（勿扰）。"
        }
    }

    /// 设置页开关变化：打开时请求系统授权，再排定。
    func remindersToggled() {
        if remindersEnabled {
            Task {
                await requestReminderAuthorization()
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
        completeObserver = NotificationCenter.default.addObserver(
            forName: .biandanCompleteOccurrence, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainReminderInbox() }
        }
        drainReminderInbox()
        installWorkspaceObservers()
    }

    // MARK: 睡眠补发、正式版、补提醒

    /// 电脑睡眠 / 醒来、正式版启动 / 退出时重新处理提醒。
    private func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty, ReminderScheduler.isAvailable else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reminders.noteSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        if let release = ReminderScheduler.releaseBundleID {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                    guard bundle == release else { return }
                    MainActor.assumeIsolated { self?.scheduleReminders() }
                })
            }
        }
    }

    /// 醒来后先等几秒，让系统自己补发的先发出来，再补发还缺的，然后重新排定。
    private func handleWake() {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self.deliverMissedReminders()
            self.scheduleReminders()
        }
    }

    /// 补发电脑睡眠期间错过、日程也还没处理的提醒。
    func deliverMissedReminders() async {
        guard remindersEnabled, authState == .signedIn, !ReminderScheduler.yieldsToRelease else { return }
        var query = OccurrenceQuery()
        query.includeUndated = true
        let pending = Set(snapshot.items(query).map(\.id))
        _ = await reminders.deliverMissed(pending: pending, acknowledged: ReminderAcknowledgements.all())
    }

    /// 一次性给还没结束、也没开时间提醒的日程补上提醒（每个版本只做一次，结果同步到云端）。
    func backfillRemindersIfNeeded() {
        let key = "biandan.reminderBackfillDone"
        guard ReminderScheduler.isAvailable, remindersEnabled, authState == .signedIn, !DebugFlags.offline,
              snapshot.lastPulledAt != nil, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let plan = ReminderPolicy.backfill(snapshot, today: today)
        guard !plan.isEmpty else { return }
        Task {
            for item in plan {
                await self.setTimeReminder(item.taskID, date: item.date, time: item.time, enabled: true)
            }
            self.reminderNotice = "已给 \(plan.count) 个还没开提醒的日程补上了提醒。"
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

    /// 菜单栏图标旁的数字：今天的待办数（逾期的单独在主窗口「逾期」里）。
    var menuBarBadge: Int {
        snapshot.counts(today: today, weekStart: weekStart).today
    }

    /// 菜单栏列表：今天的待办（不含无日期和逾期）。
    func menuBarItems(limit: Int = 12) -> (items: [OccurrenceItem], total: Int) {
        let pending = snapshot.items(OccurrenceQuery())
        let current = pending.filter { $0.occurrence.overlaps(today, today) && !$0.isOverdue(today: today) }
        return (Array(current.prefix(limit)), current.count)
    }
}
