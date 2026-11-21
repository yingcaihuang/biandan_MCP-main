import SwiftUI

// MARK: - 液态玻璃（macOS 26 起），旧系统保持主题原样
//
// 只用于浮在内容上面的控件层（快捷操作条、批量操作栏、提示条、快速添加面板、分段按钮、标签），
// 任务卡片、象限底色等内容层继续用米色主题。
// 外层的 #if compiler(>=6.2) 让旧版 Xcode（没有玻璃接口的 SDK）也能编译，直接走旧样式。

/// 液态玻璃的调参，统一在这里改。
enum GlassTuning {
    /// 没有指定 glassTint 时的默认着色：一点暖米色，让通透的 .clear 玻璃在米色背景上有层次。
    /// 想更透就调小 opacity，想更有存在感就调大。
    static let defaultTint = Color(hex: 0xFFF3D6).opacity(0.35)
}

extension View {
    /// 浮层表面。macOS 26 起用液态玻璃；旧系统是纯色填充 + 1pt 描边 + 阴影（与原来一致）。
    /// - Parameters:
    ///   - fill / border / shadowRadius / shadowOpacity：旧系统的样式。shadowRadius 为 0 时不加阴影。
    ///   - glassTint：玻璃的着色，nil 为不着色。
    ///   - glassBorder：玻璃上是否也画 border（有语义颜色的边框，例如批量操作栏的强调色、错误提示的红色）。
    ///   - glass：false 时始终用旧样式（例如表单里的分段按钮）。
    @ViewBuilder
    func floatingSurface<S: Shape>(_ shape: S, fill: Color = Theme.card, border: Color = Theme.line,
                                   shadowRadius: CGFloat = 8, shadowOpacity: Double = 0.12,
                                   glassTint: Color? = nil, glassBorder: Bool = false,
                                   glass: Bool = true) -> some View {
        #if compiler(>=6.2)
        if glass, #available(macOS 26, *) {
            self.glassEffect(.clear.tint(glassTint ?? GlassTuning.defaultTint), in: shape)
                .overlay {
                    if glassBorder {
                        shape.stroke(border, lineWidth: 1)
                    }
                }
        } else {
            legacySurface(shape, fill: fill, border: border, shadowRadius: shadowRadius, shadowOpacity: shadowOpacity)
        }
        #else
        legacySurface(shape, fill: fill, border: border, shadowRadius: shadowRadius, shadowOpacity: shadowOpacity)
        #endif
    }

    private func legacySurface<S: Shape>(_ shape: S, fill: Color, border: Color,
                                         shadowRadius: CGFloat, shadowOpacity: Double) -> some View {
        let opacity: Double = shadowRadius > 0 ? shadowOpacity : 0
        let offset: CGFloat = shadowRadius * 0.375
        return self
            .background(shape.fill(fill))
            .overlay(shape.stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(opacity), radius: shadowRadius, y: offset)
    }

    /// 系统 popover 里的内容背景。macOS 26 起 popover 本身就是液态玻璃，不再铺纯色；旧系统照旧。
    @ViewBuilder
    func popoverBackground(_ color: Color) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self
        } else {
            self.background(color)
        }
        #else
        self.background(color)
        #endif
    }

    /// 同上，用于 .popover 的 presentationBackground。
    @ViewBuilder
    func themedPresentationBackground(_ color: Color) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self
        } else {
            self.presentationBackground(color)
        }
        #else
        self.presentationBackground(color)
        #endif
    }
}
