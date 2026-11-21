import SwiftUI

/// 「今天」顶部的问候卡片与完成率圆环。
struct TodaySummaryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.todayProgress
        let hour = Calendar.current.component(.hour, from: Date())
        let name = model.profile.displayName
        let greeting: String = name.isEmpty ? Greeting.text(hour: hour) : Greeting.text(hour: hour) + "，" + name
        HStack(spacing: 16) {
            ProgressRing(progress: progress)
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(Greeting.subtitle(progress))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
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
        .help("今日完成 \(progress.done) / \(progress.total)")
    }
}
