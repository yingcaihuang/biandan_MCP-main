import SwiftUI

/// 华为账号头像：来自登录时 id_token 的 picture 字段。
/// 没有头像、加载中或加载失败时显示名字首字母的渐变圆标（与原型一致）。
struct AccountAvatar: View {
    let profile: AccountProfile
    var size: CGFloat = 34

    private var url: URL? {
        guard let text = profile.avatarURL, let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.line, lineWidth: 1))
        .help(profile.displayName)
    }

    private var initials: some View {
        Circle()
            .fill(LinearGradient(colors: [Theme.accent, Color(hex: 0xF08A24)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(String(profile.displayName.prefix(1)))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white))
    }
}
