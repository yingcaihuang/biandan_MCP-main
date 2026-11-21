import Charts
import SwiftUI

// MARK: - 统计 → 导入同步：同步次数与成功率、写入条数、来源分布、失败原因、来源健康

struct ImportSyncStatsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: StatsRange = .month
    @State private var logShown = false

    var body: some View {
        let logs = model.importLogs(sourceID: nil, limit: LocalStore.importLogLimit)
        Group {
            if logs.isEmpty && model.importSources.isEmpty {
                ContentUnavailableView("还没有导入日程", systemImage: "square.and.arrow.down.on.square",
                                       description: Text("在侧栏「导入日程」添加 CalDAV、URL 订阅、邮箱账户或文件后，每次同步的结果都会统计在这里"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                report(ImportSyncStats.summary(logs, range: range, today: model.today, weekStart: model.weekStart))
            }
        }
        .onAppear { model.reloadImportSources() }
        .sheet(isPresented: $logShown) { ImportLogSheet().environment(model) }
    }

    private func report(_ summary: ImportSyncSummary) -> some View {
        let unit: Calendar.Component = range.bucketDays == 7 ? .weekOfYear : .day
        let per = range.bucketDays == 7 ? "按周" : "按天"
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                toolbar(summary)
                ImportSyncOverview(summary: summary, troubled: troubledCount)
                if summary.syncs == 0 {
                    Text("这段时间没有同步记录，换个时间范围看看。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                } else {
                    charts(summary, unit: unit, per: per)
                }
                StatsCard("来源健康", subtitle: "当前状态 · 导入任务数为便单里实际还在的") {
                    ImportHealthList(sources: model.importSources)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }

    private var troubledCount: Int {
        model.importSources.filter { $0.kind.syncs && ($0.failures > 0 || $0.autoPaused) }.count
    }

    private func toolbar(_ summary: ImportSyncSummary) -> some View {
        HStack(spacing: 12) {
            ThemedSegmented(selection: $range,
                            options: StatsRange.allCases.map { ThemeOption(value: $0, title: $0.title) })
            Text(verbatim: "\(summary.start.shortTitle) – \(summary.end.shortTitle)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
            Spacer(minLength: 0)
            Button("查看同步日志") { logShown = true }.buttonStyle(.themed)
        }
    }

    @ViewBuilder
    private func charts(_ summary: ImportSyncSummary, unit: Calendar.Component, per: String) -> some View {
        StatsCard("同步结果", subtitle: per + "统计成功与失败的同步次数") {
            ImportStackedChart(points: ImportSyncStats.outcomePoints(summary.buckets), unit: unit,
                               series: ["成功", "失败"], colors: [Theme.done, Theme.overdue], label: "次数")
        }
        StatsCard("写入便单", subtitle: per + "统计新增（含重建）、更新和标记放弃的条数") {
            ImportStackedChart(points: ImportSyncStats.changePoints(summary.buckets), unit: unit,
                               series: ["新增", "更新", "放弃"],
                               colors: [Theme.accent, Quadrant.notImportantUrgent.tint, Theme.subtext], label: "条数")
        }
        HStack(alignment: .top, spacing: 14) {
            StatsCard("来源分布", subtitle: "按同步次数") {
                ImportShareList(rows: sourceRows(summary), empty: "没有同步")
            }
            StatsCard("触发方式", subtitle: "自动、手动和添加时的首次同步") {
                ImportShareList(rows: countRows(summary.triggers), empty: "没有同步")
            }
        }
        if summary.failures > 0 {
            HStack(alignment: .top, spacing: 14) {
                StatsCard("失败原因", subtitle: "\(summary.failures) 次失败") {
                    ImportShareList(rows: errorRows(summary.errors), empty: "没有失败")
                }
                StatsCard("各来源失败次数", subtitle: "只列出失败过的来源") {
                    ImportShareList(rows: failureRows(summary), empty: "没有失败")
                }
            }
            StatsCard("最近失败", subtitle: "最多显示 10 条 · 完整记录在同步日志里") {
                VStack(spacing: 0) {
                    ForEach(summary.recentFailures) { log in ImportLogRow(log: log, showSource: true) }
                }
            }
        }
    }

    private func sourceRows(_ summary: ImportSyncSummary) -> [StatsShareRow] {
        summary.sources.enumerated().map { index, row in
            StatsShareRow(id: "s" + row.id, title: row.name, count: row.syncs, color: AIUsagePalette.color(index))
        }
    }

    private func failureRows(_ summary: ImportSyncSummary) -> [StatsShareRow] {
        summary.sources.filter { $0.failures > 0 }.sorted { $0.failures > $1.failures }.map { row in
            StatsShareRow(id: "f" + row.id, title: row.name, count: row.failures, color: Theme.overdue)
        }
    }

    private func countRows(_ counts: [AIUsageCount]) -> [StatsShareRow] {
        counts.enumerated().map { index, item in
            StatsShareRow(id: "t" + item.id, title: item.title, count: item.count, color: AIUsagePalette.color(index))
        }
    }

    private func errorRows(_ counts: [AIUsageCount]) -> [StatsShareRow] {
        counts.map { StatsShareRow(id: "e" + $0.id, title: $0.title, count: $0.count, color: Theme.overdue) }
    }
}

// MARK: - 总览

private struct ImportSyncOverview: View {
    let summary: ImportSyncSummary
    let troubled: Int

    var body: some View {
        let failColor: Color = summary.failures > 0 ? Theme.overdue : Theme.text
        let troubleColor: Color = troubled > 0 ? Theme.overdue : Theme.done
        let rateTitle = "成功率 · 失败 \(summary.failures)"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                item("\(summary.syncs)", "同步次数", tint: Theme.text)
                item(AIUsageFormat.percent(summary.successRate), rateTitle, tint: failColor)
                item(ImportSyncStats.durationText(summary.averageMs), "平均耗时", tint: Theme.accent)
                item(ImportSyncStats.durationText(summary.p95Ms), "P95 耗时", tint: Theme.text)
                item("\(troubled)", "当前异常的来源", tint: troubleColor)
                Spacer(minLength: 0)
            }
            HStack(spacing: 28) {
                item("\(summary.fetched)", "读取日程", tint: Theme.text)
                item("\(summary.added)", "新增（含重建）", tint: Theme.done)
                item("\(summary.updated)", "更新", tint: Quadrant.notImportantUrgent.tint)
                item("\(summary.removed)", "标记放弃", tint: Theme.text)
                item("\(summary.writeFailed)", "写入失败", tint: summary.writeFailed > 0 ? Theme.overdue : Theme.text)
                item("\(summary.edits)", "修改设置", tint: Theme.text)
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

// MARK: - 图表与列表

private struct ImportStackedChart: View {
    let points: [AIChartPoint]
    let unit: Calendar.Component
    let series: [String]
    let colors: [Color]
    let label: String

    private var days: Int { unit == .weekOfYear ? 7 : 1 }
    private var dates: [Date] { ChartHover.distinctDates(points) }
    private var suffix: String { label == "次数" ? " 次" : " 条" }

    var body: some View {
        Chart(points) { point in
            BarMark(x: .value("日期", point.date, unit: unit), y: .value(label, point.value))
                .foregroundStyle(by: .value("类型", point.series))
                .cornerRadius(2)
        }
        .chartForegroundStyleScale(domain: series, range: colors)
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis { AxisMarks(position: .leading) }
        .chartHoverTip(hit: ChartHover.dates(dates, spanDays: days), tip: tip)
        .frame(height: 170)
    }

    private func tip(_ index: Int) -> ChartTip? {
        let all = dates
        guard all.indices.contains(index) else { return nil }
        return ChartHover.seriesTip(points, at: all[index], series: series, colors: colors, days: days,
                                    total: true, format: valueText)
    }

    private func valueText(_ value: Double) -> String { "\(Int(value.rounded()))" + suffix }
}

private struct ImportShareList: View {
    let rows: [StatsShareRow]
    let empty: String

    var body: some View {
        if rows.isEmpty {
            Text(verbatim: empty).font(.system(size: 12)).foregroundStyle(Theme.subtext)
        } else {
            StatsShareBars(rows: rows)
        }
    }
}

private struct ImportHealthList: View {
    @Environment(AppModel.self) private var model
    let sources: [ImportSource]

    var body: some View {
        if sources.isEmpty {
            Text("还没有导入来源").font(.system(size: 12)).foregroundStyle(Theme.subtext)
        } else {
            VStack(spacing: 8) {
                ForEach(sources) { source in ImportHealthRow(source: source) }
            }
        }
    }
}

private struct ImportHealthRow: View {
    @Environment(AppModel.self) private var model
    let source: ImportSource

    private var status: (text: String, color: Color) {
        if !source.kind.syncs { return ("一次性导入", Theme.subtext) }
        if !source.enabled && source.autoPaused { return ("失败过多 · 已暂停", Theme.overdue) }
        if !source.enabled { return ("已暂停", Theme.subtext) }
        if let retry = source.retryAt, retry > Date() { return ("退避中", Color(hex: 0xE8890C)) }
        if source.failures > 0 { return ("最近失败", Theme.overdue) }
        return ("正常", Theme.done)
    }

    private var detail: String {
        var parts = [source.kind.title, "\(source.lastCount) 条任务"]
        parts.append(source.lastSyncAt.map { "上次 " + AppModel.importTimeText($0) } ?? "还没同步")
        if source.failures > 0 { parts.append("连续失败 \(source.failures) 次") }
        if source.enabled, let retry = source.retryAt, retry > Date() {
            parts.append(AppModel.importTimeText(retry) + " 后再试")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let current = status
        let list = model.snapshot.list(source.listID)
        HStack(spacing: 10) {
            Image(systemName: source.kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(list?.swatch ?? Theme.subtext)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: source.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                if let error = source.lastError, source.failures > 0 {
                    Text(verbatim: error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.overdue)
                        .lineLimit(1)
                        .help(error)
                }
            }
            Spacer(minLength: 8)
            ImportTag(text: current.text, color: current.color)
        }
    }
}
