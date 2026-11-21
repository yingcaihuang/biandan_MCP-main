import SwiftUI

// MARK: - 设置页的行与脚注：标题下一行短说明、控件靠右；长说明放到分组底部的脚注区。

/// 设置里的一行：左边标题 + 一行短说明，右边控件。放在 InspectorSection 里。
struct SettingRow<Content: View>: View {
    let title: String
    let caption: String?
    let content: Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let caption {
                    Text(verbatim: caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

struct SettingFootnote: Identifiable {
    let icon: String
    let text: String
    var id: String { text }
}

/// 分组底部的脚注区：浅色底、小字，可带一个链接。
struct SettingFootnotes: View {
    let items: [SettingFootnote]
    var link: (title: String, url: URL)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: item.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.fieldName)
                        .frame(width: 14)
                        .padding(.top, 1)
                    Text(verbatim: item.text)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let link {
                Link(destination: link.url) {
                    HStack(spacing: 4) {
                        Text(verbatim: link.title)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.leading, 21)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}
