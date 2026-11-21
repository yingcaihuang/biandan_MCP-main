import CryptoKit
import Foundation

// MARK: - ICS 日程 → 便单任务
//
// 简单、没有结束的重复（每 N 天 / 每周几 / 每月几号 / 每年某天）直接转成便单的重复规则；
// 有次数或截止日期、有例外日期、改动过某一次、或便单表示不了的重复，在导入范围内展开成多条一次性任务。
// 导入范围：过去 30 天到未来一年。很早开始的重复，首次发生挪到范围起点之后，免得从多年前开始生成。

struct ImportedEvent: Identifiable, Equatable, Sendable {
    /// 去重用的键：UID；展开的单次为「UID#yyyy-MM-dd」。
    var key: String
    var title: String
    var notes: String
    var location: String
    var latitude: Double?
    var longitude: Double?
    var startDate: LocalDate
    var endDate: LocalDate
    /// nil 表示全天。
    var startTime: LocalTime?
    var endTime: LocalTime?
    var repeatRule: RepeatRule?
    /// 重复说明，例如「每周一、三」。
    var repeatText: String?
    var cancelled = false
    var url = ""
    /// 预览里是否勾选。
    var include = true

    var id: String { key }
    var isAllDay: Bool { startTime == nil }

    /// 内容指纹：再次同步时据此判断外部日程有没有改过。
    var fingerprint: String {
        // 重复日程的首次日期会随导入范围（今天往前 30 天）每天后移，不算外部改动；便单也不同步重复任务的日期。
        let dated = repeatRule == nil
        let parts: [String] = [
            title, notes, location, dated ? startDate.iso : "", dated ? endDate.iso : "", startTime?.shortText ?? "", endTime?.shortText ?? "",
            repeatText ?? "", latitude.map { String($0) } ?? "", longitude.map { String($0) } ?? "", cancelled ? "x" : "",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 新建参数。导入的日程不加时间提醒（外部日历一般已经会提醒），备注里写明来源。
    func input(listID: String, sourceName: String) -> CreateTaskInput {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var input = CreateTaskInput(title: name.isEmpty ? "（无标题）" : name)
        input.listID = listID
        var remark: [String] = []
        if !notes.isEmpty { remark.append(notes) }
        if !url.isEmpty { remark.append(url) }
        remark.append("来自「\(sourceName)」")
        input.remark = remark.joined(separator: "\n")
        input.startDate = startDate
        input.endDate = max(endDate, startDate)
        if let startTime {
            input.startTime = startTime
            input.endTime = endTime ?? QuickAddParser.defaultEnd(startTime)
        }
        input.repeatRule = repeatRule
        if !location.isEmpty || latitude != nil {
            input.location = LocationInput(name: location.isEmpty ? nil : location, latitude: latitude,
                                           longitude: longitude, remind: nil)
        }
        return input
    }
}

struct ICSImportResult: Sendable {
    var name: String?
    var events: [ImportedEvent]
    /// 不在导入范围内、没有开始时间等被跳过的日程数。
    var skipped: Int
}

enum ICSImport {
    static let pastDays = 30
    static let futureDays = 365
    /// 一个重复系列最多展开的次数。
    static let seriesLimit = 200

    private struct Group {
        var base: ICSRawEvent?
        var overrides: [ICSRawEvent] = []
    }

    static func parse(_ text: String, today: LocalDate, calendar: Calendar = .current) -> ICSImportResult {
        let parsed = ICSCalendar.parse(text, calendar: calendar)
        let from = today.adding(days: -pastDays)
        let to = today.adding(days: futureDays)
        var groups: [String: Group] = [:]
        var order: [String] = []
        var skipped = 0
        for event in parsed.events {
            guard let start = event.start else {
                skipped += 1
                continue
            }
            let uid = event.uid.isEmpty ? "\(event.summary)|\(start.date.iso)|\(start.time?.shortText ?? "")" : event.uid
            if groups[uid] == nil {
                order.append(uid)
                groups[uid] = Group()
            }
            if event.recurrenceID != nil {
                groups[uid]?.overrides.append(event)
            } else {
                groups[uid]?.base = event
            }
        }
        var events: [ImportedEvent] = []
        for uid in order {
            guard let group = groups[uid] else { continue }
            let built = build(uid: uid, group: group, from: from, to: to, calendar: calendar)
            events += built.events
            skipped += built.skipped
        }
        return ICSImportResult(name: parsed.name, events: events, skipped: skipped)
    }

    private static func build(uid: String, group: Group, from: LocalDate, to: LocalDate,
                              calendar: Calendar) -> (events: [ImportedEvent], skipped: Int) {
        guard let base = group.base, let start = base.start else {
            // 只有改动过的单次：各自当作一次性日程。
            var events: [ImportedEvent] = []
            var skipped = 0
            for item in group.overrides {
                let day = item.recurrenceID ?? item.start?.date ?? from
                if let event = occurrence(item, key: uid + "#" + day.iso, on: nil, calendar: calendar),
                   overlaps(event, from: from, to: to) {
                    events.append(event)
                } else {
                    skipped += 1
                }
            }
            return (events, skipped)
        }
        guard let rule = base.rule, ICSRule.frequencies.contains(rule.freq) else {
            guard let event = occurrence(base, key: uid, on: nil, calendar: calendar),
                  overlaps(event, from: from, to: to) else { return ([], 1) }
            return ([event], 0)
        }
        // 能直接用便单重复规则表示的。
        let simple = group.overrides.isEmpty && base.exdates.isEmpty && rule.count == nil && rule.until == nil
            && !rule.unsupported
        if simple, var mapped = repeatRule(rule, start: start.date) {
            let first = occurrences(rule, start: start.date, from: from, to: from.adding(days: 3_660), limit: 1).first
            if let first, var event = occurrence(base, key: uid, on: first, calendar: calendar) {
                let span = first.days(to: event.endDate) + 1
                if span > 1 { mapped.durationDays = span }
                if (try? mapped.encode()) != nil {
                    event.repeatRule = mapped
                    event.repeatText = describe(rule, start: start.date)
                    return ([event], 0)
                }
            }
        }
        // 展开成一次性任务。
        let days = occurrences(rule, start: start.date, from: from, to: to, limit: seriesLimit)
        let excluded = Set(base.exdates)
        var replaced: [LocalDate: ICSRawEvent] = [:]
        for item in group.overrides {
            if let day = item.recurrenceID { replaced[day] = item }
        }
        let note = describe(rule, start: start.date) + "（按次导入）"
        var events: [ImportedEvent] = []
        for day in days where !excluded.contains(day) {
            let key = uid + "#" + day.iso
            let source = replaced.removeValue(forKey: day)
            let event = source.flatMap { occurrence($0, key: key, on: nil, calendar: calendar) }
                ?? occurrence(base, key: key, on: day, calendar: calendar)
            if var event {
                event.repeatText = note
                events.append(event)
            }
        }
        // 改到范围内、但原本那天在范围外的单次。
        for (day, item) in replaced {
            if var event = occurrence(item, key: uid + "#" + day.iso, on: nil, calendar: calendar),
               overlaps(event, from: from, to: to) {
                event.repeatText = note
                events.append(event)
            }
        }
        return (events.sorted { ($0.startDate, $0.key) < ($1.startDate, $1.key) }, 0)
    }

    /// 一次发生：on 为这次的开始日期（nil 用原日程的开始日期），时刻与时长沿用原日程。
    private static func occurrence(_ raw: ICSRawEvent, key: String, on day: LocalDate?,
                                   calendar: Calendar) -> ImportedEvent? {
        guard let start = raw.start else { return nil }
        let first = day ?? start.date
        var event = ImportedEvent(key: key, title: raw.summary, notes: raw.notes, location: raw.location,
                                  latitude: raw.latitude, longitude: raw.longitude, startDate: first, endDate: first,
                                  startTime: start.time, endTime: nil, repeatRule: nil, repeatText: nil,
                                  cancelled: raw.status == "CANCELLED", url: raw.url)
        if let time = start.time {
            var seconds: TimeInterval = 0
            if let begin = start.instant, let finish = raw.end?.instant {
                seconds = finish.timeIntervalSince(begin)
            } else if let duration = raw.duration {
                seconds = duration
            }
            if seconds > 0, let begin = start.instant,
               let shifted = calendar.date(byAdding: .day, value: start.date.days(to: first), to: begin),
               let end = ICSDate.moment(shifted.addingTimeInterval(seconds), calendar: calendar) {
                event.endDate = end.date
                event.endTime = end.time
            }
            // 没有结束、或结束不晚于开始：按 30 分钟。
            if let end = event.endTime, event.endDate == first, end <= time { event.endTime = nil }
            if event.endTime == nil {
                event.endDate = first
                event.endTime = QuickAddParser.defaultEnd(time)
            }
        } else {
            // 全天：DTEND 是结束后的那一天，不含在内。
            var days = 1
            if let end = raw.end, end.time == nil {
                days = max(start.date.days(to: end.date), 1)
            } else if let duration = raw.duration {
                days = max(Int((duration / 86_400).rounded()), 1)
            }
            event.endDate = first.adding(days: days - 1)
        }
        return event
    }

    private static func overlaps(_ event: ImportedEvent, from: LocalDate, to: LocalDate) -> Bool {
        event.endDate >= from && event.startDate <= to
    }

    // MARK: 重复

    /// 能用便单重复规则表示时返回规则（自定义：按天 / 周 / 月 / 年 + 间隔）。
    static func repeatRule(_ rule: ICSRule, start: LocalDate) -> RepeatRule? {
        guard !rule.unsupported, rule.interval <= 366 else { return nil }
        switch rule.freq {
        case "DAILY":
            guard rule.byDay.isEmpty, rule.byMonthDay.isEmpty, rule.byMonth.isEmpty else { return nil }
            return RepeatRule(mode: .custom, unit: .day, interval: rule.interval)
        case "WEEKLY":
            guard rule.byMonthDay.isEmpty, rule.byMonth.isEmpty, rule.byDay.allSatisfy({ $0.ordinal == 0 }) else {
                return nil
            }
            let days = rule.byDay.isEmpty ? [start.weekday] : rule.byDay.map(\.weekday)
            return RepeatRule(mode: .custom, unit: .week, interval: rule.interval,
                              dates: Array(Set(days)).sorted().map(String.init))
        case "MONTHLY":
            guard rule.byDay.isEmpty, rule.byMonth.isEmpty, rule.byMonthDay.allSatisfy({ (1...31).contains($0) }) else {
                return nil
            }
            let days = rule.byMonthDay.isEmpty ? [start.day] : rule.byMonthDay
            return RepeatRule(mode: .custom, unit: .month, interval: rule.interval,
                              dates: Array(Set(days)).sorted().map(String.init))
        case "YEARLY":
            guard rule.byDay.isEmpty, rule.byMonth.count <= 1, rule.byMonthDay.count <= 1 else { return nil }
            let month = rule.byMonth.first ?? start.month
            let day = rule.byMonthDay.first ?? start.day
            guard (1...12).contains(month), (1...31).contains(day) else { return nil }
            return RepeatRule(mode: .custom, unit: .year, interval: rule.interval,
                              dates: [String(format: "%02d-%02d", month, day)])
        default:
            return nil
        }
    }

    /// 在 [from, to] 内按规则生成的日期（DTSTART 当天总算第一次；COUNT 从 DTSTART 起算）。
    static func occurrences(_ rule: ICSRule, start: LocalDate, from: LocalDate, to: LocalDate,
                            limit: Int) -> [LocalDate] {
        var result: [LocalDate] = []
        var matched = 0
        var day = start
        let last = min(to, rule.until ?? to)
        var steps = 0
        while day <= last && steps < 40_000 {
            steps += 1
            if day == start || matches(rule, day, start: start) {
                matched += 1
                if let count = rule.count, matched > count { break }
                if day >= from {
                    result.append(day)
                    if result.count >= limit { break }
                }
            }
            day = day.adding(days: 1)
        }
        return result
    }

    private static func matches(_ rule: ICSRule, _ day: LocalDate, start: LocalDate) -> Bool {
        if !rule.byMonth.isEmpty && !rule.byMonth.contains(day.month) { return false }
        switch rule.freq {
        case "DAILY":
            guard floorMod(start.days(to: day), rule.interval) == 0 else { return false }
            if !rule.byDay.isEmpty && !rule.byDay.contains(where: { $0.weekday == day.weekday }) { return false }
            if !rule.byMonthDay.isEmpty && !monthDayMatches(rule.byMonthDay, day) { return false }
            return true
        case "WEEKLY":
            let weeks = floorDiv(monday(of: start).days(to: monday(of: day)), 7)
            guard floorMod(weeks, rule.interval) == 0 else { return false }
            let days = rule.byDay.isEmpty ? [start.weekday] : rule.byDay.map(\.weekday)
            return days.contains(day.weekday)
        case "MONTHLY":
            let months = (day.year - start.year) * 12 + day.month - start.month
            guard floorMod(months, rule.interval) == 0 else { return false }
            return dayInMonthMatches(rule, day, defaultDay: start.day)
        case "YEARLY":
            guard floorMod(day.year - start.year, rule.interval) == 0 else { return false }
            if rule.byMonth.isEmpty && day.month != start.month { return false }
            return dayInMonthMatches(rule, day, defaultDay: start.day)
        default:
            return false
        }
    }

    private static func dayInMonthMatches(_ rule: ICSRule, _ day: LocalDate, defaultDay: Int) -> Bool {
        if !rule.byMonthDay.isEmpty { return monthDayMatches(rule.byMonthDay, day) }
        if !rule.byDay.isEmpty {
            let last = lastDay(year: day.year, month: day.month)
            return rule.byDay.contains { item in
                guard item.weekday == day.weekday else { return false }
                if item.ordinal > 0 { return (day.day - 1) / 7 + 1 == item.ordinal }
                if item.ordinal < 0 { return (last - day.day) / 7 + 1 == -item.ordinal }
                return true
            }
        }
        return day.day == defaultDay
    }

    /// BYMONTHDAY：正数是几号，负数从月底倒数（-1 是最后一天）。
    private static func monthDayMatches(_ values: [Int], _ day: LocalDate) -> Bool {
        let last = lastDay(year: day.year, month: day.month)
        return values.contains { $0 > 0 ? $0 == day.day : last + $0 + 1 == day.day }
    }

    private static func monday(of day: LocalDate) -> LocalDate {
        day.adding(days: -floorMod(day.weekday - 1, 7))
    }

    static func lastDay(year: Int, month: Int) -> Int {
        for day in stride(from: 31, through: 28, by: -1) where LocalDate(year: year, month: month, day: day) != nil {
            return day
        }
        return 28
    }

    /// 「每天」「每 2 周一、三」「每月 15 日」「每年 3月8日」
    static func describe(_ rule: ICSRule, start: LocalDate) -> String {
        let every: (String) -> String = { unit in rule.interval > 1 ? "每 \(rule.interval) \(unit)" : "每" + unit }
        switch rule.freq {
        case "DAILY":
            return rule.interval > 1 ? "每 \(rule.interval) 天" : "每天"
        case "WEEKLY":
            let days = rule.byDay.isEmpty ? [start.weekday] : rule.byDay.map(\.weekday)
            let names = Array(Set(days)).sorted { floorMod($0 - 1, 7) < floorMod($1 - 1, 7) }
                .map { LocalDate.weekdayShortNames[$0] }
            return every("周") + names.joined(separator: "、")
        case "MONTHLY":
            if !rule.byDay.isEmpty {
                let parts = rule.byDay.map { item -> String in
                    let name = "周" + LocalDate.weekdayShortNames[item.weekday]
                    if item.ordinal < 0 { return item.ordinal == -1 ? "最后一个" + name : "倒数第 \(-item.ordinal) 个" + name }
                    return item.ordinal > 0 ? "第 \(item.ordinal) 个" + name : name
                }
                return every("月") + parts.joined(separator: "、")
            }
            let days = rule.byMonthDay.isEmpty ? [start.day] : rule.byMonthDay
            return every("月") + " " + days.map { $0 < 0 ? "倒数第 \(-$0) 天" : "\($0) 日" }.joined(separator: "、")
        default:
            let month = rule.byMonth.first ?? start.month
            let day = rule.byMonthDay.first ?? start.day
            return every("年") + " \(month)月\(day)日"
        }
    }
}
