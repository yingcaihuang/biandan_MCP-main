import SwiftUI

// MARK: - 「已导入的日历」里的一行

struct ImportSourceRow: View {
    @Environment(AppModel.self) private var model
    let source: ImportSource
    let onReimport: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var detail: String {
        let list = model.snapshot.list(source.listID)
        let synced = source.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "还没同步"
        return [source.kind.title, "分类「\(list?.displayName ?? "已删除")」", "\(source.lastCount) 条", synced]
            .joined(separator: " · ")
    }

    private var problem: String? {
        guard let error = model.importSyncErrors[source.id] ?? source.lastError else { return nil }
        var text = source.failures > 1 ? "已连续失败 \(source.failures) 次：\(error)" : "上次同步失败：\(error)"
        if source.enabled, let retry = source.retryAt, retry > Date() {
            text += "（自动同步已放慢，\(AppModel.importTimeText(retry)) 后再试）"
        }
        return text
    }

    var body: some View {
        let list = model.snapshot.list(source.listID)
        HStack(spacing: 10) {
            Image(systemName: source.kind.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(list?.swatch ?? Theme.subtext)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: source.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if source.kind.syncs && !source.enabled {
                        ImportTag(text: source.autoPaused ? "失败过多 · 已暂停" : "已暂停",
                                  color: source.autoPaused ? Theme.overdue : Theme.subtext)
                    }
                }
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
                    .help(source.address)
                if let problem {
                    Text(verbatim: problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.overdue)
                        .lineLimit(2)
                        .help(problem)
                }
            }
            Spacer(minLength: 8)
            if source.kind.syncs {
                if model.importSyncing.contains(source.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("立即同步") { Task { await model.syncImportSource(source, manual: true) } }
                        .buttonStyle(.themed)
                        .help("马上同步一次；不受暂停和失败退避限制，成功后恢复正常")
                }
            }
            if source.kind == .file {
                Button("重新导入", action: onReimport)
                    .buttonStyle(.themed)
                    .help("选择更新后的同一文件（文件名相同），只更新有变化的日程")
            }
            Button("编辑", action: onEdit)
                .buttonStyle(.themed)
            Button("移除", action: onDelete)
                .buttonStyle(.themedDestructive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1) }
    }
}
