import Foundation
import GRDB

// MARK: - 表结构

/// 一列业务字段：云端 attributes 的键 → SQLite 列。
struct ColumnSpec: Sendable {
    enum Kind: Sendable { case id, text, int, real }

    let key: String
    let kind: Kind

    /// camelCase → snake_case，例如 taskTitle → task_title。
    var name: String {
        var out = ""
        for character in key {
            if character.isUppercase {
                out += "_" + character.lowercased()
            } else {
                out.append(character)
            }
        }
        return out
    }

    var sqlType: String {
        switch kind {
        case .id, .text: return "TEXT"
        case .int: return "INTEGER"
        case .real: return "REAL"
        }
    }
}

enum StoreSchema {
    static func table(_ kind: RecordKind) -> String {
        switch kind {
        case .task: return "task"
        case .showTask: return "show_task"
        case .favorites: return "favorites"
        case .tomato: return "tomato"
        }
    }

    /// 四张表共 44 列，与 docs/developers/data-model.md 一致。
    static func columns(_ kind: RecordKind) -> [ColumnSpec] {
        switch kind {
        case .task:
            return [
                ColumnSpec(key: "id1", kind: .id), ColumnSpec(key: "taskTitle", kind: .text),
                ColumnSpec(key: "taskContent", kind: .text), ColumnSpec(key: "id3", kind: .id),
                ColumnSpec(key: "isCollectible", kind: .int), ColumnSpec(key: "isImportant", kind: .int),
                ColumnSpec(key: "isUrgency", kind: .int), ColumnSpec(key: "startTime", kind: .text),
                ColumnSpec(key: "endTime", kind: .text), ColumnSpec(key: "isLoop", kind: .int),
                ColumnSpec(key: "haveNoTime", kind: .int), ColumnSpec(key: "unitTimeNumber", kind: .int),
                ColumnSpec(key: "validStartTime", kind: .text), ColumnSpec(key: "validEndTime", kind: .text),
                ColumnSpec(key: "loopSet", kind: .int), ColumnSpec(key: "loopBaseNumber", kind: .int),
                ColumnSpec(key: "loopUnit", kind: .int), ColumnSpec(key: "loopDate", kind: .text),
                ColumnSpec(key: "duration", kind: .int), ColumnSpec(key: "isRemind", kind: .int),
                ColumnSpec(key: "remindDate", kind: .text), ColumnSpec(key: "remindTime", kind: .text),
                ColumnSpec(key: "isFinish", kind: .int), ColumnSpec(key: "latitude", kind: .real),
                ColumnSpec(key: "longitude", kind: .real), ColumnSpec(key: "location", kind: .text),
            ]
        case .showTask:
            return [
                ColumnSpec(key: "id2", kind: .id), ColumnSpec(key: "id1", kind: .id),
                ColumnSpec(key: "startTime", kind: .text), ColumnSpec(key: "endTime", kind: .text),
                ColumnSpec(key: "validStartTime", kind: .text), ColumnSpec(key: "validEndTime", kind: .text),
                ColumnSpec(key: "completedCount", kind: .int), ColumnSpec(key: "recentFinishedTime", kind: .text),
                ColumnSpec(key: "isFinish", kind: .int),
            ]
        case .favorites:
            return [
                ColumnSpec(key: "id3", kind: .id), ColumnSpec(key: "favoritesName", kind: .text),
                ColumnSpec(key: "favoritesColor", kind: .int),
            ]
        case .tomato:
            return [
                ColumnSpec(key: "time", kind: .id), ColumnSpec(key: "date", kind: .text),
                ColumnSpec(key: "goodCount", kind: .int), ColumnSpec(key: "badCount", kind: .int),
                ColumnSpec(key: "minutes", kind: .real), ColumnSpec(key: "log", kind: .text),
            ]
        }
    }

    static let indexes: [String] = [
        "CREATE INDEX task_by_id1 ON task(id1)",
        "CREATE INDEX task_by_list ON task(id3)",
        "CREATE INDEX show_task_by_id2 ON show_task(id2)",
        "CREATE INDEX show_task_by_task ON show_task(id1)",
        "CREATE INDEX show_task_by_date ON show_task(start_time, end_time)",
        "CREATE INDEX favorites_by_id3 ON favorites(id3)",
        "CREATE INDEX tomato_by_time ON tomato(time)",
        "CREATE INDEX tomato_by_date ON tomato(date)",
    ]

    /// 业务主键不加 UNIQUE：云端可能出现重复业务 ID，由快照层报告，而不是让写入失败。
    static func createTableSQL(_ kind: RecordKind) -> String {
        let business = columns(kind).map { "\($0.name) \($0.sqlType)" }.joined(separator: ", ")
        return """
        CREATE TABLE \(table(kind)) (
          cloud_id TEXT PRIMARY KEY NOT NULL,
          version INTEGER,
          created_time TEXT,
          edited_time TEXT,
          synced_at TEXT,
          raw_attributes TEXT NOT NULL,
          \(business)
        )
        """
    }
}

// MARK: - 本地库

struct StoreChange: Sendable, Equatable {
    var inserted = 0
    var updated = 0
    var deleted = 0
    var unchanged = 0

    var total: Int { inserted + updated + unchanged }
    var hasChanges: Bool { inserted + updated + deleted > 0 }
}

struct SyncReport: Sendable {
    var changes: [RecordKind: StoreChange]
    var finishedAt: Date

    var hasChanges: Bool { changes.values.contains { $0.hasChanges } }
}

private func dbOptional<T: DatabaseValueConvertible>(_ value: T?) -> DatabaseValueConvertible? {
    value.map { $0 as DatabaseValueConvertible }
}

/// SQLite 本地缓存。每条记录同时保存拆开的业务列和原始 attributes，回写时以原始 JSON 为底，避免丢字段。
final class LocalStore: @unchecked Sendable {
    /// 当前的数据库连接。数据库文件被别的程序删掉后会换成重新打开的（见 reopenIfDeleted），所以每次用都从这里取。
    var dbQueue: DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        return queue
    }
    /// 磁盘库的路径；内存库为 nil。
    let url: URL?
    private let lock = NSLock()
    private var queue: DatabaseQueue
    /// 打开时数据库文件的 inode：文件被删后又被别人新建同名文件时，inode 会变。
    private var fileNumber: UInt64?

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ~/Library/Application Support/BiandanMac/biandan.sqlite（开发版在 BiandanMac.dev 下，见 AppPaths）。
    static func defaultURL() throws -> URL {
        guard let directory = AppPaths.supportDirectory() else { throw CocoaError(.fileNoSuchFile) }
        return directory.appendingPathComponent("biandan.sqlite")
    }

    init(url: URL) throws {
        self.url = url
        queue = try Self.open(url)
        fileNumber = Self.fileNumber(url)
    }

    /// 内存数据库，供单元测试使用。
    init() throws {
        url = nil
        queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
    }

    private static func open(_ url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "BiandanStore"
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(queue)
        return queue
    }

    private static func fileNumber(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// 数据库文件被删掉（清理工具、手动删除），或删掉后又被新建了同名文件时，重新打开一个库并返回 true。
    /// 原来的连接还指着已删除的文件，继续用只会一直报 disk I/O error。内存库、文件没变时返回 false。
    @discardableResult
    func reopenIfDeleted() throws -> Bool {
        guard let url else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let current = Self.fileNumber(url), current == fileNumber { return false }
        queue = try Self.open(url)
        fileNumber = Self.fileNumber(url)
        return true
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            for kind in RecordKind.allCases {
                try db.execute(sql: StoreSchema.createTableSQL(kind))
            }
            for sql in StoreSchema.indexes {
                try db.execute(sql: sql)
            }
            // 业务命令队列，P4 写入时使用：离线或失败时用原业务 ID 重放。
            try db.execute(sql: """
                CREATE TABLE outbox (
                  op_id TEXT PRIMARY KEY NOT NULL,
                  command TEXT NOT NULL,
                  args_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  last_error TEXT,
                  state TEXT NOT NULL DEFAULT 'pending'
                )
                """)
            try db.execute(sql: """
                CREATE TABLE sync_meta (
                  kind TEXT PRIMARY KEY NOT NULL,
                  last_pull_at TEXT,
                  record_count INTEGER
                )
                """)
        }
        // 导入日程：来源与「来源 + 日程键 → 任务」的对应关系，只在本机。
        migrator.registerMigration("v2-import") { db in
            try LocalStore.createImportTables(db)
        }
        // 导入来源的同步日志与失败退避。
        migrator.registerMigration("v3-import-log") { db in
            try LocalStore.createImportLogTables(db)
        }
        return migrator
    }

    // MARK: 写入同步结果

    /// 在一个事务里合并四张表的完整拉取结果。只传入完整拉取成功的表。
    func apply(_ pulled: [RecordKind: [RawRecord]], at date: Date = Date()) throws -> SyncReport {
        let stamp = Self.isoFormatter.string(from: date)
        let changes = try dbQueue.write { db -> [RecordKind: StoreChange] in
            var result: [RecordKind: StoreChange] = [:]
            for (kind, records) in pulled {
                result[kind] = try Self.merge(db, kind: kind, records: records, stamp: stamp)
                try db.execute(sql: """
                    INSERT INTO sync_meta(kind, last_pull_at, record_count) VALUES (?, ?, ?)
                    ON CONFLICT(kind) DO UPDATE SET last_pull_at = excluded.last_pull_at,
                                                    record_count = excluded.record_count
                    """, arguments: [kind.rawValue, stamp, records.count])
            }
            return result
        }
        return SyncReport(changes: changes, finishedAt: date)
    }

    private static func merge(_ db: Database, kind: RecordKind, records: [RawRecord], stamp: String,
                              deleteMissing: Bool = true) throws -> StoreChange {
        let table = StoreSchema.table(kind)
        let columns = StoreSchema.columns(kind)

        var existing: [String: (version: Int?, attributes: JSONObject?)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT cloud_id, version, raw_attributes FROM \(table)") {
            let cloudID: String = row["cloud_id"]
            let version: Int? = row["version"]
            let raw: String = row["raw_attributes"]
            existing[cloudID] = (version, JSONValue.parseObject(raw))
        }

        let names = ["cloud_id", "version", "created_time", "edited_time", "synced_at", "raw_attributes"]
            + columns.map(\.name)
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        let assignments = names.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        let upsert = """
            INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(placeholders))
            ON CONFLICT(cloud_id) DO UPDATE SET \(assignments)
            """

        var change = StoreChange()
        var seen = Set<String>()
        for record in records {
            guard seen.insert(record.cloudID).inserted else { continue }
            let attributes = record.attributes ?? [:]
            if let old = existing[record.cloudID] {
                if old.version == record.version && old.attributes == attributes {
                    change.unchanged += 1
                    continue
                }
                change.updated += 1
            } else {
                change.inserted += 1
            }
            var values: [DatabaseValueConvertible?] = [
                record.cloudID, dbOptional(record.version), dbOptional(record.createdTime),
                dbOptional(record.editedTime), stamp, JSONValue.object(attributes).serializedString(),
            ]
            for spec in columns {
                switch spec.kind {
                case .id: values.append(dbOptional(attributes.identifier(spec.key)))
                case .text: values.append(dbOptional(attributes.string(spec.key)))
                case .int: values.append(dbOptional(attributes.int(spec.key)))
                case .real: values.append(dbOptional(attributes.double(spec.key)))
                }
            }
            try db.execute(sql: upsert, arguments: StatementArguments(values))
        }

        // 完整拉取里没有的记录视为已在其他设备删除。
        for cloudID in existing.keys where deleteMissing && !seen.contains(cloudID) {
            try db.execute(sql: "DELETE FROM \(table) WHERE cloud_id = ?", arguments: [cloudID])
            change.deleted += 1
        }
        return change
    }

    // MARK: 写入后的局部更新

    /// 按业务 ID 查本地缓存里的云记录 ID，供业务操作直接 GET。
    func cloudIDs(_ kind: RecordKind, businessID: String) throws -> [String] {
        let column = ColumnSpec(key: kind.businessKey, kind: .id).name
        return try dbQueue.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT cloud_id FROM \(StoreSchema.table(kind)) WHERE \(column) = ?",
                                arguments: [businessID])
        }
    }

    /// 把一次业务操作读回的记录和删除结果写进本地库，不影响其他记录。
    func applyChanges(_ changes: ChangeSet, at date: Date = Date()) throws {
        guard !changes.isEmpty else { return }
        let stamp = Self.isoFormatter.string(from: date)
        let removed = Set(changes.removed)
        var latest: [RemovedRecord: RawRecord] = [:]
        for record in changes.upserted where record.attributes != nil {
            latest[RemovedRecord(kind: record.kind, cloudID: record.cloudID)] = record
        }
        try dbQueue.write { db -> Void in
            let grouped = Dictionary(grouping: latest.filter { !removed.contains($0.key) }.values) { $0.kind }
            for (kind, records) in grouped {
                _ = try Self.merge(db, kind: kind, records: records, stamp: stamp, deleteMissing: false)
            }
            for item in removed {
                try db.execute(sql: "DELETE FROM \(StoreSchema.table(item.kind)) WHERE cloud_id = ?",
                               arguments: [item.cloudID])
            }
        }
    }

    // MARK: 读取

    func loadSnapshot() throws -> DataSnapshot {
        try dbQueue.read { db -> DataSnapshot in
            func load(_ kind: RecordKind) throws -> [RawRecord] {
                let sql = """
                    SELECT cloud_id, version, created_time, edited_time, raw_attributes
                    FROM \(StoreSchema.table(kind)) ORDER BY rowid
                    """
                return try Row.fetchAll(db, sql: sql).map { row in
                    let raw: String = row["raw_attributes"]
                    return RawRecord(kind: kind, cloudID: row["cloud_id"], version: row["version"],
                                     createdTime: row["created_time"], editedTime: row["edited_time"],
                                     attributes: JSONValue.parseObject(raw) ?? [:])
                }
            }
            let stamps = try String.fetchAll(db, sql: "SELECT last_pull_at FROM sync_meta WHERE last_pull_at IS NOT NULL")
            let lastPulled = stamps.compactMap { Self.isoFormatter.date(from: $0) }.min()
            return DataSnapshot(lists: try load(.favorites), tasks: try load(.task),
                                occurrences: try load(.showTask), focus: try load(.tomato),
                                lastPulledAt: lastPulled)
        }
    }

    // MARK: 待同步队列（outbox）

    func enqueueOutbox(_ entry: OutboxEntry) throws {
        try dbQueue.write { db -> Void in
            try db.execute(sql: """
                INSERT INTO outbox(op_id, command, args_json, created_at, attempts, last_error, state)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.opID, entry.command, entry.argsJSON, entry.createdAt,
                                 entry.attempts, entry.lastError, entry.state])
        }
    }

    /// 按入队顺序返回；`state` 为 nil 时返回全部。
    func outboxEntries(state: String? = nil) throws -> [OutboxEntry] {
        try dbQueue.read { db -> [OutboxEntry] in
            let columns = "SELECT op_id, command, args_json, created_at, attempts, last_error, state FROM outbox"
            let rows: [Row]
            if let state {
                rows = try Row.fetchAll(db, sql: columns + " WHERE state = ? ORDER BY rowid", arguments: [state])
            } else {
                rows = try Row.fetchAll(db, sql: columns + " ORDER BY rowid")
            }
            return rows.map { row in
                OutboxEntry(opID: row["op_id"], command: row["command"], argsJSON: row["args_json"],
                            createdAt: row["created_at"], attempts: row["attempts"],
                            lastError: row["last_error"], state: row["state"])
            }
        }
    }

    func updateOutbox(_ opID: String, attempts: Int, lastError: String?, state: String) throws {
        try dbQueue.write { db -> Void in
            try db.execute(sql: "UPDATE outbox SET attempts = ?, last_error = ?, state = ? WHERE op_id = ?",
                           arguments: [attempts, lastError, state, opID])
        }
    }

    func removeOutbox(_ opID: String) throws {
        try dbQueue.write { db -> Void in
            try db.execute(sql: "DELETE FROM outbox WHERE op_id = ?", arguments: [opID])
        }
    }

    func removeOutbox(state: String) throws {
        try dbQueue.write { db -> Void in
            try db.execute(sql: "DELETE FROM outbox WHERE state = ?", arguments: [state])
        }
    }

    /// 退出登录时清空本地缓存。
    func wipe() throws {
        try dbQueue.write { db in
            for kind in RecordKind.allCases {
                try db.execute(sql: "DELETE FROM \(StoreSchema.table(kind))")
            }
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "DELETE FROM sync_meta")
        }
    }
}
