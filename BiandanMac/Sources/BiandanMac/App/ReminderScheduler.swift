import AppKit
import Foundation
import UserNotifications

/// 系统通知授权状态。
enum ReminderStatus: Equatable {
    /// 不是从打包后的 .app 运行（没有 Bundle ID），无法使用系统通知。
    case unavailable
    case notDetermined
    case denied
    case authorized
    /// 已授权，但提醒样式为「无」：通知会进通知中心，但不会弹出横幅。
    case silenced

    var title: String {
        switch self {
        case .unavailable: return "不可用"
        case .notDetermined: return "尚未授权"
        case .denied: return "已在系统设置中关闭"
        case .authorized: return "已授权"
        case .silenced: return "已授权，但横幅已关闭"
        }
    }

    /// 系统允许排定通知（包括横幅关闭的情况）。
    var isAuthorized: Bool { self == .authorized || self == .silenced }
}

/// 一条要排定的本地通知。
struct ReminderRequest: Hashable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
    let occurrenceID: String
}

/// 由快照算出要排定的时间提醒（纯计算，不访问系统接口）。
/// - 一次性任务：提醒日期 + 提醒时刻，要求还有未完成的执行实例。
/// - 重复任务：近 14 天内每个未完成实例的开始日期 + 提醒时刻（云端只存一个提醒时刻，这里按每次执行提醒）。
/// - 已过的时间、已完成的任务跳过；按时间排序后最多保留 60 条（系统上限 64 条）。
enum ReminderPlanner {
    static let limit = 60
    static let repeatingHorizonDays = 14

    static func fireDate(_ day: LocalDate, _ time: LocalTime, calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                           hour: time.hour, minute: time.minute))
    }

    static func plan(_ snapshot: DataSnapshot, now: Date, calendar: Calendar = .current) -> [ReminderRequest] {
        let today = LocalDate.today(now, calendar: calendar)
        let horizon = today.adding(days: repeatingHorizonDays)
        var result: [ReminderRequest] = []
        for task in snapshot.tasks.values where task.hasTimeReminder && !task.completed {
            guard let time = LocalTime(text: task.remindTime) else { continue }
            let pending = snapshot.occurrences(ofTask: task.id1).filter { $0.status == .pending }
            if task.isRepeating {
                for occurrence in pending {
                    guard let day = occurrence.startDate, day >= today, day <= horizon,
                          let fire = fireDate(day, time, calendar: calendar), fire > now else { continue }
                    result.append(request(task, occurrence, time, fire, snapshot))
                }
            } else {
                guard let occurrence = pending.first, let day = LocalDate(iso: task.remindDate),
                      let fire = fireDate(day, time, calendar: calendar), fire > now else { continue }
                result.append(request(task, occurrence, time, fire, snapshot))
            }
        }
        result.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        return Array(result.prefix(limit))
    }

    private static func request(_ task: TaskDef, _ occurrence: Occurrence, _ time: LocalTime, _ fire: Date,
                                _ snapshot: DataSnapshot) -> ReminderRequest {
        let list = snapshot.list(task.id3)?.displayName ?? "未分类"
        let remark = task.content.remark
            .split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var body = "\(time.shortText) · \(list)"
        if !remark.isEmpty { body += " · \(remark)" }
        let title = task.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReminderRequest(
            identifier: "\(ReminderScheduler.prefix)\(occurrence.id2).\(Int64(fire.timeIntervalSince1970))",
            title: title.isEmpty ? "便单提醒" : title,
            body: body, fireDate: fire, occurrenceID: occurrence.id2)
    }
}

/// 用 UNUserNotificationCenter 排定时间提醒。快照频繁刷新，这里合并 1.5 秒内的请求，计划没变就不动系统队列。
@MainActor
final class ReminderScheduler {
    nonisolated static let prefix = "biandan.reminder."

    /// SwiftPM 直接运行的可执行文件没有 Bundle，调用 UNUserNotificationCenter 会崩溃。
    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private var debounce: Task<Void, Never>?
    private var lastSignature: Int?

    nonisolated init() {}

    func status() async -> ReminderStatus {
        guard Self.isAvailable else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let base = Self.map(settings.authorizationStatus)
        if base == .authorized && settings.alertSetting == .disabled { return .silenced }
        return base
    }

    /// 发送一条约 2 秒后弹出的测试通知，用来确认授权和提醒样式。失败时返回原因。
    func sendTest() async -> String? {
        guard Self.isAvailable else { return "当前不是从打包后的 便单.app 运行。" }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard Self.map(settings.authorizationStatus) == .authorized else { return "尚未获得通知授权。" }
        let content = UNMutableNotificationContent()
        content.title = "便单测试通知"
        content.body = "收到这条通知，说明时间提醒可以正常弹出。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        // 不用提醒前缀，避免重新排定时被清掉。
        let request = UNNotificationRequest(identifier: "biandan.test.\(UUID().uuidString)", content: content, trigger: trigger)
        do {
            try await center.add(request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func requestAuthorization() async -> ReminderStatus {
        guard Self.isAvailable else { return .unavailable }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await status()
    }

    private static func map(_ status: UNAuthorizationStatus) -> ReminderStatus {
        switch status {
        case .authorized, .provisional: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// 排定新的计划（空数组表示清除全部便单提醒）。完成后回调实际排定的条数。
    func schedule(_ requests: [ReminderRequest], completion: @escaping @MainActor (Int) -> Void) {
        guard Self.isAvailable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            let count = await self.apply(requests)
            completion(count)
        }
    }

    private func apply(_ requests: [ReminderRequest]) async -> Int {
        let center = UNUserNotificationCenter.current()
        var hasher = Hasher()
        hasher.combine(requests)
        let signature = hasher.finalize()
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.prefix) }
        if signature == lastSignature && existing.count == requests.count { return requests.count }
        if !existing.isEmpty { center.removePendingNotificationRequests(withIdentifiers: existing) }
        lastSignature = signature
        guard !requests.isEmpty else { return 0 }
        let settings = await center.notificationSettings()
        guard Self.map(settings.authorizationStatus) == .authorized else {
            lastSignature = nil
            return 0
        }
        var added = 0
        for item in requests {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = "biandan.reminder"
            content.userInfo = ["occurrenceID": item.occurrenceID]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger))
                added += 1
            } catch {
                continue
            }
        }
        return added
    }
}
