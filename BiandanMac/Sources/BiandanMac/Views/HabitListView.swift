import SwiftUI

/// 习惯打卡：每个习惯一张卡片，今日打卡、连续天数、近 14 天、打卡记录。
struct HabitListView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []

    var body: some View {
        let habits = model.habitSummaries
        if habits.isEmpty {
            ContentUnavailableView(model.searchText.isEmpty ? "还没有习惯" : "没有匹配的习惯",
                                   systemImage: "leaf",
                                   description: Text("新建重复任务时打开「标记为习惯」，就能在这里每天打卡"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HabitOverview(habits: habits)
                    ForEach(habits) { habit in
                        HabitCard(habit: habit, expanded: expanded.contains(habit.id)) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if expanded.contains(habit.id) { expanded.remove(habit.id) } else { expanded.insert(habit.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct HabitOverview: View {
    let habits: [HabitSummary]

    var body: some View {
        let due = habits.filter { $0.current != nil && $0.current?.status != .abandoned }
        let done = due.filter(\.checkedToday).count
        HStack(spacing: 28) {
            item("\(done)/\(due.count)", "今日已打卡", tint: due.count > 0 && done == due.count ? Theme.done : Theme.text)
            item("\(habits.map(\.streak).max() ?? 0) 天", "当前最长连续", tint: Theme.accent)
            item("\(habits.map(\.total).reduce(0, +))", "累计打卡", tint: Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func item(_ value: String, _ title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .heavy)).monospacedDigit().foregroundStyle(tint)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.subtext)
        }
    }
}

private struct HabitCard: View {
    @Environment(AppModel.self) private var model
    let habit: HabitSummary
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                checkButton
                VStack(alignment: .leading, spacing: 3) {
                    Text(habit.task.taskTitle.isEmpty ? "（无标题）" : habit.task.taskTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(RuleSummary.describe(habit.task))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                stat("\(habit.streak)", "连续天数", tint: habit.streak > 0 ? Theme.accent : Theme.subtext)
                stat("\(habit.best)", "最长连续", tint: Theme.text)
                stat("\(habit.total)", "累计打卡", tint: Theme.text)
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.subtext)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "收起打卡记录" : "查看打卡记录")
            }
            HabitDayStrip(days: habit.checkedDays, today: model.today)
            if expanded {
                records
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(habit.needsCheckIn ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: 1))
    }

    private var checkButton: some View {
        let current = habit.current
        let done = habit.checkedToday
        let disabled = current == nil || current?.status == .abandoned
        return Button {
            if let current { Task { await model.toggleCompletion(current) } }
        } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(done ? Theme.done : (disabled ? Theme.fieldName : Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(current == nil ? "今天不需要打卡" : (done ? "撤销今天的打卡" : "今天打卡"))
    }

    private func stat(_ value: String, _ title: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .heavy)).monospacedDigit().foregroundStyle(tint)
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.subtext)
        }
        .frame(minWidth: 52)
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("打卡记录")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: 0x4A453C))
            if habit.records.isEmpty {
                Text("还没有打卡记录").font(.system(size: 11.5)).foregroundStyle(Theme.subtext)
            }
            ForEach(habit.records.prefix(30)) { record in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.done)
                    Text(recordText(record)).font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedOccurrenceID = record.id
                    model.selectedFocusID = nil
                }
            }
            if habit.records.count > 30 {
                Text("仅显示最近 30 条").font(.system(size: 10.5)).foregroundStyle(Theme.fieldName)
            }
        }
        .padding(.top, 2)
    }

    private func recordText(_ record: OccurrenceItem) -> String {
        let day = record.occurrence.completedDate.map { OccurrenceListView.dayTitle($0, today: model.today) } ?? "日期未知"
        let clock = record.occurrence.completedAt.map { String($0.dropFirst(11).prefix(5)) } ?? ""
        return clock.isEmpty ? day : day + " " + clock
    }
}

/// 近 14 天的打卡格子，最右边是今天。
private struct HabitDayStrip: View {
    let days: Set<LocalDate>
    let today: LocalDate

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<14, id: \.self) { index in
                let day = today.adding(days: index - 13)
                let checked = days.contains(day)
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(checked ? Theme.done : Theme.line.opacity(0.7))
                        .frame(width: 16, height: 16)
                    Text(verbatim: "\(day.day)")
                        .font(.system(size: 9, weight: day == today ? .heavy : .regular))
                        .foregroundStyle(day == today ? Theme.accent : Theme.fieldName)
                }
                .help(day.shortTitle + (checked ? " · 已打卡" : " · 未打卡"))
            }
            Spacer(minLength: 0)
        }
    }
}
