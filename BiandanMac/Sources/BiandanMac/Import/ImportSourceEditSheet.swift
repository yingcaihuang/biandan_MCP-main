import SwiftUI

// MARK: - 编辑导入来源：名称、分类、连接设置、自动同步开关，以及最近的同步记录

struct ImportSourceEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: ImportSource
    @State private var name: String
    @State private var listID: String
    @State private var renameList = false
    @State private var moveTasks = true
    @State private var enabled: Bool
    @State private var address: String
    @State private var username = ""
    @State private var secret = ""
    @State private var calendarTitle = ""
    @State private var logs: [ImportSyncLog] = []
    @State private var busy = false
    @State private var errorText: String?

    init(source: ImportSource) {
        self.source = source
        _name = State(initialValue: source.name)
        _listID = State(initialValue: source.listID)
        _enabled = State(initialValue: source.enabled)
        _address = State(initialValue: source.address)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { trimmedName != source.name }
    private var listChanged: Bool { listID != source.listID }
    private var live: ImportSource { model.importSources.first { $0.id == source.id } ?? source }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    basics
                    connection
                    if source.kind.syncs { syncSection }
                    history
                    if let errorText { errorRow(errorText) }
                }
                .padding(16)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.panel)
        }
        .frame(width: 580, height: 640)
        .background(Theme.background)
        .tint(Theme.accent)
        .onAppear(perform: load)
    }

    private func load() {
        renameList = model.snapshot.list(source.listID)?.displayName == source.name
        logs = model.importLogs(sourceID: source.id, limit: 8)
        switch source.kind {
        case .caldav:
            username = CalDAVKeychain.load(source.id)?.username ?? ""
        case .system:
            if SystemCalendarImport.access == .granted {
                let found = SystemCalendarImport.calendars().first { $0.id == source.address }
                calendarTitle = found.map { "\($0.account) · \($0.title)" } ?? "在这台 Mac 上找不到这个日历"
            } else {
                calendarTitle = "没有日历访问权限"
            }
        case .url, .file:
            break
        }
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("编辑导入来源").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
                Text(verbatim: "\(source.kind.title) · \(source.name)")
                    .font(.system(size: 11)).foregroundStyle(Theme.subtext).lineLimit(1)
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

    // MARK: 名称与分类

    private var basics: some View {
        InspectorSection("来源") {
            SettingRow("名称", caption: "显示在已导入的日历里，也写进之后导入任务的备注") {
                TextField("", text: $name, prompt: Text("来源名称"))
                    .themedField()
                    .frame(width: 240)
            }
            SettingRow("分类", caption: "之后同步的日程放进这个分类") {
                ThemedListPicker(selection: $listID)
            }
            if nameChanged && !listChanged {
                SettingRow("分类一起改名", caption: "把分类也改成「\(trimmedName)」") {
                    Toggle("", isOn: $renameList)
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
            }
            if listChanged {
                SettingRow("移动已导入的任务", caption: "把这个来源已经导入的任务一起移到新分类") {
                    Toggle("", isOn: $moveTasks)
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
            }
        }
    }

    // MARK: 连接设置

    @ViewBuilder
    private var connection: some View {
        switch source.kind {
        case .caldav:
            InspectorSection("CalDAV 账户") {
                SettingRow("日历地址", caption: "这个日历本身的地址；改成别的日历时会按新日历重新导入") {
                    TextField("", text: $address, prompt: Text("https://…"))
                        .themedField()
                        .frame(width: 280)
                }
                SettingRow("用户名") {
                    TextField("", text: $username, prompt: Text("用户名"))
                        .themedField()
                        .frame(width: 280)
                }
                SettingRow("密码", caption: "专用密码过期或重新生成时填新的") {
                    SecureField("", text: $secret, prompt: Text("不修改请留空"))
                        .themedField()
                        .frame(width: 280)
                }
            }
        case .url:
            InspectorSection("订阅") {
                SettingRow("订阅地址", caption: "订阅链接失效或重新生成时改成新的") {
                    TextField("", text: $address, prompt: Text("webcal://… 或 https://….ics"))
                        .themedField()
                        .frame(width: 280)
                }
            }
        case .system:
            InspectorSection("系统日历") {
                SettingRow("日历", caption: "来自 Mac「互联网账户」，账户和密码在系统设置里管理") {
                    readOnly(calendarTitle)
                }
            }
        case .file:
            InspectorSection("文件") {
                SettingRow("文件名", caption: "再次导入同名文件时，更新这个来源") {
                    readOnly(source.address)
                }
            }
        }
    }

    private func readOnly(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.subtext)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 280, alignment: .trailing)
            .help(text)
    }

    // MARK: 自动同步

    private var syncSection: some View {
        InspectorSection("同步") {
            SettingRow("自动同步", caption: syncCaption) {
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
        }
    }

    private var syncCaption: String {
        let current = live
        if !enabled {
            return current.autoPaused && !current.enabled
                ? "连续失败 \(current.failures) 次后自动暂停了。打开并保存后重新计数"
                : "关闭后只在点「立即同步」时同步"
        }
        if current.failures > 0 {
            var text = "已连续失败 \(current.failures) 次"
            if let retry = current.retryAt, retry > Date() { text += "，\(AppModel.importTimeText(retry)) 后再自动重试" }
            if let error = current.lastError { text += "：\(error)" }
            return text
        }
        return model.importSyncIntervalMinutes > 0
            ? "按「导入日程」页设置的间隔同步（\(AppModel.importIntervalTitle(model.importSyncIntervalMinutes))）"
            : "「导入日程」页设置的是「仅手动」，现在不会自动同步"
    }

    // MARK: 最近同步记录

    private var history: some View {
        InspectorSection("最近同步记录") {
            if logs.isEmpty {
                Text("还没有同步记录")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(logs) { log in ImportLogRow(log: log, showSource: false) }
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
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
                Text("正在保存…").font(.system(size: 12)).foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 6)
            Button("取消") { dismiss() }.buttonStyle(.themed)
            Button("保存") { save() }
                .buttonStyle(.themedPrimary)
                .disabled(busy || trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        let edit = ImportSourceEdit(name: name, listID: listID, moveTasks: moveTasks,
                                    renameList: renameList && nameChanged && !listChanged, enabled: enabled,
                                    address: address, username: username, password: secret)
        busy = true
        errorText = nil
        Task {
            let failure = await model.updateImportSource(source, edit)
            busy = false
            if let failure { errorText = failure } else { dismiss() }
        }
    }
}
