import Foundation

/// 与 Python `%` 一致的向下取模。
func floorMod(_ value: Int, _ divisor: Int) -> Int {
    let remainder = value % divisor
    return remainder < 0 ? remainder + divisor : remainder
}

/// 与 Python `//` 一致的向下取整除法。
func floorDiv(_ value: Int, _ divisor: Int) -> Int {
    (value - floorMod(value, divisor)) / divisor
}

/// 不带时区的本地日历日期，对应云端 `YYYY-MM-DD`。
/// 日期运算基于天数序号，不依赖 Calendar 和时区。
struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    static let weekdayShortNames = ["日", "一", "二", "三", "四", "五", "六"]
    static let minSupported = LocalDate(unchecked: 1900, 1, 31)
    static let maxSupported = LocalDate(unchecked: 2100, 12, 31)
    static let undatedStart = LocalDate(unchecked: 1970, 1, 1)

    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= LocalDate.daysIn(year: year, month: month) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    fileprivate init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// 只接受严格的 `YYYY-MM-DD`。
    init?(iso: String?) {
        guard let iso, iso.count == 10 else { return nil }
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    init(daysSinceEpoch: Int) {
        // Howard Hinnant, civil_from_days
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(unchecked: y + (m <= 2 ? 1 : 0), m, d)
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 0
        }
    }

    static func today(_ date: Date = Date(), calendar: Calendar = .current) -> LocalDate {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(unchecked: parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    var daysSinceEpoch: Int {
        // Howard Hinnant, days_from_civil
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    func adding(days: Int) -> LocalDate {
        LocalDate(daysSinceEpoch: daysSinceEpoch + days)
    }

    func adding(months: Int) -> LocalDate {
        let index = year * 12 + (month - 1) + months
        let newYear = floorDiv(index, 12)
        let newMonth = floorMod(index, 12) + 1
        let newDay = min(day, LocalDate.daysIn(year: newYear, month: newMonth))
        return LocalDate(unchecked: newYear, newMonth, newDay)
    }

    func days(to other: LocalDate) -> Int {
        other.daysSinceEpoch - daysSinceEpoch
    }

    /// 0 = 周日 … 6 = 周六（1970-01-01 是周四）。
    var weekday: Int {
        floorMod(daysSinceEpoch + 4, 7)
    }

    /// Python `date.weekday()`：0 = 周一 … 6 = 周日。
    var pythonWeekday: Int {
        floorMod(weekday + 6, 7)
    }

    var firstOfMonth: LocalDate { LocalDate(unchecked: year, month, 1) }

    var lastOfMonth: LocalDate { LocalDate(unchecked: year, month, LocalDate.daysIn(year: year, month: month)) }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    var description: String { iso }

    /// 例如「11月20日 周五」。
    var shortTitle: String { "\(month)月\(day)日 \(LocalDate.weekdayNames[weekday])" }

    /// 转成当前时区该日 00:00 的 Date，供 DatePicker 使用。
    func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// 本地时刻，对应云端 `HH:mm:ss`。
struct LocalTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    let hour: Int
    let minute: Int
    let second: Int

    static let startOfDay = LocalTime(hour: 0, minute: 0, second: 0)!
    static let endOfDay = LocalTime(hour: 23, minute: 59, second: 59)!

    init?(hour: Int, minute: Int, second: Int = 0) {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// 接受 `HH:mm` 或 `HH:mm:ss`。
    init?(text: String?) {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let s = parts.count == 3 ? Int(parts[2]) ?? -1 : 0
        self.init(hour: h, minute: m, second: s)
    }

    var text: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
    var shortText: String { String(format: "%02d:%02d", hour, minute) }
    var description: String { text }

    static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        (lhs.hour, lhs.minute, lhs.second) < (rhs.hour, rhs.minute, rhs.second)
    }
}
