import SwiftUI

private struct BatchDateChoice: Identifiable {
    let id: String
    let day: LocalDate
}

/// 多选后浮在内容区底部的批量操作栏。整批操作合并成一步，⌘Z 一次撤回。
struct BatchActionBar: View {
    @Environment(AppModel.self) private var model
    @State private var showReschedule = false
    @State private var showMove = false

    private func run(_ action: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await action() }
    }

    var body: some View {
        let items = model.batchItems
        let pending = items.filter { $0.status == .pending }.count
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "已选 \(items.count) 项")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: pending < items.count ? "其中 \(pending) 项待完成" : "⌘ 点击可增减")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 8)
            Group {
                Button { run { await model.batchComplete() } } label: { Label("完成", systemImage: "checkmark") }
                    .disabled(pending == 0)
                Button { run { await model.batchAbandon() } } label: { Label("放弃", systemImage: "slash.circle") }
                    .disabled(pending == 0)
                Button { showReschedule.toggle() } label: { Label("改期", systemImage: "calendar") }
                    .disabled(pending == 0)
                    .popover(isPresented: $showReschedule, arrowEdge: .top) { reschedulePanel }
                Button { showMove.toggle() } label: { Label("移动", systemImage: "folder") }
                    .popover(isPresented: $showMove, arrowEdge: .top) { movePanel }
                Button("全选") { model.selectAllVisible() }
                    .help("选中当前视图里的全部任务")
            }
            .buttonStyle(.themed)
            Button(role: .destructive) {
                model.batchDeleteRequested = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .buttonStyle(.themedDestructive)
            .disabled(items.isEmpty)
            Button { model.clearMultiSelection() } label: { Image(systemName: "xmark") }
                .buttonStyle(.themed)
                .help("取消选择（Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.accent.opacity(0.6)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }

    private var reschedulePanel: some View {
        let today = model.today
        let choices = [BatchDateChoice(id: "今天", day: today),
                       BatchDateChoice(id: "明天", day: today.adding(days: 1)),
                       BatchDateChoice(id: "下周一", day: OccurrenceContextMenu.nextMonday(after: today))]
        return ThemedMenuPanel(title: "批量改期", subtitle: "只改待完成的任务；重复任务只改这一次") {
            HStack(spacing: 6) {
                ForEach(choices) { choice in
                    ThemedMenuChip(title: choice.id, tint: Theme.accent) {
                        showReschedule = false
                        let day = choice.day
                        run { await model.batchReschedule(to: day) }
                    }
                }
            }
        }
    }

    private var movePanel: some View {
        let lists = model.snapshot.lists
        return ThemedMenuPanel(title: "批量移动", subtitle: "按任务移动，同一任务只改一次") {
            ThemedMenuCaption("移到象限")
            QuadrantMiniGrid(current: nil) { quadrant in
                showMove = false
                run { await model.batchMoveToQuadrant(quadrant) }
            }
            ThemedMenuCaption("移到分类")
            ThemedMenuGroup {
                if lists.count > 5 {
                    ScrollView { listRows(lists) }
                        .frame(height: 170)
                } else {
                    listRows(lists)
                }
            }
        }
    }

    private func listRows(_ lists: [TodoList]) -> some View {
        VStack(spacing: 0) {
            ForEach(lists) { list in
                ThemedMenuListRow(color: list.swatch, title: list.displayName, selected: false) {
                    showMove = false
                    let listID = list.id3
                    run { await model.batchMove(to: listID) }
                }
            }
        }
    }
}

/// 批量删除确认：写明数量和范围，删除不可撤销。
struct BatchDeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        let items = model.batchItems
        let repeating = items.filter { $0.task.isRepeating }.count
        ThemedSheet("删除 \(items.count) 项任务", tag: ThemeTag(text: "无法撤销", color: Theme.overdue)) {
            InspectorSection("影响范围") {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.subtext)
                    Text(verbatim: Self.summary(total: items.count, repeating: repeating))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0x4A453C))
                .padding(10)
            }
            Text("删除会同步到云端和其他设备，不能用 ⌘Z 撤销。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.overdue)
            ThemedErrorText(message: model.operationError)
        } footer: {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("删除 \(items.count) 项", role: .destructive) { confirm() }
                .buttonStyle(.themedDestructive)
                .keyboardShortcut(.defaultAction)
                .disabled(working || items.isEmpty)
        }
        .frame(width: 440, height: 300)
        .onAppear { model.operationError = nil }
    }

    static func summary(total: Int, repeating: Int) -> String {
        if repeating == 0 { return "将删除选中的 \(total) 项任务，连同任务定义。" }
        if repeating == total { return "\(total) 项都是重复任务，只删除这一次，后续实例保留。" }
        return "将删除选中的 \(total) 项：其中 \(repeating) 项是重复任务，只删除这一次；"
            + "其余 \(total - repeating) 项连同任务定义一起删除。"
    }

    private func confirm() {
        working = true
        Task {
            let ok = await model.batchDelete()
            working = false
            if ok { dismiss() }
        }
    }
}
