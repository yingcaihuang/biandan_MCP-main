import Foundation

/// ⌘Z 撤销需要的反向命令。撤销时执行反向业务操作写回云端，不做本地回滚。
enum UndoPlan {
    /// 把实例进度恢复到 `previous`（-1 已放弃；子任务模式下为 位掩码×100）。
    static func restoreProgress(_ id: String, previous: Int, target: Int) -> [OutboxCommand] {
        if previous < 0 { return [.changeProgress(id: id, action: .abandon, count: nil)] }
        if target >= 100 {
            let all = target / 100
            let bits = (previous / 100) & all
            if all != 0 && bits == all { return [.completeOccurrence(id: id)] }
            var commands: [OutboxCommand] = [.changeProgress(id: id, action: .reopen, count: nil)]
            for index in 0..<20 where bits & (1 << index) != 0 {
                commands.append(.setSubtask(id: id, index: index, checked: true))
            }
            return commands
        }
        if previous >= target { return [.completeOccurrence(id: id)] }
        if previous == 0 { return [.changeProgress(id: id, action: .reopen, count: nil)] }
        return [.changeProgress(id: id, action: .setCount, count: previous)]
    }

    /// 把一次性任务的日期恢复成 `task` 里的值；`restoreReminder` 时同时恢复时间提醒。
    static func restoreSchedule(_ task: TaskDef, restoreReminder: Bool = false) -> [OutboxCommand] {
        var commands: [OutboxCommand] = []
        if task.undated {
            commands.append(.clearSchedule(taskID: task.id1))
        } else if let start = task.startTime, LocalDate(iso: start) != nil {
            commands.append(.rescheduleTask(taskID: task.id1, start: start, end: task.endTime,
                                            startTime: task.validStartTime, endTime: task.validEndTime))
            if restoreReminder, task.isRemind & 1 != 0, let date = task.remindDate, let time = task.remindTime {
                commands.append(.setTimeReminder(taskID: task.id1, date: date, time: time, enabled: true))
            }
        }
        return commands
    }

    /// 按原来的开始时间重新补记一条被删除的专注（主键相同）。
    static func recreateFocus(_ record: FocusRecord, link: FocusLink?) -> FocusInput? {
        guard let started = record.startedAt, FocusCodec.validMinutes(record.minutes) != nil else { return nil }
        return FocusInput(startedAt: started, minutes: record.minutes, title: record.parsedLog.eventTitle,
                          goodCount: record.goodCount, badCount: record.badCount, link: link)
    }
}

extension AppModel {
    /// 登记一步可撤销的修改。撤销时自动登记重做，重做时再登记撤销。
    func registerUndo(_ label: String, undo: [OutboxCommand], redo: [OutboxCommand]) {
        guard let manager = undoManager, !undo.isEmpty, !redo.isEmpty else { return }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerUndo(label, undo: redo, redo: undo)
                Task { await model.runUndoCommands(label, undo) }
            }
        }
        manager.setActionName(label)
    }

    /// 依次执行反向命令；某一步失败（会有提示）时停下。
    func runUndoCommands(_ label: String, _ commands: [OutboxCommand]) async {
        for command in commands {
            guard await performQueued("撤销「\(label)」", command) else { return }
        }
    }
}
