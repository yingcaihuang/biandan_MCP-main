import CoreGraphics
import Foundation

// MARK: - 浮窗球识别日程：纯逻辑部分（OCR 排版、消息时间、候选日程、规则识别）

/// OCR 识别出的一段文字和它的位置。box 用 Vision 的归一化坐标：0–1，原点在左下角。
struct OCRFragment: Equatable, Sendable {
    var text: String
    var box: CGRect
}

enum OCRLayout {
    /// 按阅读顺序拼成行：从上到下；垂直方向重叠过半的算同一行，同一行从左到右、用空格连接。
    static func lines(_ fragments: [OCRFragment]) -> [String] {
        let sorted = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.box.midY > $1.box.midY }
        var rows: [[OCRFragment]] = []
        for fragment in sorted {
            if let anchor = rows.last?.first, sameRow(anchor.box, fragment.box) {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
        }
    }

    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > min(a.height, b.height) * 0.5
    }
}

/// 识别文字的一行，附上它所属消息的发送日期（换算「明天」「周四」时以它为准）。
struct CaptureLine: Equatable, Sendable {
    var text: String
    var messageDate: LocalDate
    /// 这一行本身是聊天里的消息时间分隔行。
    var isTimestamp = false
}

/// 微信 / 飞书聊天记录里的消息时间行，例如「14:32」「昨天 14:32」「星期三 10:20」「11月20日 09:15」。
enum ChatTimestamp {
    private static let clock = #"(?:上午|下午|晚上|凌晨|中午|早上)?\s*\d{1,2}:\d{2}"#
    private static let weekdays: [String: Int] = ["日": 0, "天": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6]

    /// 这一行如果只是一个消息时间，返回那条消息的日期；否则返回 nil。
    static func date(of line: String, today: LocalDate) -> LocalDate? {
        let text = line.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 24 else { return nil }
        if match("^" + clock + "$", text) != nil { return today }
        if let groups = match(#"^(昨天|前天)\s*"# + clock + "$", text) {
            return today.adding(days: groups[1] == "昨天" ? -1 : -2)
        }
        if let groups = match(#"^(?:星期|周)([一二三四五六日天])\s*"# + clock + "$", text),
           let weekday = weekdays[groups[1]] {
            // 微信只对一周内的消息显示星期几；和今天同一个星期几时指上周那天。
            var offset = ((today.weekday - weekday) % 7 + 7) % 7
            if offset == 0 { offset = 7 }
            return today.adding(days: -offset)
        }
        if let groups = match(#"^(\d{4})[年/.\-](\d{1,2})[月/.\-](\d{1,2})日?\s*"# + clock + "$", text),
           let year = Int(groups[1]), let month = Int(groups[2]), let day = Int(groups[3]) {
            return LocalDate(year: year, month: month, day: day)
        }
        if let groups = match(#"^(\d{1,2})[月/](\d{1,2})日?\s*"# + clock + "$", text),
           let month = Int(groups[1]), let day = Int(groups[2]),
           let thisYear = LocalDate(year: today.year, month: month, day: day) {
            // 不写年份的消息时间不会在今天之后：比今天晚就是去年的。
            if thisYear > today { return LocalDate(year: today.year - 1, month: month, day: day) }
            return thisYear
        }
        return nil
    }

    /// 给每一行标上所属消息的日期。第一个消息时间之前的行按今天算。空行去掉。
    static func annotate(_ lines: [String], today: LocalDate) -> [CaptureLine] {
        var current = today
        var result: [CaptureLine] = []
        for raw in lines {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let day = date(of: text, today: today) {
                current = day
                result.append(CaptureLine(text: text, messageDate: day, isTimestamp: true))
            } else {
                result.append(CaptureLine(text: text, messageDate: current))
            }
        }
        return result
    }

    /// 交给大模型的文字：消息时间行换成「【消息时间：2026-11-20 周五】」。
    static func promptText(_ lines: [CaptureLine]) -> String {
        lines.map { line in
            guard line.isTimestamp else { return line.text }
            let day = line.messageDate
            return "【消息时间：\(day.iso) \(LocalDate.weekdayNames[day.weekday])】"
        }
        .joined(separator: "\n")
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// 「14:30」「9:05」「14：30」「14:30:00」→ 时刻。
enum ClockText {
    static func parse(_ text: String) -> LocalTime? {
        let value = text.replacingOccurrences(of: "：", with: ":").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return LocalTime(hour: hour, minute: minute)
    }
}

/// 识别出的一条日程，确认卡片里可以修改。
struct ScheduleCandidate: Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// nil 表示无日期。
    var date: LocalDate?
    /// 跨天日程的结束日期；同一天时为 nil。
    var endDate: LocalDate?
    var start: LocalTime?
    var end: LocalTime?
    var location = ""
    /// 依据的原文片段。
    var source = ""
    /// 是否勾选添加。
    var include = true
    /// 需要用户留意的提示（没识别出日期、日期已过去）。
    var note: String?
    /// 四象限（确认卡片里选择，默认不重要不紧急）。
    var quadrant: Quadrant = .neither
    /// 原文只说了「下午」「晚上」这类时段、没写具体时刻时记下这个词，卡片里提示补时刻。
    var vagueTime: String?
    /// 分类：识别后按情景自动选（见 ScheduleCategorizer），确认卡片里可以逐条改。
    var category: CandidateCategory = .existing(TodoList.defaultID)
    /// 自动选分类的依据，卡片里提示；手动改过就清掉。
    var categoryReason: String?

    init(title: String) {
        self.title = title
    }

    /// 更新提示；initial 为 true 时顺便决定默认是否勾选（日期已过去的默认不勾）。
    mutating func review(today: LocalDate, initial: Bool = false) {
        if let date {
            note = date < today ? "日期已经过去，请确认" : nil
            if initial { include = date >= today }
        } else {
            note = "没识别出日期，添加后是无日期任务"
        }
    }

    /// 大模型的输出 → 候选日程。字段都是字符串，空字符串表示没有；日期、时刻写法不对时当作没有。
    static func fromModel(title: String, startDate: String, startTime: String, endDate: String, endTime: String,
                          location: String, source: String, today: LocalDate) -> ScheduleCandidate? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var candidate = ScheduleCandidate(title: name)
        candidate.date = LocalDate(iso: startDate.trimmingCharacters(in: .whitespacesAndNewlines))
        candidate.start = ClockText.parse(startTime)
        candidate.end = ClockText.parse(endTime)
        if let date = candidate.date, let last = LocalDate(iso: endDate.trimmingCharacters(in: .whitespacesAndNewlines)),
           last > date {
            candidate.endDate = last
        }
        if candidate.start == nil {
            candidate.end = nil
        } else if let start = candidate.start, let end = candidate.end, candidate.endDate == nil, end <= start {
            candidate.end = nil
        }
        candidate.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.review(today: today, initial: true)
        return candidate
    }

    /// 新建参数。写了时刻时设置时间段（没写结束按 30 分钟）和该时刻的提醒，与快速添加一致。
    /// 地点和原文写进备注。标题为空时返回 nil。
    func input(listID: String) -> CreateTaskInput? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var input = CreateTaskInput(title: name)
        input.listID = listID
        input.important = quadrant.isImportant
        input.urgent = quadrant.isUrgent
        var remark: [String] = []
        if !location.isEmpty { remark.append("地点：" + location) }
        if !source.isEmpty { remark.append("原文：" + source) }
        input.remark = remark.joined(separator: "\n")
        guard let date else { return input }
        let last = max(endDate ?? date, date)
        input.startDate = date
        input.endDate = last
        if let start {
            var finish = end ?? QuickAddParser.defaultEnd(start)
            if last == date && finish <= start { finish = QuickAddParser.defaultEnd(start) }
            input.startTime = start
            input.endTime = finish
            input.reminderDate = date
            input.reminderTime = start
        }
        return input
    }
}

/// 不用大模型时的规则识别：在整句里找日期和时刻（见 SentenceScheduleParser），
/// 「明天」「周一」按这一行所属消息的日期换算。「主题：」「地点：」这类行补到附近的日程上。
enum RuleScheduleExtractor {
    static func extract(_ lines: [CaptureLine], today: LocalDate, weekStart: Int,
                        lists: [(id: String, name: String)]) -> [ScheduleCandidate] {
        var topics: [(index: Int, text: String)] = []
        var places: [(index: Int, text: String)] = []
        var found: [(index: Int, event: SentenceScheduleParser.Event)] = []
        for (index, line) in lines.enumerated() where !line.isTimestamp {
            if let topic = SentenceScheduleParser.topic(line.text) {
                topics.append((index, topic))
                continue
            }
            if let place = SentenceScheduleParser.place(line.text) {
                places.append((index, place))
                continue
            }
            for event in SentenceScheduleParser.parse(line.text, base: line.messageDate, weekStart: weekStart) {
                found.append((index, event))
            }
        }
        func nearest(_ list: [(index: Int, text: String)], to index: Int) -> String? {
            list.filter { abs($0.index - index) <= 4 }.min { abs($0.index - index) < abs($1.index - index) }?.text
        }
        var seen = Set<String>()
        var result: [ScheduleCandidate] = []
        for (index, event) in found {
            let title = event.title.isEmpty ? (nearest(topics, to: index) ?? "日程") : event.title
            let key = "\(title)|\(event.date?.iso ?? "")|\(event.start?.shortText ?? "")"
            guard seen.insert(key).inserted else { continue }
            var candidate = ScheduleCandidate(title: title)
            candidate.date = event.date
            candidate.start = event.start
            candidate.end = event.end
            candidate.vagueTime = event.start == nil ? event.vagueTime : nil
            candidate.location = nearest(places, to: index) ?? ""
            candidate.source = event.source
            candidate.review(today: today, initial: true)
            if event.cancelled {
                candidate.include = false
                candidate.note = "提到了取消或改期，默认不勾选，请确认"
            } else if event.question {
                candidate.include = false
                candidate.note = "像是在询问，还没定下来，默认不勾选"
            }
            result.append(candidate)
        }
        return result
    }
}
