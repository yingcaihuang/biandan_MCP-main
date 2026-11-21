import AppKit
import SwiftUI

// MARK: - 确认卡片界面（与「新建任务」同一套主题）：每条可改标题、日期、时刻、四象限，可取消勾选，
// 显示时间冲突；点「添加选中」才写入。

private struct PreviewSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct SchedulePreviewView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: SchedulePreviewState
    let onClose: () -> Void
    let onResize: (CGSize) -> Void
    @State private var showText = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                messages
                if !state.candidates.isEmpty { candidateList }
                if !state.recognizedText.isEmpty { recognizedText }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !state.loading {
                Rectangle().fill(Theme.line).frame(height: 1)
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.panel)
            }
        }
        .frame(width: 520)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
        .tint(Theme.accent)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PreviewSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PreviewSizeKey.self) { size in onResize(size) }
    }

    // MARK: 标题栏

    private var headline: String {
        if state.loading { return "正在识别…" }
        if state.candidates.isEmpty { return state.error == nil ? "没有识别到日程" : "没能识别" }
        return "识别到 \(state.candidates.count) 条日程"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(verbatim: headline)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let source = state.source {
                SourceTag(source: source)
            }
            Spacer(minLength: 6)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.subtext)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Theme.panel)
    }

    // MARK: 提示

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在识别文字并提取日程，都在本机处理…").foregroundStyle(Theme.subtext)
                }
            }
            if let result = state.result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.done)
            }
            if let error = state.error {
                Text(verbatim: error)
                    .foregroundStyle(Theme.overdue)
                    .fixedSize(horizontal: false, vertical: true)
                if state.needsScreenPermission {
                    Button("打开「屏幕录制」设置") { NSWorkspace.shared.open(ScheduleCaptureFlow.screenRecordingSettings) }
                        .buttonStyle(.themed)
                }
            }
            if let note = state.note {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.loading && state.error == nil && state.candidates.isEmpty && !state.recognizedText.isEmpty {
                Text("可以核对下面识别到的文字，或换一块区域再试。").foregroundStyle(Theme.subtext)
            }
        }
        .font(.system(size: 12))
    }

    // MARK: 候选列表

    @ViewBuilder
    private var candidateList: some View {
        let rows = VStack(spacing: 10) {
            ForEach($state.candidates) { $candidate in
                ScheduleCandidateRow(candidate: $candidate, today: model.today, conflict: conflictText(candidate))
            }
        }
        if state.candidates.count > 2 {
            ScrollView { rows }.frame(height: 430)
        } else {
            rows
        }
    }

    // MARK: 识别到的文字（默认收起；没识别出日程时自动展开）

    private var lineCount: Int { state.recognizedText.split(separator: "\n").count }

    private var recognizedText: some View {
        let expanded = showText || (state.candidates.isEmpty && !state.loading)
        let chevron = expanded ? "chevron.down" : "chevron.right"
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showText.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: chevron).font(.system(size: 9, weight: .bold))
                    Text("识别到的文字")
                    Text(verbatim: "\(lineCount) 行").fontWeight(.regular)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.subtext)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { textBox }
        }
    }

    @ViewBuilder
    private var textBox: some View {
        let text = Text(verbatim: state.recognizedText)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.subtext)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if lineCount > 8 {
            ScrollView { text }
                .frame(height: 150)
                .background(shape.fill(Theme.card))
                .overlay(shape.stroke(Theme.line))
        } else {
            text
                .background(shape.fill(Theme.card))
                .overlay(shape.stroke(Theme.line))
        }
    }

    // MARK: 底栏

    private var footer: some View {
        let chosen = state.candidates.filter(\.include)
        let signedIn = model.authState == .signedIn
        let disabled = chosen.isEmpty || state.saving || !signedIn
        return HStack(spacing: 10) {
            if !state.candidates.isEmpty {
                Text("分类")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0x4A453C))
                ThemedListPicker(selection: $state.listID)
            }
            Spacer(minLength: 6)
            if !signedIn {
                Text("请先在便单主窗口登录").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
            if state.saving { ProgressView().controlSize(.small) }
            Button("取消", action: onClose).buttonStyle(.themed)
            if !state.candidates.isEmpty {
                Button { add() } label: { Text(verbatim: "添加选中（\(chosen.count)）") }
                    .buttonStyle(.themedPrimary)
                    .disabled(disabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func conflictText(_ candidate: ScheduleCandidate) -> String? {
        guard let input = candidate.input(listID: state.listID) else { return nil }
        let found = model.conflicts(for: input)
        guard let first = found.first else { return nil }
        let name = ScheduleConflicts.shortTitle(first.item)
        return found.count == 1 ? "⚠︎ 与「\(name)」时间冲突" : "⚠︎ 与「\(name)」等 \(found.count) 项时间冲突"
    }

    /// 逐条新建；成功的从列表里移掉，失败的留下可以重试。全部成功后稍等片刻自动关闭。
    private func add() {
        let listID = state.listID
        let chosen = state.candidates.filter(\.include)
        state.saving = true
        state.result = nil
        state.error = nil
        Task { @MainActor in
            var added: [UUID] = []
            for candidate in chosen {
                guard let input = candidate.input(listID: listID) else { continue }
                if await model.createTask(input) { added.append(candidate.id) }
            }
            state.candidates.removeAll { added.contains($0.id) }
            state.saving = false
            let failed = chosen.count - added.count
            if failed == 0 {
                state.result = "已添加 \(added.count) 条日程"
                try? await Task.sleep(for: .milliseconds(1200))
                if state.candidates.isEmpty { onClose() }
            } else {
                state.result = added.isEmpty ? nil : "已添加 \(added.count) 条"
                state.error = "有 \(failed) 条没能添加，可以检查后重试"
            }
        }
    }
}

/// 标题栏上的「端侧模型 / 规则识别」标签，样式同新建任务标题旁的象限标签。
private struct SourceTag: View {
    let source: ScheduleExtractionSource

    var body: some View {
        let fill: Color = source == .model ? Theme.accent : Color(hex: 0xA79F8E)
        Text(verbatim: source.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .help(source == .model ? "用系统端侧模型提取"
                                   : "端侧模型暂不可用，按规则从句子里找日期和时刻；识别结果可以逐条修改")
    }
}

// MARK: - 一条候选日程

/// 勾选 + 标题 + 象限，下面是日期、时刻（主题选择器），再下面是提示、冲突、地点和原文。左侧色条是象限颜色。
struct ScheduleCandidateRow: View {
    @Binding var candidate: ScheduleCandidate
    let today: LocalDate
    let conflict: String?
    @State private var pickQuadrant = false

    private static let defaultStart = LocalTime(hour: 9, minute: 0)!

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let border: Color = conflict == nil ? Theme.line : Theme.overdue.opacity(0.6)
        let opacity: Double = candidate.include ? 1 : 0.55
        let tint = candidate.quadrant.tint
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            ThemedRow("日期") { dateControls }
            if candidate.date != nil {
                ThemedRow("时刻") { timeControls }
            }
            details
        }
        .padding(.leading, 4)
        .background(shape.fill(Theme.card))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 4)
        }
        .clipShape(shape)
        .overlay(shape.stroke(border))
        .opacity(opacity)
        .animation(.easeOut(duration: 0.15), value: candidate.quadrant)
    }

    // MARK: 第一行

    private var titleRow: some View {
        HStack(spacing: 8) {
            checkbox
            TextField("", text: $candidate.title, prompt: Text("要做什么？"))
                .themedField()
            quadrantChip
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var checkbox: some View {
        let on = candidate.include
        let icon = on ? "checkmark.circle.fill" : "circle"
        let color: Color = on ? Theme.accent : Color(hex: 0xB9B09C)
        return Button {
            candidate.include.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "不添加这一条" : "添加这一条")
    }

    private var quadrantChip: some View {
        let quadrant = candidate.quadrant
        return Button {
            pickQuadrant = true
        } label: {
            HStack(spacing: 4) {
                Circle().fill(quadrant.tint).frame(width: 6, height: 6)
                Text(quadrant.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(quadrant.titleColor)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.subtext)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(quadrant.fill))
            .overlay(Capsule().stroke(quadrant.tint.opacity(0.6)))
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("选择四象限")
        .popover(isPresented: $pickQuadrant, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ThemedMenuCaption("四象限")
                QuadrantMiniGrid(current: quadrant) { picked in
                    candidate.quadrant = picked
                    pickQuadrant = false
                }
            }
            .padding(12)
            .frame(width: 270, alignment: .leading)
            .popoverBackground(Theme.panel)
        }
    }

    // MARK: 日期 / 时刻

    @ViewBuilder
    private var dateControls: some View {
        HStack(spacing: 8) {
            if candidate.date != nil {
                ThemedDateField(date: dateBinding, tint: candidate.quadrant.tint)
            } else {
                Text("无日期").font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            ThemedSwitch(isOn: hasDateBinding)
        }
    }

    @ViewBuilder
    private var timeControls: some View {
        HStack(spacing: 6) {
            if candidate.start != nil {
                ThemedTimeField(time: startBinding, tint: candidate.quadrant.tint)
                Text("–").foregroundStyle(Theme.subtext)
                ThemedTimeField(time: endBinding, tint: candidate.quadrant.tint)
            } else {
                Text("不指定时刻").font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            ThemedSwitch(isOn: hasTimeBinding)
        }
    }

    private var hasDateBinding: Binding<Bool> {
        Binding(get: { candidate.date != nil }, set: { on in
            if on {
                candidate.date = candidate.date ?? today
            } else {
                candidate.date = nil
                candidate.endDate = nil
                candidate.start = nil
                candidate.end = nil
            }
            candidate.review(today: today)
        })
    }

    private var dateBinding: Binding<LocalDate> {
        Binding(get: { candidate.date ?? today }, set: { day in
            candidate.date = day
            if let end = candidate.endDate, end <= day { candidate.endDate = nil }
            candidate.review(today: today)
        })
    }

    private var hasTimeBinding: Binding<Bool> {
        Binding(get: { candidate.start != nil }, set: { on in
            if on {
                let start = candidate.start ?? Self.defaultStart
                candidate.start = start
                candidate.end = candidate.end ?? QuickAddParser.defaultEnd(start)
            } else {
                candidate.start = nil
                candidate.end = nil
            }
        })
    }

    private var startBinding: Binding<LocalTime> {
        Binding(get: { candidate.start ?? Self.defaultStart }, set: { start in
            candidate.start = start
            if let end = candidate.end, end <= start, candidate.endDate == nil {
                candidate.end = QuickAddParser.defaultEnd(start)
            }
        })
    }

    private var endBinding: Binding<LocalTime> {
        Binding(get: { candidate.end ?? QuickAddParser.defaultEnd(candidate.start ?? Self.defaultStart) },
                set: { candidate.end = $0 })
    }

    // MARK: 提示与原文

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let note = candidate.note {
                Label(note, systemImage: "exclamationmark.circle").foregroundStyle(Color(hex: 0xA86B00))
            }
            if let vague = candidate.vagueTime, candidate.start == nil {
                Label("原文只说了「\(vague)」，没写具体时刻，可以打开「时刻」补上", systemImage: "clock")
                    .foregroundStyle(Color(hex: 0xA86B00))
            }
            if let end = candidate.endDate, candidate.date != nil {
                Label("跨天：到 " + DateText.title(end, today: today), systemImage: "arrow.right")
                    .foregroundStyle(Theme.subtext)
            }
            if let conflict {
                Text(verbatim: conflict).foregroundStyle(Theme.overdue)
            }
            if !candidate.location.isEmpty {
                Label(candidate.location, systemImage: "mappin").foregroundStyle(Theme.subtext)
            }
            if !candidate.source.isEmpty {
                Text(verbatim: "原文：" + candidate.source)
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(2)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}
