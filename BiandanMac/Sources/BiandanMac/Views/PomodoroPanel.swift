import SwiftUI

/// 工具栏的番茄钟按钮：计时中显示剩余时间，点开是番茄钟面板。
struct PomodoroToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button {
            model.showPomodoro.toggle()
        } label: {
            label
        }
        .help(model.pomodoro == nil ? "番茄钟（结束后自动补记专注）" : "查看番茄钟")
        .popover(isPresented: $model.showPomodoro, arrowEdge: .bottom) {
            PomodoroPanel().environment(model)
        }
    }

    @ViewBuilder private var label: some View {
        if let session = model.pomodoro {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: session.isPaused ? "pause.circle" : "timer")
                    Text(PomodoroSession.clock(session.remaining(at: context.date)))
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.accent)
            }
        } else {
            Image(systemName: "timer")
        }
    }
}

struct PomodoroPanel: View {
    @Environment(AppModel.self) private var model
    @State private var linkSelected = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("番茄钟")
                .font(.system(size: 15, weight: .bold))
            if let session = model.pomodoro {
                PomodoroRunning(session: session)
            } else {
                setup
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.background)
    }

    private var setup: some View {
        @Bindable var model = model
        let item = model.selectedPendingItem
        let name: String = item.map { $0.task.taskTitle.isEmpty ? "（无标题）" : $0.task.taskTitle } ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(PomodoroSession.presets, id: \.self) { minutes in
                    PomodoroPresetButton(minutes: minutes, selected: model.pomodoroMinutes == minutes) {
                        model.pomodoroMinutes = minutes
                    }
                }
            }
            Stepper(value: $model.pomodoroMinutes, in: 5...180, step: 5) {
                Text(verbatim: "时长 \(model.pomodoroMinutes) 分钟")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            if item != nil {
                HStack(spacing: 8) {
                    Text(verbatim: "关联「\(name)」")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ThemedSwitch(isOn: $linkSelected)
                }
            } else {
                Text("在列表里选中一个任务，可以把这次专注关联到它")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
            Button {
                model.startPomodoro(minutes: model.pomodoroMinutes, item: linkSelected ? item : nil)
            } label: {
                Text("开始专注").frame(maxWidth: .infinity)
            }
            .buttonStyle(.themedPrimary)
            .disabled(model.authState != .signedIn)
            Text("计时结束后会自动补记一条专注记录")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fieldName)
        }
    }
}

private struct PomodoroPresetButton: View {
    let minutes: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let fill: Color = selected ? Theme.accent : Theme.card
        let text: Color = selected ? Color.white : Theme.text
        Button(action: action) {
            Text(verbatim: "\(minutes) 分")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct PomodoroRunning: View {
    @Environment(AppModel.self) private var model
    let session: PomodoroSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let progress = CGFloat(session.progress(at: now))
        let canFinish = session.elapsed(at: now) >= 60
        return VStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(PomodoroSession.clock(session.remaining(at: now)))
                        .font(.system(size: 30, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text(session.isPaused ? "已暂停" : "专注中")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                }
            }
            .frame(width: 150, height: 150)
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 8) {
                Button(session.isPaused ? "继续" : "暂停") {
                    if session.isPaused { model.resumePomodoro() } else { model.pausePomodoro() }
                }
                Button("提前结束") {
                    Task { await model.finishPomodoro(completed: false) }
                }
                .disabled(!canFinish)
                .help("按已专注的分钟数补记，记为 1 个中断番茄")
                Button("放弃") { model.cancelPomodoro() }
                    .help("放弃本次计时，不记录")
            }
            .buttonStyle(.themed)
            Text(verbatim: "计划 \(session.plannedMinutes) 分钟 · 到时自动补记")
                .font(.system(size: 11))
                .foregroundStyle(Theme.fieldName)
        }
        .frame(maxWidth: .infinity)
    }
}
