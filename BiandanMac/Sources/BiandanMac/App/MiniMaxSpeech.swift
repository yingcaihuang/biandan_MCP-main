import Foundation
import Security

// MARK: - MiniMax 在线语音合成（国内版 api.minimax.cn）
//
// 文档：https://platform.minimax.cn/docs/api-reference/speech-t2a-http.md（POST /v1/t2a_v2，非流式时 data.audio 为 hex）
//      https://platform.minimax.cn/docs/api-reference/voice-management-get.md（POST /v1/get_voice）
// API Key 存在钥匙串里，不写进任何文件。只发送要念的那一句话。

enum ReminderVoiceEngine: String, CaseIterable, Codable, Sendable {
    case local, minimax

    var title: String {
        switch self {
        case .local: return "本机"
        case .minimax: return "MiniMax"
        }
    }
}

// MARK: - API Key（钥匙串）

enum MiniMaxKeyStore {
    private static let service = "ai.racore.BiandanMac"
    private static let account = "minimax-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        if DebugFlags.offline { return nil }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "便单 MiniMax API Key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ReminderSoundError(message: "无法把 MiniMax Key 存进钥匙串（\(status)）")
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - 音色

struct MiniMaxVoice: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String

    var title: String { name.isEmpty ? id : name }

    var isChinese: Bool {
        id.hasPrefix("Chinese") || id.hasPrefix("Cantonese")
            || ["普通话", "中文", "粤语", "国语"].contains { summary.contains($0) }
    }
}

extension ReminderSoundSpec {
    /// MiniMax 失败时改用本机语音念同一句（婷婷）。
    var localFallback: ReminderSoundSpec {
        ReminderSoundSpec(text: text, voice: "", rate: rate, chime: chime)
    }
}

// MARK: - 请求

enum MiniMaxSpeech {
    static let baseURL = URL(string: "https://api.minimax.cn")!
    static let defaultModel = "speech-2.8-hd"
    static let models: [(value: String, title: String)] = [("speech-2.8-hd", "HD 音质好"), ("speech-2.8-turbo", "Turbo 更快")]
    static let defaultVoice = "Chinese (Mandarin)_News_Anchor"
    /// 还没读到音色列表时先用这几个（来自 MiniMax 文档）。
    static let presetVoices: [MiniMaxVoice] = [
        MiniMaxVoice(id: "Chinese (Mandarin)_News_Anchor", name: "新闻女声", summary: "专业播音腔的中年女声，标准普通话"),
        MiniMaxVoice(id: "Chinese (Mandarin)_Reliable_Executive", name: "沉稳高管", summary: "沉稳可靠的中年男声，标准普通话"),
        MiniMaxVoice(id: "Chinese (Mandarin)_Lyrical_Voice", name: "Lyrical Voice", summary: "中文"),
        MiniMaxVoice(id: "Chinese (Mandarin)_HK_Flight_Attendant", name: "HK Flight Attendant", summary: "中文"),
    ]
    static let sampleRate = 44_100

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// 本机语速（每分钟字词数，190 为正常）换成 MiniMax 的 speed（0.5–2，1 为正常）。
    static func speed(forRate rate: Int) -> Double {
        guard rate > 0 else { return 1 }
        return min(max((Double(rate) / 190 * 10).rounded() / 10, 0.5), 2)
    }

    static func requestBody(_ spec: ReminderSoundSpec) -> [String: Any] {
        let voiceID = spec.voice.isEmpty ? defaultVoice : spec.voice
        let voice: [String: Any] = ["voice_id": voiceID, "speed": speed(forRate: spec.rate), "vol": 1, "pitch": 0]
        let audio: [String: Any] = ["sample_rate": sampleRate, "format": "wav", "channel": 1]
        return [
            "model": spec.model.isEmpty ? defaultModel : spec.model,
            "text": spec.text,
            "stream": false,
            "voice_setting": voice,
            "audio_setting": audio,
            "language_boost": voiceID.hasPrefix("Cantonese") ? "Chinese,Yue" : "Chinese",
            "output_format": "hex",
        ]
    }

    /// 合成一句话，写成临时 wav 文件（调用方用完删掉）。
    static func synthesizeFile(_ spec: ReminderSoundSpec) async throws -> URL {
        guard let key = MiniMaxKeyStore.load() else {
            throw ReminderSoundError(message: "还没有填写 MiniMax API Key")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/t2a_v2"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(spec))
        let (data, status) = try await send(request)
        let audio = try audio(fromResponse: data, httpStatus: status)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("biandan-minimax-\(UUID().uuidString).wav")
        try audio.write(to: url)
        return url
    }

    /// 当前账号可用的系统音色，中文在前。
    static func fetchVoices() async throws -> [MiniMaxVoice] {
        guard let key = MiniMaxKeyStore.load() else {
            throw ReminderSoundError(message: "还没有填写 MiniMax API Key")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/get_voice"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["voice_type": "system"])
        let (data, status) = try await send(request)
        return try voices(fromResponse: data, httpStatus: status)
    }

    // MARK: 解析（纯函数，便于测试）

    static func audio(fromResponse data: Data, httpStatus: Int = 200) throws -> Data {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        try check(json, httpStatus: httpStatus)
        guard let hex = (json?["data"] as? [String: Any])?["audio"] as? String, !hex.isEmpty,
              let audio = hexDecode(hex), !audio.isEmpty else {
            throw ReminderSoundError(message: "MiniMax 没有返回音频")
        }
        return audio
    }

    static func voices(fromResponse data: Data, httpStatus: Int = 200) throws -> [MiniMaxVoice] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        try check(json, httpStatus: httpStatus)
        let items = json?["system_voice"] as? [[String: Any]] ?? []
        let voices: [MiniMaxVoice] = items.compactMap { item in
            guard let id = item["voice_id"] as? String, !id.isEmpty else { return nil }
            let summary = (item["description"] as? [String] ?? []).joined(separator: " ")
            return MiniMaxVoice(id: id, name: item["voice_name"] as? String ?? "", summary: summary)
        }
        return voices.filter(\.isChinese) + voices.filter { !$0.isChinese }
    }

    static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    // MARK: 内部

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .timedOut {
            throw ReminderSoundError(message: "MiniMax 响应超时，稍后再试")
        } catch {
            throw ReminderSoundError(message: "连不上 MiniMax：\(error.localizedDescription)")
        }
    }

    private static func check(_ json: [String: Any]?, httpStatus: Int) throws {
        let base = json?["base_resp"] as? [String: Any]
        let code = (base?["status_code"] as? NSNumber)?.intValue
        if code == 0 || (code == nil && httpStatus == 200 && json != nil) { return }
        let message = base?["status_msg"] as? String ?? ""
        throw ReminderSoundError(message: describe(code ?? httpStatus, message))
    }

    private static func describe(_ code: Int, _ message: String) -> String {
        let suffix = message.isEmpty ? "" : "：" + message
        switch code {
        case 1004, 401: return "MiniMax API Key 无效或已失效，请在设置里重新填写"
        case 1002, 1039, 429: return "MiniMax 请求太频繁，稍后再试"
        case 1042: return "文案里无法识别的字符太多"
        case 2013: return "MiniMax 请求参数有误" + suffix
        default: return "MiniMax 返回错误（\(code)）" + suffix
        }
    }
}
