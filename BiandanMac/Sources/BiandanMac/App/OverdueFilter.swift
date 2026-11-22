import Foundation

/// 逾期的日程单独放在侧栏「逾期」里查看和处理，其它待办视图不再显示；
/// 日历按日期排，逾期的仍留在原来那天；已完成、已放弃本来就没有逾期项。统计照常计入逾期。
enum OverdueFilter {
    static func apply(_ items: [OccurrenceItem], for item: SidebarItem, today: LocalDate) -> [OccurrenceItem] {
        switch item {
        case .overdue: return items.filter { $0.isOverdue(today: today) }
        case .calendar, .completed, .abandoned: return items
        default: return items.filter { !$0.isOverdue(today: today) }
        }
    }
}
