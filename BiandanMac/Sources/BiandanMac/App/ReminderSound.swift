import AppKit
import AVFoundation
import CryptoKit
import Foundation

// MARK: - 提醒声音：系统默认、系统音效，或用 MiniMax 把一句话合成为提醒音
//
// 通知只能播放 ~/Library/Sounds（或 App 包里）的声音文件，所以先用 MiniMax 在线合成，
// 前面拼上一声系统提示音，转成 .caf 存进 ~/Library/Sounds，排提醒时按文件名指定。
// 文件名带内容指纹：设置变了就是新文件（系统会缓存同名声音）；不再用的文件在排提醒时清掉。
// 通知声音最长 30 秒，超过系统会改放默认声音，这里截到 29 秒。

enum ReminderSoundSource: String, CaseIterable, Codable, Sendable {
    case systemDefault, systemSound, voice

    var title: String {
        switch self {
        case .systemDefault: return "系统默认"
        case .systemSound: return "系统音效"
        case .voice: return "AI 语音"
        }
    }
}

/// 一种念法：MiniMax 音色、语速档位（190 为正常，换算成 MiniMax 的 speed）、说话前的提示音（空表示不加）。
/// 旧版本存的语音名（voice）不再读取。
struct ReminderVoiceStyle: Codable, Hashable, Sendable {
    var rate: Int = 190
    var chime: String = "Glass"
    /// MiniMax 的音色 ID。
    var cloudVoice: String = MiniMaxSpeech.defaultVoice

    static let rates: [(value: Int, title: String)] = [(150, "慢"), (190, "正常"), (230, "快"), (270, "很快")]

    private enum CodingKeys: String, CodingKey { case rate, chime, cloudVoice }
}

extension ReminderVoiceStyle {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decodeIfPresent(Int.self, forKey: .rate) { rate = value }
        if let value = try? c.decodeIfPresent(String.self, forKey: .chime) { chime = value }
        if let value = try? c.decodeIfPresent(String.self, forKey: .cloudVoice), !value.isEmpty { cloudVoice = value }
    }
}

/// 要合成的一段声音。text 为空时只有提示音；有文字时用 MiniMax 合成，voice 是音色 ID，model 是模型。
struct ReminderSoundSpec: Hashable, Sendable {
    var text: String
    var voice: String
    var rate: Int
    var chime: String
    var model: String = ""

    var isEmpty: Bool { text.isEmpty && chime.isEmpty }

    /// MiniMax 合成失败时的退路：只响提示音（没有提示音时是空的，改用系统默认声音）。
    var chimeOnly: ReminderSoundSpec { ReminderSoundSpec(text: "", voice: "", rate: 0, chime: chime) }
}

enum ReminderSoundChoice: Hashable, Sendable {
    case systemDefault
    case rendered(ReminderSoundSpec)
}

/// 设置 → 高级 → 提醒声音。存在 UserDefaults 里（JSON）。
struct ReminderSoundSettings: Codable, Hashable, Sendable {
    static let storageKey = "biandan.reminderSound"
    static let defaultTexts = ["你有新的日程需要关注，请及时处理", "这个日程还没处理，再提醒你一下", "最后提醒一次，请尽快处理"]
    static let defaultTemplates = ["{时间}，{标题}，请及时处理", "{标题}还没处理，再提醒你一下", "最后提醒一次：{标题}，请尽快处理"]
    static let attemptTitles = ["第 1 次", "第 2 次", "最后一次"]
    /// 每句文案的字数上限（朗读约 15 秒），标题最多念 30 个字。
    static let maxCharacters = 60
    static let maxTitleCharacters = 30
    static let quadrants: [Quadrant] = [.importantUrgent, .importantNotUrgent, .notImportantUrgent, .neither]

    var source: ReminderSoundSource = .systemDefault
    var systemSound = "Glass"
    var style = ReminderVoiceStyle()
    var texts = ReminderSoundSettings.defaultTexts
    var speakTitle = false
    var titleTemplates = ReminderSoundSettings.defaultTemplates
    var perQuadrant = false
    var quadrantStyles: [String: ReminderVoiceStyle] = [:]
    var cloudModel = MiniMaxSpeech.defaultModel

    /// 以前的「语音引擎」（engine）已经去掉，AI 语音一律用 MiniMax；旧设置里的 engine 不再读取。
    private enum CodingKeys: String, CodingKey {
        case source, systemSound, style, texts, speakTitle, titleTemplates, perQuadrant, quadrantStyles, cloudModel
    }

    static func quadrantKey(_ quadrant: Quadrant) -> String { String(describing: quadrant) }

    /// 四象限没单独设置时的预设：重要紧急的说快一点、提示音换成 Hero，其他和默认一样。
    static func presetStyle(_ quadrant: Quadrant, base: ReminderVoiceStyle) -> ReminderVoiceStyle {
        var result = base
        if quadrant == .importantUrgent {
            result.rate = max(base.rate, 230)
            result.chime = base.chime.isEmpty ? "" : "Hero"
        }
        return result
    }

    func style(for quadrant: Quadrant) -> ReminderVoiceStyle {
        guard perQuadrant else { return style }
        return quadrantStyles[Self.quadrantKey(quadrant)] ?? Self.presetStyle(quadrant, base: style)
    }

    /// 当前用的三句：打开「播报日程标题」时是带 {时间}{标题} 的模板。
    var currentTexts: [String] {
        let lines = speakTitle ? titleTemplates : texts
        let defaults = speakTitle ? Self.defaultTemplates : Self.defaultTexts
        return (0..<3).map { $0 < lines.count ? lines[$0] : defaults[$0] }
    }

    mutating func setText(_ text: String, at index: Int) {
        guard (0..<3).contains(index) else { return }
        var lines = currentTexts
        lines[index] = String(text.prefix(Self.maxCharacters))
        if speakTitle { titleTemplates = lines } else { texts = lines }
    }

    /// 第 attempt 次提醒要念的话（1 是第 1 次，3 及以后是最后一次）。空着的用默认文案。
    func spokenText(attempt: Int, title: String, clock: String) -> String {
        let index = min(max(attempt, 1), 3) - 1
        var text = currentTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = (speakTitle ? Self.defaultTemplates : Self.defaultTexts)[index] }
        text = String(text.prefix(Self.maxCharacters))
        if speakTitle {
            let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleCharacters))
            text = text.replacingOccurrences(of: "{标题}", with: name.isEmpty ? "日程" : name)
                .replacingOccurrences(of: "{时间}", with: clock)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "，, "))
    }

    func spec(attempt: Int, style: ReminderVoiceStyle, title: String, clock: String) -> ReminderSoundSpec {
        ReminderSoundSpec(text: spokenText(attempt: attempt, title: title, clock: clock), voice: style.cloudVoice,
                          rate: style.rate, chime: style.chime, model: cloudModel)
    }

    /// 一条提醒用什么声音。
    func choice(attempt: Int, quadrant: Quadrant, title: String, clock: String) -> ReminderSoundChoice {
        switch source {
        case .systemDefault:
            return .systemDefault
        case .systemSound:
            return systemSound.isEmpty ? .systemDefault
                : .rendered(ReminderSoundSpec(text: "", voice: "", rate: 0, chime: systemSound))
        case .voice:
            let spec = spec(attempt: attempt, style: style(for: quadrant), title: title, clock: clock)
            return spec.isEmpty ? .systemDefault : .rendered(spec)
        }
    }

    static func load() -> ReminderSoundSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(ReminderSoundSettings.self, from: data) else {
            return ReminderSoundSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

extension ReminderSoundSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decodeIfPresent(ReminderSoundSource.self, forKey: .source) { source = value }
        if let value = try? c.decodeIfPresent(String.self, forKey: .systemSound) { systemSound = value }
        if let value = try? c.decodeIfPresent(ReminderVoiceStyle.self, forKey: .style) { style = value }
        if let value = try? c.decodeIfPresent([String].self, forKey: .texts) { texts = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .speakTitle) { speakTitle = value }
        if let value = try? c.decodeIfPresent([String].self, forKey: .titleTemplates) { titleTemplates = value }
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .perQuadrant) { perQuadrant = value }
        if let value = try? c.decodeIfPresent([String: ReminderVoiceStyle].self, forKey: .quadrantStyles) {
            quadrantStyles = value
        }
        if let value = try? c.decodeIfPresent(String.self, forKey: .cloudModel), !value.isEmpty { cloudModel = value }
    }
}

struct ReminderSoundError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 合成

enum ReminderSoundSynth {
    static let sampleRate: Double = 44_100
    static let maxSeconds: Double = 29

    /// 开发版和正式版用不同前缀，清理时不会删掉对方的文件。
    static let filePrefix: String = {
        let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        return dev ? "Biandan-dev-" : "Biandan-app-"
    }()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// /System/Library/Sounds 里的系统音效名（不带扩展名）。
    static let systemSounds: [String] = {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = items.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
        return names.isEmpty ? ["Glass", "Hero", "Ping", "Pop", "Submarine", "Tink"] : names
    }()

    static func chimeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    }

    /// 内容相同文件名就相同；改了文字、音色、模型、语速或提示音就是新文件。
    /// 第二段沿用以前的写法（有文字是 minimax，只有提示音是 local），已经合成好的声音升级后照常用，不用重新计费。
    static func fileName(_ spec: ReminderSoundSpec) -> String {
        let kind = spec.text.isEmpty ? "local" : "minimax"
        let key = "v2|\(kind)|\(spec.model)|\(spec.text)|\(spec.voice)|\(spec.rate)|\(spec.chime)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return filePrefix + digest.prefix(16) + ".caf"
    }

    /// 合成并存进 ~/Library/Sounds，返回文件名（已经有了就直接返回）。耗时，不要在主线程调用。
    static func render(_ spec: ReminderSoundSpec) async throws -> String {
        guard !spec.isEmpty else { throw ReminderSoundError(message: "没有要播放的内容") }
        let name = fileName(spec)
        let target = directory.appendingPathComponent(name)
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { return name }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw ReminderSoundError(message: "无法创建音频格式")
        }
        var parts: [AVAudioPCMBuffer] = []
        if !spec.chime.isEmpty, manager.fileExists(atPath: chimeURL(spec.chime).path) {
            parts.append(try load(chimeURL(spec.chime), as: format))
            if !spec.text.isEmpty { parts.append(try silence(0.15, format: format)) }
        }
        if !spec.text.isEmpty {
            let speech = try await MiniMaxSpeech.synthesizeFile(spec)
            defer { try? manager.removeItem(at: speech) }
            parts.append(try load(speech, as: format))
        }
        guard !parts.isEmpty else { throw ReminderSoundError(message: "找不到提示音「\(spec.chime)」") }
        let joined = try concatenate(parts, format: format)
        let temporary = manager.temporaryDirectory.appendingPathComponent("biandan-sound-\(UUID().uuidString).caf")
        try write(joined, to: temporary)
        if manager.fileExists(atPath: target.path) {
            try? manager.removeItem(at: temporary)
        } else {
            try manager.moveItem(at: temporary, to: target)
        }
        return name
    }

    /// 删掉本版本不再使用的声音文件。
    static func prune(keeping names: Set<String>) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for item in items where item.hasPrefix(filePrefix) && !names.contains(item) {
            try? manager.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    // MARK: 内部

    /// 读一个音频文件并转成目标格式（单声道、44.1kHz、Float32）。
    private static func load(_ url: URL, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let frames = AVAudioFrameCount(max(file.length, 1))
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else {
            throw ReminderSoundError(message: "读取音频失败")
        }
        try file.read(into: input)
        if source == format { return input }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw ReminderSoundError(message: "无法转换音频格式")
        }
        // 系统音效多是双声道，合成单声道时混音，而不是只取一个声道。
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / source.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ReminderSoundError(message: "转换音频失败")
        }
        var delivered = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if delivered {
                state.pointee = .endOfStream
                return nil
            }
            delivered = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw failure ?? ReminderSoundError(message: "转换音频失败") }
        return output
    }

    private static func silence(_ seconds: Double, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { throw ReminderSoundError(message: "创建静音失败") }
        data.update(repeating: 0, count: Int(frames))
        buffer.frameLength = frames
        return buffer
    }

    /// 依次拼起来，最长 maxSeconds 秒。
    private static func concatenate(_ parts: [AVAudioPCMBuffer], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let limit = Int(maxSeconds * format.sampleRate)
        let total = min(parts.reduce(0) { $0 + Int($1.frameLength) }, limit)
        guard total > 0, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let target = output.floatChannelData?[0] else { throw ReminderSoundError(message: "声音是空的") }
        var offset = 0
        for part in parts {
            guard let source = part.floatChannelData?[0] else { continue }
            let count = min(Int(part.frameLength), total - offset)
            guard count > 0 else { break }
            (target + offset).update(from: source, count: count)
            offset += count
        }
        output.frameLength = AVAudioFrameCount(offset)
        return output
    }

    /// 16 位线性 PCM 的 CAF；函数返回时文件关闭。
    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

// MARK: - 试听

@MainActor
enum ReminderSoundPlayer {
    private static var current: NSSound?

    /// 合成并播放，等放完再返回；失败时返回原因。
    static func play(_ choice: ReminderSoundChoice) async -> String? {
        current?.stop()
        switch choice {
        case .systemDefault:
            NSSound.beep()
            try? await Task.sleep(nanoseconds: 600_000_000)
            return nil
        case .rendered(let spec):
            do {
                let name = try await Task.detached { try await ReminderSoundSynth.render(spec) }.value
                let url = ReminderSoundSynth.directory.appendingPathComponent(name)
                guard let sound = NSSound(contentsOf: url, byReference: true) else { return "读不了生成的声音文件" }
                current = sound
                sound.play()
                try? await Task.sleep(nanoseconds: UInt64(max(sound.duration, 0.3) * 1_000_000_000))
                return nil
            } catch {
                return "生成声音失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - AI 写文案（DeepSeek，只生成文字，语音由 MiniMax 合成）

enum ReminderCopyStyle: String, CaseIterable, Sendable {
    case formal, casual, humor, gentle

    var title: String {
        switch self {
        case .formal: return "正式"
        case .casual: return "轻松"
        case .humor: return "幽默"
        case .gentle: return "温柔"
        }
    }

    var prompt: String {
        switch self {
        case .formal: return "正式、简洁，像专业助理"
        case .casual: return "轻松、口语化，像朋友提醒"
        case .humor: return "幽默俏皮，但不油腻、不冒犯"
        case .gentle: return "温柔体贴，语气柔和"
        }
    }
}

enum ReminderCopywriter {
    static func systemPrompt(speakTitle: Bool) -> String {
        let placeholder = speakTitle
            ? "每句都必须包含占位符 {标题}，first 还要包含 {时间}；占位符原样保留，朗读时会换成日程标题和时刻。"
            : "不要写具体日程内容，也不要用任何占位符。"
        return """
        你是「便单」的提醒文案助手，为日程提醒写会被语音朗读的中文短句。
        每组三句：first 是到点时的第 1 次提醒；second 是 15 分钟后还没处理时的追加提醒；last 是再过 1 小时的最后一次提醒。三句语气逐次加重，但保持礼貌。
        每句不超过 25 个字，口语化、适合朗读，不要表情符号、英文、引号和特殊符号。\(placeholder)
        给出 4 组不同的写法，只输出 JSON：{"sets": [{"first": "", "second": "", "last": ""}]}
        """
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        return URLSession(configuration: configuration)
    }()

    static func generate(style: ReminderCopyStyle, speakTitle: Bool,
                         settings: AIExtractionSettings) async throws -> [[String]] {
        guard let key = settings.apiKey, !key.isEmpty else {
            throw AIExtractionError(message: "先在下面「AI 识别日程」里填写 DeepSeek API Key")
        }
        let base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = URL(string: base.isEmpty ? AIExtractionSettings.defaultBaseURL : base), let host = root.host else {
            throw AIExtractionError(message: "接口地址无效：\(base)")
        }
        var request = URLRequest(url: root.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": systemPrompt(speakTitle: speakTitle)],
                ["role": "user", "content": "风格：\(style.prompt)"],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 1.0,
            "max_tokens": 800,
            "stream": false,
        ]
        if host.contains("deepseek") { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIExtractionError(message: "连不上 \(host)：\(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw AIExtractionError(message: status == 401 ? "API Key 无效或已失效" : "AI 请求失败（\(status)）\(detail)")
        }
        let content = (((json?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String ?? ""
        let sets = parse(content)
        guard !sets.isEmpty else { throw AIExtractionError(message: "AI 没有返回可用的文案，再试一次") }
        return sets
    }

    /// 解析 {"sets": [{"first", "second", "last"}]}；容忍外面包了代码块。每句截到文案上限，最多 5 组。
    static func parse(_ content: String) -> [[String]] {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any],
              let sets = object["sets"] as? [[String: Any]] else { return [] }
        let result: [[String]] = sets.compactMap { set in
            let lines = ["first", "second", "last"].map { key in
                String(((set[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(ReminderSoundSettings.maxCharacters))
            }
            return lines.contains(where: \.isEmpty) ? nil : lines
        }
        return Array(result.prefix(5))
    }
}
