import SwiftUI

// MARK: - 侧栏账户卡片（点击弹出主题账户面板，替代系统 Menu）

struct AccountCard: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var hovering = false

    private var status: (text: String, color: Color) {
        switch model.syncStatus {
        case .syncing: return ("正在同步…", Theme.accent)
        case .failed: return ("同步失败，点开查看", Theme.overdue)
        case .idle:
            if model.isSavingInBackground { return ("正在保存更改…", Theme.accent) }
            if model.outboxPending > 0 { return ("\(model.outboxPending) 项修改待同步", Color(hex: 0xE8890C)) }
            return RenewalText.cardStatus(days: model.renewal?.daysUntilRelogin(now: Date()))
        }
    }

    var body: some View {
        let current = status
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 10) {
                AccountAvatar(profile: model.profile, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.profile.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(current.color).frame(width: 6, height: 6)
                        Text(current.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(open ? Color(hex: 0x9A7400) : Theme.subtext)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(open || hovering ? Theme.accent.opacity(0.2) : Color(hex: 0xEEE8DA)))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(open ? Theme.accent : Theme.line, lineWidth: open ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("账户与同步")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            AccountPanel { open = false }
                .environment(model)
        }
    }
}

// MARK: - 账户面板

struct AccountPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let close: () -> Void

    private var syncDetail: String {
        switch model.syncStatus {
        case .syncing(let message): return message
        case .failed(let message): return message
        case .idle:
            if model.isSavingInBackground { return "正在保存 \(model.backgroundOperations) 项更改…" }
            if let last = model.lastSyncedAt { return "上次同步 " + last.formatted(date: .omitted, time: .shortened) }
            return "尚未同步"
        }
    }

    var body: some View {
        let counts = model.counts
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AccountAvatar(profile: model.profile, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.profile.displayName)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("华为账号 · 凭据保存在本机钥匙串")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                stat("分类", model.snapshot.lists.count)
                statDivider
                stat("任务", model.snapshot.tasks.count)
                statDivider
                stat("待完成", counts.allPending)
                statDivider
                stat("专注", model.snapshot.focus.count)
            }
            .padding(.vertical, 8)
            .themedCard()

            TimelineView(.periodic(from: .now, by: 30)) { context in
                RenewalSummary(renewal: model.renewal, now: context.date)
            }

            VStack(spacing: 0) {
                ThemedMenuRow(icon: "arrow.clockwise", title: "立即同步", detail: syncDetail,
                              tint: Theme.accent, shortcut: "⌘R", busy: model.syncStatus.isSyncing) {
                    Task { await model.syncNow() }
                }
                .disabled(model.syncStatus.isSyncing)
                rowSeparator
                ThemedMenuRow(icon: "gearshape", title: "设置…", tint: Theme.subtext, shortcut: "⌘,") {
                    close()
                    openSettings()
                }
            }
            .themedCard()

            VStack(spacing: 0) {
                ThemedMenuRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录…",
                              tint: Theme.overdue, destructive: true) {
                    close()
                    // 等弹出面板收起后再打开确认弹窗。
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        model.signOutRequested = true
                    }
                }
            }
            .themedCard()
        }
        .padding(14)
        .frame(width: 290)
        .background(Theme.panel)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(value)")
                .font(.system(size: 16, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Color(hex: 0xF0EADD)).frame(width: 1, height: 26)
    }

    private var rowSeparator: some View {
        Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1).padding(.leading, 46)
    }
}

// MARK: - 退出登录确认（替代系统 confirmationDialog）

struct SignOutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keepCache = true
    @State private var working = false

    var body: some View {
        ThemedSheet("退出华为账号", subtitle: "退出后需要在浏览器里重新授权才能再次同步",
                    tag: ThemeTag(text: "需要重新授权", color: Theme.overdue)) {
            HStack(spacing: 12) {
                AccountAvatar(profile: model.profile, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.profile.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("钥匙串里的华为凭据会被删除")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtext)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .themedCard()

            InspectorSection("本机数据") {
                ThemedChoiceList(selection: $keepCache, options: [
                    ThemeOption(value: true, title: "保留本地缓存（下次登录打开更快）"),
                    ThemeOption(value: false, title: "清除本地数据（待办只保存在云端）"),
                ])
            }

            if model.isSavingInBackground {
                Label("还有 \(model.backgroundOperations) 项更改正在保存，现在退出会中断。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.overdue)
            }
        } footer: {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("退出登录", role: .destructive) { signOut() }
                .buttonStyle(.themedDestructive)
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        }
        .frame(width: 440, height: 400)
    }

    private func signOut() {
        working = true
        let keep = keepCache
        Task {
            await model.signOut(keepCache: keep)
            working = false
            dismiss()
        }
    }
}
