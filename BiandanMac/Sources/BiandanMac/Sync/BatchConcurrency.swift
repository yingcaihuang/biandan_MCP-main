import Foundation

/// 批量写云端时的有限并发：不同任务同时写几个，同一任务按顺序。
enum BatchConcurrency {
    /// 同时写云端的任务数。华为云有限流，取保守值；遇到 429 由 RetryPolicy 退避重试。
    static let limit = 3

    /// 最多 limit 项同时进行，结果按输入顺序返回；任何一项抛错时取消其余的并抛出。
    static func map<T: Sendable, R: Sendable>(_ items: [T], limit: Int = BatchConcurrency.limit,
                                              _ body: @escaping @Sendable (Int, T) async throws -> R) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            let width = max(1, min(limit, items.count))
            while next < width {
                let index = next
                let item = items[index]
                group.addTask { (index, try await body(index, item)) }
                next += 1
            }
            while let pair = try await group.next() {
                results[pair.0] = pair.1
                if next < items.count {
                    let index = next
                    let item = items[index]
                    group.addTask { (index, try await body(index, item)) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    /// 按 key 分组：组内保持输入顺序，组按第一次出现的顺序排列。返回每组的下标。
    static func groups<K: Hashable>(_ keys: [K]) -> [[Int]] {
        var order: [K] = []
        var members: [K: [Int]] = [:]
        for (index, key) in keys.enumerated() {
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(index)
        }
        return order.compactMap { members[$0] }
    }
}
