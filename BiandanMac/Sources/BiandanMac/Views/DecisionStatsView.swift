import Charts
import SwiftUI

// MARK: - 统计 → AI 识别 → AI 决策：总览（鼠标移到数字上看说明）、趋势（可切换指标），
// 以及按有日程概率、清晰度、判断用时、时段、内容类型、文字状态、触发方式、灵敏度、模型、失败原因的分布和最近判断。
// 每张图、每个数字、每一行都有悬停提示。

/// 放行蓝、拦下绿、失败橙，和确认卡片里的 AI 决策卡片一致。
enum DecisionStatsPalette {
    static let outcomes = ["放行", "拦下", "失败"]
    static var colors: [Color] { [DecisionPalette.model, DecisionPalette.blocked, DecisionPalette.failed] }

    static func color(_ outcome: DecisionOutcome) -> Color {
        switch outcome {
        case .pass: return DecisionPalette.model
        case .block: return DecisionPalette.blocked
        case .failed: return DecisionPalette.failed
        }
    }
}

enum DecisionTrendMetric: String, CaseIterable, Sendable {
    case calls, blockRate, saved, latency, characters

    var title: String {
        switch self {
        case .calls: return "判断次数"
        case .blockRate: return "拦截率"
        case .saved: return "省下费用"
        case .latency: return "平均用时"
        case .characters: return "少发字数"
        }
    }

    var detail: String {
        switch self {
        case .calls: return "放行、拦下、失败各几次"
        case .blockRate: return "拦下 ÷（放行 + 拦下），失败的不算"
        case .saved: return "拦下的那几次本来要花的大模型费用"
        case .latency: return "放行和拦下的平均判断用时（本机计时）"
        case .characters: return "拦下后没有发给大模型的字数"
        }
    }
}

// MARK: - 悬停提示内容

enum DecisionTips {
    typealias F = AIUsageFormat

    /// 只列出次数大于 0 的结果；都是 0 时列放行和拦下。
    static func outcomeRows(passed: Int, blocked: Int, failed: Int) -> [ChartTipRow] {
        let all: [ChartTipRow] = [
            ChartTipRow(name: "放行", value: "\(passed) 次", color: DecisionPalette.model),
            ChartTipRow(name: "拦下", value: "\(blocked) 次", color: DecisionPalette.blocked),
            ChartTipRow(name: "失败", value: "\(failed) 次", color: DecisionPalette.failed),
        ]
        let counts = [passed, blocked, failed]
        let shown = all.indices.filter { counts[$0] > 0 }.map { all[$0] }
        return shown.isEmpty ? Array(all.prefix(2)) : shown
    }

    static func group(_ group: DecisionGroup, title: String) -> ChartTip {
        var rows = outcomeRows(passed: group.passed, blocked: group.blocked, failed: group.failed)
        if let rate = group.blockRate {
            rows.append(ChartTipRow(name: "拦截率", value: F.percent(rate), color: Theme.accent))
        }
        if group.saved > 0 {
            rows.append(ChartTipRow(name: "省下", value: F.cost(group.saved), color: DecisionPalette.blocked))
        }
        if let average = group.averageMs {
            rows.append(ChartTipRow(name: "平均用时", value: "\(Int(average.rounded())) 毫秒", color: DecisionPalette.time))
        }
        let footer: String = group.total > 0 ? "合计 \(group.total) 次" : "这段时间没有"
        return ChartTip(title: title, rows: rows, footer: footer)
    }

    static func bucket(_ bucket: DecisionBucket, days: Int) -> ChartTip {
        var rows = outcomeRows(passed: bucket.passed, blocked: bucket.blocked, failed: bucket.failed)
        if let rate = bucket.blockRate {
            rows.append(ChartTipRow(name: "拦截率", value: F.percent(rate), color: Theme.accent))
        }
        if bucket.saved > 0 {
            rows.append(ChartTipRow(name: "省下", value: F.cost(bucket.saved), color: DecisionPalette.blocked))
        }
        if bucket.savedMs > 0 {
            rows.append(ChartTipRow(name: "少等", value: F.seconds(Double(bucket.savedMs) / 1000), color: DecisionPalette.time))
        }
        if bucket.savedCharacters > 0 {
            rows.append(ChartTipRow(name: "少发", value: "\(bucket.savedCharacters) 字", color: DecisionPalette.kind))
        }
        if let average = bucket.averageMs {
            rows.append(ChartTipRow(name: "平均用时", value: "\(Int(average.rounded())) 毫秒", color: DecisionPalette.time))
        }
        let footer: String = bucket.total > 0 ? "合计 \(bucket.total) 次" : "这段时间没有判断"
        return ChartTip(title: ChartHover.title(bucket.start, days: days), rows: rows, footer: footer)
    }

    static func record(_ record: DecisionRecord) -> ChartTip {
        var rows: [ChartTipRow] = []
        rows.append(ChartTipRow(name: "结果", value: record.outcome.title, color: DecisionStatsPalette.color(record.outcome)))
        if let answers = record.answers {
            rows.append(ChartTipRow(name: "有日程概率", value: F.percent(answers.hasSchedule), color: DecisionPalette.model))
            if let clarity = answers.clarity {
                rows.append(ChartTipRow(name: "清晰度", value: String(format: "%.1f / 4", clarity), color: Theme.accent))
            }
            if let kind = answers.kindTitle {
                let confidence: String = answers.kindConfidence.map { "（置信度 \(F.percent($0))）" } ?? ""
                rows.append(ChartTipRow(name: "内容类型", value: kind + confidence, color: DecisionPalette.kind))
            }
            if let status = answers.statusTitle {
                rows.append(ChartTipRow(name: "文字状态", value: status, color: DecisionPalette.status))
            }
        }
        rows.append(ChartTipRow(name: "本机用时", value: "\(record.durationMs) 毫秒", color: DecisionPalette.time))
        if let server = record.serverMs {
            rows.append(ChartTipRow(name: "服务端用时", value: String(format: "%.0f 毫秒", server), color: DecisionPalette.time))
        }
        rows.append(ChartTipRow(name: "发送", value: "\(record.inputCharacters) 字 · \(F.tokens(record.inputTokens)) tokens",
                                color: Theme.subtext))
        rows.append(ChartTipRow(name: "触发方式", value: record.trigger.title, color: Theme.subtext))
        rows.append(ChartTipRow(name: "灵敏度", value: record.sensitivity.title + "档", color: Theme.subtext))
        let decider = record.decisionModel ?? DecisionSettings.model
        let region: String = record.region.map { " · \($0)" } ?? ""
        rows.append(ChartTipRow(name: "决策模型", value: decider + region, color: DecisionPalette.decider))
        rows.append(ChartTipRow(name: "本来要调用", value: record.aiModel, color: DecisionPalette.model))
        if let saved = record.savedUSD {
            let wait: String = record.savedMs.map { " · 少等 \(F.seconds(Double($0) / 1000))" } ?? ""
            rows.append(ChartTipRow(name: "省下", value: F.cost(saved) + wait, color: DecisionPalette.blocked))
        }
        if let events = record.overrideEvents {
            let text: String = events > 0 ? "AI 找到 \(events) 条（误拦）" : "AI 也没找到日程"
            let color: Color = events > 0 ? Theme.overdue : DecisionPalette.blocked
            rows.append(ChartTipRow(name: "手动重跑", value: text, color: color))
        }
        if let error = record.error {
            rows.append(ChartTipRow(name: "错误", value: error, color: Theme.overdue))
        }
        let footer: String? = record.reason.isEmpty ? nil : record.reason
        return ChartTip(title: "\(F.time(record.date)) · \(record.outcome.title)", rows: rows, footer: footer)
    }
}

// MARK: - 总览数字

struct DecisionKPI: Identifiable {
    let id: String
    let value: String
    let title: String
    let tint: Color
    let help: String
}

enum DecisionKPIs {
    static func items(_ s: DecisionSummary) -> [DecisionKPI] {
        typealias F = AIUsageFormat
        let latest = s.records.first
        let decider = latest?.decisionModel ?? DecisionSettings.model
        let model = latest?.aiModel ?? "大模型"
        let sensitivity = latest?.sensitivity ?? .balanced
        let threshold = F.percent(sensitivity.probabilityLimit)
        let timeout = Int(DecisionSettings.timeout)
        let margin = Int(DecisionStats.borderlineMargin * 100)
        let failColor: Color = s.failed > 0 ? DecisionPalette.failed : Theme.text
        let falseColor: Color = (s.falseBlockRate ?? 0) > 0.2 ? Theme.overdue : Theme.text
        let savedText: String = s.savedKnown ? F.cost(s.saved) : "—"
        let topError: String = s.topError.map { "最多的原因是「\($0)」。" } ?? ""
        let averageChars: String = s.averageCharacters.map { "\(Int($0.rounded())) 字" } ?? "—"
        let averageTokens: String = s.averageTokens.map { "\(Int($0.rounded()))" } ?? "—"
        var list: [DecisionKPI] = []
        list.append(DecisionKPI(id: "calls", value: "\(s.calls)", title: "判断次数", tint: Theme.text,
                                help: "这段时间 \(decider) 一共判断了 \(s.calls) 次，含失败的。卡片上手动点「用 AI 识别」不经过判断，不算在内。"))
        list.append(DecisionKPI(id: "pass", value: "\(s.passed)", title: "放行", tint: DecisionPalette.model,
                                help: "判断有日程，交给 \(model) 提取。"))
        list.append(DecisionKPI(id: "block", value: "\(s.blocked)", title: "拦下", tint: DecisionPalette.blocked,
                                help: "判断没有日程，没有调用 \(model)。「总是用 AI」时改用本机识别；「规则识别不到时」直接显示没有日程。"))
        list.append(DecisionKPI(id: "rate", value: F.percent(s.blockRate), title: "拦截率", tint: Theme.accent,
                                help: "拦下 ÷（放行 + 拦下）= \(s.blocked) ÷ \(s.judged)。失败的不算在内。"))
        list.append(DecisionKPI(id: "failed", value: "\(s.failed)", title: "失败 · \(F.percent(s.failureRate))", tint: failColor,
                                help: "超时（\(timeout) 秒）、Key 无效、网络出错等。失败时照常调用 \(model)，不会因此漏掉日程。\(topError)"))
        list.append(DecisionKPI(id: "saved", value: savedText, title: "省下费用", tint: DecisionPalette.blocked,
                                help: "拦下的 \(s.blocked) 次本来要调用 \(model) 的预估费用之和：按最近 50 次成功调用的每字平均费用 × 这次的字数估算，高峰时段按两倍。决策模型目前限时免费，按 0 计，所以就是净省。"))
        list.append(DecisionKPI(id: "savedMs", value: F.seconds(Double(s.savedMs) / 1000), title: "少等时间",
                                tint: DecisionPalette.time,
                                help: "拦下的那几次本来要等 \(model) 返回的时间之和，按最近同一模型的平均用时估算。"))
        list.append(DecisionKPI(id: "chars", value: "\(s.savedCharacters) 字", title: "少发字数", tint: DecisionPalette.kind,
                                help: "拦下后没有发给 \(model) 的文字字数合计。"))
        list.append(DecisionKPI(id: "avg", value: ms(s.averageMs), title: "平均用时", tint: DecisionPalette.time,
                                help: "放行和拦下的平均判断用时：本机从发出请求到拿到结果，含网络往返。中位数 \(ms(s.medianMs))。"))
        list.append(DecisionKPI(id: "p95", value: ms(s.p95Ms), title: "P95 用时", tint: Theme.text,
                                help: "95% 的判断在这个时间内完成。超过 \(timeout) 秒按超时处理，照常调用 AI。"))
        list.append(DecisionKPI(id: "server", value: ms(s.serverAverageMs), title: "服务端用时", tint: Theme.text,
                                help: "\(decider) 在服务端平均只用这么久。本机用时减去它，约 \(ms(s.networkAverageMs)) 是网络往返。"))
        list.append(DecisionKPI(id: "avgChars", value: averageChars, title: "平均字数", tint: Theme.text,
                                help: "每次发给决策模型的字数（最多 12,000 字），平均 \(averageTokens) 输入 tokens。"))
        list.append(DecisionKPI(id: "false", value: F.percent(s.falseBlockRate), title: "误拦率 · \(s.falseBlocks)/\(s.overrides)",
                                tint: falseColor,
                                help: "拦下后你点「仍然用 \(model) 识别」重跑了 \(s.overrides) 次，其中 \(s.falseBlocks) 次 AI 找到了日程。超过 20% 时建议在设置里把灵敏度换成「宽松」。"))
        list.append(DecisionKPI(id: "border", value: "\(s.borderline)", title: "临界判断", tint: Theme.text,
                                help: "有日程的概率离当前「\(sensitivity.title)」档门槛 \(threshold) 不到 \(margin) 个百分点的次数。这些最容易判断错。"))
        return list
    }

    private static func ms(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) 毫秒" } ?? "—"
    }
}

// MARK: - 整组

struct DecisionStatsCard: View {
    let summary: DecisionSummary
    let range: StatsRange

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            overview
            DecisionTrendCard(summary: summary, range: range)
            scores
            timing
            content
            setup
            extras
            recent
        }
    }

    private var latest: DecisionRecord? { summary.records.first }

    /// 「decision-model-preview · 阿里云百炼 · 北京 · 调用大模型之前先判断有没有日程」
    private var subtitle: String {
        var parts: [String] = [latest?.decisionModel ?? DecisionSettings.model, "阿里云百炼"]
        if let region = latest?.region { parts.append(region) }
        parts.append("调用大模型之前先判断有没有日程 · 鼠标移到数字上看说明")
        return parts.joined(separator: " · ")
    }

    private var limitText: String {
        let sensitivity = latest?.sensitivity ?? .balanced
        let parts: [String] = [
            "「", sensitivity.title, "」档：低于 ", AIUsageFormat.percent(sensitivity.probabilityLimit),
            " 且清晰度低于 ", String(format: "%.1f", sensitivity.clarityLimit), " 时拦下", sensitivity.extraRules,
        ]
        return parts.joined()
    }

    private var overview: some View {
        let lines = DecisionStats.insights(summary)
        return StatsCard("AI 决策", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 12) {
                DecisionKPIGrid(items: DecisionKPIs.items(summary))
                Rectangle().fill(Theme.line).frame(height: 1)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in DecisionInsightLine(text: line) }
            }
        }
    }

    private var scores: some View {
        HStack(alignment: .top, spacing: 14) {
            StatsCard("有日程概率", subtitle: limitText) {
                DecisionGroupChart(groups: summary.probabilityBins, axis: "有日程概率")
            }
            StatsCard("清晰度", subtitle: "0 看不出时间 · 4 时间地点都清楚") {
                DecisionGroupChart(groups: summary.clarityBins, axis: "清晰度")
            }
        }
    }

    private var timing: some View {
        HStack(alignment: .top, spacing: 14) {
            StatsCard("判断用时", subtitle: "本机计时，含网络往返") {
                DecisionGroupChart(groups: summary.latencyBins, axis: "用时")
            }
            StatsCard("时段分布", subtitle: "一天中哪个时段判断得多") {
                DecisionGroupChart(groups: summary.hours, axis: "时段", axisValues: ["0时", "6时", "12时", "18时", "23时"])
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            StatsCard("内容类型", subtitle: "决策模型认为这段文字是什么") {
                DecisionGroupBars(groups: summary.kinds, empty: "还没有判断成功的记录")
            }
            StatsCard("文字状态", subtitle: "已定、还在商量、已取消……") {
                DecisionGroupBars(groups: summary.statuses, empty: "还没有判断成功的记录")
            }
        }
    }

    private var setup: some View {
        HStack(alignment: .top, spacing: 14) {
            StatsCard("触发方式", subtitle: "什么情况下先做了判断") {
                DecisionGroupBars(groups: summary.triggers)
            }
            StatsCard("灵敏度", subtitle: "判断时用的档位") {
                DecisionGroupBars(groups: summary.sensitivities)
            }
        }
    }

    private var extras: some View {
        HStack(alignment: .top, spacing: 14) {
            StatsCard("本来要调用的模型", subtitle: "拦下的就没有调用") {
                DecisionGroupBars(groups: summary.aiModels)
            }
            StatsCard("失败原因", subtitle: "\(summary.failed) 次失败 · 都照常调用了 AI") {
                DecisionGroupBars(groups: summary.errors, empty: "这段时间没有失败")
            }
        }
    }

    private var recent: some View {
        StatsCard("最近判断", subtitle: "最多显示 12 条 · 鼠标移上去看详情 · 完整记录可导出 CSV") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(summary.records.prefix(12))) { record in DecisionRecentRow(record: record) }
            }
        }
    }
}

// MARK: - 部件

private struct DecisionKPIGrid: View {
    let items: [DecisionKPI]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 14, alignment: .leading)],
                  alignment: .leading, spacing: 12) {
            ForEach(items) { item in DecisionKPIItem(item: item) }
        }
    }
}

private struct DecisionKPIItem: View {
    let item: DecisionKPI

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.value)
                .font(.system(size: 18, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 3) {
                Text(verbatim: item.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.fieldName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverPopover(arrowEdge: .bottom) { _ in DecisionHelpPopup(title: item.title, text: item.help) }
    }
}

private struct DecisionHelpPopup: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 280, alignment: .leading)
        .padding(12)
    }
}

private struct DecisionTipPopup: View {
    let tip: ChartTip

    var body: some View {
        ChartTipView(tip: tip)
            .frame(maxWidth: 380)
            .padding(8)
    }
}

private struct DecisionInsightLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DecisionPalette.decider)
                .padding(.top, 2)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DecisionLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(DecisionStatsPalette.outcomes.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DecisionStatsPalette.colors[index])
                        .frame(width: 8, height: 8)
                    Text(verbatim: DecisionStatsPalette.outcomes[index])
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.subtext)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 趋势

private struct DecisionTrendCard: View {
    let summary: DecisionSummary
    let range: StatsRange
    @AppStorage("biandan.stats.decision.metric") private var metricRaw = DecisionTrendMetric.calls.rawValue

    var body: some View {
        let metric = DecisionTrendMetric(rawValue: metricRaw) ?? .calls
        let weekly = range.bucketDays == 7
        let unit: Calendar.Component = weekly ? .weekOfYear : .day
        let per: String = weekly ? "按周" : "按天"
        let subtitle = [per, "统计 · ", metric.detail, " · 鼠标移到柱子上看当天详情"].joined()
        StatsCard("AI 决策趋势", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 10) {
                DecisionMetricChips(selection: Binding(get: { metric }, set: { metricRaw = $0.rawValue }))
                if metric == .calls { DecisionLegend() }
                DecisionTrendChart(buckets: summary.buckets, metric: metric, unit: unit)
            }
        }
    }
}

private struct DecisionMetricChips: View {
    @Binding var selection: DecisionTrendMetric

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DecisionTrendMetric.allCases, id: \.self) { metric in
                DecisionMetricChip(metric: metric, on: metric == selection) { selection = metric }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DecisionMetricChip: View {
    let metric: DecisionTrendMetric
    let on: Bool
    let action: () -> Void

    var body: some View {
        let fill: Color = on ? Theme.accent : Theme.panel
        let stroke: Color = on ? Theme.accent : Theme.line
        let textColor: Color = on ? Color.white : Theme.text
        let weight: Font.Weight = on ? .bold : .medium
        Button(action: action) {
            Text(verbatim: metric.title)
                .font(.system(size: 11.5, weight: weight))
                .foregroundStyle(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(metric.detail)
    }
}

private struct DecisionOutcomePoint: Identifiable {
    let id: String
    let date: Date
    let outcome: String
    let count: Int
}

private struct DecisionValuePoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
}

private struct DecisionTrendChart: View {
    let buckets: [DecisionBucket]
    let metric: DecisionTrendMetric
    let unit: Calendar.Component

    private var days: Int { unit == .weekOfYear ? 7 : 1 }
    private var starts: [Date] { buckets.map { $0.start.date(calendar: .current) } }

    private var outcomePoints: [DecisionOutcomePoint] {
        buckets.flatMap { bucket -> [DecisionOutcomePoint] in
            let date = bucket.start.date(calendar: .current)
            let counts = [bucket.passed, bucket.blocked, bucket.failed]
            return DecisionStatsPalette.outcomes.indices.map { index in
                let name = DecisionStatsPalette.outcomes[index]
                return DecisionOutcomePoint(id: bucket.start.iso + name, date: date, outcome: name, count: counts[index])
            }
        }
    }

    private var valuePoints: [DecisionValuePoint] {
        buckets.compactMap { bucket in
            guard let number = metricValue(bucket) else { return nil }
            return DecisionValuePoint(id: bucket.start.iso, date: bucket.start.date(calendar: .current), value: number)
        }
    }

    private func metricValue(_ bucket: DecisionBucket) -> Double? {
        switch metric {
        case .calls: return Double(bucket.total)
        case .blockRate: return bucket.blockRate
        case .saved: return bucket.saved
        case .latency: return bucket.averageMs
        case .characters: return Double(bucket.savedCharacters)
        }
    }

    private var color: Color {
        switch metric {
        case .calls: return DecisionPalette.model
        case .blockRate: return Theme.accent
        case .saved: return DecisionPalette.blocked
        case .latency: return DecisionPalette.time
        case .characters: return DecisionPalette.kind
        }
    }

    var body: some View {
        chart
    }

    @ViewBuilder
    private var chart: some View {
        if metric == .calls {
            decorate(Chart(outcomePoints) { point in
                BarMark(x: .value("日期", point.date, unit: unit), y: .value("次数", point.count))
                    .foregroundStyle(by: .value("结果", point.outcome))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: DecisionStatsPalette.outcomes, range: DecisionStatsPalette.colors)
            .chartLegend(.hidden))
        } else {
            decorate(Chart(valuePoints) { point in
                BarMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value))
                    .foregroundStyle(color)
                    .cornerRadius(2)
            })
        }
    }

    private func decorate(_ chart: some View) -> some View {
        chart
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { Text(verbatim: axisLabel(value)) }
                }
            }
            .chartHoverTip(hit: ChartHover.dates(starts, spanDays: days), tip: tip)
            .frame(height: 180)
    }

    private func tip(_ index: Int) -> ChartTip? {
        guard buckets.indices.contains(index) else { return nil }
        return DecisionTips.bucket(buckets[index], days: days)
    }

    private func axisLabel(_ value: AxisValue) -> String {
        guard let number = value.as(Double.self) ?? value.as(Int.self).map(Double.init) else { return "" }
        switch metric {
        case .blockRate: return "\(Int((number * 100).rounded()))%"
        case .saved: return number == 0 ? "$0" : String(format: "$%.4f", number)
        case .latency: return String(format: "%.0f 毫秒", number)
        default: return String(format: "%.0f", number)
        }
    }
}

// MARK: - 分布柱状图（按区间、时段），堆积放行 / 拦下 / 失败

private struct DecisionBarPoint: Identifiable {
    let id: String
    let category: String
    let outcome: String
    let count: Int
}

private struct DecisionGroupChart: View {
    let groups: [DecisionGroup]
    let axis: String
    var axisValues: [String]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DecisionLegend()
            chart
        }
    }

    private var points: [DecisionBarPoint] {
        groups.flatMap { group -> [DecisionBarPoint] in
            let counts = [group.passed, group.blocked, group.failed]
            return DecisionStatsPalette.outcomes.indices.map { index in
                let name = DecisionStatsPalette.outcomes[index]
                return DecisionBarPoint(id: group.id + "-" + name, category: group.title, outcome: name, count: counts[index])
            }
        }
    }

    private var chart: some View {
        let values: [String] = axisValues ?? groups.map(\.title)
        let names: [String] = groups.map(\.title)
        return Chart(points) { point in
            BarMark(x: .value(axis, point.category), y: .value("次数", point.count))
                .foregroundStyle(by: .value("结果", point.outcome))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(domain: DecisionStatsPalette.outcomes, range: DecisionStatsPalette.colors)
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks(values: values) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartHoverTip(hit: ChartHover.categories(names), tip: tip)
        .frame(height: 150)
    }

    private func tip(_ index: Int) -> ChartTip? {
        guard groups.indices.contains(index) else { return nil }
        let group = groups[index]
        return DecisionTips.group(group, title: group.detail ?? group.title)
    }
}

// MARK: - 横向比例条（按内容类型、状态、触发方式……），每条分放行 / 拦下 / 失败三段

private struct DecisionGroupBars: View {
    let groups: [DecisionGroup]
    var empty = "没有记录"

    var body: some View {
        let top = max(groups.map(\.total).max() ?? 0, 1)
        if groups.isEmpty {
            Text(verbatim: empty).font(.system(size: 12)).foregroundStyle(Theme.subtext)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                DecisionLegend()
                ForEach(groups) { group in DecisionGroupBar(group: group, top: top) }
            }
        }
    }
}

private struct DecisionGroupBar: View {
    let group: DecisionGroup
    let top: Int

    var body: some View {
        let rate: String = group.blockRate.map { "拦 " + AIUsageFormat.percent($0) } ?? "—"
        HStack(spacing: 8) {
            Text(verbatim: group.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
            GeometryReader { geometry in
                bar(width: geometry.size.width)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            Text(verbatim: "\(group.total)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(width: 30, alignment: .trailing)
            Text(verbatim: rate)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.subtext)
                .frame(width: 54, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .hoverPopover(arrowEdge: .trailing) { _ in
            DecisionTipPopup(tip: DecisionTips.group(group, title: group.detail ?? group.title))
        }
    }

    private func bar(width: CGFloat) -> some View {
        let full: CGFloat = width * CGFloat(group.total) / CGFloat(max(top, 1))
        let counts = [group.passed, group.blocked, group.failed]
        return HStack(spacing: 0) {
            ForEach(counts.indices, id: \.self) { index in
                Rectangle()
                    .fill(DecisionStatsPalette.colors[index].opacity(0.85))
                    .frame(width: segment(counts[index], full: full), height: 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func segment(_ count: Int, full: CGFloat) -> CGFloat {
        guard group.total > 0 else { return 0 }
        return max(full * CGFloat(count) / CGFloat(group.total), 0)
    }
}

// MARK: - 最近判断

private struct DecisionRecentRow: View {
    let record: DecisionRecord

    var body: some View {
        let blocked = record.outcome == .block
        let tint = DecisionStatsPalette.color(record.outcome)
        let modelColor: Color = blocked ? DecisionPalette.model.opacity(0.5) : DecisionPalette.model
        let detail: String = record.answers?.summary ?? (record.error ?? "")
        let saved: String = record.savedUSD.map { "省 " + AIUsageFormat.cost($0) } ?? ""
        HStack(spacing: 10) {
            Text(verbatim: AIUsageFormat.time(record.date))
                .foregroundStyle(Theme.subtext)
                .frame(width: 92, alignment: .leading)
            Text(verbatim: record.outcome.title)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .leading)
            Text(verbatim: detail).lineLimit(1).foregroundStyle(Theme.text)
            Text(verbatim: "→ " + record.aiModel)
                .font(.system(size: 10.5, design: .monospaced))
                .strikethrough(blocked)
                .foregroundStyle(modelColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if record.falseBlock { Text("误拦").foregroundStyle(Theme.overdue) }
            Text(verbatim: saved).foregroundStyle(DecisionPalette.blocked)
            Text(verbatim: "\(record.durationMs) 毫秒").monospacedDigit().foregroundStyle(DecisionPalette.time)
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .hoverPopover(arrowEdge: .trailing) { _ in DecisionTipPopup(tip: DecisionTips.record(record)) }
    }
}
