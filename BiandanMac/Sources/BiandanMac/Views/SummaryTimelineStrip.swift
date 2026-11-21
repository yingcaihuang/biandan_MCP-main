import SwiftUI

/// 完成率卡片下方的时间条：今天显示 0–24 点，近 7 天 / 本月显示日期。不依赖 AppModel，便于单独渲染检查。
struct SummaryTimelineStrip: View {
    let items: [OccurrenceItem]
    let range: ProgressRange
    let today: LocalDate
    let now: Date
    let tint: (OccurrenceItem) -> Color
    var selectedID: String?
    var onSelect: (OccurrenceItem) -> Void = { _ in }

    var body: some View {
        switch range {
        case .today:
            DayTimelineStrip(items: items, day: today, now: now, tint: tint, selectedID: selectedID, onSelect: onSelect)
        case .next7, .month:
            let bounds = range.bounds(today: today)
            RangeTimelineStrip(items: items, start: bounds.start, end: bounds.end, today: today,
                               tint: tint, selectedID: selectedID, onSelect: onSelect)
        }
    }
}

enum TimelineStyle {
    static let inset: CGFloat = 7
    static let laneHeight: CGFloat = 13
    static let barHeight: CGFloat = 8
    static let dot: CGFloat = 10
    static let labelHeight: CGFloat = 20
    /// 没设分类颜色、又不重要不紧急的待办用中性色，避免和「已完成」的绿色混淆。
    static let neutral = Color(hex: 0x7A869A)

    static func fallbackTint(_ item: OccurrenceItem) -> Color {
        item.task.important || item.task.urgent ? item.task.quadrant.tint : neutral
    }

    /// 一天的天色：深夜 → 清晨 → 正午 → 傍晚 → 入夜。
    static let dayGradient = LinearGradient(stops: [
        .init(color: Color(hex: 0x3D4A7A), location: 0),
        .init(color: Color(hex: 0x8C9BD0), location: 0.2),
        .init(color: Color(hex: 0xFFDF8A), location: 0.3),
        .init(color: Color(hex: 0xF5B800), location: 0.5),
        .init(color: Color(hex: 0xF08A24), location: 0.74),
        .init(color: Color(hex: 0x8E5BD6), location: 0.86),
        .init(color: Color(hex: 0x3D4A7A), location: 1),
    ], startPoint: .leading, endPoint: .trailing)

    static let rangeGradient = LinearGradient(colors: [Color(hex: 0xFFEDB5), Color(hex: 0xF5C23A), Color(hex: 0xF08A24)],
                                              startPoint: .leading, endPoint: .trailing)

    static func barTop(lanes: Int) -> CGFloat { CGFloat(lanes) * laneHeight + 4 }
    static func laneCenter(_ lane: Int, lanes: Int) -> CGFloat {
        barTop(lanes: lanes) - laneHeight / 2 - 1 - CGFloat(lane) * laneHeight
    }
    static func height(lanes: Int) -> CGFloat { barTop(lanes: lanes) + barHeight + labelHeight }
    static func x(_ fraction: Double, width: CGFloat) -> CGFloat {
        inset + CGFloat(min(max(fraction, 0), 1)) * max(width - inset * 2, 1)
    }

    /// 提示卡片的一行：标题（过长截断）+ 时间 · 状态（· 提醒时刻）。
    static func tooltipRow(_ item: OccurrenceItem, color: Color, today: LocalDate, extra: String? = nil) -> TimelineTooltipRow {
        var title = item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle
        if title.count > 28 { title = String(title.prefix(27)) + "…" }
        var detail = item.scheduleText(today: today) + " · " + item.status.title
        if let extra { detail += " · " + extra }
        return TimelineTooltipRow(title: title, detail: detail, color: color)
    }
}

private struct TimelineDot: View {
    let item: OccurrenceItem
    let color: Color
    let selected: Bool
    /// 鼠标靠近时放大一点，提示正指向它。
    var hovered = false
    /// 空心点：全天任务的提醒时刻。
    var hollow = false

    var body: some View {
        let fill: Color = hollow ? Theme.card : color
        let ring: Color = hollow ? color : (selected ? Theme.text : Color.white)
        let ringWidth: CGFloat = hollow ? (selected ? 3 : 2.2) : (selected ? 2 : 1.5)
        Circle()
            .fill(fill)
            .overlay(Circle().stroke(ring, lineWidth: ringWidth))
            .overlay {
                if item.status == .completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 5.5, weight: .black))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: TimelineStyle.dot, height: TimelineStyle.dot)
            .scaleEffect(hovered ? 1.4 : 1)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - 今天：0–24 点

private struct DayTimelineStrip: View {
    let items: [OccurrenceItem]
    let day: LocalDate
    let now: Date
    let tint: (OccurrenceItem) -> Color
    let selectedID: String?
    let onSelect: (OccurrenceItem) -> Void
    @State private var showAllDay = false
    @State private var hovered: String?

    var body: some View {
        let layout = TimelineLayout.day(items, day: day)
        let lanes = max((layout.timed.map(\.lane).max() ?? -1) + 1, 1)
        let top = TimelineStyle.barTop(lanes: lanes)
        HStack(alignment: .top, spacing: 10) {
            allDayChip(layout.allDay)
                .padding(.top, max(top + TimelineStyle.barHeight / 2 - 15, 0))
            GeometryReader { geo in
                track(layout.timed, lanes: lanes, width: geo.size.width)
            }
            .frame(height: TimelineStyle.height(lanes: lanes))
        }
    }

    private var nowFraction: Double { TimelineLayout.fraction(of: now) }

    private func reminderText(_ mark: TimelineMark) -> String? {
        guard mark.isReminder else { return nil }
        let total = Int((mark.start * 1440).rounded())
        return String(format: "提醒 %02d:%02d", total / 60, total % 60)
    }

    private func targets(_ marks: [TimelineMark], lanes: Int, width: CGFloat) -> [TimelineHoverTarget] {
        marks.map { mark in
            let point = CGPoint(x: TimelineStyle.x(mark.start, width: width),
                                y: TimelineStyle.laneCenter(mark.lane, lanes: lanes))
            let row = TimelineStyle.tooltipRow(mark.item, color: color(mark), today: day, extra: reminderText(mark))
            return TimelineHoverTarget(id: mark.id, point: point, item: mark.item, rows: [row])
        }
    }

    private var nowText: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private func color(_ mark: TimelineMark) -> Color {
        let item = mark.item
        if item.status == .completed { return Theme.done }
        // 提醒时刻过了不算逾期：全天任务要到当天结束才逾期。
        if let last = item.occurrence.endDate, last < day || (!mark.isReminder && last == day && mark.end < nowFraction) {
            return Theme.overdue
        }
        return tint(item)
    }

    private func track(_ marks: [TimelineMark], lanes: Int, width: CGFloat) -> some View {
        let top = TimelineStyle.barTop(lanes: lanes)
        let labelY = top + TimelineStyle.barHeight + 10
        let nowX = TimelineStyle.x(nowFraction, width: width)
        let span = max(width - TimelineStyle.inset * 2, 1)
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(TimelineStyle.dayGradient)
                .frame(width: span, height: TimelineStyle.barHeight)
                .offset(x: TimelineStyle.inset, y: top)
            // 有时长的任务：从圆点向右画一条细线表示时段，不遮住渐变条。
            ForEach(marks.filter { $0.end - $0.start > 0.004 }) { mark in
                Capsule()
                    .fill(color(mark).opacity(0.45))
                    .frame(width: max(CGFloat(mark.end - mark.start) * span, 4), height: 3)
                    .offset(x: TimelineStyle.x(mark.start, width: width),
                            y: TimelineStyle.laneCenter(mark.lane, lanes: lanes) - 1.5)
            }
            ForEach(TimelineLayout.hourTicks, id: \.self) { hour in
                let x = TimelineStyle.x(Double(hour) / 24, width: width)
                if abs(x - nowX) > 16 {
                    Text(verbatim: "\(hour)")
                        .font(.system(size: 9.5, weight: hour % 6 == 0 ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(hour % 6 == 0 ? Theme.subtext : Theme.fieldName)
                        .position(x: x, y: labelY)
                }
            }
            Rectangle()
                .fill(Theme.overdue)
                .frame(width: 1.5, height: top + TimelineStyle.barHeight + 3)
                .offset(x: nowX - 0.75)
            Text(verbatim: nowText)
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.overdue)
                .position(x: nowX, y: labelY)
            if marks.isEmpty {
                // 放在离「现在」竖线较远的一侧，避免压线。
                Text("今天没有定时安排或提醒")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.fieldName)
                    .position(x: width * (nowFraction < 0.5 ? 0.72 : 0.28), y: TimelineStyle.laneCenter(0, lanes: lanes))
            }
            ForEach(marks) { mark in
                TimelineDot(item: mark.item, color: color(mark), selected: selectedID == mark.id,
                            hovered: hovered == mark.id,
                            hollow: mark.isReminder && mark.item.status != .completed)
                    .position(x: TimelineStyle.x(mark.start, width: width),
                              y: TimelineStyle.laneCenter(mark.lane, lanes: lanes))
            }
            TimelineHoverLayer(targets: targets(marks, lanes: lanes, width: width),
                               size: CGSize(width: width, height: TimelineStyle.height(lanes: lanes)),
                               hovered: $hovered, onSelect: onSelect)
        }
        .frame(width: width, height: TimelineStyle.height(lanes: lanes), alignment: .topLeading)
    }

    private func allDayChip(_ allDay: [OccurrenceItem]) -> some View {
        let titles = allDay.map { $0.task.taskTitle.isEmpty ? "（无标题）" : $0.task.taskTitle }
        return Button {
            showAllDay = true
        } label: {
            VStack(spacing: 0) {
                Text("全天")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.subtext)
                Text(verbatim: "\(allDay.count)")
                    .font(.system(size: 13, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            .frame(width: 40, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(allDay.isEmpty)
        .opacity(allDay.isEmpty ? 0.5 : 1)
        .help(allDay.isEmpty ? "今天没有全天任务" : "全天任务：" + titles.joined(separator: "、"))
        .popover(isPresented: $showAllDay, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("全天任务").font(.system(size: 12.5, weight: .bold))
                ForEach(allDay) { item in
                    HStack(spacing: 6) {
                        Circle().fill(item.status == .completed ? Theme.done : tint(item)).frame(width: 8, height: 8)
                        Text(item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle)
                            .font(.system(size: 12))
                            .strikethrough(item.status == .completed)
                            .foregroundStyle(item.status == .completed ? Theme.subtext : Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(item)
                        showAllDay = false
                    }
                }
            }
            .padding(12)
            .frame(width: 230)
            .background(Theme.background)
        }
    }
}

// MARK: - 近 7 天 / 本月：日期

private struct RangeTimelineStrip: View {
    let items: [OccurrenceItem]
    let start: LocalDate
    let end: LocalDate
    let today: LocalDate
    let tint: (OccurrenceItem) -> Color
    let selectedID: String?
    let onSelect: (OccurrenceItem) -> Void
    @State private var hovered: String?

    var body: some View {
        let groups = TimelineLayout.range(items, start: start, end: end)
        let lanes = min(max(groups.map(\.items.count).max() ?? 0, 1), TimelineLayout.maxLanes)
        GeometryReader { geo in
            track(groups, lanes: lanes, width: geo.size.width)
        }
        .frame(height: TimelineStyle.height(lanes: lanes))
    }

    private var count: Int { max(start.days(to: end) + 1, 1) }

    private func center(_ index: Int) -> Double { (Double(index) + 0.5) / Double(count) }

    private func color(_ item: OccurrenceItem) -> Color {
        if item.status == .completed { return Theme.done }
        if item.isOverdue(today: today) { return Theme.overdue }
        return tint(item)
    }

    private func targets(_ groups: [TimelineDayGroup], lanes: Int, width: CGFloat) -> [TimelineHoverTarget] {
        var result: [TimelineHoverTarget] = []
        for group in groups {
            let x = TimelineStyle.x(center(group.index), width: width)
            let overflow = group.items.count > lanes
            for (lane, item) in group.items.prefix(lanes).enumerated() {
                let point = CGPoint(x: x, y: TimelineStyle.laneCenter(lane, lanes: lanes))
                if overflow && lane == lanes - 1 {
                    let hidden = Array(group.items.dropFirst(lanes - 1))
                    let rows = hidden.prefix(4).map { TimelineStyle.tooltipRow($0, color: color($0), today: today) }
                    result.append(TimelineHoverTarget(id: "more-\(group.index)", point: point, item: nil,
                                                      rows: Array(rows), more: hidden.count - rows.count))
                } else {
                    let row = TimelineStyle.tooltipRow(item, color: color(item), today: today)
                    result.append(TimelineHoverTarget(id: item.id, point: point, item: item, rows: [row]))
                }
            }
        }
        return result
    }

    /// 本月刻度：今天前后 2 天内的刻度让位给「今天」。
    private func visibleTicks(todayIndex: Int?) -> [Int] {
        let ticks = TimelineLayout.rangeTicks(start: start, end: end)
        guard count > 7, let todayIndex else { return ticks }
        return (ticks.filter { abs($0 - todayIndex) > 2 } + [todayIndex]).sorted()
    }

    private func label(_ index: Int) -> String {
        let day = start.adding(days: index)
        return count <= 7 ? LocalDate.weekdayShortNames[day.weekday] + " \(day.day)" : "\(day.day)"
    }

    private func track(_ groups: [TimelineDayGroup], lanes: Int, width: CGFloat) -> some View {
        let top = TimelineStyle.barTop(lanes: lanes)
        let labelY = top + TimelineStyle.barHeight + 10
        let span = max(width - TimelineStyle.inset * 2, 1)
        let todayIndex = start.days(to: today)
        let showToday = todayIndex >= 0 && todayIndex < count
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(TimelineStyle.rangeGradient)
                .frame(width: span, height: TimelineStyle.barHeight)
                .offset(x: TimelineStyle.inset, y: top)
            if showToday {
                // 在渐变条上框出今天这一格，不穿过上方的圆点。
                let slot = max(span / CGFloat(count), 6)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.overdue, lineWidth: 1.5)
                    .frame(width: slot, height: TimelineStyle.barHeight + 6)
                    .offset(x: TimelineStyle.x(center(todayIndex), width: width) - slot / 2, y: top - 3)
            }
            ForEach(visibleTicks(todayIndex: showToday ? todayIndex : nil), id: \.self) { index in
                let isToday = showToday && index == todayIndex
                Text(verbatim: isToday && count > 7 ? "今天" : label(index))
                    .font(.system(size: 9.5, weight: isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Theme.overdue : Theme.subtext)
                    .position(x: TimelineStyle.x(center(index), width: width), y: labelY)
            }
            if groups.isEmpty {
                Text("这段时间没有安排")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.fieldName)
                    .position(x: width / 2, y: TimelineStyle.laneCenter(0, lanes: lanes))
            }
            ForEach(groups) { group in
                let x = TimelineStyle.x(center(group.index), width: width)
                let overflow = group.items.count > lanes
                ForEach(Array(group.items.prefix(lanes).enumerated()), id: \.element.id) { lane, item in
                    if overflow && lane == lanes - 1 {
                        let hot = hovered == "more-\(group.index)"
                        let textColor: Color = hot ? Theme.text : Theme.subtext
                        let strokeColor: Color = hot ? Theme.accent : Theme.line
                        Text(verbatim: "+\(group.items.count - lanes + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(textColor)
                            .padding(.horizontal, 4)
                            .frame(height: 12)
                            .background(Capsule().fill(Theme.panel))
                            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
                            .position(x: x, y: TimelineStyle.laneCenter(lane, lanes: lanes))
                    } else {
                        TimelineDot(item: item, color: color(item), selected: selectedID == item.id,
                                    hovered: hovered == item.id)
                            .position(x: x, y: TimelineStyle.laneCenter(lane, lanes: lanes))
                    }
                }
            }
            TimelineHoverLayer(targets: targets(groups, lanes: lanes, width: width),
                               size: CGSize(width: width, height: TimelineStyle.height(lanes: lanes)),
                               hovered: $hovered, onSelect: onSelect)
        }
        .frame(width: width, height: TimelineStyle.height(lanes: lanes), alignment: .topLeading)
    }
}
