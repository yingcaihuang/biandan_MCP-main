import Foundation

/// 待同步队列：后台修改遇到临时失败时存进本机 outbox，联网后按顺序重放。
extension AppModel {
    /// 执行一条可入队的后台命令。临时失败时入队并保留乐观修改，返回 true 表示已执行或已排队。
    @discardableResult
    func performQueued(_ label: String, optimistic: SnapshotEdit? = nil, _ command: OutboxCommand) async -> Bool {
        guard authState == .signedIn else {
            operationError = "请先登录华为账号。"
            return false
        }
        let editID = UUID()
        let hasOptimistic = optimistic != nil
        if let optimistic {
            optimisticEdits.append(OptimisticEdit(id: editID, apply: optimistic))
            optimistic(&snapshot)
        }
        // 队列里还有命令时直接排到队尾，保证修改按顺序写入。
        if outboxPending > 0 {
            if enqueue(label, command, editID: hasOptimistic ? editID : nil) {
                Task { await self.flushOutbox() }
                return true
            }
            optimisticEdits.removeAll { $0.id == editID }
            if hasOptimistic { reloadSnapshot() }
            return false
        }
        backgroundOperations += 1
        defer { backgroundOperations -= 1 }
        do {
            let changes = try await command.execute(on: service)
            optimisticEdits.removeAll { $0.id == editID }
            applyLocal(changes, forceReload: hasOptimistic)
            return true
        } catch {
            let failure = error as? OperationFailure
            if let failure { applyLocal(failure.changes) }
            if OutboxPolicy.isTransient(error), enqueue(label, command, editID: hasOptimistic ? editID : nil) {
                operationError = "「\(label)」暂时无法写入云端，已放进待同步队列，联网后会自动重试。"
                return true
            }
            optimisticEdits.removeAll { $0.id == editID }
            if hasOptimistic { reloadSnapshot() }
            if failure?.needsSignIn == true {
                expireSession()
            } else {
                operationError = Self.failureText(label, error.localizedDescription, reverted: hasOptimistic)
            }
            return false
        }
    }

    private func enqueue(_ label: String, _ command: OutboxCommand, editID: UUID?) -> Bool {
        guard let entry = OutboxEntry.make(label: label, command: command) else { return false }
        do {
            try store.enqueueOutbox(entry)
        } catch {
            operationError = "无法保存待同步的修改：\(error.localizedDescription)"
            return false
        }
        if let editID { queuedEdits[entry.opID] = editID }
        refreshOutboxCounts()
        scheduleOutboxRetry()
        return true
    }

    private func releaseQueuedEdit(_ opID: String) {
        if let editID = queuedEdits.removeValue(forKey: opID) {
            optimisticEdits.removeAll { $0.id == editID }
        }
    }

    /// 按入队顺序重放。临时失败时停下等下次；永久失败时放弃这一条并撤掉它的乐观修改。
    func flushOutbox() async {
        guard authState == .signedIn, !isFlushingOutbox else { return }
        isFlushingOutbox = true
        defer {
            isFlushingOutbox = false
            refreshOutboxCounts()
        }
        let entries = (try? store.outboxEntries(state: OutboxEntry.pending)) ?? []
        for entry in entries {
            guard let payload = entry.payload else {
                try? store.updateOutbox(entry.opID, attempts: entry.attempts, lastError: "无法解析待同步命令",
                                        state: OutboxEntry.failed)
                releaseQueuedEdit(entry.opID)
                continue
            }
            backgroundOperations += 1
            do {
                let changes = try await payload.command.execute(on: service)
                backgroundOperations -= 1
                try? store.removeOutbox(entry.opID)
                releaseQueuedEdit(entry.opID)
                applyLocal(changes, forceReload: true)
            } catch {
                backgroundOperations -= 1
                let failure = error as? OperationFailure
                if let failure { applyLocal(failure.changes) }
                if failure?.needsSignIn == true {
                    // 保留队列，重新登录后再写。
                    expireSession()
                    return
                }
                if OutboxPolicy.isTransient(error) {
                    try? store.updateOutbox(entry.opID, attempts: entry.attempts + 1,
                                            lastError: error.localizedDescription, state: OutboxEntry.pending)
                    outboxLastError = error.localizedDescription
                    scheduleOutboxRetry()
                    return
                }
                try? store.updateOutbox(entry.opID, attempts: entry.attempts + 1,
                                        lastError: error.localizedDescription, state: OutboxEntry.failed)
                releaseQueuedEdit(entry.opID)
                reloadSnapshot()
                operationError = "待同步的「\(payload.label)」没能写入云端，已放弃：\(error.localizedDescription)"
            }
        }
        outboxLastError = nil
    }

    /// 30 秒后再试一次（已有计划时不重复安排）。
    func scheduleOutboxRetry(after seconds: Double = 30) {
        guard outboxRetryTask == nil else { return }
        outboxRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            self.outboxRetryTask = nil
            if self.outboxPending > 0 { await self.flushOutbox() }
        }
    }

    func refreshOutboxCounts() {
        outboxPending = (try? store.outboxEntries(state: OutboxEntry.pending))?.count ?? 0
        outboxFailed = (try? store.outboxEntries(state: OutboxEntry.failed))?.count ?? 0
    }

    func clearFailedOutbox() {
        try? store.removeOutbox(state: OutboxEntry.failed)
        refreshOutboxCounts()
    }

    /// 退出登录时清空队列，避免把上一个账号的修改写到新账号。
    func discardOutbox() {
        outboxRetryTask?.cancel()
        outboxRetryTask = nil
        try? store.removeOutbox(state: OutboxEntry.pending)
        try? store.removeOutbox(state: OutboxEntry.failed)
        for opID in Array(queuedEdits.keys) { releaseQueuedEdit(opID) }
        outboxLastError = nil
        refreshOutboxCounts()
    }
}
