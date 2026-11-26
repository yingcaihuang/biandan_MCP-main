import Foundation

// MARK: - AI 决策的记录：每次判断的结果、用时、省下的费用，存在本机，供确认卡片、浮窗球和「统计 → AI 识别」使用

struct DecisionRecord: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var trigger: AIUsageTrigger
    var sensitivity: DecisionSensitivity
    /// 拦下时本来要调用的大模型。
    var aiModel: String
    /// 用的决策模型和地域（旧记录没有，显示时按默认）。
    var decisionModel: String? = nil
    var region: String? = nil
    var outcome: DecisionOutcome = .failed
    var reason = ""
    var answers: DecisionAnswers?
    /// 本机从发请求到拿到结果的用时。
    var durationMs = 0
    /// 服务端返回的耗时。
    var serverMs: Double?
    var inputTokens = 0
    var inputCharacters = 0
    /// 拦下时估算省下的大模型费用（美元）；无法估算为 nil。
    var savedUSD: Double?
    /// 拦下时估算少等的时间。
    var savedMs: Int?
    /// 决策模型本身的费用；目前限时免费。
    var costUSD: Double = 0
    var error: String?
    /// 拦下之后手动用 AI 重跑时，AI 找到的日程条数；没重跑为 nil。大于 0 算误拦。
    var overrideEvents: Int?

    var falseBlock: Bool { outcome == .block && (overrideEvents ?? 0) > 0 }
    var netSavedUSD: Double? { savedUSD.map { $0 - costUSD } }
}

// MARK: - 省下的钱

enum DecisionSavings {
    /// 参考最近这么多次成功的 AI 调用。
    static let historyLimit = 50
    /// 没有历史记录时按这么久估算少等的时间。
    static let fallbackMs = 1000
    /// 没有历史记录时按价目估：系统提示词约 1,600 token，正文每字约 0.7 token，输出约 30 token。
    static let promptTokens = 1600
    static let tokensPerCharacter = 0.7
    static let outputTokens = 30

    @MainActor
    static func estimate(characters: Int, model: String, host: String, at date: Date) -> (cost: Double?, ms: Int) {
        estimate(characters: characters, model: model, host: host, history: AIUsageLog.shared.records, at: date)
    }

    /// 有历史记录：按每字平均费用（换算成非高峰价）× 这次的字数，再按现在是否高峰调整；否则按价目估。
    static func estimate(characters: Int, model: String, host: String, history: [AIUsageRecord],
                         at date: Date) -> (cost: Double?, ms: Int) {
        let recent = Array(history.filter { $0.success && $0.trigger != .test && $0.trigger != .quickAdd }.suffix(historyLimit))
        let sameModel = recent.filter { $0.model == model }
        let pool = sameModel.isEmpty ? recent : sameModel
        let ms = pool.isEmpty ? fallbackMs : pool.map(\.durationMs).reduce(0, +) / pool.count
        let factor: Double = AIPricing.isPeak(date) ? 2 : 1
        let priced = pool.filter { $0.costUSD != nil && $0.inputCharacters > 0 }
        if !priced.isEmpty {
            var cost = 0.0
            var total = 0
            for record in priced {
                let peak: Double = AIPricing.isPeak(record.date) ? 2 : 1
                cost += (record.costUSD ?? 0) / peak
                total += record.inputCharacters
            }
            return (cost / Double(total) * Double(characters) * factor, ms)
        }
        let usage = AITokenUsage(prompt: promptTokens + Int(Double(characters) * tokensPerCharacter),
                                 completion: outputTokens)
        return (AIPricing.cost(model: model, host: host, usage: usage, at: date), ms)
    }
}

// MARK: - 本机记录

@MainActor
@Observable
final class DecisionLog {
    static let shared = DecisionLog(url: DecisionLog.defaultURL())
    static let limit = 5000

    private(set) var records: [DecisionRecord] = []
    @ObservationIgnored private let url: URL?

    /// url 为 nil 时只在内存里记（测试用）。
    init(url: URL?) {
        self.url = url
        load()
    }

    nonisolated static func defaultURL() -> URL? {
        return AppPaths.supportDirectory()?.appendingPathComponent("decision-usage.json")
    }

    static func record(_ record: DecisionRecord) {
        shared.append(record)
    }

    func append(_ record: DecisionRecord) {
        records.append(record)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        save()
    }

    /// 拦下之后用户手动用 AI 重跑：记下 AI 找到了几条（找到了就算误拦）。
    func markOverride(id: UUID, events: Int) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].overrideEvents = events
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
        records = (try? decoder.decode([DecisionRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func csv() -> String {
        let header: [String] = [
            "时间", "触发方式", "灵敏度", "结果", "依据", "有日程概率", "清晰度", "内容类型", "状态", "用时(毫秒)",
            "服务端用时(毫秒)", "输入tokens", "发送字数", "本来要用的模型", "省下费用(美元)", "省下用时(毫秒)",
            "手动重跑找到日程", "错误", "决策模型", "地域",
        ]
        var lines: [String] = [header.joined(separator: ",")]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        for record in records.sorted(by: { $0.date < $1.date }) {
            let answers = record.answers
            let fields: [String] = [
                formatter.string(from: record.date), record.trigger.title, record.sensitivity.title,
                record.outcome.title, record.reason,
                answers.map { String(format: "%.3f", $0.hasSchedule) } ?? "",
                answers?.clarity.map { String(format: "%.2f", $0) } ?? "",
                answers?.kindTitle ?? "", answers?.statusTitle ?? "",
                String(record.durationMs), record.serverMs.map { String(format: "%.1f", $0) } ?? "",
                String(record.inputTokens), String(record.inputCharacters), record.aiModel,
                record.savedUSD.map { String(format: "%.6f", $0) } ?? "",
                record.savedMs.map(String.init) ?? "",
                record.overrideEvents.map(String.init) ?? "", record.error ?? "",
                record.decisionModel ?? DecisionSettings.model, record.region ?? "",
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

// MARK: - 统计

/// 按天（或按周）的一段：放行、拦下、失败各几次，省下的费用、时间、字数，判断用时。
struct DecisionBucket: Identifiable, Hashable, Sendable {
    let start: LocalDate
    var passed = 0
    var blocked = 0
    var failed = 0
    var saved: Double = 0
    var savedMs = 0
    var savedCharacters = 0
    var durationMs = 0
    var timed = 0

    var id: LocalDate { start }
    var total: Int { passed + blocked + failed }
    var blockRate: Double? { passed + blocked > 0 ? Double(blocked) / Double(passed + blocked) : nil }
    var averageMs: Double? { timed > 0 ? Double(durationMs) / Double(timed) : nil }

    mutating func add(_ record: DecisionRecord) {
        switch record.outcome {
        case .pass:
            passed += 1
        case .block:
            blocked += 1
            saved += record.netSavedUSD ?? 0
            savedMs += record.savedMs ?? 0
            savedCharacters += record.inputCharacters
        case .failed:
            failed += 1
        }
        if record.outcome != .failed {
            durationMs += record.durationMs
            timed += 1
        }
    }
}

/// 按某个维度分的一组：内容类型、状态、触发方式、灵敏度、概率区间、用时区间、时段、失败原因……
struct DecisionGroup: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    /// 悬停提示的标题；nil 时用 title。
    var detail: String? = nil
    var passed = 0
    var blocked = 0
    var failed = 0
    var saved: Double = 0
    var durationMs = 0
    var timed = 0

    var total: Int { passed + blocked + failed }
    var blockRate: Double? { passed + blocked > 0 ? Double(blocked) / Double(passed + blocked) : nil }
    var averageMs: Double? { timed > 0 ? Double(durationMs) / Double(timed) : nil }

    mutating func add(_ record: DecisionRecord) {
        switch record.outcome {
        case .pass:
            passed += 1
        case .block:
            blocked += 1
            saved += record.netSavedUSD ?? 0
        case .failed:
            failed += 1
        }
        if record.outcome != .failed {
            durationMs += record.durationMs
            timed += 1
        }
    }
}

struct DecisionSummary {
    var start: LocalDate
    var end: LocalDate
    var buckets: [DecisionBucket]
    /// 范围内的记录，最新的在前。
    var records: [DecisionRecord] = []
    var calls = 0
    var passed = 0
    var blocked = 0
    var failed = 0
    /// 拦下后手动用 AI 重跑的次数，以及其中 AI 找到了日程的次数。
    var overrides = 0
    var falseBlocks = 0
    var saved: Double = 0
    var savedKnown = false
    var savedMs = 0
    /// 拦下后没有发给大模型的字数。
    var savedCharacters = 0
    var inputTokens = 0
    var characters = 0
    /// 放行和拦下的判断用时（本机计时）。
    var averageMs: Double?
    var medianMs: Double?
    var p95Ms: Double?
    var serverAverageMs: Double?
    /// 有日程概率离门槛不到 borderlineMargin 的次数。
    var borderline = 0
    var topError: String?

    var probabilityBins: [DecisionGroup] = []
    var clarityBins: [DecisionGroup] = []
    var latencyBins: [DecisionGroup] = []
    var hours: [DecisionGroup] = []
    var kinds: [DecisionGroup] = []
    var statuses: [DecisionGroup] = []
    var triggers: [DecisionGroup] = []
    var sensitivities: [DecisionGroup] = []
    var aiModels: [DecisionGroup] = []
    var errors: [DecisionGroup] = []

    var judged: Int { passed + blocked }
    /// 只算判断成功的那部分。
    var blockRate: Double? { judged > 0 ? Double(blocked) / Double(judged) : nil }
    var falseBlockRate: Double? { overrides > 0 ? Double(falseBlocks) / Double(overrides) : nil }
    var failureRate: Double? { calls > 0 ? Double(failed) / Double(calls) : nil }
    var averageCharacters: Double? { calls > 0 ? Double(characters) / Double(calls) : nil }
    var averageTokens: Double? { calls > 0 ? Double(inputTokens) / Double(calls) : nil }
    /// 本机平均用时减去服务端平均用时，约等于网络往返。
    var networkAverageMs: Double? {
        guard let averageMs, let serverAverageMs else { return nil }
        return max(averageMs - serverAverageMs, 0)
    }
}

enum DecisionStats {
    static let probabilityLimits: [(upper: Double, title: String, detail: String)] = [
        (0.1, "0–10%", "有日程概率 0–10%"), (0.3, "10–30%", "有日程概率 10–30%"),
        (0.5, "30–50%", "有日程概率 30–50%"), (0.7, "50–70%", "有日程概率 50–70%"),
        (0.9, "70–90%", "有日程概率 70–90%"), (.infinity, "90–100%", "有日程概率 90–100%"),
    ]
    static let clarityLimits: [(upper: Double, title: String, detail: String)] = [
        (0.5, "0–0.5", "清晰度 0–0.5（看不出时间）"), (1.5, "0.5–1.5", "清晰度 0.5–1.5"),
        (2.5, "1.5–2.5", "清晰度 1.5–2.5"), (3.5, "2.5–3.5", "清晰度 2.5–3.5"),
        (.infinity, "3.5–4", "清晰度 3.5–4（时间地点都清楚）"),
    ]
    static let latencyLimits: [(upper: Double, title: String, detail: String)] = [
        (100, "<0.1秒", "判断用时不到 100 毫秒"), (200, "0.1–0.2", "判断用时 100–200 毫秒"),
        (300, "0.2–0.3", "判断用时 200–300 毫秒"), (500, "0.3–0.5", "判断用时 300–500 毫秒"),
        (1000, "0.5–1秒", "判断用时 0.5–1 秒"), (3000, "1–3秒", "判断用时 1–3 秒"),
        (.infinity, "≥3秒", "判断用时 3 秒以上（多半是超时）"),
    ]
    /// 有日程概率离门槛不到这么多算临界判断。
    static let borderlineMargin = 0.10

    static func bin(_ value: Double, _ uppers: [Double]) -> Int {
        uppers.firstIndex { value < $0 } ?? max(uppers.count - 1, 0)
    }

    static func summary(_ all: [DecisionRecord], range: StatsRange, today: LocalDate, weekStart: Int,
                        calendar: Calendar = .current) -> DecisionSummary {
        let end = today
        var start = today.adding(days: -(range.rawValue - 1))
        if range.bucketDays == 7 {
            let shift = ((start.weekday - weekStart) % 7 + 7) % 7
            start = start.adding(days: -shift)
        }
        var buckets: [DecisionBucket] = []
        var day = start
        while day <= end {
            buckets.append(DecisionBucket(start: day))
            day = day.adding(days: range.bucketDays)
        }
        var summary = DecisionSummary(start: start, end: end, buckets: buckets)
        let startDate = start.date(calendar: calendar)
        var durations: [Int] = []
        var serverTotal = 0.0
        var serverCount = 0
        let probabilityUppers = probabilityLimits.map { $0.upper }
        let clarityUppers = clarityLimits.map { $0.upper }
        let latencyUppers = latencyLimits.map { $0.upper }
        var probability = probabilityLimits.map { DecisionGroup(id: "p" + $0.title, title: $0.title, detail: $0.detail) }
        var clarity = clarityLimits.map { DecisionGroup(id: "c" + $0.title, title: $0.title, detail: $0.detail) }
        var latency = latencyLimits.map { DecisionGroup(id: "l" + $0.title, title: $0.title, detail: $0.detail) }
        var hours: [DecisionGroup] = (0..<24).map { hour in
            DecisionGroup(id: "h\(hour)", title: "\(hour)时", detail: String(format: "%02d:00–%02d:59", hour, hour))
        }
        var kinds: [String: DecisionGroup] = [:]
        var statuses: [String: DecisionGroup] = [:]
        var triggers: [String: DecisionGroup] = [:]
        var sensitivities: [String: DecisionGroup] = [:]
        var models: [String: DecisionGroup] = [:]
        var errors: [String: DecisionGroup] = [:]
        for record in all {
            let local = LocalDate.today(record.date, calendar: calendar)
            guard local >= start, local <= end, !summary.buckets.isEmpty else { continue }
            let offset = calendar.dateComponents([.day], from: startDate, to: local.date(calendar: calendar)).day ?? 0
            let index = min(max(offset / range.bucketDays, 0), summary.buckets.count - 1)
            summary.records.append(record)
            summary.calls += 1
            summary.inputTokens += record.inputTokens
            summary.characters += record.inputCharacters
            summary.buckets[index].add(record)
            switch record.outcome {
            case .pass:
                summary.passed += 1
                durations.append(record.durationMs)
            case .block:
                summary.blocked += 1
                durations.append(record.durationMs)
                summary.savedMs += record.savedMs ?? 0
                summary.savedCharacters += record.inputCharacters
                if let saved = record.netSavedUSD {
                    summary.saved += saved
                    summary.savedKnown = true
                }
                if let events = record.overrideEvents {
                    summary.overrides += 1
                    if events > 0 { summary.falseBlocks += 1 }
                }
            case .failed:
                summary.failed += 1
                let kind = AIUsageStats.errorKind(record.error)
                add(record, id: kind, title: kind, to: &errors)
            }
            if record.outcome != .failed, let server = record.serverMs {
                serverTotal += server
                serverCount += 1
            }
            latency[bin(Double(record.durationMs), latencyUppers)].add(record)
            let hour = min(max(calendar.component(.hour, from: record.date), 0), 23)
            hours[hour].add(record)
            add(record, id: record.trigger.rawValue, title: record.trigger.title, to: &triggers)
            add(record, id: record.sensitivity.rawValue, title: record.sensitivity.title + "档", to: &sensitivities)
            add(record, id: record.aiModel, title: record.aiModel, to: &models)
            if let answers = record.answers {
                probability[bin(answers.hasSchedule, probabilityUppers)].add(record)
                if let value = answers.clarity { clarity[bin(value, clarityUppers)].add(record) }
                if let kind = answers.kind { add(record, id: kind, title: answers.kindTitle ?? kind, to: &kinds) }
                if let status = answers.status {
                    add(record, id: status, title: answers.statusTitle ?? status, to: &statuses)
                }
                if abs(answers.hasSchedule - record.sensitivity.probabilityLimit) < borderlineMargin {
                    summary.borderline += 1
                }
            }
        }
        summary.records.sort { $0.date > $1.date }
        if !durations.isEmpty {
            let sorted = durations.sorted()
            summary.averageMs = Double(sorted.reduce(0, +)) / Double(sorted.count)
            summary.medianMs = Double(sorted[sorted.count / 2])
            let p95 = Int((Double(sorted.count - 1) * 0.95).rounded())
            summary.p95Ms = Double(sorted[min(p95, sorted.count - 1)])
        }
        if serverCount > 0 { summary.serverAverageMs = serverTotal / Double(serverCount) }
        summary.probabilityBins = probability
        summary.clarityBins = clarity
        summary.latencyBins = latency
        summary.hours = hours
        summary.kinds = ranked(kinds)
        summary.statuses = ranked(statuses)
        summary.triggers = ranked(triggers)
        summary.sensitivities = DecisionSensitivity.allCases.compactMap { sensitivities[$0.rawValue] }
        summary.aiModels = ranked(models)
        summary.errors = ranked(errors)
        summary.topError = summary.errors.first?.title
        return summary
    }

    private static func add(_ record: DecisionRecord, id: String, title: String,
                            to groups: inout [String: DecisionGroup]) {
        var group = groups[id] ?? DecisionGroup(id: id, title: title)
        group.add(record)
        groups[id] = group
    }

    private static func ranked(_ groups: [String: DecisionGroup]) -> [DecisionGroup] {
        groups.values.sorted { $0.total == $1.total ? $0.title < $1.title : $0.total > $1.total }
    }

    static func insights(_ s: DecisionSummary) -> [String] {
        guard s.calls > 0 else { return [] }
        typealias F = AIUsageFormat
        var lines: [String] = []
        lines.append("AI 决策共判断 \(s.calls) 次：放行 \(s.passed) 次，拦下 \(s.blocked) 次（拦截率 \(F.percent(s.blockRate))），失败 \(s.failed) 次。")
        if s.blocked > 0 {
            var text = "拦下的 \(s.blocked) 次都没有调用大模型"
            if s.savedKnown { text += "，约省 " + F.cost(s.saved) }
            text += "，少等约 " + F.seconds(Double(s.savedMs) / 1000) + "。决策模型目前限时免费，省下的就是净省。"
            lines.append(text)
        }
        if let top = s.kinds.filter({ $0.blocked > 0 }).max(by: { $0.blocked < $1.blocked }) {
            lines.append("拦下最多的内容是「\(top.title)」：\(top.blocked) 次，这一类的拦截率 \(F.percent(top.blockRate))。")
        }
        if let chat = s.kinds.first(where: { $0.id == "chat" }), chat.blocked > 0 {
            lines.append("聊天记录被拦下 \(chat.blocked) 次。聊天里常有约时间的话，如果漏掉了，在卡片上点「仍然用 AI 识别」，这里会记下误拦。")
        }
        if s.overrides > 0 {
            var text = "拦下后手动用 AI 重跑 \(s.overrides) 次，其中 \(s.falseBlocks) 次 AI 找到了日程（误拦率 \(F.percent(s.falseBlockRate))）。"
            if (s.falseBlockRate ?? 0) > 0.2 { text += "误拦偏多，可以在设置里把灵敏度换成「宽松」。" }
            lines.append(text)
        }
        if s.borderline > 0 {
            lines.append("临界判断 \(s.borderline) 次：有日程的概率离门槛不到 \(Int(borderlineMargin * 100)) 个百分点，这些最容易判断错。")
        }
        if s.failed > 0 {
            var text = "判断失败 \(s.failed) 次，这些都照常调用了 AI，不会漏掉日程。"
            if let top = s.topError { text += "最多的原因是「" + top + "」。" }
            lines.append(text)
        }
        if let average = s.averageMs {
            var text = "平均每次判断 \(Int(average.rounded())) 毫秒"
            if let p95 = s.p95Ms { text += "，P95 \(Int(p95.rounded())) 毫秒" }
            if let server = s.serverAverageMs, let network = s.networkAverageMs {
                text += "；服务端平均只用 \(Int(server.rounded())) 毫秒，其余约 \(Int(network.rounded())) 毫秒是网络往返"
            }
            text += "。共用 \(F.tokens(s.inputTokens)) 输入 tokens。"
            lines.append(text)
        }
        if s.savedCharacters > 0 {
            lines.append("拦下后少给大模型发了 \(s.savedCharacters) 字。")
        }
        if s.calls >= 5, let busiest = s.hours.max(by: { $0.total < $1.total }), busiest.total > 0 {
            lines.append("判断最多的时段是 \(busiest.detail ?? busiest.title)，共 \(busiest.total) 次。")
        }
        return lines
    }
}
