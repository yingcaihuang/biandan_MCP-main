import SwiftUI

/// 任务视图顶部的问候卡片与完成率圆环。范围跟随当前视图，时间维度可切换。
struct TodaySummaryCard: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        let progress = model.progressSummary(for: item)
        let label = model.progressLabel(for: item)
        let hour = Calendar.current.component(.hour, from: Date())
        let name = model.profile.displayName
        let greeting: String = name.isEmpty ? Greeting.text(hour: hour) : Greeting.text(hour: hour) + "，" + name
        HStack(spacing: 16) {
            ProgressRing(progress: progress, label: label)
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Greeting.subtitle(progress, label: label))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if item != .undated {
                ThemedSegmented(selection: Binding(get: { model.summaryRange },
                                                   set: { model.summaryRange = $0 }),
                                options: ProgressRange.allCases.map { ThemeOption(value: $0, title: $0.title) })
                    .help("完成率的统计时间范围")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }
}

private struct ProgressRing: View {
    let progress: TodayProgress
    let label: String

    var body: some View {
        let complete = progress.total > 0 && progress.pending == 0
        let tint: Color = complete ? Theme.done : Theme.accent
        ZStack {
            Circle()
                .stroke(Theme.line, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(progress.ratio))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress.ratio)
            Text(progress.percentText)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(Theme.text)
        }
        .frame(width: 52, height: 52)
        .help("\(label)：已完成 \(progress.done) / \(progress.total)")
    }
}
