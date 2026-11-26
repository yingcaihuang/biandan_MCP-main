import Foundation

// MARK: - AI 识别的用量记录：每次调用的用时、token、费用估算，存在本机，供「统计 → AI 识别」使用

enum AIUsageTrigger: String, Codable, CaseIterable, Sendable {
    case fallback, always, manual, test, quickAdd

    var title: String {
        switch self {
        case .fallback: return "规则兜底"
        case .always: return "总是用 AI"
        case .manual: return "手动重跑"
        case .test: return "测试连接"
        case .quickAdd: return "快速添加"
        }
    }
}

/// 接口返回的 usage 字段。DeepSeek 额外给出缓存命中 / 未命中的输入 token。
struct AITokenUsage: Equatable, Sendable {
    var prompt = 0
    var completion = 0
    var cacheHit = 0
    var cacheMiss = 0

    init(prompt: Int = 0, completion: Int = 0, cacheHit: Int = 0, cacheMiss: Int = 0) {
        self.prompt = prompt
        self.completion = completion
        self.cacheHit = cacheHit
        self.cacheMiss = cacheMiss
    }

    init(json: [String: Any]) {
        func int(_ key: String) -> Int {
            if let number = json[key] as? NSNumber { return number.intValue }
            return json[key] as? Int ?? 0
        }
        prompt = int("prompt_tokens")
        completion = int("completion_tokens")
        cacheHit = int("prompt_cache_hit_tokens")
        cacheMiss = int("prompt_cache_miss_tokens")
        if cacheHit == 0, let details = json["prompt_tokens_details"] as? [String: Any],
           let cached = details["cached_tokens"] as? NSNumber {
            cacheHit = cached.intValue
            cacheMiss = max(prompt - cacheHit, 0)
        }
    }
}

struct AIUsageRecord: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var model: String
    var host: String
    var trigger: AIUsageTrigger
    var durationMs = 0
    var promptTokens = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var completionTokens = 0
    /// 发送的文字字数（含今天日期、可选分类等说明）。
    var inputCharacters = 0
    var events = 0
    var truncated = false
    var success = false
    var error: String?
    /// 按官方价目估算的费用（美元）；不是 DeepSeek 接口或模型未知时为 nil。
    var costUSD: Double?

    var totalTokens: Int { promptTokens + completionTokens }
    var seconds: Double { Double(durationMs) / 1000 }
    /// 接口给出了缓存命中 / 未命中的拆分。
    var reportsCache: Bool { cacheHitTokens + cacheMissTokens > 0 }

    mutating func apply(_ usage: AITokenUsage) {
        promptTokens = usage.prompt
        completionTokens = usage.completion
        cacheHitTokens = usage.cacheHit
        cacheMissTokens = usage.cacheMiss
        costUSD = AIPricing.cost(model: model, host: host, usage: usage, at: date)
    }

    mutating func finish(started: Date, events: Int, error: String?) {
        durationMs = max(Int((Date().timeIntervalSince(started) * 1000).rounded()), 0)
        self.events = events
        self.error = error
        success = error == nil
    }
}

// MARK: - 费用估算（DeepSeek 官方价目，每百万 token，美元）

enum AIPricing {
    struct Rate: Equatable {
        let cacheHit: Double
        let cacheMiss: Double
        let output: Double
    }

    /// 非高峰价；高峰时段（UTC 周一至周五 01:00–04:00、06:00–10:00）为两倍。
    static func offPeakRate(model: String) -> Rate? {
        let name = model.lowercased()
        guard name.contains("deepseek") else { return nil }
        if name.contains("pro") { return Rate(cacheHit: 0.022, cacheMiss: 0.66, output: 1.98) }
        return Rate(cacheHit: 0.003, cacheMiss: 0.15, output: 0.6)
    }

    /// 没有扣除中国法定节假日（节假日全天按非高峰价），所以工作日的节假日会略微高估。
    static func isPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    static func cost(model: String, host: String, usage: AITokenUsage, at date: Date) -> Double? {
        guard host.lowercased().contains("deepseek"), let rate = offPeakRate(model: model) else { return nil }
        let reported = usage.cacheHit + usage.cacheMiss > 0
        let hit = reported ? usage.cacheHit : 0
        let miss = reported ? usage.cacheMiss : usage.prompt
        let factor: Double = isPeak(date) ? 2 : 1
        let hitCost = Double(hit) * rate.cacheHit
        let missCost = Double(miss) * rate.cacheMiss
        let outputCost = Double(usage.completion) * rate.output
        return (hitCost + missCost + outputCost) * factor / 1_000_000
    }
}

// MARK: - 本机记录

@MainActor
@Observable
final class AIUsageLog {
    static let shared = AIUsageLog(url: AIUsageLog.defaultURL())
    /// 最多保留的条数，超出时丢掉最早的。
    static let limit = 5000

    private(set) var records: [AIUsageRecord] = []
    @ObservationIgnored private let url: URL?

    /// url 为 nil 时只在内存里记（测试用）。
    init(url: URL?) {
        self.url = url
        load()
    }

    nonisolated static func defaultURL() -> URL? {
        return AppPaths.supportDirectory()?.appendingPathComponent("ai-usage.json")
    }

    /// 从任意线程记一条。
    static func record(_ record: AIUsageRecord) {
        shared.append(record)
    }

    func append(_ record: AIUsageRecord) {
        records.append(record)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([AIUsageRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 导出 CSV（按时间先后）。
    func csv() -> String {
        let header: [String] = [
            "时间", "模型", "接口", "触发方式", "用时(毫秒)", "输入tokens", "缓存命中tokens", "缓存未命中tokens",
            "输出tokens", "总tokens", "发送字数", "识别出日程", "结果", "预估费用(美元)", "错误",
        ]
        var lines: [String] = [header.joined(separator: ",")]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        for record in records.sorted(by: { $0.date < $1.date }) {
            let cost: String = record.costUSD.map { String(format: "%.6f", $0) } ?? ""
            let fields: [String] = [
                formatter.string(from: record.date), record.model, record.host, record.trigger.title,
                String(record.durationMs), String(record.promptTokens), String(record.cacheHitTokens),
                String(record.cacheMissTokens), String(record.completionTokens), String(record.totalTokens),
                String(record.inputCharacters), String(record.events), record.success ? "成功" : "失败", cost,
                record.error ?? "",
            ]
            lines.append(fields.map(Self.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - 格式化

enum AIUsageFormat {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func tokens(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.2f 亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f 万", Double(value) / 10_000) }
        return decimal.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.1f 秒", value) : String(format: "%.0f 秒", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "$0" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// 「用时 2.3 秒 · 1,234 tokens · 约 $0.0004」
    static func brief(_ record: AIUsageRecord) -> String {
        var parts: [String] = ["用时 " + seconds(record.seconds)]
        if record.totalTokens > 0 { parts.append(tokens(record.totalTokens) + " tokens") }
        if let cost = record.costUSD { parts.append("约 " + self.cost(cost)) }
        return parts.joined(separator: " · ")
    }
}
