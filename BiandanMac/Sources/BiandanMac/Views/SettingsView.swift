import AppKit
import SwiftUI

// MARK: - 设置窗口（⌘,）：左侧主题侧栏 + 右侧内容，替代系统 TabView。遵循 DESIGN.md。

enum SettingsPane: String, CaseIterable, Identifiable {
    case account, sync, calendar, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账户"
        case .sync: return "同步"
        case .calendar: return "日历"
        case .advanced: return "高级"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "华为账号、凭据与续期"
        case .sync: return "和手机、平板保持一致"
        case .calendar: return "一周起始与节假日调休"
        case .advanced: return "显示选项与本机文件"
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle.fill"
        case .sync: return "arrow.triangle.2.circlepath"
        case .calendar: return "calendar"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// 四个分区分别用四象限的颜色。
    var tint: Color {
        switch self {
        case .account: return Quadrant.importantNotUrgent.tint
        case .sync: return Quadrant.notImportantUrgent.tint
        case .calendar: return Quadrant.importantUrgent.tint
        case .advanced: return Quadrant.neither.tint
        }
    }
}

struct SettingsView: View {
    @AppStorage("biandan.settingsPane") private var paneRaw = SettingsPane.account.rawValue

    var body: some View {
        let pane = SettingsPane(rawValue: paneRaw) ?? .account
        HStack(spacing: 0) {
            SettingsSidebar(selection: Binding(get: { pane }, set: { paneRaw = $0.rawValue }))
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PaneHeader(pane: pane)
                    switch pane {
                    case .account: AccountPane()
                    case .sync: SyncPane()
                    case .calendar: CalendarPane()
                    case .advanced: AdvancedPane()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(width: 740, height: 540)
        .ignoresSafeArea()
        .tint(Theme.accent)
    }
}

// MARK: - 侧栏

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    private var versionText: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "便单 for macOS · \(version)"
        }
        return "便单 for macOS · 开发版"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFFD54A), Color(hex: 0xF5A300)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                    .overlay(Text("便").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white))
                    .shadow(color: Color(hex: 0xF5A300).opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 0) {
                    Text("便单").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.text)
                    Text("设置").font(.system(size: 11)).foregroundStyle(Theme.subtext)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)

            ForEach(SettingsPane.allCases) { pane in
                SidebarPaneButton(pane: pane, selected: pane == selection) { selection = pane }
            }

            Spacer(minLength: 0)

            QuadrantStrip(height: 4)
                .clipShape(Capsule())
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            Text(versionText)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.fieldName)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 16)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

private struct SidebarPaneButton: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? pane.tint : pane.tint.opacity(0.15))
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: pane.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : pane.tint))
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Theme.card : (hovering ? Theme.accent.opacity(0.08) : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.line : Color.clear))
            .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 通用小组件

/// 四象限色带（红、黄、蓝、绿），与授权回调页、原型一致。
struct QuadrantStrip: View {
    var height: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Quadrant.allCases, id: \.self) { quadrant in
                Rectangle().fill(quadrant.tint)
            }
        }
        .frame(height: height)
    }
}

private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(pane.tint)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: pane.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white))
                .shadow(color: pane.tint.opacity(0.3), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text(pane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.subtext)
            .padding(.bottom, -10)
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

private struct InfoTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.15))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
            Text(value)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.fieldName)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedCard()
    }
}

private struct NoteRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.subtext)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x4A453C))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

private struct ValueText: View {
    let text: String
    var color: Color = Theme.text

    var body: some View {
        Text(text)
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .textSelection(.enabled)
    }
}

private struct StatCell: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(value)")
                .font(.system(size: 18, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity)
    }
}

private let rowDivider = Color(hex: 0xF0EADD)

extension AppModel {
    /// 设置页、账户面板共用的同步说明。
    var syncSummaryText: String {
        switch syncStatus {
        case .syncing(let message): return message
        case .failed(let message): return message
        case .idle:
            if isSavingInBackground { return "正在保存 \(backgroundOperations) 项更改…" }
            if let last = lastSyncedAt { return "上次同步 " + last.formatted(date: .abbreviated, time: .shortened) }
            return "尚未同步"
        }
    }
}

// MARK: - 账户

private struct AccountPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    private var status: (text: String, color: Color) {
        switch model.authState {
        case .signedIn: return ("已登录 · 自动续期中", Theme.done)
        case .signingIn: return ("正在等待浏览器授权…", Color(hex: 0xD9A800))
        case .checking: return ("正在检查…", Theme.subtext)
        case .signedOut: return ("未登录", Theme.subtext)
        }
    }

    var body: some View {
        let signedIn = model.authState == .signedIn
        let counts = model.counts
        let current = status
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                QuadrantStrip(height: 4)
                HStack(spacing: 16) {
                    AccountAvatar(profile: model.profile, size: 64)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(signedIn ? model.profile.displayName : "尚未登录")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        StatusPill(text: current.text, color: current.color)
                    }
                    Spacer(minLength: 0)
                    if !signedIn {
                        Button("使用华为账号登录") { model.signIn() }
                            .buttonStyle(.themedPrimary)
                            .disabled(model.authState == .signingIn)
                    }
                }
                .padding(18)
                if signedIn {
                    Rectangle().fill(rowDivider).frame(height: 1)
                    HStack(spacing: 0) {
                        StatCell(title: "待办单", value: model.snapshot.lists.count)
                        Rectangle().fill(rowDivider).frame(width: 1, height: 28)
                        StatCell(title: "任务", value: model.snapshot.tasks.count)
                        Rectangle().fill(rowDivider).frame(width: 1, height: 28)
                        StatCell(title: "待完成", value: counts.allPending)
                        Rectangle().fill(rowDivider).frame(width: 1, height: 28)
                        StatCell(title: "专注记录", value: model.snapshot.focus.count)
                    }
                    .padding(.vertical, 12)
                }
            }
            .themedCard(cornerRadius: 14)

            SectionTitle("凭据与续期")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let renewal = model.renewal
                let days = renewal?.daysUntilRelogin(now: context.date)
                HStack(spacing: 10) {
                    InfoTile(icon: "key.fill", tint: Quadrant.importantNotUrgent.tint, title: "凭据存储",
                             value: "macOS 钥匙串", note: "只保存在这台 Mac，不上传")
                    InfoTile(icon: "arrow.triangle.2.circlepath", tint: Quadrant.notImportantUrgent.tint, title: "下次续期",
                             value: RenewalText.nextRenewalShort(renewal, now: context.date),
                             note: RenewalText.nextRenewalNote(renewal))
                    InfoTile(icon: "hourglass", tint: RenewalText.tint(days: days) ?? Quadrant.neither.tint, title: "重新登录",
                             value: RenewalText.reloginValue(days: days), note: RenewalText.reloginNote(renewal))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if signedIn {
                SectionTitle("操作")
                VStack(spacing: 0) {
                    ThemedMenuRow(icon: "arrow.clockwise", title: "立即同步", detail: model.syncSummaryText,
                                  tint: Theme.accent, shortcut: "⌘R", busy: model.syncStatus.isSyncing) {
                        Task { await model.syncNow() }
                    }
                    .disabled(model.syncStatus.isSyncing)
                    Rectangle().fill(rowDivider).frame(height: 1).padding(.leading, 46)
                    ThemedMenuRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录…",
                                  detail: "删除钥匙串里的华为凭据", tint: Theme.overdue, destructive: true) {
                        confirmSignOut = true
                    }
                }
                .themedCard()
            }
        }
        .sheet(isPresented: $confirmSignOut) {
            SignOutSheet().environment(model)
        }
    }
}

// MARK: - 同步

private struct SyncPane: View {
    @Environment(AppModel.self) private var model

    private var state: (icon: String, color: Color, title: String) {
        switch model.syncStatus {
        case .syncing: return ("arrow.triangle.2.circlepath", Color(hex: 0xD9A800), "正在同步")
        case .failed: return ("exclamationmark.triangle.fill", Theme.overdue, "同步失败")
        case .idle:
            if model.authState != .signedIn { return ("person.crop.circle.badge.exclamationmark", Theme.subtext, "未登录") }
            if model.isSavingInBackground { return ("square.and.arrow.up", Color(hex: 0xD9A800), "正在保存更改") }
            return ("checkmark", Theme.done, "已同步")
        }
    }

    var body: some View {
        @Bindable var model = model
        let current = state
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(current.color.opacity(0.15))
                    if model.syncStatus.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: current.icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(current.color)
                    }
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.title)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(Theme.text)
                    Text(model.syncSummaryText)
                        .font(.system(size: 12))
                        .foregroundStyle(model.syncStatus == .idle ? Theme.subtext : current.color)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("立即同步") { Task { await model.syncNow() } }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.authState != .signedIn || model.syncStatus.isSyncing)
            }
            .padding(18)
            .themedCard(cornerRadius: 14)

            InspectorSection("自动同步") {
                ThemedRow("同步间隔") {
                    ThemedSegmented(selection: $model.syncIntervalMinutes,
                                    options: [1, 5, 15, 30, 60].map {
                                        ThemeOption(value: $0, title: $0 == 60 ? "1 小时" : "\($0) 分钟")
                                    })
                }
                ThemedRow("本地数据") {
                    ValueText(text: "\(model.snapshot.lists.count) 个待办单 · \(model.snapshot.tasks.count) 个任务 · \(model.snapshot.occurrences.count) 个实例",
                              color: Theme.subtext)
                }
            }

            InspectorSection("同步方式") {
                NoteRow(icon: "square.stack.3d.down.right", text: "云端没有增量接口，每次同步完整拉取四张表，四张表都拉完整才会写进本地。")
                NoteRow(icon: "macwindow", text: "窗口重新激活时也会同步一次（距上次超过 1 分钟）。")
                NoteRow(icon: "bolt", text: "完成、拖动等修改立即显示，在后台写入云端；失败会自动恢复原状态。")
            }
        }
    }
}

// MARK: - 日历

private struct CalendarPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("一周") {
                ThemedRow("一周开始于") {
                    ThemedSegmented(selection: $model.weekStart,
                                    options: [ThemeOption(value: 0, title: "周日"), ThemeOption(value: 1, title: "周一")])
                }
            }

            InspectorSection("本周预览") {
                WeekPreview(today: model.today, weekStart: model.weekStart)
                    .padding(10)
            }

            InspectorSection("节假日") {
                ThemedRow("工作日 / 休息日使用中国调休") { ThemedSwitch(isOn: $model.chinaMakeup) }
                ThemedRow("调休数据覆盖到") {
                    HStack(spacing: 8) {
                        Text(verbatim: "\(model.holidayLastYear) 年")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        if model.isCheckingHolidays { ProgressView().controlSize(.small) }
                        Button("检查更新") { Task { await model.checkHolidayUpdates(force: true) } }
                            .buttonStyle(.themed)
                            .disabled(model.isCheckingHolidays)
                    }
                }
                NoteRow(icon: "info.circle",
                        text: "2024–2027 年内置（2027 年依据国办发明电〔2026〕10号）；之后的年份在启动时从 holiday-cn（整理自国务院放假通知）自动补充。在创建或修改「工作日 / 休息日」重复任务时生效。" + (model.holidayStatus.map { " " + $0 } ?? ""))
            }
        }
    }
}

private struct WeekPreview: View {
    let today: LocalDate
    let weekStart: Int

    var body: some View {
        let start = today.adding(days: -floorMod(today.weekday - weekStart, 7))
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { offset in
                let day = start.adding(days: offset)
                let isToday = day == today
                let weekend = day.pythonWeekday >= 5
                let lunar = LunarCalendar.lunarDay(for: day)
                VStack(spacing: 2) {
                    Text(LocalDate.weekdayShortNames[day.weekday])
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isToday ? Color.white.opacity(0.9) : (weekend ? Color(hex: 0xD9534A) : Theme.subtext))
                    Text(verbatim: "\(day.day)")
                        .font(.system(size: 17, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? Color.white : (weekend ? Color(hex: 0xD9534A) : Theme.text))
                    Text(lunar.map { $0.day == 1 ? LunarCalendar.monthName($0.month, leap: $0.isLeap) : LunarCalendar.dayName($0.day) } ?? "")
                        .font(.system(size: 9.5))
                        .foregroundStyle(isToday ? Color.white.opacity(0.85) : Theme.fieldName)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(isToday ? Theme.accent : Theme.panel))
                .overlay(alignment: .topTrailing) {
                    if ChinaMakeup.days.contains(day) {
                        let badge = weekend ? "班" : "休"
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(badge == "休" ? Color(hex: 0xE5483A) : Theme.subtext))
                            .offset(x: 3, y: -3)
                    }
                }
            }
        }
    }
}

// MARK: - 高级

private struct AdvancedPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("显示") {
                ThemedRow("检查器中显示云端字段名") { ThemedSwitch(isOn: $model.showFieldNames) }
            }

            InspectorSection("本机文件") {
                PathRow(title: "本地数据库", url: try? LocalStore.defaultURL())
                PathRow(title: "同步诊断日志", url: SyncDiagnostics.fileURL)
            }

            InspectorSection("数据检查") {
                ThemedRow("数据问题") {
                    if model.snapshot.warnings.isEmpty {
                        StatusPill(text: "无", color: Theme.done)
                    } else {
                        StatusPill(text: "\(model.snapshot.warnings.count) 个", color: Theme.overdue)
                    }
                }
                ForEach(Array(model.snapshot.warnings.prefix(5).enumerated()), id: \.offset) { _, warning in
                    NoteRow(icon: "exclamationmark.bubble", text: warning)
                }
            }

            InspectorSection("实验功能") {
                ThemedRow("本机 MCP 服务（127.0.0.1:42682）") {
                    StatusPill(text: "P7 计划中", color: Theme.subtext)
                }
            }
        }
    }
}

private struct PathRow: View {
    let title: String
    let url: URL?

    private var display: String {
        guard let path = url?.path else { return "—" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        ThemedRow(title) {
            HStack(spacing: 8) {
                Text(display)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: 280, alignment: .trailing)
                Button("显示") { reveal() }
                    .buttonStyle(.themed)
                    .disabled(url == nil)
            }
        }
    }

    private func reveal() {
        guard let url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
