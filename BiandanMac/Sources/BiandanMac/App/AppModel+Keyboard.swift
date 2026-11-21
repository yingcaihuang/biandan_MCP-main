import AppKit
import Foundation

/// 键盘导航用的纯计算：按显示顺序移动、连选范围。
enum KeyboardNav {
    /// 从 current 移动 delta 步；current 不在列表里时，向下取第一项、向上取最后一项。到头后停在两端。
    static func step(_ order: [String], current: String?, delta: Int) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return delta >= 0 ? order.first : order.last
        }
        return order[min(max(index + delta, 0), order.count - 1)]
    }

    /// from 到 to 之间（含两端）的所有项；任一端不在列表里时只返回存在的那一端。
    static func range(_ order: [String], from: String, to: String) -> [String] {
        switch (order.firstIndex(of: from), order.firstIndex(of: to)) {
        case let (a?, b?): return Array(order[min(a, b)...max(a, b)])
        case (_?, nil): return [from]
        case (nil, _?): return [to]
        case (nil, nil): return []
        }
    }
}

extension AppModel {
    /// 当前内容区里任务卡片的显示顺序（记录页为空）。
    var keyboardOrder: [OccurrenceItem] {
        let item = sidebarSelection ?? .all
        if item.isRecordPage { return [] }
        switch effectiveMode {
        case .list:
            var result = OccurrenceListView.sections(items(for: item), mode: item, today: today).flatMap(\.items)
            if showCompletedInList { result += completedItems(for: item) }
            return result
        case .quadrant:
            // 与四宫格的阅读顺序一致：重要且紧急 → 重要不紧急 → 不重要紧急 → 都不。
            let groups = quadrantItems()
            return Quadrant.allCases.flatMap { groups[$0] ?? [] }
        case .calendar:
            let window = calendarKeyboardWindow
            return items(for: .calendar)
                .filter { !$0.task.undated && $0.occurrence.overlaps(window.0, window.1) }
                .sorted {
                    ($0.occurrence.startDate ?? .minSupported, $0.occurrence.validStartTime, $0.id)
                        < ($1.occurrence.startDate ?? .minSupported, $1.occurrence.validStartTime, $1.id)
                }
        }
    }

    /// 日历当前显示的大致范围，键盘只在这个范围里移动。
    private var calendarKeyboardWindow: (LocalDate, LocalDate) {
        switch calendarScope {
        case .year:
            let year = calendarMonth.year
            return (LocalDate(year: year, month: 1, day: 1) ?? calendarMonth,
                    LocalDate(year: year, month: 12, day: 31) ?? calendarMonth)
        case .month:
            return (calendarMonth.firstOfMonth, calendarMonth.lastOfMonth)
        case .week:
            let start = calendarFocus.adding(days: -floorMod(calendarFocus.weekday - weekStart, 7))
            return (start, start.adding(days: 6))
        case .day:
            return (calendarFocus, calendarFocus)
        }
    }

    /// 有可操作的选中项（单选或多选）。
    var hasKeyboardTarget: Bool { !multiSelection.isEmpty || selectedItem != nil }

    /// ↑↓ 移动选中；extend 时从起点连选到新位置。
    func moveSelection(by delta: Int, extend: Bool) {
        let order = keyboardOrder.map(\.id)
        guard let next = KeyboardNav.step(order, current: selectedOccurrenceID, delta: delta) else { return }
        if extend {
            let anchor = selectionAnchor ?? selectedOccurrenceID ?? next
            selectionAnchor = anchor
            multiSelection = Set(KeyboardNav.range(order, from: anchor, to: next))
        } else {
            multiSelection = []
            selectionAnchor = next
        }
        selectedOccurrenceID = next
        selectedFocusID = nil
        keyboardScrollTarget = next
    }

    /// ⇧ 点击：从起点连选到这一项。
    func rangeSelect(to item: OccurrenceItem) {
        guard let anchor = selectionAnchor ?? selectedOccurrenceID, anchor != item.id else {
            multiSelection = []
            selectionAnchor = item.id
            selectedOccurrenceID = item.id
            selectedFocusID = nil
            return
        }
        let ids = KeyboardNav.range(keyboardOrder.map(\.id), from: anchor, to: item.id)
        multiSelection = Set(ids.isEmpty ? [anchor, item.id] : ids)
        selectionAnchor = anchor
        selectedOccurrenceID = item.id
        selectedFocusID = nil
    }

    /// 空格：多选时批量完成，单选时切换完成状态。
    func keyboardToggleCompletion() async {
        if !multiSelection.isEmpty {
            await batchComplete()
        } else if let item = selectedItem {
            await toggleCompletion(item)
        }
    }

    /// ⌫：弹出删除确认（多选走批量删除）。
    func keyboardDelete() {
        if !multiSelection.isEmpty {
            batchDeleteRequested = true
        } else if let item = selectedItem {
            deleteRequest = item
        }
    }

    /// 回车：打开检查器并把焦点放到标题输入框。
    func keyboardEditTitle() {
        guard multiSelection.isEmpty, selectedItem != nil else { return }
        showInspector = true
        pendingTitleFocus = true
        titleFocusRequest += 1
    }
}
