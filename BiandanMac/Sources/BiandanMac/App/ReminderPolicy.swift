import Foundation
import UserNotifications

/// 提醒的默认规则：新建日程默认开提醒、没处理时追加提醒、改期时提醒跟着走、给已有日程补上提醒。
enum ReminderPolicy {
    /// 全天日程（没有具体时刻）默认在当天这个时刻提醒。
    static let allDayTime = LocalTime(hour: 9, minute: 0)!
    /// 第 1 次提醒之后没处理时，分别隔多少分钟再提醒：+15 分钟提醒第 2 次，再隔 1 小时提醒最后一次。
    static let followUpMinutes = [15, 75]

    /// 有开始日期、还没设提醒时，按开始时刻提醒；没有时刻的按当天 9:00。无日期任务不处理。
    static func fillDefault(_ input: inout CreateTaskInput) {
        guard let start = input.startDate, input.reminderDate == nil, input.reminderTime == nil else { return }
        input.reminderDate = start
        input.reminderTime = input.startTime ?? allDayTime
    }

    /// 任务默认的提醒时刻：有开始时刻用开始时刻，全天的用 9:00。
    static func defaultTime(_ task: TaskDef) -> LocalTime {
        guard let clock = task.startClock, clock != .startOfDay else { return allDayTime }
        return clock
    }

    struct Backfill: Equatable, Sendable {
        let taskID: String
        let date: LocalDate
        let time: LocalTime
    }

    /// 还没结束、也没开时间提醒的日程，要补上的提醒。
    /// 一次性任务按这次的开始日期；重复任务按系列开始日期（提醒时刻对每一次都生效）。
    static func backfill(_ snapshot: DataSnapshot, today: LocalDate) -> [Backfill] {
        var result: [Backfill] = []
        for task in snapshot.tasks.values where !task.completed && !task.hasTimeReminder && !task.undated {
            let pending = snapshot.occurrences(ofTask: task.id1).filter { $0.status == .pending }
            let ongoing = pending.contains { occurrence in
                (occurrence.endDate ?? occurrence.startDate).map { $0 >= today } ?? false
            }
            guard ongoing else { continue }
            let day = task.isRepeating ? task.startDate : pending.first?.startDate
            guard let day else { continue }
            result.append(Backfill(taskID: task.id1, date: day, time: defaultTime(task)))
        }
        return result.sorted { $0.taskID < $1.taskID }
    }

    /// 一次性日程改期后提醒的新日期和时刻：日期按改期的天数平移；原来按开始时刻提醒、又改了开始时刻的，时刻跟着走。
    /// 没开时间提醒、提醒读不出来或者不用变时返回 nil。
    static func shifted(_ task: TaskDef, oldStart: LocalDate?, newStart: LocalDate,
                        newStartTime: LocalTime?) -> (date: LocalDate, time: LocalTime)? {
        guard task.hasTimeReminder, let date = LocalDate(iso: task.remindDate),
              let time = LocalTime(text: task.remindTime) else { return nil }
        let days = oldStart.map { $0.days(to: newStart) } ?? 0
        var newTime = time
        if let newStartTime, let oldClock = task.startClock, oldClock == time { newTime = newStartTime }
        if days == 0 && newTime == time { return nil }
        return (date.adding(days: days), newTime)
    }
}

/// 在通知上点过「稍后提醒」的提醒串，之后不再追加。只保留最近 3 天的记录。
/// 系统的通知回调在后台线程，这里只用 UserDefaults（线程安全）。
enum ReminderAcknowledgements {
    static let key = "biandan.reminderAcknowledged"
    static let keepSeconds: TimeInterval = 3 * 86_400

    static func all(now: Date = Date()) -> Set<String> {
        Set(recent(now: now).keys)
    }

    static func mark(_ chainKey: String?, now: Date = Date()) {
        guard let chainKey, !chainKey.isEmpty else { return }
        var stored = recent(now: now)
        stored[chainKey] = now.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: key)
    }

    /// 撤掉这一串还没到点的追加提醒。
    static func cancelFollowUps(_ chainKey: String?) {
        guard let chainKey, !chainKey.isEmpty, ReminderScheduler.isAvailable else { return }
        let base = ReminderScheduler.prefix + chainKey
        let ids = (2...(ReminderPolicy.followUpMinutes.count + 1)).map { "\(base).f\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func recent(now: Date) -> [String: Double] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return stored.filter { now.timeIntervalSince1970 - $0.value < keepSeconds }
    }
}
