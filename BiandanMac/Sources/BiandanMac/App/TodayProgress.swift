import Foundation

/// 完成率的时间维度。
enum ProgressRange: String, CaseIterable, Identifiable {
    case today, next7, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .next7: return "近 7 天"
        case .month: return "本月"
        }
    }

    func bounds(today: LocalDate) -> (start: LocalDate, end: LocalDate) {
        switch self {
        case .today: return (today, today)
        case .next7: return (today, today.adding(days: 6))
        case .month: return (today.firstOfMonth, today.lastOfMonth)
        }
    }
}

/// 完成率 = 已完成 / 总数。按计划日期统计：只算安排在时间范围内的执行实例，
/// 不含已放弃；有日期的维度不含无日期任务，逾期任务也不算进今天。分母固定，完成一项分子加 1。
struct TodayProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    var pending: Int { total - done }
    var ratio: Double { total == 0 ? 0 : Double(done) / Double(total) }
    var percentText: String { "\(Int((ratio * 100).rounded()))%" }

    /// 统计计划日期与 [start, end] 有交集的有日期实例。
    static func make(_ items: [OccurrenceItem], start: LocalDate, end: LocalDate) -> TodayProgress {
        var done = 0, total = 0
        for item in items where !item.task.undated && item.status != .abandoned && item.occurrence.overlaps(start, end) {
            total += 1
            if item.status == .completed { done += 1 }
        }
        return TodayProgress(done: done, total: total)
    }

    /// 「无日期」维度：统计无日期任务本身。
    static func makeUndated(_ items: [OccurrenceItem]) -> TodayProgress {
        var done = 0, total = 0
        for item in items where item.task.undated && item.status != .abandoned {
            total += 1
            if item.status == .completed { done += 1 }
        }
        return TodayProgress(done: done, total: total)
    }
}

enum Greeting {
    static func text(hour: Int) -> String {
        switch hour {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        default: return "晚上好"
        }
    }

    /// `label` 说明统计维度，例如「今天」「「工作」· 今天」「重要 · 近 7 天」。
    static func subtitle(_ progress: TodayProgress, label: String) -> String {
        if progress.total == 0 { return "\(label)没有安排" }
        if progress.pending == 0 { return "\(label)的 \(progress.total) 项都完成了" }
        return "\(label)共 \(progress.total) 项，已完成 \(progress.done) 项，还剩 \(progress.pending) 项"
    }
}

extension AppModel {
    /// 当前视图的完成率：范围跟随视图（分类、重要、收藏、无日期），时间跟随卡片上选的维度。
    func progressSummary(for item: SidebarItem) -> TodayProgress {
        var query = OccurrenceQuery(status: .all)
        query.includeUndated = item == .undated
        switch item {
        case .list(let id): query.listID = id
        case .important: query.important = true
        case .collected: query.collected = true
        default: break
        }
        let items = snapshot.items(query)
        if item == .undated { return .makeUndated(items) }
        let range = summaryRange.bounds(today: today)
        return .make(items, start: range.start, end: range.end)
    }

    func progressLabel(for item: SidebarItem) -> String {
        if item == .undated { return "无日期" }
        let range = summaryRange.title
        switch item {
        case .list(let id): return "「\(snapshot.list(id)?.displayName ?? "分类")」· " + range
        case .important: return "重要 · " + range
        case .collected: return "收藏 · " + range
        default: return range
        }
    }
}
