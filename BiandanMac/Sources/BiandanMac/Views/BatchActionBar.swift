import SwiftUI

/// 标题栏的「选择 / 完成」按钮：进入或退出选择模式。
struct SelectionModeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.selectionMode
        let title = on ? "完成" : "选择"
        let icon = on ? "checkmark.circle.fill" : "checklist"
        let help = on ? "退出选择（Esc）" : "批量选择任务：点击勾选，⇧ 点击连选，⌘A 全选"
        Button {
            if on { model.exitSelectionMode() } else { model.enterSelectionMode() }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.themed)
        .help(help)
    }
}

/// 选择模式下卡片左侧的勾选框。
struct SelectionCheckbox: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        let icon = on ? "checkmark.square.fill" : "square"
        let color: Color = on ? Theme.accent : Color(hex: 0xB9B09C)
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "取消勾选" : "勾选")
    }
}

// MARK: - 批量栏按钮：统一 28 高、12.5 号字、不折行

/// 批量栏里的一个按钮。compact 时只显示图标（悬停显示文字）；standalone 带自己的底和描边；filled 为实心（删除）。
private struct BatchButton: View {
    let title: String
    let icon: String
    var tint: Color = Theme.accent
    var compact = false
    var standalone = false
    var filled = false
    var help: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help ?? title)
    }

    private var label: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            if !compact {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(textColor)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: 28)
        .background(shape.fill(fillColor))
        .overlay(shape.stroke(strokeColor))
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var iconColor: Color { filled ? .white : tint }

    private var textColor: Color { filled ? .white : Theme.text }

    private var fillColor: Color {
        if filled { return hovering && isEnabled ? tint.opacity(0.85) : tint }
        if hovering && isEnabled { return tint.opacity(0.12) }
        return standalone ? Theme.card : Color.clear
    }

    private var strokeColor: Color { standalone ? Theme.line : Color.clear }
}

/// 一组相关按钮放在同一个分段框里。
private struct BatchButtonGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 2) { content }
            .padding(2)
            .background(shape.fill(Theme.card))
            .overlay(shape.stroke(Theme.line))
    }
}

private struct BatchGroupDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 16)
    }
}

private struct BatchDateChoice: Identifiable {
    let id: String
    let day: LocalDate
}

/// 多选后浮在内容区底部的批量操作栏。整批操作合并成一步，⌘Z 一次撤回。
struct BatchActionBar: View {
    @Environment(AppModel.self) private var model
    @State private var showReschedule = false
    @State private var showMove = false

    /// 左侧一行短提示，避免折行。
    private func hint(count: Int, pending: Int) -> String {
        if count == 0 { return "点击任务勾选，⇧ 连选" }
        if pending == 0 { return "均已完成或放弃" }
        if pending < count { return "\(pending) 待完成 · \(count - pending) 已完成" }
        return model.selectionMode ? "点击任务可增减" : "⌘ 点击可增减"
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        Task { @MainActor in await action() }
    }

    var body: some View {
        let items = model.batchItems
        let pending = items.filter { $0.status == .pending }.count
        HStack(spacing: 12) {
            summary(count: items.count, pending: pending)
            Spacer(minLength: 8)
            // 放得下时图标 + 文字，放不下时只显示图标（悬停看文字），不让文字折行变形。
            ViewThatFits(in: .horizontal) {
                actions(count: items.count, pending: pending, compact: false)
                actions(count: items.count, pending: pending, compact: true)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 920)
        .floatingSurface(RoundedRectangle(cornerRadius: 12, style: .continuous),
                         border: Theme.accent.opacity(0.6), glassBorder: true)
        .padding(.horizontal, 16)
    }

    private func summary(count: Int, pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "已选 \(count) 项")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(verbatim: hint(count: count, pending: pending))
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func actions(count: Int, pending: Int, compact: Bool) -> some View {
        let reopenable = count - pending
        let allSelected = model.allVisibleSelected
        let selectTitle = allSelected ? "全不选" : "全选"
        let selectIcon = allSelected ? "minus.square" : "checkmark.square"
        let busy = model.batchProgress != nil
        return HStack(spacing: 8) {
            BatchButtonGroup {
                BatchButton(title: "完成", icon: "checkmark", tint: Theme.done, compact: compact) {
                    run { await model.batchComplete() }
                }
                .disabled(pending == 0 || busy)
                BatchGroupDivider()
                BatchButton(title: "标记未完成", icon: "arrow.uturn.backward", tint: Theme.accent, compact: compact,
                            help: "已完成的撤销完成、已放弃的恢复，都改回待完成（⌘Z 可整批撤回）") {
                    run { await model.batchReopen() }
                }
                .disabled(reopenable == 0 || busy)
                BatchGroupDivider()
                BatchButton(title: "放弃", icon: "slash.circle", tint: Theme.subtext, compact: compact) {
                    run { await model.batchAbandon() }
                }
                .disabled(pending == 0 || busy)
            }
            BatchButtonGroup {
                BatchButton(title: "改期", icon: "calendar", tint: Quadrant.importantUrgent.tint, compact: compact) {
                    showReschedule.toggle()
                }
                .disabled(pending == 0 || busy)
                .popover(isPresented: $showReschedule, arrowEdge: .top) { reschedulePanel }
                BatchGroupDivider()
                BatchButton(title: "移动", icon: "folder", tint: Quadrant.notImportantUrgent.tint, compact: compact) {
                    showMove.toggle()
                }
                .disabled(count == 0 || busy)
                .popover(isPresented: $showMove, arrowEdge: .top) { movePanel }
            }
            BatchButton(title: selectTitle, icon: selectIcon, tint: Theme.accent, compact: compact, standalone: true,
                        help: "选中或取消当前视图里的全部任务（⌘A 全选）") {
                model.toggleSelectAllVisible()
            }
            BatchButton(title: "删除", icon: "trash", tint: Theme.overdue, compact: compact, filled: true) {
                model.batchDeleteRequested = true
            }
            .disabled(count == 0 || busy)
            BatchButton(title: "退出选择", icon: "xmark", tint: Theme.subtext, compact: true, standalone: true,
                        help: "退出选择（Esc）") {
                model.exitSelectionMode()
            }
        }
        .fixedSize()
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
            Text("点「删除」后窗口马上关掉，在后台逐项删除，底部显示进度；数量多时做完会发通知。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtext)
            ThemedErrorText(message: model.operationError)
        } footer: {
            if let running = model.batchProgress {
                Text(verbatim: "上一批「\(running.label)」还在进行（\(running.done)/\(running.total)）")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("删除 \(items.count) 项", role: .destructive) { confirm() }
                .buttonStyle(.themedDestructive)
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty || model.batchProgress != nil)
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

    /// 先关掉确认框，删除在后台进行。
    private func confirm() {
        let targets = model.batchItems
        dismiss()
        Task { await model.batchDelete(targets) }
    }
}

/// 批量操作在后台进行时，浮在内容区底部的进度条。
struct BatchProgressBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let progress = model.batchProgress {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(verbatim: "正在\(progress.label) \(progress.done)/\(progress.total)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                if progress.failed > 0 {
                    Text(verbatim: "\(progress.failed) 项没成功")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.overdue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .floatingSurface(shape, border: Theme.accent.opacity(0.4), glassBorder: true)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
