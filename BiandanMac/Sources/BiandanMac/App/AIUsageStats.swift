import Foundation

// MARK: - AI 识别统计：按时间范围汇总用量记录，生成图表数据和分析文字

struct AIUsageBucket: Identifiable, Hashable, Sendable {
    let start: LocalDate
    var calls = 0
    var failures = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    var outputTokens = 0
    var successMs = 0
    var successes = 0
    var cost: Double = 0
    var events = 0
    /// 成功调用的用时（秒），算这一段的 P95。
    var durations: [Double] = []
    var costByModel: [String: Double] = [:]

    var id: LocalDate { start }
    var averageSeconds: Double? { successes > 0 ? Double(successMs) / Double(successes) / 1000 : nil }
}

struct AIUsageCount: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
}

struct AIModelRow: Identifiable, Hashable, Sendable {
    let id: String
    var calls = 0
    var successes = 0
    var tokens = 0
    var cost: Double = 0
    var costKnown = false
    var successMs = 0

    var averageSeconds: Double? { successes > 0 ? Double(successMs) / Double(successes) / 1000 : nil }
    var costPerCall: Double? { costKnown && calls > 0 ? cost / Double(calls) : nil }
}

struct AIHourCount: Identifiable, Hashable, Sendable {
    let hour: Int
    let count: Int
    var id: Int { hour }
    var label: String { "\(hour)时" }
}

struct AIChartPoint: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let series: String
    let value: Double
}

/// 「趋势」图可切换的指标。
enum AITrendMetric: String, CaseIterable, Sendable {
    case calls, tokens, tokensPerCall, latency, cost, cumulativeCost, events, successRate

    var title: String {
        switch self {
        case .calls: return "调用次数"
        case .tokens: return "Token"
        case .tokensPerCall: return "每次 Token"
        case .latency: return "用时"
        case .cost: return "费用"
        case .cumulativeCost: return "累计费用"
        case .events: return "识别日程"
        case .successRate: return "成功率"
        }
    }

    var detail: String {
        switch self {
        case .calls: return "成功与失败的调用次数"
        case .tokens: return "输入（缓存命中 / 未命中）与输出 token"
        case .tokensPerCall: return "平均每次调用的输入、输出 token"
        case .latency: return "成功调用的平均用时与 P95（秒）"
        case .cost: return "预估费用，按模型拆分（美元）"
        case .cumulativeCost: return "从范围开始累计的预估费用（美元）"
        case .events: return "AI 识别出的日程条数"
        case .successRate: return "成功调用占比"
        }
    }

    /// 各系列相加有意义时才适合堆积。
    var stackable: Bool {
        switch self {
        case .calls, .tokens, .tokensPerCall, .cost: return true
        default: return false
        }
    }
}

/// 「趋势」图的样式。
enum AIChartStyle: String, CaseIterable, Sendable {
    case bar, stackedBar, normalized, line, area

    var title: String {
        switch self {
        case .bar: return "柱状"
        case .stackedBar: return "堆积柱状"
        case .normalized: return "百分比堆积"
        case .line: return "折线"
        case .area: return "堆积面积"
        }
    }

    /// 指标不适合堆积时改用的样式。
    var unstacked: AIChartStyle {
        switch self {
        case .stackedBar, .normalized: return .bar
        case .area: return .line
        default: return self
        }
    }
}

struct AITrend {
    var series: [String]
    var points: [AIChartPoint]
}

struct AIUsageSummary {
    var start: LocalDate
    var end: LocalDate
    var rangeDays: Int
    var buckets: [AIUsageBucket]
    /// 范围内的记录，最新的在前。
    var records: [AIUsageRecord] = []
    var calls = 0
    var successes = 0
    var failures = 0
    var promptTokens = 0
    var completionTokens = 0
    var cacheHitTokens = 0
    var cacheMissTokens = 0
    /// 给出了缓存拆分的那部分输入 token，用来算命中率。
    var cacheReportedTokens = 0
    var cost: Double = 0
    var costKnown = false
    var events = 0
    var averageSeconds: Double?
    var medianSeconds: Double?
    var p95Seconds: Double?
    var slowest: AIUsageRecord?
    var models: [AIModelRow] = []
    var triggers: [AIUsageCount] = []
    var errors: [AIUsageCount] = []
    var hours: [AIHourCount] = []
    var latencyBins: [AIUsageCount] = []

    var totalTokens: Int { promptTokens + completionTokens }
    var successRate: Double? { calls > 0 ? Double(successes) / Double(calls) : nil }
    var cacheHitRate: Double? { cacheReportedTokens > 0 ? Double(cacheHitTokens) / Double(cacheReportedTokens) : nil }
}

enum AIUsageStats {
    static let latencyLimits: [(upper: Double, title: String)] = [
        (1, "<1 秒"), (2, "1–2 秒"), (3, "2–3 秒"), (5, "3–5 秒"), (10, "5–10 秒"), (.infinity, "≥10 秒"),
    ]

    static func summary(_ all: [AIUsageRecord], range: StatsRange, today: LocalDate, weekStart: Int,
                        calendar: Calendar = .current) -> AIUsageSummary {
        let end = today
        var start = today.adding(days: -(range.rawValue - 1))
        if range.bucketDays == 7 {
            start = start.adding(days: -floorMod(start.weekday - weekStart, 7))
        }
        var buckets: [AIUsageBucket] = []
        var day = start
        while day <= end {
            buckets.append(AIUsageBucket(start: day))
            day = day.adding(days: range.bucketDays)
        }
        var summary = AIUsageSummary(start: start, end: end, rangeDays: range.rawValue, buckets: buckets)
        let startDate = start.date(calendar: calendar)
        var hours = Array(repeating: 0, count: 24)
        var durations: [Double] = []
        var models: [String: AIModelRow] = [:]
        var triggers: [AIUsageTrigger: Int] = [:]
        var errors: [String: Int] = [:]

        for record in all {
            let local = LocalDate.today(record.date, calendar: calendar)
            guard local >= start, local <= end else { continue }
            let offset = calendar.dateComponents([.day], from: startDate, to: local.date(calendar: calendar)).day ?? 0
            let index = min(max(offset / range.bucketDays, 0), summary.buckets.count - 1)
            summary.records.append(record)
            summary.calls += 1
            summary.buckets[index].calls += 1

            var row = models[record.model] ?? AIModelRow(id: record.model)
            row.calls += 1
            row.tokens += record.totalTokens

            if record.success {
                summary.successes += 1
                summary.events += record.events
                summary.buckets[index].successes += 1
                summary.buckets[index].successMs += record.durationMs
                summary.buckets[index].durations.append(record.seconds)
                summary.buckets[index].events += record.events
                durations.append(record.seconds)
                row.successes += 1
                row.successMs += record.durationMs
                if record.durationMs > (summary.slowest?.durationMs ?? -1) { summary.slowest = record }
            } else {
                summary.failures += 1
                summary.buckets[index].failures += 1
                errors[errorKind(record.error), default: 0] += 1
            }

            summary.promptTokens += record.promptTokens
            summary.completionTokens += record.completionTokens
            summary.buckets[index].outputTokens += record.completionTokens
            if record.reportsCache {
                summary.cacheHitTokens += record.cacheHitTokens
                summary.cacheMissTokens += record.cacheMissTokens
                summary.cacheReportedTokens += record.cacheHitTokens + record.cacheMissTokens
                summary.buckets[index].cacheHitTokens += record.cacheHitTokens
                summary.buckets[index].cacheMissTokens += record.cacheMissTokens
            } else {
                summary.cacheMissTokens += record.promptTokens
                summary.buckets[index].cacheMissTokens += record.promptTokens
            }
            if let cost = record.costUSD {
                summary.cost += cost
                summary.costKnown = true
                summary.buckets[index].cost += cost
                summary.buckets[index].costByModel[record.model, default: 0] += cost
                row.cost += cost
                row.costKnown = true
            }
            models[record.model] = row
            hours[calendar.component(.hour, from: record.date)] += 1
            triggers[record.trigger, default: 0] += 1
        }

        summary.records.sort { $0.date > $1.date }
        let sorted = durations.sorted()
        if !sorted.isEmpty {
            summary.averageSeconds = sorted.reduce(0, +) / Double(sorted.count)
            summary.medianSeconds = percentile(sorted, 0.5)
            summary.p95Seconds = percentile(sorted, 0.95)
        }
        summary.models = models.values.sorted { $0.calls == $1.calls ? $0.id < $1.id : $0.calls > $1.calls }
        summary.triggers = AIUsageTrigger.allCases.compactMap { trigger in
            guard let count = triggers[trigger], count > 0 else { return nil }
            return AIUsageCount(id: trigger.rawValue, title: trigger.title, count: count)
        }
        summary.errors = errors.map { AIUsageCount(id: $0.key, title: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
        summary.hours = hours.enumerated().map { AIHourCount(hour: $0.offset, count: $0.element) }
        summary.latencyBins = latencyLimits.enumerated().map { index, limit in
            let lower = index == 0 ? -Double.infinity : latencyLimits[index - 1].upper
            let count = sorted.filter { $0 >= lower && $0 < limit.upper }.count
            return AIUsageCount(id: limit.title, title: limit.title, count: count)
        }
        return summary
    }

    /// 已排序数组的分位数（取不小于该比例的那一项）。
    static func percentile(_ sorted: [Double], _ ratio: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((ratio * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// 失败原因归类。
    static func errorKind(_ message: String?) -> String {
        let text = message ?? ""
        if text.contains("超时") { return "超时" }
        if text.contains("API Key") { return "API Key 无效" }
        if text.contains("余额") { return "余额不足" }
        if text.contains("频繁") { return "请求太频繁" }
        if text.contains("连不上") { return "网络连接" }
        if text.contains("JSON") || text.contains("有效结果") { return "返回格式" }
        if text.contains("暂时不可用") { return "服务不可用" }
        if text.contains("参数") || text.contains("地址") { return "配置或参数" }
        return "其他"
    }

    // MARK: 图表数据

    static func callPoints(_ buckets: [AIUsageBucket]) -> [AIChartPoint] {
        buckets.flatMap { bucket -> [AIChartPoint] in
            let date = bucket.start.date()
            return [
                AIChartPoint(id: bucket.start.iso + "-ok", date: date, series: "成功",
                             value: Double(bucket.calls - bucket.failures)),
                AIChartPoint(id: bucket.start.iso + "-fail", date: date, series: "失败", value: Double(bucket.failures)),
            ]
        }
    }

    static let tokenSeries = ["输入·缓存命中", "输入·未命中", "输出"]

    static func tokenPoints(_ buckets: [AIUsageBucket]) -> [AIChartPoint] {
        buckets.flatMap { bucket -> [AIChartPoint] in
            let date = bucket.start.date()
            let values: [Int] = [bucket.cacheHitTokens, bucket.cacheMissTokens, bucket.outputTokens]
            return zip(tokenSeries, values).map { series, value in
                AIChartPoint(id: bucket.start.iso + series, date: date, series: series, value: Double(value))
            }
        }
    }

    static func latencyPoints(_ buckets: [AIUsageBucket]) -> [AIChartPoint] {
        buckets.compactMap { bucket in
            guard let seconds = bucket.averageSeconds else { return nil }
            return AIChartPoint(id: bucket.start.iso, date: bucket.start.date(), series: "平均用时", value: seconds)
        }
    }

    static func costPoints(_ buckets: [AIUsageBucket]) -> [AIChartPoint] {
        buckets.map { AIChartPoint(id: $0.start.iso, date: $0.start.date(), series: "费用", value: $0.cost) }
    }

    /// 「趋势」图的数据：各指标的系列名和点。没有调用的那一段，平均类指标不出点。
    static func trend(_ metric: AITrendMetric, buckets: [AIUsageBucket], models: [String]) -> AITrend {
        func point(_ bucket: AIUsageBucket, _ series: String, _ value: Double) -> AIChartPoint {
            AIChartPoint(id: bucket.start.iso + "|" + series, date: bucket.start.date(), series: series, value: value)
        }
        switch metric {
        case .calls:
            return AITrend(series: ["成功", "失败"], points: callPoints(buckets))
        case .tokens:
            return AITrend(series: tokenSeries, points: tokenPoints(buckets))
        case .tokensPerCall:
            let points = buckets.filter { $0.calls > 0 }.flatMap { bucket -> [AIChartPoint] in
                let calls = Double(bucket.calls)
                let input = Double(bucket.cacheHitTokens + bucket.cacheMissTokens) / calls
                return [point(bucket, "输入", input), point(bucket, "输出", Double(bucket.outputTokens) / calls)]
            }
            return AITrend(series: ["输入", "输出"], points: points)
        case .latency:
            let points = buckets.flatMap { bucket -> [AIChartPoint] in
                guard let average = bucket.averageSeconds,
                      let p95 = percentile(bucket.durations.sorted(), 0.95) else { return [] }
                return [point(bucket, "平均", average), point(bucket, "P95", p95)]
            }
            return AITrend(series: ["平均", "P95"], points: points)
        case .cost:
            let points = buckets.flatMap { bucket in models.map { point(bucket, $0, bucket.costByModel[$0] ?? 0) } }
            return AITrend(series: models, points: points)
        case .cumulativeCost:
            var total = 0.0
            let points = buckets.map { bucket -> AIChartPoint in
                total += bucket.cost
                return point(bucket, "累计费用", total)
            }
            return AITrend(series: ["累计费用"], points: points)
        case .events:
            return AITrend(series: ["识别日程"], points: buckets.map { point($0, "识别日程", Double($0.events)) })
        case .successRate:
            let points = buckets.filter { $0.calls > 0 }.map { bucket in
                point(bucket, "成功率", Double(bucket.calls - bucket.failures) / Double(bucket.calls))
            }
            return AITrend(series: ["成功率"], points: points)
        }
    }

    // MARK: 分析文字

    static func insights(_ s: AIUsageSummary) -> [String] {
        guard s.calls > 0 else { return [] }
        typealias F = AIUsageFormat
        var lines: [String] = []
        lines.append("共调用 \(s.calls) 次，成功 \(s.successes) 次（成功率 \(F.percent(s.successRate))），识别出 \(s.events) 条日程。")

        if let average = s.averageSeconds, let p95 = s.p95Seconds {
            var text = "成功调用平均用时 \(F.seconds(average))，中位数 \(F.seconds(s.medianSeconds))，P95 \(F.seconds(p95))。"
            if let slow = s.slowest {
                text += "最慢的一次 \(F.seconds(slow.seconds))（\(F.time(slow.date))，\(slow.model)）。"
            }
            if p95 > 10 {
                text += "P95 超过 10 秒，可以优先用 Flash，或缩小框选范围、少发无关的文字。"
            }
            lines.append(text)
        }

        if s.totalTokens > 0 {
            let perCall = s.totalTokens / s.calls
            let inputShare = Double(s.promptTokens) / Double(s.totalTokens)
            lines.append("共用 \(F.tokens(s.totalTokens)) tokens，平均每次 \(F.tokens(perCall))，其中输入占 \(F.percent(inputShare))。输入主要是固定的系统提示词和识别出的文字，框得越准，输入越少。")
        }

        if let hit = s.cacheHitRate {
            lines.append("输入的缓存命中率 \(F.percent(hit))。系统提示词每次都一样，容易命中缓存；命中部分的单价只有未命中的几十分之一。")
        }

        if s.costKnown {
            let daily = s.cost / Double(max(s.rangeDays, 1))
            lines.append("这段时间预估费用 \(F.cost(s.cost))，按日均推算 30 天约 \(F.cost(daily * 30))。按 DeepSeek 官方价目和高峰时段估算，没有扣除节假日优惠，实际以账单为准。")
        }

        if s.models.count > 1 {
            let parts = s.models.map { row in
                "\(row.id) \(row.calls) 次、平均 \(F.seconds(row.averageSeconds))、每次约 \(F.cost(row.costPerCall))"
            }
            lines.append("模型对比：" + parts.joined(separator: "；") + "。")
        }

        if let top = s.errors.first {
            lines.append("失败 \(s.failures) 次，最多的原因是「\(top.title)」（\(top.count) 次）。\(advice(top.title))")
        }

        if let busiest = s.hours.max(by: { $0.count < $1.count }), busiest.count > 0 {
            lines.append("最常在 \(busiest.hour) 点左右使用（\(busiest.count) 次）。")
        }

        if !s.triggers.isEmpty {
            let parts = s.triggers.map { "\($0.title) \($0.count) 次" }
            lines.append("触发方式：" + parts.joined(separator: "、") + "。")
        }
        return lines
    }

    private static func advice(_ kind: String) -> String {
        switch kind {
        case "超时": return "多半是网络慢或服务繁忙，可以稍后重试。"
        case "API Key 无效": return "请到「设置 → 高级 → AI 识别日程」检查 API Key。"
        case "余额不足": return "请到 DeepSeek 开放平台充值。"
        case "请求太频繁": return "稍等片刻再试。"
        case "网络连接": return "请检查网络或代理设置。"
        case "返回格式": return "偶发的返回格式问题，重试一般就好。"
        default: return ""
        }
    }
}
