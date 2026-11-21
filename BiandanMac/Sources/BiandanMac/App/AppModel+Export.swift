import AppKit
import Foundation
import UniformTypeIdentifiers

/// 导出与本地备份。
extension AppModel {
    /// 弹出保存面板导出到用户选的位置，完成后在访达里选中文件。
    func exportData(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = "导出" + format.title
        panel.nameFieldStringValue = format.fileName(today)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try DataExport.data(format, snapshot: snapshot, today: today)
            try data.write(to: url, options: .atomic)
            exportNotice = "已导出「\(url.lastPathComponent)」。"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportNotice = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 每天第一次同步成功后备份一次。
    func autoBackupIfNeeded() {
        Task { await runBackup(force: false) }
    }

    /// 设置页「立即备份」：覆盖当天的备份。
    func backupNow() async {
        await runBackup(force: true)
    }

    private func runBackup(force: Bool) async {
        let data = snapshot
        let now = Date()
        let outcome = await Task.detached(priority: .utility) {
            LocalBackup.write(data, now: now, force: force)
        }.value
        switch outcome {
        case .written:
            lastBackupAt = now
            if force { exportNotice = "已备份到本机备份文件夹。" }
        case .skipped:
            if force { exportNotice = "本地还没有数据，暂不备份。" }
        case .failed(let message):
            exportNotice = "本地备份失败：\(message)"
        }
    }
}
