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

// MARK: - 换行排列：放不下就换到下一行，同一行里上下居中

struct CaptureFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var sizes: [CGSize] = []
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + size.width > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append(index)
            sizes.append(size)
            x += size.width + spacing
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var lineX: CGFloat = 0
            for index in line {
                let size = sizes[index]
                frames[index] = CGRect(x: lineX, y: y + (height - size.height) / 2, width: size.width, height: size.height)
                lineX += size.width + spacing
            }
            widest = max(widest, lineX - spacing)
            y += height + lineSpacing
        }
        return (CGSize(width: widest, height: max(y - lineSpacing, 0)), frames)
    }
}

// MARK: - 识别过程：每一步一个彩色小胶囊，按先后排；跳过的一步用灰色虚线框，鼠标移上去看原因

extension CaptureStage {
    /// 截图灰、文字识别青、AI 决策青蓝（和浮窗球判断时的光弧同色）、端侧模型琥珀、规则识别棕灰、AI 识别蓝。
    var tint: Color {
        switch self {
        case .capture: return Color(hex: 0x8A8577)
        case .ocr: return Color(hex: 0x2BB5B0)
        case .decision: return Color(hex: 0x0FA5C9)
        case .model: return Theme.accent
        case .rules: return Color(hex: 0xA79F8E)
        case .ai: return Quadrant.notImportantUrgent.tint
        }
    }
}

struct CaptureStageStrip: View {
    let timings: [CaptureStageTiming]

    var body: some View {
        let total = timings.reduce(0) { $0 + $1.ms }
        CaptureFlowLayout(spacing: 4, lineSpacing: 5) {
            Text("识别过程")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.subtext)
                .padding(.trailing, 2)
            ForEach(timings.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.fieldName)
                    }
                    CaptureStageChip(timing: timings[index])
                }
            }
            Text(verbatim: "合计 " + CaptureTimingLog.duration(total))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .padding(.leading, 4)
        }
    }
}

private struct CaptureStageChip: View {
    let timing: CaptureStageTiming

    var body: some View {
        let skipped = timing.skipped != nil
        let tint: Color = skipped ? Theme.subtext : timing.stage.tint
        let fill: Double = skipped ? 0.04 : 0.12
        HStack(spacing: 4) {
            Text(verbatim: timing.stage.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(verbatim: detail)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint.opacity(0.85))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(fill)))
        .overlay(border(tint: tint, skipped: skipped))
        .help(helpText)
    }

    @ViewBuilder
    private func border(tint: Color, skipped: Bool) -> some View {
        if skipped {
            Capsule().stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else {
            Capsule().stroke(tint.opacity(0.35), lineWidth: 1)
        }
    }

    private var detail: String {
        if timing.skipped != nil { return "· 跳过" }
        var text = CaptureTimingLog.duration(timing.ms)
        if timing.interrupted {
            text += " · 已中断"
        } else if let warm = timing.warm {
            text += warm ? " · 已预热" : " · 未预热"
        }
        return text
    }

    private var helpText: String {
        if let skipped = timing.skipped { return timing.stage.title + "没有运行：" + skipped }
        return timing.stage.title + " 用时 " + CaptureTimingLog.duration(timing.ms)
    }
}
