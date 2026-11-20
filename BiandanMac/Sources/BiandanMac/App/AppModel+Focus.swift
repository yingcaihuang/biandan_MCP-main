import Foundation

extension AppModel {
    /// 补记专注；成功后选中新记录。可以 ⌘Z 撤销（删除这条记录）。
    @discardableResult
    func createFocus(_ input: FocusInput) async -> Bool {
        let identifier = FocusCodec.identifier(startedAt: input.startedAt)
        let ok = await performQueued("补记专注", .createFocus(input))
        if ok {
            selectedOccurrenceID = nil
            selectedFocusID = identifier
            registerUndo("补记专注", undo: [.deleteFocus(id: identifier)], redo: [.createFocus(input)])
        }
        return ok
    }

    @discardableResult
    func updateFocus(_ focusID: String, title: String?, goodCount: Int?, badCount: Int?) async -> Bool {
        let old = snapshot.focus.first { $0.time == focusID }
        let redo = OutboxCommand.updateFocus(id: focusID, title: title, goodCount: goodCount, badCount: badCount)
        let ok = await performQueued("保存专注记录", redo)
        if ok, let old {
            let undo = OutboxCommand.updateFocus(id: focusID, title: title.map { _ in old.parsedLog.eventTitle },
                                                 goodCount: goodCount.map { _ in old.goodCount },
                                                 badCount: badCount.map { _ in old.badCount })
            registerUndo("保存专注记录", undo: [undo], redo: [redo])
        }
        return ok
    }

    /// 删除专注记录。可以 ⌘Z 撤销（按原开始时间重新补记）。
    @discardableResult
    func deleteFocus(_ focusID: String) async -> Bool {
        let old = snapshot.focus.first { $0.time == focusID }
        var link: FocusLink?
        if let old, let eventID = old.parsedLog.eventID, let linked = snapshot.item(occurrenceID: eventID) {
            let log = old.parsedLog
            link = FocusLink(occurrenceID: eventID, listID: log.eventType ?? (Int(linked.task.id3) ?? 1),
                             title: log.eventTitle.isEmpty ? linked.task.taskTitle : log.eventTitle)
        }
        let ok = await performQueued("删除专注记录", .deleteFocus(id: focusID))
        if ok, selectedFocusID == focusID { selectedFocusID = nil }
        if ok, let old, let input = UndoPlan.recreateFocus(old, link: link) {
            registerUndo("删除专注记录", undo: [.createFocus(input)], redo: [.deleteFocus(id: focusID)])
        }
        return ok
    }
}
