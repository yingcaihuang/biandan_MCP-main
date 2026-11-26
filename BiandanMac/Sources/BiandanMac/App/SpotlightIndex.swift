@preconcurrency import CoreSpotlight
import Foundation
import os
import UniformTypeIdentifiers

// MARK: - Spotlight 搜索日程
//
// 把没完成的日程（逾期、今后 30 天、无日期，最多 500 条）写进本机 Spotlight 索引，⌘空格搜标题、分类就能找到，
// 点结果打开便单定位到这条（和点通知同一套定位）。本机数据、登录状态变化 3 秒后整批重建，内容没变不动；
// 退出登录或设置里关掉时清空。只写本机索引，不上传。

enum SpotlightIndex {
    static let domain = "occurrences"
    static let horizonDays = 30
    static let maxItems = 500

    struct Entry: Equatable, Sendable {
        var id: String
        var title: String
        /// 「逾期 · 11月20日 · 工作」「今天 14:30 · 工作 · 重要且紧急」
        var detail: String
        var keywords: [String]
        var start: Date?
    }

    static func entries(snapshot: DataSnapshot, today: LocalDate, calendar: Calendar = .current) -> [Entry] {
        var names: [String: String] = [:]
        for list in snapshot.lists where names[list.id3] == nil { names[list.id3] = list.displayName }
        var query = OccurrenceQuery()
        query.includeUndated = true
        let horizon = today.adding(days: horizonDays)
        let items = snapshot.items(query).filter { item in
            if item.task.undated { return true }
            guard let start = item.occurrence.startDate else { return false }
            return start <= horizon
        }
        func key(_ item: OccurrenceItem) -> (Int, String, String) {
            item.task.undated ? (1, "", item.id) : (0, item.occurrence.startDate?.iso ?? "", item.id)
        }
        return items.sorted { key($0) < key($1) }.prefix(maxItems).map { item in
            let title = item.task.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let list = names[item.task.id3] ?? "未分类"
            let day = item.task.undated ? nil : item.occurrence.startDate
            let clock = MenuBarAgenda.slot(item, calendar: calendar) != nil ? item.occurrence.startClock : nil
            var parts = [IntentSupport.when(day, clock, today: today), list]
            if item.isOverdue(today: today) { parts.insert("逾期", at: 0) }
            let quadrant = item.task.quadrant
            if quadrant != .neither { parts.append(quadrant.title) }
            let start = day.map { MenuBarAgenda.moment($0, clock ?? .startOfDay, calendar: calendar) }
            return Entry(id: item.id, title: title.isEmpty ? "（无标题）" : title, detail: parts.joined(separator: " · "),
                         keywords: ["便单", list, quadrant.title], start: start)
        }
    }

    static func searchableItem(_ entry: Entry, now: Date = Date()) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.contentDescription = entry.detail
        attributes.keywords = entry.keywords
        attributes.startDate = entry.start
        let item = CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: domain, attributeSet: attributes)
        // 数据有变化时整批重建；便单很久没开时过期，免得搜到很久以前的日程。
        item.expirationDate = now.addingTimeInterval(60 * 86_400)
        return item
    }

    /// 点了 Spotlight 里的结果：和点通知一样，先记下要打开的位置，登录、加载完再定位。
    @MainActor
    @discardableResult
    static func open(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        ReminderInbox.reveal(.occurrence(id))
        NotificationCenter.default.post(name: .biandanOpenOccurrence, object: nil)
        return true
    }
}

@MainActor
final class SpotlightIndexer {
    nonisolated static let logger = Logger(subsystem: "ai.racore.BiandanMac", category: "spotlight")

    private weak var model: AppModel?
    private var pending: Task<Void, Never>?
    private var last: [SpotlightIndex.Entry]?

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        noteChange()
    }

    func noteChange() {
        guard model != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    func publish() {
        guard let model, model.authState != .checking, CSSearchableIndex.isIndexingAvailable() else { return }
        let entries = model.spotlightEnabled && model.authState == .signedIn
            ? SpotlightIndex.entries(snapshot: model.snapshot, today: LocalDate.today()) : []
        guard entries != last else { return }
        last = entries
        let items = entries.map { SpotlightIndex.searchableItem($0) }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [SpotlightIndex.domain]) { error in
            if let error {
                Self.logger.error("清空 Spotlight 索引失败：\(error.localizedDescription, privacy: .public)")
            }
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { error in
                if let error {
                    Self.logger.error("写 Spotlight 索引失败：\(error.localizedDescription, privacy: .public)")
                } else {
                    Self.logger.info("Spotlight 索引已更新：\(items.count) 条")
                }
            }
        }
    }
}
