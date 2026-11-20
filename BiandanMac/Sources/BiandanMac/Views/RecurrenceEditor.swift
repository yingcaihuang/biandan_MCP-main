import SwiftUI

// MARK: - 重复规则草稿（界面编辑用，保存时转为 RepeatRule）

extension LoopSet {
    /// 编辑器里提供的 8 种重复方式。
    static let editorModes: [LoopSet] = [.daily, .workdays, .daysOff, .custom,
                                         .ebbinghaus, .weeklyPeriod, .monthlyPeriod, .yearlyPeriod]

    var hint: String {
        switch self {
        case .none: return ""
        case .custom: return "按周、月、年或农历"
        case .daily: return "每天一次"
        case .workdays: return "周一至周五"
        case .daysOff: return "周六、周日"
        case .ebbinghaus: return "第 1、2、3、5、7、15 天…"
        case .weeklyPeriod: return "整周算一次"
        case .monthlyPeriod: return "整月算一次"
        case .yearlyPeriod: return "整年算一次"
        }
    }
}

extension DayFilter {
    var shortTitle: String {
        switch self {
        case .all: return "全部"
        case .daysOff: return "仅休息日"
        case .workdays: return "仅工作日"
        }
    }
}

struct RuleDraft: Hashable, Sendable {
    var mode: LoopSet = .custom
    var interval = 1
    var unit: LoopUnitKind = .week
    var weekdays: Set<Int> = []
    var monthDays: Set<Int> = []
    var lunarMonthDays: Set<Int> = []
    var yearDates: [String] = []
    var lunarYearDates: [String] = []
    var filter: DayFilter = .all
    var duration = 1
    var habit = false

    /// 默认「每周 + 开始日所在的星期」，其他单位的默认日期也取开始日。
    init(start: LocalDate) {
        weekdays = [start.weekday]
        monthDays = [start.day]
        yearDates = [String(format: "%02d-%02d", start.month, start.day)]
        if let lunar = LunarCalendar.lunarDay(for: start) {
            lunarMonthDays = [lunar.day]
            lunarYearDates = [String(format: "%02d-%02d", lunar.month, lunar.day)]
        }
    }

    /// 从已有任务读回规则。
    init(task: TaskDef, fallbackStart: LocalDate) {
        self.init(start: fallbackStart)
        habit = task.isHabit
        guard let rule = RepeatRule(task: task) else { return }
        mode = rule.mode
        duration = max(rule.durationDays ?? 1, 1)
        guard mode == .custom else { return }
        interval = max(rule.interval ?? 1, 1)
        unit = rule.unit ?? .day
        filter = rule.dayFilter ?? .all
        let dates = rule.dates ?? []
        switch unit {
        case .day: break
        case .week: weekdays = Set(dates.compactMap { Int($0) })
        case .month: monthDays = Set(dates.compactMap { Int($0) })
        case .lunarMonth: lunarMonthDays = Set(dates.compactMap { Int($0) })
        case .year: yearDates = dates.sorted()
        case .lunarYear: lunarYearDates = dates.sorted()
        }
    }

    var rule: RepeatRule {
        guard mode == .custom else {
            return RepeatRule(mode: mode, durationDays: mode.isPeriod ? nil : duration)
        }
        let dates: [String]
        switch unit {
        case .day: dates = []
        case .week: dates = weekdays.sorted().map(String.init)
        case .month: dates = monthDays.sorted().map(String.init)
        case .lunarMonth: dates = lunarMonthDays.sorted().map(String.init)
        case .year: dates = yearDates
        case .lunarYear: dates = lunarYearDates
        }
        return RepeatRule(mode: .custom, unit: unit, interval: interval, dates: dates,
                          dayFilter: filter, durationDays: duration)
    }
}

// MARK: - 小组件

private struct RuleChip: View {
    let title: String
    var subtitle: String? = nil
    let on: Bool
    let tint: Color
    var height: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: on ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(on ? Color.white : Theme.text)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(on ? Color.white.opacity(0.85) : Theme.subtext)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            .padding(.vertical, subtitle == nil ? 0 : 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? tint : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.clear : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 重复规则编辑器

/// 主题风格的重复规则编辑器，下方实时显示「共 N 次 · 首次 · 最后」。
struct RepeatRuleEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: RuleDraft
    let start: LocalDate
    let end: LocalDate
    let validStart: String
    let validEnd: String
    var tint: Color = Theme.accent
    @State private var addDate = LocalDate.today()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorSection("重复方式") {
                modeGrid.padding(10)
            }
            if draft.mode == .custom {
                customSection
            }
            InspectorSection("每次与习惯") {
                if !draft.mode.isPeriod {
                    ThemedRow("每次持续", field: "duration") {
                        Stepper(value: $draft.duration, in: 1...366) {
                            Text(verbatim: "\(draft.duration) 天")
                        }
                        .fixedSize()
                    }
                }
                ThemedRow("标记为习惯", field: "isLoop = 2") { ThemedSwitch(isOn: $draft.habit) }
            }
            previewSection
        }
        .onAppear { addDate = start }
    }

    // MARK: 方式

    private var modeGrid: some View {
        let modes = LoopSet.editorModes
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { column in
                        let mode = modes[row * 4 + column]
                        RuleChip(title: mode.title, subtitle: mode.hint, on: draft.mode == mode, tint: tint, height: 38) {
                            draft.mode = mode
                        }
                    }
                }
            }
        }
    }

    // MARK: 自定义

    private var customSection: some View {
        InspectorSection("自定义规则") {
            ThemedRow("单位", field: "loopUnit") {
                ThemedSegmented(selection: $draft.unit,
                                options: LoopUnitKind.allCases.map { ThemeOption(value: $0, title: $0.title) })
            }
            ThemedRow("间隔", field: "loopBaseNumber") {
                Stepper(value: $draft.interval, in: 1...366) {
                    Text(verbatim: draft.interval == 1 ? "每\(draft.unit.title)" : "每 \(draft.interval) \(draft.unit.title)")
                }
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                datePicker
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
            }
            ThemedRow("日期筛选", field: "loopUnit ÷ 100") {
                ThemedSegmented(selection: $draft.filter,
                                options: DayFilter.allCases.map { ThemeOption(value: $0, title: $0.shortTitle) })
            }
        }
    }

    @ViewBuilder
    private var datePicker: some View {
        switch draft.unit {
        case .day:
            Text("按天重复不需要选择日期，由间隔决定。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
        case .week:
            label("选择星期", field: "loopDate")
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { index in
                    let weekday = floorMod(index + model.weekStart, 7)
                    RuleChip(title: LocalDate.weekdayNames[weekday], on: draft.weekdays.contains(weekday), tint: tint) {
                        draft.weekdays.formSymmetricDifference([weekday])
                    }
                }
            }
        case .month:
            label("选择日号", field: "loopDate")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(1...32, id: \.self) { day in
                    RuleChip(title: day == 32 ? "月末" : "\(day)", on: draft.monthDays.contains(day), tint: tint, height: 26) {
                        draft.monthDays.formSymmetricDifference([day])
                    }
                }
            }
            Text("31 号在小月会顺延到下月 1 号（与鸿蒙端一致），要每月最后一天请选「月末」。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        case .lunarMonth:
            label("选择农历日", field: "loopDate")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(1...30, id: \.self) { day in
                    RuleChip(title: LunarCalendar.dayName(day), on: draft.lunarMonthDays.contains(day), tint: tint, height: 26) {
                        draft.lunarMonthDays.formSymmetricDifference([day])
                    }
                }
            }
        case .year, .lunarYear:
            label(draft.unit == .year ? "每年的日期" : "每年的农历日期", field: "loopDate")
            yearDates
        }
    }

    private func label(_ text: String, field: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0x4A453C))
            if model.showFieldNames { FieldTag(field) }
        }
    }

    private var yearList: Binding<[String]> {
        draft.unit == .year ? $draft.yearDates : $draft.lunarYearDates
    }

    private func yearTitle(_ code: String) -> String {
        let parts = code.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return code }
        if draft.unit == .year { return "\(parts[0])月\(parts[1])日" }
        return LunarCalendar.monthName(parts[0]) + LunarCalendar.dayName(parts[1])
    }

    private var yearDates: some View {
        VStack(alignment: .leading, spacing: 8) {
            if yearList.wrappedValue.isEmpty {
                Text("还没有选择日期")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(yearList.wrappedValue, id: \.self) { code in
                        HStack(spacing: 4) {
                            Text(verbatim: yearTitle(code))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Button {
                                yearList.wrappedValue.removeAll { $0 == code }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tint))
                    }
                }
            }
            HStack(spacing: 6) {
                ThemedDateField(date: $addDate, tint: tint)
                Button("添加") { addYearDate() }
                    .buttonStyle(.themed)
                if draft.unit == .lunarYear, let lunar = LunarCalendar.lunarDay(for: addDate) {
                    Text(verbatim: "农历 " + LunarCalendar.monthName(lunar.month, leap: lunar.isLeap) + LunarCalendar.dayName(lunar.day))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                }
            }
        }
    }

    private func addYearDate() {
        let code: String
        if draft.unit == .year {
            code = String(format: "%02d-%02d", addDate.month, addDate.day)
        } else {
            guard let lunar = LunarCalendar.lunarDay(for: addDate) else { return }
            code = String(format: "%02d-%02d", lunar.month, lunar.day)
        }
        guard !yearList.wrappedValue.contains(code) else { return }
        yearList.wrappedValue = (yearList.wrappedValue + [code]).sorted()
    }

    // MARK: 预览

    private var preview: Result<[OccurrenceWindow], Error> {
        Result(catching: {
            let encoded = try draft.rule.encode()
            let input = RecurrenceInput(start: start, end: end, validStartTime: validStart, validEndTime: validEnd,
                                        rule: encoded)
            return try Recurrence.windows(input, weekStart: model.weekStart, chinaMakeup: model.chinaMakeup)
        })
    }

    private func chipTitle(_ day: LocalDate) -> String {
        "\(day.month)/\(day.day) " + LocalDate.weekdayNames[day.weekday]
    }

    private var previewSection: some View {
        let result = preview
        let today = model.today
        return InspectorSection("预览") {
            VStack(alignment: .leading, spacing: 8) {
                switch result {
                case .success(let windows):
                    HStack(spacing: 6) {
                        Image(systemName: "repeat")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tint)
                        Text(verbatim: "共 \(windows.count) 次")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Theme.text)
                        if let first = windows.first, let last = windows.last {
                            Text(verbatim: "首次 " + DateText.title(first.start, today: today)
                                 + " · 最后 " + DateText.title(last.start, today: today))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.subtext)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        ForEach(Array(windows.prefix(5).enumerated()), id: \.offset) { _, window in
                            Text(verbatim: chipTitle(window.start))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(tint.opacity(0.14)))
                        }
                        if windows.count > 5 {
                            Text("…").foregroundStyle(Theme.subtext)
                        }
                    }
                case .failure(let error):
                    ThemedErrorText(message: error.localizedDescription)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 编辑重复规则 / 设为重复（弹窗）

struct RecurrenceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskDef

    @State private var draft: RuleDraft
    @State private var seriesStart: LocalDate
    @State private var seriesEnd: LocalDate
    @State private var hasTime: Bool
    @State private var startClock: LocalTime
    @State private var endClock: LocalTime
    @State private var fromDate: LocalDate
    @State private var plan: RecurrencePlan?
    @State private var loadingPlan = false
    @State private var saving = false

    private struct PreviewKey: Hashable {
        var draft: RuleDraft
        var start: LocalDate
        var end: LocalDate
        var from: LocalDate
        var hasTime: Bool
        var startClock: LocalTime
        var endClock: LocalTime
    }

    private static let endOfDay = LocalTime(hour: 23, minute: 59)!

    init(task: TaskDef) {
        self.task = task
        let today = LocalDate.today()
        let start = (task.undated ? nil : task.startDate) ?? today
        var end = (task.undated ? nil : task.endDate) ?? start
        if !task.isRepeating && end <= start { end = start.adding(months: 1) }
        let startTime = task.startClock ?? .startOfDay
        let endTime = task.endClock ?? Self.endOfDay
        _draft = State(initialValue: RuleDraft(task: task, fallbackStart: start))
        _seriesStart = State(initialValue: start)
        _seriesEnd = State(initialValue: end)
        _hasTime = State(initialValue: !(startTime.hour == 0 && startTime.minute == 0
                                         && endTime.hour == 23 && endTime.minute == 59))
        _startClock = State(initialValue: startTime)
        _endClock = State(initialValue: endTime)
        _fromDate = State(initialValue: today)
    }

    private var validStart: String { hasTime ? BiandanService.clockText(startClock) : "00:00:00" }
    private var validEnd: String { hasTime ? BiandanService.clockText(endClock) : "23:59:00" }

    private var localError: String? {
        do {
            let encoded = try draft.rule.encode()
            let input = RecurrenceInput(start: seriesStart, end: seriesEnd, validStartTime: validStart,
                                        validEndTime: validEnd, rule: encoded)
            _ = try Recurrence.windows(input, weekStart: model.weekStart, chinaMakeup: model.chinaMakeup)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var key: PreviewKey {
        PreviewKey(draft: draft, start: seriesStart, end: seriesEnd, from: fromDate, hasTime: hasTime,
                   startClock: startClock, endClock: endClock)
    }

    var body: some View {
        let quadrant = task.quadrant
        let tint = quadrant.tint
        ThemedSheet(task.isRepeating ? "编辑重复规则" : "设为重复任务",
                    subtitle: task.taskTitle.isEmpty ? "（无标题）" : task.taskTitle,
                    tag: ThemeTag(text: quadrant.title, color: tint),
                    headerFill: quadrant.fill, titleColor: quadrant.titleColor) {
            InspectorSection("系列时间") {
                ThemedRow("开始", field: "startTime") { ThemedDateField(date: $seriesStart, tint: tint) }
                ThemedRow("截止", field: "endTime") { ThemedDateField(date: $seriesEnd, minimum: seriesStart, tint: tint) }
                ThemedRow("指定时刻") { ThemedSwitch(isOn: $hasTime) }
                if hasTime {
                    ThemedRow("开始时刻", field: "validStartTime") { ThemedTimeField(time: $startClock, tint: tint) }
                    ThemedRow("结束时刻", field: "validEndTime") { ThemedTimeField(time: $endClock, tint: tint) }
                }
                ThemedRow("从哪天起生效") { ThemedDateField(date: $fromDate, tint: tint) }
            }

            RepeatRuleEditor(draft: $draft, start: seriesStart, end: seriesEnd,
                             validStart: validStart, validEnd: validEnd, tint: tint)

            InspectorSection("对已有实例的影响") {
                impactView
            }

            ThemedErrorText(message: model.operationError)
        } footer: {
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("保存规则") { save() }
                .buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || localError != nil)
        }
        .frame(width: 560, height: 720)
        .onAppear { model.operationError = nil }
        .onChange(of: seriesStart) { _, newValue in
            if seriesEnd < newValue { seriesEnd = newValue }
        }
        .task(id: key) { await refreshPlan() }
    }

    @ViewBuilder
    private var impactView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loadingPlan {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在计算影响…").font(.system(size: 12)).foregroundStyle(Theme.subtext)
                }
            } else if let plan {
                HStack(spacing: 0) {
                    impactCell("新增", plan.created, Theme.done)
                    impactCell("改期", plan.rescheduled, Color(hex: 0xD9A800))
                    impactCell("移除", plan.removed, Theme.overdue)
                    impactCell("保留", plan.protectedDates, Theme.subtext)
                }
                Text(verbatim: "\(plan.fromDate.iso) 之前的实例，以及已完成、有进度或已放弃的实例都保持不变。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(localError == nil ? "暂时无法计算影响" : "规则有误，修正后会显示影响")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func impactCell(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(value)")
                .font(.system(size: 18, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? Theme.fieldName : color)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity)
    }

    private func refreshPlan() async {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        guard localError == nil else {
            plan = nil
            return
        }
        loadingPlan = true
        let result = await model.previewRecurrence(task.id1, rule: draft.rule, fromDate: fromDate,
                                                   start: seriesStart, end: seriesEnd,
                                                   startTime: hasTime ? startClock : .startOfDay,
                                                   endTime: hasTime ? endClock : Self.endOfDay, habit: draft.habit)
        guard !Task.isCancelled else { return }
        plan = result
        loadingPlan = false
    }

    private func save() {
        saving = true
        let rule = draft.rule
        let habit = draft.habit
        Task {
            let result = await model.updateRecurrence(task.id1, rule: rule, fromDate: fromDate,
                                                      start: seriesStart, end: seriesEnd,
                                                      startTime: hasTime ? startClock : .startOfDay,
                                                      endTime: hasTime ? endClock : Self.endOfDay, habit: habit)
            saving = false
            if result != nil { dismiss() }
        }
    }
}
