import SwiftUI

/// 卡片上快捷操作弹出的面板。
enum CardQuickAction: Hashable {
    case reschedule, list, quadrant
}

private struct QuickDate: Identifiable {
    let id: String
    let day: LocalDate
}

/// 卡片右下角的快捷操作条：改期、移到分类、移到象限、收藏。
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
            QuickActionButton(icon: starIcon, help: starHelp, active: task.collected, activeTint: Theme.accent) {
                let id = task.id1
                let collected = !task.collected
                Task { await model.updateTask(id, collected: collected) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
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
        .background(Theme.background)
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
        .background(Theme.background)
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
        .background(Theme.background)
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
