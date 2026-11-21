import Foundation
import GRDB

// MARK: - 导入来源与「来源 + 日程键 → 便单任务」的对应关系（本机数据库，不上云）

struct ImportSource: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case file, url, caldav, system

        var title: String {
            switch self {
            case .file: return "文件"
            case .url: return "URL 订阅"
            case .caldav: return "CalDAV"
            case .system: return "邮箱账户"
            }
        }

        var icon: String {
            switch self {
            case .file: return "doc.badge.plus"
            case .url: return "link"
            case .caldav: return "calendar.badge.plus"
            case .system: return "envelope"
            }
        }

        /// 订阅类来源会定时同步；文件是一次性导入。
        var syncs: Bool { self != .file }
    }

    var id: String
    var kind: Kind
    var name: String
    /// 导入到的便单分类。
    var listID: String
    /// 文件名、订阅地址或 CalDAV 日历地址。
    var address: String
    var createdAt: Date
    var lastSyncAt: Date?
    /// 上次同步后，这个来源对应的任务数。
    var lastCount: Int
    var enabled: Bool
    /// 连续失败次数；成功后清零。
    var failures = 0
    var lastError: String?
    /// 连续失败后，下次自动重试不早于这个时间。
    var retryAt: Date?
    /// 因连续失败被自动暂停（手动同步成功后自动恢复）。
    var autoPaused = false
}

struct ImportLink: Equatable, Sendable {
    var sourceID: String
    var key: String
    var taskID: String
    var fingerprint: String
    /// 外部日程的开始日期；判断「外部删除」时，只看还在导入范围内的。
    var startDay: LocalDate?
    /// 已因外部删除或取消标记为放弃。
    var abandoned: Bool
}

/// 一次导入或同步要做的事。
struct ImportPlan: Equatable {
    var added: [ImportedEvent] = []
    /// 外部改过的（链接里的任务要更新）。
    var updated: [ImportedEvent] = []
    var unchanged: [ImportedEvent] = []
    /// 外部还在、但便单里对应任务已被删掉的：重新建。
    var restored: [ImportedEvent] = []
    /// 外部取消或删除的：对应任务标记为放弃。
    var removed: [ImportLink] = []
}

enum ImportPlanner {
    /// removeMissing 为 true 时（订阅类来源），这次没再出现、且开始日期不早于 from 的视为外部删除。
    /// liveTasks：链接里在便单中还存在的任务 ID；nil 表示不检查（都当作还在）。
    static func plan(_ events: [ImportedEvent], links: [ImportLink], removeMissing: Bool,
                     liveTasks: Set<String>? = nil, from: LocalDate) -> ImportPlan {
        let alive: (ImportLink) -> Bool = { link in liveTasks?.contains(link.taskID) ?? true }
        let byKey = Dictionary(links.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var plan = ImportPlan()
        var seen = Set<String>()
        for event in events {
            seen.insert(event.key)
            let link = byKey[event.key]
            if event.cancelled {
                if let link, !link.abandoned, alive(link) { plan.removed.append(link) }
                continue
            }
            guard let link else {
                plan.added.append(event)
                continue
            }
            if !alive(link) {
                plan.restored.append(event)
                continue
            }
            if link.fingerprint == event.fingerprint && !link.abandoned {
                plan.unchanged.append(event)
            } else {
                plan.updated.append(event)
            }
        }
        if removeMissing {
            plan.removed += links.filter { link in
                !seen.contains(link.key) && !link.abandoned && alive(link) && (link.startDay.map { $0 >= from } ?? true)
            }
        }
        return plan
    }
}

// MARK: - 本机数据库

extension LocalStore {
    static let importFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 在 migrator 里注册（见 LocalStore.swift 的 v2-import）。
    static func createImportTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE import_source (
              id TEXT PRIMARY KEY NOT NULL,
              kind TEXT NOT NULL,
              name TEXT NOT NULL,
              list_id TEXT NOT NULL,
              address TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL,
              last_sync_at TEXT,
              last_count INTEGER NOT NULL DEFAULT 0,
              enabled INTEGER NOT NULL DEFAULT 1
            )
            """)
        try db.execute(sql: """
            CREATE TABLE import_link (
              source_id TEXT NOT NULL,
              key TEXT NOT NULL,
              task_id TEXT NOT NULL,
              fingerprint TEXT NOT NULL,
              start_day TEXT,
              abandoned INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (source_id, key)
            )
            """)
    }

    func importSources() throws -> [ImportSource] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_source ORDER BY created_at").compactMap { row in
                let kindRaw: String = row["kind"]
                let created: String = row["created_at"]
                let synced: String? = row["last_sync_at"]
                let retry: String? = row["retry_at"]
                guard let kind = ImportSource.Kind(rawValue: kindRaw) else { return nil }
                return ImportSource(id: row["id"], kind: kind, name: row["name"], listID: row["list_id"],
                                    address: row["address"],
                                    createdAt: Self.importFormatter.date(from: created) ?? Date(),
                                    lastSyncAt: synced.flatMap { Self.importFormatter.date(from: $0) },
                                    lastCount: row["last_count"], enabled: row["enabled"],
                                    failures: row["failures"], lastError: row["last_error"],
                                    retryAt: retry.flatMap { Self.importFormatter.date(from: $0) },
                                    autoPaused: row["auto_paused"])
            }
        }
    }

    /// 删除来源和它的对应关系（已导入的任务保留）。
    func deleteImportSource(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM import_link WHERE source_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM import_source WHERE id = ?", arguments: [id])
        }
    }

    func importLinks(sourceID: String) throws -> [ImportLink] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM import_link WHERE source_id = ?", arguments: [sourceID]).map { row in
                let day: String? = row["start_day"]
                return ImportLink(sourceID: row["source_id"], key: row["key"], taskID: row["task_id"],
                                  fingerprint: row["fingerprint"], startDay: day.flatMap { LocalDate(iso: $0) },
                                  abandoned: row["abandoned"])
            }
        }
    }

    func saveImportLink(_ link: ImportLink, at date: Date = Date()) throws {
        let stamp = Self.importFormatter.string(from: date)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO import_link (source_id, key, task_id, fingerprint, start_day, abandoned, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, key) DO UPDATE SET task_id = excluded.task_id, fingerprint = excluded.fingerprint,
                  start_day = excluded.start_day, abandoned = excluded.abandoned, updated_at = excluded.updated_at
                """, arguments: [link.sourceID, link.key, link.taskID, link.fingerprint, link.startDay?.iso,
                                 link.abandoned, stamp])
        }
    }
}
