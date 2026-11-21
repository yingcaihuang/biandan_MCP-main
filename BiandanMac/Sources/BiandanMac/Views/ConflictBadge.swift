import SwiftUI

private struct ConflictIndexKey: EnvironmentKey {
    static let defaultValue: [String: [ConflictPartner]] = [:]
}

extension EnvironmentValues {
    /// 内容区统一算一次冲突，卡片按实例 ID 取，避免每张卡片各算一遍。
    var conflictIndex: [String: [ConflictPartner]] {
        get { self[ConflictIndexKey.self] }
        set { self[ConflictIndexKey.self] = newValue }
    }
}

/// 卡片右上角的「⚠︎ 冲突」角标。鼠标移上去列出和它冲突的日程，点一项跳过去。
struct ConflictBadge: View {
    let partners: [ConflictPartner]
    var compact = false

    var body: some View {
        let horizontal: CGFloat = compact ? 4 : 6
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .bold))
            if !compact {
                Text("冲突").font(.system(size: 10.5, weight: .bold))
            }
        }
        .foregroundStyle(Theme.overdue)
        .padding(.horizontal, horizontal)
        .frame(height: 18)
        .background(Capsule().fill(Theme.overdue.opacity(0.12)))
        .overlay(Capsule().stroke(Theme.overdue.opacity(0.55), lineWidth: 1))
        .contentShape(Capsule())
        .hoverPopover(arrowEdge: .trailing) { close in
            ConflictPartnerPopover(partners: partners, close: close)
        }
    }
}

private struct ConflictPartnerPopover: View {
    @Environment(AppModel.self) private var model
    let partners: [ConflictPartner]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.overdue)
                Text(verbatim: "与 \(partners.count) 项日程时间冲突")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            ForEach(partners, id: \.id) { partner in
                ConflictPartnerRow(partner: partner) {
                    close()
                    model.jumpToOccurrence(partner.item.id)
                }
            }
            Text("点一项跳过去，可以在右侧检查器里改时间")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtext)
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
    }
}

private struct ConflictPartnerRow: View {
    @Environment(AppModel.self) private var model
    let partner: ConflictPartner
    let action: () -> Void
    @State private var hovering = false

    private var tint: Color {
        model.snapshot.list(partner.item.task.id3)?.swatch ?? TimelineStyle.fallbackTint(partner.item)
    }

    private var detail: String {
        let parts: [String] = [
            OccurrenceItem.dayLabel(partner.day, today: model.today),
            ScheduleConflicts.rangeText(partner.start, partner.end),
            "· 重叠",
            ScheduleConflicts.rangeText(partner.overlapStart, partner.overlapEnd),
        ]
        return parts.joined(separator: " ")
    }

    var body: some View {
        let fill: Color = hovering ? Theme.overdue.opacity(0.08) : Theme.panel
        let stroke: Color = hovering ? Theme.overdue.opacity(0.6) : Theme.line
        let jumpColor: Color = hovering ? Theme.overdue : Theme.subtext
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ScheduleConflicts.shortTitle(partner.item))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(verbatim: detail)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.subtext)
                }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    Text("跳转")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(jumpColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(stroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
