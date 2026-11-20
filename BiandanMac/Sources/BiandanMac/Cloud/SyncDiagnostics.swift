import Foundation

/// 同步诊断日志：只记录请求、状态、响应结构和条数，不记录令牌和业务内容。
/// 位置：~/Library/Application Support/BiandanMac/sync-diagnostics.log，每次同步开始时清空。
enum SyncDiagnostics {
    static let fileURL: URL? = (try? LocalStore.defaultURL())?
        .deletingLastPathComponent()
        .appendingPathComponent("sync-diagnostics.log")

    private static let lock = NSLock()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func reset() {
        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: fileURL)
    }

    static func log(_ line: String) {
        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        let text = stampFormatter.string(from: Date()) + "  " + line + "\n"
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// 响应结构摘要：键名、数组长度、首条记录的键名；字符串只记长度。
    static func summarize(_ object: JSONObject) -> String {
        if object.isEmpty { return "（空响应体）" }
        return object.keys.sorted().map { key -> String in
            guard let value = object[key] else { return key }
            switch value {
            case .array(let items):
                var text = "\(key)=[\(items.count)]"
                if case .object(let first)? = items.first {
                    text += " 首条键=" + first.keys.sorted().joined(separator: ",")
                    if case .object(let attributes)? = first["attributes"] {
                        text += " attributes键=" + attributes.keys.sorted().joined(separator: ",")
                    }
                }
                return text
            case .object(let inner):
                return "\(key)={" + inner.keys.sorted().joined(separator: ",") + "}"
            case .string(let string):
                return "\(key)=字符串(\(string.count))"
            case .null:
                return "\(key)=null"
            default:
                return "\(key)=\(value.displayText)"
            }
        }.joined(separator: "  ")
    }
}
