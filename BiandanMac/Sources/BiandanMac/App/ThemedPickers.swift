import SwiftUI

// MARK: - 主题选择组件：日期、时刻、待办单（遵循 DESIGN.md，替代系统 DatePicker / Picker）

/// 主题输入框外观（米色底、细描边，展开时用强调色描边）；确认卡片的分类选择也用它。
struct FieldChrome: ViewModifier {
    let active: Bool
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(active ? tint : Theme.line, lineWidth: active ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func fieldChrome(active: Bool, tint: Color) -> some View {
        modifier(FieldChrome(active: active, tint: tint))
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.subtext)
    }
}

enum DateText {
    static func relative(_ day: LocalDate, today: LocalDate) -> String {
        let diff = today.days(to: day)
        switch diff {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        case 3...: return "\(diff)天后"
        default: return "\(-diff)天前"
        }
    }

    static func title(_ day: LocalDate, today: LocalDate) -> String {
        let week = LocalDate.weekdayNames[day.weekday]
        if day.year == today.year { return "\(day.month)月\(day.day)日 \(week)" }
        return "\(day.year)年\(day.month)月\(day.day)日 \(week)"
    }

    static func period(_ hour: Int) -> String {
        switch hour {
        case 0..<6: return "凌晨"
        case 6..<12: return "上午"
        case 12..<14: return "中午"
        case 14..<18: return "下午"
        default: return "晚上"
        }
    }
}

// MARK: - 日期

/// 日期输入框：显示「11月24日 周二」+ 相对日期标签，点开主题月历。
struct ThemedDateField: View {
    @Environment(AppModel.self) private var model
    @Binding var date: LocalDate
    let minimum: LocalDate?
    let tint: Color
    @State private var open = false

    init(date: Binding<LocalDate>, minimum: LocalDate? = nil, tint: Color = Theme.accent) {
        _date = date
        self.minimum = minimum
        self.tint = tint
    }

    /// 绑定 Date 时只改日期部分，保留原来的时刻。
    init(date: Binding<Date>, minimum: Date? = nil, tint: Color = Theme.accent) {
        let local = Binding<LocalDate>(
            get: { LocalDate.today(date.wrappedValue) },
            set: { newValue in
                let time = LocalTime.from(date.wrappedValue)
                date.wrappedValue = time.date(on: newValue)
            }
        )
        self.init(date: local, minimum: minimum.map { LocalDate.today($0) }, tint: tint)
    }

    var body: some View {
        let today = model.today
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(verbatim: DateText.title(date, today: today))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(DateText.relative(date, today: today))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.14)))
                Chevron()
            }
            .fieldChrome(active: open, tint: tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ThemedCalendarPanel(selection: date, minimum: minimum, today: today,
                                weekStart: model.weekStart, tint: tint) { picked in
                date = picked
                open = false
            }
        }
    }
}

/// 月历面板：快捷日期、农历、节假日「休 / 班」、今天描边、选中用象限色。
struct ThemedCalendarPanel: View {
    let selection: LocalDate
    let minimum: LocalDate?
    let today: LocalDate
    let weekStart: Int
    let tint: Color
    let onPick: (LocalDate) -> Void
    @State private var month: LocalDate

    init(selection: LocalDate, minimum: LocalDate?, today: LocalDate, weekStart: Int, tint: Color,
         onPick: @escaping (LocalDate) -> Void) {
        self.selection = selection
        self.minimum = minimum
        self.today = today
        self.weekStart = weekStart
        self.tint = tint
        self.onPick = onPick
        _month = State(initialValue: selection.firstOfMonth)
    }

    private struct Shortcut: Identifiable {
        let title: String
        let day: LocalDate
        var id: String { title }
    }

    private var shortcuts: [Shortcut] {
        let saturday = today.adding(days: floorMod(6 - today.weekday, 7))
        var toMonday = floorMod(1 - today.weekday, 7)
        if toMonday == 0 { toMonday = 7 }
        return [
            Shortcut(title: "今天", day: today),
            Shortcut(title: "明天", day: today.adding(days: 1)),
            Shortcut(title: "本周末", day: saturday),
            Shortcut(title: "下周一", day: today.adding(days: toMonday)),
            Shortcut(title: "下个月", day: today.adding(months: 1)),
        ]
    }

    private var lunarYear: String {
        LunarCalendar.lunarDay(for: month.adding(days: 14)).map { LunarCalendar.ganzhi(year: $0.year) + "年" } ?? ""
    }

    var body: some View {
        let days = CalendarView.gridDays(month: month, weekStart: weekStart)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(month.year)年\(month.month)月")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text(lunarYear)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                Spacer()
                navButton("chevron.left") { month = month.adding(months: -1).firstOfMonth }
                Button {
                    month = today.firstOfMonth
                } label: {
                    Text("本月")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(height: 24)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                navButton("chevron.right") { month = month.adding(months: 1).firstOfMonth }
            }

            HStack(spacing: 5) {
                ForEach(shortcuts) { shortcut in
                    shortcutChip(shortcut)
                }
            }

            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        let weekday = floorMod(index + weekStart, 7)
                        Text(LocalDate.weekdayShortNames[weekday])
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(weekday == 0 || weekday == 6 ? Color(hex: 0xD9534A) : Theme.subtext)
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                    }
                }
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            let day = days[row * 7 + column]
                            DayCell(day: day,
                                    inMonth: day.month == month.month,
                                    selected: day == selection,
                                    isToday: day == today,
                                    disabled: minimum.map { day < $0 } ?? false,
                                    tint: tint) {
                                onPick(day)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))

            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(verbatim: "已选 " + DateText.title(selection, today: today))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(LunarCalendar.headerText(for: selection))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.panel)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortcutChip(_ shortcut: Shortcut) -> some View {
        let on = shortcut.day == selection
        let disabled = minimum.map { shortcut.day < $0 } ?? false
        return Button {
            onPick(shortcut.day)
        } label: {
            Text(shortcut.title)
                .font(.system(size: 11.5, weight: on ? .bold : .medium))
                .foregroundStyle(on ? Color.white : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? tint : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.clear : Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(DateText.title(shortcut.day, today: today))
    }
}

private struct DayCell: View {
    let day: LocalDate
    let inMonth: Bool
    let selected: Bool
    let isToday: Bool
    let disabled: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    private var weekend: Bool { day.pythonWeekday >= 5 }

    private var numberColor: Color {
        if selected { return .white }
        if disabled { return Theme.fieldName.opacity(0.6) }
        if !inMonth { return Theme.fieldName }
        if weekend { return Color(hex: 0xD9534A) }
        return Theme.text
    }

    private var fill: Color {
        if selected { return tint }
        if hovering && !disabled { return tint.opacity(0.12) }
        return .clear
    }

    /// 法定节假日（工作日放假）标「休」，调休上班（周末上班）标「班」。
    private var badge: String? {
        guard ChinaMakeup.days.contains(day) else { return nil }
        return weekend ? "班" : "休"
    }

    private var lunar: String {
        guard let value = LunarCalendar.lunarDay(for: day) else { return "" }
        return value.day == 1 ? LunarCalendar.monthName(value.month, leap: value.isLeap) : LunarCalendar.dayName(value.day)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(verbatim: "\(day.day)")
                    .font(.system(size: 13, weight: selected || isToday ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                Text(lunar)
                    .font(.system(size: 8.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.fieldName)
                    .lineLimit(1)
            }
            .frame(width: 38, height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(isToday && !selected ? tint : Color.clear, lineWidth: 1.3))
            .overlay(alignment: .topTrailing) { badgeView }
            .opacity(inMonth ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            Text(badge)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 12, height: 12)
                .background(Circle().fill(badge == "休" ? Color(hex: 0xE5483A) : Theme.subtext))
                .offset(x: 3, y: -3)
        }
    }
}

// MARK: - 时刻

/// 时刻输入框：「09:30 上午」，点开选小时和分钟。
struct ThemedTimeField: View {
    @Binding var time: LocalTime
    let tint: Color
    @State private var open = false

    init(time: Binding<LocalTime>, tint: Color = Theme.accent) {
        _time = time
        self.tint = tint
    }

    /// 绑定 Date 时只改时刻部分，保留原来的日期。
    init(time: Binding<Date>, tint: Color = Theme.accent) {
        let local = Binding<LocalTime>(
            get: { LocalTime.from(time.wrappedValue) },
            set: { newValue in
                let day = LocalDate.today(time.wrappedValue)
                time.wrappedValue = newValue.date(on: day)
            }
        )
        self.init(time: local, tint: tint)
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(verbatim: time.shortText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(DateText.period(time.hour))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
                Chevron()
            }
            .fieldChrome(active: open, tint: tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ThemedTimePanel(initial: time, tint: tint, onChange: { time = $0 }, onDone: { open = false })
        }
    }
}

struct ThemedTimePanel: View {
    let tint: Color
    let onChange: (LocalTime) -> Void
    let onDone: () -> Void
    @State private var hour: Int
    @State private var minute: Int

    private static let presets: [(Int, Int)] = [(9, 0), (12, 0), (14, 0), (18, 0), (21, 0)]

    init(initial: LocalTime, tint: Color, onChange: @escaping (LocalTime) -> Void, onDone: @escaping () -> Void) {
        self.tint = tint
        self.onChange = onChange
        self.onDone = onDone
        _hour = State(initialValue: initial.hour)
        _minute = State(initialValue: initial.minute)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: String(format: "%02d:%02d", hour, minute))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(DateText.period(hour))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Button("完成") { onDone() }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 5) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    chip(String(format: "%02d:%02d", preset.0, preset.1),
                         selected: hour == preset.0 && minute == preset.1) {
                        hour = preset.0
                        minute = preset.1
                        emit()
                    }
                }
            }

            sectionTitle("小时")
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<4, id: \.self) { row in
                    GridRow {
                        ForEach(0..<6, id: \.self) { column in
                            let value = row * 6 + column
                            chip(String(format: "%02d", value), selected: value == hour) {
                                hour = value
                                emit()
                            }
                        }
                    }
                }
            }

            sectionTitle("分钟")
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<6, id: \.self) { column in
                            let value = (row * 6 + column) * 5
                            chip(String(format: "%02d", value), selected: value == minute) {
                                minute = value
                                emit()
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.panel)
    }

    private func emit() {
        if let value = LocalTime(hour: hour, minute: minute) { onChange(value) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.subtext)
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.system(size: 12, weight: selected ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? tint : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.clear : Theme.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 待办单

/// 待办单选择：彩色圆点 + 名称，点开列表选择。
struct ThemedListPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    var tint: Color = Theme.accent
    @State private var open = false

    var body: some View {
        let current = model.snapshot.list(selection)
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(current?.swatch ?? Theme.fieldName).frame(width: 10, height: 10)
                Text(current?.displayName ?? "未分类")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Chevron()
            }
            .fieldChrome(active: open, tint: tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(model.snapshot.lists) { list in
                    Button {
                        selection = list.id3
                        open = false
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(list.swatch).frame(width: 10, height: 10)
                            Text(list.displayName)
                                .font(.system(size: 13, weight: list.id3 == selection ? .semibold : .regular))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 12)
                            if list.id3 == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(tint)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(width: 220)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .background(Theme.panel)
        }
    }
}
