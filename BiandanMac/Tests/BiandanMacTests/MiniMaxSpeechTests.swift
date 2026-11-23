import CryptoKit
import Foundation
import XCTest
@testable import BiandanMac

final class MiniMaxSpeechTests: XCTestCase {
    func testSpeedFromRate() {
        XCTAssertEqual(MiniMaxSpeech.speed(forRate: 150), 0.8, accuracy: 0.001)
        XCTAssertEqual(MiniMaxSpeech.speed(forRate: 190), 1.0, accuracy: 0.001)
        XCTAssertEqual(MiniMaxSpeech.speed(forRate: 230), 1.2, accuracy: 0.001)
        XCTAssertEqual(MiniMaxSpeech.speed(forRate: 270), 1.4, accuracy: 0.001)
        XCTAssertEqual(MiniMaxSpeech.speed(forRate: 1000), 2, accuracy: 0.001)
        XCTAssertEqual(MiniMaxSpeech.speed(forRate: 0), 1, accuracy: 0.001)
    }

    func testRequestBody() {
        let spec = ReminderSoundSpec(text: "请及时处理", voice: "Cantonese_GentleLady", rate: 230, chime: "", model: "")
        let body = MiniMaxSpeech.requestBody(spec)
        XCTAssertEqual(body["model"] as? String, MiniMaxSpeech.defaultModel)
        XCTAssertEqual(body["text"] as? String, "请及时处理")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["output_format"] as? String, "hex")
        XCTAssertEqual(body["language_boost"] as? String, "Chinese,Yue")
        let voice = body["voice_setting"] as? [String: Any]
        XCTAssertEqual(voice?["voice_id"] as? String, "Cantonese_GentleLady")
        XCTAssertEqual(voice?["speed"] as? Double ?? 0, 1.2, accuracy: 0.001)
        let audio = body["audio_setting"] as? [String: Any]
        XCTAssertEqual(audio?["format"] as? String, "wav")
        XCTAssertEqual(audio?["channel"] as? Int, 1)
        XCTAssertEqual(audio?["sample_rate"] as? Int, 44_100)
        // 没选音色用默认，普通话。
        let plain = MiniMaxSpeech.requestBody(ReminderSoundSpec(text: "x", voice: "", rate: 190, chime: ""))
        XCTAssertEqual((plain["voice_setting"] as? [String: Any])?["voice_id"] as? String, MiniMaxSpeech.defaultVoice)
        XCTAssertEqual(plain["language_boost"] as? String, "Chinese")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(plain))
    }

    func testHexDecode() {
        XCTAssertEqual(MiniMaxSpeech.hexDecode("48656c6C6f"), Data("Hello".utf8))
        XCTAssertNil(MiniMaxSpeech.hexDecode("abc"))
        XCTAssertNil(MiniMaxSpeech.hexDecode("zz"))
    }

    func testAudioResponse() throws {
        let ok = Data(#"{"data":{"audio":"52494646","status":2},"base_resp":{"status_code":0,"status_msg":"success"}}"#.utf8)
        XCTAssertEqual(try MiniMaxSpeech.audio(fromResponse: ok), Data("RIFF".utf8))
        let denied = Data(#"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#.utf8)
        XCTAssertThrowsError(try MiniMaxSpeech.audio(fromResponse: denied)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Key"))
        }
        let empty = Data(#"{"data":null,"base_resp":{"status_code":0}}"#.utf8)
        XCTAssertThrowsError(try MiniMaxSpeech.audio(fromResponse: empty))
        XCTAssertThrowsError(try MiniMaxSpeech.audio(fromResponse: Data("<html>".utf8), httpStatus: 502))
    }

    func testVoiceList() throws {
        let data = Data(#"""
        {"system_voice": [
          {"voice_id": "English_Graceful_Lady", "voice_name": "Graceful Lady", "description": ["An elegant female voice"]},
          {"voice_id": "Chinese (Mandarin)_News_Anchor", "voice_name": "新闻女声", "description": ["专业播音腔的中年女性，标准普通话。"]},
          {"voice_id": "", "voice_name": "坏数据"}
        ], "base_resp": {"status_code": 0, "status_msg": "success"}}
        """#.utf8)
        let voices = try MiniMaxSpeech.voices(fromResponse: data)
        XCTAssertEqual(voices.map(\.id), ["Chinese (Mandarin)_News_Anchor", "English_Graceful_Lady"])
        XCTAssertEqual(voices.first?.title, "新闻女声")
    }

    func testSettingsUseMiniMax() {
        var settings = ReminderSoundSettings()
        settings.source = .voice
        settings.style.cloudVoice = "Chinese (Mandarin)_Reliable_Executive"
        guard case .rendered(let spec) = settings.choice(attempt: 1, quadrant: .neither, title: "", clock: "") else {
            return XCTFail("AI 语音应合成声音")
        }
        XCTAssertEqual(spec.voice, "Chinese (Mandarin)_Reliable_Executive")
        XCTAssertEqual(spec.model, MiniMaxSpeech.defaultModel)
        XCTAssertEqual(spec.rate, 190)
        XCTAssertEqual(spec.text, "你有新的日程需要关注，请及时处理")
        // MiniMax 失败时只响提示音。
        XCTAssertEqual(spec.chimeOnly, ReminderSoundSpec(text: "", voice: "", rate: 0, chime: "Glass"))
        XCTAssertNotEqual(ReminderSoundSynth.fileName(spec), ReminderSoundSynth.fileName(spec.chimeOnly))
        var silent = spec
        silent.chime = ""
        XCTAssertTrue(silent.chimeOnly.isEmpty)
    }

    /// 以前选了「本机」引擎的设置：升级后改用 MiniMax 的默认音色，语速和提示音不变。
    func testOldLocalEngineSettingsUseMiniMax() throws {
        let json = #"{"source":"voice","engine":"local","style":{"voice":"Flo","rate":230,"chime":"Ping"}}"#
        let old = try JSONDecoder().decode(ReminderSoundSettings.self, from: Data(json.utf8))
        XCTAssertEqual(old.source, .voice)
        XCTAssertEqual(old.cloudModel, MiniMaxSpeech.defaultModel)
        XCTAssertEqual(old.style, ReminderVoiceStyle(rate: 230, chime: "Ping", cloudVoice: MiniMaxSpeech.defaultVoice))
        guard case .rendered(let spec) = old.choice(attempt: 1, quadrant: .neither, title: "", clock: "") else {
            return XCTFail("AI 语音应合成声音")
        }
        XCTAssertEqual(spec.voice, MiniMaxSpeech.defaultVoice)
        // 再存一次就没有 engine 和旧的语音名了。
        let saved = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(saved.contains("engine"))
        XCTAssertFalse(saved.contains("Flo"))
    }

    /// 文件名沿用以前的写法：已经合成好的 MiniMax 声音和提示音升级后照常用，不重新计费。
    func testFileNameKeepsOldCacheKeys() {
        func expected(_ key: String) -> String {
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return ReminderSoundSynth.filePrefix + digest.prefix(16) + ".caf"
        }
        let speech = ReminderSoundSpec(text: "请及时处理", voice: "Chinese (Mandarin)_News_Anchor", rate: 190,
                                       chime: "Glass", model: "speech-2.8-hd")
        XCTAssertEqual(ReminderSoundSynth.fileName(speech),
                       expected("v2|minimax|speech-2.8-hd|请及时处理|Chinese (Mandarin)_News_Anchor|190|Glass"))
        let chime = ReminderSoundSpec(text: "", voice: "", rate: 0, chime: "Hero")
        XCTAssertEqual(ReminderSoundSynth.fileName(chime), expected("v2|local||||0|Hero"))
    }
}
