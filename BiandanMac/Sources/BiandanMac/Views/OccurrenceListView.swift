import SwiftUI

struct OccurrenceSection: Identifiable {
    let id: String
    let title: String
    let items: [OccurrenceItem]
}

/// 列表视图：按逾期 / 每天 / 月份 / 无日期分组；已完成按完成日分组。
struct OccurrenceListView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        let items = model.items(for: item)
        let sections = Self.sections(items, mode: item, today: model.today)
        if items.isEmpty {
            ContentUnavailableView(model.searchText.isEmpty ? "这里没有待办" : "没有匹配的待办",
                                   systemImage: item.systemImage,
                                   description: Text(model.lastSyncedAt == nil ? "登录后首次同步完成即可看到数据" : ""))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { occurrence in
                                OccurrenceCard(item: occurrence, showList: !isListScope)
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(section.id == "0" ? Theme.overdue : Color(hex: 0x4A453C))
                                Text("\(section.items.count)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.subtext)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.top, 6)
                            .background(Theme.background)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
        }
    }

    private var isListScope: Bool {
        if case .list = item { return true }
        return false
    }

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

        // 排序键：0 逾期，1-日期 未来 7 天内逐日，2-年月 更远按月，9 无日期。
        var buckets: [String: (title: String, items: [OccurrenceItem])] = [:]
        let horizon = today.adding(days: 7)
        func add(_ key: String, _ title: String, _ value: OccurrenceItem) {
            buckets[key, default: (title: title, items: [])].items.append(value)
        }
        for value in items {
            if value.task.undated {
                add("9", "无日期", value)
            } else if value.isOverdue(today: today) {
                add("0", "已逾期", value)
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
        let descending = mode == .abandoned
        let keys = buckets.keys.sorted { lhs, rhs in
            if lhs == "9" || rhs == "9" { return rhs == "9" && lhs != "9" }
            return descending ? lhs > rhs : lhs < rhs
        }
        return keys.compactMap { key in
            buckets[key].map { OccurrenceSection(id: key, title: $0.title, items: $0.items) }
        }
    }
}
