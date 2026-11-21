import SwiftUI

// MARK: - 导入预览：逐条勾选，选择分类，确认后写入

struct ImportPreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ImportPreview
    @State private var useNewList: Bool
    @State private var chosenList: String

    init(preview: ImportPreview) {
        _preview = State(initialValue: preview)
        _useNewList = State(initialValue: preview.listID == nil)
        _chosenList = State(initialValue: preview.listID ?? TodoList.defaultID)
    }

    var body: some View {
        let plan = preview.plan
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                settings
                summary(plan)
                eventList(plan)
            }
            .padding(16)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer(plan)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.panel)
        }
        .frame(width: 600, height: 640)
        .background(Theme.background)
        .tint(Theme.accent)
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFA8B36))
            VStack(alignment: .leading, spacing: 1) {
                Text("导入日程").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
                Text(verbatim: preview.address).font(.system(size: 11)).foregroundStyle(Theme.subtext).lineLimit(1)
            }
            if preview.existing != nil { ImportTag(text: "再次导入", color: Theme.accent) }
            Spacer(minLength: 6)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.subtext)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    // MARK: 来源名称与分类

    private var settings: some View {
        InspectorSection("导入设置") {
            SettingRow("来源名称", caption: "显示在已导入的日历里，也写进每条任务的备注") {
                TextField("", text: $preview.sourceName, prompt: Text("例如：飞书日历"))
                    .themedField()
                    .frame(width: 220)
            }
            SettingRow("放到分类", caption: useNewList ? "按来源名称新建一个分类（已有同名分类时直接用它）" : "放进已有的分类") {
                HStack(spacing: 8) {
                    ThemedSegmented(selection: $useNewList,
                                    options: [ThemeOption(value: true, title: "新建分类"),
                                              ThemeOption(value: false, title: "已有分类")])
                    if !useNewList { ThemedListPicker(selection: $chosenList) }
                }
            }
        }
    }

    // MARK: 统计

    private func summary(_ plan: ImportPlan) -> some View {
        let selected = preview.events.filter(\.include).count
        let allOn = selected == preview.events.count
        return HStack(spacing: 8) {
            ImportTag(text: "新增 \(plan.added.count)", color: Theme.done)
            if !plan.restored.isEmpty { ImportTag(text: "重建 \(plan.restored.count)", color: Theme.done) }
            if !plan.updated.isEmpty { ImportTag(text: "更新 \(plan.updated.count)", color: Quadrant.notImportantUrgent.tint) }
            if !plan.unchanged.isEmpty { ImportTag(text: "不变 \(plan.unchanged.count)", color: Theme.subtext) }
            if !plan.removed.isEmpty { ImportTag(text: "已取消 \(plan.removed.count)", color: Theme.overdue) }
            if preview.skipped > 0 {
                Text(verbatim: "另有 \(preview.skipped) 条不在导入范围内，已跳过")
                    .font(.system(size: 11)).foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 0)
            Button(allOn ? "全不选" : "全选") {
                for index in preview.events.indices { preview.events[index].include = !allOn }
            }
            .buttonStyle(.themed)
        }
    }

    // MARK: 日程列表

    private func eventList(_ plan: ImportPlan) -> some View {
        let added = Set((plan.added + plan.restored).map(\.key))
        let updated = Set(plan.updated.map(\.key))
        let removed = Set(plan.removed.map(\.key))
        let shape = RoundedRectangle(cornerRadius: 10)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($preview.events) { $event in
                    ImportEventRow(event: $event, state: rowState(event, added: added, updated: updated, removed: removed))
                }
            }
        }
        .background(shape.fill(Theme.card))
        .clipShape(shape)
        .overlay(shape.stroke(Theme.line))
    }

    private func rowState(_ event: ImportedEvent, added: Set<String>, updated: Set<String>,
                          removed: Set<String>) -> ImportEventRow.State {
        if !event.include { return .skipped }
        if removed.contains(event.key) { return .cancelled }
        if event.cancelled { return .ignoredCancel }
        if added.contains(event.key) { return .new }
        if updated.contains(event.key) { return .updated }
        return .unchanged
    }

    // MARK: 底栏

    private func footer(_ plan: ImportPlan) -> some View {
        let work = plan.added.count + plan.restored.count + plan.updated.count + plan.removed.count
        let signedIn = model.authState == .signedIn
        return HStack(spacing: 10) {
            if !signedIn {
                Text("请先在便单主窗口登录").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
            Spacer(minLength: 6)
            if model.importBusy {
                ProgressView().controlSize(.small)
                Text("正在导入…").font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            Button("取消") { dismiss() }.buttonStyle(.themed)
            Button {
                var final = preview
                final.listID = useNewList ? nil : chosenList
                Task { await model.runImport(final) }
            } label: {
                Text(verbatim: work == 0 ? "没有需要导入的" : "导入（\(work)）")
            }
            .buttonStyle(.themedPrimary)
            .disabled(work == 0 || model.importBusy || !signedIn)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ImportEventRow: View {
    enum State {
        case new, updated, unchanged, cancelled, ignoredCancel, skipped
    }

    @Binding var event: ImportedEvent
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { event.include.toggle() } label: {
                Image(systemName: event.include ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(event.include ? Theme.accent : Color(hex: 0xB9B09C))
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: event.title.isEmpty ? "（无标题）" : event.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .strikethrough(event.cancelled)
                        .lineLimit(1)
                    badge
                }
                Text(verbatim: event.scheduleText)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.subtext)
                if let repeatText = event.repeatText {
                    Label(repeatText, systemImage: "repeat").font(.system(size: 11)).foregroundStyle(Theme.subtext)
                }
                if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin").font(.system(size: 11)).foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(event.include ? 1 : 0.5)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1) }
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .new: ImportTag(text: "新增", color: Theme.done)
        case .updated: ImportTag(text: "有更新", color: Quadrant.notImportantUrgent.tint)
        case .unchanged: ImportTag(text: "已导入", color: Theme.subtext)
        case .cancelled: ImportTag(text: "已取消 · 标记放弃", color: Theme.overdue)
        case .ignoredCancel: ImportTag(text: "已取消 · 不导入", color: Theme.subtext)
        case .skipped: EmptyView()
        }
    }
}
