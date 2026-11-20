import SwiftUI

// MARK: - 补记 / 编辑专注（遵循 ThemeKit 主题规范）

struct FocusEditorRequest: Identifiable {
    let id = UUID()
    /// nil 表示补记。
    var record: FocusRecord? = nil
    var link: FocusLink? = nil
}

struct FocusEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: FocusEditorRequest

    @State private var startedAt: Date
    @State private var minutes: Int
    @State private var title: String
    @State private var good: Int
    @State private var bad: Int
    @State private var saving = false

    init(request: FocusEditorRequest) {
        self.request = request
        let record = request.record
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .minute, value: -25, to: Date()) ?? Date()
        let rounded = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: base)) ?? base
        _startedAt = State(initialValue: record?.startedAt ?? rounded)
        _minutes = State(initialValue: record.map { max(1, Int($0.minutes.rounded(.down))) } ?? 25)
        _title = State(initialValue: record?.parsedLog.eventTitle ?? request.link?.title ?? "")
        _good = State(initialValue: record?.goodCount ?? 1)
        _bad = State(initialValue: record?.badCount ?? 0)
    }

    private var isNew: Bool { request.record == nil }
    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var endsInFuture: Bool {
        isNew && startedAt.addingTimeInterval(Double(minutes) * 60) > Date().addingTimeInterval(60)
    }
    private var minutesValid: Bool { (1...1440).contains(minutes) }

    var body: some View {
        ThemedSheet(isNew ? "补记专注" : "编辑专注记录",
                    subtitle: isNew ? "记录一段已经完成的专注，会同步到你的便单账号" : "可以修改标题和好坏番茄数",
                    tag: ThemeTag(text: "\(minutes) 分钟", color: Theme.accent)) {
            InspectorSection("时间 · time / minutes") {
                if isNew {
                    newTimeRows
                } else {
                    ThemedRow("开始") { valueText(request.record.map(FocusText.summary) ?? "—") }
                }
            }
            if let link = request.link {
                InspectorSection("关联任务 · log.eventId") {
                    ThemedRow("任务") { valueText(link.title) }
                }
            }
            InspectorSection("标题 · log.eventTitle") {
                TextField("", text: $title, prompt: Text("专注的事项，可留空"))
                    .themedField()
                    .padding(10)
            }
            InspectorSection("番茄 · goodCount / badCount") {
                ThemedRow("好番茄") { counter($good) }
                ThemedRow("坏番茄") { counter($bad) }
            }
            if endsInFuture {
                Text("结束时间在未来。补记只能记录已经完成的专注。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.overdue)
            }
            ThemedErrorText(message: model.operationError)
        } footer: {
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "补记" : "保存") { save() }
                .buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || endsInFuture || !minutesValid)
        }
        .frame(width: 460, height: isNew ? 560 : 440)
        .onAppear { model.operationError = nil }
    }

    @ViewBuilder private var newTimeRows: some View {
        ThemedRow("开始日期") { ThemedDateField(date: $startedAt) }
        ThemedRow("开始时刻") { ThemedTimeField(time: $startedAt) }
        ThemedRow("时长（分钟）") {
            HStack(spacing: 6) {
                TextField("", value: $minutes, format: .number)
                    .themedField()
                    .frame(width: 64)
                Stepper("", value: $minutes, in: 1...1440, step: 5)
                    .labelsHidden()
            }
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }

    private func counter(_ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...99) {
            Text(verbatim: "\(value.wrappedValue)")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
    }

    private func save() {
        saving = true
        Task {
            let ok: Bool
            if let record = request.record {
                let titleChange: String? = trimmed == record.parsedLog.eventTitle ? nil : trimmed
                let goodChange: Int? = good == record.goodCount ? nil : good
                let badChange: Int? = bad == record.badCount ? nil : bad
                if titleChange == nil && goodChange == nil && badChange == nil {
                    ok = true
                } else {
                    ok = await model.updateFocus(record.time, title: titleChange, goodCount: goodChange, badCount: badChange)
                }
            } else {
                let input = FocusInput(startedAt: startedAt, minutes: Double(minutes), title: trimmed,
                                       goodCount: good, badCount: bad, link: request.link)
                ok = await model.createFocus(input)
            }
            saving = false
            if ok { dismiss() }
        }
    }
}

// MARK: - 删除专注记录

struct FocusDeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: FocusRecord
    @State private var working = false

    var body: some View {
        let title = record.parsedLog.eventTitle
        ThemedSheet("删除专注记录", subtitle: title.isEmpty ? "未命名专注" : title,
                    tag: ThemeTag(text: "无法撤销", color: Theme.overdue)) {
            InspectorSection("记录") {
                Text(verbatim: FocusText.summary(record))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0x4A453C))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            Text("删除会同步到云端和其他设备，按日统计也会相应减少。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.overdue)
            ThemedErrorText(message: model.operationError)
        } footer: {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("删除", role: .destructive) { remove() }
                .buttonStyle(.themedDestructive)
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        }
        .frame(width: 420, height: 320)
        .onAppear { model.operationError = nil }
    }

    private func remove() {
        working = true
        Task {
            let ok = await model.deleteFocus(record.time)
            working = false
            if ok { dismiss() }
        }
    }
}
