import SwiftUI

/// 年视图的取数：某一年的全部日期，以及每天有安排的实例数（不含已放弃和无日期）。
enum CalendarYear {
    static func range(year: Int) -> (start: LocalDate, end: LocalDate)? {
        guard let start = LocalDate(year: year, month: 1, day: 1),
              let end = LocalDate(year: year, month: 12, day: 31) else { return nil }
        return (start, end)
    }

    static func days(year: Int) -> [LocalDate] {
        guard let range = range(year: year) else { return [LocalDate.today()] }
        return (0...range.start.days(to: range.end)).map { range.start.adding(days: $0) }
    }

    static func dayCounts(_ items: [OccurrenceItem], year: Int) -> [LocalDate: Int] {
        guard let range = range(year: year) else { return [:] }
        var counts: [LocalDate: Int] = [:]
        for item in items where item.status != .abandoned && !item.task.undated {
            guard let start = item.occurrence.startDate else { continue }
            let end = item.occurrence.endDate ?? start
            var day = max(start, range.start)
            let last = min(end, range.end)
            while day <= last {
                counts[day, default: 0] += 1
                day = day.adding(days: 1)
            }
        }
        return counts
    }
}

/// 年视图：12 个小月历，4 列 × 3 行。
struct CalendarYearGrid: View {
    let year: Int
    let items: [OccurrenceItem]

    var body: some View {
        let counts = CalendarYear.dayCounts(items, year: year)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(1...12, id: \.self) { month in
                    if let first = LocalDate(year: year, month: month, day: 1) {
                        CalendarMiniMonth(month: first, counts: counts)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }
}

private struct CalendarMiniMonth: View {
    @Environment(AppModel.self) private var model
    let month: LocalDate
    let counts: [LocalDate: Int]

    var body: some View {
        let days = CalendarView.gridDays(month: month, weekStart: model.weekStart)
        let isCurrentMonth = month.year == model.today.year && month.month == model.today.month
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.showMonth(month)
            } label: {
                Text(verbatim: "\(month.month)月")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(isCurrentMonth ? Theme.accent : Theme.text)
            }
            .buttonStyle(.plain)
            .help("打开\(month.month)月的月视图")

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(LocalDate.weekdayShortNames[floorMod(index + model.weekStart, 7)])
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.fieldName)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: 1) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = days[row * 7 + column]
                            if day.month == month.month {
                                CalendarMiniDay(day: day, count: counts[day] ?? 0, isToday: day == model.today)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 24)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isCurrentMonth ? Theme.accent : Theme.line, lineWidth: 1))
    }
}

private struct CalendarMiniDay: View {
    @Environment(AppModel.self) private var model
    let day: LocalDate
    let count: Int
    let isToday: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(day.day)")
                .font(.system(size: 10.5, weight: isToday ? .heavy : .medium))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : Theme.text)
                .frame(width: 18, height: 16)
                .background(Circle().fill(isToday ? Theme.accent : Color.clear))
            Circle()
                .fill(count > 0 ? Theme.accent.opacity(min(0.35 + 0.2 * Double(count), 1)) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { model.showDay(day) }
        .help(day.shortTitle + (count > 0 ? " · \(count) 项" : ""))
    }
}
