import AppKit
import SwiftUI

enum MenuBarDefaults {
    /// 是否在菜单栏显示便单（默认显示）。AppDelegate 也读它，决定关窗后是否退出。
    static let showKey = "biandan.showMenuBarExtra"
    /// 菜单栏图标旁显示下一场倒计时（默认显示）。
    static let countdownKey = "biandan.menuBarCountdown"
    /// 隐藏 Dock 图标（默认不隐藏；只有菜单栏图标显示时才生效）。
    static let hideDockKey = "biandan.hideDockIcon"

    static var isShown: Bool {
        UserDefaults.standard.object(forKey: showKey) as? Bool ?? true
    }

    static var showsCountdown: Bool {
        UserDefaults.standard.object(forKey: countdownKey) as? Bool ?? true
    }

    static var hidesDock: Bool {
        UserDefaults.standard.bool(forKey: hideDockKey)
    }

    /// 菜单栏图标不显示时一定保留 Dock 图标，免得找不到便单。
    static var activationPolicy: NSApplication.ActivationPolicy {
        isShown && hidesDock ? .accessory : .regular
    }

    @MainActor
    static func applyDockPolicy() {
        let policy = activationPolicy
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 把 openWindow 交给 AppModel，菜单栏和通知点击都能唤起主窗口。
private struct MainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            model.openMainWindow = { open(id: "main") }
        }
    }
}

extension View {
    func registersMainWindowOpener() -> some View {
        modifier(MainWindowOpener())
    }
}

/// 菜单栏图标：打开倒计时时显示下一场 / 进行中的日程，否则显示今天 + 逾期的待办数。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    private let clock = MenuBarClock.shared

    var body: some View {
        let signedIn = model.authState == .signedIn
        let count = signedIn ? model.menuBarBadge : 0
        let countdown: String? = signedIn && model.menuBarCountdown ? model.menuBarCountdownText(now: clock.now) : nil
        HStack(spacing: 3) {
            Image(systemName: "checklist")
            if let countdown {
                Text(verbatim: countdown)
            } else if count > 0 {
                Text("\(count)")
            }
        }
        .registersMainWindowOpener()
    }
}

/// 菜单栏弹出面板：第一屏是「现在该做什么、还剩多久」，下面是逾期与今天的待办（可直接完成），底部常驻快速添加。
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let signedIn = model.authState == .signedIn
        VStack(alignment: .leading, spacing: 10) {
            header
            if signedIn { MenuBarFocusCard() }
            Divider()
            if signedIn {
                list
            } else {
                Text("尚未登录华为账号")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .padding(.vertical, 6)
            }
            if signedIn { MenuBarQuickAdd() }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .background(Theme.background)
        .registersMainWindowOpener()
        .onAppear { MenuBarClock.shared.tick() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今天")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(model.today.month) 月 \(model.today.day) 日")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer()
            if model.authState == .signedIn {
                let counts = model.snapshot.counts(today: model.today, weekStart: model.weekStart)
                HStack(spacing: 10) {
                    Text("待办 \(counts.today)")
                        .foregroundStyle(Theme.text)
                    if counts.overdue > 0 {
                        Text("逾期 \(counts.overdue)")
                            .foregroundStyle(Theme.overdue)
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    @ViewBuilder private var list: some View {
        let entries = model.menuBarItems()
        if entries.items.isEmpty {
            Label("今天没有待办", systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .padding(.vertical, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entries.items) { item in
                        MenuBarRow(item: item)
                    }
                }
            }
            .frame(height: min(CGFloat(entries.items.count) * 40, 240))
            if entries.total > entries.items.count {
                Text("还有 \(entries.total - entries.items.count) 项，在便单中查看")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            footerButton("新建", "plus") {
                model.newTaskPreset = model.makeNewTaskPreset()
                model.showMainWindow()
            }
            .disabled(model.authState != .signedIn)
            footerButton("同步", "arrow.triangle.2.circlepath") {
                Task { await model.syncNow() }
            }
            .disabled(model.authState != .signedIn)
            Spacer()
            // 隐藏 Dock 图标后没有顶部菜单，从这里进设置。
            SettingsLink {
                Label("设置", systemImage: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            footerButton("打开便单", "macwindow") { model.showMainWindow() }
            footerButton("退出", "power") { NSApp.terminate(nil) }
        }
    }

    private func footerButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - 现在该做什么

private struct MenuBarFocusCard: View {
    @Environment(AppModel.self) private var model
    private let clock = MenuBarClock.shared

    var body: some View {
        let now = clock.now
        let focus = model.agendaFocus(now: now)
        VStack(alignment: .leading, spacing: 9) {
            if let current = focus.current {
                MenuBarSlotRow(slot: current, now: now, running: true)
            }
            if let next = focus.next {
                MenuBarSlotRow(slot: next, now: now, running: false)
            }
            if focus.current == nil && focus.next == nil {
                MenuBarFreeRow()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

private struct MenuBarFreeRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.done)
            VStack(alignment: .leading, spacing: 1) {
                Text("现在没有要赶的日程")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("今天接下来没有定时日程")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
        }
    }
}

private struct MenuBarSlotRow: View {
    @Environment(AppModel.self) private var model
    let slot: AgendaSlot
    let now: Date
    let running: Bool

    var body: some View {
        let tint: Color = running ? Theme.done : Theme.accent
        let tag: String = running ? "进行中" : "下一场"
        let detail: String = running
            ? MenuBarAgenda.runningDetail(slot, now: now) : MenuBarAgenda.upcomingDetail(slot, now: now)
        let detailColor: Color = running ? Theme.text : Theme.subtext
        Button {
            model.revealOccurrence(slot.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: tag)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tint))
                    Text(verbatim: slot.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(detailColor)
                if running {
                    MenuBarProgressBar(fraction: MenuBarAgenda.progress(slot, now: now), tint: tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在便单中查看")
    }
}

private struct MenuBarProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule().fill(tint).frame(width: geometry.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - 常驻快速添加：写法同快速添加栏，没写日期时记在今天

private struct MenuBarQuickAdd: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var saving = false
    @State private var done: String?

    private var preset: NewTaskPreset {
        var preset = NewTaskPreset()
        preset.date = model.today
        return preset
    }

    var body: some View {
        let draft = model.parseQuickAdd(text)
        let current = preset
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                TextField("", text: $text, prompt: Text("快速添加，如：下午3点 评审会"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit { submit(draft, preset: current) }
                    .disabled(saving)
                if saving { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            hint(draft, preset: current)
        }
    }

    @ViewBuilder
    private func hint(_ draft: QuickAddDraft, preset: NewTaskPreset) -> some View {
        if !draft.title.isEmpty {
            if let warning = model.quickAddConflictText(draft, preset: preset) {
                Text(verbatim: warning)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.overdue)
                    .lineLimit(1)
            }
            Text(verbatim: model.quickAddHint(draft, preset: preset))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtext)
                .lineLimit(1)
        } else if let done {
            Label(done, systemImage: "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.done)
                .lineLimit(1)
        } else {
            Text("回车保存，没写日期时记在今天")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.fieldName)
        }
    }

    private func submit(_ draft: QuickAddDraft, preset: NewTaskPreset) {
        guard !saving, let input = QuickAddParser.input(draft, preset: preset) else { return }
        saving = true
        let title = draft.title
        Task {
            let ok = await model.createTask(input)
            saving = false
            if ok {
                text = ""
                done = "已添加「" + title + "」"
            }
        }
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let item: OccurrenceItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.toggleCompletion(item) }
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(overdue ? Theme.overdue : Theme.subtext)
            }
            .buttonStyle(.plain)
            .help("完成")

            Button {
                model.revealOccurrence(item.id)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(overdue ? Theme.overdue : Theme.subtext)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.accent.opacity(0.08) : Color.clear))
        .onHover { hovering = $0 }
    }

    private var overdue: Bool { item.isOverdue(today: model.today) }

    private var detail: String {
        var parts: [String] = []
        if overdue, let end = item.occurrence.endDate {
            parts.append("逾期 · \(end.month)月\(end.day)日")
        }
        let start = item.occurrence.validStartTime
        let end = item.occurrence.validEndTime
        if start.hasPrefix("00:00") && end.hasPrefix("23:59") {
            parts.append("全天")
        } else {
            parts.append("\(start.prefix(5))–\(end.prefix(5))")
        }
        let progress = item.progress
        if progress.targetCount > 1 {
            parts.append("\(progress.completedCount)/\(progress.targetCount)")
        }
        if let list = model.snapshot.list(item.task.id3), !list.isDefault {
            parts.append(list.favoritesName)
        }
        return parts.joined(separator: " · ")
    }
}
