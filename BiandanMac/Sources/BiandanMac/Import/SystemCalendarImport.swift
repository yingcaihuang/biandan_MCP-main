import AppKit
import CoreLocation
import EventKit
import Foundation

// MARK: - 邮箱账户：读取 Mac「互联网账户」里登录的日历（Exchange、Google、QQ、163、iCloud 等），只读
//
// 系统日历给的是展开后的每一次。重复日程把规则转成 RRULE 文本，用 ICSRule 推算应有的日期，
// 和系统实际给出的一致（没有删掉或改过某一次）时转成便单的重复任务，否则按次导入。

struct SystemCalendarInfo: Identifiable, Hashable, Sendable {
    /// EKCalendar.calendarIdentifier，存为来源地址。
    var id: String
    var title: String
    /// 账户名称，例如邮箱地址、「iCloud」「本机」。
    var account: String
    var kindTitle: String
    var colorHex: String?
}

enum SystemCalendarAccess: Equatable, Sendable {
    case granted, notDetermined, denied, writeOnly
}

enum SystemCalendarError: LocalizedError, Equatable {
    case noAccess
    case calendarGone

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "没有日历访问权限，请在「系统设置 → 隐私与安全性 → 日历」里允许「便单」完全访问"
        case .calendarGone:
            return "这个日历在 Mac 上已经不存在了（账户可能已退出或关闭了日历），可以移除后重新添加"
        }
    }
}

struct SystemRecurrence: Equatable, Sendable {
    /// RRULE 的值部分，例如「FREQ=WEEKLY;INTERVAL=1;BYDAY=MO」（不含次数和截止日期）。
    var text: String
    /// 有次数或截止日期。
    var hasEnd: Bool
}

/// 一次日程发生的快照（与 EventKit 无关，便于测试）。
struct SystemEventSnapshot: Sendable {
    var uid: String
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var notes = ""
    var location = ""
    var latitude: Double? = nil
    var longitude: Double? = nil
    var url = ""
    var cancelled = false
    /// 这一次原本的开始时间（改过时间的单次，仍是原来那天）。
    var occurrenceDate: Date? = nil
    /// 单独改过的某一次。
    var detached = false
    var recurrence: SystemRecurrence? = nil
}

// MARK: - 系统日历读取

@MainActor
enum SystemCalendarImport {
    static let store = EKEventStore()

    static var access: SystemCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    static func requestAccess() async -> SystemCalendarAccess {
        _ = try? await store.requestFullAccessToEvents()
        return access
    }

    /// 刚在「互联网账户」里登录或打开日历后，让列表尽快更新。
    static func refreshSources() {
        store.refreshSourcesIfNecessary()
    }

    static func calendars() -> [SystemCalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event).map { calendar in
            let source: EKSource? = calendar.source
            return SystemCalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                                      account: source?.title ?? "本机", kindTitle: kindTitle(source?.sourceType),
                                      colorHex: hex(calendar.cgColor))
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    static func events(calendarID: String, today: LocalDate) throws -> [ImportedEvent] {
        guard access == .granted else { throw SystemCalendarError.noAccess }
        guard let target = store.calendar(withIdentifier: calendarID) else { throw SystemCalendarError.calendarGone }
        let calendar = Calendar.current
        let from = today.adding(days: -ICSImport.pastDays)
        let to = today.adding(days: ICSImport.futureDays)
        guard let start = date(from, calendar), let end = date(to.adding(days: 1), calendar) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [target])
        let snapshots = store.events(matching: predicate).map(snapshot)
        return SystemEventConverter.convert(snapshots, to: to, calendar: calendar)
    }

    private static func snapshot(_ event: EKEvent) -> SystemEventSnapshot {
        let external = event.calendarItemExternalIdentifier ?? ""
        let coordinate = event.structuredLocation?.geoLocation?.coordinate
        let occurrence: Date? = event.occurrenceDate
        return SystemEventSnapshot(uid: external.isEmpty ? event.calendarItemIdentifier : external,
                                   title: event.title ?? "", start: event.startDate, end: event.endDate,
                                   allDay: event.isAllDay, notes: event.notes ?? "", location: event.location ?? "",
                                   latitude: coordinate?.latitude, longitude: coordinate?.longitude,
                                   url: event.url?.absoluteString ?? "", cancelled: event.status == .canceled,
                                   occurrenceDate: occurrence, detached: event.isDetached,
                                   recurrence: event.recurrenceRules?.first.map(SystemEventConverter.recurrence))
    }

    private static func date(_ day: LocalDate, _ calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    private static func kindTitle(_ type: EKSourceType?) -> String {
        switch type {
        case .local?: return "本机"
        case .exchange?: return "Exchange"
        case .calDAV?: return "CalDAV"
        case .mobileMe?: return "iCloud"
        case .subscribed?: return "订阅"
        case .birthdays?: return "生日"
        default: return "日历"
        }
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

// MARK: - 快照 → 导入的日程

enum SystemEventConverter {
    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    static func recurrence(_ rule: EKRecurrenceRule) -> SystemRecurrence {
        var parts: [String] = []
        switch rule.frequency {
        case .daily: parts.append("FREQ=DAILY")
        case .weekly: parts.append("FREQ=WEEKLY")
        case .monthly: parts.append("FREQ=MONTHLY")
        case .yearly: parts.append("FREQ=YEARLY")
        @unknown default: parts.append("FREQ=UNKNOWN")
        }
        parts.append("INTERVAL=\(max(rule.interval, 1))")
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let codes = days.map { item -> String in
                let index = min(max(item.dayOfTheWeek.rawValue - 1, 0), 6)
                let prefix = item.weekNumber == 0 ? "" : String(item.weekNumber)
                return prefix + weekdayCodes[index]
            }
            parts.append("BYDAY=" + codes.joined(separator: ","))
        }
        func add(_ name: String, _ values: [NSNumber]?) {
            guard let values, !values.isEmpty else { return }
            parts.append(name + "=" + values.map(\.stringValue).joined(separator: ","))
        }
        add("BYMONTHDAY", rule.daysOfTheMonth)
        add("BYMONTH", rule.monthsOfTheYear)
        add("BYWEEKNO", rule.weeksOfTheYear)
        add("BYYEARDAY", rule.daysOfTheYear)
        add("BYSETPOS", rule.setPositions)
        return SystemRecurrence(text: parts.joined(separator: ";"), hasEnd: rule.recurrenceEnd != nil)
    }

    /// to：导入范围的最后一天（判断重复日程是否完整时用）。
    static func convert(_ items: [SystemEventSnapshot], to: LocalDate, calendar: Calendar) -> [ImportedEvent] {
        var groups: [String: [SystemEventSnapshot]] = [:]
        var order: [String] = []
        for item in items {
            if groups[item.uid] == nil { order.append(item.uid) }
            groups[item.uid, default: []].append(item)
        }
        var result: [ImportedEvent] = []
        var seen = Set<String>()
        for uid in order {
            for event in series(uid, groups[uid] ?? [], to: to, calendar: calendar) where seen.insert(event.key).inserted {
                result.append(event)
            }
        }
        return result
    }

    private static func series(_ uid: String, _ group: [SystemEventSnapshot], to: LocalDate,
                               calendar: Calendar) -> [ImportedEvent] {
        let sorted = group.sorted { $0.start < $1.start }
        let recurrence = sorted.first(where: { $0.recurrence != nil })?.recurrence
        if sorted.count == 1, recurrence == nil, let only = sorted.first, !only.detached {
            return makeEvent(only, key: uid, calendar: calendar).map { [$0] } ?? []
        }
        let rule = recurrence.flatMap { ICSRule($0.text, calendar: calendar) }
        if let recurrence, let rule,
           let single = repeating(uid, sorted, recurrence: recurrence, rule: rule, to: to, calendar: calendar) {
            return [single]
        }
        // 按次导入。
        var note: String?
        if recurrence != nil {
            if let rule, let first = sorted.first, let firstDay = localDay(first.start, calendar) {
                note = ICSImport.describe(rule, start: firstDay) + "（按次导入）"
            } else {
                note = "重复日程（按次导入）"
            }
        }
        var events: [ImportedEvent] = []
        for item in sorted {
            guard let original = localDay(item.occurrenceDate ?? item.start, calendar),
                  var event = makeEvent(item, key: uid + "#" + original.iso, calendar: calendar) else { continue }
            event.repeatText = note
            events.append(event)
        }
        return events
    }

    /// 系统给出的日期和规则推算的完全一致时，转成一条便单重复任务。
    private static func repeating(_ uid: String, _ sorted: [SystemEventSnapshot], recurrence: SystemRecurrence,
                                  rule: ICSRule, to: LocalDate, calendar: Calendar) -> ImportedEvent? {
        guard !recurrence.hasEnd, !rule.unsupported, rule.count == nil, rule.until == nil,
              !sorted.contains(where: { $0.detached || $0.cancelled }),
              let first = sorted.first, var event = makeEvent(first, key: uid, calendar: calendar),
              var mapped = ICSImport.repeatRule(rule, start: event.startDate) else { return nil }
        let expected = ICSImport.occurrences(rule, start: event.startDate, from: event.startDate, to: to, limit: 2_000)
        let actual = Array(Set(sorted.compactMap { localDay($0.start, calendar) })).sorted()
        guard expected == actual else { return nil }
        let span = event.startDate.days(to: event.endDate) + 1
        if span > 1 { mapped.durationDays = span }
        guard (try? mapped.encode()) != nil else { return nil }
        event.repeatRule = mapped
        event.repeatText = ICSImport.describe(rule, start: event.startDate)
        return event
    }

    static func makeEvent(_ item: SystemEventSnapshot, key: String, calendar: Calendar) -> ImportedEvent? {
        let startDate: LocalDate
        var endDate: LocalDate
        var startTime: LocalTime?
        var endTime: LocalTime?
        if item.allDay {
            guard let first = localDay(item.start, calendar) else { return nil }
            // 全天日程的结束：有的是最后一天 23:59:59，有的是第二天 0 点（不含）。
            let atMidnight = calendar.startOfDay(for: item.end) == item.end
            let last = item.end > item.start && atMidnight ? item.end.addingTimeInterval(-1) : item.end
            startDate = first
            endDate = max(localDay(last, calendar) ?? first, first)
        } else {
            guard let begin = ICSDate.moment(item.start, calendar: calendar), let time = begin.time else { return nil }
            startDate = begin.date
            startTime = time
            endDate = begin.date
            if item.end > item.start, let finish = ICSDate.moment(item.end, calendar: calendar) {
                endDate = finish.date
                endTime = finish.time
            }
            if endDate == startDate, let end = endTime, end <= time { endTime = nil }
            if endTime == nil {
                endDate = startDate
                endTime = QuickAddParser.defaultEnd(time)
            }
        }
        return ImportedEvent(key: key, title: item.title, notes: item.notes, location: item.location,
                             latitude: item.latitude, longitude: item.longitude, startDate: startDate,
                             endDate: endDate, startTime: startTime, endTime: endTime, repeatRule: nil,
                             repeatText: nil, cancelled: item.cancelled, url: item.url)
    }

    static func localDay(_ date: Date, _ calendar: Calendar) -> LocalDate? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return LocalDate(year: year, month: month, day: day)
    }
}
