import Foundation

// MARK: - 错误与变更集

/// 业务操作错误，对应 Python `ToolError`。
struct ServiceError: Error, LocalizedError, Sendable {
    var message: String
    var mayHaveWritten: Bool
    var recovery: String?
    /// 原始错误是否是临时性的（断网、超时、429、5xx），可以放进待同步队列重试。
    var transient = false

    init(_ message: String, mayHaveWritten: Bool = false, recovery: String? = nil) {
        self.message = message
        self.mayHaveWritten = mayHaveWritten
        self.recovery = recovery
    }

    /// 包装下层错误，保留「是否临时」的判断。
    init(wrapping error: Error, mayHaveWritten: Bool = false, recovery: String? = nil) {
        self.init(error.localizedDescription, mayHaveWritten: mayHaveWritten, recovery: recovery)
        transient = OutboxPolicy.isTransient(error)
    }

    var errorDescription: String? {
        var text = message
        if mayHaveWritten { text += "（部分修改可能已写入云端）" }
        if let recovery { text += " " + recovery }
        return text
    }
}

struct RemovedRecord: Hashable, Sendable {
    let kind: RecordKind
    let cloudID: String
}

/// 一次业务操作对本地缓存的影响：读回的最新记录、已删除的记录。
struct ChangeSet: Sendable {
    var upserted: [RawRecord] = []
    var removed: [RemovedRecord] = []

    var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }
}

/// 操作失败时也带回已经发生的变化，便于更新本地缓存。
struct OperationFailure: Error, LocalizedError, Sendable {
    let message: String
    let changes: ChangeSet
    let needsSignIn: Bool
    /// 临时失败，可以入队重试。
    let transient: Bool
    /// 原始错误（MCP 需要从中取出 ServiceError 的附加信息）。
    let source: Error

    init(error: Error, changes: ChangeSet) {
        source = error
        message = error.localizedDescription
        self.changes = changes
        transient = OutboxPolicy.isTransient(error)
        if let auth = error as? AuthError {
            needsSignIn = auth == .reauthorizationRequired || auth == .notSignedIn
        } else {
            needsSignIn = false
        }
    }

    var errorDescription: String? { message }
}

// MARK: - 字段比较

extension JSONValue {
    static func of(_ value: Int) -> JSONValue { .int(Int64(value)) }
}

/// 与 Python 比较语义一致：业务 ID 按字符串比较，数字与布尔按数值比较（1 == 1.0 == True）。
enum AttributeMatch {
    static let identityKeys: Set<String> = ["id1", "id2", "id3", "time"]

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }

    static func matches(_ actual: JSONValue?, _ expected: JSONValue, key: String) -> Bool {
        if identityKeys.contains(key) {
            return (actual?.identifierString ?? "") == (expected.identifierString ?? "")
        }
        let value = actual ?? .null
        if let a = number(value), let b = number(expected) { return a == b }
        return value == expected
    }
}

// MARK: - 业务服务

/// 便单业务操作，对应 Python `BiandanTools`。
/// 所有操作串行执行（与 Python HTTP 模式的全局锁一致），写入后读回核对。
actor BiandanService {
    let cloud: SyncAPIClient
    let store: LocalStore
    let clock: @Sendable () -> Date

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 当前操作累积的变化。
    var pending = ChangeSet()

    init(cloud: SyncAPIClient, store: LocalStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.store = store
        self.clock = clock
    }

    // MARK: 串行执行

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func run<T: Sendable>(_ body: () async throws -> T) async throws -> (T, ChangeSet) {
        await acquire()
        defer { release() }
        pending = ChangeSet()
        do {
            let value = try await body()
            return (value, pending)
        } catch {
            throw OperationFailure(error: error, changes: pending)
        }
    }

    // MARK: 时间格式

    static func clockText(_ time: LocalTime) -> String {
        String(format: "%02d:%02d:00", time.hour, time.minute)
    }

    /// `YYYY-MM-DD HH:mm:00`，对应 Python `now().strftime("%Y-%m-%d %H:%M:00")`。
    func nowStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:00"
        return formatter.string(from: clock())
    }

    func today() -> LocalDate { LocalDate.today(clock()) }

    /// 对应 Python `date_window`：未给时刻时开始为 00:00:00、结束为 23:59:00。
    static func dateWindow(start: LocalDate, end: LocalDate?, startTime: LocalTime?, endTime: LocalTime?) throws -> JSONObject {
        let last = end ?? start
        let first = startTime.map(clockText) ?? "00:00:00"
        let final = endTime.map(clockText) ?? "23:59:00"
        if (start.iso, first) > (last.iso, final) {
            throw ServiceError("结束时间不能早于开始时间。")
        }
        return ["startTime": .string(start.iso), "endTime": .string(last.iso),
                "validStartTime": .string(first), "validEndTime": .string(final)]
    }

    // MARK: 记录读写（对应 find / fresh / patch / ensure_record / delete_record）

    func listAll(_ kind: RecordKind) async throws -> [RawRecord] {
        try await cloud.listAll(kind)
    }

    /// 按业务 ID 查记录。先用本地索引直接 GET；对不上再完整拉取该表查找（与 Python 一致，并检查重复）。
    func find(_ kind: RecordKind, _ identifier: String, in rows: [RawRecord]? = nil,
              required: Bool = true) async throws -> RawRecord? {
        guard BusinessID.isValid(identifier) else {
            throw ServiceError("请使用便单返回的正整数业务 ID。")
        }
        let key = kind.businessKey
        if rows == nil, let local = try? store.cloudIDs(kind, businessID: identifier), local.count == 1,
           let record = try? await cloud.get(kind, local[0]), record.attributes?.identifier(key) == identifier {
            pending.upserted.append(record)
            return record
        }
        let all: [RawRecord]
        if let rows { all = rows } else { all = try await cloud.listAll(kind) }
        let matches = all.filter { $0.attributes?.identifier(key) == identifier }
        if matches.count > 1 {
            throw ServiceError("有多条 \(kind.rawValue) 记录使用了同一个 ID \(identifier)。")
        }
        if let match = matches.first { return match }
        if required {
            throw ServiceError("找不到 ID 为 \(identifier) 的\(kind.title)，可能已在其他设备删除。")
        }
        return nil
    }

    func require(_ kind: RecordKind, _ identifier: String) async throws -> RawRecord {
        guard let record = try await find(kind, identifier) else {
            throw ServiceError("找不到 ID 为 \(identifier) 的\(kind.title)。")
        }
        return record
    }

    /// 读取最新版本。
    func fresh(_ record: RawRecord) async throws -> RawRecord {
        let latest = try await cloud.get(record.kind, record.cloudID)
        pending.upserted.append(latest)
        return latest
    }

    /// 只提交真正变化的字段，写后读回确认。
    /// 遇到 409（版本已变化）时重新读取并三方合并：其他设备只改了别的字段就重试，
    /// 改了同一个字段就以云端为准并提示「已被其他设备修改」。
    @discardableResult
    func patch(_ record: RawRecord, _ changes: JSONObject, reparent: Bool = false) async throws -> RawRecord {
        var base = record
        var diff = changes.filter { !AttributeMatch.matches(base.attributes?[$0.key], $0.value, key: $0.key) }
        guard !diff.isEmpty else { return record }
        var attempt = 0
        while true {
            guard let version = base.version else {
                throw ServiceError("记录缺少版本号，请重新同步后再试。")
            }
            do {
                _ = try await cloud.update(base.kind, base.cloudID, baseVersion: version, changes: diff, reparent: reparent)
                break
            } catch let error as CloudError where error.status == 409 && attempt < ConflictMerge.maxRetries {
                attempt += 1
                let latest = try await fresh(base)
                let resolution = ConflictMerge.resolve(base: base.attributes ?? [:], latest: latest.attributes ?? [:],
                                                       desired: diff)
                if !resolution.conflicts.isEmpty {
                    throw ServiceError(ConflictMerge.message(kind: base.kind, conflicts: resolution.conflicts))
                }
                if resolution.remaining.isEmpty { return latest }
                base = latest
                diff = resolution.remaining
            }
        }
        let updated = try await fresh(base)
        for (key, value) in diff where !AttributeMatch.matches(updated.attributes?[key], value, key: key) {
            throw ServiceError("云端读回没有确认\(record.kind.title)的修改。", mayHaveWritten: true)
        }
        return updated
    }

    /// 不存在则新建；存在（重试同一笔创建）则只核对。最后读回逐字段确认。
    func ensureRecord(_ kind: RecordKind, _ identifier: String, expected: JSONObject, existing: RawRecord?) async throws {
        var target = existing
        if target == nil {
            let created = try await cloud.create(kind, attributes: expected)
            if case .array(let saved)? = created["saveResults"], saved.count == 1,
               let receipt = try? RawRecord.normalize(saved[0], kind: kind) {
                target = receipt
            }
            if target == nil {
                target = try await find(kind, identifier, required: true)
            }
        }
        guard let target else { throw ServiceError("新建\(kind.title)后找不到记录。", mayHaveWritten: true) }
        let actual = try await fresh(target).attributes ?? [:]
        for (key, value) in expected where !AttributeMatch.matches(actual[key], value, key: key) {
            throw ServiceError("云端保存的\(kind.title)与要新建的内容不一致（\(key)）。", mayHaveWritten: true)
        }
    }

    /// 删除记录，404 视为已删除；409 时读取最新版本后重试。
    func deleteRecord(_ record: RawRecord) async throws {
        var target = record
        var attempt = 0
        deleting: while true {
            guard let version = target.version else {
                throw ServiceError("记录缺少版本号，请重新同步后再试。")
            }
            do {
                try await cloud.delete(target.kind, target.cloudID, baseVersion: version)
                break
            } catch let error as CloudError where error.status == 404 {
                break   // 已被删除
            } catch let error as CloudError where error.status == 409 && attempt < ConflictMerge.maxRetries {
                attempt += 1
                do {
                    target = try await fresh(target)
                } catch let missing as CloudError where missing.status == 404 {
                    break deleting
                }
            }
        }
        pending.removed.append(RemovedRecord(kind: record.kind, cloudID: record.cloudID))
    }

    /// 某任务的全部执行实例（完整拉取 showTask 后筛选，保证汇总准确）。
    func taskOccurrences(_ taskID: String) async throws -> [RawRecord] {
        try await cloud.listAll(.showTask).filter { $0.attributes?.identifier("id1") == taskID }
    }

    // MARK: - 待办单

    func validateList(_ listID: String) async throws -> Int {
        if listID != TodoList.defaultID {
            _ = try await require(.favorites, listID)
        }
        guard let value = Int(listID) else { throw ServiceError("无效的分类 ID。") }
        return value
    }

    func createList(name: String, colorIndex: Int, sortIndex: Int? = nil,
                    operationID: String? = nil) async throws -> (String, ChangeSet) {
        try await run {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ServiceError("请填写分类名称。") }
            guard (0...24).contains(colorIndex) else { throw ServiceError("颜色索引应在 0–24 之间。") }
            let identifier = operationID ?? BusinessID.generate(now: clock())
            guard BusinessID.isValid(identifier), identifier != TodoList.defaultID, let numeric = Int64(identifier) else {
                throw ServiceError("分类 ID 无效或为保留值 1。")
            }
            let rows = try await cloud.listAll(.favorites)
            let existing = try await find(.favorites, identifier, in: rows, required: false)
            let sort: Int
            if let sortIndex {
                sort = sortIndex
            } else if let existing {
                sort = ListColor(raw: existing.attributes?.int("favoritesColor") ?? 0).sortIndex
            } else {
                sort = (rows.map { ListColor(raw: $0.attributes?.int("favoritesColor") ?? 0).sortIndex }.max() ?? 0) + 1
            }
            do {
                try await ensureRecord(.favorites, identifier, expected: [
                    "id3": .int(numeric), "favoritesName": .string(trimmed), "favoritesColor": .of(sort * 100 + colorIndex),
                ], existing: existing)
            } catch {
                throw ServiceError(wrapping: error, mayHaveWritten: true, recovery: "请重试同一操作。")
            }
            return identifier
        }
    }

    func updateList(_ listID: String, name: String? = nil, colorIndex: Int? = nil,
                    sortIndex: Int? = nil) async throws -> ChangeSet {
        try await run {
            guard listID != TodoList.defaultID else { throw ServiceError("「未分类」不能编辑。") }
            guard name != nil || colorIndex != nil || sortIndex != nil else { throw ServiceError("没有要修改的内容。") }
            let row = try await fresh(try await require(.favorites, listID))
            var changes: JSONObject = [:]
            if let name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw ServiceError("请填写分类名称。") }
                changes["favoritesName"] = .string(trimmed)
            }
            if colorIndex != nil || sortIndex != nil {
                let old = ListColor(raw: row.attributes?.int("favoritesColor") ?? 0)
                if let colorIndex, !(0...24).contains(colorIndex) { throw ServiceError("颜色索引应在 0–24 之间。") }
                changes["favoritesColor"] = .of(ListColor(sortIndex: sortIndex ?? old.sortIndex,
                                                          colorIndex: colorIndex ?? old.colorIndex).raw)
            }
            try await patch(row, changes)
        }.1
    }

    /// 删除待办单：默认把任务移回「默认」，`deleteTasks` 时连同任务和实例一起删除。
    func deleteList(_ listID: String, deleteTasks: Bool) async throws -> ChangeSet {
        try await run {
            guard listID != TodoList.defaultID else { throw ServiceError("「未分类」不能删除。") }
            let folder = try await find(.favorites, listID, required: false)
            let matches = try await cloud.listAll(.task).filter { $0.attributes?.identifier("id3") == listID }
            if folder == nil && !matches.isEmpty {
                throw ServiceError("分类已不存在，但仍有任务引用它。请先移动这些任务。")
            }
            do {
                for row in matches {
                    if deleteTasks {
                        guard let taskID = row.attributes?.identifier("id1") else { continue }
                        try await deleteTaskBody(taskID, scope: .series, occurrenceID: nil, fromDate: nil, expectedList: listID)
                    } else {
                        try await patch(row, ["id3": .of(1)])
                    }
                }
                if let folder {
                    let remaining = try await cloud.listAll(.task).contains { $0.attributes?.identifier("id3") == listID }
                    if remaining { throw ServiceError("仍有任务引用这个分类。") }
                    try await deleteRecord(folder)
                }
            } catch {
                throw ServiceError(wrapping: error, mayHaveWritten: true, recovery: "请同步后重试同一操作。")
            }
        }.1
    }

    // MARK: - 任务编辑

    func updateTask(_ taskID: String, title: String? = nil, remark: String? = nil, important: Bool? = nil,
                    urgent: Bool? = nil, collected: Bool? = nil) async throws -> ChangeSet {
        try await run {
            let current = try await fresh(try await require(.task, taskID))
            var changes: JSONObject = [:]
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw ServiceError("任务标题不能为空。") }
                changes["taskTitle"] = .string(trimmed)
            }
            if let remark {
                // 改备注时保留子任务和附件。
                var content = TaskContent.decode(current.attributes?.string("taskContent") ?? "")
                content.remark = remark
                changes["taskContent"] = .string(content.encoded())
            }
            if let important { changes["isImportant"] = .of(important ? 1 : 0) }
            if let urgent { changes["isUrgency"] = .of(urgent ? 1 : 0) }
            if let collected { changes["isCollectible"] = .of(collected ? 1 : 0) }
            guard !changes.isEmpty else { throw ServiceError("没有要修改的内容。") }
            try await patch(current, changes)
        }.1
    }

    func moveTask(_ taskID: String, to listID: String) async throws -> ChangeSet {
        try await run {
            let destination = try await validateList(listID)
            let task = try await fresh(try await require(.task, taskID))
            try await patch(task, ["id3": .of(destination)])
        }.1
    }

    /// 对应 Python `location_changes`。
    static func locationChanges(_ row: JSONObject, name: String?, latitude: Double?, longitude: Double?,
                                remind: Bool?, clear: Bool) throws -> JSONObject {
        let flags = row.int("isRemind") ?? 0
        if clear {
            guard name == nil, latitude == nil, longitude == nil, remind == nil else {
                throw ServiceError("清除地点时不能同时设置地点或提醒。")
            }
            return ["location": .string(""), "latitude": .of(-1), "longitude": .of(-1), "isRemind": .of(flags & ~2)]
        }
        guard name != nil || latitude != nil || longitude != nil || remind != nil else {
            throw ServiceError("请提供地点、坐标或提醒设置。")
        }
        guard (latitude == nil) == (longitude == nil) else { throw ServiceError("纬度和经度需要一起提供。") }
        var changes: JSONObject = [:]
        if let name { changes["location"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let latitude, let longitude {
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw ServiceError("坐标超出有效范围。")
            }
            changes["latitude"] = .double(latitude)
            changes["longitude"] = .double(longitude)
        }
        if let remind {
            let lat = latitude ?? row.double("latitude")
            let lon = longitude ?? row.double("longitude")
            if remind, lat == nil || lon == nil || (lat == -1 && lon == -1) {
                throw ServiceError("开启地点提醒需要实际的地图坐标。")
            }
            changes["isRemind"] = .of(remind ? (flags | 2) : (flags & ~2))
        } else if latitude == -1 && longitude == -1 {
            changes["isRemind"] = .of(flags & ~2)
        }
        return changes
    }

    func setLocation(_ taskID: String, name: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                     remind: Bool? = nil, clear: Bool = false) async throws -> ChangeSet {
        try await run {
            let current = try await fresh(try await require(.task, taskID))
            let changes = try Self.locationChanges(current.attributes ?? [:], name: name, latitude: latitude,
                                                   longitude: longitude, remind: remind, clear: clear)
            try await patch(current, changes)
        }.1
    }

    /// 开启需同时给日期和时刻；关闭只清时间提醒位，保留地点提醒。
    func setTimeReminder(_ taskID: String, date: LocalDate?, time: LocalTime?, enabled: Bool) async throws -> ChangeSet {
        try await run {
            let task = try await fresh(try await require(.task, taskID))
            let flags = task.attributes?.int("isRemind") ?? 0
            let changes: JSONObject
            if enabled {
                guard let date, let time else { throw ServiceError("开启时间提醒需要日期和时刻。") }
                changes = ["remindDate": .string(date.iso), "remindTime": .string(Self.clockText(time)),
                           "isRemind": .of(flags | 1)]
            } else {
                guard date == nil, time == nil else { throw ServiceError("关闭提醒时不要传日期和时刻。") }
                changes = ["isRemind": .of(flags & ~1)]
            }
            try await patch(task, changes)
        }.1
    }
}
