import SwiftUI

/// 完成率圆环的配色：0% 红 → 100% 绿，中间经过红橙、橙、琥珀、金黄、黄绿、浅绿，按 RGB 线性插值。
enum ProgressPalette {
    static let stops: [(location: Double, hex: UInt32)] = [
        (0.00, 0xD93025), // 红
        (0.15, 0xE8562E), // 红橙
        (0.30, 0xF08A24), // 橙
        (0.45, 0xF5A800), // 琥珀
        (0.60, 0xF2C511), // 金黄
        (0.75, 0xB5C832), // 黄绿
        (0.88, 0x7DBE48), // 浅绿
        (1.00, 0x43A047), // 绿
    ]

    static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// ratio（0–1）处的颜色分量。
    static func components(at ratio: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max(ratio.isFinite ? ratio : 0, 0), 1)
        for index in 1..<stops.count where t <= stops[index].location {
            let lower = stops[index - 1], upper = stops[index]
            let span = upper.location - lower.location
            let f = span > 0 ? (t - lower.location) / span : 0
            let a = rgb(lower.hex), b = rgb(upper.hex)
            return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
        }
        return rgb(stops[stops.count - 1].hex)
    }

    static func color(at ratio: Double) -> Color {
        let c = components(at: ratio)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// 沿圆环一整圈的渐变（12 点钟方向起笔，顺时针）。
    static var gradient: Gradient {
        Gradient(stops: stops.map { .init(color: Color(hex: $0.hex), location: $0.location) })
    }
}
