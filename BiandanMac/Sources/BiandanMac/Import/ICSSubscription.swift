import Foundation

// MARK: - URL 订阅：webcal:// 或 https://….ics，只读

enum ICSSubscriptionError: LocalizedError, Equatable {
    case invalidAddress
    case http(Int)
    case notCalendar
    case tooLarge
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "订阅地址不对，请粘贴 webcal:// 或 https:// 开头的地址"
        case .http(let code):
            if code == 401 || code == 403 { return "没有权限读取这个地址（HTTP \(code)），订阅链接可能已失效或需要重新生成" }
            if code == 404 { return "这个地址上没有日历（HTTP 404），请核对订阅地址" }
            return "服务器返回错误（HTTP \(code)）"
        case .notCalendar: return "这个地址返回的不是日历内容（.ics）"
        case .tooLarge: return "日历文件太大（超过 20 MB），没有读取"
        case .network(let message): return "网络错误：\(message)"
        }
    }
}

enum ICSSubscription {
    static let maxBytes = 20 * 1024 * 1024

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// webcal:// / webcals:// / http:// 统一改用 https；只填域名时补上 https://。
    static func url(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        for prefix in ["webcals://", "webcal://", "http://"] where lower.hasPrefix(prefix) {
            value = "https://" + value.dropFirst(prefix.count)
            break
        }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 读取订阅地址，返回 iCalendar 文本。
    static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("text/calendar, text/plain;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Biandan/1.0 (calendar subscription)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ICSSubscriptionError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ICSSubscriptionError.http(http.statusCode)
        }
        guard data.count <= maxBytes else { throw ICSSubscriptionError.tooLarge }
        guard let text = AppModel.decodeCalendarText(data), text.contains("BEGIN:VCALENDAR") else {
            throw ICSSubscriptionError.notCalendar
        }
        return text
    }
}
