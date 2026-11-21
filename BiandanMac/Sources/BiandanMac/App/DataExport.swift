import Foundation
import UniformTypeIdentifiers

/// 导出格式。都是只读导出，不会写回云端。
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case backupJSON, occurrencesCSV, focusCSV, calendarICS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .backupJSON: return "完整备份（JSON）"
        case .occurrencesCSV: return "任务明细（CSV）"
        case .focusCSV: return "专注记录（CSV）"
        case .calendarICS: return "日历（ICS）"
        }
    }

    var detail: String {
        switch self {
        case .backupJSON: return "四张表的全部原始字段，不丢数据"
        case .occurrencesCSV: return "每个执行实例一行，可用 Excel / Numbers 打开"
        case .focusCSV: return "每条专注一行"
        case .calendarICS: return "有日期的待办，可导入系统日历"
        }
    }

    var fileExtension: String {
        switch self {
        case .backupJSON: return "json"
        case .occurrencesCSV, .focusCSV: return "csv"
        case .calendarICS: return "ics"
        }
    }

    var contentType: UTType {
        switch self {
        case .backupJSON: return .json
        case .occurrencesCSV, .focusCSV: return .commaSeparatedText
        case .calendarICS: return UTType(filenameExtension: "ics") ?? .data
        }
    }

    func fileName(_ today: LocalDate) -> String {
        let base: String
        switch self {
        case .backupJSON: base = "便单备份"
        case .occurrencesCSV: base = "便单任务"
        case .focusCSV: base = "便单专注记录"
        case .calendarICS: base = "便单日历"
        }
        return "\(base)-\(today.iso).\(fileExtension)"
    }
}

/// 由快照生成导出内容（纯计算，不访问文件）。
enum DataExport {
    static func data(_ format: ExportFormat, snapshot: DataSnapshot, today: LocalDate, now: Date = Date()) throws -> Data {
        switch format {
        case .backupJSON: return try backupJSON(snapshot, exportedAt: now)
        case .occurrencesCSV: return Data(occurrencesCSV(snapshot).utf8)
        case .focusCSV: return Data(focusCSV(snapshot).utf8)
        case .calendarICS: return Data(calendar(snapshot, now: now).utf8)
        }
    }

    static func allItems(_ snapshot: DataSnapshot) -> [OccurrenceItem] {
        var query = OccurrenceQuery(status: .all)
        query.includeUndated = true
        return snapshot.items(query)
    }

    static func isAllDay(_ occurrence: Occurrence) -> Bool {
        occurrence.validStartTime.hasPrefix("00:00") && occurrence.validEndTime.hasPrefix("23:59")
    }

    // MARK: - JSON 完整备份

    /// 四张表的原始字段（含云端 ID、版本、时间戳）。表名与云端一致：favorites / Task / showTask / tomato。
    static func backupJSON(_ snapshot: DataSnapshot, exportedAt: Date) throws -> Data {
        func row(_ meta: RecordMeta?) -> JSONValue? {
            guard let meta else { return nil }
            var object: JSONObject = ["cloudID": .string(meta.cloudID), "attributes": .object(meta.raw)]
            object["version"] = meta.version.map { JSONValue.int(Int64($0)) } ?? JSONValue.null
            object["createdTime"] = meta.createdTime.map { JSONValue.string($0) } ?? JSONValue.null
            object["editedTime"] = meta.editedTime.map { JSONValue.string($0) } ?? JSONValue.null
            return .object(object)
        }
        let iso = ISO8601DateFormatter()
        let tasks = snapshot.tasks.values.sorted { $0.id1 < $1.id1 }
        var tables: JSONObject = [:]
        tables[RecordKind.favorites.rawValue] = .array(snapshot.lists.compactMap { row($0.meta) })
        tables[RecordKind.task.rawValue] = .array(tasks.compactMap { row($0.meta) })
        tables[RecordKind.showTask.rawValue] = .array(snapshot.occurrences.compactMap { row($0.meta) })
        tables[RecordKind.tomato.rawValue] = .array(snapshot.focus.compactMap { row($0.meta) })
        let pulled: JSONValue = snapshot.lastPulledAt.map { JSONValue.string(iso.string(from: $0)) } ?? JSONValue.null
        var root: JSONObject = [:]
        root["format"] = .string("biandan-backup")
        root["version"] = .int(1)
        root["exportedAt"] = .string(iso.string(from: exportedAt))
        root["lastPulledAt"] = pulled
        root["tables"] = .object(tables)
        return try JSONValue.object(root).serialized(pretty: true)
    }

    // MARK: - CSV

    static let bom = "\u{FEFF}"

    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"" + escaped + "\""
    }

    static func csvLine(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    private static func csvDocument(_ lines: [String]) -> String {
        [bom, lines.joined(separator: "\r\n"), "\r\n"].joined()
    }

    /// 每个执行实例一行。带 UTF-8 BOM，Excel 直接打开中文不乱码。
    static func occurrencesCSV(_ snapshot: DataSnapshot) -> String {
        let header = ["标题", "分类", "象限", "状态", "开始日期", "结束日期", "开始时刻", "结束时刻",
                      "完成时间", "重复", "习惯", "收藏", "备注", "子任务", "任务 ID", "实例 ID"]
        var lines = [csvLine(header)]
        for item in allItems(snapshot) {
            let task = item.task
            let occurrence = item.occurrence
            let content = task.content
            let dated = !task.undated
            let timed = dated && !isAllDay(occurrence)
            let list: String = snapshot.list(task.id3)?.displayName ?? "未分类"
            let startDay: String = dated ? (occurrence.startTime ?? "") : ""
            let endDay: String = dated ? (occurrence.endTime ?? "") : ""
            let startClock: String = timed ? (occurrence.startClock?.shortText ?? "") : ""
            let endClock: String = timed ? (occurrence.endClock?.shortText ?? "") : ""
            let rule: String = task.isRepeating ? RuleSummary.describe(task) : ""
            let habit: String = task.isHabit ? "是" : ""
            let collected: String = task.collected ? "是" : ""
            var fields: [String] = [task.taskTitle, list, task.quadrant.title, item.status.title]
            fields += [startDay, endDay, startClock, endClock, occurrence.completedAt ?? ""]
            fields += [rule, habit, collected, content.remark, content.subtasks.joined(separator: "；")]
            fields += [task.id1, occurrence.id2]
            lines.append(csvLine(fields))
        }
        return csvDocument(lines)
    }

    static func focusCSV(_ snapshot: DataSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        var lines = [csvLine(["日期", "开始", "结束", "分钟", "好番茄", "坏番茄", "标题"])]
        for record in snapshot.focus.sorted(by: { $0.time > $1.time }) {
            let start: String = record.startedAt.map { formatter.string(from: $0) } ?? ""
            let end: String = record.endedAt.map { formatter.string(from: $0) } ?? ""
            let fields: [String] = [record.date, start, end, String(Int(record.minutes)),
                                    String(record.goodCount), String(record.badCount), record.parsedLog.eventTitle]
            lines.append(csvLine(fields))
        }
        return csvDocument(lines)
    }

    // MARK: - ICS 日历

    /// 转义 ICS 文本：反斜杠、分号、逗号、换行。
    static func icsText(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case ";": out += "\\;"
            case ",": out += "\\,"
            case "\n", "\r\n", "\r": out += "\\n"
            default: out.append(character)
            }
        }
        return out
    }

    /// 按 RFC 5545 折行：每行不超过 75 字节（续行以一个空格开头），不拆开多字节字符。
    static func fold(_ line: String) -> String {
        var segments: [String] = []
        var current = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = segments.isEmpty ? 75 : 74
            if bytes + size > limit {
                segments.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        segments.append(current)
        return segments.joined(separator: "\r\n ")
    }

    static func dateText(_ day: LocalDate) -> String {
        String(format: "%04d%02d%02d", day.year, day.month, day.day)
    }

    static func dateTimeText(_ day: LocalDate, _ time: LocalTime) -> String {
        dateText(day) + String(format: "T%02d%02d%02d", time.hour, time.minute, time.second)
    }

    /// 有日期、待完成的执行实例。全天任务为全天事件；有时刻的按本地时间（浮动时间）导出。
    static func calendar(_ snapshot: DataSnapshot, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Biandan//BiandanMac//ZH",
                     "CALSCALE:GREGORIAN", "X-WR-CALNAME:便单"]
        for item in allItems(snapshot) where item.status == .pending && !item.task.undated {
            if let event = event(item, snapshot: snapshot, stamp: stamp) { lines += event }
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func event(_ item: OccurrenceItem, snapshot: DataSnapshot, stamp: String) -> [String]? {
        let occurrence = item.occurrence
        let task = item.task
        guard let start = occurrence.startDate else { return nil }
        let end = max(occurrence.endDate ?? start, start)
        var lines = ["BEGIN:VEVENT", "UID:\(occurrence.id2)@biandan", "DTSTAMP:\(stamp)"]
        if !isAllDay(occurrence), let from = occurrence.startClock, let to = occurrence.endClock, (end, to) > (start, from) {
            lines.append("DTSTART:" + dateTimeText(start, from))
            lines.append("DTEND:" + dateTimeText(end, to))
        } else {
            lines.append("DTSTART;VALUE=DATE:" + dateText(start))
            lines.append("DTEND;VALUE=DATE:" + dateText(end.adding(days: 1)))
            lines.append("TRANSP:TRANSPARENT")
        }
        let title = task.taskTitle.isEmpty ? "（无标题）" : task.taskTitle
        lines.append("SUMMARY:" + icsText(title))
        let list = snapshot.list(task.id3)?.displayName ?? "未分类"
        let content = task.content
        var notes: [String] = []
        if !content.remark.isEmpty { notes.append(content.remark) }
        notes += content.subtasks.map { "· " + $0 }
        notes.append("分类：" + list + " · " + task.quadrant.title)
        if task.isRepeating { notes.append("重复：" + RuleSummary.describe(task)) }
        lines.append("DESCRIPTION:" + icsText(notes.joined(separator: "\n")))
        lines.append("CATEGORIES:" + icsText(list))
        lines.append("END:VEVENT")
        return lines
    }
}

/// 本地自动备份的结果。
enum BackupOutcome: Sendable, Equatable {
    case written, skipped, failed(String)
}

/// 本地 JSON 快照：~/Library/Application Support/BiandanMac/Backups，每天一份，保留最近 7 份。
enum LocalBackup {
    static let prefix = "biandan-backup-"
    static let keep = 7

    static var directoryURL: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("BiandanMac", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    static func fileName(_ day: LocalDate) -> String { prefix + day.iso + ".json" }

    static func isBackup(_ name: String) -> Bool { name.hasPrefix(prefix) && name.hasSuffix(".json") }

    /// 超出保留份数的旧备份（文件名带日期，按名称排序即按时间排序）。
    static func stale(_ names: [String], limit: Int) -> [String] {
        Array(names.filter(isBackup).sorted(by: >).dropFirst(limit))
    }

    /// 写当天的备份；force 为 false 时当天已有就跳过。本地没有数据时不写，避免空备份。
    static func write(_ snapshot: DataSnapshot, now: Date, force: Bool) -> BackupOutcome {
        guard !snapshot.tasks.isEmpty || !snapshot.focus.isEmpty else { return .skipped }
        guard let directory = directoryURL else { return .failed("找不到应用支持目录") }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(LocalDate.today(now)))
            if !force && manager.fileExists(atPath: url.path) { return .skipped }
            try DataExport.backupJSON(snapshot, exportedAt: now).write(to: url, options: .atomic)
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in stale(names, limit: keep) {
                try? manager.removeItem(at: directory.appendingPathComponent(name))
            }
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 最新一份备份的修改时间（设置页显示）。
    static func latestDate() -> Date? {
        guard let directory = directoryURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let newest = names.filter(isBackup).max() else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(newest).path)
        return attributes?[.modificationDate] as? Date
    }
}
