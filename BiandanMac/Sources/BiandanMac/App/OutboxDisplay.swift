import Foundation

/// 待同步命令作用的对象，用来在队列明细里显示任务标题或分类名。
enum OutboxTarget: Equatable {
    case task(String), occurrence(String), list(String), focus
}

extension OutboxCommand {
    var target: OutboxTarget {
        switch self {
        case .completeOccurrence(let id): return .occurrence(id)
        case .changeProgress(let id, _, _): return .occurrence(id)
        case .setSubtask(let id, _, _): return .occurrence(id)
        case .rescheduleOccurrence(let id, _, _, _): return .occurrence(id)
        case .updateTask(let taskID, _, _, _, _, _): return .task(taskID)
        case .moveTask(let taskID, _): return .task(taskID)
        case .setTimeReminder(let taskID, _, _, _): return .task(taskID)
        case .setLocation(let taskID, _, _, _, _): return .task(taskID)
        case .clearLocation(let taskID): return .task(taskID)
        case .rescheduleTask(let taskID, _, _, _, _): return .task(taskID)
        case .clearSchedule(let taskID): return .task(taskID)
        case .editGoal(let taskID, _, _): return .task(taskID)
        case .updateList(let listID, _, _, _): return .list(listID)
        case .createFocus, .updateFocus, .deleteFocus: return .focus
        }
    }
}

enum OutboxDisplay {
    /// 入队时间：今天只显示时刻，其余带日期；解析不了时原样返回。
    static func time(_ iso: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 「入队 13:30 · 已尝试 2 次 · 待同步」
    static func detail(_ entry: OutboxEntry, now: Date = Date()) -> String {
        let state = entry.state == OutboxEntry.failed ? "已放弃" : "待同步"
        let parts = ["入队 " + time(entry.createdAt, now: now), "已尝试 \(entry.attempts) 次", state]
        return parts.joined(separator: " · ")
    }
}

extension AppModel {
    /// 这条修改对应的任务标题、分类名或「专注记录」；对象已不在本地时为 nil。
    func outboxSubject(_ entry: OutboxEntry) -> String? {
        guard let command = entry.payload?.command else { return nil }
        func named(_ title: String) -> String { title.isEmpty ? "（无标题）" : title }
        switch command.target {
        case .task(let id): return snapshot.tasks[id].map { named($0.taskTitle) }
        case .occurrence(let id): return snapshot.item(occurrenceID: id).map { named($0.task.taskTitle) }
        case .list(let id): return snapshot.list(id)?.displayName
        case .focus: return "专注记录"
        }
    }
}
