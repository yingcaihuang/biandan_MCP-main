import Foundation
import UserNotifications

/// 提醒通知上的操作按钮：完成、放弃本次、10 分钟后提醒、1 小时后提醒。
enum ReminderAction: String, CaseIterable, Sendable {
    case complete = "biandan.action.complete"
    case abandon = "biandan.action.abandon"
    case snooze10 = "biandan.action.snooze10"
    case snooze60 = "biandan.action.snooze60"

    static let categoryID = "biandan.reminder.category"
    /// 稍后提醒的标识前缀。与 ReminderScheduler.prefix 不同，重排提醒时不会被清掉。
    static let snoozePrefix = "biandan.snooze."

    var title: String {
        switch self {
        case .complete: return "完成"
        case .abandon: return "放弃本次"
        case .snooze10: return "10 分钟后提醒"
        case .snooze60: return "1 小时后提醒"
        }
    }

    var snoozeSeconds: TimeInterval? {
        switch self {
        case .complete, .abandon: return nil
        case .snooze10: return 600
        case .snooze60: return 3600
        }
    }

    /// 都在后台执行，不把应用切到前台。
    static func category() -> UNNotificationCategory {
        // 「放弃本次」用红字，免得误点。
        let actions = allCases.map {
            UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: $0 == .abandon ? [.destructive] : [])
        }
        return UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: [])
    }

    /// 每个执行实例只保留一条稍后提醒：再按一次会替换上一条。
    static func snoozeIdentifier(_ occurrenceID: String) -> String { snoozePrefix + occurrenceID }

    static func occurrenceID(fromSnooze identifier: String) -> String? {
        guard identifier.hasPrefix(snoozePrefix) else { return nil }
        let id = String(identifier.dropFirst(snoozePrefix.count))
        return id.isEmpty ? nil : id
    }

    /// 对应实例已经不在待完成列表里的稍后提醒。
    static func staleSnoozes(_ identifiers: [String], keeping ids: Set<String>) -> [String] {
        identifiers.filter { identifier in
            occurrenceID(fromSnooze: identifier).map { !ids.contains($0) } ?? false
        }
    }
}

/// 稍后提醒的系统调用。都是 nonisolated 静态方法：系统回调在后台线程，不能带主线程隔离。
enum ReminderSnooze {
    /// 按原通知内容在 seconds 秒后再提醒一次。
    static func schedule(_ original: UNNotificationContent, after seconds: TimeInterval,
                         completion: @escaping @Sendable () -> Void) {
        guard let content = original.mutableCopy() as? UNMutableNotificationContent else {
            completion()
            return
        }
        content.categoryIdentifier = ReminderAction.categoryID
        content.subtitle = "稍后提醒"
        let occurrenceID = content.userInfo["occurrenceID"] as? String ?? UUID().uuidString
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: ReminderAction.snoozeIdentifier(occurrenceID),
                                            content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in completion() }
    }

    /// 实例完成后撤掉它的稍后提醒。
    static func cancel(_ occurrenceID: String) {
        guard ReminderScheduler.isAvailable else { return }
        let id = ReminderAction.snoozeIdentifier(occurrenceID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// 完成或放弃后，把这一次留在通知中心里的提醒（第 1 次、追加的、稍后提醒）一起清掉。
    static func clearDelivered(_ occurrenceID: String) {
        guard ReminderScheduler.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes
                .filter { ($0.request.content.userInfo["occurrenceID"] as? String) == occurrenceID }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// 删掉对应实例已完成、已删除的稍后提醒。
    static func prune(keeping ids: Set<String>) {
        guard ReminderScheduler.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = ReminderAction.staleSnoozes(requests.map(\.identifier), keeping: ids)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        }
    }
}

/// 通知上点「完成」时先记在这里；应用刚被通知拉起、还没读完登录状态时，等登录后再处理。
@MainActor
enum ReminderInbox {
    static var pendingComplete: [String] = []
    /// 通知上点了「放弃本次」的实例，处理方式同上。
    static var pendingAbandon: [String] = []
    /// 点通知要打开的位置（见 NotificationReveal.swift），登录、加载完再处理。
    static var pendingReveal: RevealTarget?
    static var pendingRevealAt: Date?
}

extension Notification.Name {
    /// 通知上点了「完成」或「放弃本次」，待处理的实例在 ReminderInbox 里。
    static let biandanCompleteOccurrence = Notification.Name("biandan.completeOccurrence")
}

extension AppModel {
    /// 处理通知上点的「完成」「放弃本次」。未登录（含启动时读取凭据期间）时保留，登录后再处理。
    func drainReminderInbox() {
        guard authState == .signedIn else { return }
        let completes = ReminderInbox.pendingComplete
        let abandons = ReminderInbox.pendingAbandon
        guard !completes.isEmpty || !abandons.isEmpty else { return }
        ReminderInbox.pendingComplete = []
        ReminderInbox.pendingAbandon = []
        for id in completes { completeFromNotification(id) }
        for id in abandons { abandonFromNotification(id) }
    }

    /// 后台完成这一次（不打开主窗口），撤掉它的稍后提醒、清掉通知中心里同一次的提醒。已完成或找不到时只撤提醒。
    func completeFromNotification(_ id: String) {
        ReminderSnooze.cancel(id)
        ReminderSnooze.clearDelivered(id)
        guard let item = snapshot.item(occurrenceID: id), item.status == .pending else { return }
        Task { await toggleCompletion(item) }
    }

    /// 后台放弃这一次（重复日程只放弃这一次，可以 ⌘Z 撤销），其余同「完成」。
    func abandonFromNotification(_ id: String) {
        ReminderSnooze.cancel(id)
        ReminderSnooze.clearDelivered(id)
        guard let item = snapshot.item(occurrenceID: id), item.status == .pending else { return }
        Task { await abandon(item) }
    }
}
