import SwiftUI

// MARK: - 添加 CalDAV 日历：填账户 → 连接并发现日历 → 勾选 → 导入

struct CalDAVConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var presetID = CalDAVPreset.all[0].id
    @State private var server = CalDAVPreset.all[0].server
    @State private var username = ""
    @State private var password = ""
    @State private var calendars: [CalDAVCalendar] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var connectedServer: URL?

    private var preset: CalDAVPreset { CalDAVPreset.all.first { $0.id == presetID } ?? CalDAVPreset.all[0] }

    private var credentials: CalDAVCredentials {
        CalDAVCredentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
    }

    /// 分类名称前缀：预设服务用服务名，自定义用服务器域名。
    private var accountLabel: String {
        preset.id == "custom" ? (connectedServer?.host ?? "") : preset.name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if calendars.isEmpty { accountForm } else { calendarPicker }
                    if let errorText { errorRow(errorText) }
                    Text("只读取日历，不会修改原来的日历。密码只保存在这台 Mac 的钥匙串里，导入后\(model.importSyncPhrase)，可以在「导入日程」页修改。")
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
        .frame(width: 560, height: 520)
        .background(Theme.background)
        .tint(Theme.accent)
        .onChange(of: presetID) { _, _ in server = preset.server }
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Quadrant.notImportantUrgent.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("添加 CalDAV 日历").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
                Text(verbatim: calendars.isEmpty ? "第 1 步：填写账户" : "第 2 步：选择要导入的日历")
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

    // MARK: 第 1 步：账户

    private var accountForm: some View {
        InspectorSection("账户") {
            SettingRow("服务", caption: preset.hint) {
                Picker("", selection: $presetID) {
                    ForEach(CalDAVPreset.all) { item in Text(verbatim: item.name).tag(item.id) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingRow("服务器", caption: "只填域名也可以，会自动查找日历") {
                TextField("", text: $server, prompt: Text("https://caldav.example.com"))
                    .themedField()
                    .frame(width: 260)
            }
            SettingRow("用户名", caption: "CalDAV 设置里给的用户名，iCloud 用 Apple ID 邮箱") {
                TextField("", text: $username, prompt: Text("用户名"))
                    .themedField()
                    .frame(width: 260)
            }
            SettingRow("密码", caption: "多数服务要用专门生成的密码，不是登录密码") {
                SecureField("", text: $password, prompt: Text("专用密码"))
                    .themedField()
                    .frame(width: 260)
            }
        }
    }

    // MARK: 第 2 步：选日历

    private var calendarPicker: some View {
        InspectorSection("找到 \(calendars.count) 个日历") {
            ForEach(calendars) { calendar in
                let on = selected.contains(calendar.id)
                Button {
                    if on { selected.remove(calendar.id) } else { selected.insert(calendar.id) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16))
                            .foregroundStyle(on ? Theme.accent : Color(hex: 0xB9B09C))
                        Circle().fill(Self.color(calendar.color)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: calendar.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text(verbatim: "导入到分类「\(AppModel.caldavSourceName(account: accountLabel, calendar: calendar.name))」")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.subtext)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(on ? 1 : 0.6)
            }
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
        let canConnect = !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        return HStack(spacing: 10) {
            if !calendars.isEmpty {
                Button("上一步") {
                    calendars = []
                    errorText = nil
                }
                .buttonStyle(.themed)
                .disabled(busy)
            }
            if !signedIn {
                Text("请先在便单主窗口登录").font(.system(size: 11)).foregroundStyle(Theme.overdue)
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
                Text(verbatim: calendars.isEmpty ? "正在连接…" : "正在添加…")
                    .font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            Button("取消") { dismiss() }.buttonStyle(.themed)
            if calendars.isEmpty {
                Button("连接") { connect() }
                    .buttonStyle(.themedPrimary)
                    .disabled(busy || !canConnect)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    add()
                } label: {
                    Text(verbatim: selected.isEmpty ? "请选择日历" : "导入（\(selected.count) 个日历）")
                }
                .buttonStyle(.themedPrimary)
                .disabled(busy || selected.isEmpty || !signedIn)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 动作

    private func connect() {
        guard let url = CalDAVClient.serverURL(server) else {
            errorText = CalDAVError.invalidAddress.localizedDescription
            return
        }
        let client = CalDAVClient(credentials: credentials)
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                let found = try await client.discover(server: url)
                connectedServer = url
                calendars = found
                selected = Set(found.map(\.id))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func add() {
        let chosen = calendars.filter { selected.contains($0.id) }
        let account = accountLabel
        let login = credentials
        busy = true
        Task {
            await model.addCalDAVSources(account: account, credentials: login, calendars: chosen)
            busy = false
            dismiss()
        }
    }

    static func color(_ hex: String?) -> Color {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return Theme.accent }
        text.removeFirst()
        if text.count == 8 { text = String(text.prefix(6)) }
        guard text.count == 6, let value = Int(text, radix: 16) else { return Theme.accent }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
