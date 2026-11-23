import AppKit
import SwiftUI

/// 工具栏的更新按钮（番茄钟左边）。平时只是一个图标；发现新版本时显示「发现新版本 x.y.z」，带波纹和跳动；
/// 下载中显示进度环和百分比，下载出错显示「下载异常」，下载完显示安装倒计时。点开是更新面板。
struct UpdateToolbarButton: View {
    private let updater = AppUpdater.shared

    var body: some View {
        @Bindable var updater = updater
        Button {
            updater.showPanel.toggle()
        } label: {
            UpdateBadge(status: updater.status)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: updater.status.stageKey)
        }
        .help(help(updater.status))
        .popover(isPresented: $updater.showPanel, arrowEdge: .bottom) {
            UpdatePanel()
        }
    }

    private func help(_ status: AppUpdateStatus) -> String {
        switch status {
        case .found(let v): return "发现新版本 \(v)，点开更新"
        case .downloading, .extracting: return "正在下载新版本"
        case .countdown, .waiting: return "新版本已下载好，点开可以立即安装或改为退出时安装"
        case .installing: return "正在安装新版本"
        case .installOnQuit(let v): return "\(v) 会在退出便单时安装"
        case .downloadFailed(let m): return "下载异常：\(m)"
        case .failed(let m): return "检查更新失败：\(m)"
        case .checking: return "正在检查更新"
        case .idle, .upToDate: return "软件更新（当前 \(updater.version)）"
        }
    }
}

private struct UpdateBadge: View {
    let status: AppUpdateStatus

    var body: some View {
        switch status {
        case .found(let version):
            NewVersionBadge(version: version)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .downloading, .extracting:
            HStack(spacing: 5) {
                UpdateProgressRing(fraction: status.ringFraction, color: Theme.accent)
                Text(verbatim: status.toolbarTitle(at: Date()) ?? "")
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.accent)
            .transition(.opacity)
        case .countdown:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    UpdateProgressRing(fraction: status.countdownFraction(at: context.date), color: Theme.accent)
                    Text(verbatim: status.toolbarTitle(at: context.date) ?? "")
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.accent)
            }
            .transition(.opacity)
        case .waiting, .installOnQuit:
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                Text(verbatim: status.toolbarTitle(at: Date()) ?? "")
            }
            .foregroundStyle(Theme.accent)
        case .installing:
            HStack(spacing: 5) {
                UpdateProgressRing(fraction: nil, color: Theme.accent)
                Text("正在安装…")
            }
            .foregroundStyle(Theme.accent)
        case .downloadFailed:
            DownloadErrorBadge()
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        case .checking:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.pulse, options: .repeating)
        case .failed:
            Image(systemName: "arrow.down.circle")
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Theme.overdue).frame(width: 6, height: 6).offset(x: 2, y: -2)
                }
        case .idle, .upToDate:
            Image(systemName: "arrow.down.circle")
        }
    }
}

/// 发现新版本：小圆点往外扩波纹，箭头隔几秒跳一下。
private struct NewVersionBadge: View {
    let version: String
    @State private var ripple = false
    @State private var bounce = 0

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Theme.accent, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .scaleEffect(ripple ? 2.2 : 1)
                    .opacity(ripple ? 0 : 0.9)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 16, height: 16)
            Text(verbatim: "发现新版本 \(version)")
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "arrow.down.circle.fill")
                .symbolEffect(.bounce, value: bounce)
        }
        .foregroundStyle(Theme.accent)
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { ripple = true }
            bounce += 1
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                bounce += 1
            }
        }
    }
}

private struct DownloadErrorBadge: View {
    @State private var shake = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolEffect(.bounce, value: shake)
            Text("下载异常")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.overdue)
        .onAppear { shake += 1 }
    }
}

/// 小进度环；fraction 为 nil 时转圈。
struct UpdateProgressRing: View {
    let fraction: Double?
    let color: Color
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2.5)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .frame(width: 13, height: 13)
    }
}

// MARK: - 更新面板

struct UpdatePanel: View {
    private let updater = AppUpdater.shared

    var body: some View {
        @Bindable var updater = updater
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("软件更新")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(verbatim: "当前版本 \(updater.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
            if let reason = updater.unavailableReason {
                note(reason)
            } else {
                content
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动下载并安装")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("发现新版本就下载，下完 60 秒后安装并重启")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                }
                Spacer(minLength: 4)
                ThemedSwitch(isOn: $updater.automaticDownloads)
            }
            .disabled(updater.unavailableReason != nil)
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.background)
    }

    @ViewBuilder private var content: some View {
        switch updater.status {
        case .found(let version):
            VStack(alignment: .leading, spacing: 10) {
                headline("发现新版本 \(version)", icon: "sparkles", color: Theme.accent)
                if let url = updater.releaseNotesURL {
                    Button("查看更新说明") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                HStack(spacing: 8) {
                    Button {
                        updater.installUpdate()
                    } label: {
                        Text(updater.isInformationOnly ? "前往下载" : "立即更新").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themedPrimary)
                    Button("稍后") { updater.remindLater() }
                        .buttonStyle(.themed)
                    Button("跳过此版本") { updater.skipVersion() }
                        .buttonStyle(.themed)
                }
            }
        case .downloading(let version, let received, let expected):
            VStack(alignment: .leading, spacing: 8) {
                headline("正在下载 \(version)", icon: "arrow.down.circle", color: Theme.accent)
                if let fraction = updater.status.downloadFraction {
                    ProgressView(value: fraction).tint(Theme.accent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                HStack {
                    Text(verbatim: Self.bytes(received, expected))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.subtext)
                    Spacer()
                    Button("取消") { updater.cancelDownload() }
                        .buttonStyle(.themed)
                }
            }
        case .extracting(let version, let progress):
            VStack(alignment: .leading, spacing: 8) {
                headline("正在准备安装 \(version)", icon: "shippingbox", color: Theme.accent)
                ProgressView(value: min(max(progress, 0), 1)).tint(Theme.accent)
            }
        case .countdown(let version, _):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = updater.status.secondsLeft(at: context.date)
                VStack(alignment: .leading, spacing: 8) {
                    headline("\(version) 已下载好", icon: "checkmark.circle.fill", color: Theme.done)
                    Text(verbatim: "\(left) 秒后自动安装，便单会退出并重新打开")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    ProgressView(value: Double(left), total: AppUpdateStatus.countdownSeconds).tint(Theme.accent)
                    installButtons
                }
            }
        case .waiting(let version, let reason):
            VStack(alignment: .leading, spacing: 8) {
                headline("\(version) 已下载好", icon: "checkmark.circle.fill", color: Theme.done)
                Text(verbatim: "\(reason)后再开始 60 秒倒计时")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                installButtons
            }
        case .installing(let version):
            VStack(alignment: .leading, spacing: 8) {
                headline("正在安装 \(version)", icon: "arrow.triangle.2.circlepath", color: Theme.accent)
                Text("便单会退出并重新打开")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            }
        case .installOnQuit(let version):
            VStack(alignment: .leading, spacing: 10) {
                headline("\(version) 会在退出便单时安装", icon: "clock.arrow.circlepath", color: Theme.accent)
                Button {
                    updater.resumeInstall()
                } label: {
                    Text("现在安装").frame(maxWidth: .infinity)
                }
                .buttonStyle(.themedPrimary)
                .disabled(!updater.canCheck)
            }
        case .downloadFailed(let message):
            VStack(alignment: .leading, spacing: 8) {
                headline("下载异常", icon: "exclamationmark.triangle.fill", color: Theme.overdue)
                Text(verbatim: message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Text("重新下载").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themedPrimary)
                    .disabled(!updater.canCheck)
                    Button("关闭") { updater.dismissNotice() }
                        .buttonStyle(.themed)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                headline("检查更新失败", icon: "exclamationmark.triangle", color: Theme.overdue)
                Text(verbatim: message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                checkRow
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查更新…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
            }
        case .upToDate:
            VStack(alignment: .leading, spacing: 8) {
                headline("已是最新版本", icon: "checkmark.circle.fill", color: Theme.done)
                checkRow
            }
        case .idle:
            checkRow
        }
    }

    private var installButtons: some View {
        HStack(spacing: 8) {
            Button {
                updater.installNow()
            } label: {
                Text("立即安装").frame(maxWidth: .infinity)
            }
            .buttonStyle(.themedPrimary)
            Button("退出时再装") { updater.installLater() }
                .buttonStyle(.themed)
        }
    }

    private var checkRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: updater.lastCheck.map { "上次检查 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "还没有检查过")
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
            Spacer(minLength: 4)
            Button("检查更新") { updater.checkForUpdates() }
                .buttonStyle(.themed)
                .disabled(!updater.canCheck)
        }
    }

    private func headline(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(verbatim: text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(Theme.subtext)
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func bytes(_ received: UInt64, _ expected: UInt64) -> String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        guard expected > 0 else { return done }
        return done + " / " + ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file)
    }
}
