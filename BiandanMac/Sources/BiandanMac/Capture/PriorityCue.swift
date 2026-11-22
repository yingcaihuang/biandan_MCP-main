import Foundation

// MARK: - 四象限线索：从原文里找「重要」「紧急」这类说法
//
// 规则识别、端侧模型、AI 识别出来的候选都在汇总时过一遍这里，三条路径的结果一致。
// 原文明确说了的（「非常重要」「紧急安排」「不急」）以原文为准；原文没提到的，保留 AI 的判断。

enum PriorityCue {
    struct Cue: Equatable {
        /// nil 表示原文没提到；false 表示明确说了「不重要」「不急」。
        var important: Bool?
        var urgent: Bool?
        /// 命中的词，卡片里提示。
        var words: [String]
    }

    static let notImportantWords = [
        "不重要", "不太重要", "不怎么重要", "没那么重要", "不是很重要", "不是特别重要", "并不重要", "无关紧要",
        "可去可不去", "可来可不来", "不一定要", "不是必须", "非必须", "不必", "可选参加",
    ]
    static let notUrgentWords = [
        "不紧急", "不太紧急", "不是很紧急", "不急", "不太急", "不是很急", "没那么急", "不着急", "别着急", "别急",
        "不用急", "不用着急", "不赶", "不赶时间", "不用太赶", "慢慢来", "有空再", "有空的时候", "有时间再",
    ]
    static let importantWords = [
        "非常重要", "特别重要", "十分重要", "极其重要", "极为重要", "超级重要", "超重要", "很重要", "挺重要", "最重要",
        "比较重要", "尤其重要", "重中之重", "重要", "重点", "务必", "一定要", "一定记得", "千万要", "千万记得", "千万别",
        "千万不要", "必须", "切记", "牢记", "记得", "记住", "别忘了", "别忘记", "不要忘了", "不要忘记", "不能忘",
        "别迟到", "不要迟到", "不能迟到", "准时参加", "准时到", "必到", "必须到", "必须参加", "高优先级", "高优",
        "优先处理", "important", "p0",
    ]
    static let urgentWords = [
        "十万火急", "非常紧急", "特别紧急", "十分紧急", "很紧急", "紧急", "加急", "特急", "很急", "挺急", "比较急",
        "非常急", "特别急", "有点急", "急事", "急需", "急件", "急诊", "着急", "火速", "火急", "尽快", "尽早", "越快越好",
        "马上", "立刻", "立即", "赶紧", "赶快", "抓紧", "刻不容缓", "迫在眉睫", "来不及", "asap", "urgent",
    ]
    /// 在标题开头或结尾时直接去掉的口头强调（「记得交报告」→「交报告」）。
    static let leadingWords = [
        "记得", "记住", "别忘了", "别忘记", "不要忘了", "不要忘记", "切记", "牢记", "务必", "请务必", "一定要", "一定记得",
        "千万要", "千万记得", "尽快", "尽早", "赶紧", "赶快", "抓紧", "火速", "加急", "asap",
        "紧急安排", "紧急通知", "紧急提醒", "重要通知", "重要提醒", "重要提示",
    ]

    struct Phrase {
        let text: String
        let important: Bool
        let urgent: Bool
    }

    /// 四象限名称整句写出来的说法：「重要紧急」「重要但不紧急」「不重要但紧急」「不重要且不紧急」及其变体，
    /// 还有「第一象限」到「第四象限」。比单个词优先，两个维度一起定。
    static let quadrantPhrases: [Phrase] = {
        var list: [Phrase] = []
        let joins = ["", "且", "但", "但是", "而", "而且", "并且", "又", "也", "、", "/", "／", " ", "·"]
        for important in [true, false] {
            for urgent in [true, false] {
                let first = important ? "重要" : "不重要"
                let second = urgent ? "紧急" : "不紧急"
                for join in joins {
                    list.append(Phrase(text: first + join + second, important: important, urgent: urgent))
                    list.append(Phrase(text: second + join + first, important: important, urgent: urgent))
                }
            }
        }
        list += [
            Phrase(text: "又重要又紧急", important: true, urgent: true),
            Phrase(text: "既重要又紧急", important: true, urgent: true),
            Phrase(text: "重要但不急", important: true, urgent: false),
            Phrase(text: "重要不急", important: true, urgent: false),
            Phrase(text: "既不重要也不紧急", important: false, urgent: false),
            Phrase(text: "既不重要又不紧急", important: false, urgent: false),
            Phrase(text: "第一象限", important: true, urgent: true),
            Phrase(text: "第二象限", important: true, urgent: false),
            Phrase(text: "第三象限", important: false, urgent: true),
            Phrase(text: "第四象限", important: false, urgent: false),
        ]
        return list.sorted { $0.text.count > $1.text.count }
    }()

    private static func longestFirst(_ words: [String]) -> [String] { words.sorted { $0.count > $1.count } }
    private static let sortedNotImportant = longestFirst(notImportantWords)
    private static let sortedNotUrgent = longestFirst(notUrgentWords)
    private static let sortedImportant = longestFirst(importantWords)
    private static let sortedUrgent = longestFirst(urgentWords)
    private static let sortedLeading = longestFirst(leadingWords + quadrantPhrases.map(\.text))
    /// 只有和正文用空格、标点隔开时才去掉的词（「重要客户拜访」保留，「非常重要 看新品」去掉）。
    private static let sortedLabels = longestFirst(quadrantPhrases.map(\.text) + notImportantWords + notUrgentWords
                                                   + importantWords + urgentWords)

    private static let edges = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "，,。.！!？?；;：:、~～-—|｜·"))
    private static let bracketRegex = try! NSRegularExpression(
        pattern: #"[【\[（(〔]\s*([^】\]）)〕]{1,12})\s*[】\]）)〕]"#)
    private static let connectors = CharacterSet(charactersIn: "且和与及、/ ").union(.whitespaces)

    // MARK: 判断

    /// 原文里的线索。先认否定说法（「不重要」「不急」），再认肯定说法；都没有时返回 nil。
    static func detect(_ raw: String) -> Cue? {
        var text = raw
        var cue = Cue(important: nil, urgent: nil, words: [])
        func scan(_ words: [String], _ update: (inout Cue) -> Void) {
            for word in words {
                let ranges = occurrences(word, in: text)
                guard !ranges.isEmpty else { continue }
                update(&cue)
                if !cue.words.contains(word) { cue.words.append(word) }
                for range in ranges.reversed() { text.replaceSubrange(range, with: "｜") }
            }
        }
        for phrase in quadrantPhrases {
            let ranges = occurrences(phrase.text, in: text)
            guard !ranges.isEmpty else { continue }
            if cue.important == nil { cue.important = phrase.important }
            if cue.urgent == nil { cue.urgent = phrase.urgent }
            if !cue.words.contains(phrase.text) { cue.words.append(phrase.text) }
            for range in ranges.reversed() { text.replaceSubrange(range, with: "｜") }
        }
        scan(sortedNotImportant) { if $0.important == nil { $0.important = false } }
        scan(sortedNotUrgent) { if $0.urgent == nil { $0.urgent = false } }
        scan(sortedImportant) { if $0.important == nil { $0.important = true } }
        scan(sortedUrgent) { if $0.urgent == nil { $0.urgent = true } }
        if cue.important == nil && cue.urgent == nil { return nil }
        return cue
    }

    /// 汇总时调用：按原文定象限、清理标题里的强调词，并写一句依据给卡片显示。
    static func apply(_ candidates: [ScheduleCandidate]) -> [ScheduleCandidate] {
        candidates.map { original in
            var candidate = original
            let stripped = stripTitle(candidate.title)
            if !stripped.isEmpty { candidate.title = stripped }
            guard let cue = detect(original.source + "\n" + original.title) else { return candidate }
            let important = cue.important ?? candidate.quadrant.isImportant
            let urgent = cue.urgent ?? candidate.quadrant.isUrgent
            let quadrant = Quadrant(important: important, urgent: urgent)
            candidate.quadrant = quadrant
            let words = cue.words.prefix(3).map { "「" + $0 + "」" }.joined()
            candidate.quadrantReason = ["原文提到", words, "，归到「", quadrant.title, "」"].joined()
            return candidate
        }
    }

    // MARK: 标题

    /// 去掉标题里的「【紧急】」「非常重要」「记得」这类强调，只留事项本身。
    static func stripTitle(_ title: String) -> String {
        var text = removingBrackets(title)
        var changed = true
        while changed {
            changed = false
            let trimmed = text.trimmingCharacters(in: edges)
            if trimmed != text {
                text = trimmed
                changed = true
            }
            for word in sortedLeading where text.count > word.count {
                if let range = text.range(of: word, options: [.anchored, .caseInsensitive]) {
                    text.removeSubrange(range)
                    changed = true
                    break
                }
                if let range = text.range(of: word, options: [.anchored, .backwards, .caseInsensitive]) {
                    text.removeSubrange(range)
                    changed = true
                    break
                }
            }
            if changed { continue }
            for word in sortedLabels where text.count > word.count {
                if let range = text.range(of: word, options: [.anchored, .caseInsensitive]),
                   isEdge(text, at: range.upperBound) {
                    text.removeSubrange(range)
                    changed = true
                    break
                }
                if let range = text.range(of: word, options: [.anchored, .backwards, .caseInsensitive]),
                   range.lowerBound > text.startIndex, isEdge(text, at: text.index(before: range.lowerBound)) {
                    text.removeSubrange(range)
                    changed = true
                    break
                }
            }
        }
        return text
    }

    /// 「【紧急】」「(重要)」这类括号里只有强调词时整个去掉。
    private static func removingBrackets(_ title: String) -> String {
        var text = title
        let matches = bracketRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text), let innerRange = Range(match.range(at: 1), in: text) else { continue }
            var inner = String(text[innerRange])
            for word in sortedLabels { inner = inner.replacingOccurrences(of: word, with: "", options: .caseInsensitive) }
            if inner.trimmingCharacters(in: connectors).isEmpty { text.replaceSubrange(whole, with: " ") }
        }
        return text
    }

    private static func isEdge(_ text: String, at index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        return text[index].unicodeScalars.allSatisfy { edges.contains($0) }
    }

    // MARK: 查找

    /// 词在文字里出现的位置；英文词要求前后不是字母数字（「asap」不匹配「wasapp」）。
    private static func occurrences(_ word: String, in text: String) -> [Range<String.Index>] {
        let ascii = word.unicodeScalars.allSatisfy(\.isASCII)
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: word, options: .caseInsensitive, range: start..<text.endIndex) {
            if !ascii || isWordBoundary(text, range) { found.append(range) }
            start = range.upperBound
        }
        return found
    }

    private static func isWordBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        func isWord(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isASCII && (character.isLetter || character.isNumber)
        }
        let before: Character? = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
        let after: Character? = range.upperBound == text.endIndex ? nil : text[range.upperBound]
        return !isWord(before) && !isWord(after)
    }
}
