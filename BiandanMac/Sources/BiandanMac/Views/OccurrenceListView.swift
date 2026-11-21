import SwiftUI

struct OccurrenceSection: Identifiable {
    let id: String
    let title: String
    let items: [OccurrenceItem]
}

/// 列表视图：待办（按日期 / 月份 / 无日期）→ 已过期 → 已完成。
/// 「已完成」侧栏项按完成日分组。
struct OccurrenceListView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        let items = model.items(for: item)
        let sections = Self.sections(items, mode: item, today: model.today)
        let done = model.completedItems(for: item)
        if items.isEmpty && done.isEmpty {
            ContentUnavailableView(model.searchText.isEmpty ? "这里没有待办" : "没有匹配的待办",
                                   systemImage: item.systemImage,
                                   description: Text(model.lastSyncedAt == nil ? "登录后首次同步完成即可看到数据" : ""))
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                    if items.isEmpty {
                        Label("待办都处理完了", systemImage: "checkmark.seal")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.done)
                            .padding(.vertical, 14)
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { occurrence in
                                OccurrenceCard(item: occurrence, showList: !isListScope)
                            }
                        } header: {
                            SectionHeader(title: section.title, count: section.items.count,
                                          color: section.id == Self.overdueKey ? Theme.overdue : Color(hex: 0x4A453C))
                        }
                    }
                    if !done.isEmpty {
                        Section {
                            if model.showCompletedInList {
                                ForEach(done) { occurrence in
                                    OccurrenceCard(item: occurrence, showList: !isListScope)
                                }
                            }
                        } header: {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { model.showCompletedInList.toggle() }
                            } label: {
                                SectionHeader(title: ListCompletion.title(for: item), count: done.count,
                                              color: Theme.done,
                                              chevron: model.showCompletedInList ? "chevron.down" : "chevron.right")
                            }
                            .buttonStyle(.plain)
                            .help(model.showCompletedInList ? "收起已完成" : "展开已完成")
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
            // 键盘移动选中时滚动到那一项。
            .onChange(of: model.keyboardScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(target) }
            }
            }
        }
    }

    private var isListScope: Bool {
        if case .list = item { return true }
        return false
    }

    static let overdueKey = "0"

    static func dayTitle(_ day: LocalDate, today: LocalDate) -> String {
        switch today.days(to: day) {
        case 0: return "今天 · " + day.shortTitle
        case 1: return "明天 · " + day.shortTitle
        case -1: return "昨天 · " + day.shortTitle
        default: return day.year == today.year ? day.shortTitle : "\(day.year)年" + day.shortTitle
        }
    }

    static func sections(_ items: [OccurrenceItem], mode: SidebarItem, today: LocalDate) -> [OccurrenceSection] {
        if mode == .completed {
            let grouped = Dictionary(grouping: items) { $0.occurrence.completedDate }
            let keys = grouped.keys.sorted { ($0 ?? .minSupported) > ($1 ?? .minSupported) }
            return keys.map { key in
                let rows = (grouped[key] ?? []).sorted {
                    ($0.occurrence.completedAt ?? "") > ($1.occurrence.completedAt ?? "")
                }
                return OccurrenceSection(id: key?.iso ?? "unknown",
                                         title: key.map { dayTitle($0, today: today) } ?? "完成日期未知",
                                         items: rows)
            }
        }

        // 分组键：0 已过期，1-日期 未来 7 天内逐日，2-年月 更远按月，9 无日期。
        var buckets: [String: (title: String, items: [OccurrenceItem])] = [:]
        let horizon = today.adding(days: 7)
        func add(_ key: String, _ title: String, _ value: OccurrenceItem) {
            buckets[key, default: (title: title, items: [])].items.append(value)
        }
        for value in items {
            if value.task.undated {
                add("9", "无日期", value)
            } else if value.isOverdue(today: today) {
                add(overdueKey, "已过期", value)
            } else if let start = value.occurrence.startDate {
                let day = value.status == .pending ? max(start, today) : start
                if day < horizon || value.status != .pending {
                    add("1-" + day.iso, dayTitle(day, today: today), value)
                } else {
                    let month = String(format: "%04d-%02d", day.year, day.month)
                    let title = day.year == today.year ? "\(day.month)月" : "\(day.year)年\(day.month)月"
                    add("2-" + month, title, value)
                }
            } else {
                add("9", "无日期", value)
            }
        }
        // 顺序与鸿蒙端一致：待办（按日期，无日期在后）→ 已过期。已放弃按日期倒序。
        let descending = mode == .abandoned
        func rank(_ key: String) -> Int {
            if key == "9" { return 1 }
            if key == overdueKey && !descending { return 2 }
            return 0
        }
        let keys = buckets.keys.sorted { lhs, rhs in
            let a = rank(lhs), b = rank(rhs)
            if a != b { return a < b }
            return descending ? lhs > rhs : lhs < rhs
        }
        return keys.compactMap { key in
            buckets[key].map { OccurrenceSection(id: key, title: $0.title, items: $0.items) }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    let color: Color
    var chevron: String?

    var body: some View {
        HStack(spacing: 6) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 10)
            }
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.top, 6)
        .background(Theme.background)
        .contentShape(Rectangle())
    }
}
