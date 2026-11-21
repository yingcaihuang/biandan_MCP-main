import SwiftUI

/// 便单图标。解码失败时退回原来的「便」字方块。
struct BrandLogo: View {
    var size: CGFloat = 88

    var body: some View {
        if let icon = BrandIcon.image {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xFFD54A), Color(hex: 0xF5A300)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(Text("便").font(.system(size: size * 0.48, weight: .heavy)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}
