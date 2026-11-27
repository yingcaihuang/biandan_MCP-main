import SwiftUI

/// 卡片上快捷操作弹出的面板。
enum CardQuickAction: Hashable {
    case reschedule, list, quadrant, pomodoro
}

private struct QuickDate: Identifiable {
    let id: String
    let day: LocalDate
}

/// 卡片右下角的快捷操作条：改期、移到分类、移到象限、番茄钟、收藏。
/// 鼠标移到卡片上或选中卡片时出现；面板沿用右键菜单的组件，行为与右键菜单一致。
struct CardQuickActions: View {
    @Environment(AppModel.self) private var model
    let item: OccurrenceItem
    @Binding var open: CardQuickAction?

    var body: some View {
        let task = item.task
        let pending = item.status == .pending
        let starIcon = task.collected ? "star.fill" : "star"
        let starHelp = task.collected ? "取消收藏" : "收藏"
        let focusing = model.pomodoro?.link?.occurrenceID == item.id
        let pomodoroHelp = focusing ? "查看番茄钟" : "开始番茄钟"
        HStack(spacing: 1) {
            if pending {
                QuickActionButton(icon: "calendar", help: "改期", active: open == .reschedule) { open = .reschedule }
                    .popover(isPresented: presented(.reschedule), arrowEdge: .bottom) { reschedulePanel }
            }
            QuickActionButton(icon: "folder", help: "移到分类", active: open == .list) { open = .list }
                .popover(isPresented: presented(.list), arrowEdge: .bottom) { listPanel }
            if pending {
                QuickActionButton(icon: "square.grid.2x2", help: "移到象限", active: open == .quadrant) { open = .quadrant }
                    .popover(isPresented: presented(.quadrant), arrowEdge: .bottom) { quadrantPanel }
            }
            if pending {
                QuickActionButton(icon: "timer", help: pomodoroHelp, active: open == .pomodoro || focusing) {
                    open = .pomodoro
                }
                .popover(isPresented: presented(.pomodoro), arrowEdge: .bottom) { pomodoroPanel }
            }
            QuickActionButton(icon: starIcon, help: starHelp, active: task.collected, activeTint: Theme.accent) {
                let id = task.id1
                let collected = !task.collected
                Task { await model.updateTask(id, collected: collected) }
            }
        }
        .padding(2)
        .floatingSurface(Capsule(), shadowRadius: 3, shadowOpacity: 0.1)
    }

    private func presented(_ action: CardQuickAction) -> Binding<Bool> {
        Binding(get: { open == action }, set: { shown in
            if !shown, open == action { open = nil }
        })
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        open = nil
        Task { @MainActor in await body() }
    }

    // MARK: 改期

    private var reschedulePanel: some View {
        let task = item.task
        let today = model.today
        let current: LocalDate? = task.undated ? nil : item.occurrence.startDate
        let all = [QuickDate(id: "今天", day: today),
                   QuickDate(id: "明天", day: today.adding(days: 1)),
                   QuickDate(id: "下周一", day: OccurrenceContextMenu.nextMonday(after: today))]
        let choices = all.filter { $0.day != current }
        let canClear = !task.isRepeating && !task.undated
        let target = item
        let taskID = task.id1
        let caption = task.isRepeating ? "改期（只改这一次）" : "改期"
        return VStack(alignment: .leading, spacing: 8) {
            ThemedMenuCaption(caption)
            HStack(spacing: 6) {
                ForEach(choices) { choice in
                    ThemedMenuChip(title: choice.id, tint: Theme.accent) {
                        run { await model.rescheduleKeepingSpan(target, to: choice.day) }
                    }
                }
                if canClear {
                    ThemedMenuChip(title: "无日期", tint: Theme.subtext) {
                        run { await model.clearSchedule(taskID) }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .popoverBackground(Theme.background)
    }

    // MARK: 分类

    private var listPanel: some View {
        let lists = model.snapshot.lists
        return VStack(alignment: .leading, spacing: 8) {
            ThemedMenuCaption("移到分类")
            ThemedMenuGroup {
                if lists.count > 6 {
                    ScrollView { listRows(lists) }
                        .frame(height: 210)
                } else {
                    listRows(lists)
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .popoverBackground(Theme.background)
    }

    private func listRows(_ lists: [TodoList]) -> some View {
        let taskID = item.task.id1
        let current = item.task.id3
        return VStack(spacing: 0) {
            ForEach(lists) { list in
                ThemedMenuListRow(color: list.swatch, title: list.displayName, selected: list.id3 == current) {
                    let target = list.id3
                    run { await model.moveTask(taskID, to: target) }
                }
            }
        }
    }

    // MARK: 象限

    private var quadrantPanel: some View {
        let id = item.id
        return VStack(alignment: .leading, spacing: 8) {
            ThemedMenuCaption("移到象限")
            QuadrantMiniGrid(current: item.task.quadrant) { quadrant in
                run { await model.moveToQuadrant(occurrenceID: id, quadrant) }
            }
        }
        .padding(12)
        .frame(width: 270, alignment: .leading)
        .popoverBackground(Theme.background)
    }

    // MARK: 番茄钟

    private var pomodoroPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedMenuCaption("番茄钟")
            if let session = model.pomodoro {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    runningPomodoro(session, now: context.date)
                }
            } else {
                pomodoroPresets
            }
        }
        .padding(12)
        .frame(width: 290, alignment: .leading)
        .popoverBackground(Theme.background)
    }

    /// 没在计时：点时长直接开始，关联这张卡片。
    private var pomodoroPresets: some View {
        let target = item
        let signedIn = model.authState == .signedIn
        let hint: String = signedIn ? "点时长直接开始，关联这个任务，到时自动补记专注" : "登录后才能开始番茄钟"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(PomodoroSession.presets, id: \.self) { minutes in
                    ThemedMenuChip(title: "\(minutes) 分", tint: Theme.accent) {
                        open = nil
                        model.pomodoroMinutes = minutes
                        model.startPomodoro(minutes: minutes, item: target)
                    }
                    .disabled(!signedIn)
                }
            }
            Text(verbatim: hint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        }
    }

    /// 正在计时：这张卡片的可以暂停 / 继续；别的任务在计时时只提示，不另开一个。
    private func runningPomodoro(_ session: PomodoroSession, now: Date) -> some View {
        let mine = session.link?.occurrenceID == item.id
        let paused = session.isPaused
        let icon: String = paused ? "pause.circle" : "timer"
        let status: String
        if mine {
            status = paused ? "已暂停" : "专注中"
        } else {
            status = "正在专注「\(session.title)」"
        }
        let toggleTitle: String = paused ? "继续" : "暂停"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PomodoroDial(session: session, now: now, size: 16, lineWidth: 2.5)
                Text(PomodoroSession.clock(session.remaining(at: now)))
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(PomodoroPalette.color(session, at: now))
                Text(verbatim: status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                if mine {
                    ThemedMenuChip(title: toggleTitle, tint: Theme.accent) {
                        if paused { model.resumePomodoro() } else { model.pausePomodoro() }
                    }
                }
                ThemedMenuChip(title: "打开番茄钟", tint: Theme.subtext) { showPomodoroPanel() }
            }
            if !mine {
                Text("一次只能计一个番茄钟，结束或放弃后再开始")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
        }
    }

    /// 先收起卡片上的弹窗，再打开工具栏的番茄钟面板，免得两个弹窗同时出现。
    private func showPomodoroPanel() {
        open = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            model.showPomodoro = true
        }
    }
}

private struct QuickActionButton: View {
    let icon: String
    let help: String
    var active = false
    var activeTint: Color = Theme.accent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let lit = active || hovering
        let color: Color = lit ? activeTint : Theme.subtext
        let fill: Color = hovering ? activeTint.opacity(0.14) : Color.clear
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 20)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
