import Foundation

/// 快速添加的解析结果。`date` 只有在 `dateSet` 为 true 时才覆盖默认日期（nil 表示无日期）。
struct QuickAddDraft: Equatable {
    var title: String
    var dateSet = false
    var date: LocalDate?
    var important: Bool?
    var urgent: Bool?
    var startTime: LocalTime?
    /// 只有写了时间段（15:30-16:30）时才有值；否则按开始时刻 + 30 分钟。
    var endTime: LocalTime?
    var listID: String?
    var repeatRule: RepeatRule?
    var repeatText: String?
    var habit = false
    /// 解析时的今天：有时刻或重复但没有日期时用它。
    var today: LocalDate?
}

/// 解析快速添加栏的文字。只识别用空格隔开的词（一个词里可以把日期、时刻连写，如「明天下午3点」），
/// 识别不了的词原样留在标题里，避免把「明天的会议」「3点开会」拆开。
enum QuickAddParser {
    enum RepeatSpec: Equatable {
        case daily, workdays
        /// dates 为 nil 时按开始日期推出（每周 → 开始那天是周几，每月 → 几号，每年 → 几月几日）。
        case custom(unit: LoopUnitKind, interval: Int, dates: [String]?)
    }

    typealias TimeRange = (start: LocalTime, end: LocalTime?)

    static func parse(_ text: String, today: LocalDate, weekStart: Int = 0,
                      lists: [(id: String, name: String)] = []) -> QuickAddDraft {
        var draft = QuickAddDraft(title: "")
        draft.today = today
        var words: [String] = []
        var spec: RepeatSpec?
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "\t" }).map(String.init)
        func setTime(_ range: TimeRange) {
            draft.startTime = range.start
            draft.endTime = range.end
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case "无日期": draft.dateSet = true; draft.date = nil; continue
            case "#重要", "＃重要": draft.important = true; continue
            case "#紧急", "＃紧急": draft.urgent = true; continue
            case "#习惯", "＃习惯": draft.habit = true; continue
            default: break
            }
            if let first = token.first, first == "@" || first == "＠",
               let id = matchList(String(token.dropFirst()), lists) {
                draft.listID = id
                continue
            }
            if let found = repeatToken(token) {
                spec = found.spec
                if let range = found.time { setTime(range) }
                continue
            }
            if let found = dateToken(token, today: today, weekStart: weekStart) {
                if found.rest.isEmpty {
                    draft.dateSet = true
                    draft.date = found.date
                    continue
                }
                if let range = time(found.rest, period: found.period) {
                    draft.dateSet = true
                    draft.date = found.date
                    setTime(range)
                    continue
                }
            }
            if let range = time(token, period: nil) {
                setTime(range)
                continue
            }
            // 「下午 3点」分成两个词时，时段词作用到下一个时刻。
            if let kind = periodKind(token), index < tokens.count, let range = time(tokens[index], period: kind) {
                setTime(range)
                index += 1
                continue
            }
            words.append(token)
        }
        if draft.habit && spec == nil { spec = .daily }
        if let spec {
            let resolved = resolveRepeat(spec, explicit: draft.dateSet ? draft.date : nil, today: today)
            draft.dateSet = true
            draft.date = resolved.start
            draft.repeatRule = resolved.rule
            draft.repeatText = resolved.text
        }
        draft.title = words.joined(separator: " ")
        return draft
    }

    /// 按当前侧栏的默认值补齐，生成新建参数；标题为空时返回 nil。
    /// 写了时刻时同时设置时间段（默认 30 分钟）和该时刻的提醒。
    static func input(_ draft: QuickAddDraft, preset: NewTaskPreset) -> CreateTaskInput? {
        guard !draft.title.isEmpty else { return nil }
        var input = CreateTaskInput(title: draft.title)
        input.listID = draft.listID ?? preset.listID
        input.important = draft.important ?? preset.important
        input.urgent = draft.urgent ?? preset.urgent
        var date = draft.dateSet ? draft.date : preset.date
        if date == nil, draft.startTime != nil || draft.repeatRule != nil { date = draft.today }
        input.startDate = date
        input.endDate = date
        guard let date else { return input }
        if let start = draft.startTime {
            input.startTime = start
            input.endTime = draft.endTime ?? defaultEnd(start)
            input.reminderDate = date
            input.reminderTime = start
        }
        if let rule = draft.repeatRule {
            input.repeatRule = rule
            input.habit = draft.habit
            input.endDate = seriesEnd(date, rule)
        }
        return input
    }

    /// 重复系列的默认结束日期：按天 / 工作日 / 按周一年，按月两年，按年十年。
    static func seriesEnd(_ start: LocalDate, _ rule: RepeatRule) -> LocalDate {
        let days: Int
        switch rule.unit {
        case .month?, .lunarMonth?: days = 730
        case .year?, .lunarYear?: days = 3652
        default: days = 364
        }
        return min(start.adding(days: days), LocalDate.maxSupported)
    }

    static func defaultEnd(_ start: LocalTime) -> LocalTime {
        let total = min(start.hour * 60 + start.minute + 30, 23 * 60 + 59)
        return LocalTime(hour: total / 60, minute: total % 60) ?? start
    }

    // MARK: - 日期

    private static let relativeWords: [(word: String, offset: Int, period: String?)] = [
        ("大后天", 3, nil), ("后天", 2, nil), ("明天", 1, nil), ("今天", 0, nil),
        ("今晚", 0, "pm"), ("明晚", 1, "pm"), ("今早", 0, "am"), ("明早", 1, "am"),
    ]

    private static let weekdayIndex: [Character: Int] = [
        "日": 0, "天": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
    ]

    /// 词首的日期；rest 是剩下的部分（为空，或者是时刻）。
    static func dateToken(_ s: String, today: LocalDate, weekStart: Int) -> (date: LocalDate, period: String?, rest: String)? {
        for entry in relativeWords where s.hasPrefix(entry.word) {
            return (today.adding(days: entry.offset), entry.period, String(s.dropFirst(entry.word.count)))
        }
        if let m = groups("(下下|下|本|这)?(?:周|星期|礼拜)([一二三四五六日天])", s),
           let char = m.captures[1].first, let target = weekdayIndex[char] {
            let weekBegin = today.adding(days: -floorMod(today.weekday - weekStart, 7))
            let inWeek = floorMod(target - weekStart, 7)
            let date: LocalDate
            switch m.captures[0] {
            case "下": date = weekBegin.adding(days: 7 + inWeek)
            case "下下": date = weekBegin.adding(days: 14 + inWeek)
            case "本", "这": date = weekBegin.adding(days: inWeek)
            default: date = today.adding(days: floorMod(target - today.weekday, 7))  // 最近的那一天（含今天）
            }
            return (date, nil, m.rest)
        }
        if let m = groups("(\\d{4})-(\\d{1,2})-(\\d{1,2})", s) {
            guard let y = Int(m.captures[0]), let mo = Int(m.captures[1]), let d = Int(m.captures[2]),
                  let date = LocalDate(year: y, month: mo, day: d) else { return nil }
            return (date, nil, m.rest)
        }
        if let m = groups("(\\d{1,2})月(\\d{1,2})[日号]?", s) ?? groups("(\\d{1,2})/(\\d{1,2})", s) {
            guard let mo = Int(m.captures[0]), let d = Int(m.captures[1]),
                  let date = upcoming(month: mo, day: d, today: today) else { return nil }
            return (date, nil, m.rest)
        }
        if let m = groups("(\\d{1,2})[日号]", s) {
            guard let d = Int(m.captures[0]), let date = upcoming(dayOfMonth: d, today: today) else { return nil }
            return (date, nil, m.rest)
        }
        return nil
    }

    /// 今年的这一天；已经过去就取明年。
    private static func upcoming(month: Int, day: Int, today: LocalDate) -> LocalDate? {
        if let date = LocalDate(year: today.year, month: month, day: day), date >= today { return date }
        return LocalDate(year: today.year + 1, month: month, day: day)
    }

    /// 本月的这一号；已经过去或本月没有这一天就往后顺延。
    private static func upcoming(dayOfMonth day: Int, today: LocalDate) -> LocalDate? {
        for offset in 0..<3 {
            let index = today.year * 12 + today.month - 1 + offset
            if let date = LocalDate(year: floorDiv(index, 12), month: floorMod(index, 12) + 1, day: day),
               date >= today {
                return date
            }
        }
        return nil
    }

    // MARK: - 时刻

    private static let periods: [(word: String, kind: String)] = [
        ("凌晨", "am"), ("早上", "am"), ("早晨", "am"), ("上午", "am"),
        ("中午", "noon"), ("下午", "pm"), ("傍晚", "pm"), ("晚上", "pm"),
    ]

    private static let num = "(\\d{1,2}|[零一二两三四五六七八九十]{1,3})"

    private static func periodKind(_ token: String) -> String? {
        periods.first { $0.word == token }?.kind
    }

    /// 整个文字都是时刻（或时间段）时才返回。
    static func time(_ text: String, period: String?) -> TimeRange? {
        guard let first = clock(text, period: period) else { return nil }
        if first.rest.isEmpty { return (first.time, nil) }
        guard let separator = groups("[-~～到至—]", first.rest),
              let second = clock(separator.rest, period: first.period), second.rest.isEmpty,
              second.time > first.time else { return nil }
        return (first.time, second.time)
    }

    /// 词首的一个时刻：15:30、下午3点、3点半、十点一刻。没写时段的「1点」–「5点」按下午算。
    private static func clock(_ text: String, period inherited: String?) -> (time: LocalTime, period: String?, rest: String)? {
        var body = text
        var period = inherited
        if let found = periods.first(where: { body.hasPrefix($0.word) }) {
            period = found.kind
            body = String(body.dropFirst(found.word.count))
        }
        var hour: Int
        var minute = 0
        let rest: String
        var spoken = false
        if let m = groups("(\\d{1,2})[:：](\\d{2})", body), let h = Int(m.captures[0]), let mi = Int(m.captures[1]) {
            hour = h
            minute = mi
            rest = m.rest
        } else if let m = groups(num + "[点时](半|一刻|三刻|" + num + "分?)?", body), let h = number(m.captures[0]) {
            hour = h
            spoken = true
            rest = m.rest
            switch m.captures[1] {
            case "": minute = 0
            case "半": minute = 30
            case "一刻": minute = 15
            case "三刻": minute = 45
            default:
                guard let value = number(m.captures[2]) else { return nil }
                minute = value
            }
        } else {
            return nil
        }
        switch period {
        case "pm"?: if hour < 12 { hour += 12 }
        case "noon"?: if hour < 6 { hour += 12 }
        case nil: if spoken && (1...5).contains(hour) { hour += 12 }
        default: break
        }
        guard let time = LocalTime(hour: hour, minute: minute) else { return nil }
        return (time, period, rest)
    }

    // MARK: - 重复

    /// 重复写法，后面可以跟时刻（「每周一8点」）；其余文字不认。
    static func repeatToken(_ s: String) -> (spec: RepeatSpec, time: TimeRange?)? {
        let spec: RepeatSpec
        var rest: String
        if let m = groups("(?:每个?)?工作日", s) {
            spec = .workdays
            rest = m.rest
        } else if let m = groups("每周末", s) {
            spec = .custom(unit: .week, interval: 1, dates: ["6", "0"])
            rest = m.rest
        } else if let m = groups("天天", s) {
            spec = .daily
            rest = m.rest
        } else if let m = groups("每(\\d{1,3}|[两二三四五六七八九十]{1,3})?个?(天|日|周|星期|礼拜|月|年)", s) {
            guard let interval = m.captures[0].isEmpty ? 1 : number(m.captures[0]), (1...366).contains(interval) else {
                return nil
            }
            rest = m.rest
            switch m.captures[1] {
            case "天", "日":
                spec = interval == 1 ? .daily : .custom(unit: .day, interval: interval, dates: nil)
            case "月":
                if let d = groups("(?:最后一天|月底|底)", rest) {
                    spec = .custom(unit: .month, interval: interval, dates: ["32"])
                    rest = d.rest
                } else if let d = groups("([\\d、,，和]+)[日号]", rest) {
                    let days = d.captures[0].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                    guard !days.isEmpty, days.allSatisfy({ (1...31).contains($0) }) else { return nil }
                    spec = .custom(unit: .month, interval: interval, dates: unique(days.map(String.init)))
                    rest = d.rest
                } else {
                    spec = .custom(unit: .month, interval: interval, dates: nil)
                }
            case "年":
                if let d = groups("(\\d{1,2})月(\\d{1,2})[日号]?", rest) {
                    guard let mo = Int(d.captures[0]), let day = Int(d.captures[1]),
                          LocalDate(year: 2024, month: mo, day: day) != nil else { return nil }
                    spec = .custom(unit: .year, interval: interval, dates: [String(format: "%02d-%02d", mo, day)])
                    rest = d.rest
                } else {
                    spec = .custom(unit: .year, interval: interval, dates: nil)
                }
            default:  // 周 / 星期 / 礼拜
                if let d = groups("([一二三四五六日天、,，和]+)", rest) {
                    let days = d.captures[0].compactMap { weekdayIndex[$0] }.map(String.init)
                    guard !days.isEmpty else { return nil }
                    spec = .custom(unit: .week, interval: interval, dates: unique(days))
                    rest = d.rest
                } else {
                    spec = .custom(unit: .week, interval: interval, dates: nil)
                }
            }
        } else {
            return nil
        }
        if rest.isEmpty { return (spec, nil) }
        guard let range = time(rest, period: nil) else { return nil }
        return (spec, range)
    }

    /// 定下开始日期和规则。没写日期时，开始日期取今天起最近一次重复的那天。
    static func resolveRepeat(_ spec: RepeatSpec, explicit: LocalDate?, today: LocalDate)
        -> (start: LocalDate, rule: RepeatRule, text: String) {
        switch spec {
        case .daily:
            return (explicit ?? today, RepeatRule(mode: .daily, durationDays: 1), "每天")
        case .workdays:
            return (explicit ?? today, RepeatRule(mode: .workdays, durationDays: 1), "工作日")
        case .custom(let unit, let interval, let given):
            var start = explicit ?? today
            if explicit == nil, let given, !given.isEmpty {
                start = (0..<400).lazy.map { today.adding(days: $0) }
                    .first { matches($0, unit: unit, dates: given) } ?? today
            }
            let dates: [String]
            if let given, !given.isEmpty {
                dates = given
            } else {
                switch unit {
                case .week: dates = [String(start.weekday)]
                case .month: dates = [String(start.day)]
                case .year: dates = [String(format: "%02d-%02d", start.month, start.day)]
                default: dates = []
                }
            }
            let rule = RepeatRule(mode: .custom, unit: unit, interval: interval, dates: dates,
                                  dayFilter: .all, durationDays: 1)
            return (start, rule, repeatText(unit: unit, interval: interval, dates: dates))
        }
    }

    private static func matches(_ day: LocalDate, unit: LoopUnitKind, dates: [String]) -> Bool {
        switch unit {
        case .week: return dates.contains(String(day.weekday))
        case .month: return dates.contains(String(day.day)) || (dates.contains("32") && day == day.lastOfMonth)
        case .year: return dates.contains(String(format: "%02d-%02d", day.month, day.day))
        default: return true
        }
    }

    static func repeatText(unit: LoopUnitKind, interval: Int, dates: [String]) -> String {
        let every = interval == 1 ? "每" : "每\(interval)"
        switch unit {
        case .week:
            let names = dates.compactMap { Int($0) }
                .sorted { floorMod($0 - 1, 7) < floorMod($1 - 1, 7) }  // 周一在前
                .map { LocalDate.weekdayShortNames[floorMod($0, 7)] }
            return every + "周" + names.joined(separator: "、")
        case .month:
            let days = dates.compactMap { Int($0) }.sorted().map { $0 == 32 ? "最后一天" : "\($0)日" }
            return every + "月" + days.joined(separator: "、")
        case .year:
            let days = dates.compactMap { text -> String? in
                let parts = text.split(separator: "-").compactMap { Int($0) }
                return parts.count == 2 ? "\(parts[0])月\(parts[1])日" : nil
            }
            return every + "年" + days.joined(separator: "、")
        default:
            return interval == 1 ? "每天" : "每\(interval)天"
        }
    }

    // MARK: - 工具

    /// @分类：先按全名（不分大小写）匹配，再按唯一前缀匹配。
    static func matchList(_ name: String, _ lists: [(id: String, name: String)]) -> String? {
        let key = name.lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = lists.first(where: { $0.name.lowercased() == key }) { return exact.id }
        let prefixed = lists.filter { $0.name.lowercased().hasPrefix(key) }
        return prefixed.count == 1 ? prefixed[0].id : nil
    }

    /// 阿拉伯数字或 1–99 的中文数字（十、十五、二十三、两）。
    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        guard !text.isEmpty else { return nil }
        if let ten = text.firstIndex(of: "十") {
            let head = text[..<ten]
            let tail = text[text.index(after: ten)...]
            let tens = head.isEmpty ? 1 : (head.count == 1 ? head.first.flatMap { digits[$0] } : nil)
            let ones = tail.isEmpty ? 0 : (tail.count == 1 ? tail.first.flatMap { digits[$0] } : nil)
            guard let tens, let ones else { return nil }
            return tens * 10 + ones
        }
        guard text.count == 1, let first = text.first else { return nil }
        return digits[first]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// 从词首匹配 pattern，返回各捕获组（未参与匹配的为空串）和剩下的文字。
    private static func groups(_ pattern: String, _ text: String) -> (captures: [String], rest: String)? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")") else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var captures: [String] = []
        if match.numberOfRanges > 1 {
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                captures.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
        }
        return (captures, ns.substring(from: match.range.length))
    }
}

extension AppModel {
    /// 用当前的周起始日和分类解析快速添加文字（内容区快速添加栏和全局快速添加共用）。
    func parseQuickAdd(_ text: String) -> QuickAddDraft {
        QuickAddParser.parse(text, today: today, weekStart: weekStart,
                             lists: snapshot.lists.map { (id: $0.id3, name: $0.displayName) })
    }

    /// 回车前的预览：日期 · 时刻 · 重复 · 分类 · 重要 / 紧急。
    func quickAddHint(_ draft: QuickAddDraft, preset: NewTaskPreset? = nil) -> String {
        guard let input = QuickAddParser.input(draft, preset: preset ?? makeNewTaskPreset()) else { return "" }
        var parts: [String] = []
        if let day = input.startDate {
            parts.append(day == today ? "今天" : (day == today.adding(days: 1) ? "明天" : day.shortTitle))
        } else {
            parts.append("无日期")
        }
        if let start = input.startTime {
            parts.append(draft.endTime.map { "\(start.shortText)–\($0.shortText)" } ?? "\(start.shortText) 提醒")
        }
        if let text = draft.repeatText { parts.append(text) }
        if input.habit { parts.append("习惯") }
        parts.append(snapshot.list(input.listID)?.displayName ?? "未分类")
        if input.important { parts.append("重要") }
        if input.urgent { parts.append("紧急") }
        return "↩︎ " + parts.joined(separator: " · ")
    }
}
