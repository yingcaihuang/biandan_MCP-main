import SwiftUI

// MARK: - URL 导入：粘贴订阅地址 → 检查 → 订阅（之后定时刷新）

struct URLSubscribeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var checked: Checked?
    @State private var busy = false
    @State private var errorText: String?

    private struct Checked: Equatable {
        var address: String
        var events: Int
        var skipped: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    form
                    if let checked { checkedRow(checked) }
                    if let errorText { errorRow(errorText) }
                    Text("只读取订阅地址，不会修改原来的日历。订阅后\(model.importSyncPhrase)，可以在「导入日程」页修改。订阅地址里常带有访问凭证，请不要分享给别人。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.panel)
        }
        .frame(width: 560, height: 430)
        .background(Theme.background)
        .tint(Theme.accent)
        .onChange(of: address) { _, _ in
            checked = nil
            errorText = nil
        }
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Quadrant.neither.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("URL 导入").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
                Text(verbatim: checked == nil ? "粘贴日历的订阅地址" : "确认后订阅")
                    .font(.system(size: 11)).foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 6)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.subtext)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    // MARK: 表单

    private var form: some View {
        InspectorSection("订阅") {
            SettingRow("订阅地址", caption: "在飞书、钉钉、Outlook、Google 等日历的「订阅 / 公开地址」里复制") {
                TextField("", text: $address, prompt: Text("webcal://… 或 https://….ics"))
                    .themedField()
                    .frame(width: 280)
            }
            SettingRow("名称", caption: "也是导入到的分类名称；不填时用日历自带的名称") {
                TextField("", text: $name, prompt: Text("例如：节假日"))
                    .themedField()
                    .frame(width: 280)
            }
        }
    }

    private func checkedRow(_ checked: Checked) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.done)
            Text(verbatim: "读取成功：导入范围内有 \(checked.events) 条日程"
                 + (checked.skipped > 0 ? "，另有 \(checked.skipped) 条不在范围内" : ""))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.overdue)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 底栏

    private var footer: some View {
        let signedIn = model.authState == .signedIn
        let empty = address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 10) {
            if !signedIn {
                Text("请先在便单主窗口登录").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
                Text(verbatim: checked == nil ? "正在读取…" : "正在订阅…")
                    .font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            Button("取消") { dismiss() }.buttonStyle(.themed)
            if checked == nil {
                Button("检查地址") { check() }
                    .buttonStyle(.themedPrimary)
                    .disabled(busy || empty)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("订阅") { subscribe() }
                    .buttonStyle(.themedPrimary)
                    .disabled(busy || !signedIn)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 动作

    private func check() {
        guard let url = ICSSubscription.url(address) else {
            errorText = ICSSubscriptionError.invalidAddress.localizedDescription
            return
        }
        busy = true
        errorText = nil
        let today = model.today
        Task {
            defer { busy = false }
            do {
                let text = try await ICSSubscription.fetch(url)
                let result = ICSImport.parse(text, today: today)
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = result.name ?? url.host ?? "订阅日历"
                }
                checked = Checked(address: url.absoluteString, events: result.events.count, skipped: result.skipped)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func subscribe() {
        guard let checked else { return }
        busy = true
        let finalName = name
        Task {
            await model.addURLSource(address: checked.address, name: finalName)
            busy = false
            dismiss()
        }
    }
}
