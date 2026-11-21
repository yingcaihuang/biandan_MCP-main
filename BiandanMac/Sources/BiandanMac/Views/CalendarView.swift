import SwiftUI

/// 日历：年视图（12 个小月历）、月视图（6×7 网格）、周视图（7 列）和单日视图。显示与每天有交集的执行实例（含已完成、已放弃），
/// 可以把实例拖到其他日期改期。
struct CalendarView: View {
    @Environment(AppModel.self) private var model

    static func gridDays(month: LocalDate, weekStart: Int) -> [LocalDate] {
        let first = month.firstOfMonth
        let offset = floorMod(first.weekday - weekStart, 7)
        let start = first.adding(days: -offset)
        return (0..<42).map { start.adding(days: $0) }
    }

    static func weekDays(containing day: LocalDate, weekStart: Int) -> [LocalDate] {
        let start = CalendarDrop.weekStart(of: day, weekStart: weekStart)
        return (0..<7).map { start.adding(days: $0) }
    }

    var body: some View {
        @Bindable var model = model
        let scope = model.calendarScope
        let days = visibleDays(scope)
        let rangeStart = days[0]
        let rangeEnd = days[days.count - 1]
        let visible = model.items(for: .calendar).filter {
            !$0.task.undated && $0.occurrence.overlaps(rangeStart, rangeEnd)
        }
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: title(days: days))
                    .font(.system(size: 17, weight: .bold))
                Picker("范围", selection: $model.calendarScope) {
                    ForEach(CalendarScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 176)
                Spacer()
                Text("拖动任务到其他日期即可改期")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.fieldName)
                ThemedDateField(date: Binding(get: { model.calendarFocus },
                                              set: { model.jumpCalendar(to: $0) }))
                    .help("跳转到任意一天")
                Group {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .help(stepHelp(-1))
                    Button("今天") { model.jumpCalendar(to: model.today) }
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .help(stepHelp(1))
                }
                .buttonStyle(.themed)
            }

            if scope == .year {
                CalendarYearGrid(year: model.calendarMonth.year, items: visible)
            } else if scope == .month {
                weekdayHeader
                VStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { column in
                                let day = days[row * 7 + column]
                                CalendarDayCell(day: day,
                                                inMonth: day.month == model.calendarMonth.month,
                                                isToday: day == model.today,
                                                items: visible.filter { $0.occurrence.overlaps(day, day) })
                            }
                        }
                    }
                }
            } else if scope == .week {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        CalendarWeekColumn(day: day, isToday: day == model.today,
                                           items: visible.filter { $0.occurrence.overlaps(day, day) })
                    }
                }
            } else {
                CalendarWeekColumn(day: model.calendarFocus, isToday: model.calendarFocus == model.today,
                                   items: visible)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private func visibleDays(_ scope: CalendarScope) -> [LocalDate] {
        switch scope {
        case .year: return CalendarYear.days(year: model.calendarMonth.year)
        case .month: return Self.gridDays(month: model.calendarMonth, weekStart: model.weekStart)
        case .week: return Self.weekDays(containing: model.calendarFocus, weekStart: model.weekStart)
        case .day: return [model.calendarFocus]
        }
    }

    private func stepHelp(_ direction: Int) -> String {
        let word = direction < 0 ? "上" : "下"
        switch model.calendarScope {
        case .year: return word + "一年"
        case .month: return word + "个月"
        case .week: return word + "一周"
        case .day: return direction < 0 ? "前一天" : "后一天"
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { index in
                Text(LocalDate.weekdayShortNames[floorMod(index + model.weekStart, 7)])
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func title(days: [LocalDate]) -> String {
        if model.calendarScope == .year {
            return "\(model.calendarMonth.year)年"
        }
        if model.calendarScope == .day {
            let day = model.calendarFocus
            return "\(day.year)年\(day.month)月\(day.day)日 " + LocalDate.weekdayNames[day.weekday]
        }
        if model.calendarScope == .month {
            let month = model.calendarMonth
            return "\(month.year)年\(month.month)月"
        }
        let first = days[0], last = days[days.count - 1]
        let tail = first.month == last.month ? "\(last.day)日" : "\(last.month)月\(last.day)日"
        return "\(first.year)年\(first.month)月\(first.day)日 – " + tail
    }

    private func step(_ direction: Int) {
        let next = CalendarNavigation.step(scope: model.calendarScope, month: model.calendarMonth,
                                           focus: model.calendarFocus, direction: direction)
        model.calendarMonth = next.month
        model.calendarFocus = next.focus
    }
}

/// 初一显示月名，其余显示日名，例如「十月」「十二」。
func calendarLunarText(_ day: LocalDate) -> String {
    guard let lunar = LunarCalendar.lunarDay(for: day) else { return "" }
    return lunar.day == 1 ? LunarCalendar.monthName(lunar.month, leap: lunar.isLeap) : LunarCalendar.dayName(lunar.day)
}

/// 把拖进来的实例改期到这一天。
private struct CalendarDropModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { identifiers, _ in
            for identifier in identifiers {
                Task { await model.dropOnDay(identifier, day: day) }
            }
            return !identifiers.isEmpty
        } isTargeted: { value in
            targeted = value
        }
    }
}

struct CalendarDayCell: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let inMonth: Bool
    let isToday: Bool
    let items: [OccurrenceItem]
    @State private var showAll = false
    @State private var targeted = false

    private let maxVisible = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "\(day.day)")
                    .font(.system(size: 13, weight: isToday ? .heavy : .semibold))
                    .foregroundStyle(isToday ? Color.white : (inMonth ? Theme.text : Theme.fieldName))
                    .padding(.horizontal, isToday ? 6 : 0)
                    .background(Capsule().fill(isToday ? Theme.accent : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.showDay(day) }
                    .help("查看这一天")
                Text(calendarLunarText(day))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.fieldName)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            ForEach(items.prefix(maxVisible)) { item in
                CalendarChip(item: item, day: day)
            }
            if items.count > maxVisible {
                Button {
                    showAll = true
                } label: {
                    Text(verbatim: "+\(items.count - maxVisible) 项")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.subtext)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAll, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.shortTitle).font(.system(size: 13, weight: .bold))
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(items) { item in
                                    OccurrenceCard(item: item)
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                    }
                    .padding(12)
                    .frame(width: 300)
                    .background(Theme.background)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(targeted ? Theme.accent.opacity(0.14) : (inMonth ? Theme.card : Theme.card.opacity(0.45))))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(targeted || isToday ? Theme.accent : Theme.line, lineWidth: targeted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .modifier(CalendarDropModifier(day: day, targeted: $targeted))
    }
}

/// 周视图的一列：当天的完整任务卡片。
struct CalendarWeekColumn: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let isToday: Bool
    let items: [OccurrenceItem]
    @State private var targeted = false

    var body: some View {
        let weekend = day.pythonWeekday >= 5
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(LocalDate.weekdayShortNames[day.weekday])
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(weekend ? Color(hex: 0xD9534A) : Theme.subtext)
                Text(verbatim: "\(day.day)")
                    .font(.system(size: 16, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : Theme.text)
                    .padding(.horizontal, isToday ? 7 : 0)
                    .background(Capsule().fill(isToday ? Theme.accent : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.showDay(day) }
                    .help("查看这一天")
                Text(calendarLunarText(day))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.fieldName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !items.isEmpty {
                    Text(verbatim: "\(items.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.subtext)
                }
            }
            if items.isEmpty {
                Text("拖到这里改期")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.fieldName)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items) { item in
                            OccurrenceCard(item: item)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? Theme.accent.opacity(0.14) : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(targeted || isToday ? Theme.accent : Theme.line, lineWidth: targeted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .modifier(CalendarDropModifier(day: day, targeted: $targeted))
    }
}

struct CalendarChip: View {
    @Environment(AppModel.self) private var model
    let item: OccurrenceItem
    let day: LocalDate

    var body: some View {
        let selected = model.selectedOccurrenceID == item.id || model.multiSelection.contains(item.id)
        let tint = item.task.quadrant.tint
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3)
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .strikethrough(item.status != .pending)
                .foregroundStyle(item.status == .pending ? Theme.text : Theme.subtext)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 4)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(selected ? 0.32 : 0.12)))
        .contentShape(Rectangle())
        .onTapGesture {
            model.tapSelect(item)
        }
        .draggable(item.id)
        .help(item.task.taskTitle + " · " + item.scheduleText(today: model.today) + " · 拖到其他日期可改期")
    }

    private var label: String {
        let title = item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle
        guard item.occurrence.startDate == day, !item.occurrence.validStartTime.hasPrefix("00:00"),
              let clock = item.occurrence.startClock else { return title }
        return clock.shortText + " " + title
    }
}
