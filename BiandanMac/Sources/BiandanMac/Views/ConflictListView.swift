import SwiftUI

/// 日程冲突：今天起 30 天内，待完成的定时日程时间段有交叉的，按日期分组列出。点任务可以在检查器里改时间。
struct ConflictListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = model.scheduleConflicts
        if groups.isEmpty {
            ContentUnavailableView("近 30 天没有日程冲突", systemImage: "checkmark.seal",
                                   description: Text("待完成的定时日程时间段有交叉时，会在这里列出"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "近 30 天有 \(groups.count) 处时间重叠。点任务可以在右侧改时间，改完会自动从这里消失。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                    ForEach(groups) { group in
                        ConflictGroupCard(group: group)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct ConflictGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: ScheduleConflictGroup

    private func tint(_ item: OccurrenceItem) -> Color {
        model.snapshot.list(item.task.id3)?.swatch ?? TimelineStyle.fallbackTint(item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.overdue)
                Text(verbatim: ScheduleConflicts.dayText(group.day, today: model.today))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: ScheduleConflicts.rangeText(group.start, group.end) + " · \(group.slots.count) 项重叠")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.overdue)
                Spacer(minLength: 0)
            }
            ConflictBars(group: group, tint: tint)
            VStack(spacing: 6) {
                ForEach(group.slots, id: \.item.id) { slot in
                    HStack(alignment: .center, spacing: 10) {
                        Text(verbatim: ScheduleConflicts.rangeText(slot.start, slot.end))
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.subtext)
                            .frame(width: 84, alignment: .leading)
                        OccurrenceCard(item: slot.item)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.overdue.opacity(0.45), lineWidth: 1.2))
    }
}

/// 每项一条横条，按组内最早开始到最晚结束排开，看得出哪一段重叠。
private struct ConflictBars: View {
    let group: ScheduleConflictGroup
    let tint: (OccurrenceItem) -> Color

    var body: some View {
        let low = group.start
        let span = CGFloat(max(group.end - group.start, 1))
        VStack(spacing: 3) {
            ForEach(group.slots, id: \.item.id) { slot in
                GeometryReader { geometry in
                    let width = geometry.size.width
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint(slot.item).opacity(0.85))
                        .frame(width: max(width * CGFloat(slot.end - slot.start) / span, 4), height: 6)
                        .offset(x: width * CGFloat(slot.start - low) / span)
                }
                .frame(height: 6)
            }
        }
        .padding(.leading, 94)
    }
}

/// 新建的日程和已有日程时间重叠时，底部弹出的醒目提醒。
struct ConflictNoticeCard: View {
    @Environment(AppModel.self) private var model
    let notice: ConflictNotice

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.overdue)
            VStack(alignment: .leading, spacing: 3) {
                Text("日程冲突")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Theme.overdue)
                Text(verbatim: notice.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                model.sidebarSelection = .conflicts
                model.conflictNotice = nil
            } label: {
                Text("查看冲突")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.overdue))
            }
            .buttonStyle(.plain)
            Button {
                model.conflictNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.overdue, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
