import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 统计 → AI 识别：用时、token 用量、费用估算、模型与触发方式、失败原因、最近调用

enum AIUsagePalette {
    static let all: [Color] = [
        Quadrant.notImportantUrgent.tint, Theme.accent, Quadrant.importantUrgent.tint, Quadrant.neither.tint,
        Color(hex: 0x8E5BD6), Color(hex: 0x2BB5B0),
    ]

    static func color(_ index: Int) -> Color { all[index % all.count] }

    static func colors(_ count: Int) -> [Color] { (0..<max(count, 1)).map(color) }
}

struct AIUsageStatsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: StatsRange = .month
    @State private var confirmClear = false

    var body: some View {
        let log = AIUsageLog.shared
        if log.records.isEmpty {
            ContentUnavailableView("还没有 AI 识别记录", systemImage: "sparkles",
                                   description: Text("在「设置 → 高级 → AI 识别日程」接入 DeepSeek 后，每次 AI 识别的用时、token 用量和预估费用都会记在这里"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            report(AIUsageStats.summary(log.records, range: range, today: model.today, weekStart: model.weekStart))
        }
    }

    private func report(_ summary: AIUsageSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                toolbar(summary)
                AIUsageOverview(summary: summary)
                if summary.calls == 0 {
                    Text("这段时间没有 AI 识别记录，换个时间范围看看。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                } else {
                    AIUsageCharts(summary: summary, range: range)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .alert("清空 AI 识别记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { AIUsageLog.shared.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清空本机的统计记录，不影响已添加的日程。")
        }
    }

    private func toolbar(_ summary: AIUsageSummary) -> some View {
        HStack(spacing: 12) {
            ThemedSegmented(selection: $range,
                            options: StatsRange.allCases.map { ThemeOption(value: $0, title: $0.title) })
            Text(verbatim: "\(summary.start.shortTitle) – \(summary.end.shortTitle)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
            Spacer(minLength: 0)
            Button("导出 CSV", action: export).buttonStyle(.themed)
            Button("清空记录") { confirmClear = true }.buttonStyle(.themed)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "便单 AI 识别记录.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 带 BOM，Excel 打开中文不乱码。
        let text = "\u{FEFF}" + AIUsageLog.shared.csv()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 总览

private struct AIUsageOverview: View {
    let summary: AIUsageSummary

    var body: some View {
        typealias F = AIUsageFormat
        let failColor: Color = summary.failures > 0 ? Theme.overdue : Theme.text
        let costText: String = summary.costKnown ? F.cost(summary.cost) : "—"
        let perCall: Int = summary.calls > 0 ? summary.totalTokens / summary.calls : 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                item("\(summary.calls)", "调用次数", tint: Theme.text)
                item(F.percent(summary.successRate), "成功率 · 失败 \(summary.failures)", tint: failColor)
                item(F.seconds(summary.averageSeconds), "平均用时", tint: Theme.accent)
                item(F.seconds(summary.p95Seconds), "P95 用时", tint: Theme.text)
                item(F.tokens(summary.totalTokens), "总 Token", tint: Quadrant.notImportantUrgent.tint)
                item(costText, "预估费用", tint: Theme.done)
                Spacer(minLength: 0)
            }
            HStack(spacing: 28) {
                item(F.tokens(summary.promptTokens), "输入 Token", tint: Theme.text)
                item(F.tokens(summary.completionTokens), "输出 Token", tint: Theme.text)
                item(F.tokens(perCall), "平均每次 Token", tint: Theme.text)
                item(F.percent(summary.cacheHitRate), "缓存命中率", tint: Theme.text)
                item("\(summary.events)", "识别出日程", tint: Theme.text)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func item(_ value: String, _ title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.system(size: 18, weight: .heavy)).monospacedDigit().foregroundStyle(tint)
            Text(verbatim: title).font(.system(size: 11)).foregroundStyle(Theme.subtext)
        }
    }
}

// MARK: - 图表

private struct AIUsageCharts: View {
    let summary: AIUsageSummary
    let range: StatsRange

    var body: some View {
        let unit: Calendar.Component = range.bucketDays == 7 ? .weekOfYear : .day
        let per: String = range.bucketDays == 7 ? "按周" : "按天"
        let models: [String] = summary.models.map(\.id)
        let insights = AIUsageStats.insights(summary)
        return VStack(alignment: .leading, spacing: 14) {
            if !insights.isEmpty { AIInsightsCard(lines: insights) }
            AITrendCard(summary: summary, unit: unit, per: per)
            HStack(alignment: .top, spacing: 14) {
                StatsCard("模型占比", subtitle: "按调用次数") {
                    AIShareDonut(slices: modelSlices(summary), center: "\(summary.calls)", caption: "次调用")
                }
                StatsCard("Token 构成", subtitle: "输入（缓存命中 / 未命中）与输出") {
                    AIShareDonut(slices: tokenSlices(summary), center: AIUsageFormat.tokens(summary.totalTokens),
                                 caption: "tokens")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                StatsCard("用时分布", subtitle: "成功的调用") { AILatencyHistogram(bins: summary.latencyBins) }
                StatsCard("时段分布", subtitle: "一天中哪个时段用得多") { AIHourChart(hours: summary.hours) }
            }
            StatsCard("Token 与用时", subtitle: "每个点是一次成功的调用，颜色区分模型") {
                AIScatterChart(records: summary.records.filter(\.success), models: models)
            }
            HStack(alignment: .top, spacing: 14) {
                StatsCard("触发方式", subtitle: "什么情况下用了 AI") {
                    StatsShareBars(rows: shareRows(summary.triggers, offset: 0))
                }
                if !summary.errors.isEmpty {
                    StatsCard("失败原因", subtitle: "\(summary.failures) 次失败") {
                        StatsShareBars(rows: errorRows(summary.errors))
                    }
                }
            }
            StatsCard("最近调用", subtitle: "最多显示 20 条 · 完整记录可导出 CSV") {
                AIRecentTable(records: Array(summary.records.prefix(20)))
            }
        }
    }

    private func shareRows(_ counts: [AIUsageCount], offset: Int) -> [StatsShareRow] {
        counts.enumerated().map { index, count in
            StatsShareRow(id: count.id, title: count.title, count: count.count,
                          color: AIUsagePalette.color(index + offset))
        }
    }

    private func modelSlices(_ summary: AIUsageSummary) -> [AIShareSlice] {
        typealias F = AIUsageFormat
        return summary.models.enumerated().map { index, row in
            AIShareSlice(id: row.id, title: row.id, value: Double(row.calls), color: AIUsagePalette.color(index),
                         detail: "\(row.calls) 次 · 平均 \(F.seconds(row.averageSeconds)) · 每次 \(F.cost(row.costPerCall))")
        }
    }

    private func tokenSlices(_ summary: AIUsageSummary) -> [AIShareSlice] {
        let values = [summary.cacheHitTokens, summary.cacheMissTokens, summary.completionTokens]
        let colors = AITrendPalette.colors(.tokens, series: AIUsageStats.tokenSeries)
        return AIUsageStats.tokenSeries.enumerated().compactMap { index, title in
            guard values[index] > 0 else { return nil }
            return AIShareSlice(id: title, title: title, value: Double(values[index]), color: colors[index],
                                detail: AIUsageFormat.tokens(values[index]) + " tokens")
        }
    }

    private func errorRows(_ counts: [AIUsageCount]) -> [StatsShareRow] {
        counts.map { StatsShareRow(id: "e" + $0.id, title: $0.title, count: $0.count, color: Theme.overdue) }
    }
}

private struct AIInsightsCard: View {
    let lines: [String]

    var body: some View {
        StatsCard("分析", subtitle: "根据这段时间的记录自动生成") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                        Text(verbatim: line)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// 趋势图配色：成功 / 失败用绿 / 红，Token 三段用绿 / 蓝 / 琥珀，费用按模型分色。
enum AITrendPalette {
    static func colors(_ metric: AITrendMetric, series: [String]) -> [Color] {
        switch metric {
        case .calls: return [Theme.done, Theme.overdue]
        case .tokens: return [Quadrant.neither.tint, Quadrant.notImportantUrgent.tint, Theme.accent]
        case .tokensPerCall: return [Quadrant.notImportantUrgent.tint, Theme.accent]
        case .latency: return [Theme.accent, Theme.overdue]
        case .cost: return AIUsagePalette.colors(series.count)
        case .cumulativeCost: return [Theme.done]
        case .events: return [Color(hex: 0x8E5BD6)]
        case .successRate: return [Theme.done]
        }
    }
}

/// 「趋势」卡片：上面选指标，下面选图表样式，选择会记住。
private struct AITrendCard: View {
    let summary: AIUsageSummary
    let unit: Calendar.Component
    let per: String
    @AppStorage("biandan.stats.ai.metric") private var metricRaw = AITrendMetric.calls.rawValue
    @AppStorage("biandan.stats.ai.style") private var styleRaw = AIChartStyle.stackedBar.rawValue

    var body: some View {
        let metric = AITrendMetric(rawValue: metricRaw) ?? .calls
        let chosen = AIChartStyle(rawValue: styleRaw) ?? .stackedBar
        let style = metric.stackable ? chosen : chosen.unstacked
        let trend = AIUsageStats.trend(metric, buckets: summary.buckets, models: summary.models.map(\.id))
        let colors = AITrendPalette.colors(metric, series: trend.series)
        let note = style != chosen ? " · 这个指标不适合堆积，已改用" + style.title : ""
        StatsCard("趋势", subtitle: per + "统计 · " + metric.detail + note) {
            VStack(alignment: .leading, spacing: 10) {
                AIMetricChips(selection: Binding(get: { metric }, set: { metricRaw = $0.rawValue }))
                ThemedSegmented(selection: Binding(get: { chosen }, set: { styleRaw = $0.rawValue }),
                                options: AIChartStyle.allCases.map { ThemeOption(value: $0, title: $0.title) })
                AITrendChart(trend: trend, colors: colors, metric: metric, style: style, unit: unit)
            }
        }
    }
}

private struct AIMetricChips: View {
    @Binding var selection: AITrendMetric

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AITrendMetric.allCases, id: \.self) { metric in
                chip(metric)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ metric: AITrendMetric) -> some View {
        let on = metric == selection
        return Button {
            selection = metric
        } label: {
            Text(verbatim: metric.title)
                .font(.system(size: 11.5, weight: on ? .bold : .medium))
                .foregroundStyle(on ? Color.white : Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(on ? Theme.accent : Theme.panel))
                .overlay(Capsule().stroke(on ? Theme.accent : Theme.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(metric.detail)
    }
}

/// 一张图，五种样式：柱状（并排）、堆积柱状、百分比堆积、折线、堆积面积。
private struct AITrendChart: View {
    let trend: AITrend
    let colors: [Color]
    let metric: AITrendMetric
    let style: AIChartStyle
    let unit: Calendar.Component

    var body: some View {
        if trend.points.isEmpty {
            Text("这段时间没有可画的数据")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            chart
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch style {
        case .bar:
            decorate(Chart(trend.points) { point in
                BarMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .position(by: .value("系列", point.series))
                    .cornerRadius(2)
            })
        case .stackedBar:
            decorate(Chart(trend.points) { point in
                BarMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value),
                        stacking: .standard)
                    .foregroundStyle(by: .value("系列", point.series))
                    .cornerRadius(2)
            })
        case .normalized:
            decorate(Chart(trend.points) { point in
                BarMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value),
                        stacking: .normalized)
                    .foregroundStyle(by: .value("系列", point.series))
            })
        case .line:
            decorate(Chart(trend.points) { point in
                LineMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .symbolSize(20)
            })
        case .area:
            decorate(Chart(trend.points) { point in
                AreaMark(x: .value("日期", point.date, unit: unit), y: .value(metric.title, point.value),
                         stacking: .standard)
                    .foregroundStyle(by: .value("系列", point.series))
                    .interpolationMethod(.monotone)
                    .opacity(0.85)
            })
        }
    }

    private func decorate(_ chart: some View) -> some View {
        let legend: Visibility = trend.series.count > 1 ? .visible : .hidden
        return chart
            .chartForegroundStyleScale(domain: trend.series, range: colors)
            .chartLegend(legend)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { Text(verbatim: axisLabel(value)) }
                }
            }
            .chartHoverTip(hit: ChartHover.dates(dates, spanDays: days), tip: tip)
            .frame(height: 210)
    }

    private var days: Int { unit == .weekOfYear ? 7 : 1 }
    private var dates: [Date] { ChartHover.distinctDates(trend.points) }

    private func tip(_ index: Int) -> ChartTip? {
        let all = dates
        guard all.indices.contains(index) else { return nil }
        return ChartHover.seriesTip(trend.points, at: all[index], series: trend.series, colors: colors, days: days,
                                    total: metric.stackable, share: style == .normalized, format: valueText)
    }

    private func valueText(_ value: Double) -> String {
        switch metric {
        case .calls: return "\(Int(value.rounded())) 次"
        case .events: return "\(Int(value.rounded())) 条"
        case .tokens, .tokensPerCall: return AIUsageFormat.tokens(Int(value.rounded()))
        case .latency: return String(format: "%.1f 秒", value)
        case .cost, .cumulativeCost: return value == 0 ? "$0" : String(format: "$%.4f", value)
        case .successRate: return AIUsageFormat.percent(value)
        }
    }

    private func axisLabel(_ value: AxisValue) -> String {
        guard let number = value.as(Double.self) else { return "" }
        if style == .normalized || metric == .successRate { return "\(Int((number * 100).rounded()))%" }
        switch metric {
        case .cost, .cumulativeCost:
            if number == 0 { return "$0" }
            return String(format: number < 0.01 ? "$%.4f" : "$%.2f", number)
        case .tokens, .tokensPerCall:
            return AIUsageFormat.tokens(Int(number.rounded()))
        case .latency:
            return String(format: "%.1f 秒", number)
        default:
            return String(format: "%.0f", number)
        }
    }
}

// MARK: - 环形图（模型占比、Token 构成）

struct AIShareSlice: Identifiable {
    let id: String
    let title: String
    let value: Double
    let color: Color
    let detail: String
}

private struct AIShareDonut: View {
    let slices: [AIShareSlice]
    let center: String
    let caption: String
    @State private var hovered: String?
    @State private var location: CGPoint = .zero

    var body: some View {
        let total = slices.reduce(0) { $0 + $1.value }
        if slices.isEmpty || total <= 0 {
            Text("暂无数据")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .frame(height: 116)
        } else {
            HStack(alignment: .center, spacing: 14) {
                donut(total: total)
                    .zIndex(1)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(slices) { slice in
                        legend(slice, share: slice.value / total)
                            .opacity(fade(slice))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func outer(_ slice: AIShareSlice) -> CGFloat { hovered == slice.id ? 1 : 0.94 }

    private func fade(_ slice: AIShareSlice) -> Double { hovered == nil || hovered == slice.id ? 1 : 0.4 }

    private func donut(total: Double) -> some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("占比", slice.value), innerRadius: .ratio(0.62),
                       outerRadius: .ratio(outer(slice)), angularInset: 1.5)
                .foregroundStyle(slice.color)
                .opacity(fade(slice))
                .cornerRadius(3)
        }
        .frame(width: 116, height: 116)
        .overlay { centerLabel }
        .overlay { hoverLayer(total: total) }
    }

    private var centerLabel: some View {
        VStack(spacing: 0) {
            Text(verbatim: center)
                .font(.system(size: 14, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: caption)
                .font(.system(size: 10))
                .foregroundStyle(Theme.subtext)
        }
        .frame(width: 64)
        .allowsHitTesting(false)
    }

    private func hoverLayer(total: Double) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        location = point
                        hovered = sliceID(at: point, size: geometry.size, total: total)
                    case .ended:
                        hovered = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let id = hovered, let slice = slices.first(where: { $0.id == id }) {
                        ChartTipView(tip: tip(slice, total: total))
                            .chartTipPlacement(at: location, in: geometry.size, clamp: false)
                    }
                }
        }
    }

    /// 扇区从 12 点方向开始、按数据顺序顺时针排列。
    private func sliceID(at point: CGPoint, size: CGSize, total: Double) -> String? {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let radius = hypot(dx, dy)
        let outerRadius = min(size.width, size.height) / 2
        guard radius >= outerRadius * 0.55, radius <= outerRadius + 2 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let target = Double(angle / (2 * .pi)) * total
        var sum = 0.0
        for slice in slices {
            sum += slice.value
            if target < sum { return slice.id }
        }
        return slices.last?.id
    }

    private func tip(_ slice: AIShareSlice, total: Double) -> ChartTip {
        let rows: [ChartTipRow] = [
            ChartTipRow(name: "占比", value: AIUsageFormat.percent(slice.value / total), color: slice.color),
            ChartTipRow(name: "明细", value: slice.detail, color: slice.color),
        ]
        return ChartTip(title: slice.title, rows: rows)
    }

    private func legend(_ slice: AIShareSlice, share: Double) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(slice.color).frame(width: 9, height: 9).padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: slice.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(verbatim: AIUsageFormat.percent(share))
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(slice.color)
                }
                Text(verbatim: slice.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            }
        }
    }
}

private struct AILatencyHistogram: View {
    let bins: [AIUsageCount]

    var body: some View {
        Chart(bins) { bin in
            BarMark(x: .value("用时", bin.title), y: .value("次数", bin.count))
                .foregroundStyle(Quadrant.notImportantUrgent.tint)
                .cornerRadius(3)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartHoverTip(hit: ChartHover.categories(bins.map(\.title)), tip: tip)
        .frame(height: 150)
    }

    private func tip(_ index: Int) -> ChartTip? {
        guard bins.indices.contains(index) else { return nil }
        let bin = bins[index]
        let total = bins.reduce(0) { $0 + $1.count }
        var value = "\(bin.count) 次"
        if total > 0 { value += "（" + AIUsageFormat.percent(Double(bin.count) / Double(total)) + "）" }
        let row = ChartTipRow(name: "成功调用", value: value, color: Quadrant.notImportantUrgent.tint)
        return ChartTip(title: "用时 " + bin.title, rows: [row])
    }
}

private struct AIHourChart: View {
    let hours: [AIHourCount]

    var body: some View {
        Chart(hours) { item in
            BarMark(x: .value("时段", item.label), y: .value("次数", item.count))
                .foregroundStyle(Theme.accent)
                .cornerRadius(2)
        }
        .chartXAxis { AxisMarks(values: ["0时", "6时", "12时", "18时", "23时"]) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartHoverTip(hit: ChartHover.categories(hours.map(\.label)), tip: tip)
        .frame(height: 150)
    }

    private func tip(_ index: Int) -> ChartTip? {
        guard hours.indices.contains(index) else { return nil }
        let item = hours[index]
        let title = String(format: "%02d:00–%02d:59", item.hour, item.hour)
        return ChartTip(title: title, rows: [ChartTipRow(name: "调用", value: "\(item.count) 次", color: Theme.accent)])
    }
}

private struct AIScatterChart: View {
    let records: [AIUsageRecord]
    let models: [String]

    var body: some View {
        Chart(records) { record in
            PointMark(x: .value("Token", record.totalTokens), y: .value("用时（秒）", record.seconds))
                .foregroundStyle(by: .value("模型", record.model))
                .symbolSize(28)
                .opacity(0.8)
        }
        .chartForegroundStyleScale(domain: models, range: AIUsagePalette.colors(models.count))
        .chartXAxisLabel("Token")
        .chartYAxisLabel("用时（秒）")
        .chartYAxis { AxisMarks(position: .leading) }
        .chartHoverTip(hit: ChartHover.nearest(points), tip: tip)
        .frame(height: 190)
    }

    private var points: [ChartValuePoint] {
        records.map { ChartValuePoint(x: Double($0.totalTokens), y: $0.seconds) }
    }

    private func tip(_ index: Int) -> ChartTip? {
        guard records.indices.contains(index) else { return nil }
        typealias F = AIUsageFormat
        let record = records[index]
        let color = AIUsagePalette.color(models.firstIndex(of: record.model) ?? 0)
        let rows: [ChartTipRow] = [
            ChartTipRow(name: "模型", value: record.model, color: color),
            ChartTipRow(name: "Token", value: F.tokens(record.totalTokens), color: Quadrant.notImportantUrgent.tint),
            ChartTipRow(name: "用时", value: F.seconds(record.seconds), color: Theme.accent),
            ChartTipRow(name: "识别日程", value: "\(record.events) 条", color: Color(hex: 0x8E5BD6)),
        ]
        return ChartTip(title: F.time(record.date), rows: rows)
    }
}

// MARK: - 最近调用

private struct AIRecentTable: View {
    let records: [AIUsageRecord]
    private static let widths: [CGFloat] = [104, 116, 66, 56, 66, 56, 68]
    private static let header = ["时间", "模型", "触发", "用时", "输入", "输出", "费用", "结果"]

    var body: some View {
        VStack(spacing: 0) {
            row(Self.header, header: true, failed: false)
            ForEach(records) { record in
                Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
                row(Self.cells(record), header: false, failed: !record.success)
                    .help(record.error ?? AIUsageFormat.brief(record))
            }
        }
    }

    private static func cells(_ record: AIUsageRecord) -> [String] {
        typealias F = AIUsageFormat
        let result: String = record.success ? "成功 · \(record.events) 条" : AIUsageStats.errorKind(record.error)
        return [
            F.time(record.date), record.model, record.trigger.title, F.seconds(record.seconds),
            F.tokens(record.promptTokens), F.tokens(record.completionTokens), F.cost(record.costUSD), result,
        ]
    }

    private func row(_ cells: [String], header: Bool, failed: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, text in
                cell(text, index: index, header: header, failed: failed)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func cell(_ text: String, index: Int, header: Bool, failed: Bool) -> some View {
        let isResult = index == Self.widths.count
        let color: Color = header ? Theme.subtext : ((failed && isResult) ? Theme.overdue : Theme.text)
        let weight: Font.Weight = header ? .semibold : .regular
        let label = Text(verbatim: text)
            .font(.system(size: 11.5, weight: weight))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
        if isResult {
            label.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            label.frame(width: Self.widths[index], alignment: .leading)
        }
    }
}
