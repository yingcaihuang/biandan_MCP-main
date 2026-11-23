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
        let spec = ReminderSoundSpec(text: "请及时处理", voice: "Cantonese_GentleLady", rate: 230, chime: "",
                                     engine: .minimax, model: "")
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
        let plain = MiniMaxSpeech.requestBody(ReminderSoundSpec(text: "x", voice: "", rate: 190, chime: "", engine: .minimax))
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
        settings.engine = .minimax
        settings.style.cloudVoice = "Chinese (Mandarin)_Reliable_Executive"
        guard case .rendered(let spec) = settings.choice(attempt: 1, quadrant: .neither, title: "", clock: "") else {
            return XCTFail("AI 语音应合成声音")
        }
        XCTAssertEqual(spec.engine, .minimax)
        XCTAssertEqual(spec.voice, "Chinese (Mandarin)_Reliable_Executive")
        XCTAssertEqual(spec.model, MiniMaxSpeech.defaultModel)
        XCTAssertEqual(spec.text, "你有新的日程需要关注，请及时处理")
        // 同一句话换引擎是不同的文件；退回本机时用婷婷。
        XCTAssertNotEqual(ReminderSoundSynth.fileName(spec), ReminderSoundSynth.fileName(spec.localFallback))
        XCTAssertEqual(spec.localFallback.engine, .local)
        XCTAssertEqual(spec.localFallback.voice, "")
        XCTAssertEqual(spec.localFallback.text, spec.text)
        // 本机引擎仍用本机语音。
        settings.engine = .local
        settings.style.voice = "Flo"
        guard case .rendered(let local) = settings.choice(attempt: 1, quadrant: .neither, title: "", clock: "") else {
            return XCTFail("AI 语音应合成声音")
        }
        XCTAssertEqual(local.engine, .local)
        XCTAssertEqual(local.voice, "Flo")
    }

    func testOldSettingsDecodeAsLocal() throws {
        let old = try JSONDecoder().decode(ReminderSoundSettings.self, from: Data(#"{"source":"voice","style":{"voice":"Flo"}}"#.utf8))
        XCTAssertEqual(old.engine, .local)
        XCTAssertEqual(old.cloudModel, MiniMaxSpeech.defaultModel)
        XCTAssertEqual(old.style.cloudVoice, MiniMaxSpeech.defaultVoice)
    }
}
