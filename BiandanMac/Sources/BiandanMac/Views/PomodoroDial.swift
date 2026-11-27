import SwiftUI

/// 番茄钟按剩余时间分 4 段配色，每段 25%：绿 → 蓝 → 黄 → 红；暂停时灰色。
enum PomodoroPalette {
    static let phases: [Color] = [Color(hex: 0x5DB65A), Color(hex: 0x4BA9E0), Color(hex: 0xF5B800), Color(hex: 0xE5483A)]

    static func color(_ session: PomodoroSession, at now: Date) -> Color {
        if session.isPaused { return Theme.subtext }
        return phases[PomodoroSession.phase(remainingFraction: session.remainingFraction(at: now))]
    }

    static func percent(_ session: PomodoroSession, at now: Date) -> Int {
        Int((session.remainingFraction(at: now) * 100).rounded())
    }
}

/// 剩余时间圆环：满圈表示刚开始，越转越少。
struct PomodoroDial: View {
    let session: PomodoroSession
    let now: Date
    var size: CGFloat = 18
    var lineWidth: CGFloat = 3

    var body: some View {
        let color = PomodoroPalette.color(session, at: now)
        let fraction = CGFloat(session.remainingFraction(at: now))
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if session.isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 0.9), value: fraction)
    }
}

/// 工具栏番茄钟按钮计时中的样子：彩色圆环 + 大号剩余时间。
struct PomodoroToolbarLabel: View {
    let session: PomodoroSession
    let now: Date

    var body: some View {
        let color = PomodoroPalette.color(session, at: now)
        HStack(spacing: 6) {
            PomodoroDial(session: session, now: now, size: 18, lineWidth: 3)
            Text(PomodoroSession.clock(session.remaining(at: now)))
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .help("番茄钟剩余 \(PomodoroPalette.percent(session, at: now))%" + (session.isPaused ? "（已暂停）" : ""))
    }
}

/// 正在计时的卡片上，快捷图标前面一直显示的倒计时；点它打开卡片上的番茄钟面板。
struct CardPomodoroBadge: View {
    let session: PomodoroSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                badge(now: context.date)
            }
        }
        .buttonStyle(.plain)
        .help(session.isPaused ? "番茄钟已暂停，点开可以继续" : "番茄钟剩余时间，点开可以暂停")
    }

    private func badge(now: Date) -> some View {
        let color = PomodoroPalette.color(session, at: now)
        return HStack(spacing: 5) {
            PomodoroDial(session: session, now: now, size: 15, lineWidth: 2.5)
            Text(PomodoroSession.clock(session.remaining(at: now)))
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(verbatim: "\(PomodoroPalette.percent(session, at: now))%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Theme.card))
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        .contentShape(Capsule())
    }
}
