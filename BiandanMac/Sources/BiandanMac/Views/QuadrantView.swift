import SwiftUI

/// 四象限视图，配色与截图一致。P3 只读，P4 起支持拖动改写 isImportant / isUrgency。
struct QuadrantView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = model.quadrantItems()
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
                QuadrantCell(quadrant: .importantUrgent, items: groups[.importantUrgent] ?? [])
                QuadrantCell(quadrant: .importantNotUrgent, items: groups[.importantNotUrgent] ?? [])
            }
            HStack(spacing: 12) {
                QuadrantCell(quadrant: .notImportantUrgent, items: groups[.notImportantUrgent] ?? [])
                QuadrantCell(quadrant: .neither, items: groups[.neither] ?? [])
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
    @State private var isTargeted = false

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
            }
            .padding(.top, 10)

            if items.isEmpty {
                Spacer()
                Text("暂无待办")
                    .font(.system(size: 12))
                    .foregroundStyle(quadrant.titleColor.opacity(0.45))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(items) { item in
                            OccurrenceCard(item: item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(quadrant.fill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(quadrant.tint, lineWidth: isTargeted ? 4 : 2))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 拖入卡片：改写该任务的重要 / 紧急。
        .dropDestination(for: String.self) { identifiers, _ in
            for identifier in identifiers {
                Task { await model.moveToQuadrant(occurrenceID: identifier, quadrant) }
            }
            return !identifiers.isEmpty
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
