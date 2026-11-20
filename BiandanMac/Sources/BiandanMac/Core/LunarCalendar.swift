import Foundation

/// 农历数据与换算，年份位表与原生 chineseCalendar.ets / Python LUNAR_YEARS 相同（1900–2100）。
enum LunarCalendar {
    struct Month: Hashable, Sendable {
        let year: Int
        let month: Int
        let isLeap: Bool
        let first: LocalDate
        let days: Int
    }

    struct LunarDay: Hashable, Sendable {
        let year: Int
        let month: Int
        let day: Int
        let isLeap: Bool
    }

    /// 所有农历月，按时间顺序。闰月与正常月使用同一月号（与 Python lunar_months 一致）。
    static let months: [Month] = {
        var result: [Month] = []
        var first = LocalDate(year: 1900, month: 1, day: 31)!
        for (offset, bits) in yearBits.enumerated() {
            let year = 1900 + offset
            let leap = bits & 15
            for month in 1...12 {
                let days = 29 + ((bits & (0x10000 >> month)) != 0 ? 1 : 0)
                result.append(Month(year: year, month: month, isLeap: false, first: first, days: days))
                first = first.adding(days: days)
                if month == leap {
                    let leapDays = 29 + ((bits & 0x10000) != 0 ? 1 : 0)
                    result.append(Month(year: year, month: month, isLeap: true, first: first, days: leapDays))
                    first = first.adding(days: leapDays)
                }
            }
        }
        return result
    }()

    /// 最后一个 first <= date 的农历月下标。
    private static func monthIndex(containing date: LocalDate) -> Int? {
        var low = 0, high = months.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if months[mid].first <= date {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    static func lunarDay(for date: LocalDate) -> LunarDay? {
        guard let index = monthIndex(containing: date) else { return nil }
        let month = months[index]
        let day = month.first.days(to: date) + 1
        guard day <= month.days else { return nil }
        return LunarDay(year: month.year, month: month.month, day: day, isLeap: month.isLeap)
    }

    /// 农历月和农历年的重复日期（对应 Python lunar_dates）。
    static func recurrenceDates(start: LocalDate, end: LocalDate, unit: LoopUnitKind, interval: Int,
                                selected: Set<String>) throws -> [LocalDate] {
        guard let anchorIndex = monthIndex(containing: start) else {
            throw RecurrenceError("日期超出农历数据范围。")
        }
        let anchorYear = months[anchorIndex].year
        let anchor = anchorYear * 12 + months[anchorIndex].month
        var monthDays: [Int] = []
        if unit == .lunarMonth {
            for value in selected {
                guard let day = Int(value) else { throw RecurrenceError("无效的农历日号 \(value)。") }
                monthDays.append(day)
            }
        }
        var out: [LocalDate] = []
        for entry in months {
            if entry.first > end { break }
            let offset = entry.year * 12 + entry.month - anchor
            if offset < 0 { continue }
            if unit == .lunarMonth && offset % interval == 0 {
                for day in monthDays where day <= entry.days {
                    out.append(entry.first.adding(days: day - 1))
                }
            }
            if unit == .lunarYear && (entry.year - anchorYear) % interval == 0 {
                for day in 1...entry.days where selected.contains(String(format: "%02d-%02d", entry.month, day)) {
                    out.append(entry.first.adding(days: day - 1))
                }
            }
        }
        return out
    }

    // MARK: 显示

    static let stems = Array("甲乙丙丁戊己庚辛壬癸").map(String.init)
    static let branches = Array("子丑寅卯辰巳午未申酉戌亥").map(String.init)
    static let monthNames = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]

    static func ganzhi(year: Int) -> String {
        stems[floorMod(year - 4, 10)] + branches[floorMod(year - 4, 12)]
    }

    static func monthName(_ month: Int, leap: Bool = false) -> String {
        (leap ? "闰" : "") + ((1...12).contains(month) ? monthNames[month - 1] : "?") + "月"
    }

    static func dayName(_ day: Int) -> String {
        let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        switch day {
        case 1...10: return day == 10 ? "初十" : "初" + digits[day]
        case 11...19: return "十" + digits[day - 10]
        case 20: return "二十"
        case 21...29: return "廿" + digits[day - 20]
        case 30: return "三十"
        default: return "\(day)"
        }
    }

    /// 例如「丙午十月十二」，与截图里日期后的农历一致。
    static func headerText(for date: LocalDate) -> String {
        guard let lunar = lunarDay(for: date) else { return "" }
        return ganzhi(year: lunar.year) + monthName(lunar.month, leap: lunar.isLeap) + dayName(lunar.day)
    }

    // MARK: 数据：commons/utils/src/main/ets/utils/chineseCalendar.ets

    static let yearBits: [Int] = [
        0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
        0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
        0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
        0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
        0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
        0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,
        0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
        0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,
        0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
        0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x05ac0, 0x0ab60, 0x096d5, 0x092e0,
        0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
        0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
        0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,
        0x05aa0, 0x076a3, 0x096d0, 0x04afb, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
        0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,
        0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0,
        0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,
        0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,
        0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,
        0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,
        0x0d520,
    ]
}

/// 中国法定节假日调休。集合里的日期会翻转「是否休息日」：工作日放假、周末补班。
/// - 内置 2024–2027 年（2024–2026 来自 holidayChecker.ets；2027 依据国办发明电〔2026〕10号）。
/// - 之后的年份由 `HolidayUpdater` 远程补充；只计入紧接内置末年、逐年连续的年份。
enum ChinaMakeup {
    static let firstYear = 2024
    static let builtinLastYear = 2027

    static var coverageStart: LocalDate { LocalDate(year: firstYear, month: 1, day: 1)! }
    static var coverageEnd: LocalDate { LocalDate(year: lastYear, month: 12, day: 31)! }
    /// 当前覆盖到的最后一年（内置 + 远程补充）。
    static var lastYear: Int { store.snapshot().lastYear }
    static var days: Set<LocalDate> { store.snapshot().days }

    /// 安装远程年份数据，返回新的覆盖末年。
    @discardableResult
    static func install(_ years: [Int: Set<LocalDate>]) -> Int { store.update(years) }

    /// 清除远程补充的年份（测试用）。
    static func resetRemote() { store.reset() }

    /// 由官方放假安排换算翻转日：放假且是工作日，或上班且是周末。
    static func flipDays(year: Int, entries: [(date: LocalDate, isOffDay: Bool)]) -> Set<LocalDate> {
        Set(entries.filter { entry in
            entry.date.year == year && (entry.isOffDay ? entry.date.pythonWeekday < 5 : entry.date.pythonWeekday >= 5)
        }.map(\.date))
    }

    static let builtinDays: Set<LocalDate> = Set(raw.compactMap { LocalDate(year: $0.0, month: $0.1, day: $0.2) })
    private static let store = MakeupStore(builtin: builtinDays, lastYear: builtinLastYear)

    private static let raw: [(Int, Int, Int)] = [
        (2024, 1, 1), (2024, 2, 4), (2024, 2, 12), (2024, 2, 13), (2024, 2, 14),
        (2024, 2, 15), (2024, 2, 16), (2024, 2, 18), (2024, 4, 4), (2024, 4, 5),
        (2024, 4, 7), (2024, 4, 28), (2024, 5, 1), (2024, 5, 2), (2024, 5, 3),
        (2024, 5, 11), (2024, 6, 10), (2024, 9, 14), (2024, 9, 16), (2024, 9, 17),
        (2024, 9, 29), (2024, 10, 1), (2024, 10, 2), (2024, 10, 3), (2024, 10, 4),
        (2024, 10, 7), (2024, 10, 12), (2025, 1, 1), (2025, 1, 26), (2025, 1, 28),
        (2025, 1, 29), (2025, 1, 30), (2025, 1, 31), (2025, 2, 3), (2025, 2, 4),
        (2025, 2, 8), (2025, 4, 4), (2025, 4, 27), (2025, 5, 1), (2025, 5, 2),
        (2025, 5, 5), (2025, 6, 2), (2025, 9, 28), (2025, 10, 1), (2025, 10, 2),
        (2025, 10, 3), (2025, 10, 6), (2025, 10, 7), (2025, 10, 8), (2025, 10, 11),
        (2026, 1, 1), (2026, 1, 2), (2026, 1, 4), (2026, 2, 14), (2026, 2, 16),
        (2026, 2, 17), (2026, 2, 18), (2026, 2, 19), (2026, 2, 20), (2026, 2, 23),
        (2026, 2, 28), (2026, 4, 6), (2026, 5, 1), (2026, 5, 4), (2026, 5, 5),
        (2026, 5, 9), (2026, 6, 19), (2026, 9, 20), (2026, 9, 25), (2026, 10, 1),
        (2026, 10, 2), (2026, 10, 5), (2026, 10, 6), (2026, 10, 7), (2026, 10, 10),
        // 2027：国办发明电〔2026〕10号
        (2027, 1, 1), (2027, 1, 31), (2027, 2, 5), (2027, 2, 8), (2027, 2, 9),
        (2027, 2, 10), (2027, 2, 11), (2027, 2, 12), (2027, 2, 14), (2027, 4, 5),
        (2027, 5, 3), (2027, 5, 4), (2027, 5, 5), (2027, 5, 8), (2027, 6, 9),
        (2027, 9, 15), (2027, 9, 26), (2027, 10, 1), (2027, 10, 4), (2027, 10, 5),
        (2027, 10, 6), (2027, 10, 7), (2027, 10, 9),
    ]
}

/// 调休数据的线程安全存储：内置数据 + 远程补充年份。
private final class MakeupStore: @unchecked Sendable {
    struct Snapshot {
        var days: Set<LocalDate>
        var lastYear: Int
    }

    private let lock = NSLock()
    private let builtin: Set<LocalDate>
    private let builtinLastYear: Int
    private var remote: [Int: Set<LocalDate>] = [:]
    private var current: Snapshot

    init(builtin: Set<LocalDate>, lastYear: Int) {
        self.builtin = builtin
        builtinLastYear = lastYear
        current = Snapshot(days: builtin, lastYear: lastYear)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func update(_ years: [Int: Set<LocalDate>]) -> Int {
        lock.lock(); defer { lock.unlock() }
        for (year, days) in years where year > builtinLastYear {
            remote[year] = days.filter { $0.year == year }
        }
        rebuild()
        return current.lastYear
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        remote = [:]
        rebuild()
    }

    private func rebuild() {
        var days = builtin
        var last = builtinLastYear
        while let next = remote[last + 1] {
            days.formUnion(next)
            last += 1
        }
        current = Snapshot(days: days, lastYear: last)
    }
}
