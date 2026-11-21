import SwiftUI

/// 时间条提示卡片里的一行。
struct TimelineTooltipRow: Hashable {
    let title: String
    let detail: String
    let color: Color
    /// 时间冲突说明，红字显示在下面一行。
    var warning: String? = nil
}

/// 提示卡片里的红色冲突说明。
private struct TimelineTooltipWarning: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
            Text(verbatim: text).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(Theme.overdue)
    }
}

/// 时间条上可以悬停 / 点击的一个点（圆点或「+N」）。
struct TimelineHoverTarget: Identifiable {
    let id: String
    let point: CGPoint
    /// 点击时选中的任务；「+N」没有对应的单个任务。
    let item: OccurrenceItem?
    let rows: [TimelineTooltipRow]
    var more = 0
}

enum TimelineHit {
    /// 鼠标离圆点中心多近就算指向它（圆点本身只有 10pt）。
    static let radius: CGFloat = 22

    /// 离 point 最近、且在 radius 以内的点。
    static func nearest(_ targets: [TimelineHoverTarget], to point: CGPoint) -> TimelineHoverTarget? {
        var best: TimelineHoverTarget?
        var bestDistance = CGFloat.infinity
        for target in targets {
            let distance = hypot(target.point.x - point.x, target.point.y - point.y)
            if distance <= radius, distance < bestDistance {
                best = target
                bestDistance = distance
            }
        }
        return best
    }
}

/// 盖在时间条上的透明层：鼠标靠近圆点就显示主题样式的提示卡片，点击选中最近的圆点。
/// 比时间条向上多出一点，从上方靠近最上面一排圆点时也能提示。
struct TimelineHoverLayer: View {
    let targets: [TimelineHoverTarget]
    let size: CGSize
    @Binding var hovered: String?
    let onSelect: (OccurrenceItem) -> Void

    static let pad: CGFloat = 10

    var body: some View {
        let pad = Self.pad
        let active = targets.first { $0.id == hovered }
        Color.clear
            .frame(width: size.width, height: size.height + pad)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let id = TimelineHit.nearest(targets, to: CGPoint(x: location.x, y: location.y - pad))?.id
                    if id != hovered { hovered = id }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                let target = TimelineHit.nearest(targets, to: CGPoint(x: location.x, y: location.y - pad))
                if let item = target?.item { onSelect(item) }
            }
            .overlay(alignment: .topLeading) {
                if let active {
                    TimelineTooltipPlacement(target: active, width: size.width, dotY: active.point.y + pad)
                        .allowsHitTesting(false)
                }
            }
            .offset(y: -pad)
    }
}

/// 把提示卡片放在圆点正上方；靠近左右两端时贴边，不超出时间条。
private struct TimelineTooltipPlacement: View {
    let target: TimelineHoverTarget
    let width: CGFloat
    /// 圆点在透明层里的 y。
    let dotY: CGFloat

    private static let edge: CGFloat = 120

    var body: some View {
        let x = target.point.x
        let height = max(dotY - TimelineStyle.dot / 2 - 7, 0)
        let card = TimelineTooltip(rows: target.rows, more: target.more).fixedSize()
        if x < Self.edge {
            card.frame(width: width, height: height, alignment: .bottomLeading)
                .offset(x: max(x - 14, 0))
        } else if x > width - Self.edge {
            card.frame(width: width, height: height, alignment: .bottomTrailing)
                .offset(x: min(x + 14 - width, 0))
        } else {
            card.frame(width: width, height: height, alignment: .bottom)
                .offset(x: x - width / 2)
        }
    }
}

/// 提示卡片：同内容区的白卡片（圆角、细描边、轻阴影），每行一个分类色圆点 + 标题 + 时间状态。
private struct TimelineTooltip: View {
    let rows: [TimelineTooltipRow]
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: rows.count > 1 ? 4 : 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if rows.count > 1 {
                    TimelineTooltipCompactLine(row: row)
                } else {
                    TimelineTooltipLine(row: row)
                }
            }
            if more > 0 {
                Text(verbatim: "还有 \(more) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

/// 多项时每项一行：圆点 · 标题 · 时间状态，卡片不会太高。
private struct TimelineTooltipCompactLine: View {
    let row: TimelineTooltipRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle().fill(row.color).frame(width: 7, height: 7)
                Text(verbatim: row.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: row.detail)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtext)
            }
            if let warning = row.warning {
                TimelineTooltipWarning(text: warning).padding(.leading, 13)
            }
        }
    }
}

private struct TimelineTooltipLine: View {
    let row: TimelineTooltipRow

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(row.color)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: row.detail)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtext)
                if let warning = row.warning {
                    TimelineTooltipWarning(text: warning).padding(.top, 2)
                }
            }
        }
    }
}
