import Foundation
import Network

/// 本机 MCP 的 HTTP 层，对应 Python `biandan_http.create_server`。
/// 规则与 Python 版一致：只监听 127.0.0.1，校验 Host / Origin / Bearer 密钥，只接受 POST /mcp，
/// 直接返回 JSON（不开 SSE、不建会话）。校验顺序与状态码也保持一致。
enum MCPHTTP {
    static let defaultPort: UInt16 = 42682
    static let maxBody = 256 * 1024
    static let maxHead = 64 * 1024
    static let maxHeaderFields = 100
    /// 读取请求的时限（对应 Python socket 超时 10 秒）。工具执行不受此限制。
    static let readTimeout: TimeInterval = 10
    static let maxConnections = 32
    static let defaultProtocolVersion = "2025-03-26"
}

/// 解析后的请求行与头部。头部名不区分大小写，同名取第一个（与 Python `headers.get` 一致）。
struct MCPRequestHead {
    var method: String
    var target: String
    private var fields: [(String, String)]

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.first == "" { lines.removeFirst() }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        method = String(parts[0])
        target = String(parts[1])
        fields = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((name, value))
        }
        guard fields.count <= MCPHTTP.maxHeaderFields else { return nil }
    }

    func header(_ name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.0 == key }?.1
    }

    /// 对应 Python `get_content_type()`：只取媒体类型并转小写，缺省为 text/plain。
    var contentType: String {
        guard let raw = header("Content-Type") else { return "text/plain" }
        let media = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return media.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// 单个连接的读取状态。只在服务的队列上访问。
private final class MCPConnection: @unchecked Sendable {
    let connection: NWConnection
    var buffer = Data()
    /// 请求已读完（或已回复），之后不再受读取时限约束。
    var requestRead = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }
}

final class MCPHTTPServer: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case ready
        case failed(String)
        case stopped
    }

    /// 收到 JSON-RPC 消息和协议版本，返回响应；nil 表示通知（回 202）。
    typealias Dispatch = @Sendable (JSONValue, String) async -> JSONObject?

    let port: UInt16
    private let token: String
    private let versions: Set<String>
    private let dispatch: Dispatch
    private let onState: @Sendable (State) -> Void
    private let queue = DispatchQueue(label: "com.biandan.mac.mcp-http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: MCPConnection] = [:]

    private static let headTerminator = Data("\r\n\r\n".utf8)

    init(port: UInt16 = MCPHTTP.defaultPort, token: String, versions: [String],
         dispatch: @escaping Dispatch, onState: @escaping @Sendable (State) -> Void) {
        self.port = port
        self.token = token
        self.versions = Set(versions)
        self.dispatch = dispatch
        self.onState = onState
    }

    func start() {
        queue.async { self.startListening() }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for state in self.connections.values { state.connection.cancel() }
            self.connections.removeAll()
            self.onState(.stopped)
        }
    }

    // MARK: 监听

    private func startListening() {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onState(.failed("端口 \(port) 无效。"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onState(.failed(describe(error)))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState(.ready)
            case .failed(let error), .waiting(let error):
                self.onState(.failed(self.describe(error)))
                self.listener?.cancel()
                self.listener = nil
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? NWError, case .posix(let code) = error, code == .EADDRINUSE {
            return "端口 \(port) 已被占用，可能是 Python 版便单 MCP 正在运行。"
        }
        return error.localizedDescription
    }

    // MARK: 连接

    private func accept(_ connection: NWConnection) {
        guard connections.count < MCPHTTP.maxConnections else {
            connection.cancel()
            return
        }
        let state = MCPConnection(connection)
        let key = ObjectIdentifier(state)
        connections[key] = state
        connection.stateUpdateHandler = { [weak self] status in
            switch status {
            case .failed, .cancelled:
                self?.connections[key] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + MCPHTTP.readTimeout) { [weak self] in
            if !state.requestRead { self?.close(state) }
        }
        readHead(state)
    }

    private func close(_ state: MCPConnection) {
        state.requestRead = true
        state.connection.cancel()
        connections[ObjectIdentifier(state)] = nil
    }

    private func readHead(_ state: MCPConnection) {
        state.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { state.buffer.append(data) }
            if let end = state.buffer.range(of: Self.headTerminator) {
                let head = Data(state.buffer[..<end.lowerBound])
                state.buffer = Data(state.buffer[end.upperBound...])
                self.handleHead(state, head)
            } else if state.buffer.count > MCPHTTP.maxHead {
                self.reply(state, 431)
            } else if error != nil || isComplete {
                self.close(state)
            } else {
                self.readHead(state)
            }
        }
    }

    private func handleHead(_ state: MCPConnection, _ data: Data) {
        guard let head = MCPRequestHead(data) else {
            reply(state, 400)
            return
        }
        switch head.method {
        case "POST":
            break
        case "GET", "DELETE", "OPTIONS":
            if authorized(state, head) { reply(state, 405, headers: [("Allow", "POST")]) }
            return
        default:
            reply(state, 501)
            return
        }
        guard authorized(state, head) else { return }
        let version = head.header("MCP-Protocol-Version") ?? MCPHTTP.defaultProtocolVersion
        guard versions.contains(version) else {
            reply(state, 400, ["error": .string("Unsupported MCP protocol version")])
            return
        }
        guard head.contentType == "application/json" else {
            reply(state, 415, ["error": .string("Use application/json")])
            return
        }
        let length = head.header("Content-Length").flatMap { Int($0) } ?? -1
        let chunked = !(head.header("Transfer-Encoding") ?? "").isEmpty
        guard length >= 0, !chunked else {
            reply(state, 400, ["error": .string("A valid Content-Length is required")])
            return
        }
        guard length <= MCPHTTP.maxBody else {
            reply(state, 413, ["error": .string("MCP request too large")])
            return
        }
        readBody(state, length: length, version: version)
    }

    /// 只在 Host、Origin、路径、密钥全部通过时返回 true；否则已回复错误。
    private func authorized(_ state: MCPConnection, _ head: MCPRequestHead) -> Bool {
        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
        let origins = Set(hosts.map { "http://" + $0 })
        let hostAllowed = head.header("Host").map { hosts.contains($0) } ?? false
        let originAllowed = head.header("Origin").map { origins.contains($0) } ?? true
        guard hostAllowed, originAllowed else {
            reply(state, 403, ["error": .string("Only loopback MCP clients are accepted")])
            return false
        }
        guard head.target == "/mcp" else {
            reply(state, 404)
            return false
        }
        let supplied = head.header("Authorization") ?? ""
        guard PKCE.constantTimeEqual(supplied, "Bearer " + token) else {
            reply(state, 401, ["error": .string("Use the Authorization header from --print-http-config")],
                  headers: [("WWW-Authenticate", "Bearer realm=\"Biandan local MCP\"")])
            return false
        }
        return true
    }

    private func readBody(_ state: MCPConnection, length: Int, version: String) {
        if state.buffer.count >= length {
            state.requestRead = true
            process(state, body: Data(state.buffer.prefix(length)), version: version)
            return
        }
        let remaining = length - state.buffer.count
        state.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { state.buffer.append(data) }
            if state.buffer.count >= length {
                self.readBody(state, length: length, version: version)
            } else if error != nil || isComplete {
                self.close(state)
            } else {
                self.readBody(state, length: length, version: version)
            }
        }
    }

    private func process(_ state: MCPConnection, body: Data, version: String) {
        // 与 Python 一致：先按 UTF-8 严格解码，再解析 JSON。
        guard String(data: body, encoding: .utf8) != nil, let message = try? JSONValue.parse(body) else {
            reply(state, 400, ["jsonrpc": .string("2.0"),
                               "error": .object(["code": .int(-32700), "message": .string("Parse error")])])
            return
        }
        let dispatch = self.dispatch
        Task {
            let response = await dispatch(message, version)
            self.queue.async { self.respond(state, response) }
        }
    }

    private func respond(_ state: MCPConnection, _ response: JSONObject?) {
        guard let response else {
            reply(state, 202)
            return
        }
        if case .object(let error)? = response["error"], case .int(let code)? = error["code"], code == -32600 {
            reply(state, 400, response)
        } else {
            reply(state, 200, response)
        }
    }

    // MARK: 响应

    private func reply(_ state: MCPConnection, _ code: Int, _ body: JSONObject? = nil,
                       headers: [(String, String)] = []) {
        state.requestRead = true
        var payload = Data()
        if let body {
            payload = (try? JSONValue.object(body).serialized())
                ?? Data(#"{"error":"Response encoding failed"}"#.utf8)
        }
        var head = "HTTP/1.1 \(code) \(Self.reason(code))\r\n"
        if !payload.isEmpty { head += "Content-Type: application/json; charset=utf-8\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        state.connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            self?.close(state)
        })
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        default: return "Internal Server Error"
        }
    }
}
