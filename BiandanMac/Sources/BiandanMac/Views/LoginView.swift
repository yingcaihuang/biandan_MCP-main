import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    private let steps = [
        "在系统浏览器打开华为授权页（PKCE）",
        "等待授权… 本机正在监听 127.0.0.1:42681",
        "换取令牌，凭据保存到钥匙串",
        "首次全量同步四张表",
    ]

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xFFD54A), Color(hex: 0xF5A300)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .overlay(Text("便").font(.system(size: 42, weight: .heavy)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

            Text("登录便单")
                .font(.system(size: 28, weight: .bold))
            Text("登录华为账号后，Mac 上的待办会和你的鸿蒙手机、平板保持同步")
                .foregroundStyle(Theme.subtext)

            if model.authState == .signingIn {
                signingInSteps
            } else {
                Button { model.signIn() } label: {
                    Text("使用华为账号登录")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.huawei))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.overdue)
                    .font(.callout)
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.center)
            }

            Spacer()
            Text("使用便单网页版的华为 OAuth 客户端登录，凭据只保存在本机钥匙串。")
                .font(.caption)
                .foregroundStyle(Theme.fieldName)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var signingInSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(index <= 1 ? Theme.accent : Color(hex: 0xEEE8DA))
                        if index == 0 {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index == 1 ? .white : Theme.subtext)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(text)
                        .foregroundStyle(index == 1 ? Theme.text : Theme.subtext)
                    if index == 1 {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            HStack {
                Button("重新打开授权页") { model.reopenAuthorizationPage() }
                Button("取消") { model.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .padding(.top, 10)
    }
}
