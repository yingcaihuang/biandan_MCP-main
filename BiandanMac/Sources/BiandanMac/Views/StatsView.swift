import Charts
import SwiftUI

enum StatsSubject: String, CaseIterable, Hashable {
    case tasks, ai

    var title: String { self == .tasks ? "任务" : "AI 识别" }
}

/// 统计：任务（完成趋势、按期完成率、象限与分类分布、专注时长）和 AI 识别（用时、token、费用）。
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: StatsRange = .month
    @AppStorage("biandan.stats.subject") private var subjectRaw = StatsSubject.tasks.rawValue

    var body: some View {
        let subject = StatsSubject(rawValue: subjectRaw) ?? .tasks
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ThemedSegmented(selection: Binding(get: { subject }, set: { subjectRaw = $0.rawValue }),
                                options: StatsSubject.allCases.map { ThemeOption(value: $0, title: $0.title) })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 10)
            if subject == .ai {
                AIUsageStatsView()
            } else if model.snapshot.tasks.isEmpty && model.snapshot.focus.isEmpty {
                ContentUnavailableView("还没有可统计的数据", systemImage: "chart.bar.xaxis",
                                       description: Text("同步完成后，这里会显示完成趋势和分布"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
    }

    private var content: some View {
        let summary = StatsCalculator.summary(model.snapshot, range: range, today: model.today,
                                              weekStart: model.weekStart)
        let unit: Calendar.Component = range.bucketDays == 7 ? .weekOfYear : .day
        let per = range.bucketDays == 7 ? "按周" : "按天"
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ThemedSegmented(selection: $range,
                                    options: StatsRange.allCases.map { ThemeOption(value: $0, title: $0.title) })
                    Text(verbatim: "\(summary.start.shortTitle) – \(summary.end.shortTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                    Spacer(minLength: 0)
                }
                StatsOverview(summary: summary)
                StatsCard("完成趋势", subtitle: per + "统计完成的执行实例") {
                    StatsTrendChart(buckets: summary.buckets, unit: unit, metric: .completed)
                }
                HStack(alignment: .top, spacing: 14) {
                    StatsCard("象限分布", subtitle: "待完成的任务") {
                        StatsShareBars(rows: quadrantRows(summary))
                    }
                    StatsCard("分类分布", subtitle: "待完成的任务") {
                        StatsShareBars(rows: listRows(summary))
                    }
                }
                StatsCard("专注时长", subtitle: per + "统计 · 合计 " + StatsCalculator.durationText(summary.focusMinutes)) {
                    StatsTrendChart(buckets: summary.buckets, unit: unit, metric: .focus)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }

    private func quadrantRows(_ summary: StatsSummary) -> [StatsShareRow] {
        summary.quadrants.map { row in
            StatsShareRow(id: "q\(row.quadrant.rawValue)", title: row.quadrant.title, count: row.count,
                          color: row.quadrant.tint)
        }
    }

    private func listRows(_ summary: StatsSummary) -> [StatsShareRow] {
        summary.lists.map { row in
            let color: Color = model.snapshot.list(row.id)?.swatch ?? Theme.subtext
            return StatsShareRow(id: "l" + row.id, title: row.name, count: row.count, color: color)
        }
    }
}

private struct StatsOverview: View {
    let summary: StatsSummary

    private var rateText: String {
        guard let rate = summary.onTimeRate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    private var rateTitle: String {
        "按期完成率 · \(summary.dueCompleted)/\(summary.dueTotal)"
    }

    var body: some View {
        let overdueColor: Color = summary.overdue > 0 ? Theme.overdue : Theme.text
        HStack(spacing: 28) {
            item("\(summary.completed)", "完成", tint: Theme.done)
            item(rateText, rateTitle, tint: Theme.accent)
            item("\(summary.overdue)", "当前逾期", tint: overdueColor)
            item(String(format: "%.1f", summary.dailyAverage), "日均完成", tint: Theme.text)
            item(StatsCalculator.durationText(summary.focusMinutes), "专注 · \(summary.focusCount) 次", tint: Theme.text)
            Spacer(minLength: 0)
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

struct StatsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(Theme.subtext)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

private struct StatsTrendChart: View {
    enum Metric { case completed, focus }

    let buckets: [StatsBucket]
    let unit: Calendar.Component
    let metric: Metric

    private var color: Color { metric == .completed ? Theme.accent : Quadrant.importantUrgent.tint }
    private var label: String { metric == .completed ? "完成" : "分钟" }

    private func value(_ bucket: StatsBucket) -> Double {
        metric == .completed ? Double(bucket.completed) : bucket.focusMinutes.rounded()
    }

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("日期", bucket.start.date(), unit: unit),
                    y: .value(label, value(bucket)))
                .foregroundStyle(color)
                .cornerRadius(3)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 170)
    }
}

struct StatsShareRow: Identifiable {
    let id: String
    let title: String
    let count: Int
    let color: Color
}

/// 横向比例条：名称 · 条 · 数量。
struct StatsShareBars: View {
    let rows: [StatsShareRow]

    var body: some View {
        let top = max(rows.map(\.count).max() ?? 0, 1)
        if rows.isEmpty {
            Text("没有待完成的任务").font(.system(size: 12)).foregroundStyle(Theme.subtext)
        } else {
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    StatsShareBar(row: row, fraction: Double(row.count) / Double(top))
                }
            }
        }
    }
}

private struct StatsShareBar: View {
    let row: StatsShareRow
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: row.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geometry in
                let width: CGFloat = row.count > 0 ? max(geometry.size.width * fraction, 4) : 0
                RoundedRectangle(cornerRadius: 4)
                    .fill(row.color.opacity(0.85))
                    .frame(width: width, height: 12)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            Text(verbatim: "\(row.count)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
