import AppKit
import Foundation
import UserNotifications

/// 一次番茄钟计时。暂停的时间不计入专注时长。
struct PomodoroSession: Equatable, Sendable {
    static let presets = [15, 25, 45, 60]

    var startedAt: Date
    var plannedMinutes: Int
    var title: String
    var link: FocusLink?
    var pausedAt: Date?
    var pausedSeconds: TimeInterval = 0

    init(startedAt: Date, plannedMinutes: Int, title: String, link: FocusLink?) {
        self.startedAt = startedAt
        self.plannedMinutes = max(plannedMinutes, 1)
        self.title = title
        self.link = link
    }

    var isPaused: Bool { pausedAt != nil }
    var plannedSeconds: TimeInterval { Double(plannedMinutes) * 60 }

    /// 已专注的秒数（不含暂停），最多到计划时长。
    func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return min(max(end.timeIntervalSince(startedAt) - pausedSeconds, 0), plannedSeconds)
    }

    func remaining(at now: Date) -> TimeInterval { plannedSeconds - elapsed(at: now) }
    func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }
    func progress(at now: Date) -> Double { elapsed(at: now) / plannedSeconds }

    /// 剩余时间占计划时长的比例（0…1）。
    func remainingFraction(at now: Date) -> Double { min(max(remaining(at: now) / plannedSeconds, 0), 1) }

    /// 按剩余比例分 4 段，每段 25%：0 = 剩 75% 以上，1 = 50–75%，2 = 25–50%，3 = 不到 25%。
    static func phase(remainingFraction fraction: Double) -> Int {
        if fraction > 0.75 { return 0 }
        if fraction > 0.5 { return 1 }
        if fraction > 0.25 { return 2 }
        return 3
    }

    mutating func pause(at now: Date) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        pausedSeconds += max(now.timeIntervalSince(pausedAt), 0)
        self.pausedAt = nil
    }

    /// 结束时补记的专注：计满记 1 个好番茄；提前结束按已专注的整分钟记 1 个中断。不足 1 分钟不记。
    func record(at now: Date, completed: Bool) -> FocusInput? {
        let minutes = completed ? plannedMinutes : Int(elapsed(at: now) / 60)
        guard minutes >= 1 else { return nil }
        return FocusInput(startedAt: startedAt, minutes: Double(minutes), title: title,
                          goodCount: completed ? 1 : 0, badCount: completed ? 0 : 1, link: link)
    }

    /// 倒计时文字，例如「24:59」。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum PomodoroNotifier {
    @MainActor
    static func notify(title: String, body: String) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        // SwiftPM 直接运行时没有 Bundle，不能调用通知中心。
        guard ReminderScheduler.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 不用提醒前缀，避免重新排定提醒时被清掉。
        let request = UNNotificationRequest(identifier: "biandan.pomodoro.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

extension AppModel {
    /// 列表里选中的待完成任务，番茄钟可以关联到它。
    var selectedPendingItem: OccurrenceItem? {
        guard let id = selectedOccurrenceID, let item = snapshot.item(occurrenceID: id),
              item.status == .pending else { return nil }
        return item
    }

    func startPomodoro(minutes: Int, item: OccurrenceItem?) {
        let link = item.map { FocusLink(occurrenceID: $0.id, listID: Int($0.task.id3) ?? 1, title: $0.task.taskTitle) }
        let name = item?.task.taskTitle ?? ""
        pomodoro = PomodoroSession(startedAt: Date(), plannedMinutes: minutes,
                                   title: name.isEmpty ? "专注" : name, link: link)
        startPomodoroTicker()
    }

    func pausePomodoro() { pomodoro?.pause(at: Date()) }
    func resumePomodoro() { pomodoro?.resume(at: Date()) }

    /// 放弃本次计时，不记录。
    func cancelPomodoro() {
        pomodoroTicker?.cancel()
        pomodoroTicker = nil
        pomodoro = nil
    }

    /// 结束计时并补记专注。`completed` 为 false 表示提前结束。
    func finishPomodoro(completed: Bool) async {
        guard let session = pomodoro else { return }
        let now = Date()
        cancelPomodoro()
        if completed {
            PomodoroNotifier.notify(title: "番茄钟结束",
                                    body: "「\(session.title)」专注了 \(session.plannedMinutes) 分钟，已记入专注记录。")
        }
        guard let input = session.record(at: now, completed: completed) else { return }
        await createFocus(input)
    }

    /// 后台检查是否到时，面板关着也能按时结束并补记。
    private func startPomodoroTicker() {
        pomodoroTicker?.cancel()
        pomodoroTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let session = self.pomodoro else { return }
                if !session.isPaused, session.isFinished(at: Date()) {
                    await self.finishPomodoro(completed: true)
                    return
                }
            }
        }
    }
}
