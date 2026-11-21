import AppKit
import SwiftUI

// MARK: - 添加邮箱账户：授权读取日历 → 勾选 Mac「互联网账户」里的日历 → 导入

struct SystemCalendarSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var access: SystemCalendarAccess = .notDetermined
    @State private var calendars: [SystemCalendarInfo] = []
    @State private var selected: Set<String> = []
    @State private var busy = false

    private static let privacyURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    private static let accountsURL = "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"

    private var addedIDs: Set<String> {
        Set(model.importSources.filter { $0.kind == .system }.map(\.address))
    }

    private var pending: [SystemCalendarInfo] {
        let added = addedIDs
        return calendars.filter { selected.contains($0.id) && !added.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                    Text("只读取日历，不会修改原来的日历。导入后\(model.importSyncPhrase)，可以在「导入日程」页修改。已经用 CalDAV 导入过的账户，不要在这里再选它的日历，否则会重复。")
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
        .frame(width: 560, height: 560)
        .background(Theme.background)
        .tint(Theme.accent)
        .onAppear { reload(refresh: false) }
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: 0x8E5BD6))
            VStack(alignment: .leading, spacing: 1) {
                Text("添加邮箱账户").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
                Text(verbatim: "读取 Mac「互联网账户」里的日历")
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

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch access {
        case .granted:
            if calendars.isEmpty {
                Text("这台 Mac 上还没有日历。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
            } else {
                calendarList
            }
            accountsHint
        case .notDetermined:
            permissionBox("便单需要读取这台 Mac 上的日历。点下面的按钮后系统会询问，选「允许」即可。",
                          button: "允许读取日历") { request() }
        case .denied, .writeOnly:
            permissionBox(deniedText, button: "打开系统设置") { Self.openSettings(Self.privacyURL) }
        }
    }

    private var deniedText: String {
        if access == .writeOnly {
            return "便单现在只有「添加日程」权限，读不了日程。请在「系统设置 → 隐私与安全性 → 日历」里把「便单」改成「完全访问」，再回来点「刷新」。"
        }
        return "便单没有日历访问权限。请在「系统设置 → 隐私与安全性 → 日历」里打开「便单」（完全访问），再回来点「刷新」。"
    }

    private var calendarList: some View {
        let accounts = Array(Set(calendars.map(\.account))).sorted()
        let added = addedIDs
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(accounts, id: \.self) { account in
                InspectorSection("\(account)") {
                    ForEach(calendars.filter { $0.account == account }) { info in
                        SystemCalendarRow(info: info, added: added.contains(info.id),
                                          on: selected.contains(info.id)) { toggle(info) }
                    }
                }
            }
        }
    }

    private var accountsHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Theme.subtext)
            Text("没看到想要的邮箱？在「系统设置 → 互联网账户」里登录，打开它的「日历」，再回来点「刷新」。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("打开互联网账户") { Self.openSettings(Self.accountsURL) }
                .buttonStyle(.themed)
        }
    }

    private func permissionBox(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(.themedPrimary)
                .disabled(busy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Theme.card))
        .overlay(shape.stroke(Theme.line))
    }

    // MARK: 底栏

    private var footer: some View {
        let signedIn = model.authState == .signedIn
        let count = pending.count
        return HStack(spacing: 10) {
            Button("刷新") { reload(refresh: true) }
                .buttonStyle(.themed)
                .disabled(busy)
            if !signedIn {
                Text("请先在便单主窗口登录").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
                Text("正在处理…").font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            Button("取消") { dismiss() }.buttonStyle(.themed)
            Button {
                add()
            } label: {
                Text(verbatim: count == 0 ? "请选择日历" : "导入（\(count) 个日历）")
            }
            .buttonStyle(.themedPrimary)
            .disabled(busy || count == 0 || !signedIn || access != .granted)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 动作

    private func reload(refresh: Bool) {
        if refresh { SystemCalendarImport.refreshSources() }
        access = SystemCalendarImport.access
        model.reloadImportSources()
        calendars = access == .granted ? SystemCalendarImport.calendars() : []
        let ids = Set(calendars.map(\.id))
        selected = selected.intersection(ids)
    }

    private func request() {
        busy = true
        Task {
            access = await SystemCalendarImport.requestAccess()
            busy = false
            reload(refresh: true)
        }
    }

    private func toggle(_ info: SystemCalendarInfo) {
        if selected.contains(info.id) { selected.remove(info.id) } else { selected.insert(info.id) }
    }

    private func add() {
        let chosen = pending
        busy = true
        Task {
            await model.addSystemSources(chosen)
            busy = false
            dismiss()
        }
    }

    private static func openSettings(_ address: String) {
        if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

private struct SystemCalendarRow: View {
    let info: SystemCalendarInfo
    let added: Bool
    let on: Bool
    let toggle: () -> Void

    var body: some View {
        let icon: String = added ? "checkmark.circle.fill" : (on ? "checkmark.square.fill" : "square")
        let iconColor: Color = added || on ? Theme.accent : Color(hex: 0xB9B09C)
        let target = AppModel.caldavSourceName(account: info.account, calendar: info.title)
        let detail = "\(info.kindTitle) · 导入到分类「\(target)」"
        let faded: Double = added ? 0.55 : (on ? 1 : 0.7)
        return Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                Circle().fill(CalDAVConnectSheet.color(info.colorHex)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if added { ImportTag(text: "已导入", color: Theme.subtext) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .opacity(faded)
    }
}
