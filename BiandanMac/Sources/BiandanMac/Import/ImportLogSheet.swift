import AppKit
import SwiftUI

// MARK: - 同步日志：按来源筛选、只看失败、复制、清空

struct ImportLogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var onlyFailures = false
    @State private var logs: [ImportSyncLog] = []
    @State private var copied = false
    @State private var confirmClear = false

    private var shown: [ImportSyncLog] { onlyFailures ? logs.filter { !$0.ok } : logs }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            toolbar
            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        Text(onlyFailures ? "没有失败的记录" : "还没有同步记录")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.subtext)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(shown) { log in ImportLogRow(log: log, showSource: filter.isEmpty) }
                    }
                }
            }
            .background(shape.fill(Theme.card))
            .clipShape(shape)
            .overlay(shape.stroke(Theme.line))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.panel)
        }
        .frame(width: 660, height: 600)
        .background(Theme.background)
        .tint(Theme.accent)
        .onAppear { reload() }
        .onChange(of: filter) { _, _ in reload() }
        .onChange(of: onlyFailures) { _, _ in copied = false }
        .alert("清空同步日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                model.clearImportLogs(sourceID: filter.isEmpty ? nil : filter)
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(filter.isEmpty ? "将删除全部来源的同步记录。" : "将删除这个来源的同步记录。")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                Text("全部来源").tag("")
                ForEach(model.importSources) { source in
                    Text(verbatim: source.name).tag(source.id)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            Toggle("只看失败", isOn: $onlyFailures)
                .toggleStyle(.checkbox)
            Spacer(minLength: 0)
            Text(verbatim: "\(shown.count) 条")
                .font(.system(size: 11)).foregroundStyle(Theme.subtext)
            Button("刷新") { reload() }.buttonStyle(.themed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("同步日志").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
                Text(verbatim: "保留最近 \(LocalStore.importLogLimit) 条，只存在这台 Mac 上")
                    .font(.system(size: 11)).foregroundStyle(Theme.subtext)
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

    private var footer: some View {
        HStack(spacing: 10) {
            Button(copied ? "已复制" : "复制日志") { copy() }
                .buttonStyle(.themed)
                .disabled(shown.isEmpty)
                .help("按时间顺序复制当前列表，方便排查问题")
            Button("清空…") { confirmClear = true }
                .buttonStyle(.themedDestructive)
                .disabled(logs.isEmpty)
            Spacer(minLength: 6)
            Button("关闭") { dismiss() }
                .buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        model.reloadImportSources()
        logs = model.importLogs(sourceID: filter.isEmpty ? nil : filter)
        copied = false
    }

    private func copy() {
        let text = shown.reversed().map(\.copyLine).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

struct ImportLogRow: View {
    let log: ImportSyncLog
    var showSource = true

    var body: some View {
        let icon = log.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
        let iconColor: Color = log.ok ? Theme.done : Theme.overdue
        let messageColor: Color = log.ok ? Theme.subtext : Theme.overdue
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: log.timeText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    ImportTag(text: log.trigger.title, color: Theme.subtext)
                    if showSource {
                        Text(verbatim: log.sourceName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if log.trigger != .edited {
                        Text(verbatim: log.durationText)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.subtext)
                    }
                }
                Text(verbatim: log.summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                if !log.message.isEmpty {
                    Text(verbatim: log.message)
                        .font(.system(size: 11))
                        .foregroundStyle(messageColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1) }
    }
}
