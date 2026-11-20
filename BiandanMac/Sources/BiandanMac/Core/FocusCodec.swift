import Foundation

/// 补记时关联的执行实例。
struct FocusLink: Hashable, Sendable {
    var occurrenceID: String
    var listID: Int
    var title: String
}

/// 补记专注的输入。
struct FocusInput: Sendable {
    var startedAt: Date
    var minutes: Double
    var title: String
    var goodCount: Int
    var badCount: Int
    var link: FocusLink?
}

/// 专注记录的编码规则，对应 Python `create_focus` / `update_focus`。
enum FocusCodec {
    /// 主键 `time`：开始时间的毫秒时间戳（向下取整）。
    static func identifier(startedAt: Date) -> String {
        String(Int64((startedAt.timeIntervalSince1970 * 1000).rounded(.down)))
    }

    /// 时长必须在 1–1440 分钟，向下取整。
    static func validMinutes(_ value: Double) -> Int? {
        guard value.isFinite, value >= 1, value <= 1440 else { return nil }
        return Int(value.rounded(.down))
    }

    /// 与 Python `datetime.astimezone().isoformat()` 一致：`2026-11-20T10:30:00+08:00`。
    static func endTimeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// 新建时的 `log`，键顺序和格式与 Python `json.dumps(ensure_ascii=False)` 相同。
    static func createLog(title: String, link: FocusLink?, endTime: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventID = link?.occurrenceID ?? "-1"
        let eventType = link.map { String($0.listID) } ?? "-1"
        let eventTitle = trimmed.isEmpty ? (link?.title ?? "") : trimmed
        let parts: [String] = [
            "\"eventId\": " + eventID,
            "\"eventType\": " + eventType,
            "\"eventTitle\": " + jsonLiteral(eventTitle),
            "\"endTime\": " + jsonLiteral(endTime),
        ]
        return "{" + parts.joined(separator: ", ") + "}"
    }

    /// 改标题：保留原 `log` 的其他键；原值不是 JSON 对象时按 Python 的做法补齐。
    static func updatedLog(original: String?, title: String) -> String {
        let log = FocusLog(raw: original)
        var object: [String: Any] = log.object.mapValues(anyValue)
        if object.isEmpty {
            object = ["eventId": -1, "eventType": -1, "endTime": original ?? ""]
        }
        object["eventTitle"] = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return original ?? "" }
        return text
    }

    static func jsonLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
              let wrapped = String(data: data, encoding: .utf8), wrapped.count >= 2 else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
    }

    static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let text): return text
        case .int(let number): return NSNumber(value: number)
        case .double(let number): return NSNumber(value: number)
        case .bool(let flag): return NSNumber(value: flag)
        case .array(let items): return items.map(anyValue)
        case .object(let object): return object.mapValues(anyValue)
        default: return NSNull()
        }
    }
}

/// 按日期汇总的一行。
struct FocusDayRow: Identifiable, Hashable {
    let date: String
    let count: Int
    let minutes: Double
    let good: Int
    let bad: Int

    var id: String { date }

    static func group(_ records: [FocusRecord]) -> [FocusDayRow] {
        Dictionary(grouping: records, by: \.date).map { date, rows in
            FocusDayRow(date: date, count: rows.count,
                        minutes: rows.reduce(0) { $0 + $1.minutes },
                        good: rows.reduce(0) { $0 + $1.goodCount },
                        bad: rows.reduce(0) { $0 + $1.badCount })
        }
        .sorted { $0.date > $1.date }
    }
}

enum FocusText {
    static func minutes(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }

    static func summary(_ record: FocusRecord) -> String {
        let start = record.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? record.date
        let parts: [String] = [start, minutes(record.minutes) + " 分钟", "🍅 \(record.goodCount) / \(record.badCount)"]
        return parts.joined(separator: " · ")
    }
}
