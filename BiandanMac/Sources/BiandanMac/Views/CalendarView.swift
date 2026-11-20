import SwiftUI

/// 月历视图：6×7 网格，显示与每天有交集的执行实例（含已完成、已放弃）。
struct CalendarView: View {
    @Environment(AppModel.self) private var model

    static func gridDays(month: LocalDate, weekStart: Int) -> [LocalDate] {
        let first = month.firstOfMonth
        let offset = floorMod(first.weekday - weekStart, 7)
        let start = first.adding(days: -offset)
        return (0..<42).map { start.adding(days: $0) }
    }

    var body: some View {
        let month = model.calendarMonth
        let days = Self.gridDays(month: month, weekStart: model.weekStart)
        let rangeStart = days[0]
        let rangeEnd = days[41]
        let visible = model.items(for: .calendar).filter {
            !$0.task.undated && $0.occurrence.overlaps(rangeStart, rangeEnd)
        }
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: "\(month.year)年\(month.month)月")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button {
                    model.calendarMonth = month.adding(months: -1).firstOfMonth
                } label: {
                    Image(systemName: "chevron.left")
                }
                Button("今天") { model.calendarMonth = model.today.firstOfMonth }
                Button {
                    model.calendarMonth = month.adding(months: 1).firstOfMonth
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Text(LocalDate.weekdayShortNames[floorMod(index + model.weekStart, 7)])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.subtext)
                        .frame(maxWidth: .infinity)
                }
            }

            VStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = days[row * 7 + column]
                            CalendarDayCell(day: day,
                                            inMonth: day.month == month.month,
                                            isToday: day == model.today,
                                            items: visible.filter { $0.occurrence.overlaps(day, day) })
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }
}

struct CalendarDayCell: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let inMonth: Bool
    let isToday: Bool
    let items: [OccurrenceItem]
    @State private var showAll = false

    private let maxVisible = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "\(day.day)")
                    .font(.system(size: 13, weight: isToday ? .heavy : .semibold))
                    .foregroundStyle(isToday ? Color.white : (inMonth ? Theme.text : Theme.fieldName))
                    .padding(.horizontal, isToday ? 6 : 0)
                    .background(Capsule().fill(isToday ? Theme.accent : Color.clear))
                Text(lunarText)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(inMonth ? Theme.card : Theme.card.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isToday ? Theme.accent : Theme.line))
    }

    /// 初一显示月名，其余显示日名，例如「十月」「十二」。
    private var lunarText: String {
        guard let lunar = LunarCalendar.lunarDay(for: day) else { return "" }
        return lunar.day == 1 ? LunarCalendar.monthName(lunar.month, leap: lunar.isLeap) : LunarCalendar.dayName(lunar.day)
    }
}

struct CalendarChip: View {
    @Environment(AppModel.self) private var model
    let item: OccurrenceItem
    let day: LocalDate

    var body: some View {
        let selected = model.selectedOccurrenceID == item.id
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
            model.selectedOccurrenceID = item.id
            model.selectedFocusID = nil
        }
        .help(item.task.taskTitle + " · " + item.scheduleText(today: model.today))
    }

    private var label: String {
        let title = item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle
        guard item.occurrence.startDate == day, !item.occurrence.validStartTime.hasPrefix("00:00"),
              let clock = item.occurrence.startClock else { return title }
        return clock.shortText + " " + title
    }
}
