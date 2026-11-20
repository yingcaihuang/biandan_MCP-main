import SwiftUI

/// 快速添加的解析结果。`date` 只有在 `dateSet` 为 true 时才覆盖默认日期（nil 表示无日期）。
struct QuickAddDraft: Equatable {
    var title: String
    var dateSet = false
    var date: LocalDate?
    var important: Bool?
    var urgent: Bool?
}

/// 解析快速添加栏的文字。只识别用空格隔开的关键词，避免把「明天的会议」拆开。
enum QuickAddParser {
    static func parse(_ text: String, today: LocalDate) -> QuickAddDraft {
        var draft = QuickAddDraft(title: "")
        var words: [String] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "\t" }).map(String.init) {
            switch token {
            case "今天": draft.dateSet = true; draft.date = today
            case "明天": draft.dateSet = true; draft.date = today.adding(days: 1)
            case "后天": draft.dateSet = true; draft.date = today.adding(days: 2)
            case "无日期": draft.dateSet = true; draft.date = nil
            case "#重要", "＃重要": draft.important = true
            case "#紧急", "＃紧急": draft.urgent = true
            default: words.append(token)
            }
        }
        draft.title = words.joined(separator: " ")
        return draft
    }

    /// 按当前侧栏的默认值补齐，生成新建参数；标题为空时返回 nil。
    static func input(_ draft: QuickAddDraft, preset: NewTaskPreset) -> CreateTaskInput? {
        guard !draft.title.isEmpty else { return nil }
        var input = CreateTaskInput(title: draft.title)
        input.listID = preset.listID
        input.important = draft.important ?? preset.important
        input.urgent = draft.urgent ?? preset.urgent
        let date = draft.dateSet ? draft.date : preset.date
        input.startDate = date
        input.endDate = date
        return input
    }
}

/// 内容区顶部的快速添加栏：输入标题回车即新建，默认值与新建弹窗相同。
struct QuickAddBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var saving = false

    var body: some View {
        let draft = QuickAddParser.parse(text, today: model.today)
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            TextField("", text: $text,
                      prompt: Text("快速添加任务，回车保存（可加「明天」「后天」「无日期」「#重要」「#紧急」）"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { submit(draft) }
                .disabled(saving || model.authState != .signedIn)
            if saving {
                ProgressView().controlSize(.small)
            } else if !draft.title.isEmpty {
                Text(verbatim: hint(draft))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private func hint(_ draft: QuickAddDraft) -> String {
        let preset = model.makeNewTaskPreset()
        guard let input = QuickAddParser.input(draft, preset: preset) else { return "" }
        var parts: [String] = []
        parts.append(input.startDate.map { $0 == model.today ? "今天" : $0.shortTitle } ?? "无日期")
        parts.append(model.snapshot.list(input.listID)?.displayName ?? "默认")
        if input.important { parts.append("重要") }
        if input.urgent { parts.append("紧急") }
        return "↩︎ " + parts.joined(separator: " · ")
    }

    private func submit(_ draft: QuickAddDraft) {
        guard !saving, let input = QuickAddParser.input(draft, preset: model.makeNewTaskPreset()) else { return }
        saving = true
        Task {
            let ok = await model.createTask(input)
            saving = false
            if ok { text = "" }
        }
    }
}
