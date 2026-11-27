import Foundation
import Network
import XCTest
@testable import BiandanMac

/// 原始 TCP 客户端：发一个完整 HTTP 请求，读到服务端关闭连接为止。所有回调都在自己的队列上。
private final class RawHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "biandan.mcp.test.client")
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    init(port: UInt16) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func exchange(_ request: Data, timeout: TimeInterval = 5) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.connection.send(content: request, completion: .contentProcessed { _ in self.receive() })
                    case .failed(let error):
                        self.finish(.failure(error))
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(URLError(.timedOut))) }
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            if isComplete || error != nil {
                self.finish(.success(self.buffer))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

private struct RawResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    var json: JSONObject? { JSONValue.parseObject(String(decoding: body, as: UTF8.self)) }

    var errorCode: JSONValue? {
        if case .object(let error)? = json?["error"] { return error["code"] }
        return nil
    }

    init(_ data: Data) {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            status = 0
            headers = [:]
            body = Data()
            return
        }
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        status = lines.first.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Int($0) } ?? 0
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = fields
        body = Data(data[range.upperBound...])
    }
}

/// 记录业务工具的并发度，用来校验云端工具串行执行。
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var calls = 0

    func enter() {
        current += 1
        calls += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [MCPHTTPServer.State] = []

    /// 记录状态，返回是否是第一条。
    func append(_ state: MCPHTTPServer.State) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        states.append(state)
        return states.count == 1
    }

    var first: MCPHTTPServer.State? {
        lock.lock()
        defer { lock.unlock() }
        return states.first
    }
}

/// 在随机端口启动真实的 MCPHTTPServer（业务工具用桩代替），通过原始 HTTP 验证与 Python 版一致的规则。
final class MCPHTTPServerTests: XCTestCase {
    private let token = MCPAccessKey.generate()
    private var server: MCPHTTPServer?
    private var port: UInt16 = 0

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func startServer(_ runner: @escaping MCPDispatcher.Runner = { name, arguments in
        ["tool": .string(name), "arguments": .object(arguments)]
    }) async throws {
        let dispatcher = MCPDispatcher(runner: runner)
        for _ in 0..<5 {
            let candidate = UInt16.random(in: 50_000...59_999)
            let settled = expectation(description: "server \(candidate)")
            let log = StateLog()
            let instance = MCPHTTPServer(
                port: candidate, token: token, versions: MCPDispatcher.httpVersions,
                dispatch: { message, version in await dispatcher.handle(message, version: version) },
                onState: { state in
                    if log.append(state) { settled.fulfill() }
                })
            instance.start()
            await fulfillment(of: [settled], timeout: 5)
            if log.first == .ready {
                server = instance
                port = candidate
                return
            }
            instance.stop()
        }
        XCTFail("连续 5 个随机端口都无法监听")
    }

    private func send(method: String = "POST", path: String = "/mcp", host: String? = nil,
                      authorization: String?? = .none, contentType: String? = "application/json",
                      version: String? = nil, origin: String? = nil, extra: [String] = [],
                      body: String? = nil, includeLength: Bool = true) async throws -> RawResponse {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(port)")"]
        let auth: String? = authorization ?? "Bearer \(token)"
        if let auth { lines.append("Authorization: \(auth)") }
        if let contentType { lines.append("Content-Type: \(contentType)") }
        if let version { lines.append("MCP-Protocol-Version: \(version)") }
        if let origin { lines.append("Origin: \(origin)") }
        lines += extra
        let payload = Data((body ?? "").utf8)
        if includeLength && method == "POST" { lines.append("Content-Length: \(payload.count)") }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + payload
        return RawResponse(try await RawHTTPClient(port: port).exchange(request))
    }

    private func rpc(_ body: String, version: String? = "2025-06-18") async throws -> RawResponse {
        try await send(version: version, body: body)
    }

    // MARK: 正常流程

    func testInitializeListAndCallOverHTTP() async throws {
        try await startServer()

        let initialize = try await rpc(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(initialize.status, 200)
        XCTAssertEqual(initialize.headers["cache-control"], "no-store")
        XCTAssertTrue(initialize.headers["content-type"]?.hasPrefix("application/json") ?? false)
        guard case .object(let result)? = initialize.json?["result"] else { return XCTFail("initialize 没有 result") }
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))

        let list = try await rpc(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .object(let listResult)? = list.json?["result"], case .array(let tools)? = listResult["tools"] else {
            return XCTFail("tools/list 没有工具数组")
        }
        XCTAssertEqual(tools.count, 35)

        let call = try await rpc(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"biandan_get_task","arguments":{"task_id":"7"}}}"#)
        XCTAssertEqual(call.status, 200)
        guard case .object(let callResult)? = call.json?["result"],
              case .object(let structured)? = callResult["structuredContent"] else {
            return XCTFail("tools/call 没有 structuredContent")
        }
        XCTAssertEqual(callResult["isError"], .bool(false))
        XCTAssertEqual(structured["tool"], .string("biandan_get_task"))
        XCTAssertEqual(structured["arguments"], .object(["task_id": .string("7")]))

        // 不带协议版本头时按 2025-03-26 处理：不返回 structuredContent。
        let legacy = try await rpc(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"biandan_local_today"}}"#,
                                   version: nil)
        guard case .object(let legacyResult)? = legacy.json?["result"] else { return XCTFail("旧版本没有 result") }
        XCTAssertNil(legacyResult["structuredContent"])

        let note = try await rpc(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)
    }

    // MARK: 来源与密钥

    func testHostOriginAndPathChecks() async throws {
        try await startServer()
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

        let localhost = try await send(host: "localhost:\(port)", body: ping)
        XCTAssertEqual(localhost.status, 200)
        let foreign = try await send(host: "evil.example:\(port)", body: ping)
        XCTAssertEqual(foreign.status, 403)
        let otherPort = try await send(host: "127.0.0.1:1", body: ping)
        XCTAssertEqual(otherPort.status, 403)
        let crossSite = try await send(origin: "https://evil.example", body: ping)
        XCTAssertEqual(crossSite.status, 403)
        let sameOrigin = try await send(origin: "http://127.0.0.1:\(port)", body: ping)
        XCTAssertEqual(sameOrigin.status, 200)
        let path = try await send(path: "/other", body: ping)
        XCTAssertEqual(path.status, 404)
        let query = try await send(path: "/mcp?x=1", body: ping)
        XCTAssertEqual(query.status, 404)
    }

    func testAuthorization() async throws {
        try await startServer()
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

        let missing = try await send(authorization: .some(nil), body: ping)
        XCTAssertEqual(missing.status, 401)
        XCTAssertTrue(missing.headers["www-authenticate"]?.contains("Biandan local MCP") ?? false)
        let wrong = try await send(authorization: "Bearer \(MCPAccessKey.generate())", body: ping)
        XCTAssertEqual(wrong.status, 401)
        let scheme = try await send(authorization: "Basic \(token)", body: ping)
        XCTAssertEqual(scheme.status, 401)
        // 未授权的 GET 也先返回 401，不暴露 405。
        let get = try await send(method: "GET", authorization: .some(nil))
        XCTAssertEqual(get.status, 401)
    }

    // MARK: 请求格式

    func testMethodAndBodyRules() async throws {
        try await startServer()
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

        let get = try await send(method: "GET")
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.headers["allow"], "POST")
        let delete = try await send(method: "DELETE")
        XCTAssertEqual(delete.status, 405)

        let media = try await send(contentType: "text/plain", body: ping)
        XCTAssertEqual(media.status, 415)
        let charset = try await send(contentType: "application/json; charset=utf-8", body: ping)
        XCTAssertEqual(charset.status, 200)
        let version = try await send(version: "2024-11-05", body: ping)
        XCTAssertEqual(version.status, 400)

        let noLength = try await send(includeLength: false)
        XCTAssertEqual(noLength.status, 400)
        let chunked = try await send(extra: ["Transfer-Encoding: chunked"], body: ping)
        XCTAssertEqual(chunked.status, 400)
        let tooLarge = try await send(extra: ["Content-Length: \(MCPHTTP.maxBody + 1)"], includeLength: false)
        XCTAssertEqual(tooLarge.status, 413)

        let garbage = try await send(body: "{not json")
        XCTAssertEqual(garbage.status, 400)
        XCTAssertEqual(garbage.errorCode, .int(-32700))
        let invalid = try await send(body: #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(invalid.status, 400)
        XCTAssertEqual(invalid.errorCode, .int(-32600))
    }

    // MARK: 串行执行

    func testCloudToolsRunOneAtATime() async throws {
        let tracker = ConcurrencyTracker()
        try await startServer { _, _ in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 80_000_000)
            await tracker.leave()
            return ["ok": .bool(true)]
        }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"biandan_list_lists","arguments":{}}}"#
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask { try await self.rpc(body).status }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(statuses, Array(repeating: 200, count: 5))
        let calls = await tracker.calls
        let peak = await tracker.peak
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(peak, 1, "云端工具应串行执行")
    }
}
