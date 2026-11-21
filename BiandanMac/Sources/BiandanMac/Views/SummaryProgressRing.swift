import SwiftUI

/// 完成率圆环：圆弧从 12 点钟的红色起笔，沿渐变走到当前完成率对应的颜色（越接近 100% 越绿）。
struct SummaryProgressRing: View {
    let progress: TodayProgress
    let label: String
    var size: CGFloat = 52
    var lineWidth: CGFloat = 6

    var body: some View {
        let ratio = progress.ratio
        let tip = ProgressPalette.color(at: ratio)
        let gradient = AngularGradient(gradient: ProgressPalette.gradient, center: .center,
                                       startAngle: .degrees(-90), endAngle: .degrees(270))
        ZStack {
            Circle()
                .fill(tip.opacity(progress.total > 0 ? 0.10 : 0))
                .padding(lineWidth)
            Circle()
                .stroke(Theme.line, lineWidth: lineWidth)
            if ratio >= 1 {
                // 满分时整圈纯绿，避免 12 点钟处红绿接缝。
                Circle()
                    .stroke(ProgressPalette.color(at: 1), lineWidth: lineWidth)
            } else if ratio > 0 {
                RingArc(progress: ratio, lineWidth: lineWidth)
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                // 起笔圆头（红）与末端圆头（当前颜色）；100% 时末端绿色盖住起笔。
                RingCap(progress: 0, lineWidth: lineWidth)
                    .fill(ProgressPalette.color(at: 0))
                RingCap(progress: ratio, lineWidth: lineWidth)
                    .fill(tip)
                    .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.4)
            }
            Text(progress.percentText)
                .font(.system(size: size * 0.23, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.35), value: ratio)
        .help("\(label)：已完成 \(progress.done) / \(progress.total)")
    }
}

/// 从 12 点钟方向顺时针画到 progress 处的圆弧，可动画。
struct RingArc: Shape {
    var progress: Double
    var lineWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(max(progress, 0), 1)),
                    clockwise: false)
        return path
    }
}

/// 圆弧在 progress 处的圆头，跟着圆弧一起动画。
struct RingCap: Shape {
    var progress: Double
    var lineWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        let angle = (-90 + 360 * min(max(progress, 0), 1)) * Double.pi / 180
        let center = CGPoint(x: rect.midX + radius * CGFloat(cos(angle)), y: rect.midY + radius * CGFloat(sin(angle)))
        return Path(ellipseIn: CGRect(x: center.x - lineWidth / 2, y: center.y - lineWidth / 2,
                                      width: lineWidth, height: lineWidth))
    }
}
