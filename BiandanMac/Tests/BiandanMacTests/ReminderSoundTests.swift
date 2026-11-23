import AVFoundation
import Foundation
import XCTest
@testable import BiandanMac

final class ReminderSoundTests: XCTestCase {
    func testFixedTextsByAttempt() {
        var settings = ReminderSoundSettings()
        settings.source = .voice
        XCTAssertEqual(settings.spokenText(attempt: 1, title: "开会", clock: "10:00"), "你有新的日程需要关注，请及时处理")
        XCTAssertEqual(settings.spokenText(attempt: 2, title: "开会", clock: "10:00"), "这个日程还没处理，再提醒你一下")
        XCTAssertEqual(settings.spokenText(attempt: 3, title: "开会", clock: "10:00"), "最后提醒一次，请尽快处理")
        XCTAssertEqual(settings.spokenText(attempt: 9, title: "开会", clock: "10:00"), "最后提醒一次，请尽快处理")
        // 清空的一句用默认文案。
        settings.setText("  ", at: 1)
        XCTAssertEqual(settings.spokenText(attempt: 2, title: "", clock: ""), "这个日程还没处理，再提醒你一下")
    }

    func testTitleTemplates() {
        var settings = ReminderSoundSettings()
        settings.speakTitle = true
        XCTAssertEqual(settings.spokenText(attempt: 1, title: "产研周例会", clock: "10:00"), "10:00，产研周例会，请及时处理")
        XCTAssertEqual(settings.spokenText(attempt: 3, title: "产研周例会", clock: "10:00"), "最后提醒一次：产研周例会，请尽快处理")
        // 标题太长只念前 30 个字。
        let long = String(repeating: "长", count: 50)
        XCTAssertFalse(settings.spokenText(attempt: 2, title: long, clock: "").contains(String(repeating: "长", count: 31)))
        // 改模板只改播报标题这一套，固定文案不受影响。
        settings.setText("{标题}要开始了", at: 0)
        XCTAssertEqual(settings.spokenText(attempt: 1, title: "打牌", clock: "16:00"), "打牌要开始了")
        XCTAssertEqual(settings.texts, ReminderSoundSettings.defaultTexts)
    }

    func testChoiceBySource() {
        var settings = ReminderSoundSettings()
        XCTAssertEqual(settings.choice(attempt: 1, quadrant: .neither, title: "x", clock: ""), .systemDefault)
        settings.source = .systemSound
        settings.systemSound = "Hero"
        XCTAssertEqual(settings.choice(attempt: 2, quadrant: .neither, title: "x", clock: ""),
                       .rendered(ReminderSoundSpec(text: "", voice: "", rate: 0, chime: "Hero")))
        settings.source = .voice
        guard case .rendered(let spec) = settings.choice(attempt: 1, quadrant: .importantUrgent, title: "x", clock: "") else {
            return XCTFail("AI 语音应合成声音")
        }
        XCTAssertEqual(spec.rate, 190)
        XCTAssertEqual(spec.chime, "Glass")
    }

    func testPerQuadrantStyles() {
        var settings = ReminderSoundSettings()
        settings.source = .voice
        settings.perQuadrant = true
        // 没单独设置：重要紧急用预设（快一点、Hero），其他和默认一样。
        XCTAssertEqual(settings.style(for: .importantUrgent).rate, 230)
        XCTAssertEqual(settings.style(for: .importantUrgent).chime, "Hero")
        XCTAssertEqual(settings.style(for: .neither), settings.style)
        settings.quadrantStyles[ReminderSoundSettings.quadrantKey(.neither)] =
            ReminderVoiceStyle(rate: 150, chime: "", cloudVoice: "Chinese (Mandarin)_Lyrical_Voice")
        guard case .rendered(let spec) = settings.choice(attempt: 1, quadrant: .neither, title: "", clock: "") else {
            return XCTFail("AI 语音应合成声音")
        }
        XCTAssertEqual(spec.voice, "Chinese (Mandarin)_Lyrical_Voice")
        XCTAssertEqual(spec.rate, 150)
        XCTAssertEqual(spec.chime, "")
        // 关掉四象限就都用默认。
        settings.perQuadrant = false
        XCTAssertEqual(settings.style(for: .importantUrgent), settings.style)
    }

    func testFileNameIsStable() {
        let spec = ReminderSoundSpec(text: "请及时处理", voice: "", rate: 190, chime: "Glass")
        XCTAssertEqual(ReminderSoundSynth.fileName(spec), ReminderSoundSynth.fileName(spec))
        XCTAssertTrue(ReminderSoundSynth.fileName(spec).hasPrefix(ReminderSoundSynth.filePrefix))
        XCTAssertTrue(ReminderSoundSynth.fileName(spec).hasSuffix(".caf"))
        var other = spec
        other.rate = 230
        XCTAssertNotEqual(ReminderSoundSynth.fileName(spec), ReminderSoundSynth.fileName(other))
    }

    func testSettingsRoundTripAndMissingFields() throws {
        var settings = ReminderSoundSettings()
        settings.source = .voice
        settings.speakTitle = true
        settings.quadrantStyles["importantUrgent"] = ReminderVoiceStyle(rate: 270, chime: "Ping", cloudVoice: "Chinese (Mandarin)_HK_Flight_Attendant")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ReminderSoundSettings.self, from: data), settings)
        // 旧版本没有的字段用默认值，不认识的来源也不报错。
        let partial = try JSONDecoder().decode(ReminderSoundSettings.self, from: Data(#"{"source":"voice","style":{"rate":150}}"#.utf8))
        XCTAssertEqual(partial.source, .voice)
        XCTAssertEqual(partial.style.rate, 150)
        XCTAssertEqual(partial.style.chime, "Glass")
        XCTAssertEqual(partial.texts, ReminderSoundSettings.defaultTexts)
        let unknown = try JSONDecoder().decode(ReminderSoundSettings.self, from: Data(#"{"source":"cloud"}"#.utf8))
        XCTAssertEqual(unknown.source, .systemDefault)
    }

    /// 真的合成一段只有提示音的声音：单声道 44.1kHz 的 .caf，再删掉。有文字的要调 MiniMax，测试里不联网。
    func testRenderChimeOnly() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ReminderSoundSynth.chimeURL("Hero").path), "没有 Hero")
        let spec = ReminderSoundSpec(text: "", voice: "", rate: 0, chime: "Hero")
        let name = try await ReminderSoundSynth.render(spec)
        let url = ReminderSoundSynth.directory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, ReminderSoundSynth.sampleRate)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertGreaterThan(seconds, 0.1)
        XCTAssertLessThanOrEqual(seconds, ReminderSoundSynth.maxSeconds)
        // 第二次直接用已有文件。
        let again = try await ReminderSoundSynth.render(spec)
        XCTAssertEqual(again, name)
    }

    func testCopywriterParsing() {
        let content = """
        ```json
        {"sets": [{"first": "日程到了，快看看", "second": "还没处理哦", "last": "最后一次啦"},
                  {"first": "只有一句", "second": "", "last": ""}]}
        ```
        """
        XCTAssertEqual(ReminderCopywriter.parse(content), [["日程到了，快看看", "还没处理哦", "最后一次啦"]])
        XCTAssertTrue(ReminderCopywriter.parse("不是 JSON").isEmpty)
    }
}
