import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// 与 UI 原型一致的暖色主题。
enum Theme {
    static let background = Color(hex: 0xF4EFE3)
    static let panel = Color(hex: 0xFBF8F1)
    static let card = Color(hex: 0xFFFDF8)
    static let line = Color(hex: 0xE6DFCF)
    static let text = Color(hex: 0x1F1D1A)
    static let subtext = Color(hex: 0x8A8273)
    static let fieldName = Color(hex: 0xB3AA97)
    static let accent = Color(hex: 0xF5B800)
    static let huawei = Color(hex: 0xCE0E2D)
    static let done = Color(hex: 0x5DB65A)
    static let overdue = Color(hex: 0xD93025)
}

extension Quadrant {
    /// 边框与标题色。
    var tint: Color {
        switch self {
        case .importantUrgent: return Color(hex: 0xE5483A)
        case .importantNotUrgent: return Color(hex: 0xE9BC12)
        case .notImportantUrgent: return Color(hex: 0x4BA9E0)
        case .neither: return Color(hex: 0x5DB65A)
        }
    }

    var titleColor: Color {
        self == .importantNotUrgent ? Color(hex: 0xD9A800) : tint
    }

    /// 象限底色。
    var fill: Color {
        switch self {
        case .importantUrgent: return Color(hex: 0xEFDCD3)
        case .importantNotUrgent: return Color(hex: 0xEEE7CB)
        case .notImportantUrgent: return Color(hex: 0xDCE3DF)
        case .neither: return Color(hex: 0xE0E3CC)
        }
    }
}

extension ListColor {
    var color: Color { Color(hex: hex) }
}

extension TodoList {
    var swatch: Color { color.color }
    var displayName: String { favoritesName.isEmpty ? (isDefault ? "默认" : "未命名") : favoritesName }
}

extension OccurrenceStatus {
    var tint: Color {
        switch self {
        case .pending: return Color(hex: 0x9A7400)
        case .completed: return Color(hex: 0x2F8A2B)
        case .abandoned: return Color(hex: 0x888888)
        }
    }

    var badgeFill: Color {
        switch self {
        case .pending: return Color(hex: 0xFFF1C2)
        case .completed: return Color(hex: 0xDDF0DA)
        case .abandoned: return Color(hex: 0xEEEEEE)
        }
    }
}

/// 云端字段名的小号等宽标注，与原型中的灰色小字一致。
struct FieldTag: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Text(name)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.fieldName)
            .lineLimit(1)
    }
}
