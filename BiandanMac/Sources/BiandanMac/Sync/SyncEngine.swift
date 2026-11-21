import Foundation

extension RecordKind {
    var title: String {
        switch self {
        case .task: return "待办定义"
        case .showTask: return "执行实例"
        case .favorites: return "分类"
        case .tomato: return "专注记录"
        }
    }

    /// 拉取顺序：先待办单和任务，再实例和专注记录。
    static let pullOrder: [RecordKind] = [.favorites, .task, .showTask, .tomato]
}

/// P3 只读同步：四张表全部完整拉取后，在一个事务里写入本地库。
/// 任何一张表拉取失败（游标重复、网络错误、授权失效）都不改动本地数据。
actor SyncEngine {
    private let client: SyncAPIClient
    private let store: LocalStore
    private var current: Task<SyncReport, Error>?

    init(client: SyncAPIClient, store: LocalStore) {
        self.client = client
        self.store = store
    }

    var isSyncing: Bool { current != nil }

    /// 同时触发多次时合并为一次。
    func syncNow(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SyncReport {
        if let current {
            return try await current.value
        }
        let task = Task { try await self.pull(progress: progress) }
        current = task
        defer { current = nil }
        return try await task.value
    }

    func cancel() {
        current?.cancel()
    }

    private func pull(progress: @escaping @Sendable (String) -> Void) async throws -> SyncReport {
        var pulled: [RecordKind: [RawRecord]] = [:]
        SyncDiagnostics.reset()
        SyncDiagnostics.log("开始同步")
        progress("正在检查云端容器…")
        try await client.check()
        for kind in RecordKind.pullOrder {
            try Task.checkCancellation()
            progress("正在同步\(kind.title)…")
            let records = try await client.listAll(kind) { count in
                progress("正在同步\(kind.title)… \(count)")
            }
            SyncDiagnostics.log("\(kind.rawValue) 合计 \(records.count) 条")
            pulled[kind] = records
        }
        try Task.checkCancellation()
        progress("正在写入本地数据库…")
        return try store.apply(pulled, at: Date())
    }
}
