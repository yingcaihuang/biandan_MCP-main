import AppKit
import Foundation
import UniformTypeIdentifiers

/// 一次导入的预览：解析出的日程、和已有来源的对应关系、目标分类。确认后才写入。
struct ImportPreview: Identifiable {
    let id = UUID()
    var kind: ImportSource.Kind
    /// 文件名或订阅地址。
    var address: String
    var sourceName: String
    var events: [ImportedEvent]
    var skipped: Int
    /// 已有的同一来源：再次导入同一文件时复用它的对应关系，不会重复新建。
    var existing: ImportSource?
    var links: [ImportLink]
    /// 目标分类；nil 表示按来源名称新建。
    var listID: String?
    /// 链接里在便单中还存在的任务；被删掉的会重新建。
    var liveTasks: Set<String>? = nil

    var plan: ImportPlan {
        ImportPlanner.plan(events.filter(\.include), links: links, removeMissing: false, liveTasks: liveTasks,
                           from: LocalDate.minSupported)
    }
}

extension ImportedEvent {
    /// 「12月1日 周二 15:00–16:30」「12月5日 周六 全天 → 12月7日 周一」
    var scheduleText: String {
        var text = startDate.shortTitle
        if let start = startTime {
            text += " " + start.shortText
            if let end = endTime { text += "–" + end.shortText }
        } else {
            text += " 全天"
        }
        if endDate > startDate { text += " → " + endDate.shortTitle }
        return text
    }
}

/// 一次写入（导入或同步）的结果。
struct ImportCounts: Equatable {
    var added = 0
    var updated = 0
    var removed = 0
    var failed = 0
    /// 便单里被删掉、这次重新建的。
    var restored = 0
    /// 这次从来源读到的日程数；为 0 时不按外部删除处理。
    var fetched = 0
    var emptyFetch = false

    var hasChanges: Bool { added + updated + removed + failed + restored > 0 }

    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added) 条") }
        if restored > 0 { parts.append("重建 \(restored) 条（便单里删掉的）") }
        if updated > 0 { parts.append("更新 \(updated) 条") }
        if removed > 0 { parts.append("\(removed) 条已取消，标记为放弃") }
        if failed > 0 { parts.append("\(failed) 条没能写入") }
        return parts.isEmpty ? "没有变化" : parts.joined(separator: "，")
    }
}

struct ImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 后台导入队列里的一项。
struct ImportQueueItem: Equatable, Sendable {
    let sourceID: String
    let trigger: ImportSyncTrigger
}

/// 写入便单的进度：已处理 / 总数。
struct ImportProgress: Equatable, Sendable {
    var done = 0
    var total = 0
}

// MARK: - 导入日程

extension AppModel {
    /// 订阅类来源（CalDAV）自动同步间隔的默认值和可选项（分钟；0 表示只手动同步）。
    nonisolated static let defaultImportSyncMinutes = 30
    nonisolated static let importSyncChoices = [5, 15, 30, 60, 180, 0]

    /// 「仅手动」「15 分钟」「1 小时」
    nonisolated static func importIntervalTitle(_ minutes: Int) -> String {
        if minutes <= 0 { return "仅手动" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    /// 「每 30 分钟自动同步一次」或「只在点「立即同步」时同步」。
    var importSyncPhrase: String {
        importSyncIntervalMinutes > 0
            ? "每 \(Self.importIntervalTitle(importSyncIntervalMinutes))自动同步一次"
            : "只在点「立即同步」时同步"
    }

    /// CalDAV 日历对应的来源 / 分类名称：「飞书·我的日历」。
    nonisolated static func caldavSourceName(account: String, calendar: String) -> String {
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = calendar.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.isEmpty { return calendar.isEmpty ? "CalDAV 日历" : calendar }
        if calendar.isEmpty || calendar == account { return account }
        return "\(account)·\(calendar)"
    }

    func reloadImportSources() {
        importSources = (try? store.importSources()) ?? []
    }

    func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ics"), UTType.calendarEvent].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的日历文件（.ics）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImportFile(url)
    }

    /// 读文件、解析，生成预览（不写入）。
    func loadImportFile(_ url: URL) {
        importNotice = nil
        guard let data = try? Data(contentsOf: url) else {
            importNotice = "读不了这个文件：\(url.lastPathComponent)"
            return
        }
        guard let text = Self.decodeCalendarText(data), text.contains("BEGIN:VCALENDAR") || text.contains("BEGIN:VEVENT") else {
            importNotice = "「\(url.lastPathComponent)」不是日历文件（.ics）"
            return
        }
        let result = ICSImport.parse(text, today: today)
        guard !result.events.isEmpty else {
            importNotice = "「\(url.lastPathComponent)」里没有可导入的日程（导入范围：过去 \(ICSImport.pastDays) 天到未来一年）"
            return
        }
        reloadImportSources()
        let address = url.lastPathComponent
        let existing = importSources.first { $0.kind == .file && $0.address == address }
        let links = existing.flatMap { try? store.importLinks(sourceID: $0.id) } ?? []
        let name = existing?.name ?? result.name ?? url.deletingPathExtension().lastPathComponent
        importPreview = ImportPreview(kind: .file, address: address, sourceName: name, events: result.events,
                                      skipped: result.skipped, existing: existing, links: links,
                                      listID: existing?.listID,
                                      liveTasks: Set(links.map(\.taskID).filter { importTaskVisible($0) }))
    }

    /// UTF-8 优先；部分国内日历导出的是 GB18030。
    nonisolated static func decodeCalendarText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 按预览写入：新建、更新、把外部取消的标记为放弃，并记下对应关系。
    func runImport(_ preview: ImportPreview) async {
        guard authState == .signedIn else {
            importNotice = "请先在便单主窗口登录华为账号"
            return
        }
        importBusy = true
        defer { importBusy = false }
        let trimmed = preview.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = trimmed.isEmpty ? "导入的日程" : trimmed
        guard let listID = await importList(named: sourceName, preferred: preview.listID) else {
            importNotice = "没能新建分类「\(sourceName)」，请稍后重试"
            return
        }
        var source = preview.existing ?? ImportSource(id: UUID().uuidString, kind: preview.kind, name: sourceName,
                                                      listID: listID, address: preview.address, createdAt: Date(),
                                                      lastSyncAt: nil, lastCount: 0, enabled: true)
        source.name = sourceName
        source.listID = listID
        try? store.saveImportSource(source)
        reloadImportSources()
        // 预览先关掉，写入在后台进行：进度显示在「已导入的日历」里，完成后发系统通知。
        importPreview = nil
        importNotice = "正在后台导入「\(sourceName)」，完成后会通知你"

        let counts = await applyImportPlan(preview.plan, links: preview.links, sourceID: source.id, listID: listID,
                                           sourceName: sourceName)
        recordSync(&source)
        var notice = "已导入「\(sourceName)」：" + counts.summary
        if counts.failed > 0 { notice += "，可以重新导入同一文件再试" }
        importNotice = notice
        ImportNotifier.notify(title: counts.failed > 0 ? "日程导入完成，有 \(counts.failed) 条没写入" : "日程导入完成",
                              body: notice, sourceID: source.id)
    }

    /// 删除来源、对应关系和保存的密码。已导入的任务保留。
    func removeImportSource(_ source: ImportSource) {
        try? store.deleteImportSource(source.id)
        if source.kind == .caldav { CalDAVKeychain.delete(source.id) }
        importSyncErrors[source.id] = nil
        reloadImportSources()
        importNotice = "已移除「\(source.name)」，已导入的任务仍保留在分类里"
    }

    // MARK: CalDAV

    /// 为选中的每个日历建一个来源（各自一个分类），保存密码，并立即同步一次。
    func addCalDAVSources(account: String, credentials: CalDAVCredentials, calendars: [CalDAVCalendar]) async {
        guard authState == .signedIn else {
            importNotice = "请先在便单主窗口登录华为账号"
            return
        }
        importBusy = true
        defer { importBusy = false }
        reloadImportSources()
        var ready: [ImportSource] = []
        var problems: [String] = []
        for calendar in calendars {
            let address = calendar.url.absoluteString
            if let existing = importSources.first(where: { $0.kind == .caldav && $0.address == address }) {
                // 已经添加过：只更新密码，再同步一次。
                do {
                    try CalDAVKeychain.save(credentials, for: existing.id)
                    ready.append(existing)
                } catch {
                    problems.append("「\(existing.name)」\(error.localizedDescription)")
                }
                continue
            }
            let name = Self.caldavSourceName(account: account, calendar: calendar.name)
            guard let listID = await importList(named: name, preferred: nil) else {
                problems.append("没能新建分类「\(name)」")
                continue
            }
            let source = ImportSource(id: UUID().uuidString, kind: .caldav, name: name, listID: listID,
                                      address: address, createdAt: Date(), lastSyncAt: nil, lastCount: 0, enabled: true)
            do {
                try CalDAVKeychain.save(credentials, for: source.id)
            } catch {
                problems.append("「\(name)」\(error.localizedDescription)")
                continue
            }
            try? store.saveImportSource(source)
            ready.append(source)
        }
        reloadImportSources()

        // 写日程放进后台队列，窗口不用等。
        for source in ready { enqueueImportSync(source.id, trigger: .added) }
        var lines: [String] = []
        if !ready.isEmpty { lines.append("已添加 \(ready.count) 个 CalDAV 日历，正在后台导入，完成后会通知你") }
        lines += problems
        importNotice = lines.isEmpty ? "没有添加日历" : lines.joined(separator: "；")
    }

    /// 添加 URL 订阅：按名称建分类，立即同步一次。同一地址已订阅过时只同步。
    func addURLSource(address: String, name: String) async {
        guard authState == .signedIn else {
            importNotice = "请先在便单主窗口登录华为账号"
            return
        }
        importBusy = true
        defer { importBusy = false }
        reloadImportSources()
        if let existing = importSources.first(where: { $0.kind == .url && $0.address == address }) {
            enqueueImportSync(existing.id, trigger: .manual)
            importNotice = "「\(existing.name)」已经订阅过，正在后台同步，完成后会通知你"
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = trimmed.isEmpty ? "订阅日历" : trimmed
        guard let listID = await importList(named: sourceName, preferred: nil) else {
            importNotice = "没能新建分类「\(sourceName)」，请稍后重试"
            return
        }
        let source = ImportSource(id: UUID().uuidString, kind: .url, name: sourceName, listID: listID,
                                  address: address, createdAt: Date(), lastSyncAt: nil, lastCount: 0, enabled: true)
        try? store.saveImportSource(source)
        reloadImportSources()
        // 写日程放进后台队列，订阅窗口不用等。
        enqueueImportSync(source.id, trigger: .added)
        importNotice = "已订阅「\(sourceName)」，正在后台导入，完成后会通知你"
    }

    func syncAllImportSources() async {
        reloadImportSources()
        for source in importSources where source.kind.syncs && source.enabled {
            guard !Task.isCancelled, authState == .signedIn else { return }
            await syncImportSource(source, manual: false)
        }
    }

    /// 登录后启动；退出登录或授权失效时停止（见 AppModel 的 startAutoSync / stopImportAutoSync 调用处）。
    func startImportAutoSync() {
        importSyncTask?.cancel()
        importSyncTask = nil
        let minutes = importSyncIntervalMinutes
        // 「仅手动」：不启动定时同步。
        guard minutes > 0 else { return }
        importSyncTask = Task { [weak self] in
            // 启动后（或改了间隔后）稍等，先让便单自己的同步跑完。
            var delay: Double = 20
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.syncAllImportSources()
                delay = Double(minutes) * 60
            }
        }
    }

    func stopImportAutoSync() {
        importSyncTask?.cancel()
        importSyncTask = nil
        cancelImportQueue()
    }

    func performSourceSync(_ original: ImportSource) async throws -> ImportCounts {
        let texts: [String]
        switch original.kind {
        case .caldav:
            guard let credentials = CalDAVKeychain.load(original.id) else { throw CalDAVError.missingPassword }
            guard let url = URL(string: original.address) else { throw CalDAVError.invalidAddress }
            texts = try await CalDAVClient(credentials: credentials)
                .events(in: url, pastDays: ICSImport.pastDays, futureDays: ICSImport.futureDays)
        case .url:
            guard let url = ICSSubscription.url(original.address) else { throw ICSSubscriptionError.invalidAddress }
            texts = [try await ICSSubscription.fetch(url)]
        case .system:
            texts = []
        case .file:
            return ImportCounts()
        }
        var events: [ImportedEvent] = []
        var seen = Set<String>()
        if original.kind == .system {
            let systemEvents = try SystemCalendarImport.events(calendarID: original.address, today: today)
            for event in systemEvents where seen.insert(event.key).inserted {
                events.append(event)
            }
        }
        for text in texts {
            for event in ICSImport.parse(text, today: today).events where seen.insert(event.key).inserted {
                events.append(event)
            }
        }
        // 同步期间来源被移除了：不再写入。
        reloadImportSources()
        guard var source = importSources.first(where: { $0.id == original.id }) else { return ImportCounts() }
        let links = (try? store.importLinks(sourceID: source.id)) ?? []
        // 一条都没取到时不按「外部删除」处理，免得服务器出错把整个分类都标成放弃。
        let live = Set(links.map(\.taskID).filter { importTaskVisible($0) })
        let plan = ImportPlanner.plan(events, links: links, removeMissing: !events.isEmpty, liveTasks: live,
                                      from: today.adding(days: -ICSImport.pastDays))
        guard let listID = await importList(named: source.name, preferred: source.listID) else {
            throw ImportError(message: "没能新建分类「\(source.name)」")
        }
        source.listID = listID
        var counts = await applyImportPlan(plan, links: links, sourceID: source.id, listID: listID,
                                           sourceName: source.name)
        counts.fetched = events.count
        counts.emptyFetch = events.isEmpty
        recordSync(&source)
        return counts
    }

    // MARK: 写入

    /// 目标分类：指定的还在就用它；否则按名称找同名分类，没有就新建。
    func importList(named name: String, preferred: String?) async -> String? {
        if let preferred, snapshot.list(preferred) != nil { return preferred }
        if let list = snapshot.lists.first(where: { $0.displayName == name }) { return list.id3 }
        return await createList(name: name, colorIndex: ScheduleCategorizer.colorIndex(for: name), select: false)
    }

    /// 要新建两条及以上时，先让服务层把任务表、实例表各拉一次做查重索引，不再每建一条各拉一遍。
    private func applyImportPlan(_ plan: ImportPlan, links: [ImportLink], sourceID: String, listID: String,
                                 sourceName: String) async -> ImportCounts {
        let bulk = plan.added.count + plan.restored.count + plan.updated.count >= 2
        // 拉表失败时退回逐条查重，导入照常进行。
        if bulk { try? await service.beginBulkCreate() }
        let counts = await applyImportPlanBody(plan, links: links, sourceID: sourceID, listID: listID,
                                               sourceName: sourceName)
        if bulk { await service.endBulkCreate() }
        return counts
    }

    private func applyImportPlanBody(_ plan: ImportPlan, links: [ImportLink], sourceID: String, listID: String,
                                     sourceName: String) async -> ImportCounts {
        let linkByKey = Dictionary(links.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var counts = ImportCounts()
        // 进度：每处理完一条加一，「已导入的日历」里显示「正在写入便单 n/总数」。
        let total = plan.added.count + plan.restored.count + plan.updated.count + plan.removed.count
        if total > 0 { importProgress[sourceID] = ImportProgress(done: 0, total: total) }
        defer { importProgress[sourceID] = nil }
        func step() { importProgress[sourceID]?.done += 1 }
        for event in plan.added {
            guard !Task.isCancelled else { return counts }
            defer { step() }
            if let taskID = await createImportedTask(event.input(listID: listID, sourceName: sourceName)) {
                saveLink(sourceID, event, taskID: taskID)
                counts.added += 1
            } else {
                counts.failed += 1
            }
        }
        for event in plan.restored {
            guard !Task.isCancelled else { return counts }
            defer { step() }
            // 便单里只剩一个没有实例、看不见的空任务时，先清掉再重建。
            await purgeEmptyImportedTask(linkByKey[event.key]?.taskID)
            if let taskID = await createImportedTask(event.input(listID: listID, sourceName: sourceName)) {
                saveLink(sourceID, event, taskID: taskID)
                counts.restored += 1
            } else {
                counts.failed += 1
            }
        }
        for event in plan.updated {
            guard !Task.isCancelled else { return counts }
            defer { step() }
            guard let link = linkByKey[event.key] else { continue }
            if snapshot.tasks[link.taskID] == nil {
                // 便单里已经删掉了：重新建一条。
                if let taskID = await createImportedTask(event.input(listID: listID, sourceName: sourceName)) {
                    saveLink(sourceID, event, taskID: taskID)
                    counts.updated += 1
                } else {
                    counts.failed += 1
                }
                continue
            }
            await applyImportedChange(event, taskID: link.taskID, sourceName: sourceName)
            saveLink(sourceID, event, taskID: link.taskID)
            counts.updated += 1
        }
        for link in plan.removed {
            guard !Task.isCancelled else { return counts }
            defer { step() }
            await abandonImported(taskID: link.taskID)
            var done = link
            done.abandoned = true
            try? store.saveImportLink(done)
            counts.removed += 1
        }
        return counts
    }

    /// 导入的任务在便单里还看得见：任务还在，并且至少有一个实例。
    func importTaskVisible(_ taskID: String) -> Bool {
        snapshot.tasks[taskID] != nil && !snapshot.occurrences(ofTask: taskID).isEmpty
    }

    /// 删掉没有任何实例的空任务（界面上看不到，只会留下垃圾数据）。
    private func purgeEmptyImportedTask(_ taskID: String?) async {
        guard let taskID, let task = snapshot.tasks[taskID], snapshot.occurrences(ofTask: taskID).isEmpty else { return }
        let scope: DeleteScope? = task.isRepeating ? .series : nil
        _ = await perform("清理空任务", silent: true) { try await $0.deleteTask(taskID, scope: scope) }
    }

    private func saveLink(_ sourceID: String, _ event: ImportedEvent, taskID: String) {
        try? store.saveImportLink(ImportLink(sourceID: sourceID, key: event.key, taskID: taskID,
                                             fingerprint: event.fingerprint, startDay: event.startDate,
                                             abandoned: false))
    }

    /// 静默新建（不打扰选中状态），返回新任务的 ID。
    private func createImportedTask(_ input: CreateTaskInput) async -> String? {
        var prepared = input
        prepared.weekStart = weekStart
        prepared.chinaMakeup = chinaMakeup
        let final = prepared
        let result = await perform("导入日程", silent: true) { try await $0.createTask(final) }
        return result?.taskID
    }

    /// 外部改过：更新标题、备注；一次性任务同步日期时刻（之前放弃过的先恢复），有地点时更新地点。
    private func applyImportedChange(_ event: ImportedEvent, taskID: String, sourceName: String) async {
        let input = event.input(listID: TodoList.defaultID, sourceName: sourceName)
        await updateTask(taskID, title: input.title, remark: input.remark)
        if let task = snapshot.tasks[taskID], !task.isRepeating, event.repeatRule == nil,
           let occurrence = snapshot.occurrences(ofTask: taskID).first {
            if occurrence.status == .abandoned {
                await toggleCompletion(OccurrenceItem(occurrence: occurrence, task: task))
            }
            if let fresh = snapshot.tasks[taskID], let current = snapshot.occurrences(ofTask: taskID).first {
                await reschedule(OccurrenceItem(occurrence: current, task: fresh), start: event.startDate,
                                 end: event.endDate, startTime: event.startTime, endTime: event.endTime)
            }
        }
        if !event.location.isEmpty || event.latitude != nil {
            await setLocation(taskID, name: event.location, latitude: event.latitude, longitude: event.longitude,
                              remind: nil)
        }
    }

    /// 外部取消或删除：待完成的实例标记为放弃（重复任务只放弃今天及以后的，最多 60 次）。
    private func abandonImported(taskID: String) async {
        guard let task = snapshot.tasks[taskID] else { return }
        var count = 0
        for occurrence in snapshot.occurrences(ofTask: taskID) where occurrence.status == .pending {
            if task.isRepeating, let start = occurrence.startDate, start < today { continue }
            await abandon(OccurrenceItem(occurrence: occurrence, task: task))
            count += 1
            if count >= 60 { break }
        }
    }
}
