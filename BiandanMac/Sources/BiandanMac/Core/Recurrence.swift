import Foundation

struct RecurrenceError: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 规则编码（对应 Python encode_rule）

/// 用户编辑的重复规则。非自定义模式下 unit / interval / dates / dayFilter 必须为 nil。
struct RepeatRule: Hashable, Sendable {
    var mode: LoopSet
    var unit: LoopUnitKind?
    var interval: Int?
    var dates: [String]?
    var dayFilter: DayFilter?
    var durationDays: Int?

    static let maxOccurrences = 1000

    init(mode: LoopSet, unit: LoopUnitKind? = nil, interval: Int? = nil, dates: [String]? = nil,
         dayFilter: DayFilter? = nil, durationDays: Int? = nil) {
        self.mode = mode
        self.unit = unit
        self.interval = interval
        self.dates = dates
        self.dayFilter = dayFilter
        self.durationDays = durationDays
    }

    struct Encoded: Hashable, Sendable {
        var loopSet: Int
        var loopUnit: Int
        var loopBaseNumber: Int
        var loopDate: String
        var duration: Int

        var attributes: JSONObject {
            ["loopSet": .int(Int64(loopSet)), "loopUnit": .int(Int64(loopUnit)),
             "loopBaseNumber": .int(Int64(loopBaseNumber)), "loopDate": .string(loopDate),
             "duration": .int(Int64(duration))]
        }
    }

    func encode() throws -> Encoded {
        guard mode != .none else { throw RecurrenceError("不支持的重复模式。") }
        let span = durationDays ?? 1
        if mode != .custom && (unit != nil || interval != nil || dates != nil || dayFilter != nil) {
            throw RecurrenceError("单位、间隔、日期和日期筛选只适用于自定义重复。")
        }
        let unit = self.unit ?? .day
        let interval = self.interval ?? 1
        let selector = dayFilter ?? .all
        let selected = Set(dates ?? [])
        guard (1...366).contains(interval), (1...366).contains(span) else {
            throw RecurrenceError("重复间隔或持续天数无效（1–366）。")
        }
        if (unit != .day) != !selected.isEmpty {
            throw RecurrenceError("按周、月、年的自定义重复必须选择日期；按天不能选日期。")
        }
        switch unit {
        case .year, .lunarYear:
            for value in selected {
                guard value.range(of: "\\A[0-9]{2}-[0-9]{2}\\z", options: .regularExpression) != nil else {
                    throw RecurrenceError("按年的日期使用 MM-DD。")
                }
                let parts = value.split(separator: "-").compactMap { Int($0) }
                let month = parts[0], day = parts[1]
                if unit == .year {
                    guard LocalDate(year: 2000, month: month, day: day) != nil else {
                        throw RecurrenceError("无效的公历日期 \(value)。")
                    }
                } else if !((1...12).contains(month) && (1...30).contains(day)) {
                    throw RecurrenceError("无效的农历月或日 \(value)。")
                }
            }
        case .week, .month, .lunarMonth:
            let bounds: ClosedRange<Int> = unit == .week ? 0...6 : (unit == .month ? 1...32 : 1...30)
            let allowed = Set(bounds.map(String.init))
            guard selected.isSubset(of: allowed) else {
                throw RecurrenceError("所选日期超出该重复单位的范围。")
            }
        case .day:
            break
        }
        // Python ','.join(sorted(dates)) 是字符串字典序，这里保持一致。
        return Encoded(loopSet: mode.rawValue, loopUnit: unit.rawValue + selector.rawValue * 100,
                       loopBaseNumber: interval, loopDate: selected.sorted().joined(separator: ","),
                       duration: span)
    }

    /// 从任务读回规则（对应 Python view_rule）。不循环时返回 nil；未知编码的字段为 nil。
    init?(task: TaskDef) {
        guard task.loopSet != 0 else { return nil }
        let mode = LoopSet(rawValue: task.loopSet) ?? .custom
        self.mode = mode
        durationDays = task.duration == 0 ? 1 : task.duration
        if mode == .custom {
            let codec = task.unit
            unit = codec.unit
            dayFilter = codec.filter
            interval = task.loopBaseNumber == 0 ? 1 : task.loopBaseNumber
            dates = task.loopDates
        } else {
            unit = nil
            dayFilter = nil
            interval = nil
            dates = nil
        }
    }
}

// MARK: - 实例窗口（对应 Python recurrence_windows）

/// 展开实例所需的 Task 字段。
struct RecurrenceInput: Hashable, Sendable {
    var startTime: String
    var endTime: String
    var validStartTime: String
    var validEndTime: String
    var loopSet: Int
    var loopUnit: Int
    var loopBaseNumber: Int
    var loopDate: String
    var duration: Int

    init(task: TaskDef) {
        startTime = task.startTime ?? ""
        endTime = task.endTime ?? ""
        validStartTime = task.validStartTime
        validEndTime = task.validEndTime
        loopSet = task.loopSet
        loopUnit = task.loopUnit
        loopBaseNumber = task.loopBaseNumber
        loopDate = task.loopDate
        duration = task.duration
    }

    init(start: LocalDate, end: LocalDate, validStartTime: String, validEndTime: String, rule: RepeatRule.Encoded) {
        startTime = start.iso
        endTime = end.iso
        self.validStartTime = validStartTime
        self.validEndTime = validEndTime
        loopSet = rule.loopSet
        loopUnit = rule.loopUnit
        loopBaseNumber = rule.loopBaseNumber
        loopDate = rule.loopDate
        duration = rule.duration
    }
}

struct OccurrenceWindow: Hashable, Sendable {
    var start: LocalDate
    var end: LocalDate
    var validStartTime: String
    var validEndTime: String

    var attributes: JSONObject {
        ["startTime": .string(start.iso), "endTime": .string(end.iso),
         "validStartTime": .string(validStartTime), "validEndTime": .string(validEndTime)]
    }
}

enum Recurrence {
    static func windows(_ row: RecurrenceInput, weekStart: Int = 0, chinaMakeup: Bool = false,
                        fromDate: LocalDate? = nil, allowEmpty: Bool = false) throws -> [OccurrenceWindow] {
        guard let start = LocalDate(iso: row.startTime), let end = LocalDate(iso: row.endTime),
              LocalDate.minSupported <= start, start <= end, end <= LocalDate.maxSupported else {
            throw RecurrenceError("重复日期必须在 1900-01-31 至 2100-12-31 之间。")
        }
        guard row.loopSet != 0 else { throw RecurrenceError("该任务不是重复任务。") }
        let mode = LoopSet(rawValue: row.loopSet)   // nil = 未知模式，按 Python 落到按天展开
        let isCustom = mode == .custom
        let codec = LoopUnit(raw: row.loopUnit)
        let unit: LoopUnitKind? = isCustom ? codec.unit : nil
        let interval = isCustom ? (row.loopBaseNumber == 0 ? 1 : row.loopBaseNumber) : 1
        let selected: Set<String> = isCustom ? Set(row.loopDate.split(separator: ",").map(String.init).filter { !$0.isEmpty }) : []
        let selector: DayFilter? = mode == .workdays ? .workdays : mode == .daysOff ? .daysOff : (isCustom ? codec.filter : .all)
        let durationDays = row.duration == 0 ? 1 : row.duration

        if chinaMakeup && selector != .all && !(ChinaMakeup.coverageStart <= start && end <= ChinaMakeup.coverageEnd) {
            throw RecurrenceError("内置中国调休数据只覆盖 \(ChinaMakeup.coverageStart.year)–\(ChinaMakeup.coverageEnd.year) 年，其他日期请按普通周末计算。")
        }
        guard interval >= 1 else { throw RecurrenceError("该规则在此日期范围内不会产生任何实例。") }

        let period = mode?.isPeriod ?? false
        var dates = Set<LocalDate>()
        for day in try candidates(start: start, end: end, mode: mode, unit: unit, interval: interval,
                                  selected: selected, weekStart: weekStart) {
            if day > end || (!period && day < start) { continue }
            if let fromDate, day < fromDate { continue }
            var holiday = day.pythonWeekday >= 5
            if chinaMakeup && ChinaMakeup.days.contains(day) { holiday.toggle() }
            if (selector == .daysOff && !holiday) || (selector == .workdays && holiday) { continue }
            dates.insert(day)
            if dates.count > RepeatRule.maxOccurrences {
                throw RecurrenceError("一次操作最多生成 \(RepeatRule.maxOccurrences) 条实例，请缩短日期范围。")
            }
        }
        if dates.isEmpty && !allowEmpty {
            throw RecurrenceError("该规则在此日期范围内不会产生任何实例。")
        }

        var result: [OccurrenceWindow] = []
        for day in dates.sorted() {
            let last: LocalDate
            switch mode {
            case .weeklyPeriod?: last = day.adding(days: 6)
            case .monthlyPeriod?: last = day.lastOfMonth
            case .yearlyPeriod?: last = LocalDate(year: day.year, month: 12, day: 31)!
            default: last = day.adding(days: durationDays - 1)
            }
            if last > LocalDate.maxSupported {
                throw RecurrenceError("有实例会结束在 2100-12-31 之后。")
            }
            if (day, row.validStartTime) > (last, row.validEndTime) {
                throw RecurrenceError("至少有一个实例的结束早于开始。")
            }
            result.append(OccurrenceWindow(start: day, end: last,
                                           validStartTime: row.validStartTime, validEndTime: row.validEndTime))
        }
        return result
    }

    /// 候选日期（对应 Python generate_dates），保留 JS `setDate` 溢出等原生行为。
    static func candidates(start: LocalDate, end: LocalDate, mode: LoopSet?, unit: LoopUnitKind?,
                           interval: Int, selected: Set<String>, weekStart: Int) throws -> [LocalDate] {
        var out: [LocalDate] = []
        let total = start.days(to: end)
        if mode == .ebbinghaus {
            var offsets = [0, 1, 2, 4, 6, 14]
            if total >= 29 { offsets += Array(stride(from: 29, through: total, by: 15)) }
            for offset in offsets where offset <= total {
                out.append(start.adding(days: offset))
            }
        } else if mode == .weeklyPeriod || unit == .week {
            let sunday = start.weekday
            // 注意：自定义按周时 Python 没有取模，偏移可能为 -1。
            let offset = mode == .weeklyPeriod ? floorMod(sunday - weekStart, 7) : sunday - weekStart
            let first = start.adding(days: -offset)
            let span = first.days(to: end)
            if span >= 0 {
                for delta in stride(from: 0, through: span, by: 7 * interval) {
                    let week = first.adding(days: delta)
                    if mode == .weeklyPeriod {
                        out.append(week)
                    } else {
                        for day in 0..<7 where selected.contains(String(floorMod(day + weekStart, 7))) {
                            out.append(week.adding(days: day))
                        }
                    }
                }
            }
        } else if mode == .monthlyPeriod || unit == .month {
            let firstIndex = start.year * 12 + start.month - 1
            let lastIndex = end.year * 12 + end.month - 1
            for index in stride(from: firstIndex, through: lastIndex, by: interval) {
                let first = LocalDate(year: floorDiv(index, 12), month: floorMod(index, 12) + 1, day: 1)!
                if mode == .monthlyPeriod {
                    out.append(first)
                } else {
                    for value in selected {
                        guard let day = Int(value) else { throw RecurrenceError("无效的日号 \(value)。") }
                        let actual = day == 32 ? LocalDate.daysIn(year: first.year, month: first.month) : day
                        // 超出当月天数时顺延到下月，与 JS Date.setDate 一致。
                        out.append(first.adding(days: actual - 1))
                    }
                }
            }
        } else if mode == .yearlyPeriod || unit == .year {
            for year in stride(from: start.year, through: end.year, by: interval) {
                if mode == .yearlyPeriod {
                    out.append(LocalDate(year: year, month: 1, day: 1)!)
                } else {
                    for value in selected {
                        let parts = value.split(separator: "-").compactMap { Int($0) }
                        guard parts.count == 2, (1...12).contains(parts[0]) else {
                            throw RecurrenceError("无效的年度日期 \(value)。")
                        }
                        if let date = LocalDate(year: year, month: parts[0], day: parts[1]) {
                            out.append(date)
                        }
                    }
                }
            }
        } else if unit == .lunarMonth || unit == .lunarYear {
            out = try LunarCalendar.recurrenceDates(start: start, end: end, unit: unit!, interval: interval, selected: selected)
        } else {
            if total >= 0 {
                for offset in stride(from: 0, through: total, by: interval) {
                    out.append(start.adding(days: offset))
                }
            }
        }
        return out
    }
}

// MARK: - 规则的中文摘要（列表与卡片显示用）

enum RuleSummary {
    static func describe(_ task: TaskDef) -> String {
        guard let rule = RepeatRule(task: task) else { return "不重复" }
        var text: String
        if rule.mode == .custom {
            let interval = rule.interval ?? 1
            let unit = rule.unit
            let every = "每" + (interval == 1 ? "" : "\(interval)") + (unit?.title ?? "?")
            let picked = (rule.dates ?? []).sorted { (Int($0) ?? 0, $0) < (Int($1) ?? 0, $1) }
            switch unit {
            case .week?:
                text = every + " " + picked.compactMap { Int($0) }.map { LocalDate.weekdayShortNames[floorMod($0, 7)] }.joined(separator: "、")
            case .month?:
                text = every + " " + picked.map { $0 == "32" ? "月末" : "\($0)日" }.joined(separator: "、")
            case .lunarMonth?:
                text = every + " " + picked.compactMap { Int($0) }.map { LunarCalendar.dayName($0) }.joined(separator: "、")
            case .year?, .lunarYear?:
                text = every + " " + picked.joined(separator: "、")
            default:
                text = every
            }
            if let filter = rule.dayFilter, filter != .all { text += "（\(filter.title)）" }
        } else {
            text = rule.mode.title
        }
        if let days = rule.durationDays, days > 1, !rule.mode.isPeriod { text += " · 持续\(days)天" }
        return text
    }
}
