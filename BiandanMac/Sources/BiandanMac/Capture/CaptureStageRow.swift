import SwiftUI

// MARK: - 确认卡片里「正在识别」那一行：当前阶段、已用时间；端侧模型或 AI 太慢时可改用规则识别

struct CaptureStageRow: View {
    let state: SchedulePreviewState
    /// 等这么久还没返回，就给出「改用规则识别」。
    static let skipAfter: TimeInterval = 3

    private var text: String {
        guard let stage = state.stage else { return "正在准备…" }
        if stage == .model && state.modelWarm == false {
            return "正在用端侧模型提取日程（第一次使用要先加载模型）…"
        }
        return stage.running
    }

    private var hint: String {
        state.stage == .ai ? "AI 识别还没返回" : "端侧模型第一次加载会慢一些"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = max(context.date.timeIntervalSince(state.stageStart), 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: text).foregroundStyle(Theme.subtext)
                    if state.stage != nil {
                        Text(verbatim: String(format: "%.1f 秒", elapsed))
                            .monospacedDigit()
                            .foregroundStyle(Theme.subtext)
                    }
                }
                if state.canSkipToRules && elapsed >= Self.skipAfter {
                    HStack(spacing: 8) {
                        Text(verbatim: hint + "，可以先用规则识别。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                        Button("改用规则识别") { ScheduleCaptureFlow.useRules() }
                            .buttonStyle(.themed)
                    }
                }
            }
        }
    }
}
