import XCTest
@testable import BiandanMac

/// AI 识别统计：token 解析、费用估算、汇总、记录与导出。今天是 2026-11-20（周五）。
final class AIUsageStatsTests: XCTestCase {
    private let today = LocalDate(year: 2026, month: 11, day: 20)!

    private func utc(_ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func record(_ day: LocalDate, hour: Int, ms: Int, success: Bool = true, error: String? = nil,
                        model: String = "deepseek-flash", trigger: AIUsageTrigger = .fallback) -> AIUsageRecord {
        let date = day.date().addingTimeInterval(TimeInterval(hour * 3600))
        var item = AIUsageRecord(date: date, model: model, host: "api.deepseek.com", trigger: trigger)
        item.apply(AITokenUsage(prompt: 1000, completion: 200, cacheHit: 600, cacheMiss: 400))
        item.durationMs = ms
        item.success = success
        item.error = error
        item.events = success ? 1 : 0
        return item
    }

    func testTokenUsageParsing() {
        let usage = AITokenUsage(json: [
            "prompt_tokens": 1200, "completion_tokens": 300,
            "prompt_cache_hit_tokens": 1000, "prompt_cache_miss_tokens": 200,
        ])
        XCTAssertEqual(usage, AITokenUsage(prompt: 1200, completion: 300, cacheHit: 1000, cacheMiss: 200))

        let openAI = AITokenUsage(json: [
            "prompt_tokens": 500, "completion_tokens": 50, "prompt_tokens_details": ["cached_tokens": 100],
        ])
        XCTAssertEqual(openAI.cacheHit, 100)
        XCTAssertEqual(openAI.cacheMiss, 400)
        XCTAssertEqual(AITokenUsage(json: [:]), AITokenUsage())
    }

    func testPricing() {
        let usage = AITokenUsage(prompt: 1000, completion: 500, cacheHit: 200, cacheMiss: 800)
        // 周六全天非高峰：(200×0.003 + 800×0.15 + 500×0.6) / 1e6
        let offPeak = AIPricing.cost(model: "deepseek-flash", host: "api.deepseek.com", usage: usage, at: utc(21, 2))!
        XCTAssertEqual(offPeak, 0.0004206, accuracy: 1e-9)
        // 周五 UTC 02:00 是高峰，两倍。
        XCTAssertTrue(AIPricing.isPeak(utc(20, 2)))
        XCTAssertFalse(AIPricing.isPeak(utc(20, 5)))
        XCTAssertFalse(AIPricing.isPeak(utc(21, 2)))
        let peak = AIPricing.cost(model: "deepseek-flash", host: "api.deepseek.com", usage: usage, at: utc(20, 2))!
        XCTAssertEqual(peak, offPeak * 2, accuracy: 1e-9)
        // Pro 更贵；其他接口不估算。
        let pro = AIPricing.cost(model: "deepseek-v4-pro", host: "api.deepseek.com", usage: usage, at: utc(21, 2))!
        XCTAssertGreaterThan(pro, offPeak)
        XCTAssertNil(AIPricing.cost(model: "qwen-plus", host: "dashscope.aliyuncs.com", usage: usage, at: utc(21, 2)))
        // 没有缓存拆分时，输入全部按未命中计。
        let plain = AIPricing.cost(model: "deepseek-flash", host: "api.deepseek.com",
                                   usage: AITokenUsage(prompt: 1000, completion: 0), at: utc(21, 2))!
        XCTAssertEqual(plain, 0.00015, accuracy: 1e-9)
    }

    func testSummary() {
        let yesterday = today.adding(days: -1)
        let records = [
            record(today, hour: 10, ms: 1000),
            record(today, hour: 15, ms: 3000, model: "deepseek-v4-pro", trigger: .manual),
            record(yesterday, hour: 10, ms: 60000, success: false, error: "AI 响应超时，稍后再试"),
            // 范围外的不算。
            record(today.adding(days: -30), hour: 10, ms: 500),
        ]
        let summary = AIUsageStats.summary(records, range: .week, today: today, weekStart: 1)
        XCTAssertEqual(summary.buckets.count, 7)
        XCTAssertEqual(summary.calls, 3)
        XCTAssertEqual(summary.successes, 2)
        XCTAssertEqual(summary.failures, 1)
        XCTAssertEqual(summary.events, 2)
        XCTAssertEqual(summary.averageSeconds ?? 0, 2.0, accuracy: 1e-9)
        XCTAssertEqual(summary.p95Seconds, 3.0)
        XCTAssertEqual(summary.slowest?.durationMs, 3000)
        XCTAssertEqual(summary.promptTokens, 3000)
        XCTAssertEqual(summary.completionTokens, 600)
        XCTAssertEqual(summary.cacheHitRate ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertTrue(summary.costKnown)
        XCTAssertEqual(summary.buckets.last?.calls, 2)
        XCTAssertEqual(summary.buckets[5].failures, 1)
        XCTAssertEqual(summary.errors.first?.title, "超时")
        XCTAssertEqual(summary.models.map(\.id), ["deepseek-flash", "deepseek-v4-pro"])
        XCTAssertEqual(summary.triggers.map(\.title), ["规则兜底", "手动重跑"])
        XCTAssertEqual(summary.hours.count, 24)
        XCTAssertEqual(summary.hours.map(\.count).reduce(0, +), 3)
        XCTAssertEqual(summary.latencyBins.map(\.count), [0, 1, 0, 1, 0, 0])
        XCTAssertEqual(summary.records.first?.durationMs, 3000)

        let insights = AIUsageStats.insights(summary)
        XCTAssertTrue(insights[0].contains("共调用 3 次"))
        XCTAssertTrue(insights.contains { $0.contains("超时") })
        XCTAssertTrue(insights.contains { $0.contains("模型对比") })

        XCTAssertEqual(AIUsageStats.callPoints(summary.buckets).count, 14)
        XCTAssertEqual(AIUsageStats.tokenPoints(summary.buckets).count, 21)
        XCTAssertEqual(AIUsageStats.latencyPoints(summary.buckets).count, 1)
    }

    func testTrend() {
        let records = [
            record(today, hour: 10, ms: 1000),
            record(today, hour: 11, ms: 3000, model: "deepseek-v4-pro"),
            record(today.adding(days: -1), hour: 10, ms: 2000, success: false, error: "AI 响应超时"),
        ]
        let summary = AIUsageStats.summary(records, range: .week, today: today, weekStart: 1)
        let models = summary.models.map(\.id)

        let cost = AIUsageStats.trend(.cost, buckets: summary.buckets, models: models)
        XCTAssertEqual(cost.series, models)
        XCTAssertEqual(cost.points.count, 7 * models.count)

        let latency = AIUsageStats.trend(.latency, buckets: summary.buckets, models: models)
        XCTAssertEqual(latency.points.count, 2)
        XCTAssertEqual(latency.points.first { $0.series == "P95" }?.value, 3)

        let rate = AIUsageStats.trend(.successRate, buckets: summary.buckets, models: models)
        XCTAssertEqual(rate.points.map(\.value), [0, 1])

        let cumulative = AIUsageStats.trend(.cumulativeCost, buckets: summary.buckets, models: models)
        XCTAssertEqual(cumulative.points.last?.value ?? 0, summary.cost, accuracy: 1e-12)
        XCTAssertEqual(AIUsageStats.trend(.events, buckets: summary.buckets, models: models).points.last?.value, 2)
        XCTAssertEqual(AIUsageStats.trend(.tokensPerCall, buckets: summary.buckets, models: models).points.count, 4)

        XCTAssertFalse(AITrendMetric.latency.stackable)
        XCTAssertTrue(AITrendMetric.tokens.stackable)
        XCTAssertEqual(AIChartStyle.area.unstacked, .line)
        XCTAssertEqual(AIChartStyle.normalized.unstacked, .bar)
    }

    func testEmptySummary() {
        let summary = AIUsageStats.summary([], range: .month, today: today, weekStart: 1)
        XCTAssertEqual(summary.calls, 0)
        XCTAssertNil(summary.successRate)
        XCTAssertNil(summary.averageSeconds)
        XCTAssertTrue(AIUsageStats.insights(summary).isEmpty)
    }

    func testErrorKinds() {
        XCTAssertEqual(AIUsageStats.errorKind("API Key 无效或已失效"), "API Key 无效")
        XCTAssertEqual(AIUsageStats.errorKind("DeepSeek 账户余额不足"), "余额不足")
        XCTAssertEqual(AIUsageStats.errorKind("连不上 api.deepseek.com：…"), "网络连接")
        XCTAssertEqual(AIUsageStats.errorKind("AI 返回的内容不是有效的 JSON"), "返回格式")
        XCTAssertEqual(AIUsageStats.errorKind(nil), "其他")
    }

    func testPercentile() {
        XCTAssertNil(AIUsageStats.percentile([], 0.95))
        XCTAssertEqual(AIUsageStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95), 10)
        XCTAssertEqual(AIUsageStats.percentile([1, 2, 3, 4], 0.5), 2)
    }

    @MainActor
    func testLogAndCSV() {
        let log = AIUsageLog(url: nil)
        var item = record(today, hour: 9, ms: 1500)
        item.error = "含,逗号"
        log.append(item)
        log.append(record(today, hour: 10, ms: 800))
        XCTAssertEqual(log.records.count, 2)
        let csv = log.csv().components(separatedBy: "\n")
        XCTAssertEqual(csv.count, 3)
        XCTAssertTrue(csv[0].hasPrefix("时间,模型,接口"))
        XCTAssertTrue(csv[1].contains("\"含,逗号\""))
        XCTAssertTrue(csv[2].contains("deepseek-flash"))
        log.clear()
        XCTAssertTrue(log.records.isEmpty)
    }

    func testBrief() {
        var item = record(today, hour: 9, ms: 2300)
        item.costUSD = 0.0004
        let text = AIUsageFormat.brief(item)
        XCTAssertTrue(text.hasPrefix("用时 2.3 秒"))
        XCTAssertTrue(text.contains("tokens"))
        XCTAssertTrue(text.contains("$0.0004"))
        XCTAssertEqual(AIUsageFormat.tokens(12_345), "1.2 万")
        XCTAssertEqual(AIUsageFormat.cost(0.0123), "$0.01")
        XCTAssertEqual(AIUsageFormat.seconds(nil), "—")
    }
}
