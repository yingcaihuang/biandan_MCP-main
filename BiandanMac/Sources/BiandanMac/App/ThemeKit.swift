import SwiftUI

// MARK: - 主题规范（所有页面必须遵守）
//
// 便单 for macOS 的所有窗口、弹窗、设置页都沿用四象限主界面的风格，不要另起一套：
// - 背景 Theme.background（暖米色），面板 Theme.panel，卡片 Theme.card + Theme.line 描边，圆角 10（大块 14）。
// - 强调色只用 Theme.accent（黄）；和四象限相关的颜色只用 Quadrant.tint / fill / titleColor。
// - 页面标题用 heavy 粗体；分区标题 11pt、Theme.subtext；云端字段名用 FieldTag。
// - 不要用 .formStyle(.grouped)、系统蓝色强调、默认灰色背景或 .borderedProminent 按钮。
// 新页面直接组合本文件的组件：ThemedSheet / InspectorSection / ThemedRow / ThemedSwitch /
// ThemedSegmented / ThemedChoiceList / QuadrantPicker / ThemedErrorText / .themedField() /
// ThemedDateField / ThemedTimeField / ThemedListPicker（见 ThemedPickers.swift） /
// ThemedMenuRow / .themedCard()（点击弹出的菜单面板，替代系统 Menu） /
// .themedContextMenu / ThemedMenuPanel / ThemedMenuGroup（右键菜单，见 ThemedContextMenu.swift） /
// .buttonStyle(.themedPrimary | .themed | .themedDestructive)。

struct ThemeTag: Equatable {
    var text: String
    var color: Color
}

// MARK: - 弹窗外框

/// 标准弹窗：标题栏 + 可滚动内容 + 底部按钮栏。
struct ThemedSheet<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let tag: ThemeTag?
    let headerFill: Color
    let titleColor: Color
    let content: Content
    let footer: Footer

    init(_ title: String, subtitle: String? = nil, tag: ThemeTag? = nil,
         headerFill: Color = Theme.panel, titleColor: Color = Theme.text,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.tag = tag
        self.headerFill = headerFill
        self.titleColor = titleColor
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if let tag {
                        Text(tag.text)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tag.color))
                    }
                    Spacer(minLength: 0)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(headerFill)
            .animation(.easeInOut(duration: 0.2), value: tag)

            Rectangle().fill(Theme.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(18)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            HStack(spacing: 10) {
                footer
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.panel)
        }
        .background(Theme.background)
        .tint(Theme.accent)
    }
}

// MARK: - 表单行与控件

/// 卡片里的一行：左侧标签（可带云端字段名），右侧控件。放在 InspectorSection 里使用。
struct ThemedRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let label: String
    let field: String?
    let content: Content

    init(_ label: String, field: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.field = field
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Color(hex: 0x4A453C))
                .fixedSize()
            if let field, model.showFieldNames {
                FieldTag(field)
            }
            Spacer(minLength: 6)
            content
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

struct ThemedSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .tint(Theme.accent)
    }
}

struct ThemeOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// 与内容区标题栏「列表 / 四象限 / 日历」一致的分段选择。
struct ThemedSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [ThemeOption<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let on = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.subtext)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(on ? Color.white : Color.clear)
                                .shadow(color: .black.opacity(on ? 0.1 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xE8E1D1)))
    }
}

/// 单选列表（替代系统 radioGroup），每项一行，带圆圈勾选。
struct ThemedChoiceList<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [ThemeOption<Value>]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                let on = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Theme.accent : Color(hex: 0xB9B09C))
                        Text(option.title)
                            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
                }
            }
        }
    }
}

/// 2×2 四象限选择，颜色与主界面四个象限一致。
struct QuadrantPicker: View {
    @Binding var selection: Quadrant

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                chip(.importantUrgent)
                chip(.importantNotUrgent)
            }
            GridRow {
                chip(.notImportantUrgent)
                chip(.neither)
            }
        }
    }

    private func chip(_ quadrant: Quadrant) -> some View {
        let on = selection == quadrant
        return Button {
            selection = quadrant
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(quadrant.tint)
                Text(quadrant.title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(quadrant.titleColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(quadrant.fill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(quadrant.tint.opacity(on ? 1 : 0.45), lineWidth: on ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ThemedErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.overdue)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// 主题输入框：白色卡片底、细描边、圆角 8。
    func themedField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

// MARK: - 按钮

struct ThemedButtonStyle: ButtonStyle {
    enum Kind {
        case primary, secondary, destructive
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        ThemedButtonBody(configuration: configuration, kind: kind)
    }
}

private struct ThemedButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let kind: ThemedButtonStyle.Kind

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .secondary ? .regular : .semibold))
            .foregroundStyle(kind == .secondary ? Theme.text : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .secondary ? Theme.line : Color.clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fill: Color {
        switch kind {
        case .primary: return Theme.accent
        case .secondary: return Theme.card
        case .destructive: return Theme.overdue
        }
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static var themedPrimary: ThemedButtonStyle { ThemedButtonStyle(kind: .primary) }
    static var themed: ThemedButtonStyle { ThemedButtonStyle(kind: .secondary) }
    static var themedDestructive: ThemedButtonStyle { ThemedButtonStyle(kind: .destructive) }
}

// MARK: - 卡片与弹出面板菜单行

extension View {
    /// 白色卡片底 + 细描边，圆角 10。
    func themedCard(cornerRadius: CGFloat = 10) -> some View {
        self.background(RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.card))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Theme.line))
    }
}

/// 弹出面板里的一行操作：彩色图标块 + 标题 / 说明 + 快捷键，悬停高亮。替代系统 Menu 的菜单项。
struct ThemedMenuRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var tint: Color = Theme.accent
    var shortcut: String? = nil
    var destructive = false
    var busy = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.15))
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(destructive ? Theme.overdue : Theme.text)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x6B6457))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xEEE8DA)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering && isEnabled
                        ? (destructive ? Theme.overdue.opacity(0.08) : Theme.accent.opacity(0.12))
                        : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled || busy ? 1 : 0.45)
    }
}
