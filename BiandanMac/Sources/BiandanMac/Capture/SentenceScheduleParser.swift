import Foundation

// MARK: - 规则识别：从整句聊天里找日程（不需要大模型）
//
// 和快速添加栏不同，聊天里的日期、时刻常写在句子中间：「我们明天下午三点在 3 楼开会」。
// 这里在整句里找日期和时刻，日期的换算、时刻的上下午处理沿用 QuickAddParser，
// 去掉日期、时刻和「我们」「记得」这类口语词后，剩下的作为标题。
// 一句里用逗号隔开了几件有各自时间的事，会拆成几条：「明天上午十点评审，下午三点复盘」。

enum SentenceScheduleParser {
    struct Event: Equatable {
        var title: String
        var date: LocalDate?
        var start: LocalTime?
        var end: LocalTime?
        /// 原文写的时长（分钟），例如「时间为2小时」；只写了开始时刻时用它算结束时刻。
        var durationMinutes: Int?
        /// 原文的日期只到一段时间（「12月中旬」「月底」），date 是按这段时间估的那一天。
        var vagueDate: String?
        /// 只说了「下午」「晚上」、没写具体时刻时记下这个词。
        var vagueTime: String?
        /// 句子里的地点：「在杭州西湖区文三社区举行」「在3楼开会」。
        var location: String?
        /// 像是在询问（「明天有空吗？」），还没定下来。
        var question = false
        /// 提到了取消、改期。
        var cancelled = false
        /// 截止类：「11/13 前修复」「周五截止」「已经超期一周」。
        var deadline = false
        var source: String
    }

    // MARK: 正则

    private static let num = "(?:\\d{1,2}|[零一二两三四五六七八九十]{1,3})"
    /// 分钟：中文只有一个字时必须带「分」，避免把「三点一起开会」的「一」当成 1 分。
    private static let minute = "(?:半|一刻|三刻|\\d{1,2}分?|[零一二两三四五六七八九十]{2,3}分?|[零一二两三四五六七八九十]分)"
    private static let clock = "(?:\\d{1,2}[:：]\\d{2}|" + num + "\\s*[点时]" + minute + "?)"
    private static let period = "(?:凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|半夜)"
    private static let separator = "\\s*(?:[-~～—–]+|到|至)\\s*"

    /// 第 1 组是时段词（可以没有），第 2 组是第一个时刻。「第1点」不算时刻。
    private static let timeRegex = regex("(?<!第)(" + period + ")?\\s*(" + clock + ")(?:" + separator + period + "?" + clock + ")?")
    private static let periodRegex = regex(period)
    /// OCR 带进来的编辑器行号：行首「3 阿里开发大会…」。后面紧跟时刻、日期的不算（「3 点开会」）。
    private static let lineNumberRegex = regex(#"^\s*\d{1,4}\s+(?=[^\d\s:：点时号日月/.\-])"#)
    private static let repeatedCommaRegex = regex("[，,]\\s*[，,]+")
    /// 「在X举行」「在X开会」：第 1 组地点，第 2 组后面的动词。前面是「现、正、存」等时不是地点（「现在」「正在」）。
    private static let placeVerbRegex = regex(
        #"(?<![现正存实还所自不好])(?:在|于)\s*([^\s，,。；;！!？?、]{1,30}?)\s*"# +
        "(举行|举办|召开|进行|集合|见面|碰头|碰面|会面|开会|上课|吃饭|聚餐|聚会|见)")
    /// 「在X」后面没有动词时，地点要以楼、区、路、大厦这类词结尾。
    private static let placeTailRegex = regex(
        #"(?<![现正存实还所自不好])(?:在|于)\s*([^\s，,。；;！!？?、]{1,30}"# +
        "(?:楼|层|室|厅|区|路|街|道|巷|号|馆|中心|大厦|广场|公园|酒店|餐厅|饭店|学校|大学|公司|社区|小区|村|镇|县|市|省|店|园|院|场|站|口|座|栋))" +
        #"(?=$|[\s，,。；;！!？?、])"#)
    private static let exactMonthDayRegex = regex(#"^(\d{1,2})月(\d{1,2})[日号]?$"#)
    /// 时长：「时间为2小时」「一个半小时」「1.5h」「90分钟」「半小时」「1小时20分」。
    /// 第 1 组小时数，第 2 组「半」，第 3 组小时后面的分钟，第 4 组单独的「半小时」，第 5 组单独的分钟数。
    private static let durationRegex = regex(
        #"(?:(?:时间|时长|用时|耗时|持续|大概|大约|约|共|一共)\s*(?:为|是|[:：])?\s*)*"# +
        #"(?:(\d+(?:\.\d+)?|[零一二两三四五六七八九十]+)\s*个?\s*(半)?\s*(?:小时|钟头|h(?![a-zA-Z]))"# +
        #"(?:\s*(\d{1,2}|[零一二三四五六七八九十]+)\s*分钟?)?"# +
        #"|(半)\s*个?\s*(?:小时|钟头)"# +
        #"|(\d{1,3}|[零一二两三四五六七八九十]+)\s*(?:分钟|min))"#)
    private static let dateRegex = regex(
        // 带年份：「明年5月15号」「明年5月」「后年3月中旬」。
        #"(?:明年|今年|后年)\d{1,2}月\d{1,2}[日号]?"# +
        #"|(?:明年|今年|后年)(?:\d{1,2}|[一二三四五六七八九十]{1,3})月(?:上旬|中旬|下旬|初|中|底|末)?|"# +
        // 模糊日期：「12月中旬」「十二月底」「下个月初」「本月下旬」「月底」。
        #"(?:\d{1,2}|[一二三四五六七八九十]{1,3})月(?:上旬|中旬|下旬|初|中|底|末)"# +
        "|(?:下下个?|下个?)月(?:上旬|中旬|下旬|初|中|底|末)?" +
        "|(?:本|这个?)月(?:上旬|中旬|下旬|初|中|底|末)" +
        "|月初|月底|月末|" +
        #"\d{4}[年/.\-]\d{1,2}[月/.\-]\d{1,2}[日号]?"# +
        #"|\d{1,2}月\d{1,2}[日号]?"# +
        #"|\d{1,2}/\d{1,2}(?!\d)"# +
        "|(?:下下|下|本|这)?(?:周|星期|礼拜)[一二三四五六日天]" +
        // 「周末时段」「周末价」「周末特惠」是名词，不是日期。
        "|(?:下下|下|本|这)?周末(?!时段|价|特价|特惠|优惠|折扣|套餐|版|档|费|模式)" +
        "|大后天|后天|明天|今天|今晚|明晚|今早|明早" +
        #"|\d{1,2}[日号](?![楼栋室层座期线门厅房位机窗床柜台桌箱库仓馆]|会议室|会客室|包厢|车厢|教室|展厅)"#)
    /// 第 1 组月份数字，第 2 组「下个」「本」这类前缀，第 3 组上旬 / 中旬 / 下旬 / 初 / 中 / 底 / 末。
    private static let fuzzyMonthRegex = regex(
        #"^(?:(\d{1,2}|[一二三四五六七八九十]{1,3})月|(下下个?|下个?|本|这个?)?月)(上旬|中旬|下旬|初|中|底|末)?$"#)
    private static let explicitDateRegex = regex(#"^(\d{4})[年/.\-](\d{1,2})[月/.\-](\d{1,2})"#)
    private static let keyPrefixRegex = regex("(?:会议)?(?:时间|日期)\\s*[:：]")
    private static let emptyBracketRegex = regex("[（(【\\[]\\s*[）)】\\]]")
    private static let spacesRegex = regex("\\s+")
    private static let topicRegex = regex("^\\s*(?:会议)?(?:主题|标题|事项|名称)\\s*[:：]\\s*(.+?)\\s*$")
    private static let placeRegex = regex("^\\s*(?:会议)?(?:地点|地址|会议室|位置)\\s*[:：]\\s*(.+?)\\s*$")

    private static let periodKinds: [String: String] = [
        "凌晨": "am", "早上": "am", "早晨": "am", "上午": "am", "半夜": "am",
        "中午": "noon", "下午": "pm", "傍晚": "pm", "晚上": "pm", "夜里": "pm",
    ]

    private static let fillers = [
        "别忘了", "别忘记", "不要忘了", "提醒一下", "提醒我", "记得", "我们", "咱们", "大家", "他们",
        "有一个", "有个", "到时候", "那就", "麻烦", "需要", "准备", "一起", "请", "您", "你", "我",
        "那", "就", "要", "得", "在", "于", "的",
    ].sorted { $0.count > $1.count }
    private static let trailingParticles: Set<Character> = ["吧", "哦", "啊", "呀", "哈", "呢", "了", "吗", "嘛", "啦", "喔", "噢"]
    private static let edgePunctuation: Set<Character> = [
        "，", ",", "。", ".", "！", "!", "？", "?", "；", ";", "：", ":", "、", "~", "～",
        "（", "）", "(", ")", "【", "】", "[", "]", "-", "—", " ", "\u{3000}", "\t",
    ]
    private static let cancelWords = ["取消", "不去了", "不开了", "不来了", "改天", "延期", "推迟"]
    private static let deadlineWords = ["截止", "截至", "deadline", "ddl", "到期", "超期", "逾期"]
    /// 没写年份的「11/13」「11月13日」。
    private static let bareMonthDayRegex = regex(#"^\d{1,2}(?:月\d{1,2}[日号]?|/\d{1,2})$"#)
    /// 没写年份的日期过去不超过这么多天时指今年那天，更早的才算明年。
    static let recentPastDays = 92

    // MARK: 入口

    /// 解析一行文字。base 是这行所属消息的发送日期，「明天」「周五」按它换算。
    static func parse(_ line: String, base: LocalDate, weekStart: Int) -> [Event] {
        var events: [Event] = []
        let cleaned = replace(lineNumberRegex, in: line, with: "")
        for sentence in sentences(cleaned) {
            var groups: [Group] = []
            let parts = sentence.text.split(whereSeparator: { $0 == "，" || $0 == "," }).map(String.init)
            for part in parts where !part.trimmingCharacters(in: .whitespaces).isEmpty {
                let found = anchors(part, base: base, weekStart: weekStart)
                guard var last = groups.last else {
                    groups.append(Group(parts: [part], hasDate: found.hasDate, hasTime: found.hasTime))
                    continue
                }
                if found.hasDate && (last.hasDate || last.hasTime) {
                    groups.append(Group(parts: [part], hasDate: true, hasTime: found.hasTime))
                } else if found.hasTime && last.hasTime {
                    // 同一句里的下一个时刻沿用前面的日期：「明天上午十点评审，下午三点复盘」。
                    groups.append(Group(parts: [part], hasDate: false, hasTime: true, inheritsDate: true))
                } else {
                    last.parts.append(part)
                    last.hasDate = last.hasDate || found.hasDate
                    last.hasTime = last.hasTime || found.hasTime
                    groups[groups.count - 1] = last
                }
            }
            var previousDate: LocalDate?
            for group in groups {
                let text = group.parts.joined(separator: "，")
                guard let event = event(text, inherited: group.inheritsDate ? previousDate : nil, base: base,
                                        weekStart: weekStart, question: sentence.question) else { continue }
                previousDate = event.date
                events.append(event)
            }
        }
        return events
    }

    /// 「会议主题：Q4 复盘」这类行的值。
    static func topic(_ line: String) -> String? { value(topicRegex, line) }

    /// 「地点：3 楼大会议室」这类行的值。
    static func place(_ line: String) -> String? { value(placeRegex, line) }

    // MARK: 拆句、分组

    private struct Group {
        var parts: [String]
        var hasDate: Bool
        var hasTime: Bool
        var inheritsDate = false
    }

    private static func sentences(_ text: String) -> [(text: String, question: Bool)] {
        var result: [(text: String, question: Bool)] = []
        var current = ""
        func flush(_ question: Bool) {
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append((current, question)) }
            current = ""
        }
        for character in text {
            if "。！？!?；;\n".contains(character) {
                flush(character == "？" || character == "?")
            } else {
                current.append(character)
            }
        }
        flush(false)
        return result
    }

    // MARK: 日期、时刻

    private struct Anchors {
        var dateRanges: [Range<String.Index>] = []
        var date: LocalDate?
        var datePeriod: String?
        var timeRange: Range<String.Index>?
        var start: LocalTime?
        var end: LocalTime?
        var vagueDate: String?
        var durationRange: Range<String.Index>?
        var duration: Int?
        var hasDate: Bool { date != nil }
        var hasTime: Bool { start != nil }
    }

    private static func anchors(_ text: String, base: LocalDate, weekStart: Int) -> Anchors {
        var found = Anchors()
        for match in find(dateRegex, text) {
            if isPageCounter(text, match.range) { continue }
            let piece = String(text[match.range]).filter { !$0.isWhitespace }
            let resolved: (date: LocalDate, period: String?, vague: String?)
            if let yearly = resolveWithYear(piece, base: base) {
                resolved = (yearly.date, nil, yearly.vague)
            } else if let fuzzy = resolveFuzzy(piece, base: base) {
                resolved = (fuzzy, nil, piece)
            } else if let exact = resolveDate(piece, base: base, weekStart: weekStart) {
                resolved = (recentPast(piece, exact.date, base: base), exact.period, nil)
            } else {
                continue
            }
            found.dateRanges.append(match.range)
            if found.date == nil {
                found.date = resolved.date
                found.datePeriod = resolved.period
                found.vagueDate = resolved.vague
            }
        }
        for match in find(timeRegex, text) {
            let word = match.groups[1]
            var body = String(text[match.range])
            if !word.isEmpty { body = String(body.dropFirst(word.count)) }
            body = body.filter { !$0.isWhitespace }.replacingOccurrences(of: "–", with: "-")
            let first = match.groups[2].filter { !$0.isWhitespace }
            // 没有时段词、句子里也没有日期时，「一点」「两点」这类中文写法多半不是时刻（「快一点」）。
            if word.isEmpty && found.date == nil && !body.contains(where: { $0.isASCII && $0.isNumber }) { continue }
            let kind = word.isEmpty ? found.datePeriod : periodKinds[word]
            guard let range = QuickAddParser.time(body, period: kind) ?? QuickAddParser.time(first, period: kind) else {
                continue
            }
            found.timeRange = match.range
            found.start = range.start
            // 只有写成时间段（「3:00-4:30」「3点到5点」）时才算明确的结束时刻。
            let explicitEnd = body.contains { "-~～—到至".contains($0) }
            found.end = explicitEnd ? range.end : nil
            break
        }
        for match in find(durationRegex, text) {
            if let time = found.timeRange, match.range.overlaps(time) { continue }
            guard let minutes = durationMinutes(match.groups), minutes > 0, minutes <= 24 * 60 else { continue }
            found.durationRange = match.range
            found.duration = minutes
            break
        }
        return found
    }

    /// 「12月中旬」→ 12 月 11 日（月份已过就算明年）；「月底」→ 本月最后一天；「下个月初」→ 下月 1 日。
    /// 这段时间已经开始、还没过完（「这个月中旬」在 15 号说）时取 base 当天。
    /// 「明年5月15号」→ 2027-05-15；「明年5月」「后年3月中旬」按那一年换算，并记下原词。
    private static func resolveWithYear(_ value: String, base: LocalDate) -> (date: LocalDate, vague: String?)? {
        let prefixes: [(word: String, offset: Int)] = [("明年", 1), ("今年", 0), ("后年", 2)]
        guard let prefix = prefixes.first(where: { value.hasPrefix($0.word) }) else { return nil }
        let year = base.year + prefix.offset
        let rest = String(value.dropFirst(prefix.word.count))
        if let match = find(exactMonthDayRegex, rest).first,
           let month = Int(match.groups[1]), let day = Int(match.groups[2]) {
            return LocalDate(year: year, month: month, day: day).map { ($0, nil) }
        }
        return resolveFuzzy(rest, base: base, year: year).map { ($0, value) }
    }

    private static func resolveFuzzy(_ value: String, base: LocalDate, year forcedYear: Int? = nil) -> LocalDate? {
        guard let match = find(fuzzyMonthRegex, value).first else { return nil }
        let part = match.groups[3]
        var year = base.year
        let month: Int
        if !match.groups[1].isEmpty {
            guard let number = chineseNumber(match.groups[1]), (1...12).contains(number) else { return nil }
            month = number
            if let forcedYear {
                year = forcedYear
            } else if month < base.month {
                year += 1
            }
        } else {
            let prefix = match.groups[2]
            guard !(prefix.isEmpty && part.isEmpty) else { return nil }
            let offset = prefix.hasPrefix("下下") ? 2 : (prefix.hasPrefix("下") ? 1 : 0)
            let index = base.year * 12 + base.month - 1 + offset
            year = index / 12
            month = index % 12 + 1
        }
        let last = lastDay(year: year, month: month)
        let bounds: (start: Int, end: Int)
        switch part {
        case "初": bounds = (1, 5)
        case "上旬": bounds = (1, 10)
        case "中旬": bounds = (11, 20)
        case "中": bounds = (15, 20)
        case "下旬": bounds = (21, last)
        case "底", "末": bounds = (last, last)
        default: bounds = (1, last)
        }
        guard let start = LocalDate(year: year, month: month, day: bounds.start),
              let end = LocalDate(year: year, month: month, day: bounds.end) else { return nil }
        if start < base && end >= base { return base }
        return start
    }

    private static func lastDay(year: Int, month: Int) -> Int {
        for day in stride(from: 31, through: 28, by: -1) where LocalDate(year: year, month: month, day: day) != nil {
            return day
        }
        return 28
    }

    private static func resolveDate(_ text: String, base: LocalDate, weekStart: Int) -> (date: LocalDate, period: String?)? {
        let value = text.filter { !$0.isWhitespace }
        if let match = find(explicitDateRegex, value).first,
           let year = Int(match.groups[1]), let month = Int(match.groups[2]), let day = Int(match.groups[3]) {
            return LocalDate(year: year, month: month, day: day).map { ($0, nil) }
        }
        if value.hasSuffix("周末") {
            let prefix = String(value.dropLast(2))
            return QuickAddParser.dateToken(prefix + "周六", today: base, weekStart: weekStart).map { ($0.date, nil) }
        }
        guard let found = QuickAddParser.dateToken(value, today: base, weekStart: weekStart), found.rest.isEmpty else {
            return nil
        }
        return (found.date, found.period)
    }

    /// 「11/13 前修复，已经超期一周」在 11 月 22 日说：指今年 11 月 13 日（已经过去），不是明年。
    /// 过去超过 3 个月的才算明年（11 月说「1/5 开会」指明年 1 月 5 日）。
    private static func recentPast(_ piece: String, _ date: LocalDate, base: LocalDate) -> LocalDate {
        guard date.year == base.year + 1, !find(bareMonthDayRegex, piece).isEmpty,
              let thisYear = LocalDate(year: base.year, month: date.month, day: date.day),
              base.daysSinceEpoch - thisYear.daysSinceEpoch <= recentPastDays else { return date }
        return thisYear
    }

    /// 「页面：1/1」「第 3/10 页」「Page 2/5」「进度 4/7」这类页码、进度，不是日期。
    static func isPageCounter(_ text: String, _ range: Range<String.Index>) -> Bool {
        guard text[range].contains("/") else { return false }
        let before = String(text[text.startIndex..<range.lowerBound].suffix(6)).lowercased()
        if ["页", "page", "进度", "进展"].contains(where: { before.contains($0) }) { return true }
        if before.trimmingCharacters(in: .whitespaces).hasSuffix("第") { return true }
        if let after = text[range.upperBound...].drop(while: { $0 == " " }).first, "页张条项篇步".contains(after) {
            return true
        }
        return false
    }

    // MARK: 一条日程

    private static func event(_ text: String, inherited: LocalDate?, base: LocalDate, weekStart: Int,
                              question: Bool) -> Event? {
        let found = anchors(text, base: base, weekStart: weekStart)
        guard found.hasDate || found.hasTime else { return nil }
        var removed = found.dateRanges
        if let range = found.timeRange { removed.append(range) }
        if let range = found.durationRange { removed.append(range) }
        var vague: String?
        if !found.hasTime, let match = find(periodRegex, text).first {
            vague = match.groups[0]
            removed.append(match.range)
        } else if found.hasTime {
            // 「后天晚上，19:10」：时段词和时刻被逗号隔开，留在标题里没有意义（「下午茶」这类后面不是标点的不动）。
            for match in find(periodRegex, text) where !removed.contains(where: { $0.overlaps(match.range) }) {
                let after = match.range.upperBound
                if after == text.endIndex || "，,、 \u{3000}".contains(text[after]) { removed.append(match.range) }
            }
        }
        let source = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,")))
        var remaining = removing(removed, from: text)
        let place = extractPlace(remaining)
        if let place { remaining = place.rest }
        // 「非常重要」「【紧急】」这类强调只用来定象限，不留在标题里。
        var event = Event(title: cleanTitle(PriorityCue.stripTitle(cleanTitle(remaining))), source: source)
        event.location = place?.place
        event.date = found.date ?? inherited ?? base
        event.start = found.start
        if let start = found.start, let end = found.end, end > start {
            event.end = end
        } else if let start = found.start, let minutes = found.duration {
            // 「下午3点打球 时间为2小时」：结束 = 开始 + 时长，最晚到当天 23:59。
            let total = min(start.hour * 60 + start.minute + minutes, 23 * 60 + 59)
            event.end = LocalTime(hour: total / 60, minute: total % 60)
        }
        event.durationMinutes = found.duration
        event.vagueDate = found.vagueDate
        event.vagueTime = vague
        event.question = question || source.hasSuffix("吗")
        event.cancelled = cancelWords.contains { text.contains($0) }
        let lower = text.lowercased()
        event.deadline = deadlineWords.contains { lower.contains($0) } || found.dateRanges.contains { range in
            let after = text[range.upperBound...].drop(while: { $0.isWhitespace })
            return after.hasPrefix("前") || after.hasPrefix("之前") || after.hasPrefix("以前")
        }
        return event
    }

    /// 去掉「会议时间：」、空括号、首尾标点、开头的口语词和结尾的语气词。
    static func cleanTitle(_ raw: String) -> String {
        var title = replace(keyPrefixRegex, in: raw, with: "")
        title = replace(emptyBracketRegex, in: title, with: "")
        title = replace(spacesRegex, in: title, with: " ")
        title = replace(repeatedCommaRegex, in: title, with: "，")
        var changed = true
        while changed {
            changed = false
            while let first = title.first, edgePunctuation.contains(first) {
                title.removeFirst()
                changed = true
            }
            while let last = title.last, edgePunctuation.contains(last) || trailingParticles.contains(last) {
                title.removeLast()
                changed = true
            }
            if let word = fillers.first(where: { title.hasPrefix($0) && title.count > $0.count }) {
                title.removeFirst(word.count)
                changed = true
            }
        }
        return title
    }

    // MARK: 地点

    /// 从句子里拆出地点。「在X举行 / 举办 / 召开 / 进行」整段去掉；「在X开会」只去掉「在X」，保留动词。
    static func extractPlace(_ text: String) -> (place: String, rest: String)? {
        if let match = find(placeVerbRegex, text).first, !match.groups[1].isEmpty {
            let verb = match.groups[2]
            let dropVerb = ["举行", "举办", "召开", "进行"].contains(verb)
            var rest = text
            rest.replaceSubrange(match.range, with: dropVerb ? "" : verb)
            return (match.groups[1], rest)
        }
        if let match = find(placeTailRegex, text).first, !match.groups[1].isEmpty {
            var rest = text
            rest.replaceSubrange(match.range, with: "")
            return (match.groups[1], rest)
        }
        return nil
    }

    // MARK: 时长

    private static func durationMinutes(_ groups: [String]) -> Int? {
        guard groups.count > 5 else { return nil }
        if !groups[1].isEmpty {
            let hours: Double
            if let value = Double(groups[1]) {
                hours = value
            } else if let value = chineseNumber(groups[1]) {
                hours = Double(value)
            } else {
                return nil
            }
            var minutes = Int((hours * 60).rounded())
            if !groups[2].isEmpty { minutes += 30 }
            if !groups[3].isEmpty {
                guard let extra = chineseNumber(groups[3]) else { return nil }
                minutes += extra
            }
            return minutes
        }
        if !groups[4].isEmpty { return 30 }
        if !groups[5].isEmpty { return chineseNumber(groups[5]) }
        return nil
    }

    /// 「2」「两」「十五」「二十」「二十五」→ 数字。
    static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        var total = 0
        var current = 0
        var seen = false
        for character in text {
            if character == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
                seen = true
            } else if let digit = digits[character] {
                current = digit
                seen = true
            } else {
                return nil
            }
        }
        return seen ? total + current : nil
    }

    // MARK: 工具

    private struct Match {
        let range: Range<String.Index>
        /// 第 0 项是整个匹配；没参与匹配的组是空串。
        let groups: [String]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // 模式都是写死的，编译失败属于程序错误。
        try! NSRegularExpression(pattern: pattern)
    }

    private static func find(_ regex: NSRegularExpression, _ text: String) -> [Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (0..<result.numberOfRanges).map { index -> String in
                let group = result.range(at: index)
                guard group.location != NSNotFound, let bounds = Range(group, in: text) else { return "" }
                return String(text[bounds])
            }
            return Match(range: range, groups: groups)
        }
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func value(_ regex: NSRegularExpression, _ line: String) -> String? {
        guard let match = find(regex, line).first, !match.groups[1].isEmpty else { return nil }
        return match.groups[1]
    }

    private static func removing(_ ranges: [Range<String.Index>], from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > cursor { result += text[cursor..<range.lowerBound] }
            cursor = max(cursor, range.upperBound)
        }
        result += text[cursor...]
        return result
    }
}
