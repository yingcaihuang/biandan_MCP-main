import SwiftUI

/// 四象限视图，配色与截图一致。P3 只读，P4 起支持拖动改写 isImportant / isUrgency。
struct QuadrantView: View {
    @Environment(AppModel.self) private var model
    /// 点象限空白处选中的象限（没有选中任务时高亮它）。
    @State private var focused: Quadrant?

    /// 要高亮的象限：有选中任务时是它们所在的象限，否则是点过的那个象限。
    private func highlighted(_ groups: [Quadrant: [OccurrenceItem]]) -> Set<Quadrant> {
        var ids = model.multiSelection
        if let id = model.selectedOccurrenceID { ids.insert(id) }
        let lit = Quadrant.allCases.filter { quadrant in
            (groups[quadrant] ?? []).contains { ids.contains($0.id) }
        }
        if !lit.isEmpty { return Set(lit) }
        return focused.map { [$0] } ?? []
    }

    private func cell(_ quadrant: Quadrant, _ groups: [Quadrant: [OccurrenceItem]], _ lit: Set<Quadrant>) -> some View {
        QuadrantCell(quadrant: quadrant, items: groups[quadrant] ?? [], highlighted: lit.contains(quadrant)) {
            focused = quadrant
            model.multiSelection = []
            model.selectedOccurrenceID = nil
        }
    }

    var body: some View {
        let groups = model.quadrantItems()
        let lit = highlighted(groups)
        let hidden = model.quadrantHiddenCount
        VStack(spacing: 12) {
            if hidden > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(verbatim: "\(model.quadrantRange.title)范围外还有 \(hidden) 条待办")
                    Button("显示全部") { model.quadrantRange = .all }
                        .buttonStyle(.link)
                    Spacer()
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
            HStack(spacing: 12) {
                cell(.importantUrgent, groups, lit)
                cell(.importantNotUrgent, groups, lit)
            }
            HStack(spacing: 12) {
                cell(.notImportantUrgent, groups, lit)
                cell(.neither, groups, lit)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }
}

struct QuadrantCell: View {
    @Environment(AppModel.self) private var model
    let quadrant: Quadrant
    let items: [OccurrenceItem]
    /// 选中的任务在这个象限里，或点选了这个象限。
    var highlighted = false
    var onFocus: () -> Void = {}
    @State private var isTargeted = false
    @State private var hovering = false

    private var borderWidth: CGFloat {
        if isTargeted { return 4 }
        if highlighted { return 3 }
        return hovering ? 2.5 : 2
    }

    private var glow: Color { highlighted ? quadrant.tint.opacity(0.38) : Color.clear }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(quadrant.title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(quadrant.titleColor)
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(quadrant.titleColor.opacity(0.8))
                }
                if highlighted {
                    CurrentQuadrantTag(tint: quadrant.tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.top, 10)

            if items.isEmpty {
                Spacer()
                Text("暂无待办")
                    .font(.system(size: 12))
                    .foregroundStyle(quadrant.titleColor.opacity(0.45))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(items) { item in
                                OccurrenceCard(item: item)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                    // 键盘移动或从冲突浮层跳转时，滚动到这一项。
                    .onChange(of: model.keyboardScrollTarget) { _, target in
                        guard let target, items.contains(where: { $0.id == target }) else { return }
                        withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(quadrant.fill)
            .shadow(color: glow, radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(quadrant.tint, lineWidth: borderWidth))
        .animation(.easeOut(duration: 0.18), value: highlighted)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        // 点空白处选中这个象限；点卡片时卡片自己处理。
        .onTapGesture { onFocus() }
        // 拖入卡片：改写该任务的重要 / 紧急。
        .dropDestination(for: String.self) { identifiers, _ in
            guard !identifiers.isEmpty else { return false }
            let target = quadrant
            Task { await model.dropOnQuadrant(identifiers, target) }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .themedContextMenu { close in
            ThemedMenuPanel(title: quadrant.title, subtitle: "\(items.count) 条待办", tint: quadrant.tint) {
                ThemedMenuGroup {
                    ThemedMenuRow(icon: "plus", title: "在这里新建任务", detail: "自动设为「\(quadrant.title)」",
                                  tint: quadrant.tint, shortcut: "⌘N") {
                        close()
                        afterMenuCloses {
                            model.newTaskPreset = NewTaskPreset(important: quadrant.isImportant, urgent: quadrant.isUrgent,
                                                                date: model.today)
                        }
                    }
                }
            }
            .environment(model)
        }
    }
}

/// 象限标题旁的「当前象限」标签。
private struct CurrentQuadrantTag: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("当前象限").font(.system(size: 10.5, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
    }
}
