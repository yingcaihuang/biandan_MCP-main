import Foundation
import GRDB

// MARK: - 导入来源的同步日志、失败退避（本机数据库，不上云）

enum ImportSyncTrigger: String, Sendable {
    case manual, automatic, added, edited

    var title: String {
        switch self {
        case .manual: return "手动"
        case .automatic: return "自动"
        case .added: return "添加"
        case .edited: return "修改"
        }
    }
}

/// 连续失败后的降频与暂停。
enum ImportBackoff {
    /// 连续失败到这个次数起，自动同步按倍数放慢。
    static let slowDownAfter = 3
    /// 连续失败到这个次数，自动暂停这个来源（手动同步的失败不会触发暂停）。
    static let pauseAfter = 8
    static let maxDelayMinutes = 12 * 60

    /// 连续失败 failures 次后，距下次自动重试的分钟数；nil 表示按正常间隔。
    static func delayMinutes(failures: Int, interval: Int) -> Int? {
        guard failures >= slowDownAfter else { return nil }
        let base = max(interval, 5)
        let exponent = min(failures - slowDownAfter + 1, 10)
        return min(base * (1 << exponent), maxDelayMinutes)
    }

    static func shouldPause(failures: Int) -> Bool { failures >= pauseAfter }
}

struct ImportSyncLog: Identifiable, Equatable, Sendable {
    var id: Int64 = 0
    var sourceID: String
    var sourceName: String
    var trigger: ImportSyncTrigger
    var startedAt: Date
    var durationMs: Int
    var ok: Bool
    var fetched: Int
    var added: Int
    var updated: Int
    var removed: Int
    var failed: Int
    /// 错误信息或补充说明（退避、暂停、恢复、修改了什么）。
    var message: String
}

extension ImportSyncLog {
    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var timeText: String { Self.shortFormatter.string(from: startedAt) }

    var durationText: String {
        durationMs < 1000 ? "\(durationMs) 毫秒" : String(format: "%.1f 秒", Double(durationMs) / 1000)
    }

    var summaryText: String {
        if trigger == .edited { return "修改了来源设置" }
        if !ok && fetched + added + updated + removed + failed == 0 { return "没有写入" }
        var parts = ["读取 \(fetched) 条", "新增 \(added)", "更新 \(updated)", "放弃 \(removed)"]
        if failed > 0 { parts.append("写入失败 \(failed)") }
        return parts.joined(separator: " · ")
    }

    /// 复制到剪贴板时的一行。
    var copyLine: String {
        var line = "\(Self.fullFormatter.string(from: startedAt)) [\(trigger.title)] \(sourceName) \(ok ? "成功" : "失败")"
            + " · \(durationText) · \(summaryText)"
        if !message.isEmpty { line += " — \(message)" }
        return line
    }
}

// MARK: - 本机数据库

extension LocalStore {
    static let importLogLimit = 2000

    /// 在 migrator 里注册（见 LocalStore.swift 的 v3-import-log）。
    static func createImportLogTables(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE import_source ADD COLUMN failures INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE import_source ADD COLUMN last_error TEXT")
        try db.execute(sql: "ALTER TABLE import_source ADD COLUMN retry_at TEXT")
        try db.execute(sql: "ALTER TABLE import_source ADD COLUMN auto_paused INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: """
            CREATE TABLE import_sync_log (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source_id TEXT NOT NULL,
              source_name TEXT NOT NULL,
              trigger_kind TEXT NOT NULL,
              started_at TEXT NOT NULL,
              duration_ms INTEGER NOT NULL DEFAULT 0,
              ok INTEGER NOT NULL,
              fetched INTEGER NOT NULL DEFAULT 0,
              added INTEGER NOT NULL DEFAULT 0,
              updated INTEGER NOT NULL DEFAULT 0,
              removed INTEGER NOT NULL DEFAULT 0,
              failed INTEGER NOT NULL DEFAULT 0,
              message TEXT NOT NULL DEFAULT ''
            )
            """)
        try db.execute(sql: "CREATE INDEX import_sync_log_source ON import_sync_log (source_id, id)")
    }

    func saveImportSource(_ source: ImportSource) throws {
        let created = Self.importFormatter.string(from: source.createdAt)
        let synced = source.lastSyncAt.map { Self.importFormatter.string(from: $0) }
        let retry = source.retryAt.map { Self.importFormatter.string(from: $0) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO import_source (id, kind, name, list_id, address, created_at, last_sync_at, last_count, enabled,
                  failures, last_error, retry_at, auto_paused)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, name = excluded.name, list_id = excluded.list_id,
                  address = excluded.address, last_sync_at = excluded.last_sync_at, last_count = excluded.last_count,
                  enabled = excluded.enabled, failures = excluded.failures, last_error = excluded.last_error,
                  retry_at = excluded.retry_at, auto_paused = excluded.auto_paused
                """, arguments: [source.id, source.kind.rawValue, source.name, source.listID, source.address, created,
                                 synced, source.lastCount, source.enabled, source.failures, source.lastError, retry,
                                 source.autoPaused])
        }
    }

    /// 追加一条日志，只保留最新的 keep 条。
    func appendImportLog(_ log: ImportSyncLog, keep: Int = LocalStore.importLogLimit) throws {
        let started = Self.importFormatter.string(from: log.startedAt)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO import_sync_log (source_id, source_name, trigger_kind, started_at, duration_ms, ok,
                  fetched, added, updated, removed, failed, message)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [log.sourceID, log.sourceName, log.trigger.rawValue, started, log.durationMs, log.ok,
                                 log.fetched, log.added, log.updated, log.removed, log.failed, log.message])
            try db.execute(sql: """
                DELETE FROM import_sync_log
                WHERE id <= (SELECT id FROM import_sync_log ORDER BY id DESC LIMIT 1 OFFSET ?)
                """, arguments: [keep])
        }
    }

    /// 最新的在前。sourceID 为 nil 时取全部来源。
    func importLogs(sourceID: String? = nil, limit: Int = 500) throws -> [ImportSyncLog] {
        try dbQueue.read { db in
            let rows: [Row]
            if let sourceID {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM import_sync_log WHERE source_id = ? ORDER BY id DESC LIMIT ?",
                                        arguments: [sourceID, limit])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM import_sync_log ORDER BY id DESC LIMIT ?", arguments: [limit])
            }
            return rows.map { row in
                let started: String = row["started_at"]
                let trigger: String = row["trigger_kind"]
                return ImportSyncLog(id: row["id"], sourceID: row["source_id"], sourceName: row["source_name"],
                                     trigger: ImportSyncTrigger(rawValue: trigger) ?? .automatic,
                                     startedAt: Self.importFormatter.date(from: started) ?? Date(),
                                     durationMs: row["duration_ms"], ok: row["ok"], fetched: row["fetched"],
                                     added: row["added"], updated: row["updated"], removed: row["removed"],
                                     failed: row["failed"], message: row["message"])
            }
        }
    }

    func clearImportLogs(sourceID: String? = nil) throws {
        try dbQueue.write { db in
            if let sourceID {
                try db.execute(sql: "DELETE FROM import_sync_log WHERE source_id = ?", arguments: [sourceID])
            } else {
                try db.execute(sql: "DELETE FROM import_sync_log")
            }
        }
    }
}
