import Foundation
import Security

// MARK: - CalDAV：发现日历、按时间范围读取日程（只读，单向导入）
//
// 发现顺序（RFC 6764 / 4791）：/.well-known/caldav → current-user-principal → calendar-home-set → 日历列表。
// 重定向自己处理：只跟随到同一站点的 https 地址，避免把密码带到别的服务器。

struct CalDAVCredentials: Codable, Equatable, Sendable {
    var username: String
    var password: String
}

struct CalDAVCalendar: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    /// "#RRGGBB" 或 "#RRGGBBAA"；服务器没给时为 nil。
    var color: String?
    var id: String { url.absoluteString }
}

enum CalDAVError: LocalizedError, Equatable {
    case invalidAddress
    case unauthorized
    case notFound
    case noCalendars
    case missingPassword
    case insecure
    case http(Int)
    case malformed
    case network(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "服务器地址不对，请填写 https:// 开头的地址或域名"
        case .unauthorized: return "用户名或密码不对。多数服务要用 App 里生成的专用密码，不是登录密码"
        case .notFound: return "这个地址上没找到 CalDAV 服务，请核对服务器地址"
        case .noCalendars: return "登录成功，但这个账户下没有可导入的日历"
        case .missingPassword: return "钥匙串里找不到这个日历的密码，请移除后重新添加"
        case .insecure: return "服务器把请求转到了别的站点或不安全的地址，已停止，避免泄露密码"
        case .http(let code): return "服务器返回错误（HTTP \(code)）"
        case .malformed: return "服务器返回的内容看不懂，可能不是 CalDAV 服务"
        case .network(let message): return "网络错误：\(message)"
        case .keychain(let status): return "保存密码到钥匙串失败（\(status)）"
        }
    }
}

/// 常见服务的预填地址。地址以各 App 里「CalDAV 同步」页面显示的为准，用户可以改。
struct CalDAVPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let server: String
    let hint: String

    static let all: [CalDAVPreset] = [
        CalDAVPreset(id: "dingtalk", name: "钉钉", server: "https://calendar.dingtalk.com",
                     hint: "在钉钉日历设置里找「CalDAV 同步」，生成用户名和密码；服务器地址以那里显示的为准"),
        CalDAVPreset(id: "feishu", name: "飞书", server: "https://caldav.feishu.cn",
                     hint: "在飞书日历设置里找「CalDAV 同步」，生成专用密码；服务器地址以那里显示的为准"),
        CalDAVPreset(id: "wecom", name: "企业微信", server: "https://caldav.wecom.work",
                     hint: "在企业微信日程设置里找 CalDAV 同步；服务器地址以那里显示的为准"),
        CalDAVPreset(id: "tencent", name: "腾讯会议", server: "",
                     hint: "在腾讯会议的日历同步设置里复制 CalDAV 服务器地址、用户名和密码"),
        CalDAVPreset(id: "icloud", name: "iCloud", server: "https://caldav.icloud.com",
                     hint: "用户名是 Apple ID 邮箱，密码要在 Apple 账户页生成「App 专用密码」"),
        CalDAVPreset(id: "custom", name: "其他 CalDAV", server: "",
                     hint: "填写服务商提供的 CalDAV 地址；只填域名也可以，会自动查找"),
    ]
}

// MARK: - WebDAV XML

final class DAVNode {
    let name: String
    let namespace: String
    let attributes: [String: String]
    var text = ""
    var children: [DAVNode] = []

    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    func child(_ name: String) -> DAVNode? { children.first { $0.name == name } }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private final class DAVTreeBuilder: NSObject, XMLParserDelegate {
    var stack: [DAVNode] = []
    var root: DAVNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = DAVNode(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty { root = node }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}

enum DAVXML {
    struct Response {
        let href: String
        /// 状态为 200 的 propstat 里的属性。
        let props: [DAVNode]

        func prop(_ name: String) -> DAVNode? { props.first { $0.name == name } }
    }

    static func parse(_ data: Data) -> DAVNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let builder = DAVTreeBuilder()
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    static func multistatus(_ data: Data) throws -> [Response] {
        guard let root = parse(data), root.name == "multistatus" else { throw CalDAVError.malformed }
        return root.children.filter { $0.name == "response" }.map { response in
            let href = response.child("href")?.trimmedText ?? ""
            var props: [DAVNode] = []
            for propstat in response.children where propstat.name == "propstat" {
                let status = propstat.child("status")?.trimmedText ?? ""
                guard status.isEmpty || status.contains(" 200") else { continue }
                props += propstat.child("prop")?.children ?? []
            }
            return Response(href: href, props: props)
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - 客户端

private final class CalDAVRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 交给 CalDAVClient 自己跟随：保留 PROPFIND/REPORT 方法和请求体，并检查目标站点。
        completionHandler(nil)
    }
}

struct CalDAVClient: Sendable {
    var credentials: CalDAVCredentials

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: CalDAVRedirectBlocker(), delegateQueue: nil)
    }()

    /// 「caldav.feishu.cn」→「https://caldav.feishu.cn」。只接受 https。
    static func serverURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("caldav://") { value = "https://" + value.dropFirst("caldav://".count) }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 同一站点：主机相同，或可注册域名相同（p01-caldav.icloud.com 与 caldav.icloud.com）。
    static func sameSite(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased(), b = second.lowercased()
        if a == b { return !a.isEmpty }
        func site(_ host: String) -> String {
            let labels = host.split(separator: ".").map(String.init)
            guard labels.count >= 2 else { return host }
            // example.com.cn 这类：取后三段。
            let secondLevel = ["com", "net", "org", "gov", "edu", "co", "ac"]
            if labels.count >= 3, labels[labels.count - 1].count == 2, secondLevel.contains(labels[labels.count - 2]) {
                return labels.suffix(3).joined(separator: ".")
            }
            return labels.suffix(2).joined(separator: ".")
        }
        return !a.isEmpty && site(a) == site(b)
    }

    // MARK: 发现

    func discover(server: URL) async throws -> [CalDAVCalendar] {
        let root = URL(string: "/", relativeTo: server)?.absoluteURL ?? server
        let wellKnown = URL(string: "/.well-known/caldav", relativeTo: server)?.absoluteURL ?? server
        let hasPath = server.path.count > 1
        let starts = hasPath ? [server, wellKnown] : [wellKnown, root]
        var lastError = CalDAVError.notFound
        for start in starts {
            do {
                let principal = try await principalURL(at: start) ?? start
                let home = try await calendarHome(of: principal) ?? principal
                let found = try await calendars(in: home)
                if !found.isEmpty { return found }
                lastError = .noCalendars
            } catch let error as CalDAVError {
                if error == .unauthorized || error == .insecure { throw error }
                if lastError != .noCalendars { lastError = error }
            }
        }
        // 用户填的可能本身就是日历或日历主目录。
        if hasPath, let found = try? await calendars(in: server), !found.isEmpty { return found }
        throw lastError
    }

    func principalURL(at url: URL) async throws -> URL? {
        let (data, final) = try await dav("PROPFIND", url, depth: "0", body: Self.propfind("<d:current-user-principal/>"))
        return try Self.parsePrincipal(data, base: final)
    }

    func calendarHome(of principal: URL) async throws -> URL? {
        let (data, final) = try await dav("PROPFIND", principal, depth: "0", body: Self.propfind("<c:calendar-home-set/>"))
        return try Self.parseCalendarHome(data, base: final)
    }

    func calendars(in home: URL) async throws -> [CalDAVCalendar] {
        let props = "<d:resourcetype/><d:displayname/><c:supported-calendar-component-set/><a:calendar-color/>"
        let (data, final) = try await dav("PROPFIND", home, depth: "1", body: Self.propfind(props))
        return try Self.parseCalendars(data, base: final)
    }

    // MARK: 读取日程

    /// 返回每个日程资源的 iCalendar 文本。
    func events(in calendar: URL, pastDays: Int, futureDays: Int, now: Date = Date()) async throws -> [String] {
        let start = Self.utcDay(now.addingTimeInterval(-Double(pastDays) * 86_400))
        let end = Self.utcDay(now.addingTimeInterval(Double(futureDays + 1) * 86_400))
        var data: Data
        var final: URL
        do {
            (data, final) = try await dav("REPORT", calendar, depth: "1", body: Self.calendarQuery(start: start, end: end))
        } catch CalDAVError.http(let code) where code != 404 {
            // 有的服务器不支持 time-range 过滤：取全部，再由导入范围筛选。
            (data, final) = try await dav("REPORT", calendar, depth: "1", body: Self.calendarQuery(start: nil, end: nil))
        }
        let parsed = try Self.parseCalendarData(data, base: final)
        var texts = parsed.texts
        if !parsed.missing.isEmpty {
            texts += try await multiget(calendar, hrefs: parsed.missing)
        }
        return texts
    }

    private func multiget(_ calendar: URL, hrefs: [String]) async throws -> [String] {
        var texts: [String] = []
        let limited = Array(hrefs.prefix(1000))
        for start in stride(from: 0, to: limited.count, by: 100) {
            let batch = limited[start..<min(start + 100, limited.count)]
            let list = batch.map { "<d:href>\(DAVXML.escape($0))</d:href>" }.joined()
            let body = """
                <?xml version="1.0" encoding="utf-8"?>
                <c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\
                <d:prop><d:getetag/><c:calendar-data/></d:prop>\(list)</c:calendar-multiget>
                """
            let (data, final) = try await dav("REPORT", calendar, depth: "1", body: body)
            texts += try Self.parseCalendarData(data, base: final).texts
        }
        return texts
    }

    // MARK: 解析（静态，便于测试）

    static func parsePrincipal(_ data: Data, base: URL) throws -> URL? {
        try firstHref(in: "current-user-principal", data, base: base)
    }

    static func parseCalendarHome(_ data: Data, base: URL) throws -> URL? {
        try firstHref(in: "calendar-home-set", data, base: base)
    }

    private static func firstHref(in property: String, _ data: Data, base: URL) throws -> URL? {
        for response in try DAVXML.multistatus(data) {
            if let href = response.prop(property)?.child("href")?.trimmedText, !href.isEmpty {
                return URL(string: href, relativeTo: base)?.absoluteURL
            }
        }
        return nil
    }

    static func parseCalendars(_ data: Data, base: URL) throws -> [CalDAVCalendar] {
        var result: [CalDAVCalendar] = []
        var seen = Set<String>()
        for response in try DAVXML.multistatus(data) {
            guard response.prop("resourcetype")?.child("calendar") != nil,
                  let url = URL(string: response.href, relativeTo: base)?.absoluteURL else { continue }
            // 声明了支持的组件、但不含 VEVENT 的（只放待办的列表）不导入。
            if let components = response.prop("supported-calendar-component-set"), !components.children.isEmpty,
               !components.children.contains(where: { ($0.attributes["name"] ?? "").uppercased() == "VEVENT" }) {
                continue
            }
            guard seen.insert(url.absoluteString).inserted else { continue }
            let display = response.prop("displayname")?.trimmedText ?? ""
            let last = url.lastPathComponent
            let fallback = last.removingPercentEncoding ?? last
            let color = response.prop("calendar-color")?.trimmedText ?? ""
            result.append(CalDAVCalendar(url: url,
                                         name: display.isEmpty ? (fallback.isEmpty || fallback == "/" ? "日历" : fallback) : display,
                                         color: color.isEmpty ? nil : color))
        }
        return result
    }

    /// texts：带了日程数据的；missing：只给了地址、要再用 multiget 取的 .ics。
    static func parseCalendarData(_ data: Data, base: URL) throws -> (texts: [String], missing: [String]) {
        var texts: [String] = []
        var missing: [String] = []
        for response in try DAVXML.multistatus(data) {
            if let text = response.prop("calendar-data")?.text, text.contains("BEGIN:VCALENDAR") {
                texts.append(text)
            } else if response.href.lowercased().hasSuffix(".ics") {
                missing.append(response.href)
            }
        }
        return (texts, missing)
    }

    // MARK: 请求

    private static func propfind(_ props: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">\
        <d:prop>\(props)</d:prop></d:propfind>
        """
    }

    private static func calendarQuery(start: String?, end: String?) -> String {
        let range = start.map { "<c:time-range start=\"\($0)\" end=\"\(end ?? $0)\"/>" } ?? ""
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">\
            <d:prop><d:getetag/><c:calendar-data/></d:prop>\
            <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">\(range)</c:comp-filter>\
            </c:comp-filter></c:filter></c:calendar-query>
            """
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02dT000000Z", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    private var authorization: String {
        "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    }

    /// 发请求并跟随最多 5 次重定向；返回数据和最终地址（解析相对 href 用）。
    private func dav(_ method: String, _ url: URL, depth: String, body: String) async throws -> (Data, URL) {
        let origin = url.host ?? ""
        var target = url
        for _ in 0..<6 {
            var request = URLRequest(url: target)
            request.httpMethod = method
            request.httpBody = Data(body.utf8)
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(depth, forHTTPHeaderField: "Depth")
            request.setValue("Biandan/1.0 (CalDAV import)", forHTTPHeaderField: "User-Agent")
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: request)
            } catch {
                throw CalDAVError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw CalDAVError.malformed }
            switch http.statusCode {
            case 200...299:
                return (data, http.url ?? target)
            case 301, 302, 303, 307, 308:
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: target)?.absoluteURL else { throw CalDAVError.malformed }
                guard next.scheme?.lowercased() == "https", Self.sameSite(origin, next.host ?? "") else {
                    throw CalDAVError.insecure
                }
                target = next
            case 401, 403:
                throw CalDAVError.unauthorized
            case 404:
                throw CalDAVError.notFound
            default:
                throw CalDAVError.http(http.statusCode)
            }
        }
        throw CalDAVError.http(310)
    }
}

// MARK: - 钥匙串：每个 CalDAV 来源一条（用户名 + 密码）

enum CalDAVKeychain {
    private static let service = "ai.racore.BiandanMac.caldav"

    private static func query(_ sourceID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: sourceID]
    }

    static func load(_ sourceID: String) -> CalDAVCredentials? {
        var query = query(sourceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CalDAVCredentials.self, from: data)
    }

    static func save(_ credentials: CalDAVCredentials, for sourceID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query(sourceID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(sourceID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "便单 CalDAV 日历"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CalDAVError.keychain(status) }
    }

    static func delete(_ sourceID: String) {
        SecItemDelete(query(sourceID) as CFDictionary)
    }
}
