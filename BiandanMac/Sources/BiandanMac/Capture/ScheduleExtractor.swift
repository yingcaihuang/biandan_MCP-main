import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 从识别出的文字里提取日程：macOS 26 起用系统端侧大模型，用不了时退回规则识别

enum ScheduleExtractionSource: Sendable {
    case model, rules

    var title: String { self == .model ? "端侧模型" : "规则识别" }
}

struct ScheduleExtraction {
    var candidates: [ScheduleCandidate]
    var source: ScheduleExtractionSource
    /// 说明，例如为什么退回了规则识别、文字太长只识别了一部分。
    var note: String?
}

struct ScheduleExtractionFailure: Error {
    let message: String
}

/// 「端侧模型暂不可用」这类说明同一个原因只提示一次，之后只靠标题旁的「规则识别」标签。
enum FallbackNotice {
    static let key = "biandan.capture.fallbackNotice"

    static func once(_ message: String) -> String? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == message { return nil }
        defaults.set(message, forKey: key)
        return message
    }
}

enum ScheduleExtractor {
    static func extract(_ lines: [CaptureLine], today: LocalDate, weekStart: Int,
                        lists: [(id: String, name: String)]) async -> ScheduleExtraction {
        var note: String?
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            do {
                let (candidates, modelNote) = try await ModelScheduleExtractor.extract(lines, today: today)
                return ScheduleExtraction(candidates: candidates, source: .model, note: modelNote)
            } catch let failure as ScheduleExtractionFailure {
                note = FallbackNotice.once("端侧模型暂不可用（\(failure.message)），当前用规则识别")
            } catch {
                note = "端侧模型没能处理这段文字（\(error.localizedDescription)），已改用规则识别"
            }
        } else {
            note = FallbackNotice.once("端侧模型需要 macOS 26 及以上，当前用规则识别")
        }
        #else
        note = FallbackNotice.once("当前版本没有端侧模型，用规则识别")
        #endif
        let candidates = RuleScheduleExtractor.extract(lines, today: today, weekStart: weekStart, lists: lists)
        return ScheduleExtraction(candidates: candidates, source: .rules, note: note)
    }
}

#if canImport(FoundationModels)

@available(macOS 26, *)
@Generable
struct GeneratedSchedules {
    @Guide(description: "文字里提到的全部日程安排；没有日程时为空数组")
    var events: [GeneratedEvent]
}

@available(macOS 26, *)
@Generable
struct GeneratedEvent {
    @Guide(description: "简短的事项标题，例如「和腾讯开会」「项目评审」，不要包含日期和时间")
    var title: String
    @Guide(description: "开始日期，格式 yyyy-MM-dd；文字里完全没有日期时为空字符串")
    var startDate: String
    @Guide(description: "开始时刻，24 小时制 HH:mm；没有具体时刻时为空字符串")
    var startTime: String
    @Guide(description: "结束日期，格式 yyyy-MM-dd；和开始同一天或没提到时为空字符串")
    var endDate: String
    @Guide(description: "结束时刻，24 小时制 HH:mm；没提到时为空字符串")
    var endTime: String
    @Guide(description: "地点；没提到时为空字符串")
    var location: String
    @Guide(description: "这条日程依据的原文片段，原样摘录")
    var source: String
}

@available(macOS 26, *)
enum ModelScheduleExtractor {
    /// 端侧模型上下文较短，文字太长时只取最后一部分（聊天记录最新的消息在最下面）。
    static let maxCharacters = 2400

    static let instructions = """
    你是日程提取助手。用户会给你一段从屏幕上识别出的文字，通常是微信、飞书等聊天记录，也可能是通知或文档。
    请找出其中明确的日程安排：会议、约会、活动、出行、截止时间等。
    规则：
    1. 把「今天、明天、后天、周四、下周一、月底」这类相对日期换算成具体日期 yyyy-MM-dd。
       换算基准是这句话所在消息的发送日期：文字中的【消息时间：yyyy-MM-dd 周X】标出了它后面那些消息的发送日期；
       没有标注时以「今天」为准。
    2. 「下午3点」换成 15:00，「晚上7点半」换成 19:30；只说了上午、下午而没有具体时刻时，时刻留空。
    3. 只输出文字里确实存在的日程，不要编造；闲聊、问候、已经取消的安排不算。同一件事只输出一次。
    4. 标题要简短，不包含日期和时间。
    """

    static func extract(_ lines: [CaptureLine], today: LocalDate) async throws -> ([ScheduleCandidate], String?) {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw ScheduleExtractionFailure(message: "这台 Mac 暂不支持 Apple 智能")
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ScheduleExtractionFailure(message: "没有开启 Apple 智能（系统设置 → Apple 智能与 Siri）")
        case .unavailable(.modelNotReady):
            throw ScheduleExtractionFailure(message: "端侧模型还在下载或准备中")
        case .unavailable:
            throw ScheduleExtractionFailure(message: "端侧模型暂时不可用")
        @unknown default:
            throw ScheduleExtractionFailure(message: "端侧模型暂时不可用")
        }

        var body = ChatTimestamp.promptText(lines)
        var note: String?
        if body.count > maxCharacters {
            body = String(body.suffix(maxCharacters))
            note = "文字较长，只识别了最后一部分"
        }
        let weekday = LocalDate.weekdayNames[today.weekday]
        let prompt = "今天是 \(today.iso)（\(weekday)）。\n\n以下是要识别的文字：\n\(body)"

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: GeneratedSchedules.self)
        let candidates = response.content.events.compactMap { event in
            ScheduleCandidate.fromModel(title: event.title, startDate: event.startDate, startTime: event.startTime,
                                        endDate: event.endDate, endTime: event.endTime, location: event.location,
                                        source: event.source, today: today)
        }
        return (candidates, note)
    }
}

#endif
