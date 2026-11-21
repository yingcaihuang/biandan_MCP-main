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
        let fallback = state.listID
        let chosen = state.candidates.filter(\.include)
        state.saving = true
        state.result = nil
        state.error = nil
        Task { @MainActor in
            var added: [UUID] = []
            // 同一批里同名的新分类只建一次。
            var created: [String: String] = [:]
            for candidate in chosen {
                var listID = fallback
                switch candidate.category {
                case .existing(let id):
                    listID = id
                case .new(let name, let colorIndex):
                    if let id = created[name] ?? model.snapshot.lists.first(where: { $0.displayName == name })?.id3 {
                        listID = id
                    } else if let id = await model.createList(name: name, colorIndex: colorIndex, select: false) {
                        created[name] = id
                        listID = id
                    } else {
                        continue
                    }
                }
                guard let input = candidate.input(listID: listID) else { continue }
                if await model.createTask(input) { added.append(candidate.id) }
            }
            let newLists = created.keys.sorted().map { "「\($0)」" }.joined()
            let suffix = newLists.isEmpty ? "" : "，新建分类" + newLists
            state.candidates.removeAll { added.contains($0.id) }
            state.saving = false
            let failed = chosen.count - added.count
            if failed == 0 {
                state.result = "已添加 \(added.count) 条日程" + suffix
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
            ThemedRow("分类") { CandidateCategoryPicker(category: categoryBinding, tint: candidate.quadrant.tint) }
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

    private var categoryBinding: Binding<CandidateCategory> {
        Binding(get: { candidate.category }, set: { value in
            if value != candidate.category { candidate.categoryReason = nil }
            candidate.category = value
        })
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
            if let reason = candidate.categoryReason {
                Label(reason, systemImage: "sparkles").foregroundStyle(Theme.subtext)
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

// MARK: - 一条日程的分类

/// 分类选择：已有分类，或按情景建议的新分类（点「添加选中」时才真正新建）；也可以输入名字新建。
struct CandidateCategoryPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var category: CandidateCategory
    var tint: Color = Theme.accent
    @State private var open = false
    @State private var draft = ""

    private var current: (name: String, swatch: Color, isNew: Bool) {
        switch category {
        case .existing(let id):
            let list = model.snapshot.list(id)
            return (list?.displayName ?? "未分类", list?.swatch ?? Theme.fieldName, false)
        case .new(let name, let colorIndex):
            return (name, ListColor(sortIndex: 0, colorIndex: colorIndex).color, true)
        }
    }

    var body: some View {
        let label = current
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(label.swatch).frame(width: 10, height: 10)
                Text(verbatim: label.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if label.isNew { NewCategoryTag() }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.subtext)
            }
            .fieldChrome(active: open, tint: tint)
        }
        .buttonStyle(.plain)
        .help(label.isNew ? "点「添加选中」时会新建这个分类" : "选择分类")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            menu
                .frame(width: 250, alignment: .leading)
                .popoverBackground(Theme.panel)
        }
    }

    @ViewBuilder
    private var menu: some View {
        let lists = model.snapshot.lists
        let suggested = ScheduleCategorizer.missingScenes(existing: lists.map(\.displayName))
        VStack(alignment: .leading, spacing: 0) {
            ThemedMenuCaption("分类")
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            // 手动输入的新分类（不在内置常用分类里）放在最上面。
            if case .new(let name, let colorIndex) = category, !suggested.contains(where: { $0.name == name }) {
                option(name: name, swatch: ListColor(sortIndex: 0, colorIndex: colorIndex).color,
                       selected: true, isNew: true) { open = false }
            }
            if lists.count + suggested.count > 9 {
                ScrollView { allOptions(lists, suggested) }.frame(height: 320)
            } else {
                allOptions(lists, suggested)
            }
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
            HStack(spacing: 6) {
                TextField("", text: $draft, prompt: Text("新分类名称"))
                    .themedField()
                    .onSubmit(createDraft)
                Button("新建", action: createDraft)
                    .buttonStyle(.themed)
                    .disabled(trimmedDraft.isEmpty)
            }
            .padding(.horizontal, 10)
            Text("新分类在点「添加选中」时才会建好")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtext)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
    }

    /// 已有分类，下面是还没建过的内置常用分类（选中后点「添加选中」时新建）。
    private func allOptions(_ lists: [TodoList], _ suggested: [ScheduleCategorizer.Scene]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            listOptions(lists)
            if !suggested.isEmpty {
                ThemedMenuCaption("常用分类（添加时新建）")
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ForEach(suggested, id: \.name) { scene in
                    let value = CandidateCategory.new(name: scene.name, colorIndex: scene.colorIndex)
                    option(name: scene.name, swatch: ListColor(sortIndex: 0, colorIndex: scene.colorIndex).color,
                           selected: category == value, isNew: true) {
                        category = value
                        open = false
                    }
                }
            }
        }
    }

    private func listOptions(_ lists: [TodoList]) -> some View {
        VStack(spacing: 0) {
            ForEach(lists) { list in
                option(name: list.displayName, swatch: list.swatch,
                       selected: category == .existing(list.id3), isNew: false) {
                    category = .existing(list.id3)
                    open = false
                }
            }
        }
    }

    private func option(name: String, swatch: Color, selected: Bool, isNew: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(swatch).frame(width: 10, height: 10)
                Text(verbatim: name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if isNew { NewCategoryTag() }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func createDraft() {
        let name = trimmedDraft
        guard !name.isEmpty else { return }
        if let list = model.snapshot.lists.first(where: { $0.displayName == name }) {
            category = .existing(list.id3)
        } else {
            category = .new(name: name, colorIndex: ScheduleCategorizer.colorIndex(for: name))
        }
        draft = ""
        open = false
    }
}

/// 「新建」小标签：这个分类还不存在，添加时才会建。
private struct NewCategoryTag: View {
    var body: some View {
        Text("新建")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color(hex: 0x9A7400))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.selectionFill))
    }
}
