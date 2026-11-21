import SwiftUI

extension OccurrenceItem {
    static func dayLabel(_ day: LocalDate, today: LocalDate) -> String {
        switch today.days(to: day) {
        case 0: return "今天"
        case 1: return "明天"
        case -1: return "昨天"
        default: return day.year == today.year ? "\(day.month)/\(day.day)" : day.iso
        }
    }

    /// 卡片上的时间文本，例如「09:30–10:00」「明天」「11/23 → 11/29」。
    func scheduleText(today: LocalDate) -> String {
        guard !task.undated, let start = occurrence.startDate else { return "无日期" }
        let end = occurrence.endDate ?? start
        let allDay = occurrence.validStartTime.hasPrefix("00:00") && occurrence.validEndTime.hasPrefix("23:59")
        let from = occurrence.startClock?.shortText ?? ""
        let to = occurrence.endClock?.shortText ?? ""
        // 开始、结束时刻相同时只显示一个时刻。
        let clock = from == to ? from : "\(from)–\(to)"
        if start == end {
            if allDay { return Self.dayLabel(start, today: today) }
            let prefix = start == today ? "" : Self.dayLabel(start, today: today) + " "
            return prefix + clock
        }
        let range = "\(Self.dayLabel(start, today: today)) → \(Self.dayLabel(end, today: today))"
        return allDay ? range : range + " " + clock
    }
}

private struct MetaChip {
    var icon: String?
    var text: String
    var tint: Color?
}

/// 一个执行实例的卡片，用于四象限、列表和日历。P3 只读，圆圈不可点。
struct OccurrenceCard: View {
    @Environment(AppModel.self) private var model
    let item: OccurrenceItem
    var compact = false
    var showList = true

    var body: some View {
        let selected = model.selectedOccurrenceID == item.id
        let progress = item.progress
        HStack(alignment: .top, spacing: 9) {
            Button {
                Task { await model.toggleCompletion(item) }
            } label: {
                StatusCircle(status: item.status, tint: model.checkboxTint(for: item.task))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .help(item.status == .pending ? "完成本次" : (item.status == .completed ? "撤销完成" : "恢复"))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .strikethrough(item.status != .pending)
                    .foregroundStyle(item.status == .pending ? Theme.text : Theme.subtext)
                    .lineLimit(compact ? 1 : 2)
                if !compact {
                    HStack(spacing: 8) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                            HStack(spacing: 3) {
                                if let icon = chip.icon {
                                    Image(systemName: icon).font(.system(size: 9.5))
                                        .foregroundStyle(chip.tint ?? Theme.subtext)
                                }
                                Text(chip.text)
                                    .foregroundStyle(chip.icon == nil ? (chip.tint ?? Theme.subtext) : Theme.subtext)
                            }
                        }
                    }
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    if item.status == .pending && progress.targetCount > 1 {
                        ThinProgress(fraction: progress.fraction)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 5 : 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedOccurrenceID = item.id
            model.selectedFocusID = nil
        }
        .draggable(item.id)
        .themedContextMenu(onOpen: {
            model.selectedOccurrenceID = item.id
            model.selectedFocusID = nil
        }) { close in
            OccurrenceContextMenu(item: item, close: close).environment(model)
        }
    }

    private var chips: [MetaChip] {
        let task = item.task
        let progress = item.progress
        var result: [MetaChip] = []
        let overdue = item.isOverdue(today: model.today)
        result.append(MetaChip(icon: nil, text: (overdue ? "逾期 · " : "") + item.scheduleText(today: model.today),
                               tint: overdue ? Theme.overdue : nil))
        if task.isRepeating {
            result.append(MetaChip(icon: "repeat", text: RuleSummary.describe(task), tint: nil))
        }
        if task.isHabit {
            result.append(MetaChip(icon: "leaf", text: "习惯", tint: Theme.done))
        }
        if task.hasTimeReminder {
            let time = LocalTime(text: task.remindTime)?.shortText ?? ""
            result.append(MetaChip(icon: "bell", text: time, tint: nil))
        }
        if task.hasLocation {
            result.append(MetaChip(icon: task.hasLocationReminder ? "mappin.and.ellipse" : "mappin",
                                   text: task.location.isEmpty ? "地点提醒" : task.location, tint: nil))
        }
        if task.goal.isChecklist {
            result.append(MetaChip(icon: "checklist", text: "\(progress.completedCount)/\(progress.targetCount)", tint: nil))
        } else if progress.targetCount > 1 {
            result.append(MetaChip(icon: nil, text: "次数 \(progress.completedCount)/\(progress.targetCount)", tint: nil))
        }
        if item.status == .completed, let at = item.occurrence.completedAt {
            result.append(MetaChip(icon: nil, text: "完成于 " + String(at.dropFirst(11).prefix(5)), tint: nil))
        }
        if task.collected {
            result.append(MetaChip(icon: "star.fill", text: "", tint: Theme.accent))
        }
        if showList, task.id3 != TodoList.defaultID, let list = model.snapshot.list(task.id3) {
            result.append(MetaChip(icon: "circle.fill", text: list.displayName, tint: list.swatch))
        }
        return result
    }
}

/// 完成圆圈的取色：开关打开且待办单选了颜色时用待办单颜色；默认色（0 号）和关闭时返回 nil，保持原样式。
enum CheckboxTint {
    static func hex(listColor: ListColor?, enabled: Bool) -> UInt32? {
        guard enabled, let listColor, listColor.colorIndex > 0,
              ListColor.palette.indices.contains(listColor.colorIndex) else { return nil }
        return listColor.hex
    }
}

extension AppModel {
    func checkboxTint(for task: TaskDef) -> Color? {
        CheckboxTint.hex(listColor: snapshot.list(task.id3)?.color, enabled: tintCheckboxByList).map { Color(hex: $0) }
    }
}

struct StatusCircle: View {
    let status: OccurrenceStatus
    /// nil 表示原样式：灰色圆圈、绿色完成。
    var tint: Color? = nil
    var size: CGFloat = 16

    private var ring: Color { tint ?? Color(hex: 0xB9B09C) }
    private var filled: Color { tint ?? Theme.done }
    private var abandonedRing: Color { tint.map { $0.opacity(0.55) } ?? Color(hex: 0xB9B09C) }

    var body: some View {
        switch status {
        case .pending:
            Circle()
                .stroke(ring, lineWidth: tint == nil ? 1.6 : 1.9)
                .frame(width: size, height: size)
        case .completed:
            ZStack {
                Circle().fill(filled)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case .abandoned:
            ZStack {
                Circle().stroke(abandonedRing, lineWidth: 1.6)
                Image(systemName: "minus")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(Theme.subtext)
            }
            .frame(width: size, height: size)
        }
    }
}

struct ThinProgress: View {
    let fraction: Double
    var width: CGFloat = 120

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color(hex: 0xE7E0D0))
            Capsule().fill(Theme.accent).frame(width: width * max(0, min(fraction, 1)))
        }
        .frame(width: width, height: 4)
    }
}
