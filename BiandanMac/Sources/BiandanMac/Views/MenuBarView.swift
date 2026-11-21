import AppKit
import SwiftUI

enum MenuBarDefaults {
    /// 是否在菜单栏显示便单（默认显示）。AppDelegate 也读它，决定关窗后是否退出。
    static let showKey = "biandan.showMenuBarExtra"

    static var isShown: Bool {
        UserDefaults.standard.object(forKey: showKey) as? Bool ?? true
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

/// 菜单栏图标：今天 + 逾期的待办数。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.authState == .signedIn ? model.menuBarBadge : 0
        HStack(spacing: 3) {
            Image(systemName: "checklist")
            if count > 0 { Text("\(count)") }
        }
        .registersMainWindowOpener()
    }
}

/// 菜单栏弹出面板：逾期与今天的待办，可直接完成。
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if model.authState == .signedIn {
                list
            } else {
                Text("尚未登录华为账号")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(Theme.background)
        .registersMainWindowOpener()
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
            .frame(height: min(CGFloat(entries.items.count) * 40, 360))
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
