import Foundation

// MARK: - ICS（RFC 5545）解析：展开折行、拆属性、日期时间与时区、时长、重复规则、VEVENT

struct ICSProperty: Equatable, Sendable {
    var name: String
    var params: [String: String]
    var value: String
}

enum ICSText {
    /// 统一换行，把以空格或 Tab 开头的续行接回上一行。
    static func unfold(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1].append(contentsOf: raw.dropFirst())
            } else {
                lines.append(String(raw))
            }
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 「NAME;PARAM=V;PARAM="A:B":VALUE」→ 属性。引号里的冒号、分号不算分隔符。
    static func property(_ line: String) -> ICSProperty? {
        var inQuotes = false
        var colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ":" && !inQuotes {
                colon = index
                break
            }
        }
        guard let colon else { return nil }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let parts = split(head, by: ";")
        guard var name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        // 「item1.SUMMARY」这类带分组前缀的写法。
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equal = part.firstIndex(of: "=") else { continue }
            let key = part[..<equal].trimmingCharacters(in: .whitespaces).uppercased()
            var text = String(part[part.index(after: equal)...])
            if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
            params[key] = text
        }
        return ICSProperty(name: name.uppercased(), params: params, value: value)
    }

    static func split(_ text: String, by separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if character == separator && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// 还原转义：\n → 换行，\, \; \\ → 原字符。
    static func unescape(_ text: String) -> String {
        var out = ""
        var escaping = false
        for character in text {
            if escaping {
                out.append(character == "n" || character == "N" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }
}

// MARK: - 日期时间

/// 换算到本机时区后的一个时间点。time 为 nil 表示全天（只有日期）。
struct ICSMoment: Equatable, Sendable {
    var date: LocalDate
    var time: LocalTime?
    /// 定时日程的绝对时间；全天为 nil。
    var instant: Date?
}

enum ICSDate {
    /// Outlook / Exchange 导出的 Windows 时区名。
    static let windowsZones: [String: String] = [
        "China Standard Time": "Asia/Shanghai", "Taipei Standard Time": "Asia/Taipei",
        "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "Singapore Standard Time": "Asia/Singapore", "India Standard Time": "Asia/Kolkata",
        "UTC": "UTC", "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris", "Pacific Standard Time": "America/Los_Angeles",
        "Mountain Standard Time": "America/Denver", "Central Standard Time": "America/Chicago",
        "Eastern Standard Time": "America/New_York", "AUS Eastern Standard Time": "Australia/Sydney",
    ]

    static func timeZone(_ identifier: String?) -> TimeZone? {
        guard let id = identifier?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        if let zone = TimeZone(identifier: id) { return zone }
        if let mapped = windowsZones[id], let zone = TimeZone(identifier: mapped) { return zone }
        // 「/mozilla.org/20050126_1/Asia/Shanghai」这类带前缀的写法：从后往前找合法的时区名。
        let parts = id.split(separator: "/").map(String.init)
        for count in stride(from: min(3, parts.count), through: 1, by: -1) {
            if let zone = TimeZone(identifier: parts.suffix(count).joined(separator: "/")) { return zone }
        }
        return nil
    }

    /// 解析 DTSTART / DTEND / RECURRENCE-ID / EXDATE / UNTIL 的一个值，换算成本机日期和时刻。
    /// 带 Z 的是 UTC，带 TZID 的按该时区，都没有的是浮动时间（按本机时区）。
    static func parse(_ raw: String, params: [String: String], calendar: Calendar) -> ICSMoment? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let tIndex = value.firstIndex { $0 == "T" || $0 == "t" }
        if params["VALUE"]?.uppercased() == "DATE" || tIndex == nil {
            return localDate(value.filter(\.isNumber)).map { ICSMoment(date: $0, time: nil, instant: nil) }
        }
        guard let tIndex else { return nil }
        let datePart = value[..<tIndex].filter(\.isNumber)
        let timePart = Array(value[value.index(after: tIndex)...].filter(\.isNumber))
        guard let day = localDate(datePart), timePart.count >= 4 else { return nil }
        let hour = Int(String(timePart[0...1])) ?? 0
        let minute = Int(String(timePart[2...3])) ?? 0
        let second = timePart.count >= 6 ? min(Int(String(timePart[4...5])) ?? 0, 59) : 0
        let utc = value.hasSuffix("Z") || value.hasSuffix("z")
        let zone: TimeZone
        if utc {
            zone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        } else {
            zone = timeZone(params["TZID"]) ?? calendar.timeZone
        }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = zone
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let instant = source.date(from: components) else { return nil }
        return moment(instant, calendar: calendar)
    }

    /// 绝对时间 → 本机日期和时刻。
    static func moment(_ instant: Date, calendar: Calendar) -> ICSMoment? {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day,
              let date = LocalDate(year: year, month: month, day: dayOfMonth),
              let time = LocalTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: min(parts.second ?? 0, 59))
        else { return nil }
        return ICSMoment(date: date, time: time, instant: instant)
    }

    private static func localDate(_ digits: String) -> LocalDate? {
        let chars = Array(digits)
        guard chars.count >= 8, let year = Int(String(chars[0..<4])), let month = Int(String(chars[4..<6])),
              let day = Int(String(chars[6..<8])) else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }

    /// 「PT1H30M」「P1D」「P1W」「-PT15M」→ 秒。
    static func duration(_ raw: String) -> TimeInterval? {
        var text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var sign: Double = 1
        if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        } else if text.hasPrefix("+") {
            text.removeFirst()
        }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        var found = false
        for character in text {
            if character == "T" {
                inTime = true
                continue
            }
            if character.isNumber {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            number = ""
            found = true
            switch character {
            case "W": total += value * 7 * 86_400
            case "D": total += value * 86_400
            case "H": total += value * 3_600
            case "M": total += inTime ? value * 60 : value * 30 * 86_400
            case "S": total += value
            default: return nil
            }
        }
        return found ? sign * total : nil
    }
}

// MARK: - 重复规则（RRULE）

/// BYDAY 的一项：weekday 0 = 周日 … 6 = 周六（与 LocalDate.weekday 一致）；ordinal 0 表示每个，2 表示第二个，-1 表示最后一个。
struct ICSWeekday: Equatable, Sendable {
    var ordinal: Int
    var weekday: Int
}

struct ICSRule: Equatable, Sendable {
    static let frequencies: Set<String> = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"]
    static let weekdays: [String: Int] = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]

    var freq: String
    var interval = 1
    var count: Int?
    var until: LocalDate?
    var byDay: [ICSWeekday] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    /// 含 BYSETPOS、BYWEEKNO、BYYEARDAY、BYHOUR 等暂不支持的部分，或频率是 HOURLY 及更细。
    var unsupported = false
    var raw: String

    init?(_ text: String, calendar: Calendar) {
        raw = text
        var frequency: String?
        for part in text.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch pair[0].trimmingCharacters(in: .whitespaces).uppercased() {
            case "FREQ": frequency = value.uppercased()
            case "INTERVAL": interval = max(Int(value) ?? 1, 1)
            case "COUNT": count = Int(value)
            case "UNTIL": until = ICSDate.parse(value, params: [:], calendar: calendar)?.date
            case "BYDAY": byDay = value.split(separator: ",").compactMap(Self.weekday)
            case "BYMONTHDAY": byMonthDay = value.split(separator: ",").compactMap { Int($0) }
            case "BYMONTH": byMonth = value.split(separator: ",").compactMap { Int($0) }
            case "WKST": break
            default: unsupported = true
            }
        }
        guard let frequency else { return nil }
        freq = frequency
        if !Self.frequencies.contains(frequency) { unsupported = true }
    }

    /// 「MO」「1MO」「-1FR」「+2TU」
    static func weekday(_ token: Substring) -> ICSWeekday? {
        let text = token.trimmingCharacters(in: .whitespaces).uppercased()
        guard text.count >= 2, let day = weekdays[String(text.suffix(2))] else { return nil }
        let prefix = String(text.dropLast(2))
        return ICSWeekday(ordinal: prefix.isEmpty ? 0 : (Int(prefix) ?? 0), weekday: day)
    }
}

// MARK: - VEVENT

struct ICSRawEvent: Equatable, Sendable {
    var uid = ""
    var summary = ""
    var notes = ""
    var location = ""
    var latitude: Double?
    var longitude: Double?
    var start: ICSMoment?
    var end: ICSMoment?
    var duration: TimeInterval?
    var rule: ICSRule?
    var exdates: [LocalDate] = []
    /// 改动过的单次：原本那次的日期。
    var recurrenceID: LocalDate?
    var status = ""
    var url = ""
}

struct ICSCalendar: Sendable {
    var name: String?
    var events: [ICSRawEvent]

    static func parse(_ text: String, calendar: Calendar = .current) -> ICSCalendar {
        var name: String?
        var events: [ICSRawEvent] = []
        var current: ICSRawEvent?
        // 事件里嵌套的子组件（VALARM 等）层数，里面的属性不属于事件本身。
        var depth = 0
        for line in ICSText.unfold(text) {
            guard let property = ICSText.property(line) else { continue }
            let kind = property.value.trimmingCharacters(in: .whitespaces).uppercased()
            if property.name == "BEGIN" {
                if current == nil {
                    if kind == "VEVENT" { current = ICSRawEvent() }
                } else {
                    depth += 1
                }
                continue
            }
            if property.name == "END" {
                guard let event = current else { continue }
                if depth > 0 {
                    depth -= 1
                } else if kind == "VEVENT" {
                    events.append(event)
                    current = nil
                }
                continue
            }
            guard var event = current else {
                if property.name == "X-WR-CALNAME" {
                    name = ICSText.unescape(property.value).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            guard depth == 0 else { continue }
            apply(property, to: &event, calendar: calendar)
            current = event
        }
        return ICSCalendar(name: name?.isEmpty == true ? nil : name, events: events)
    }

    private static func apply(_ property: ICSProperty, to event: inout ICSRawEvent, calendar: Calendar) {
        func text() -> String {
            ICSText.unescape(property.value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch property.name {
        case "UID": event.uid = property.value.trimmingCharacters(in: .whitespaces)
        case "SUMMARY": event.summary = text()
        case "DESCRIPTION": event.notes = text()
        case "LOCATION": event.location = text()
        case "URL": event.url = property.value.trimmingCharacters(in: .whitespaces)
        case "STATUS": event.status = property.value.trimmingCharacters(in: .whitespaces).uppercased()
        case "GEO":
            let parts = property.value.split { $0 == ";" || $0 == "," }.compactMap { Double($0) }
            if parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) {
                event.latitude = parts[0]
                event.longitude = parts[1]
            }
        case "DTSTART": event.start = ICSDate.parse(property.value, params: property.params, calendar: calendar)
        case "DTEND": event.end = ICSDate.parse(property.value, params: property.params, calendar: calendar)
        case "DURATION": event.duration = ICSDate.duration(property.value)
        case "RRULE": event.rule = ICSRule(property.value, calendar: calendar)
        case "RECURRENCE-ID":
            event.recurrenceID = ICSDate.parse(property.value, params: property.params, calendar: calendar)?.date
        case "EXDATE":
            for value in property.value.split(separator: ",") {
                if let moment = ICSDate.parse(String(value), params: property.params, calendar: calendar) {
                    event.exdates.append(moment.date)
                }
            }
        default: break
        }
    }
}
