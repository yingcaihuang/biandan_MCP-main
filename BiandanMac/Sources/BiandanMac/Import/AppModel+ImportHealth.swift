import Foundation
import UserNotifications

// MARK: - 导入来源：同步记录、失败退避、自动暂停、异常通知

enum ImportNotifier {
    /// 同一来源只保留最新的一条通知。
    @MainActor
    static func notify(title: String, body: String, sourceID: String) {
        // SwiftPM 直接运行时没有 Bundle，不能调用通知中心。
        guard ReminderScheduler.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["importSourceID": sourceID]
        // 不用提醒前缀，避免重新排定提醒时被清掉。
        let request = UNNotificationRequest(identifier: "biandan.import.\(sourceID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

extension AppModel {
    func importLogs(sourceID: String?, limit: Int = 500) -> [ImportSyncLog] {
        (try? store.importLogs(sourceID: sourceID, limit: limit)) ?? []
    }

    func clearImportLogs(sourceID: String?) {
        try? store.clearImportLogs(sourceID: sourceID)
    }

    /// 「23:30」或「11月23日 01:30」
    nonisolated static func importTimeText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 同步一个订阅类来源。manual 为 true 时（点「立即同步」）总是给出结果提示，也不受暂停和退避限制。
    func syncImportSource(_ source: ImportSource, manual: Bool) async {
        guard source.kind.syncs, !importSyncing.contains(source.id) else { return }
        guard authState == .signedIn else {
            if manual { importNotice = "请先在便单主窗口登录华为账号" }
            return
        }
        if !manual {
            // 自动同步：跳过已暂停的、还在退避期的来源。
            guard let fresh = importSources.first(where: { $0.id == source.id }), fresh.enabled else { return }
            if let retry = fresh.retryAt, retry > Date() { return }
        }
        importSyncing.insert(source.id)
        defer { importSyncing.remove(source.id) }
        do {
            let counts = try await syncAndRecord(source, trigger: manual ? .manual : .automatic)
            if manual || counts.hasChanges {
                importNotice = "已同步「\(source.name)」：" + counts.summary
            }
        } catch {
            if manual { importNotice = "同步「\(source.name)」失败：\(error.localizedDescription)" }
        }
    }

    /// 同步并记录：写日志，更新失败次数、退避和暂停状态，需要时发通知。
    func syncAndRecord(_ source: ImportSource, trigger: ImportSyncTrigger) async throws -> ImportCounts {
        let started = Date()
        do {
            let counts = try await performSourceSync(source)
            recordSuccess(source, trigger: trigger, started: started, counts: counts)
            return counts
        } catch {
            // 退出登录等取消的同步不算失败。
            if Task.isCancelled || error is CancellationError { throw error }
            recordFailure(source, trigger: trigger, started: started, error: error)
            throw error
        }
    }

    func logImport(_ source: ImportSource, trigger: ImportSyncTrigger, started: Date, ok: Bool,
                   counts: ImportCounts = ImportCounts(), message: String) {
        let log = ImportSyncLog(sourceID: source.id, sourceName: source.name, trigger: trigger, startedAt: started,
                                durationMs: max(Int(Date().timeIntervalSince(started) * 1000), 0), ok: ok,
                                fetched: counts.fetched, added: counts.added + counts.restored, updated: counts.updated,
                                removed: counts.removed, failed: counts.failed, message: message)
        try? store.appendImportLog(log)
    }

    /// 记下同步时间和条数。来源在同步期间被移除时不再写回。
    func recordSync(_ source: inout ImportSource) {
        reloadImportSources()
        guard var fresh = importSources.first(where: { $0.id == source.id }) else { return }
        fresh.listID = source.listID
        fresh.lastSyncAt = Date()
        fresh.lastCount = ((try? store.importLinks(sourceID: fresh.id)) ?? []).filter { !$0.abandoned && importTaskVisible($0.taskID) }.count
        try? store.saveImportSource(fresh)
        source = fresh
        reloadImportSources()
    }

    private func recordSuccess(_ original: ImportSource, trigger: ImportSyncTrigger, started: Date, counts: ImportCounts) {
        reloadImportSources()
        guard var source = importSources.first(where: { $0.id == original.id }) else { return }
        let previousFailures = source.failures
        let resumed = source.autoPaused
        source.failures = 0
        source.lastError = nil
        source.retryAt = nil
        if resumed {
            source.autoPaused = false
            source.enabled = true
        }
        try? store.saveImportSource(source)
        reloadImportSources()
        importSyncErrors[source.id] = nil

        var notes: [String] = []
        if counts.restored > 0 { notes.append("重建了 \(counts.restored) 条在便单里被删掉的任务") }
        if counts.emptyFetch { notes.append("这次没读到日程，没有按外部删除处理") }
        if counts.failed > 0 { notes.append("\(counts.failed) 条没能写入便单") }
        if previousFailures > 0 { notes.append("连续失败 \(previousFailures) 次后恢复正常") }
        if resumed { notes.append("已重新开启自动同步") }
        logImport(source, trigger: trigger, started: started, ok: true, counts: counts,
                  message: notes.joined(separator: "；"))

        if importNotifyFailures, previousFailures > 0, trigger != .manual || resumed {
            ImportNotifier.notify(title: "日程同步已恢复",
                                  body: "「\(source.name)」同步恢复正常" + (resumed ? "，已重新开启自动同步" : ""),
                                  sourceID: source.id)
        }
    }

    private func recordFailure(_ original: ImportSource, trigger: ImportSyncTrigger, started: Date, error: Error) {
        let message = error.localizedDescription
        importSyncErrors[original.id] = message
        reloadImportSources()
        guard var source = importSources.first(where: { $0.id == original.id }) else { return }
        source.failures += 1
        source.lastError = message
        var notes: [String] = []
        var paused = false
        if trigger != .manual, source.enabled, ImportBackoff.shouldPause(failures: source.failures) {
            source.enabled = false
            source.autoPaused = true
            source.retryAt = nil
            paused = true
            notes.append("连续失败 \(source.failures) 次，已暂停自动同步")
        } else if let minutes = ImportBackoff.delayMinutes(failures: source.failures, interval: importSyncIntervalMinutes) {
            let retry = Date().addingTimeInterval(Double(minutes) * 60)
            source.retryAt = retry
            notes.append("连续失败 \(source.failures) 次，自动同步放慢到 \(Self.importTimeText(retry)) 后再试")
        }
        try? store.saveImportSource(source)
        reloadImportSources()
        logImport(source, trigger: trigger, started: started, ok: false,
                  message: ([message] + notes).joined(separator: "；"))

        guard importNotifyFailures else { return }
        if paused {
            ImportNotifier.notify(title: "日程同步已暂停",
                                  body: "「\(source.name)」连续失败 \(source.failures) 次，已暂停自动同步：\(message)。处理好后在「导入日程」里点「立即同步」即可恢复。",
                                  sourceID: source.id)
        } else if source.failures == 1, trigger == .automatic {
            // 之前正常、这次开始失败：通知一次，之后连续失败不再打扰。
            ImportNotifier.notify(title: "日程同步失败",
                                  body: "「\(source.name)」同步失败：\(message)。稍后会自动重试。",
                                  sourceID: source.id)
        }
    }
}
