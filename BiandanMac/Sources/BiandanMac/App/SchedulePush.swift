import CryptoKit
import Foundation
import Observation
import Security

// MARK: - 推送给远程 biandan-api 的日程快照（格式见 BiandanAPI/README.md）

struct SchedulePayload: Encodable, Sendable {
    struct List: Encodable, Sendable {
        var id: String
        var name: String
        var color: String
        var order: Int
        var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, color, order
            case isDefault = "is_default"
        }
    }

    struct Source: Encodable, Hashable, Sendable {
        var kind: String
        var name: String
        static let biandan = Source(kind: "biandan", name: "便单")
    }

    struct Reminder: Encodable, Sendable {
        var date: String?
        var time: String?
    }

    struct Item: Encodable, Sendable {
        var occurrenceID: String
        var taskID: String
        var listID: String
        var title: String
        var remark: String?
        var subtasks: [String]?
        var undated: Bool
        var allDay: Bool
        var startDate: String?
        var endDate: String?
        var startTime: String?
        var endTime: String?
        var status: String
        var completedAt: String?
        var important: Bool
        var urgent: Bool
        var collected: Bool
        var repeating: Bool
        var habit: Bool
        var repeatRule: String?
        var location: String?
        var reminder: Reminder?
        var source: Source

        enum CodingKeys: String, CodingKey {
            case occurrenceID = "occurrence_id", taskID = "task_id", listID = "list_id"
            case title, remark, subtasks, undated
            case allDay = "all_day", startDate = "start_date", endDate = "end_date"
            case startTime = "start_time", endTime = "end_time", status
            case completedAt = "completed_at", important, urgent, collected, repeating, habit
            case repeatRule = "repeat_rule", location, reminder, source
        }
    }

    let format = "biandan-schedule"
    let version = 1
    var generatedAt: String?
    var timezone: String
    var device: String
    var lists: [List]
    var items: [Item]

    enum CodingKeys: String, CodingKey {
        case format, version, timezone, device, lists, items
        case generatedAt = "generated_at"
    }

    /// 把本地快照转成推送格式。sources：任务 ID → 导入来源；不在里面的是便单里直接建的。
    static func build(snapshot: DataSnapshot, sources: [String: Source], timeZone: TimeZone, device: String) -> SchedulePayload {
        let lists = snapshot.lists.map { list in
            List(id: list.id3, name: list.displayName, color: hexColor(list.color.hex),
                 order: list.color.sortIndex, isDefault: list.isDefault)
        }
        var items: [Item] = []
        for entry in DataExport.allItems(snapshot) {
            let task = entry.task
            let occurrence = entry.occurrence
            let content = task.content
            let start = occurrence.startDate
            let dated = !task.undated && start != nil
            let allDay = dated && DataExport.isAllDay(occurrence)
            let timed = dated && !allDay
            items.append(Item(
                occurrenceID: occurrence.id2, taskID: task.id1, listID: task.id3, title: task.taskTitle,
                remark: content.remark.isEmpty ? nil : content.remark,
                subtasks: content.subtasks.isEmpty ? nil : content.subtasks,
                undated: !dated, allDay: allDay,
                startDate: dated ? start?.iso : nil,
                endDate: dated ? (occurrence.endDate ?? start)?.iso : nil,
                startTime: timed ? occurrence.startClock?.shortText : nil,
                endTime: timed ? occurrence.endClock?.shortText : nil,
                status: entry.status.rawValue, completedAt: occurrence.completedAt,
                important: task.important, urgent: task.urgent, collected: task.collected,
                repeating: task.isRepeating, habit: task.isHabit,
                repeatRule: task.isRepeating ? RuleSummary.describe(task) : nil,
                location: task.location.isEmpty ? nil : task.location,
                reminder: reminder(task), source: sources[task.id1] ?? .biandan))
        }
        // 固定顺序：内容不变时编码结果（和哈希）也不变。
        items.sort { $0.occurrenceID < $1.occurrenceID }
        return SchedulePayload(generatedAt: nil, timezone: timeZone.identifier, device: device, lists: lists, items: items)
    }

    private static func hexColor(_ value: UInt32) -> String {
        let digits = String(value & 0xFF_FFFF, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    private static func reminder(_ task: TaskDef) -> Reminder? {
        guard task.hasTimeReminder else { return nil }
        let date = LocalDate(iso: task.remindDate)?.iso
        let time = LocalTime(text: task.remindTime ?? "")?.shortText
        return date == nil && time == nil ? nil : Reminder(date: date, time: time)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 不含生成时间的内容哈希：判断要不要重新推送。
    func contentHash() -> String {
        var copy = self
        copy.generatedAt = nil
        let data = (try? copy.encoded()) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 推送密钥

/// 推送密钥：先读钥匙串（设置里粘贴保存的），没有再读 ~/.biandan-api/push-mac.key（BiandanAPI/deploy.sh 生成，权限 600）。
enum SchedulePushKeyStore {
    enum Origin: Equatable { case keychain, file, none }

    private static let service = "ai.racore.BiandanMac"
    private static let account = "schedule-push-key"

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".biandan-api", isDirectory: true)
            .appendingPathComponent("push-mac.key")
    }

    /// bdp_ 加 43 位 base64url。
    static func isValid(_ key: String) -> Bool {
        guard key.hasPrefix("bdp_"), key.count == 47 else { return false }
        return key.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> (key: String, origin: Origin)? {
        if DebugFlags.offline { return nil }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
           let key = String(data: data, encoding: .utf8), isValid(key) {
            return (key, .keychain)
        }
        if let text = try? String(contentsOf: fileURL, encoding: .ascii) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValid(key) { return (key, .file) }
        }
        return nil
    }

    static func save(_ key: String) throws {
        guard isValid(key) else {
            throw SchedulePushError("推送密钥格式不对：应为 bdp_ 开头的 47 个字符")
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "便单 远程日程推送密钥"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SchedulePushError("无法把推送密钥存进钥匙串（\(status)）") }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

struct SchedulePushError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 推送

/// 把日程快照推到远程 biandan-api。本地数据变化后 3 秒推送（防抖）；内容没变时每 10 分钟推一次当心跳，
/// 让设备从 data_age_seconds 知道数据是否新鲜；失败按 30 秒、1、2、4… 分钟退避，最长 30 分钟。
/// 只在登录且至少同步过一次时推送：退出登录清空本地库后不会把远程数据也清空。
@MainActor
@Observable
final class SchedulePusher {
    enum Status: Equatable {
        case off, waiting, pushing, ok, failed(String)
    }

    static let defaultEndpoint = "https://www.aigslb.link/biandan/api"
    static let heartbeat: TimeInterval = 600
    static let maxBackoff: TimeInterval = 1800

    private enum Keys {
        static let enabled = "biandan.schedulePush.enabled"
        static let endpoint = "biandan.schedulePush.endpoint"
    }

    var enabled: Bool = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled {
                status = .waiting
                pushNow()
            } else {
                pending?.cancel()
                status = .off
            }
        }
    }

    var endpoint: String = UserDefaults.standard.string(forKey: Keys.endpoint) ?? SchedulePusher.defaultEndpoint {
        didSet {
            UserDefaults.standard.set(endpoint, forKey: Keys.endpoint)
            lastHash = nil
        }
    }

    private(set) var status: Status = .off
    private(set) var keyOrigin: SchedulePushKeyStore.Origin = .none
    private(set) var lastPushAt: Date?
    private(set) var lastItemCount = 0
    private(set) var lastListCount = 0
    private(set) var lastVersion: String?
    private(set) var failures = 0

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var lastHash: String?
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var again = false

    init() {}

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        reloadKey()
        if enabled { status = .waiting }
        // 每 30 秒检查一次：心跳到期或退避结束就推送（run 自己判断要不要真的发）。
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                if self.enabled && !self.inFlight { await self.run(force: false) }
            }
        }
    }

    /// 本地快照刷新后调用：3 秒内多次变化只推一次。
    func noteChange() { schedule(after: .seconds(3), force: false) }

    /// 设置页「立即推送」：不等防抖、不管退避、内容没变也推。
    func pushNow() { schedule(after: .zero, force: true) }

    func reloadKey() {
        let loaded = SchedulePushKeyStore.load()
        key = loaded?.key
        keyOrigin = loaded?.origin ?? .none
        lastHash = nil
    }

    func saveKey(_ text: String) throws {
        try SchedulePushKeyStore.save(text.trimmingCharacters(in: .whitespacesAndNewlines))
        reloadKey()
        if enabled { pushNow() }
    }

    func clearKey() {
        SchedulePushKeyStore.clear()
        reloadKey()
    }

    var pushURL: URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let base = URL(string: text), let host = base.host, !host.isEmpty else { return nil }
        // 密钥只走 HTTPS；本机调试可以用 http://127.0.0.1。
        let local = host == "127.0.0.1" || host == "localhost"
        guard base.scheme == "https" || (base.scheme == "http" && local) else { return nil }
        return URL(string: text + "/v1/push")
    }

    private func schedule(after delay: Duration, force: Bool) {
        guard enabled, model != nil else { return }
        if inFlight {
            again = true
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.run(force: force)
        }
    }

    private func run(force: Bool) async {
        guard enabled, let model, !inFlight else { return }
        guard let key else {
            status = .failed("还没有推送密钥")
            return
        }
        guard let url = pushURL else {
            status = .failed("接口地址要以 https:// 开头")
            return
        }
        guard model.authState == .signedIn, model.snapshot.lastPulledAt != nil else {
            status = .waiting
            return
        }
        let now = Date()
        if !force, let retryAt, retryAt > now { return }
        var payload = SchedulePayload.build(snapshot: model.snapshot, sources: model.scheduleSourceMap(),
                                            timeZone: .current, device: Self.deviceName)
        let hash = payload.contentHash()
        if !force, hash == lastHash, let last = lastPushAt, now.timeIntervalSince(last) < Self.heartbeat { return }

        inFlight = true
        status = .pushing
        defer {
            inFlight = false
            if again {
                again = false
                schedule(after: .seconds(1), force: false)
            }
        }
        payload.generatedAt = ISO8601DateFormatter.string(from: now, timeZone: .current,
                                                          formatOptions: [.withInternetDateTime])
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try payload.encoded()
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (200..<300).contains(code), object?["ok"] as? Bool == true else {
                let detail = (object?["error"] as? [String: Any])?["message"] as? String
                throw SchedulePushError(code == 401 ? "推送密钥无效（HTTP 401）"
                                        : "服务器返回 HTTP \(code)" + (detail.map { "：\($0)" } ?? ""))
            }
            lastHash = hash
            lastPushAt = Date()
            lastItemCount = payload.items.count
            lastListCount = payload.lists.count
            lastVersion = object?["version"] as? String
            failures = 0
            retryAt = nil
            status = .ok
        } catch {
            failures += 1
            let delay = min(30 * pow(2, Double(failures - 1)), Self.maxBackoff)
            retryAt = Date().addingTimeInterval(delay)
            status = .failed(error.localizedDescription)
        }
    }

    private static var deviceName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "BiandanMac \(version)"
    }

    // MARK: 设置页显示

    var statusTitle: String {
        switch status {
        case .off: return "未开启"
        case .waiting: return "等待同步"
        case .pushing: return "正在推送"
        case .ok: return "已推送"
        case .failed: return "推送失败"
        }
    }

    var statusDetail: String? {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        var parts: [String] = []
        if let last = lastPushAt {
            parts.append("上次推送 \(clock.string(from: last))：\(lastListCount) 个分类、\(lastItemCount) 条日程"
                         + (lastVersion.map { "，版本 \($0)" } ?? ""))
        }
        switch status {
        case .failed(let message):
            parts.append(message + (retryAt.map { "，\(clock.string(from: $0)) 自动重试" } ?? ""))
        case .waiting:
            parts.append("登录并完成一次同步后开始推送")
        default:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: "。")
    }
}
