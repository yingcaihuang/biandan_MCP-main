import Foundation

// MARK: - 后台导入队列

/// 添加 URL 订阅、CalDAV 日历后的导入放进后台队列：添加窗口马上关掉，一次只导入一个来源，
/// 「已导入的日历」里显示排队和写入进度，完成或失败后发系统通知。退出登录、授权失效时清空。
extension AppModel {
    func importQueued(_ sourceID: String) -> Bool {
        importQueue.contains { $0.sourceID == sourceID }
    }

    func enqueueImportSync(_ sourceID: String, trigger: ImportSyncTrigger) {
        guard !importQueued(sourceID), !importSyncing.contains(sourceID) else { return }
        importQueue.append(ImportQueueItem(sourceID: sourceID, trigger: trigger))
        guard importWorker == nil else { return }
        importWorker = Task { [weak self] in
            while !Task.isCancelled {
                guard let model = self, let item = model.nextQueuedImport() else { break }
                await model.runQueuedImport(item)
            }
            // 被取消时 cancelImportQueue 已经清掉了引用，可能已有新的队列在跑，不要覆盖。
            if !Task.isCancelled { self?.importWorker = nil }
        }
    }

    func cancelImportQueue() {
        importWorker?.cancel()
        importWorker = nil
        importQueue.removeAll()
    }

    private func nextQueuedImport() -> ImportQueueItem? {
        importQueue.isEmpty ? nil : importQueue.removeFirst()
    }

    private func runQueuedImport(_ item: ImportQueueItem) async {
        guard authState == .signedIn else { return }
        reloadImportSources()
        // 排队期间被移除，或「立即同步」已经在跑：跳过。
        guard let source = importSources.first(where: { $0.id == item.sourceID }),
              !importSyncing.contains(source.id) else { return }
        importSyncing.insert(source.id)
        defer { importSyncing.remove(source.id) }
        do {
            let counts = try await syncAndRecord(source, trigger: item.trigger)
            importSyncErrors[source.id] = nil
            importNotice = "已导入「\(source.name)」：" + counts.summary
            let title = counts.failed > 0 ? "日程导入完成，有 \(counts.failed) 条没写入" : "日程导入完成"
            ImportNotifier.notify(title: title, body: "「\(source.name)」" + counts.summary, sourceID: source.id)
        } catch {
            // 退出登录等取消的不算失败，也不通知。
            if Task.isCancelled || error is CancellationError { return }
            let message = error.localizedDescription
            importSyncErrors[source.id] = message
            importNotice = "导入「\(source.name)」失败：\(message)"
            ImportNotifier.notify(title: "日程导入失败",
                                  body: "「\(source.name)」：\(message)。可以在「导入日程」里点「立即同步」重试。",
                                  sourceID: source.id)
        }
    }
}
