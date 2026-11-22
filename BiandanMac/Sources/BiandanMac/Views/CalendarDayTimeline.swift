import SwiftUI

// MARK: - 日历的日视图 / 周视图时间轴
//
// 左边按小时标刻度，日程块按开始–结束时刻定位、高度和时长成正比，一眼看出哪段有事、哪段空着。
// 块用四象限颜色（浅底深字 + 左侧色条）；时间重叠的并排；今天画一条「现在」红线；没有具体时刻的放在顶部「全天」一栏。
// 每一列都可以把任务拖进来改期；块可以点选、右键。周视图每列较窄，块里只写标题，详情放在悬停提示里。

enum DayAgendaMetrics {
    static let hourHeight: CGFloat = 45
    static let gutter: CGFloat = 52
    static let inset: CGFloat = 8
    static let minBlockHeight: CGFloat = 18

    /// 某个分钟数在时间轴上的纵坐标。
    static func y(_ minute: Int, hours: Range<Int>) -> CGFloat {
        let offset = CGFloat(minute - hours.lowerBound * 60)
        return inset + offset / 60 * hourHeight
    }

    static func height(hours: Range<Int>) -> CGFloat {
        CGFloat(hours.count) * hourHeight + inset * 2
    }

    /// 块在列里的横向位置和宽度。日视图列宽够，重叠的并排平分；
    /// 周视图列窄，平分后标题放不下，改成错开叠放：后面的往右缩进一点、压在前面的上面，每块都接近整列宽。
    static func horizontal(column: Int, columns: Int, width: CGFloat, cascade: Bool) -> (x: CGFloat, width: CGFloat) {
        let area = max(width - 4, 20)
        let count = max(columns, 1)
        if cascade && count > 1 {
            let indent = min(14, area * 0.18)
            let x = 2 + indent * CGFloat(column)
            return (x, max(area - indent * CGFloat(column), 16))
        }
        let columnWidth = area / CGFloat(count)
        return (2 + CGFloat(column) * columnWidth, max(columnWidth - 3, 16))
    }
}

/// 时间轴上的一列（一天）。
struct DayAgendaColumnData: Identifiable {
    let day: LocalDate
    let blocks: [DayAgendaBlock]
    let allDay: [OccurrenceItem]
    var id: String { day.iso }

    static func make(_ items: [OccurrenceItem], day: LocalDate) -> DayAgendaColumnData {
        let layout = DayAgendaLayout.layout(items.filter { $0.occurrence.overlaps(day, day) }, day: day)
        return DayAgendaColumnData(day: day, blocks: layout.timed, allDay: layout.allDay)
    }
}

/// 日视图。
struct CalendarDayTimeline: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let isToday: Bool
    let items: [OccurrenceItem]

    var body: some View {
        let column = DayAgendaColumnData.make(items, day: day)
        VStack(alignment: .leading, spacing: 8) {
            header
            if items.isEmpty {
                Text("这一天没有安排，可以把任务拖到下面的时间轴上改期")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fieldName)
            }
            if !column.allDay.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    DayAgendaAllDayLabel()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6)], alignment: .leading, spacing: 4) {
                        ForEach(column.allDay) { item in
                            CalendarChip(item: item, day: day)
                        }
                    }
                }
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
            // 每分钟刷新一次「现在」红线。
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now: Int? = isToday ? DayAgendaLayout.minute(of: context.date) : nil
                ScrollView {
                    DayAgendaGrid(columns: [column], nowMinute: now, todayIndex: isToday ? 0 : nil, compact: false)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isToday ? Theme.accent : Theme.line, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            DayAgendaDayTitle(day: day, isToday: isToday)
            Spacer(minLength: 0)
            if !items.isEmpty {
                Text(verbatim: "\(items.count) 项")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.subtext)
            }
        }
    }
}

/// 周视图：7 列共用左边的小时刻度。
struct CalendarWeekTimeline: View {
    @Environment(AppModel.self) private var model
    let days: [LocalDate]
    let items: [OccurrenceItem]

    private typealias M = DayAgendaMetrics

    var body: some View {
        let columns = days.map { DayAgendaColumnData.make(items, day: $0) }
        let todayIndex = days.firstIndex(of: model.today)
        let hasAllDay = columns.contains { !$0.allDay.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Color.clear.frame(width: M.gutter, height: 1)
                ForEach(columns) { column in
                    HStack(spacing: 4) {
                        DayAgendaDayTitle(day: column.day, isToday: column.day == model.today)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                }
            }
            if hasAllDay {
                HStack(alignment: .top, spacing: 0) {
                    DayAgendaAllDayLabel()
                    ForEach(columns) { column in
                        VStack(spacing: 3) {
                            ForEach(column.allDay) { item in
                                CalendarChip(item: item, day: column.day)
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now: Int? = todayIndex == nil ? nil : DayAgendaLayout.minute(of: context.date)
                ScrollView {
                    DayAgendaGrid(columns: columns, nowMinute: now, todayIndex: todayIndex, compact: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}

/// 「日 22 十四」：星期、日期（今天用黄色胶囊）、农历，点一下打开这一天。
private struct DayAgendaDayTitle: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let isToday: Bool

    var body: some View {
        let weekend = day.pythonWeekday >= 5
        let weekdayColor: Color = weekend ? Color(hex: 0xD9534A) : Theme.subtext
        let dayColor: Color = isToday ? Color.white : Theme.text
        let capsule: Color = isToday ? Theme.accent : Color.clear
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(LocalDate.weekdayShortNames[day.weekday])
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(weekdayColor)
            Text(verbatim: "\(day.day)")
                .font(.system(size: 16, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(dayColor)
                .padding(.horizontal, isToday ? 7 : 0)
                .background(Capsule().fill(capsule))
            Text(calendarLunarText(day))
                .font(.system(size: 10))
                .foregroundStyle(Theme.fieldName)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.showDay(day) }
        .help("查看这一天")
    }
}

private struct DayAgendaAllDayLabel: View {
    var body: some View {
        Text("全天")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.subtext)
            .frame(width: DayAgendaMetrics.gutter - 8, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.top, 2)
    }
}

/// 时间刻度 + 每一天一列（日程块、现在红线）。
private struct DayAgendaGrid: View {
    let columns: [DayAgendaColumnData]
    let nowMinute: Int?
    let todayIndex: Int?
    let compact: Bool

    private typealias M = DayAgendaMetrics

    var body: some View {
        let spans = columns.flatMap { column in column.blocks.map { (start: $0.start, end: $0.end) } }
        let hours = DayAgendaLayout.hourRange(spans, now: nowMinute)
        ZStack(alignment: .topLeading) {
            DayAgendaHourLines(hours: hours)
            HStack(spacing: 0) {
                Color.clear.frame(width: M.gutter)
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    DayAgendaColumn(column: column, hours: hours,
                                    nowMinute: index == todayIndex ? nowMinute : nil,
                                    compact: compact, separator: columns.count > 1 && index > 0)
                }
            }
        }
        .frame(height: M.height(hours: hours))
    }
}

private struct DayAgendaHourLines: View {
    let hours: Range<Int>

    private typealias M = DayAgendaMetrics

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ForEach(Array(hours.lowerBound...hours.upperBound), id: \.self) { hour in
                let top = M.y(hour * 60, hours: hours)
                Text(verbatim: String(format: "%02d:00", hour))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtext)
                    .frame(width: M.gutter - 8, alignment: .trailing)
                    .offset(y: top - 7)
                Path { path in
                    path.move(to: CGPoint(x: M.gutter, y: top))
                    path.addLine(to: CGPoint(x: width, y: top))
                }
                .stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// 一天的一列：可以把任务拖进来改到这一天。
private struct DayAgendaColumn: View {
    let column: DayAgendaColumnData
    let hours: Range<Int>
    let nowMinute: Int?
    let compact: Bool
    let separator: Bool
    @State private var targeted = false

    private typealias M = DayAgendaMetrics

    var body: some View {
        let highlight: Color = targeted ? Theme.accent.opacity(0.12) : Color.clear
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(highlight)
                ForEach(column.blocks) { block in
                    blockView(block, width: width)
                }
                if let nowMinute {
                    nowLine(nowMinute, width: width)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            if separator { Rectangle().fill(Theme.line).frame(width: 1) }
        }
        .contentShape(Rectangle())
        .modifier(CalendarDropModifier(day: column.day, targeted: $targeted))
    }

    private func blockView(_ block: DayAgendaBlock, width: CGFloat) -> some View {
        let place = M.horizontal(column: block.column, columns: block.columns, width: width, cascade: compact)
        let top = M.y(block.start, hours: hours) + 1.5
        let bottom = M.y(block.displayEnd, hours: hours) - 1.5
        let height = max(bottom - top, M.minBlockHeight)
        return DayAgendaBlockView(block: block, height: height, compact: compact)
            .frame(width: place.width, height: height)
            .offset(x: place.x, y: top)
            .zIndex(Double(block.column))
    }

    private func nowLine(_ minute: Int, width: CGFloat) -> some View {
        let top = M.y(minute, hours: hours)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.overdue)
                .frame(width: width, height: 2)
                .offset(y: top - 1)
            Circle()
                .fill(Theme.overdue)
                .frame(width: 9, height: 9)
                .offset(x: -4, y: top - 4.5)
        }
        .allowsHitTesting(false)
    }
}

/// 一个日程块：四象限颜色的浅底 + 左侧色条，深色字。已完成 / 已放弃的变淡、标题加删除线。
private struct DayAgendaBlockView: View {
    @Environment(AppModel.self) private var model
    let block: DayAgendaBlock
    let height: CGFloat
    /// 周视图：只写标题，详情放在悬停提示里。
    let compact: Bool

    private var item: OccurrenceItem { block.item }

    private var title: String {
        item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle
    }

    private var timeText: String {
        let occurrence = item.occurrence
        if block.continuesBefore || block.continuesAfter {
            return item.scheduleText(today: model.today)
        }
        let start = occurrence.startClock?.shortText ?? ""
        guard let end = occurrence.endClock, end != occurrence.startClock else { return start }
        return start + "–" + end.shortText
    }

    /// 「13:00–15:00 · 杭州西湖区文三社区 · 工作 · 已完成」
    private var detail: String {
        var parts: [String] = [timeText]
        let place = item.task.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty { parts.append(place) }
        if let list = model.snapshot.list(item.task.id3)?.displayName, !list.isEmpty { parts.append(list) }
        switch item.status {
        case .completed: parts.append("已完成")
        case .abandoned: parts.append("已放弃")
        default: if item.isOverdue(today: model.today) { parts.append("逾期") }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let tint = item.task.quadrant.tint
        let done = item.status != .pending
        let selected = model.selectedOccurrenceID == item.id || model.multiSelection.contains(item.id)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let fill: Color = tint.opacity(selected ? 0.3 : 0.16)
        let border: Color = selected ? Theme.accent : tint.opacity(0.35)
        let borderWidth: CGFloat = selected ? 2 : 1
        let help: String = [title, detail, "拖到其他日期可改期"].joined(separator: " · ")
        content(done: done)
            .padding(.leading, compact ? 6 : 9)
            .padding(.trailing, compact ? 2 : 5)
            .padding(.vertical, height >= 34 ? 4 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(fill))
            .background(shape.fill(Theme.card))
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
            .clipShape(shape)
            .overlay(shape.stroke(border, lineWidth: borderWidth))
            .opacity(done ? 0.55 : 1)
            .contentShape(shape)
            .onTapGesture { model.tapSelect(item) }
            .draggable(item.id)
            .themedContextMenu(onOpen: {
                model.selectedOccurrenceID = item.id
                model.selectedFocusID = nil
            }) { close in
                OccurrenceContextMenu(item: item, close: close).environment(model)
            }
            .help(help)
    }

    @ViewBuilder
    private func content(done: Bool) -> some View {
        if compact {
            // 周视图：标题按块的高度尽量多显示几行，放不下时字号稍缩小。
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .strikethrough(done)
                .foregroundStyle(Theme.text)
                .lineLimit(max(Int((height - 4) / 13), 1))
                .minimumScaleFactor(0.85)
        } else if height >= 34 {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .strikethrough(done)
                    .foregroundStyle(Theme.text)
                    .lineLimit(height >= 56 ? 2 : 1)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .strikethrough(done)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(1)
            }
        }
    }
}
