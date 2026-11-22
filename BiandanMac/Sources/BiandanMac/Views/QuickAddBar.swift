import SwiftUI

/// 内容区顶部的快速添加栏：输入一句话回车即新建，默认值与新建弹窗相同。
/// 默认先交给 AI 整理（见 QuickAddAI）；没配置或失败时按本机规则解析，写法见 QuickAddParser。
struct QuickAddBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var saving = false
    @State private var note: String?
    @FocusState private var focused: Bool

    static let prompt = "快速添加，回车保存（可加：明天 下午3点、周五、11月30日、每周一、@分类、#重要 #紧急）"
    static let aiPrompt = "快速添加，随便写一句回车保存，AI 会整理成标题、时间、地点（@分类、#重要 #紧急 照样有效）"
    static let help = "日期：今天 / 明天 / 后天、周五 / 下周三、11月30日 / 25号\n"
        + "时刻：下午3点 / 3点半 / 15:30-16:30（写了时刻会在该时刻提醒）\n"
        + "重复：每天 / 工作日 / 每周一三五 / 每两周 / 每月15号 / 每年3月5日\n"
        + "其他：@分类 或 #分类、#重要、#紧急、#习惯；可以连写，如「明天下午3点」「每周一8点」\n"
        + "日期和时刻也可以直接写在标题前面，如「后天下午1点跟腾讯开会」「下午3点开会」"

    var body: some View {
        let draft = model.parseQuickAdd(text)
        let ai = model.quickAddAIReady
        HStack(spacing: 8) {
            // 鼠标移到 ＋ 上弹出写法说明（主题样式），点示例填进输入框。
            QuickAddGuideAnchor { example in
                text = text.isEmpty ? example : text + " " + example
                focused = true
            }
            if ai {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .help("回车后先由 AI 整理成标题、日期、时刻、地点；可在「设置 → 高级 → AI 识别日程」里关掉")
            }
            TextField("", text: $text, prompt: Text(ai ? Self.aiPrompt : Self.prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { submit(draft) }
                .onChange(of: text) { _, new in if !new.isEmpty { note = nil } }
                .disabled(saving || model.authState != .signedIn)
            if saving {
                if ai {
                    Text("AI 整理中…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                }
                ProgressView().controlSize(.small)
            } else if !draft.title.isEmpty {
                if let warning = model.quickAddConflictText(draft) {
                    Text(verbatim: warning)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.overdue)
                        .lineLimit(1)
                }
                Text(verbatim: model.quickAddHint(draft))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            } else if let note {
                Text(verbatim: note)
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
        .task { model.refreshAIKeyStatus() }
    }

    private func submit(_ draft: QuickAddDraft) {
        guard !saving, !draft.title.isEmpty else { return }
        let raw = text
        saving = true
        note = nil
        Task {
            guard let outcome = await model.quickAddInput(raw, preset: model.makeNewTaskPreset()) else {
                saving = false
                return
            }
            let ok = await model.createTask(outcome.input)
            saving = false
            if ok {
                text = ""
                note = ["已添加「", outcome.input.title, "」", outcome.note.map { " · " + $0 } ?? ""].joined()
            }
        }
    }
}
