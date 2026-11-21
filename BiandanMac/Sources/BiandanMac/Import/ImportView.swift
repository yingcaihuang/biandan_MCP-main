import SwiftUI

// MARK: - 侧栏「导入日程」：四种导入方式 + 已连接的来源

private struct ImportOption: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    /// 还没实现的入口显示「即将支持」。
    let available: Bool
}

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var pendingDelete: ImportSource?

    private static let options: [ImportOption] = [
        ImportOption(id: "caldav", icon: "calendar.badge.plus", title: "添加 CalDAV 日历",
                     detail: "钉钉、飞书、腾讯会议、企业微信、iCloud 等，填服务器、用户名和专用密码，之后定时自动同步",
                     tint: Quadrant.notImportantUrgent.tint, available: true),
        ImportOption(id: "mail", icon: "envelope", title: "添加邮箱账户",
                     detail: "读取 Mac「互联网账户」里已登录的 Exchange、Google、QQ、163 等邮箱日历，定时自动同步",
                     tint: Color(hex: 0x8E5BD6), available: true),
        ImportOption(id: "url", icon: "link", title: "URL 导入",
                     detail: "粘贴 webcal:// 或 https://….ics 订阅地址，和 CalDAV 一样定时刷新",
                     tint: Quadrant.neither.tint, available: true),
        ImportOption(id: "file", icon: "doc.badge.plus", title: "从文件中导入",
                     detail: "选择 .ics 文件，或直接拖到这个页面；再次导入同一文件只更新，不会重复",
                     tint: Color(hex: 0xFA8B36), available: true),
    ]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("把其他日历里的日程导入便单。每个来源单独放进一个分类，外部取消的日程会标记为放弃，不会直接删除。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = model.importNotice {
                    noticeRow(notice)
                }
                optionGrid
                sourcesSection
                InspectorSection("自动同步") {
                    ThemedRow("同步间隔") {
                        ThemedSegmented(selection: $model.importSyncIntervalMinutes,
                                        options: AppModel.importSyncChoices.map {
                                            ThemeOption(value: $0, title: AppModel.importIntervalTitle($0))
                                        })
                    }
                    ThemedRow("同步异常时通知") {
                        Toggle("", isOn: $model.importNotifyFailures)
                            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    }
                    ThemedRow("同步日志") {
                        Button("查看日志") { model.importLogShown = true }
                            .buttonStyle(.themed)
                    }
                }
                SettingFootnotes(items: [
                    SettingFootnote(icon: "arrow.right",
                                    text: "只做单向导入：外部日历 → 便单。在便单里修改导入的任务，不会写回原来的日历。"),
                    SettingFootnote(icon: "exclamationmark.arrow.triangle.2.circlepath",
                                    text: "连续失败 \(ImportBackoff.slowDownAfter) 次起自动同步逐步放慢（最长 12 小时），连续失败 \(ImportBackoff.pauseAfter) 次自动暂停并通知；点「立即同步」成功后恢复。"),
                    SettingFootnote(icon: "arrow.triangle.2.circlepath",
                                    text: "CalDAV、URL 订阅和邮箱账户日历登录后\(model.importSyncPhrase)，可以在上方「自动同步」里修改；外部删除的日程标记为放弃，密码只存在这台 Mac 的钥匙串里。"),
                    SettingFootnote(icon: "calendar",
                                    text: "导入范围是过去 \(ICSImport.pastDays) 天到未来一年。简单的重复日程转成便单的重复任务，有次数、截止日期或例外日期的按次导入。"),
                    SettingFootnote(icon: "bell.slash",
                                    text: "导入的任务不另加时间提醒，避免和原日历重复提醒；需要时可以在任务里单独打开。"),
                ])
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .overlay { if targeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ics" }) ?? urls.first else {
                return false
            }
            model.loadImportFile(url)
            return true
        } isTargeted: { targeted = $0 }
        .onAppear { model.reloadImportSources() }
        .sheet(item: $model.importPreview) { preview in
            ImportPreviewSheet(preview: preview).environment(model)
        }
        .sheet(isPresented: $model.caldavSheetShown) {
            CalDAVConnectSheet().environment(model)
        }
        .sheet(isPresented: $model.urlSheetShown) {
            URLSubscribeSheet().environment(model)
        }
        .sheet(isPresented: $model.systemSheetShown) {
            SystemCalendarSheet().environment(model)
        }
        .sheet(item: $model.importEditing) { source in
            ImportSourceEditSheet(source: source).environment(model)
        }
        .sheet(isPresented: $model.importLogShown) {
            ImportLogSheet().environment(model)
        }
        .alert("移除这个来源？", isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } })) {
            Button("移除", role: .destructive) {
                if let source = pendingDelete { model.removeImportSource(source) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("之后不再同步这个来源。已导入的任务保留在分类里，可以自己删除。")
        }
    }

    // MARK: 入口

    private var optionGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Self.options) { option in
                ImportOptionCard(option: option) {
                    if option.id == "file" {
                        model.chooseImportFile()
                    } else if option.id == "caldav" {
                        model.caldavSheetShown = true
                    } else if option.id == "url" {
                        model.urlSheetShown = true
                    } else if option.id == "mail" {
                        model.systemSheetShown = true
                    }
                }
            }
        }
    }

    // MARK: 已连接的来源

    private var sourcesSection: some View {
        InspectorSection("已导入的日历") {
            if model.importSources.isEmpty {
                Text("还没有导入过日历。选上面的一种方式开始，或把 .ics 文件拖到这里。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.importSources) { source in
                    ImportSourceRow(source: source, onReimport: { model.chooseImportFile() },
                                    onEdit: { model.importEditing = source },
                                    onDelete: { pendingDelete = source })
                }
            }
        }
    }

    private func noticeRow(_ text: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Theme.accent)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.importNotice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.subtext)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(shape.fill(Theme.selectionFill))
        .overlay(shape.stroke(Theme.accent.opacity(0.4)))
    }

    private var dropOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus").font(.system(size: 30, weight: .semibold))
            Text("松开导入 .ics 文件").font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(Color(hex: 0xFA8B36))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Theme.card.opacity(0.92)))
        .overlay(shape.stroke(Color(hex: 0xFA8B36), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .padding(16)
        .allowsHitTesting(false)
    }
}

private struct ImportOptionCard: View {
    let option: ImportOption
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let border: Color = hovering && option.available ? option.tint.opacity(0.7) : Theme.line
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(option.tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: option.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(option.tint))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: option.title)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Theme.text)
                        if !option.available { ImportTag(text: "即将支持", color: Theme.subtext) }
                    }
                    Text(verbatim: option.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.fieldName)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(shape.fill(Theme.card))
            .overlay(shape.stroke(border))
            .contentShape(shape)
            .opacity(option.available ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!option.available)
        .onHover { hovering = $0 }
        .help(option.available ? option.title : "正在开发，后续版本提供")
    }
}

struct ImportTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
