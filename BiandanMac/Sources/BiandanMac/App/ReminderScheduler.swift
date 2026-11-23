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
    /// 同一串提醒（第 1 次和没处理时追加的）共用：执行实例 ID + 第 1 次提醒的时刻。
    var chainKey: String = ""
    /// 1 是第 1 次；2、3 是没处理时追加的。
    var attempt: Int = 1
    /// 提醒声音，排提醒前按「提醒声音」设置填（见 AppModel.reminderWithSound）。
    var sound: ReminderSoundChoice = .systemDefault

    var subtitle: String {
        switch attempt {
        case 1: return ""
        case ReminderPolicy.followUpMinutes.count + 1: return "最后一次提醒"
        default: return "第 \(attempt) 次提醒"
        }
    }

    /// 没处理时追加的第 attempt 次提醒。
    func followUp(_ attempt: Int, at date: Date) -> ReminderRequest {
        ReminderRequest(identifier: "\(identifier).f\(attempt)", title: title, body: body, fireDate: date,
                        occurrenceID: occurrenceID, chainKey: chainKey, attempt: attempt)
    }
}

/// 由快照算出要排定的时间提醒（纯计算，不访问系统接口）。
/// - 一次性任务：提醒日期 + 提醒时刻，要求还有未完成的执行实例。
/// - 重复任务：近 14 天内每个未完成实例的开始日期 + 提醒时刻（云端只存一个提醒时刻，这里按每次执行提醒）。
/// - 第 1 次之后没处理的，按 ReminderPolicy.followUpMinutes 追加；完成、放弃、改期后快照变了，追加的随之撤掉。
/// - 已过的时间、已完成的任务跳过；按时间排序后最多保留 60 条（系统上限 64 条）。
enum ReminderPlanner {
    static let limit = 60
    static let repeatingHorizonDays = 14

    static func fireDate(_ day: LocalDate, _ time: LocalTime, calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                           hour: time.hour, minute: time.minute))
    }

    /// acknowledged：点过「稍后提醒」的提醒串（chainKey），不再追加。
    static func plan(_ snapshot: DataSnapshot, now: Date, acknowledged: Set<String> = [],
                     calendar: Calendar = .current) -> [ReminderRequest] {
        let today = LocalDate.today(now, calendar: calendar)
        // 前一天深夜的提醒，追加的可能落在今天。
        let earliest = today.adding(days: -1)
        let horizon = today.adding(days: repeatingHorizonDays)
        var result: [ReminderRequest] = []
        for task in snapshot.tasks.values where task.hasTimeReminder && !task.completed {
            guard let time = LocalTime(text: task.remindTime) else { continue }
            let pending = snapshot.occurrences(ofTask: task.id1).filter { $0.status == .pending }
            if task.isRepeating {
                for occurrence in pending {
                    guard let day = occurrence.startDate, day >= earliest, day <= horizon,
                          let fire = fireDate(day, time, calendar: calendar) else { continue }
                    result += chain(request(task, occurrence, time, fire, snapshot), now: now, acknowledged: acknowledged)
                }
            } else {
                guard let occurrence = pending.first, let day = LocalDate(iso: task.remindDate),
                      let fire = fireDate(day, time, calendar: calendar) else { continue }
                result += chain(request(task, occurrence, time, fire, snapshot), now: now, acknowledged: acknowledged)
            }
        }
        result.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        return Array(result.prefix(limit))
    }

    /// 第 1 次提醒和没处理时追加的几次，只留还没到点的。
    static func chain(_ first: ReminderRequest, now: Date, acknowledged: Set<String>) -> [ReminderRequest] {
        var result: [ReminderRequest] = []
        if first.fireDate > now { result.append(first) }
        guard !acknowledged.contains(first.chainKey) else { return result }
        for (index, minutes) in ReminderPolicy.followUpMinutes.enumerated() {
            let date = first.fireDate.addingTimeInterval(TimeInterval(minutes * 60))
            if date > now { result.append(first.followUp(index + 2, at: date)) }
        }
        return result
    }

    /// 电脑睡眠期间（since 到 now）到点的提醒：每串只取最晚到点的一条，它已经发出来了就不补。
    static func missed(_ plan: [ReminderRequest], since: Date, now: Date, delivered: Set<String>,
                       acknowledged: Set<String>) -> [ReminderRequest] {
        var latest: [String: ReminderRequest] = [:]
        for item in plan where item.fireDate > since && item.fireDate <= now && !acknowledged.contains(item.chainKey) {
            if let current = latest[item.chainKey], current.fireDate >= item.fireDate { continue }
            latest[item.chainKey] = item
        }
        return latest.values
            .filter { !delivered.contains($0.identifier) }
            .sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
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
        let key = "\(occurrence.id2).\(Int64(fire.timeIntervalSince1970))"
        return ReminderRequest(
            identifier: "\(ReminderScheduler.prefix)\(key)",
            title: title.isEmpty ? "便单提醒" : title,
            body: body, fireDate: fire, occurrenceID: occurrence.id2, chainKey: key)
    }
}

/// 用 UNUserNotificationCenter 排定时间提醒。快照频繁刷新，这里合并 1.5 秒内的请求，计划没变就不动系统队列。
@MainActor
final class ReminderScheduler {
    nonisolated static let prefix = "biandan.reminder."
    /// 睡眠醒来后补发的提醒。不用 prefix，重新排定时不会被清掉。
    nonisolated static let latePrefix = "biandan.late."

    /// SwiftPM 直接运行的可执行文件没有 Bundle，调用 UNUserNotificationCenter 会崩溃。
    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// 开发版的 Bundle ID 以 .dev 结尾，去掉后就是正式版的；正式版返回 nil。
    nonisolated static var releaseBundleID: String? {
        guard let id = Bundle.main.bundleIdentifier, id.hasSuffix(".dev") else { return nil }
        return String(id.dropLast(".dev".count))
    }

    /// 开发版发现正式版也在运行时不排提醒，免得同一条提醒两个版本各弹一次。
    nonisolated static var yieldsToRelease: Bool {
        guard let release = releaseBundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: release).isEmpty
    }

    private var debounce: Task<Void, Never>?
    private var lastSignature: Int?
    /// 最近排进系统的计划（已经到点的保留一天），醒来后据此补发睡眠期间错过的提醒。
    private(set) var lastPlan: [ReminderRequest] = []
    private var sleptAt: Date?
    /// 已经合成好的声音文件名；本次排定用到的文件，排完后其余的清掉。
    private var renderedSounds: [ReminderSoundSpec: String] = [:]
    private var usedSounds: Set<String> = []

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

    /// 电脑要睡眠了：记下时间，醒来后补发这段时间里错过的提醒。
    func noteSleep(at date: Date = Date()) {
        sleptAt = date
    }

    /// 醒来后补发睡眠期间到点、系统没发出来、日程也还没处理的提醒（每串只补最晚的一条）。返回补发的条数。
    func deliverMissed(pending: Set<String>, acknowledged: Set<String>, now: Date = Date()) async -> Int {
        guard Self.isAvailable, let since = sleptAt else { return 0 }
        sleptAt = nil
        let center = UNUserNotificationCenter.current()
        let delivered = Set(await center.deliveredNotifications().map(\.request.identifier))
        let missed = ReminderPlanner.missed(lastPlan, since: since, now: now, delivered: delivered,
                                            acknowledged: acknowledged)
            .filter { pending.contains($0.occurrenceID) }
        var added = 0
        for item in missed {
            let content = await self.content(item)
            content.subtitle = item.attempt == 1 ? "电脑睡眠时错过的提醒" : "\(item.subtitle) · 电脑睡眠时错过"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let id = "\(Self.latePrefix)\(item.identifier.dropFirst(Self.prefix.count))"
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                added += 1
            } catch {
                continue
            }
        }
        return added
    }

    /// 记下排进系统的计划；已经到点的保留一天，补发时要用。
    private func remember(_ requests: [ReminderRequest], now: Date) {
        let ids = Set(requests.map(\.identifier))
        let due = lastPlan.filter {
            $0.fireDate <= now && $0.fireDate > now.addingTimeInterval(-86_400) && !ids.contains($0.identifier)
        }
        lastPlan = due + requests
    }

    /// 通知内容；声音按设置合成，失败时用系统默认。
    private func content(_ item: ReminderRequest) async -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = item.subtitle
        content.body = item.body
        content.sound = await sound(item.sound)
        content.threadIdentifier = "biandan.reminder"
        content.categoryIdentifier = ReminderAction.categoryID
        content.userInfo = ["occurrenceID": item.occurrenceID, "chainKey": item.chainKey]
        return content
    }

    private func sound(_ choice: ReminderSoundChoice) async -> UNNotificationSound {
        guard case .rendered(let spec) = choice else { return .default }
        if let name = renderedSounds[spec],
           FileManager.default.fileExists(atPath: ReminderSoundSynth.directory.appendingPathComponent(name).path) {
            usedSounds.insert(name)
            return UNNotificationSound(named: UNNotificationSoundName(name))
        }
        do {
            let name = try await Task.detached { try ReminderSoundSynth.render(spec) }.value
            renderedSounds[spec] = name
            usedSounds.insert(name)
            return UNNotificationSound(named: UNNotificationSoundName(name))
        } catch {
            return .default
        }
    }

    private func apply(_ requests: [ReminderRequest]) async -> Int {
        remember(requests, now: Date())
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
        usedSounds = []
        guard !requests.isEmpty else {
            ReminderSoundSynth.prune(keeping: [])
            return 0
        }
        let settings = await center.notificationSettings()
        guard Self.map(settings.authorizationStatus) == .authorized else {
            lastSignature = nil
            return 0
        }
        var added = 0
        for item in requests {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            do {
                let content = await content(item)
                try await center.add(UNNotificationRequest(identifier: item.identifier, content: content,
                                                           trigger: trigger))
                added += 1
            } catch {
                continue
            }
        }
        ReminderSoundSynth.prune(keeping: usedSounds)
        return added
    }
}
