import AppKit
import SwiftUI

// MARK: - 上手清单：「今天」页顶部的卡片，做完自动打勾；设置里的「新手指引」分区

struct OnboardingChecklistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    private var onboarding: Onboarding { .shared }

    var body: some View {
        let done = onboarding.doneItems(model: model)
        let progress = Onboarding.progress(done)
        let finished = progress.done >= progress.total
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            header(progress, finished: finished)
            if !onboarding.checklistCollapsed {
                if finished { celebration }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(ChecklistItem.allCases) { item in
                        ChecklistTile(item: item, done: done.contains(item)) { perform(item) }
                    }
                }
            }
        }
        .padding(14)
        .background(shape.fill(Theme.card))
        .overlay(shape.stroke(Theme.line))
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: onboarding.checklistCollapsed)
        .onAppear {
            model.reloadImportSources()
            Task { await model.refreshReminderStatus() }
        }
    }

    private func header(_ progress: (done: Int, total: Int), finished: Bool) -> some View {
        let fraction = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        return HStack(spacing: 10) {
            Image(systemName: finished ? "party.popper" : "flag.checkered")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selectionFill))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("上手清单").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Theme.text)
                    Text(verbatim: "完成 \(progress.done) / \(progress.total)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.subtext)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.accent).frame(width: max(geometry.size.width * fraction, fraction > 0 ? 6 : 0))
                    }
                }
                .frame(width: 180, height: 5)
            }
            Spacer(minLength: 0)
            Button {
                onboarding.checklistCollapsed.toggle()
            } label: {
                Image(systemName: onboarding.checklistCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.subtext)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(onboarding.checklistCollapsed ? "展开" : "收起")
            Button(finished ? "完成" : "不再显示") { onboarding.checklistHidden = true }
                .buttonStyle(.themed)
                .help("之后可以在「帮助 → 上手清单」里重新打开")
        }
    }

    private var celebration: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.done)
            Text("都完成了！便单的主要功能你已经上手。点「完成」收起这张清单，帮助菜单里随时能再打开。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.done.opacity(0.1)))
    }

    private func perform(_ item: ChecklistItem) {
        switch item {
        case .firstTask:
            model.newTaskPreset = model.makeNewTaskPreset()
        case .quadrant:
            onboarding.mark(.quadrant)
            model.setMode(.quadrant)
        case .capture:
            ScheduleCaptureFlow.startRegion(model: model, anchor: FloatingBallController.shared.frame)
        case .notifications:
            if model.reminderStatus == .denied,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            } else {
                Task { await model.requestReminderAuthorization() }
            }
        case .importCalendar:
            model.sidebarSelection = .importer
        case .ai:
            SettingsNavigator.prepare(model: model, pane: .advanced, anchor: .ai)
            openSettings()
            SettingsNavigator.ensureOpened()
        }
    }
}

private struct ChecklistTile: View {
    let item: ChecklistItem
    let done: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let border: Color = done ? Theme.done.opacity(0.35) : (hovering ? item.tint.opacity(0.6) : Theme.line)
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill((done ? Theme.done : item.tint).opacity(0.14))
                Image(systemName: done ? "checkmark" : item.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(done ? Theme.done : item.tint)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .strikethrough(done, color: Theme.subtext)
                        .lineLimit(1)
                    if item.optional { ImportTag(text: "可选", color: Theme.subtext) }
                }
                Text(verbatim: item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if done {
                    Text("已完成").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.done)
                } else {
                    Button(item.actionTitle, action: action)
                        .buttonStyle(.themed)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(shape.fill(done ? Theme.done.opacity(0.05) : Theme.panel))
        .overlay(shape.stroke(border))
        .onHover { hovering = $0 }
    }
}

// MARK: - 设置 → 高级 → 新手指引

struct OnboardingSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        let signedIn = model.authState == .signedIn
        InspectorSection("新手指引") {
            ThemedRow("欢迎介绍") {
                Button("重看") { Onboarding.shared.replayWelcome(model: model) }.buttonStyle(.themed)
            }
            ThemedRow("功能导览") {
                Button("开始导览") { Onboarding.shared.startTour(model: model, bringToFront: true) }
                    .buttonStyle(.themed)
                    .disabled(!signedIn)
            }
            ThemedRow("上手清单") {
                Button("在「今天」里显示") { Onboarding.shared.showChecklist(model: model, bringToFront: true) }
                    .buttonStyle(.themed)
                    .disabled(!signedIn)
            }
            ThemedRow("重新开始") {
                Button("重新开始新手指引…") { confirmReset = true }.buttonStyle(.themed)
            }
        }
        .alert("重新开始新手指引？", isPresented: $confirmReset) {
            Button("重新开始") {
                Onboarding.shared.resetAll()
                Onboarding.shared.replayWelcome(model: model)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清掉欢迎页、功能导览和上手清单的完成记录，从欢迎页重新走一遍。不影响任何任务数据。")
        }
    }
}
