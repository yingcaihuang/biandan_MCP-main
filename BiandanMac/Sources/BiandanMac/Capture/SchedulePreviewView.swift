import AppKit
import SwiftUI

// MARK: - 确认卡片界面（与「新建任务」同一套主题）：每条可改标题、日期、时刻、四象限，可取消勾选，
// 显示时间冲突；点「添加选中」才写入。

private struct PreviewSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// 标题栏 + 底栏的总高度（两处相加）。
private struct PreviewChromeKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// 中间内容（提示、候选、识别到的文字）不受限制时的高度。
private struct PreviewBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    func reportHeight<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { proxy in Color.clear.preference(key: key, value: proxy.size.height) })
    }
}

struct SchedulePreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Bindable var state: SchedulePreviewState
    let onClose: () -> Void
    let onResize: (CGSize) -> Void
    @State private var showText = false
    @State private var chromeHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0

    /// 中间内容最多多高：卡片上限减去标题栏和底栏；没有上限时不限。
    private var bodyLimit: CGFloat {
        state.maxHeight > 0 ? max(state.maxHeight - chromeHeight, 160) : .infinity
    }

    /// 内容比屏幕可见区域还高（例如球在屏幕下方、候选又多），中间整体滚动，标题栏和按钮始终看得到。
    private var scrollsBody: Bool { bodyHeight > bodyLimit + 0.5 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .reportHeight(PreviewChromeKey.self)
            bodySection
            if !state.loading {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    footer
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Theme.panel)
                }
                .reportHeight(PreviewChromeKey.self)
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
        .onPreferenceChange(PreviewChromeKey.self) { height in chromeHeight = height }
        .onPreferenceChange(PreviewBodyHeightKey.self) { height in bodyHeight = height }
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            messages
            if !state.candidates.isEmpty { candidateList }
            if !state.recognizedText.isEmpty { recognizedText }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportHeight(PreviewBodyHeightKey.self)
    }

    @ViewBuilder
    private var bodySection: some View {
        if scrollsBody {
            ScrollView { bodyContent }.frame(height: bodyLimit)
        } else {
            bodyContent
        }
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
                CaptureStageRow(state: state)
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
            if !state.loading, let privacy = CapturePrivacy.note(source: state.source, decision: state.decision,
                                                                 aiModel: state.usage?.model ?? model.aiModelName) {
                CapturePrivacyLabel(note: privacy)
            }
            if !state.loading && !state.timings.isEmpty {
                CaptureStageStrip(timings: state.timings)
                    .help(CaptureTimingLog.summary())
            }
            if let decision = state.decision, !state.loading {
                DecisionCard(record: decision, after: decisionAfter)
            }
            if let usage = state.usage, !state.loading {
                AIUsageTiles(usage: usage)
            }
            if let reason = aiSetupReason {
                AISetupGuide(reason: reason, action: openAISettings)
            }
            if !state.loading && state.error == nil && state.candidates.isEmpty && !state.recognizedText.isEmpty {
                Text(verbatim: emptyHint)
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }

    private var aiReady: Bool { model.aiExtractionMode != .off && model.aiKeyConfigured }

    private var retryTitle: String {
        state.decision?.outcome == .block ? "仍然用 " + model.aiModelName + " 识别" : "用 AI 识别"
    }

    private var retryHelp: String {
        var text = "把识别到的文字发给 " + model.aiModelName + " 重新提取（不含截图）"
        if state.decision?.outcome == .block, let saved = state.decision?.savedUSD {
            text += "，预计约 " + AIUsageFormat.cost(saved)
        }
        return text
    }

    /// AI 决策卡片「之后」一行：拦下 / 放行之后实际发生了什么。
    private var decisionAfter: [DecisionPiece] {
        guard let record = state.decision else { return [] }
        let count = state.candidates.count
        let source = state.source ?? .rules
        if record.outcome == .block {
            if record.trigger == .fallback {
                return [.plain("不再调用 AI 兜底，这段文字没有日程")]
            }
            var pieces: [DecisionPiece] = [.plain("改用 "), .tag(source.title, SourceTag.color(source))]
            if count > 0 {
                pieces.append(.plain("，找到 \(count) 条，"))
                pieces.append(.strong("可能是误识别，默认不勾选", DecisionPalette.failed))
            } else {
                pieces.append(.plain("，也没有找到日程"))
            }
            return pieces
        }
        if source == .ai {
            var pieces: [DecisionPiece] = [.chip(record.aiModel, DecisionPalette.model, false), .plain(" 找到 \(count) 条")]
            if let usage = state.usage {
                pieces.append(.plain(" · "))
                pieces.append(.strong(AIUsageFormat.seconds(usage.seconds), DecisionPalette.time))
                if let cost = usage.costUSD {
                    pieces.append(.plain(" · "))
                    pieces.append(.strong(AIUsageFormat.cost(cost), DecisionPalette.blocked))
                }
            }
            return pieces
        }
        return [.plain("AI 没成功，改用 "), .tag(source.title, SourceTag.color(source)), .plain("，找到 \(count) 条")]
    }

    private var emptyHint: String {
        if state.decision?.outcome == .block {
            return ["如果这里其实有日程，点下方「仍然用 ", model.aiModelName,
                    " 识别」。这次会记作误拦，统计里能看到误拦率，方便调整灵敏度。"].joined()
        }
        if state.source == .ai {
            return "AI 也没找到明确的日程。可以核对下面识别到的文字，或只框住聊天内容再试。"
        }
        let rule = "规则识别只认带日期或时刻的句子，例如「明天下午3点」「下周二」「12月中旬」「11月24日 14:00」。"
        return aiReady ? rule + "可以点下方「用 AI 识别」再试一次。" : rule
    }

    /// 需要 AI 兜底、但 AI 还没配置好（或 Key 失效）时的引导文字；不需要引导时为 nil。
    private var aiSetupReason: String? {
        guard !state.loading else { return nil }
        let messages = (state.note ?? "") + (state.error ?? "")
        if messages.contains("API Key") { return "AI 的 API Key 无效或已失效，请到设置里重新填写。" }
        guard state.source != .ai, !aiReady, state.candidates.isEmpty, !state.lines.isEmpty else { return nil }
        if model.aiExtractionMode == .off {
            return "规则识别没找到日程，AI 识别目前是关闭的。打开后，这种情况会自动交给 AI 兜底。"
        }
        return "规则识别没找到日程。填入 DeepSeek API Key 后，这种情况会自动交给 AI 兜底。"
    }

    /// 打开「设置 → 高级」并滚动到「AI 识别日程」。卡片保持打开，配好后回来就能点「用 AI 识别」。
    private func openAISettings() {
        SettingsNavigator.prepare(model: model, anchor: .ai)
        openSettings()
        SettingsNavigator.ensureOpened()
    }

    // MARK: 候选列表

    @ViewBuilder
    private var candidateList: some View {
        let rows = VStack(spacing: 10) {
            ForEach($state.candidates) { $candidate in
                ScheduleCandidateRow(candidate: $candidate, today: model.today, conflict: conflictText(candidate),
                                     onLocate: { ScheduleCaptureFlow.locate(id: candidate.id) })
            }
        }
        if state.candidates.count > 2 && !scrollsBody {
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
            if state.source != .ai && !state.lines.isEmpty {
                if aiReady {
                    Button {
                        ScheduleCaptureFlow.retryWithAI(model: model)
                    } label: {
                        Label(retryTitle, systemImage: "sparkles")
                    }
                    .buttonStyle(.themed)
                    .disabled(state.saving)
                    .help(retryHelp)
                } else if aiSetupReason == nil {
                    // 识别出了日程、但还没接入 AI：也给一个入口，想用 AI 再识别时去设置。
                    Button(action: openAISettings) {
                        Label("设置 AI 识别", systemImage: "gearshape")
                    }
                    .buttonStyle(.themed)
                    .help("接入 DeepSeek 后，可以用 AI 识别这段文字")
                }
            }
            Spacer(minLength: 6)
            if !signedIn {
                Text("请先在便单主窗口登录").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
            if signedIn && chosen.isEmpty && !state.candidates.isEmpty && !state.saving {
                Text("先勾选左边的圆圈")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DecisionPalette.failed)
                    .lineLimit(1)
                    .help("这几条默认没有勾选，勾选后「添加选中」才能点")
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
        let fill = fillColor
        Text(verbatim: source.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .help(source.help)
    }

    private var fillColor: Color { Self.color(source) }

    /// 端侧模型用琥珀色，AI 用蓝色，规则识别用灰色。
    static func color(_ source: ScheduleExtractionSource) -> Color {
        switch source {
        case .model: return Theme.accent
        case .ai: return Quadrant.notImportantUrgent.tint
        case .rules: return Color(hex: 0xA79F8E)
        }
    }
}

// MARK: - 一条候选日程

/// 勾选 + 标题 + 象限，下面是日期、时刻（主题选择器），再下面是提示、冲突、地点和原文。左侧色条是象限颜色。
struct ScheduleCandidateRow: View {
    @Binding var candidate: ScheduleCandidate
    let today: LocalDate
    let conflict: String?
    /// 点定位按钮或在地点框里回车时，在地图上查坐标。
    var onLocate: () -> Void = {}
    @State private var pickQuadrant = false

    private static let defaultStart = LocalTime(hour: 9, minute: 0)!

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let border: Color = conflict == nil ? Theme.line : Theme.overdue.opacity(0.6)
        let opacity: Double = candidate.include ? 1 : 0.55
        let tint = candidate.quadrant.tint
        let doubts = candidate.doubts(today: today)
        VStack(alignment: .leading, spacing: 0) {
            // 勾选框不跟着变淡，免得看起来像不能点。
            titleRow.candidateDoubt(doubts[.title])
            VStack(alignment: .leading, spacing: 0) {
                ThemedRow("日期") { dateControls }.candidateDoubt(doubts[.date])
                if candidate.date != nil {
                    ThemedRow("时刻") { timeControls }.candidateDoubt(doubts[.time])
                }
                ThemedRow("分类") { CandidateCategoryPicker(category: categoryBinding, tint: candidate.quadrant.tint) }
                ThemedRow("地点") { locationControls }.candidateDoubt(doubts[.location])
                details
            }
            .opacity(opacity)
        }
        .padding(.leading, 4)
        .background(shape.fill(Theme.card))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 4)
        }
        .clipShape(shape)
        .overlay(shape.stroke(border))
        .animation(.easeOut(duration: 0.15), value: candidate.quadrant)
    }

    // MARK: 第一行

    private var titleRow: some View {
        HStack(spacing: 8) {
            checkbox
            TextField("", text: $candidate.title, prompt: Text("要做什么？"))
                .themedField()
            quadrantChip
            dragHandle
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var checkbox: some View {
        let on = candidate.include
        let icon = on ? "checkmark.circle.fill" : "circle"
        let color: Color = on ? Theme.accent : Theme.accent.opacity(0.75)
        return Button {
            candidate.include.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "不添加这一条" : "勾选后才会添加这一条")
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
                    if picked != candidate.quadrant { candidate.quadrantReason = nil }
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
            if day != candidate.date { candidate.vagueDate = nil }
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

    // MARK: 地点

    private var locationControls: some View {
        let empty = candidate.locateQuery.isEmpty
        let busy = candidate.lookup == .locating
        return HStack(spacing: 6) {
            TextField("", text: locationBinding, prompt: Text("没有地点"))
                .themedField()
                .frame(width: 230)
                .onSubmit(onLocate)
            Button(action: onLocate) {
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.themed)
            .disabled(empty || busy)
            .help("在地图上查找坐标")
        }
    }

    /// 改了地点就清掉旧坐标，等重新定位。
    private var locationBinding: Binding<String> {
        Binding(get: { candidate.location }, set: { value in
            guard value != candidate.location else { return }
            candidate.location = value
            candidate.locationQuery = nil
            candidate.latitude = nil
            candidate.longitude = nil
            candidate.placeTitle = nil
            candidate.lookup = .idle
        })
    }

    @ViewBuilder
    private var placeStatus: some View {
        switch candidate.lookup {
        case .locating:
            Label("正在地图上查找「\(candidate.locateQuery)」…", systemImage: "location.magnifyingglass")
                .foregroundStyle(Theme.subtext)
        case .found:
            if let latitude = candidate.latitude, let longitude = candidate.longitude {
                PlaceFoundRow(name: candidate.placeTitle ?? candidate.location, latitude: latitude, longitude: longitude)
            }
        case .notFound:
            Label("地图上没找到「\(candidate.locateQuery)」，添加时只保存地点名称；可以写得更具体再点定位",
                  systemImage: "mappin.slash")
                .foregroundStyle(Color(hex: 0xA86B00))
        case .idle:
            EmptyView()
        }
    }

    // MARK: 提示与原文

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let summary = doubtSummary {
                Label(summary, systemImage: "questionmark.diamond.fill").foregroundStyle(Color(hex: 0xB07D00))
            }
            if let note = candidate.note {
                Label(note, systemImage: "exclamationmark.circle").foregroundStyle(Color(hex: 0xA86B00))
            }
            if let vague = candidate.vagueDate, let date = candidate.date {
                Label("原文只说了「\(vague)」，日期先按 \(DateText.title(date, today: today)) 填，可以改",
                      systemImage: "calendar")
                    .foregroundStyle(Color(hex: 0xA86B00))
            }
            if let vague = candidate.vagueTime, candidate.start == nil {
                Label("原文只说了「\(vague)」，没写具体时刻，可以打开「时刻」补上", systemImage: "clock")
                    .foregroundStyle(Color(hex: 0xA86B00))
            }
            if let end = candidate.endDate, candidate.date != nil {
                Label("跨天：到 " + DateText.title(end, today: today), systemImage: "arrow.right")
                    .foregroundStyle(Theme.subtext)
            }
            if let reason = candidate.quadrantReason {
                Label(reason, systemImage: "flag.fill").foregroundStyle(Theme.subtext)
            }
            if let reason = candidate.categoryReason {
                Label(reason, systemImage: "sparkles").foregroundStyle(Theme.subtext)
            }
            if let conflict {
                Text(verbatim: conflict).foregroundStyle(Theme.overdue)
            }
            placeStatus
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

// MARK: - AI 设置引导

/// AI 兜底需要用到、但还没配置好时，在卡片里提示并一键打开设置。
private struct AISetupGuide: View {
    let reason: String
    let action: () -> Void

    var body: some View {
        let tint = Color(hex: 0xFA8B36)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint))
            VStack(alignment: .leading, spacing: 4) {
                Text("接入 AI 识别")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(verbatim: reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0x4A453C))
                    .fixedSize(horizontal: false, vertical: true)
                Text("申请 DeepSeek API Key → 在设置里粘贴保存 → 回到这里点「用 AI 识别」")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: action) {
                        Label("打开 AI 设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.themedPrimary)
                    Link(destination: URL(string: "https://platform.deepseek.com/api_keys")!) {
                        HStack(spacing: 3) {
                            Text("申请 API Key")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tint)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tint.opacity(0.07)))
        .overlay(shape.stroke(tint.opacity(0.35)))
    }
}

// MARK: - 地图上找到的地点

/// 「文三社区 · 30.2741, 120.1301  在地图中查看」
private struct PlaceFoundRow: View {
    let name: String
    let latitude: Double
    let longitude: Double

    var body: some View {
        let coordinate = GeoText.format(latitude) + ", " + GeoText.format(longitude)
        HStack(spacing: 8) {
            Label {
                Text(verbatim: name + " · " + coordinate).lineLimit(1)
            } icon: {
                Image(systemName: "mappin.circle.fill")
            }
            .foregroundStyle(Theme.done)
            .help("添加时地点名称和坐标一起写进任务（不开启地点提醒）")
            if let url = PlaceLocator.mapsURL(name: name, latitude: latitude, longitude: longitude) {
                Link("在地图中查看", destination: url)
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

// MARK: - AI 用量

/// 这次 AI 识别的用量：用时、Token、费用、模型各一张不同颜色的小卡片，单独一行显示。
struct AIUsageTiles: View {
    let usage: AIUsageRecord

    var body: some View {
        typealias F = AIUsageFormat
        let tokenDetail = "输入 \(F.tokens(usage.promptTokens)) · 输出 \(F.tokens(usage.completionTokens))"
        let cacheHelp: String = usage.reportsCache
            ? "缓存命中 \(F.tokens(usage.cacheHitTokens)) · 未命中 \(F.tokens(usage.cacheMissTokens)) · 发送 \(usage.inputCharacters) 字"
            : "发送 \(usage.inputCharacters) 字"
        let costValue: String = usage.costUSD.map { "约 " + F.cost($0) } ?? "—"
        let costCaption: String = usage.costUSD == nil
            ? "无法估算费用" : (AIPricing.isPeak(usage.date) ? "预估 · 高峰价" : "预估 · 非高峰价")
        let modelName = AIModelOption(rawValue: usage.model)?.title ?? usage.model
        // 两列两行、等宽：卡片宽 520，一行放四张时文字会被挤没。
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            tile(icon: "clock", value: F.seconds(usage.seconds), caption: "识别用时 · 请求到解析完成",
                 tint: Color(hex: 0xD99A00), help: "从发出请求到解析完结果")
            tile(icon: "number", value: F.tokens(usage.totalTokens) + " tokens", caption: tokenDetail,
                 tint: Quadrant.notImportantUrgent.tint, help: cacheHelp)
            tile(icon: "dollarsign.circle", value: costValue, caption: costCaption, tint: Theme.done,
                 help: "按 DeepSeek 官方价目估算，实际以账单为准")
            tile(icon: "cpu", value: modelName, caption: usage.trigger.title, tint: Color(hex: 0x8E5BD6),
                 help: usage.model)
        }
    }

    private func tile(icon: String, value: String, caption: String, tint: Color, help: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: value)
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(verbatim: caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tint.opacity(0.10)))
        .overlay(shape.stroke(tint.opacity(0.30)))
        .help(help)
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

// MARK: - AI 决策卡片：标题写明决策模型；结论、省下、依据、内容、之后各一行，关键字分色

enum DecisionPalette {
    /// 决策模型名：紫色。
    static var decider: Color { Color(hex: 0x8E5BD6) }
    /// 大模型名、放行：蓝色。
    static var model: Color { Quadrant.notImportantUrgent.tint }
    /// 拦下、省下的钱、高于门槛：绿色。
    static var blocked: Color { Theme.done }
    /// 没判断成功、需要留意：橙色。
    static var failed: Color { Color(hex: 0xD9822B) }
    /// 低于门槛：红棕。
    static var low: Color { Color(hex: 0xB5532A) }
    /// 用时：琥珀，和 AI 用量小卡片一致。
    static var time: Color { Color(hex: 0xD99A00) }
    /// 内容类型：浅青；状态：浅粉。
    static var kind: Color { Color(hex: 0x2BB5B0) }
    static var status: Color { Color(hex: 0xD9558C) }
}

enum DecisionPiece {
    case text(String, Color, Bool)
    case small(String)
    /// 模型名：等宽字体胶囊；第三个参数为 true 时变浅、加删除线（被拦下，没有调用）。
    case chip(String, Color, Bool)
    /// 内容类型、状态、识别方式这类小标签。
    case tag(String, Color)

    static func plain(_ value: String) -> DecisionPiece { .text(value, Theme.text, false) }
    static func strong(_ value: String, _ color: Color) -> DecisionPiece { .text(value, color, true) }
}

struct DecisionChip: View {
    let text: String
    let tint: Color
    var mono = true
    var faded = false

    var body: some View {
        let color: Color = faded ? tint.opacity(0.6) : tint
        let font: Font = mono ? .system(size: 11, weight: .semibold, design: .monospaced) : .system(size: 11, weight: .semibold)
        let fill: Double = faded ? 0.06 : 0.13
        let stroke: Double = faded ? 0.25 : 0.4
        Text(verbatim: text)
            .strikethrough(faded, color: color)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(fill)))
            .overlay(Capsule().stroke(tint.opacity(stroke), lineWidth: 1))
    }
}

private struct DecisionPieceView: View {
    let piece: DecisionPiece

    var body: some View {
        switch piece {
        case .text(let value, let color, let bold):
            Text(verbatim: value)
                .font(.system(size: 12, weight: bold ? .bold : .regular))
                .foregroundStyle(color)
        case .small(let value):
            Text(verbatim: value)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtext)
        case .chip(let value, let color, let faded):
            DecisionChip(text: value, tint: color, mono: true, faded: faded)
        case .tag(let value, let color):
            DecisionChip(text: value, tint: color, mono: false)
        }
    }
}

private struct DecisionRow {
    let label: String
    let pieces: [DecisionPiece]
}

struct DecisionCard: View {
    let record: DecisionRecord
    /// 「之后」一行由确认卡片按这次的实际结果给出。
    let after: [DecisionPiece]

    private var style: (icon: String, tint: Color) {
        switch record.outcome {
        case .block: return ("line.3.horizontal.decrease.circle.fill", DecisionPalette.blocked)
        case .pass: return ("arrow.right.circle.fill", DecisionPalette.model)
        case .failed: return ("exclamationmark.circle.fill", DecisionPalette.failed)
        }
    }

    var body: some View {
        let tint = style.tint
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let list = rows
        return VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(list.indices, id: \.self) { index in row(list[index]) }
        }
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tint.opacity(0.07)))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .clipShape(shape)
        .overlay(shape.stroke(tint.opacity(0.3)))
        .help(record.reason)
    }

    // MARK: 标题

    private var providerText: String {
        var parts: [String] = ["阿里云百炼"]
        if let region = record.region { parts.append(region) }
        parts.append(record.sensitivity.title + "档")
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        let current = style
        return HStack(spacing: 6) {
            Image(systemName: current.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(current.tint)
            Text("AI 决策")
                .font(.system(size: 12.5, weight: .heavy))
                .foregroundStyle(Theme.text)
            DecisionChip(text: record.decisionModel ?? DecisionSettings.model, tint: DecisionPalette.decider)
            Text(verbatim: providerText)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtext)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(verbatim: "\(record.durationMs) 毫秒")
                .font(.system(size: 11.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(DecisionPalette.time)
        }
    }

    private func row(_ item: DecisionRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: item.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.fieldName)
                .frame(width: 28, alignment: .leading)
                .padding(.top, 1.5)
            CaptureFlowLayout(spacing: 2, lineSpacing: 3) {
                ForEach(item.pieces.indices, id: \.self) { index in DecisionPieceView(piece: item.pieces[index]) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 各行

    private var rows: [DecisionRow] {
        var list: [DecisionRow] = [DecisionRow(label: "结论", pieces: conclusion)]
        if record.outcome == .block { list.append(DecisionRow(label: "省下", pieces: savings)) }
        if let answers = record.answers {
            list.append(DecisionRow(label: "依据", pieces: basis(answers)))
            let content = contentPieces(answers)
            if !content.isEmpty { list.append(DecisionRow(label: "内容", pieces: content)) }
        }
        if record.outcome == .failed, let error = record.error {
            list.append(DecisionRow(label: "原因", pieces: [.strong(error, DecisionPalette.failed)]))
        }
        if !after.isEmpty { list.append(DecisionRow(label: "之后", pieces: after)) }
        return list
    }

    private var conclusion: [DecisionPiece] {
        let model = record.aiModel
        switch record.outcome {
        case .block:
            return [.plain("没有日程 → "), .strong("已拦下", DecisionPalette.blocked), .plain("，没有调用 "),
                    .chip(model, DecisionPalette.model, true)]
        case .pass:
            return [.plain("有日程 → "), .strong("放行", DecisionPalette.model), .plain("，交给 "),
                    .chip(model, DecisionPalette.model, false), .plain(" 提取")]
        case .failed:
            let timedOut = (record.error ?? "").contains("超时")
            let title: String = timedOut ? "判断超时（\(Int(DecisionSettings.timeout)) 秒）" : "没判断成功"
            return [.plain(title + " → "), .strong("照常调用", DecisionPalette.failed), .plain(" "),
                    .chip(model, DecisionPalette.model, false)]
        }
    }

    private var savings: [DecisionPiece] {
        var pieces: [DecisionPiece] = []
        if let saved = record.savedUSD {
            pieces.append(.strong(AIUsageFormat.cost(saved), DecisionPalette.blocked))
        } else {
            pieces.append(.small("费用无法估算"))
        }
        if let ms = record.savedMs {
            pieces.append(.plain(" · 少等约 "))
            pieces.append(.strong(AIUsageFormat.seconds(Double(ms) / 1000), DecisionPalette.time))
        }
        return pieces
    }

    private func basis(_ answers: DecisionAnswers) -> [DecisionPiece] {
        let sensitivity = record.sensitivity
        let p = answers.hasSchedule
        let pLow = p < sensitivity.probabilityLimit
        let pLimit = AIUsageFormat.percent(sensitivity.probabilityLimit)
        let pColor: Color = pLow ? DecisionPalette.low : DecisionPalette.blocked
        let pNote: String = pLow ? "（低于 " + pLimit + "）" : "（高于 " + pLimit + "）"
        var pieces: [DecisionPiece] = [.plain("有日程概率 "), .strong(AIUsageFormat.percent(p), pColor), .small(pNote)]
        var cLow = true
        if let c = answers.clarity {
            cLow = c < sensitivity.clarityLimit
            let cLimit = String(format: "%.1f", sensitivity.clarityLimit)
            let cColor: Color = cLow ? DecisionPalette.low : DecisionPalette.blocked
            let cNote: String = cLow ? "（低于 " + cLimit + "）" : "（不低于 " + cLimit + "）"
            pieces.append(.plain(" · 清晰度 "))
            pieces.append(.strong(String(format: "%.1f/4", c), cColor))
            pieces.append(.small(cNote))
        }
        // 不是因为概率、清晰度低被拦（例如内容是代码），把具体依据也写上。
        if record.outcome == .block && !(pLow && cLow) {
            pieces.append(.small(" · " + record.reason))
        }
        return pieces
    }

    private func contentPieces(_ answers: DecisionAnswers) -> [DecisionPiece] {
        var pieces: [DecisionPiece] = []
        if let kind = answers.kindTitle {
            let confidence: String = answers.kindConfidence.map { " " + AIUsageFormat.percent($0) } ?? ""
            pieces.append(.tag(kind + confidence, DecisionPalette.kind))
        }
        if let status = answers.statusTitle {
            if !pieces.isEmpty { pieces.append(.plain(" ")) }
            pieces.append(.tag(status, DecisionPalette.status))
        }
        return pieces
    }
}

// MARK: - 候选：拖到日历、存疑汇总

extension ScheduleCandidateRow {
    /// 按住拖到主窗口的日历（月 / 周视图）某一天：只改这条候选的日期，点「添加选中」才写入。
    var dragHandle: some View {
        Image(systemName: "calendar.badge.plus")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.subtext)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .draggable(candidate.dragID) { CandidateDragPreview(title: candidate.title) }
            .help("按住拖到主窗口的日历上，改到那一天")
    }

    var doubtSummary: String? {
        let count = candidate.doubts(today: today).count
        return count > 0 ? "黄色标出的 \(count) 项不太确定，添加前请核对" : nil
    }
}
