import Foundation

// MARK: - 编辑导入来源

struct ImportSourceEdit: Sendable {
    var name: String
    var listID: String
    /// 换分类时把已导入的任务一起移过去。
    var moveTasks: Bool
    /// 名称改了时，分类也改成同样的名称。
    var renameList: Bool
    var enabled: Bool
    /// CalDAV 日历地址或订阅地址。
    var address: String
    var username: String
    /// 空表示不改。
    var password: String
}

extension AppModel {
    /// 保存修改；返回错误信息，nil 表示成功。改了连接设置时立即同步一次。
    func updateImportSource(_ original: ImportSource, _ edit: ImportSourceEdit) async -> String? {
        guard authState == .signedIn else { return "请先在便单主窗口登录华为账号" }
        reloadImportSources()
        guard var source = importSources.first(where: { $0.id == original.id }) else { return "这个来源已经被移除了" }
        guard !importSyncing.contains(source.id) else { return "这个来源正在同步，请稍后再保存" }
        let name = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "名称不能为空" }
        guard snapshot.list(edit.listID) != nil else { return "选择的分类不存在了，请重新选择" }

        var changes: [String] = []
        var connectionChanged = false
        switch source.kind {
        case .caldav:
            guard let url = CalDAVClient.serverURL(edit.address) else { return CalDAVError.invalidAddress.localizedDescription }
            let username = edit.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { return "用户名不能为空" }
            let saved = CalDAVKeychain.load(source.id)
            let secret = edit.password.isEmpty ? (saved?.password ?? "") : edit.password
            guard !secret.isEmpty else { return "请填写密码" }
            let credentials = CalDAVCredentials(username: username, password: secret)
            if credentials != saved {
                do {
                    try CalDAVKeychain.save(credentials, for: source.id)
                } catch {
                    return error.localizedDescription
                }
                connectionChanged = true
                changes.append(saved?.username == username ? "更新了密码" : "更新了账户")
            }
            if url.absoluteString != source.address {
                source.address = url.absoluteString
                connectionChanged = true
                changes.append("修改了日历地址")
            }
        case .url:
            guard let url = ICSSubscription.url(edit.address) else {
                return ICSSubscriptionError.invalidAddress.localizedDescription
            }
            if url.absoluteString != source.address {
                source.address = url.absoluteString
                connectionChanged = true
                // 订阅地址里常带访问凭证，日志里不写地址本身。
                changes.append("修改了订阅地址")
            }
        case .file, .system:
            break
        }

        let oldListID = source.listID
        if name != source.name {
            changes.append("名称「\(source.name)」改为「\(name)」")
            if edit.renameList, edit.listID == oldListID, let list = snapshot.list(oldListID), list.displayName != name {
                if await updateList(oldListID, name: name, colorIndex: nil) { changes.append("分类也改了名") }
            }
            source.name = name
        }
        if edit.listID != oldListID {
            source.listID = edit.listID
            changes.append("分类改为「\(snapshot.list(edit.listID)?.displayName ?? "")」")
        }
        if source.kind.syncs, edit.enabled != source.enabled {
            if edit.enabled {
                source.failures = 0
                source.retryAt = nil
                source.lastError = nil
            }
            source.autoPaused = false
            source.enabled = edit.enabled
            changes.append(edit.enabled ? "开启自动同步" : "暂停自动同步")
        }
        if connectionChanged {
            // 换了账户或地址：重新计数。
            source.failures = 0
            source.retryAt = nil
            source.lastError = nil
            importSyncErrors[source.id] = nil
        }
        guard !changes.isEmpty else { return nil }
        do {
            try store.saveImportSource(source)
        } catch {
            return "保存失败：\(error.localizedDescription)"
        }
        reloadImportSources()

        if edit.moveTasks, edit.listID != oldListID {
            let links = (try? store.importLinks(sourceID: source.id)) ?? []
            let taskIDs = Set(links.map(\.taskID)).filter { snapshot.tasks[$0] != nil }
            for taskID in taskIDs.sorted() {
                await moveTask(taskID, to: edit.listID)
            }
            if !taskIDs.isEmpty { changes.append("移动了 \(taskIDs.count) 条已导入的任务") }
        }
        logImport(source, trigger: .edited, started: Date(), ok: true, message: changes.joined(separator: "；"))
        importNotice = "已保存「\(source.name)」：" + changes.joined(separator: "，")
        if connectionChanged, source.kind.syncs {
            await syncImportSource(source, manual: true)
        }
        return nil
    }
}
