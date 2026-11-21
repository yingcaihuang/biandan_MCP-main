import Combine
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
    @Environment(AppModel.self) private var model

    /// 从确认卡片等地方跳过来时，切到对应分区、滚动到位置并短暂高亮。
    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = model.settingsAnchor else { return }
        model.settingsAnchor = nil
        paneRaw = SettingsPane.advanced.rawValue
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(anchor.rawValue, anchor: .top) }
            withAnimation(.easeOut(duration: 0.2)) { model.settingsHighlight = anchor }
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut(duration: 0.5)) {
                if model.settingsHighlight == anchor { model.settingsHighlight = nil }
            }
        }
    }

    var body: some View {
        let pane = SettingsPane(rawValue: paneRaw) ?? .account
        HStack(spacing: 0) {
            SettingsSidebar(selection: Binding(get: { pane }, set: { paneRaw = $0.rawValue }))
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollViewReader { proxy in
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
                .onAppear { scrollToAnchor(proxy) }
                .onChange(of: model.settingsAnchor) { _, _ in scrollToAnchor(proxy) }
            }
        }
        .frame(minWidth: 740, idealWidth: 820, maxWidth: .infinity, minHeight: 540, idealHeight: 640, maxHeight: .infinity)
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

/// 待同步队列里的一条：修改名称 · 对象、入队时间与尝试次数、最后一次错误，可重试或放弃。
private struct OutboxEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: OutboxEntry

    var body: some View {
        let failed = entry.state == OutboxEntry.failed
        let label = entry.payload?.label ?? entry.command
        let subject = model.outboxSubject(entry)
        let title: String = subject.map { label + " · " + $0 } ?? label
        let iconColor: Color = failed ? Theme.overdue : Color(hex: 0xE8890C)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failed ? "xmark.octagon.fill" : "clock.arrow.circlepath")
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(verbatim: OutboxDisplay.detail(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                if let error = entry.lastError, !error.isEmpty {
                    Text(verbatim: error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.overdue)
                        .lineLimit(2)
                        .help(error)
                }
            }
            Spacer(minLength: 8)
            Button(failed ? "重新写入" : "重试") {
                let id = entry.opID
                Task { await model.retryOutboxEntry(id) }
            }
            .buttonStyle(.themed)
            Button("放弃") { model.discardOutboxEntry(entry.opID) }
                .buttonStyle(.themedDestructive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                        StatCell(title: "分类", value: model.snapshot.lists.count)
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
                    ValueText(text: "\(model.snapshot.lists.count) 个分类 · \(model.snapshot.tasks.count) 个任务 · \(model.snapshot.occurrences.count) 个实例",
                              color: Theme.subtext)
                }
                NoteRow(icon: "gauge.with.dots.needle.33percent",
                        text: "定时和切回窗口触发的自动同步至少间隔 1 分钟，本地超过 3000 条时放宽到 3 分钟；连续失败时按 30 秒、1、2、4… 分钟退避，最长 30 分钟。手动同步不受限制，只在云端要求稍后再试时等待。"
                            + (model.syncThrottle.consecutiveFailures > 0
                               ? " 已连续失败 \(model.syncThrottle.consecutiveFailures) 次。" : ""))
            }

            InspectorSection("待同步队列") {
                ThemedRow("等待写入云端") {
                    HStack(spacing: 8) {
                        StatusPill(text: model.outboxPending == 0 ? "无" : "\(model.outboxPending) 项",
                                   color: model.outboxPending == 0 ? Theme.done : Color(hex: 0xE8890C))
                        if model.outboxPending > 0 {
                            Button("立即重试") { Task { await model.flushOutbox() } }
                                .buttonStyle(.themed)
                        }
                    }
                }
                if model.outboxFailed > 0 {
                    ThemedRow("已放弃") {
                        HStack(spacing: 8) {
                            StatusPill(text: "\(model.outboxFailed) 项", color: Theme.overdue)
                            Button("清除") { model.clearFailedOutbox() }
                                .buttonStyle(.themed)
                        }
                    }
                }
                ForEach(Array(model.outboxEntries.prefix(30)), id: \.opID) { entry in
                    OutboxEntryRow(entry: entry)
                }
                if model.outboxEntries.count > 30 {
                    NoteRow(icon: "ellipsis", text: "还有 \(model.outboxEntries.count - 30) 项未显示。")
                }
                if !model.outboxEntries.isEmpty {
                    NoteRow(icon: "arrow.uturn.backward",
                            text: "「放弃」会撤回这条修改，界面恢复为云端状态；排在它后面、依赖它的修改可能随之失败。")
                }
                NoteRow(icon: "info.circle",
                        text: "断网、超时或云端暂时不可用时，完成、改期、编辑等修改会先保存在本机，联网后按顺序自动写入。"
                            + (model.outboxLastError.map { " 上次失败：" + $0 } ?? ""))
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
                ThemedRow("完成圆圈使用分类颜色") { ThemedSwitch(isOn: $model.tintCheckboxByList) }
            }

            InspectorSection("本机文件") {
                PathRow(title: "本地数据库", url: try? LocalStore.defaultURL())
                PathRow(title: "同步诊断日志", url: SyncDiagnostics.fileURL)
            }

            ExportSettingsSection()

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

            ReminderSettingsSection()
            CaptureSettingsSection()
            AISettingsSection()
                .id(SettingsAnchor.ai.rawValue)

            MCPSettingsSection()
        }
    }
}

// MARK: - 导出与备份

private struct ExportSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var backingUp = false

    private var backupText: String {
        guard let date = model.lastBackupAt else { return "还没有备份" }
        return "上次 " + date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        InspectorSection("导出与备份") {
            ForEach(ExportFormat.allCases) { format in
                ThemedRow(format.title) {
                    HStack(spacing: 8) {
                        Text(verbatim: format.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                            .lineLimit(1)
                        Button("导出…") { model.exportData(format) }
                            .buttonStyle(.themed)
                    }
                }
            }
            ThemedRow("本地自动备份") {
                HStack(spacing: 8) {
                    ValueText(text: backupText, color: Theme.subtext)
                    Button(backingUp ? "备份中…" : "立即备份") {
                        Task {
                            backingUp = true
                            await model.backupNow()
                            backingUp = false
                        }
                    }
                    .buttonStyle(.themed)
                    .disabled(backingUp)
                }
            }
            PathRow(title: "备份文件夹", url: LocalBackup.directoryURL)
            if let notice = model.exportNotice {
                NoteRow(icon: "checkmark.circle", text: notice)
            }
            NoteRow(icon: "externaldrive",
                    text: "每天第一次同步成功后自动保存一份完整 JSON 备份，保留最近 7 份。导出和备份都是只读的，不会改动云端数据。")
        }
    }
}

// MARK: - 通知与菜单栏

// MARK: - 桌面浮窗球与识别日程

private struct CaptureSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        @Bindable var model = model
        InspectorSection("桌面浮窗球与识别日程") {
            SettingRow("桌面浮窗球", caption: "单击框选、双击截整屏、右键更多，也可以把文字或图片拖到球上") {
                ThemedSwitch(isOn: $model.showFloatingBall)
            }
            SettingRow("屏幕录制权限", caption: "框选和截整屏需要；识别剪贴板和拖入不需要") {
                HStack(spacing: 8) {
                    StatusPill(text: screenGranted ? "已授权" : "未授权",
                               color: screenGranted ? Theme.done : Theme.subtext)
                    Button("打开系统设置") { NSWorkspace.shared.open(ScheduleCaptureFlow.screenRecordingSettings) }
                        .buttonStyle(.themed)
                }
            }
            SettingRow("自动选择分类", caption: "没有对应分类时建议新建，点「添加选中」时才真正建好") {
                ThemedSwitch(isOn: $model.autoCreateCaptureCategory)
            }
            SettingRow("自动定位地点", caption: "用 Apple 地图查坐标，添加时一起写进任务，不开地点提醒") {
                ThemedSwitch(isOn: $model.autoLocateCapturePlace)
            }
            SettingFootnotes(items: [
                SettingFootnote(icon: "lock.shield",
                                text: "截图只在内存里处理，不存盘、不上传，文字在本机识别。macOS 26 起用系统端侧模型提取，其他情况用规则识别，识别不到时可以用 AI 兜底。"),
                SettingFootnote(icon: "mappin.and.ellipse",
                                text: "定位时地点查询词会发给 Apple 地图服务；关掉后只保存地点名称，卡片里也可以手动定位。"),
            ])
        }
        // 从系统设置切回来时刷新授权状态。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }
}

// MARK: - AI 识别日程

private struct AISettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var testing = false
    @State private var status: TestStatus?

    private struct TestStatus {
        let ok: Bool
        let text: String
    }

    private var trimmedKey: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var settings = model
        InspectorSection("AI 识别日程") {
            SettingRow("使用 AI", caption: modeCaption) {
                ThemedSegmented(selection: $settings.aiExtractionMode,
                                options: AIExtractionMode.allCases.map { ThemeOption(value: $0, title: $0.title) })
            }
            SettingRow("模型", caption: "Flash 速度快、费用低；V4 Pro 更准，但慢一些") {
                ThemedSegmented(selection: $settings.aiModelName,
                                options: AIModelOption.allCases.map { ThemeOption(value: $0.rawValue, title: $0.title) })
            }
            SettingRow("API Key", caption: "存在本机钥匙串里，不写进配置文件") { keyField }
            if let keyError {
                NoteRow(icon: "exclamationmark.triangle", text: keyError)
            }
            SettingRow("接口地址", caption: "默认 DeepSeek，也可换成其他兼容 OpenAI 格式的服务") {
                TextField("", text: $settings.aiBaseURL, prompt: Text(AIExtractionSettings.defaultBaseURL))
                    .themedField()
                    .frame(width: 250)
            }
            SettingRow("测试连接", caption: "用一句示例试一次完整识别，显示结果、用时和费用") {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Button("测试", action: test)
                        .buttonStyle(.themed)
                        .disabled(!model.aiKeyConfigured || testing)
                }
            }
            if let status {
                NoteRow(icon: status.ok ? "checkmark.circle" : "exclamationmark.triangle", text: status.text)
            }
            SettingFootnotes(items: [
                SettingFootnote(icon: "lock.shield",
                                text: "只发送识别出的文字，不发送截图；文字会经过 DeepSeek 的服务器，处理敏感聊天时可以选「关闭」。"),
                SettingFootnote(icon: "sparkles",
                                text: "内置系统提示词规定了输出格式和日期、时刻、地点的换算规则，要求不编造、不执行聊天文字里的指令。确认卡片里也可以点「用 AI 识别」手动重跑。"),
                SettingFootnote(icon: "chart.bar.xaxis",
                                text: "每次识别的用时、Token 和预估费用都记在本机，可在侧栏「统计 → AI 识别」查看报表、导出 CSV。"),
            ], link: ("去 DeepSeek 开放平台申请 API Key", URL(string: "https://platform.deepseek.com/api_keys")!))
        }
        .task { model.refreshAIKeyStatus() }
        // 从确认卡片跳过来时短暂高亮这一组。
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.accent.opacity(model.settingsHighlight == .ai ? 0.16 : 0))
                .padding(-8)
        )
    }

    private var modeCaption: String {
        switch model.aiExtractionMode {
        case .off: return "不使用 AI，只在本机识别"
        case .fallback: return "本机识别没找到日程时，才把文字交给 AI"
        case .always: return "每次先用 AI，失败时退回本机识别"
        }
    }

    private var keyField: some View {
        let saved = model.aiKeyConfigured
        return HStack(spacing: 6) {
            StatusPill(text: saved ? "已保存" : "未填写", color: saved ? Theme.done : Theme.subtext)
            SecureField("", text: $keyDraft, prompt: Text(saved ? "输入新的可替换" : "sk-…"))
                .themedField()
                .frame(width: 170)
                .onSubmit(saveKey)
            Button("保存", action: saveKey)
                .buttonStyle(.themed)
                .disabled(trimmedKey.isEmpty)
            if model.aiKeyConfigured {
                Button("清除") {
                    AIKeyStore.clear()
                    model.refreshAIKeyStatus()
                    status = nil
                }
                .buttonStyle(.themed)
            }
        }
    }

    private func saveKey() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        do {
            try AIKeyStore.save(key)
            keyDraft = ""
            keyError = nil
            status = nil
            model.refreshAIKeyStatus()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        status = nil
        let settings = model.aiExtractionSettings()
        let today = model.today
        Task { @MainActor in
            do {
                let text = try await AIScheduleExtractor.test(settings: settings, today: today)
                status = TestStatus(ok: true, text: text)
            } catch {
                status = TestStatus(ok: false, text: error.localizedDescription)
            }
            testing = false
        }
    }
}

private struct ReminderSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false
    @State private var working = false

    var body: some View {
        @Bindable var model = model
        InspectorSection("通知与菜单栏") {
            SettingRow("时间提醒通知", caption: "按任务的提醒日期和时刻弹出通知") {
                ThemedSwitch(isOn: $model.remindersEnabled)
            }
            ThemedRow("系统授权") {
                HStack(spacing: 8) {
                    if let checked = model.reminderCheckedAt {
                        Text("\(checked.formatted(date: .omitted, time: .standard)) 检查")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                    }
                    StatusPill(text: model.reminderStatus.title, color: statusColor)
                    Button(checking ? "检查中…" : "重新检查") {
                        Task {
                            checking = true
                            await model.refreshReminderStatus()
                            checking = false
                        }
                    }
                    .buttonStyle(.themed)
                    .disabled(checking)
                }
            }
            if let guide = Self.guide(for: model.reminderStatus) {
                GuideSteps(title: guide.title, steps: guide.steps)
            }
            actionRow
            if let notice = model.reminderNotice {
                NoteRow(icon: "bell.badge", text: notice)
            }
            if model.remindersEnabled && model.reminderStatus.isAuthorized {
                ThemedRow("已排定的提醒") {
                    Text("\(model.scheduledReminderCount) 条")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                }
            }
            SettingRow("在菜单栏显示便单", caption: "显示时关闭主窗口不会退出应用") {
                ThemedSwitch(isOn: $model.showMenuBarExtra)
            }
            SettingRow("全局快速添加", caption: "在任何 App 里按快捷键弹出输入框记任务") {
                ThemedSegmented(selection: $model.quickAddHotKey,
                                options: QuickAddHotKey.allCases.map { ThemeOption(value: $0, title: $0.title) })
            }
            if let status = model.quickAddHotKeyStatus {
                NoteRow(icon: "exclamationmark.triangle", text: status)
            }
            SettingFootnotes(items: [
                SettingFootnote(icon: "bell",
                                text: "一次性任务按提醒日期和时刻通知；重复任务排定近 14 天、最多 60 条。通知上可以直接点「完成」或稍后提醒。地点提醒仍由手机处理。"),
                SettingFootnote(icon: "keyboard",
                                text: "快速添加的写法与快速添加栏相同，没写日期时默认今天，不需要辅助功能权限。"),
            ])
        }
        .task { await model.refreshReminderStatus() }
        // 从系统设置切回来时自动重新检查。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshReminderStatus() }
        }
    }

    private var statusColor: Color {
        switch model.reminderStatus {
        case .authorized: return Theme.done
        case .denied: return Theme.overdue
        case .silenced: return Theme.accent
        case .notDetermined, .unavailable: return Theme.subtext
        }
    }

    /// 按授权状态给出的下一步按钮。
    @ViewBuilder private var actionRow: some View {
        switch model.reminderStatus {
        case .notDetermined:
            ThemedRow("下一步") {
                Button("请求授权") { run { await model.requestReminderAuthorization() } }
                    .buttonStyle(.themedPrimary)
                    .disabled(working)
            }
        case .denied, .silenced:
            ThemedRow("下一步") {
                Button("打开系统设置") { model.openNotificationSettings() }
                    .buttonStyle(.themedPrimary)
            }
        case .authorized:
            ThemedRow("校验") {
                Button("发送测试通知") { run { await model.sendTestReminder() } }
                    .buttonStyle(.themed)
                    .disabled(working)
            }
        case .unavailable:
            EmptyView()
        }
    }

    private func run(_ body: @escaping () async -> Void) {
        Task {
            working = true
            await body()
            working = false
        }
    }

    static func guide(for status: ReminderStatus) -> (title: String, steps: [String])? {
        switch status {
        case .unavailable:
            return ("当前是直接运行的可执行文件，系统不允许它发送通知", [
                "在终端进入 BiandanMac 目录，运行 Tools/build_app.sh 打包",
                "退出当前运行的便单，打开打包生成的 便单.app",
                "回到「设置 → 高级」，点「重新检查」",
            ])
        case .notDetermined:
            return ("还没有向系统申请通知权限", [
                "点下方「请求授权」",
                "在系统弹出的窗口里选择「允许」",
                "状态变成「已授权」后，点「发送测试通知」确认能正常弹出",
            ])
        case .denied:
            return ("通知权限已被关闭，系统不会再弹出授权窗口", [
                "点下方「打开系统设置」，进入「通知」",
                "在应用列表中找到「便单」，打开「允许通知」",
                "提醒样式选择「横幅」或「提醒」",
                "切回便单会自动重新检查，也可以点「重新检查」",
            ])
        case .silenced:
            return ("已授权，但提醒样式为「无」，通知只进通知中心、不会弹出", [
                "点下方「打开系统设置」，进入「通知 → 便单」",
                "把提醒样式改为「横幅」或「提醒」",
                "切回便单后点「发送测试通知」确认",
            ])
        case .authorized:
            return ("通知权限正常", [
                "点下方「发送测试通知」，约 2 秒后应弹出横幅",
                "没看到横幅时，检查是否开启了专注模式（勿扰）",
                "打开上方「时间提醒通知」后，任务的时间提醒会按时弹出",
            ])
        }
    }
}

/// 带序号的分步引导。
private struct GuideSteps: View {
    let title: String
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Theme.accent))
                    Text(step)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x4A453C))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

// MARK: - 本机 MCP 服务

private struct MCPSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var revealKey = false

    var body: some View {
        @Bindable var model = model
        InspectorSection("本机 MCP 服务") {
            ThemedRow("启用（127.0.0.1:\(String(MCPHTTP.defaultPort))）") {
                ThemedSwitch(isOn: $model.mcpEnabled)
            }
            ThemedRow("状态") {
                HStack(spacing: 8) {
                    StatusPill(text: model.mcpStatus.title, color: mcpColor)
                    if model.mcpStatus.failureMessage != nil && model.mcpEnabled {
                        Button("重试") { model.restartMCP() }
                            .buttonStyle(.themed)
                    }
                }
            }
            if let message = model.mcpStatus.failureMessage {
                NoteRow(icon: "exclamationmark.triangle", text: message)
            }
            ThemedRow("访问密钥") {
                HStack(spacing: 8) {
                    Text(keyDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.mcpAccessKey == nil ? Theme.subtext : Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: 310, alignment: .trailing)
                    Button(revealKey ? "隐藏" : "显示") { revealKey.toggle() }
                        .buttonStyle(.themed)
                        .disabled(model.mcpAccessKey == nil)
                    CopyButton(title: "拷贝") { model.copyMCPKey() }
                        .disabled(model.mcpAccessKey == nil)
                }
            }
            ThemedRow("AI 客户端配置") {
                CopyButton(title: "拷贝配置") { model.copyMCPConfig() }
            }
            if let config = model.mcpConfigText(revealed: revealKey) {
                CodeBlockRow(text: config)
            } else {
                NoteRow(icon: "key", text: "打开上方开关（或点「拷贝配置」）后会生成访问密钥，并在这里显示客户端配置。")
            }
            if let notice = model.mcpNotice {
                NoteRow(icon: "checkmark.circle", text: notice)
            }
            if model.mcpCallCount > 0 {
                ThemedRow("已处理工具调用") {
                    Text("\(model.mcpCallCount) 次")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                }
            }
            NoteRow(icon: "info.circle",
                    text: "密钥保存在 \(keyPath)，与 Python 版共用端口和访问密钥，已配置好的 Claude、Codex 无需修改；请勿同时运行 Python 版。AI 写入后界面会立即刷新。")
        }
        .task { model.loadMCPKeyIfPresent() }
    }

    private var keyDisplay: String {
        guard let token = model.mcpAccessKey else { return "启用服务后生成" }
        return revealKey ? token : MCPAccessKey.masked(token)
    }

    private var keyPath: String {
        let path = MCPAccessKey.fileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var mcpColor: Color {
        switch model.mcpStatus {
        case .running: return Theme.done
        case .failed: return Theme.overdue
        case .off, .starting: return Theme.subtext
        }
    }
}

/// 点击后变成「✓ 已拷贝」，2 秒后恢复。action 返回 false 时不显示。
private struct CopyButton: View {
    let title: String
    let action: () -> Bool
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard action() else { return }
            copied = true
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { copied = false }
            }
        } label: {
            Label(copied ? "已拷贝" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.themed)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

/// 等宽字体的代码块，可选中文字，过宽时横向滚动。
private struct CodeBlockRow: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF7F3EA)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xE6DFD0), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
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
