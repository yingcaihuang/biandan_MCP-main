import Foundation

// MARK: - 快速添加接 AI
//
// 回车后先把这句话交给 AI（和识别日程同一套提示词）整理成标题、日期、时刻、地点、四象限，写得随意也能记规范。
// 「@分类」「#重要」「#紧急」这类明确的标记以本机解析为准；写了重复（AI 不认识）时整句按本机规则。
// 没配置 AI、设置里关掉、超时或失败时按本机规则添加，保证记得下来。网址和邮箱放进备注，不留在标题里。

enum QuickAddAI {
    /// 最多等 AI 这么久，超时按本机规则添加。
    static let timeout: Double = 8

    struct Outcome {
        var input: CreateTaskInput
        var usedAI: Bool
        /// 退回本机规则的原因，或「识别出几条只加了第一条」这类提醒。
        var note: String?
    }

    /// 本机规则：和以前一样，只是把标题里的网址、邮箱挪进备注。
    static func rulesInput(_ draft: QuickAddDraft, preset: NewTaskPreset, text: String) -> CreateTaskInput? {
        guard var input = QuickAddParser.input(draft, preset: preset) else { return nil }
        let split = NoteLinks.strip(input.title)
        if !split.links.isEmpty, !split.rest.isEmpty {
            input.title = split.rest
            input.remark = appendLinks(split.links, to: input.remark)
        }
        return input
    }

    /// AI 整理出的一条 + 本机解析的明确标记 → 新建参数。
    static func merge(_ candidate: ScheduleCandidate, draft: QuickAddDraft, preset: NewTaskPreset,
                      text: String) -> CreateTaskInput? {
        var candidate = candidate
        candidate.source = ""
        if candidate.date == nil {
            candidate.date = draft.dateSet ? draft.date : preset.date
            if candidate.date == nil, candidate.start != nil { candidate.date = draft.today }
        }
        let split = NoteLinks.strip(candidate.title)
        if !split.rest.isEmpty { candidate.title = split.rest }
        // 在某个分类里添加时就放在这个分类；在「全部」「今天」这类地方才用 AI 建议的分类。
        var listID = preset.listID
        if listID == TodoList.defaultID, case .existing(let id) = candidate.category { listID = id }
        if let explicit = draft.listID { listID = explicit }
        guard var input = candidate.input(listID: listID) else { return nil }
        input.important = draft.important ?? (candidate.quadrant.isImportant || preset.important)
        input.urgent = draft.urgent ?? (candidate.quadrant.isUrgent || preset.urgent)
        input.remark = appendLinks(NoteLinks.detect(text).map(\.text), to: input.remark)
        return input
    }

    static func appendLinks(_ links: [String], to remark: String) -> String {
        var lines = remark.isEmpty ? [] : [remark]
        for link in links where !remark.contains(link) && !lines.contains(link) { lines.append(link) }
        return lines.joined(separator: "\n")
    }
}

/// AI 调用结果的中转（超时由另一个任务取消请求）。
@MainActor
private final class QuickAddAIBox {
    var result: Result<AIExtractionResult, Error>?
    var timedOut = false
}

@MainActor
extension AppModel {
    /// 快速添加现在会不会用 AI（界面上显示提示用；真正调用时再读一次钥匙串）。
    var quickAddAIReady: Bool { quickAddUsesAI && aiExtractionMode != .off && aiKeyConfigured }

    /// 快速添加回车后的新建参数。标题为空时返回 nil。
    func quickAddInput(_ text: String, preset: NewTaskPreset) async -> QuickAddAI.Outcome? {
        let draft = parseQuickAdd(text)
        guard let rules = QuickAddAI.rulesInput(draft, preset: preset, text: text) else { return nil }
        let settings = aiExtractionSettings()
        guard quickAddUsesAI, settings.isReady, draft.repeatRule == nil else {
            return QuickAddAI.Outcome(input: rules, usedAI: false, note: nil)
        }
        let lists = snapshot.lists.map { (id: $0.id3, name: $0.displayName) }
        let today = self.today
        let lines = ChatTimestamp.annotate([text], today: today)
        let box = QuickAddAIBox()
        let work = Task { @MainActor in
            do {
                box.result = .success(try await AIScheduleExtractor.extract(lines, today: today, lists: lists,
                                                                            settings: settings, trigger: .quickAdd))
            } catch {
                box.result = .failure(error)
            }
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(QuickAddAI.timeout))
            if box.result == nil {
                box.timedOut = true
                work.cancel()
            }
        }
        await work.value
        timer.cancel()
        if !box.timedOut, case .success(let result)? = box.result {
            let found = ScheduleCategorizer.apply(PriorityCue.apply(result.candidates), lists: lists,
                                                  fallback: preset.listID, allowNew: false)
            if let first = found.first, let input = QuickAddAI.merge(first, draft: draft, preset: preset, text: text) {
                let note: String? = found.count > 1 ? "AI 识别出 \(found.count) 条，只添加了第一条" : nil
                return QuickAddAI.Outcome(input: input, usedAI: true, note: note)
            }
            return QuickAddAI.Outcome(input: rules, usedAI: false, note: "AI 没整理出日程，已按本机规则添加")
        }
        let reason = box.timedOut ? "AI 超过 \(Int(QuickAddAI.timeout)) 秒没返回" : "AI 没成功"
        return QuickAddAI.Outcome(input: rules, usedAI: false, note: reason + "，已按本机规则添加")
    }
}
