import Charts
import SwiftUI

// MARK: - 统计图表的悬停提示：鼠标移到柱子、点或日期上，显示日期 / 名称和数值

struct ChartTipRow: Identifiable {
    let name: String
    let value: String
    let color: Color
    var id: String { name }
}

struct ChartTip {
    var title: String
    var rows: [ChartTipRow]
    var footer: String? = nil
}

struct ChartHoverHit {
    var index: Int
    /// 高亮的横向区间（图表坐标）。
    var band: ClosedRange<CGFloat>? = nil
    /// 高亮的点（散点图）。
    var point: CGPoint? = nil
}

struct ChartValuePoint {
    let x: Double
    let y: Double
}

/// 参数：图表代理、鼠标位置、绘图区（都在同一坐标系里）。
typealias ChartHitTest = (ChartProxy, CGPoint, CGRect) -> ChartHoverHit?

extension View {
    /// 给 Chart 加悬停提示。hit 找出鼠标下的数据项，tip 给出这一项的提示内容。
    func chartHoverTip(hit: @escaping ChartHitTest, tip: @escaping (Int) -> ChartTip?) -> some View {
        chartOverlay { proxy in
            ChartHoverLayer(proxy: proxy, hit: hit, tip: tip)
        }
    }

    /// 放在鼠标旁边：右边放不下时放左边，并限制在 size 以内；clamp 为 false 时只往右放，可以超出。
    func chartTipPlacement(at location: CGPoint, in size: CGSize, clamp: Bool = true) -> some View {
        fixedSize()
            .alignmentGuide(.leading) { d in
                -ChartHover.tipX(location.x, width: d.width, limit: size.width, clamp: clamp)
            }
            .alignmentGuide(.top) { d in
                -ChartHover.tipY(location.y, height: d.height, limit: size.height, clamp: clamp)
            }
            .allowsHitTesting(false)
    }
}

enum ChartHover {
    static func tipX(_ x: CGFloat, width: CGFloat, limit: CGFloat, clamp: Bool) -> CGFloat {
        let right = x + 14
        guard clamp else { return right }
        let left = x - 14 - width
        let chosen = right + width <= limit || left < 0 ? right : left
        return min(max(chosen, 0), max(limit - width, 0))
    }

    static func tipY(_ y: CGFloat, height: CGFloat, limit: CGFloat, clamp: Bool) -> CGFloat {
        let top = y - height / 2
        guard clamp else { return top }
        return min(max(top, 0), max(limit - height, 0))
    }

    // MARK: 命中

    /// 按日期分段的图：starts 为每段起点（升序），每段 spanDays 天。
    static func dates(_ starts: [Date], spanDays: Int, calendar: Calendar = .current) -> ChartHitTest {
        { proxy, location, plot in
            guard !starts.isEmpty, location.x >= plot.minX, location.x <= plot.maxX,
                  let value = proxy.value(atX: location.x - plot.minX, as: Date.self),
                  let index = starts.lastIndex(where: { $0 <= value }) else { return nil }
            let start = starts[index]
            let end = calendar.date(byAdding: .day, value: max(spanDays, 1), to: start) ?? start
            guard value < end else { return nil }
            return ChartHoverHit(index: index, band: dateBand(proxy, start, end, plot))
        }
    }

    private static func dateBand(_ proxy: ChartProxy, _ start: Date, _ end: Date,
                                 _ plot: CGRect) -> ClosedRange<CGFloat>? {
        guard let x0 = proxy.position(forX: start), let x1 = proxy.position(forX: end) else { return nil }
        let low = max(plot.minX + min(x0, x1), plot.minX)
        let high = min(plot.minX + max(x0, x1), plot.maxX)
        return low < high ? low...high : nil
    }

    /// 按名称分类的柱状图。
    static func categories(_ names: [String]) -> ChartHitTest {
        { proxy, location, plot in
            guard !names.isEmpty, plot.width > 0, location.x >= plot.minX, location.x <= plot.maxX else { return nil }
            var index: Int?
            if let value = proxy.value(atX: location.x - plot.minX, as: String.self) {
                index = names.firstIndex(of: value)
            }
            if index == nil {
                // 分类均分绘图区宽度。
                let slot = Int((location.x - plot.minX) / plot.width * CGFloat(names.count))
                index = min(max(slot, 0), names.count - 1)
            }
            guard let found = index else { return nil }
            let half = plot.width / CGFloat(names.count) / 2
            let center: CGFloat = proxy.position(forX: names[found]).map { plot.minX + $0 }
                ?? plot.minX + half * CGFloat(found * 2 + 1)
            let low = max(center - half, plot.minX)
            let high = min(center + half, plot.maxX)
            return ChartHoverHit(index: found, band: low < high ? low...high : nil)
        }
    }

    /// 散点图：离鼠标最近、且在 radius 以内的点。
    static func nearest(_ points: [ChartValuePoint], radius: CGFloat = 28) -> ChartHitTest {
        { proxy, location, plot in
            var bestIndex: Int?
            var bestDistance = CGFloat.infinity
            var bestPoint = CGPoint.zero
            for (index, item) in points.enumerated() {
                guard let px = proxy.position(forX: item.x), let py = proxy.position(forY: item.y) else { continue }
                let point = CGPoint(x: plot.minX + px, y: plot.minY + py)
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance <= radius && distance < bestDistance {
                    bestIndex = index
                    bestDistance = distance
                    bestPoint = point
                }
            }
            guard let bestIndex else { return nil }
            return ChartHoverHit(index: bestIndex, point: bestPoint)
        }
    }

    // MARK: 内容

    /// 「11月22日 周日」或「11月16日 周一 – 11月22日 周日」
    static func title(_ start: LocalDate, days: Int) -> String {
        guard days > 1 else { return start.shortTitle }
        return start.shortTitle + " – " + start.adding(days: days - 1).shortTitle
    }

    static func title(_ date: Date, days: Int) -> String {
        title(LocalDate.today(date, calendar: .current), days: days)
    }

    static func distinctDates(_ points: [AIChartPoint]) -> [Date] {
        Array(Set(points.map(\.date))).sorted()
    }

    /// 多系列趋势图某一段的提示：每个系列一行；total 时加合计，share 时附占比。
    static func seriesTip(_ points: [AIChartPoint], at date: Date, series: [String], colors: [Color], days: Int,
                          total: Bool, share: Bool = false, format: (Double) -> String) -> ChartTip {
        let values: [Double] = series.map { name in
            points.first { $0.date == date && $0.series == name }?.value ?? 0
        }
        let sum = values.reduce(0, +)
        var rows: [ChartTipRow] = []
        for (index, name) in series.enumerated() {
            var text = format(values[index])
            if share && sum > 0 { text += "（" + AIUsageFormat.percent(values[index] / sum) + "）" }
            let color: Color = colors.isEmpty ? Theme.accent : colors[index % colors.count]
            rows.append(ChartTipRow(name: name, value: text, color: color))
        }
        let footer: String? = total && series.count > 1 ? "合计 " + format(sum) : nil
        return ChartTip(title: title(date, days: days), rows: rows, footer: footer)
    }
}

// MARK: - 视图

struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let hit: ChartHitTest
    let tip: (Int) -> ChartTip?
    @State private var location: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let plot: CGRect = proxy.plotFrame.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
            let current: ChartHoverHit? = location.flatMap { self.hit(proxy, $0, plot) }
            let content: ChartTip? = current.flatMap { self.tip($0.index) }
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): location = point
                    case .ended: location = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let current, let content, let location {
                        ChartHoverMarks(hit: current, plot: plot)
                        ChartTipView(tip: content).chartTipPlacement(at: location, in: geometry.size)
                    }
                }
        }
    }
}

private struct ChartHoverMarks: View {
    let hit: ChartHoverHit
    let plot: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let band = hit.band {
                Rectangle()
                    .fill(Theme.text.opacity(0.07))
                    .frame(width: band.upperBound - band.lowerBound, height: plot.height)
                    .offset(x: band.lowerBound, y: plot.minY)
            }
            if let point = hit.point {
                Circle()
                    .stroke(Theme.text, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .offset(x: point.x - 7, y: point.y - 7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct ChartTipView: View {
    let tip: ChartTip

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: tip.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.text)
            ForEach(tip.rows) { row in ChartTipRowView(row: row) }
            if let footer = tip.footer {
                Rectangle().fill(Theme.line).frame(height: 1)
                Text(verbatim: footer)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(Theme.card))
        .overlay(shape.stroke(Theme.line))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
    }
}

private struct ChartTipRowView: View {
    let row: ChartTipRow

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 8, height: 8)
            Text(verbatim: row.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
            Spacer(minLength: 12)
            Text(verbatim: row.value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
    }
}
