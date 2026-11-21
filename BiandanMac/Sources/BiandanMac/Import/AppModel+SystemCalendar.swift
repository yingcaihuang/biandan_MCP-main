import Foundation

// MARK: - 邮箱账户（系统日历）来源

extension AppModel {
    /// 为选中的每个系统日历建一个来源（各自一个分类），并立即同步一次。已添加过的只再同步。
    func addSystemSources(_ calendars: [SystemCalendarInfo]) async {
        guard authState == .signedIn else {
            importNotice = "请先在便单主窗口登录华为账号"
            return
        }
        guard !calendars.isEmpty else { return }
        importBusy = true
        defer { importBusy = false }
        reloadImportSources()
        var ready: [ImportSource] = []
        var problems: [String] = []
        for info in calendars {
            if let existing = importSources.first(where: { $0.kind == .system && $0.address == info.id }) {
                ready.append(existing)
                continue
            }
            let name = Self.caldavSourceName(account: info.account, calendar: info.title)
            guard let listID = await importList(named: name, preferred: nil) else {
                problems.append("没能新建分类「\(name)」")
                continue
            }
            let source = ImportSource(id: UUID().uuidString, kind: .system, name: name, listID: listID,
                                      address: info.id, createdAt: Date(), lastSyncAt: nil, lastCount: 0, enabled: true)
            do {
                try store.saveImportSource(source)
            } catch {
                problems.append("「\(name)」保存失败：\(error.localizedDescription)")
                continue
            }
            ready.append(source)
        }
        reloadImportSources()

        var lines: [String] = []
        for source in ready {
            importSyncing.insert(source.id)
            do {
                let counts = try await syncAndRecord(source, trigger: .added)
                importSyncErrors[source.id] = nil
                lines.append("「\(source.name)」\(counts.summary)")
            } catch {
                importSyncErrors[source.id] = error.localizedDescription
                lines.append("「\(source.name)」同步失败：\(error.localizedDescription)")
            }
            importSyncing.remove(source.id)
        }
        lines += problems
        importNotice = lines.isEmpty ? "没有添加日历" : "已添加邮箱账户日历：" + lines.joined(separator: "；")
    }
}
