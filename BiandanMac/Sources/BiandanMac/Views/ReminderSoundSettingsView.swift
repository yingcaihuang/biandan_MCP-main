import SwiftUI

/// 设置 → 高级 → 提醒声音：声音来源、本机语音、语速、提示音、三段文案、播报标题、四象限、AI 写文案、试听。
struct ReminderSoundSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var voices: [ReminderVoice] = []
    @State private var playing: String?
    @State private var previewError: String?
    @State private var copyStyle: ReminderCopyStyle = .formal
    @State private var writing = false
    @State private var suggestions: [[String]] = []
    @State private var copyError: String?
    @State private var cloudVoices: [MiniMaxVoice] = []
    @State private var minimaxKeySaved = MiniMaxKeyStore.load() != nil
    @State private var minimaxKeyDraft = ""
    @State private var cloudError: String?

    private static let sampleTitle = "产研周例会"
    private static let sampleClock = "10:00"

    var body: some View {
        @Bindable var model = model
        let sound = model.reminderSound
        InspectorSection("提醒声音") {
            SettingRow("声音", caption: caption(sound.source)) {
                ThemedSegmented(selection: $model.reminderSound.source,
                                options: ReminderSoundSource.allCases.map { ThemeOption(value: $0, title: $0.title) })
            }
            switch sound.source {
            case .systemDefault:
                EmptyView()
            case .systemSound:
                SettingRow("音效", caption: "所有提醒都用这一声") {
                    HStack(spacing: 6) {
                        chimePicker($model.reminderSound.systemSound, allowNone: false)
                        previewButton("system", sound.choice(attempt: 1, quadrant: .neither, title: "", clock: ""))
                    }
                }
            case .voice:
                voiceSection(sound)
            }
            if let previewError {
                errorText(previewError)
            }
            SettingFootnotes(items: [
                SettingFootnote(icon: "waveform",
                                text: "AI 语音可以用 Mac 自带语音（不联网、不收费），也可以用 MiniMax 在线合成（声音更自然，按字数计费，Key 存在钥匙串里）。固定文案只在改了文案、音色或语速时合成一次；打开「播报日程标题」后每个日程都要合成一次。合成好的声音存在「~/Library/Sounds」里，不再使用的会自动删掉。"),
                SettingFootnote(icon: "speaker.wave.2",
                                text: "音量跟随「系统设置 → 声音」里的提醒音量；开着专注模式时不会响。每段声音最长 29 秒，MiniMax 失败时先改用本机语音，再不行用系统默认声音，提醒照常弹出。改了设置后，新声音对之后排进系统的提醒生效。"),
            ])
        }
        .task {
            if voices.isEmpty { voices = await ReminderVoices.load() }
            if model.reminderSound.engine == .minimax && cloudVoices.isEmpty { await loadCloudVoices() }
        }
        .onChange(of: model.reminderSound.engine) { _, engine in
            if engine == .minimax && cloudVoices.isEmpty { Task { await loadCloudVoices() } }
        }
    }

    // MARK: AI 语音

    @ViewBuilder
    private func voiceSection(_ sound: ReminderSoundSettings) -> some View {
        @Bindable var model = model
        SettingRow("语音引擎", caption: sound.engine == .local ? "Mac 自带语音，不联网、不收费"
                                                        : "MiniMax 在线合成，声音更自然，按字数计费") {
            ThemedSegmented(selection: $model.reminderSound.engine,
                            options: ReminderVoiceEngine.allCases.map { ThemeOption(value: $0, title: $0.title) })
        }
        if sound.engine == .minimax {
            SettingRow("MiniMax Key", caption: minimaxKeySaved ? "已保存在钥匙串里"
                                                               : "在 platform.minimax.cn「账户管理 → 接口密钥」里创建") {
                HStack(spacing: 6) {
                    if minimaxKeySaved {
                        Button("刷新音色") { Task { await loadCloudVoices() } }
                            .buttonStyle(.themed)
                        Button("清除") {
                            MiniMaxKeyStore.clear()
                            minimaxKeySaved = false
                            cloudVoices = []
                        }
                        .buttonStyle(.themed)
                    } else {
                        SecureField("", text: $minimaxKeyDraft, prompt: Text("粘贴 API Key"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Button("保存") { saveMiniMaxKey() }
                            .buttonStyle(.themedPrimary)
                            .disabled(minimaxKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if let cloudError {
                errorText(cloudError)
            }
            SettingRow("模型") {
                ThemedSegmented(selection: $model.reminderSound.cloudModel,
                                options: MiniMaxSpeech.models.map { ThemeOption(value: $0.value, title: $0.title) })
            }
        }
        SettingRow("语音", caption: sound.engine == .local ? "本机的中文语音" : "MiniMax 的系统音色") {
            voicePicker($model.reminderSound.style)
        }
        SettingRow("语速") {
            ThemedSegmented(selection: $model.reminderSound.style.rate,
                            options: ReminderVoiceStyle.rates.map { ThemeOption(value: $0.value, title: $0.title) })
        }
        SettingRow("提示音", caption: "开口前先响一声，免得一上来就是人声") {
            chimePicker($model.reminderSound.style.chime, allowNone: true)
        }
        SettingRow("播报日程标题", caption: "打开后每条提醒说出时间和标题；文案里用 {时间}、{标题} 代替") {
            ThemedSwitch(isOn: $model.reminderSound.speakTitle)
        }
        ForEach(0..<3, id: \.self) { index in
            ThemedRow(ReminderSoundSettings.attemptTitles[index]) {
                HStack(spacing: 6) {
                    TextField("", text: textBinding(index),
                              prompt: Text(verbatim: (sound.speakTitle ? ReminderSoundSettings.defaultTemplates
                                                                       : ReminderSoundSettings.defaultTexts)[index]))
                        .themedField()
                    previewButton("text\(index)", .rendered(sound.spec(attempt: index + 1, style: sound.style,
                                                                       title: Self.sampleTitle, clock: Self.sampleClock)))
                }
            }
        }
        SettingRow("AI 写文案", caption: "用「AI 识别日程」里的 DeepSeek 写几组，点「用这组」填进上面") {
            HStack(spacing: 6) {
                ThemedSegmented(selection: $copyStyle,
                                options: ReminderCopyStyle.allCases.map { ThemeOption(value: $0, title: $0.title) })
                Button(writing ? "生成中…" : "生成") { writeCopy(speakTitle: sound.speakTitle) }
                    .buttonStyle(.themed)
                    .disabled(writing)
            }
        }
        if let copyError {
            errorText(copyError)
        }
        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, lines in
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: "\(index + 1). \(line)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(index == 0 ? Theme.text : Theme.subtext)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("用这组") { apply(lines) }
                    .buttonStyle(.themed)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1) }
        }
        SettingRow("按四象限用不同声音", caption: "比如重要紧急的说快一点、换一声更醒目的提示音") {
            ThemedSwitch(isOn: $model.reminderSound.perQuadrant)
        }
        if sound.perQuadrant {
            ForEach(ReminderSoundSettings.quadrants, id: \.self) { quadrant in
                let style = sound.style(for: quadrant)
                ThemedRow(quadrant.title) {
                    HStack(spacing: 6) {
                        voicePicker(styleBinding(quadrant))
                        Picker("", selection: styleBinding(quadrant).rate) {
                            ForEach(ReminderVoiceStyle.rates, id: \.value) { Text($0.title).tag($0.value) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 70)
                        chimePicker(styleBinding(quadrant).chime, allowNone: true)
                        previewButton("q\(ReminderSoundSettings.quadrantKey(quadrant))",
                                      .rendered(sound.spec(attempt: 1, style: style, title: Self.sampleTitle,
                                                           clock: Self.sampleClock)))
                    }
                }
            }
        }
    }

    // MARK: 控件

    @ViewBuilder
    private func voicePicker(_ style: Binding<ReminderVoiceStyle>) -> some View {
        if model.reminderSound.engine == .minimax {
            Picker("", selection: style.cloudVoice) {
                ForEach(cloudVoiceOptions(including: style.wrappedValue.cloudVoice)) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170)
        } else {
            Picker("", selection: style.voice) {
                Text("自动（婷婷）").tag("")
                ForEach(voices) { Text($0.title).tag($0.name) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150)
        }
    }

    /// 还没读到音色列表时用预置的几个；当前选的不在列表里也要能显示。
    private func cloudVoiceOptions(including id: String) -> [MiniMaxVoice] {
        var list = cloudVoices.isEmpty ? MiniMaxSpeech.presetVoices : cloudVoices
        if !id.isEmpty, !list.contains(where: { $0.id == id }) {
            list.insert(MiniMaxVoice(id: id, name: id, summary: ""), at: 0)
        }
        return list
    }

    private func saveMiniMaxKey() {
        let key = minimaxKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try MiniMaxKeyStore.save(key)
            minimaxKeyDraft = ""
            minimaxKeySaved = true
            cloudError = nil
            Task { await loadCloudVoices() }
        } catch {
            cloudError = error.localizedDescription
        }
    }

    private func loadCloudVoices() async {
        guard minimaxKeySaved else { return }
        do {
            cloudVoices = try await MiniMaxSpeech.fetchVoices()
            cloudError = nil
        } catch {
            cloudError = "读取 MiniMax 音色失败：\(error.localizedDescription)"
        }
    }

    private func chimePicker(_ selection: Binding<String>, allowNone: Bool) -> some View {
        Picker("", selection: selection) {
            if allowNone { Text("不加").tag("") }
            ForEach(ReminderSoundSynth.systemSounds, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 110)
    }

    private func previewButton(_ id: String, _ choice: ReminderSoundChoice) -> some View {
        Button {
            play(id, choice)
        } label: {
            Image(systemName: playing == id ? "speaker.wave.2.fill" : "play.fill")
                .frame(width: 14)
        }
        .buttonStyle(.themed)
        .disabled(playing != nil)
        .help("试听")
    }

    private func errorText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.overdue)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func caption(_ source: ReminderSoundSource) -> String {
        switch source {
        case .systemDefault: return "和其他 App 一样的通知声音"
        case .systemSound: return "从 Mac 自带的音效里选一个"
        case .voice: return "用本机语音或 MiniMax 把一句话念出来，第几次提醒说不同的话"
        }
    }

    // MARK: 绑定与动作

    private func textBinding(_ index: Int) -> Binding<String> {
        Binding(get: { model.reminderSound.currentTexts[index] },
                set: { model.reminderSound.setText($0, at: index) })
    }

    private func styleBinding(_ quadrant: Quadrant) -> Binding<ReminderVoiceStyle> {
        Binding(get: { model.reminderSound.style(for: quadrant) },
                set: { model.reminderSound.quadrantStyles[ReminderSoundSettings.quadrantKey(quadrant)] = $0 })
    }

    private func play(_ id: String, _ choice: ReminderSoundChoice) {
        playing = id
        previewError = nil
        Task { @MainActor in
            previewError = await ReminderSoundPlayer.play(choice)
            playing = nil
        }
    }

    private func writeCopy(speakTitle: Bool) {
        writing = true
        copyError = nil
        let settings = model.aiExtractionSettings()
        let style = copyStyle
        Task { @MainActor in
            do {
                suggestions = try await ReminderCopywriter.generate(style: style, speakTitle: speakTitle, settings: settings)
            } catch {
                copyError = error.localizedDescription
            }
            writing = false
        }
    }

    private func apply(_ lines: [String]) {
        for (index, line) in lines.prefix(3).enumerated() {
            model.reminderSound.setText(line, at: index)
        }
        suggestions = []
    }
}
