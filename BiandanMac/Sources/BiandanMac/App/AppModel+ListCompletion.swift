import Foundation

/// 列表底部「已完成」分组的取数规则。
enum ListCompletion {
    /// 今天只看今天完成的，其余入口看近 7 天完成的；已完成、已放弃、日历、四象限、无日期、专注记录不显示这一组。
    static func query(from base: OccurrenceQuery, item: SidebarItem, today: LocalDate) -> OccurrenceQuery? {
        switch item {
        case .today, .next7, .all, .important, .collected, .list:
            break
        case .quadrant, .calendar, .undated, .completed, .abandoned, .focus:
            return nil
        }
        var query = base
        query.status = .completed
        query.start = item == .today ? today : today.adding(days: -6)
        query.end = today
        return query
    }

    static func title(for item: SidebarItem) -> String {
        item == .today ? "已完成" : "近 7 天已完成"
    }
}

extension AppModel {
    /// 当前侧栏范围内最近完成的执行实例，按完成时间倒序。
    func completedItems(for item: SidebarItem) -> [OccurrenceItem] {
        guard let base = query(for: item),
              let query = ListCompletion.query(from: base, item: item, today: today) else { return [] }
        return snapshot.items(query).sorted {
            ($0.occurrence.completedAt ?? "") > ($1.occurrence.completedAt ?? "")
        }
    }
}
