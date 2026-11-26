import SwiftUI
import WidgetKit

// MARK: - 便单桌面小组件（只读）
//
// 读主程序写在 App Group 里的 widget.json（见 Sources/BiandanMac/Widget/WidgetShared.swift），
// 显示今天的日程、下一场和逾期数；点某一条用 biandan://occurrence/<ID> 打开便单定位到它。
// 每条日程的开始、结束时刻和零点各排一个刷新点，主程序没开时「下一场」也会按时切换。

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private enum Palette {
    static let background = Color(hex: 0xF4EFE3)
    static let text = Color(hex: 0x1F1D1A)
    static let subtext = Color(hex: 0x8A8273)
    static let accent = Color(hex: 0xD9A800)
    static let overdue = Color(hex: 0xD93025)

    static func quadrant(_ raw: Int) -> Color {
        switch raw {
        case 0: return Color(hex: 0xE5483A)
        case 1: return Color(hex: 0xE9BC12)
        case 2: return Color(hex: 0x4BA9E0)
        default: return Color(hex: 0x5DB65A)
        }
    }
}

// MARK: 时间线

struct BiandanEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    private var calendar: Calendar { .current }
    var today: String { WidgetShared.dayString(date) }
    var tomorrow: String {
        WidgetShared.dayString(calendar.date(byAdding: .day, value: 1, to: date) ?? date)
    }
    var todayItems: [WidgetSnapshot.Item] { snapshot?.items(on: today) ?? [] }
    var tomorrowItems: [WidgetSnapshot.Item] { snapshot?.items(on: tomorrow) ?? [] }
    var overdue: Int { snapshot?.overdue ?? 0 }

    /// 已经结束的定时日程（还没勾完成），显示变淡。
    func isPast(_ item: WidgetSnapshot.Item) -> Bool { item.end.map { $0 <= date } ?? false }

    /// 进行中或接下来的第一条定时日程。
    var next: WidgetSnapshot.Item? { todayItems.first { ($0.end ?? .distantPast) > date } }

    /// 数据一天多没更新（主程序很久没开）。
    var stale: Bool { snapshot.map { date.timeIntervalSince($0.generatedAt) > 86_400 } ?? false }

    static let sample: WidgetSnapshot = {
        let now = Date()
        let day = WidgetShared.dayString(now)
        return WidgetSnapshot(generatedAt: now, signedIn: true, overdue: 1, items: [
            .init(id: "s1", title: "交周报", day: day, start: nil, end: nil, quadrant: 1, list: "工作"),
            .init(id: "s2", title: "设计评审", day: day, start: now.addingTimeInterval(1800),
                  end: now.addingTimeInterval(5400), quadrant: 0, list: "工作"),
            .init(id: "s3", title: "健身", day: day, start: now.addingTimeInterval(14_400),
                  end: now.addingTimeInterval(18_000), quadrant: 3, list: "运动"),
        ])
    }()
}

struct BiandanProvider: TimelineProvider {
    func placeholder(in context: Context) -> BiandanEntry {
        BiandanEntry(date: Date(), snapshot: BiandanEntry.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (BiandanEntry) -> Void) {
        let loaded = WidgetShared.load()
        completion(BiandanEntry(date: Date(), snapshot: loaded ?? (context.isPreview ? BiandanEntry.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BiandanEntry>) -> Void) {
        let snapshot = WidgetShared.load()
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        var moments: Set<Date> = [now, midnight]
        for item in snapshot?.items ?? [] {
            for moment in [item.start, item.end].compactMap({ $0 }) where moment > now && moment < midnight {
                moments.insert(moment)
            }
        }
        let entries = moments.sorted().prefix(48).map { BiandanEntry(date: $0, snapshot: snapshot) }
        // 零点之后重新读一次；数据变化时主程序会主动让小组件刷新。
        completion(Timeline(entries: Array(entries), policy: .atEnd))
    }
}

// MARK: 视图

private struct ItemTime: View {
    let item: WidgetSnapshot.Item
    let now: Date

    var body: some View {
        if let start = item.start, let end = item.end {
            if start <= now && now < end {
                (Text("进行中 · 到 ") + Text(end, style: .time))
            } else {
                (Text(start, style: .time) + Text(" 开始"))
            }
        } else {
            Text("全天")
        }
    }
}

private struct ItemRow: View {
    let item: WidgetSnapshot.Item
    let entry: BiandanEntry

    var body: some View {
        Link(destination: WidgetShared.url(.occurrence(item.id))) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Palette.quadrant(item.quadrant))
                    .frame(width: 3, height: 14)
                Group {
                    if let start = item.start { Text(start, style: .time) } else { Text("全天") }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Palette.subtext)
                .frame(width: 40, alignment: .leading)
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .opacity(entry.isPast(item) ? 0.45 : 1)
        }
    }
}

private struct OverdueLabel: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Label("\(count) 项逾期", systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.overdue)
        }
    }
}

private struct NoticeView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("便单", systemImage: "checklist").font(.headline).foregroundStyle(Palette.text)
            Text(text).font(.callout).foregroundStyle(Palette.subtext)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetShared.url(.open))
    }
}

private struct SmallView: View {
    let entry: BiandanEntry

    var body: some View {
        let items = entry.todayItems
        let focus = entry.next ?? items.first
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("今天").font(.headline).foregroundStyle(Palette.text)
                Spacer()
                Text("\(items.count)").font(.title2.bold()).foregroundStyle(Palette.accent)
            }
            if let focus {
                Text(focus.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                ItemTime(item: focus, now: entry.date)
                    .font(.caption)
                    .foregroundStyle(Palette.quadrant(focus.quadrant))
            } else {
                Text("今天没有待办了").font(.subheadline).foregroundStyle(Palette.subtext)
            }
            Spacer(minLength: 0)
            OverdueLabel(count: entry.overdue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetShared.url(focus.map { .occurrence($0.id) } ?? .open))
    }
}

private struct MediumView: View {
    let entry: BiandanEntry

    var body: some View {
        let items = entry.todayItems
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今天").font(.headline).foregroundStyle(Palette.text)
                Text("\(items.count)").font(.largeTitle.bold()).foregroundStyle(Palette.accent)
                Text("项待办").font(.caption).foregroundStyle(Palette.subtext)
                Spacer(minLength: 0)
                OverdueLabel(count: entry.overdue)
            }
            .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if items.isEmpty {
                    Text("今天没有待办了").font(.callout).foregroundStyle(Palette.subtext)
                }
                ForEach(items.prefix(4)) { ItemRow(item: $0, entry: entry) }
                if items.count > 4 {
                    Text("还有 \(items.count - 4) 项…").font(.caption).foregroundStyle(Palette.subtext)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(WidgetShared.url(.open))
    }
}

private struct LargeView: View {
    let entry: BiandanEntry

    private func section(_ title: String, _ items: [WidgetSnapshot.Item], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline).foregroundStyle(Palette.text)
                Text("\(items.count) 项").font(.caption).foregroundStyle(Palette.subtext)
                Spacer()
            }
            if items.isEmpty {
                Text("没有待办").font(.callout).foregroundStyle(Palette.subtext)
            }
            ForEach(items.prefix(limit)) { ItemRow(item: $0, entry: entry) }
            if items.count > limit {
                Text("还有 \(items.count - limit) 项…").font(.caption).foregroundStyle(Palette.subtext)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("今天", entry.todayItems, limit: 8)
            Divider()
            section("明天", entry.tomorrowItems, limit: 4)
            Spacer(minLength: 0)
            HStack {
                OverdueLabel(count: entry.overdue)
                Spacer()
                if entry.stale {
                    Text("打开便单更新数据").font(.caption2).foregroundStyle(Palette.subtext)
                }
            }
        }
        .widgetURL(WidgetShared.url(.open))
    }
}

struct BiandanWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BiandanEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            if !snapshot.signedIn {
                NoticeView(text: "打开便单登录后，这里显示今天的日程。")
            } else {
                switch family {
                case .systemSmall: SmallView(entry: entry)
                case .systemLarge: LargeView(entry: entry)
                default: MediumView(entry: entry)
                }
            }
        } else {
            NoticeView(text: "打开一次便单，这里就会显示今天的日程。")
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.kind, provider: BiandanProvider()) { entry in
            BiandanWidgetView(entry: entry)
                .containerBackground(Palette.background, for: .widget)
        }
        .configurationDisplayName("便单 · 今天")
        .description("今天的日程、下一场和逾期数，点一下打开便单定位到这条日程。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct BiandanWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}
