import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - 从识别出的文字里提取日程：macOS 26 起用系统端侧大模型，用不了时退回规则识别

enum ScheduleExtractionSource: Sendable {
    case model, rules, ai

    var title: String {
        switch self {
        case .model: return "端侧模型"
        case .rules: return "规则识别"
        case .ai: return "AI 识别"
        }
    }

    var help: String {
        switch self {
        case .model: return "用系统端侧模型提取"
        case .rules: return "按规则从句子里找日期和时刻；识别结果可以逐条修改"
        case .ai: return "识别出的文字已发给 AI 大模型提取（不含截图）；识别结果可以逐条修改"
        }
    }
}

struct ScheduleExtraction {
    var candidates: [ScheduleCandidate]
    var source: ScheduleExtractionSource
    /// 说明，例如为什么退回了规则识别、文字太长只识别了一部分。
    var note: String?
    /// 用了 AI 时这次调用的用量（用时、token、费用）。
    var usage: AIUsageRecord? = nil
    /// 用了 AI 决策时这次的判断结果。
    var decision: DecisionRecord? = nil
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

/// 顺序：「总是用 AI」时先用 AI；否则端侧模型 → 规则识别，都没找到日程时再用 AI 兜底（需要已填 API Key）。
enum ScheduleExtractor {
    /// 开了 AI 决策时，调用大模型之前先判断有没有日程：「总是用 AI」被拦下就改用本机识别，
    /// 「规则识别不到时」被拦下就不再兜底。判断失败照常调用。
    static func extract(_ lines: [CaptureLine], today: LocalDate, weekStart: Int,
                        lists: [(id: String, name: String)],
                        ai: AIExtractionSettings = .disabled,
                        decision: DecisionSettings = .disabled,
                        input: CaptureInputSource = .region,
                        onStage: (@MainActor @Sendable (CaptureStage, Bool?) -> Void)? = nil,
                        onSkip: (@MainActor @Sendable (CaptureStage, String) -> Void)? = nil) async -> ScheduleExtraction {
        let box = DecisionBox()
        var result = await extractCore(lines, today: today, weekStart: weekStart, lists: lists, ai: ai,
                                       decision: decision, input: input, box: box, onStage: onStage, onSkip: onSkip)
        result.decision = box.record
        if let record = box.record, record.outcome == .block {
            // 决策模型判断没有日程，本机却找到了：多半是误识别（页码、界面文字），默认不勾选。
            let decider = record.decisionModel ?? DecisionSettings.model
            result.candidates = result.candidates.map { candidate in
                var item = candidate
                item.include = false
                item.note = decider + " 判断这段文字没有日程，可能是误识别，默认不勾选"
                return item
            }
        }
        return result
    }

    private static func extractCore(_ lines: [CaptureLine], today: LocalDate, weekStart: Int,
                                    lists: [(id: String, name: String)], ai: AIExtractionSettings,
                                    decision: DecisionSettings, input: CaptureInputSource, box: DecisionBox,
                                    onStage: (@MainActor @Sendable (CaptureStage, Bool?) -> Void)?,
                                    onSkip: (@MainActor @Sendable (CaptureStage, String) -> Void)?) async -> ScheduleExtraction {
        var note: String?
        var skipAI = false
        if ai.isReady && ai.mode == .always && decision.isReady {
            await onStage?(.decision, nil)
            let found = RuleScheduleExtractor.extract(lines, today: today, weekStart: weekStart, lists: lists)
            let record = await DecisionGate.run(lines, today: today, source: input,
                                                hints: DecisionHints.collect(lines, ruleCandidates: found.count),
                                                settings: decision, ai: ai, trigger: .always)
            box.record = record
            if record.outcome == .block {
                skipAI = true
            }
        }
        if ai.isReady && ai.mode == .always && !skipAI {
            await onStage?(.ai, nil)
            do {
                let result = try await AIScheduleExtractor.extract(lines, today: today, lists: lists,
                                                                   settings: ai, trigger: .always)
                return ScheduleExtraction(candidates: result.candidates, source: .ai, note: result.note(prefix: nil),
                                          usage: result.usage)
            } catch {
                note = "AI 识别没成功（\(error.localizedDescription)），已改用本机识别"
            }
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let reason = ModelScheduleExtractor.unavailableReason() {
                // 用不了就不进这个阶段，免得耗时里出现一段 0 毫秒。
                await onSkip?(.model, reason)
                note = note ?? FallbackNotice.once("端侧模型暂不可用（\(reason)），当前用规则识别")
            } else {
                await onStage?(.model, ModelWarmup.shared.isWarm)
                do {
                    let (candidates, modelNote) = try await ModelScheduleExtractor.extract(lines, today: today)
                    if !candidates.isEmpty || !(ai.isReady && ai.mode == .fallback) {
                        return ScheduleExtraction(candidates: candidates, source: .model, note: note ?? modelNote)
                    }
                } catch let failure as ScheduleExtractionFailure {
                    note = note ?? FallbackNotice.once("端侧模型暂不可用（\(failure.message)），当前用规则识别")
                } catch {
                    note = note ?? "端侧模型没能处理这段文字（\(error.localizedDescription)），已改用规则识别"
                }
            }
        } else {
            note = note ?? FallbackNotice.once("端侧模型需要 macOS 26 及以上，当前用规则识别")
        }
        #else
        note = note ?? FallbackNotice.once("当前版本没有端侧模型，用规则识别")
        #endif
        await onStage?(.rules, nil)
        let candidates = RuleScheduleExtractor.extract(lines, today: today, weekStart: weekStart, lists: lists)
        if candidates.isEmpty && ai.isReady && ai.mode == .fallback {
            if decision.isReady {
                await onStage?(.decision, nil)
                let record = await DecisionGate.run(lines, today: today, source: input,
                                                    hints: DecisionHints.collect(lines, ruleCandidates: 0),
                                                    settings: decision, ai: ai, trigger: .fallback)
                box.record = record
                if record.outcome == .block {
                    return ScheduleExtraction(candidates: [], source: .rules, note: nil)
                }
            }
            await onStage?(.ai, nil)
            do {
                let result = try await AIScheduleExtractor.extract(lines, today: today, lists: lists,
                                                                   settings: ai, trigger: .fallback)
                return ScheduleExtraction(candidates: result.candidates, source: .ai,
                                          note: result.note(prefix: "规则识别没找到日程，已用 AI（\(ai.model)）识别"),
                                          usage: result.usage)
            } catch {
                return ScheduleExtraction(candidates: [], source: .rules,
                                          note: "规则识别没找到日程，AI 识别也没成功：\(error.localizedDescription)")
            }
        }
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

    /// 端侧模型用不了时的原因；能用时为 nil。
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "这台 Mac 不支持 Apple 智能"
        case .unavailable(.appleIntelligenceNotEnabled): return "没有开启 Apple 智能（系统设置 → Apple 智能与 Siri）"
        case .unavailable(.modelNotReady): return "端侧模型还在下载或准备中"
        case .unavailable: return "端侧模型暂时不可用"
        @unknown default: return "端侧模型暂时不可用"
        }
    }

    static func extract(_ lines: [CaptureLine], today: LocalDate) async throws -> ([ScheduleCandidate], String?) {
        if let reason = unavailableReason() { throw ScheduleExtractionFailure(message: reason) }

        var body = ChatTimestamp.promptText(lines)
        var note: String?
        if body.count > maxCharacters {
            body = String(body.suffix(maxCharacters))
            note = "文字较长，只识别了最后一部分"
        }
        let weekday = LocalDate.weekdayNames[today.weekday]
        let prompt = "今天是 \(today.iso)（\(weekday)）。\n\n以下是要识别的文字：\n\(body)"

        // 优先用预热好的对话（模型已在内存里），没有时现建。
        let session = (ModelWarmup.shared.take() as? LanguageModelSession)
            ?? LanguageModelSession(instructions: instructions)
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
