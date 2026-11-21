import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// 便单 Web OAuth 客户端与官网中转的固定配置（与 Python 参考实现相同）。
enum OAuthConfig {
    static let authorizeURL = "https://oauth-login.cloud.huawei.com/oauth2/v3/authorize"
    static let tokenURL = URL(string: "https://oauth-login.cloud.huawei.com/oauth2/v3/token")!
    static let clientID = "5765880207852987515"
    /// 已登记回调。换码时 redirect_uri 仍填这个官网地址。
    static let redirectURI = "https://www.biandangroup.com/#/biandan_online"
    static let relayHost = "127.0.0.1"
    static let relayPort: UInt16 = 42681
    static let relayPath = "/biandan/callback"
    /// 交出授权码后，回调页把地址换成这里（不再带授权码），刷新也只显示进度。
    static let donePath = "/biandan/done"
    /// 回调页轮询登录进度的接口，需要带会话令牌 s。
    static let statusPath = "/biandan/status"
    static let statePrefix = "biandan-local-v1."
    static let scope = "openid profile"
    static let callbackTimeout: TimeInterval = 180
    /// 交出授权码后，监听最多再保留这么久，供回调页显示进度。
    static let progressServingLimit: TimeInterval = 600

    static let renewalRefreshURL = URL(string: "https://auth.biandangroup.com/v1/refresh")!
    static let renewalDeviceURL = URL(string: "https://auth.biandangroup.com/v1/device")!
}

enum AuthError: Error, LocalizedError, Equatable {
    case notSignedIn
    case denied
    case timedOut
    case cancelled
    case portUnavailable
    /// 42681 已被其他程序监听（最常见的是正在等待授权的 Python 版便单 MCP）。
    case portInUse
    /// 监听因其他原因失败，附系统错误。
    case listenerFailed(String)
    case reauthorizationRequired
    case renewalUnavailable(status: Int?)
    case invalidResponse(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "尚未登录华为账号。"
        case .denied: return "华为没有授予授权。"
        case .timedOut: return "等待华为授权超时，请重新登录。"
        case .cancelled: return "已取消登录。"
        case .portUnavailable:
            return "无法在本机 127.0.0.1:42681 接收授权回调。请先关闭正在等待授权的便单 MCP，再重试。"
        case .portInUse:
            return "本机端口 42681 已被其他程序占用，最常见的是正在等待授权的 Python 版便单 MCP。"
                + "请先关闭它再重试；可在终端运行 lsof -nP -iTCP:42681 -sTCP:LISTEN 查看占用的进程。"
        case .listenerFailed(let detail):
            return "无法在本机 127.0.0.1:42681 接收授权回调（\(detail)）。请稍后重试。"
        case .reauthorizationRequired: return "华为授权已过期或被撤销，请重新登录。"
        case .renewalUnavailable(let status):
            return "便单续期服务暂时不可用" + (status.map { "（HTTP \($0)）" } ?? "") + "，请稍后重试。"
        case .invalidResponse(let detail): return detail
        case .storage(let detail): return detail
        }
    }
}

/// 回环端口探测。NWListener 开了 allowLocalEndpointReuse 时，端口被占用报的是 EINVAL 而不是 EADDRINUSE，
/// 不能只看它的错误码，所以直接用 BSD socket 试绑一次。
enum LoopbackPort {
    /// 试绑 127.0.0.1:port（带 SO_REUSEADDR，TIME_WAIT 残留不算占用）；EADDRINUSE 表示已有程序在监听。
    static func isInUse(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == EADDRINUSE
    }
}

extension AuthError {
    /// 把回环监听的失败分类：端口被占用单独提示，其他错误附上系统描述。
    /// 传入 port 时先实际探测端口，避免 NWListener 报 EINVAL 时漏判。
    static func listenerFailure(_ error: Error?, port: UInt16? = nil) -> AuthError {
        if let port, LoopbackPort.isInUse(port) { return .portInUse }
        if let error = error as? NWError, case .posix(let code) = error {
            return code == .EADDRINUSE ? .portInUse : .listenerFailed(error.localizedDescription)
        }
        if let code = (error as NSError?).flatMap({ $0.domain == NSPOSIXErrorDomain ? $0.code : nil }),
           code == Int(EADDRINUSE) {
            return .portInUse
        }
        return error.map { .listenerFailed($0.localizedDescription) } ?? .portUnavailable
    }
}

// MARK: - PKCE

enum PKCE {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 对应 Python `secrets.token_urlsafe(n)`：n 字节随机数的无填充 Base64URL。
    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "系统随机数不可用")
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}

// MARK: - 本机回调监听

/// 在 127.0.0.1:42681 等待官网中转回来的授权回调，对应 Python `receive_loopback_code`。
/// 收到授权码后监听不立即关闭：回调页继续轮询 /biandan/status 显示换取令牌和首次同步的进度，
/// 登录流程结束后由 App 调用 stopServing 关闭（最长保留 progressServingLimit）。
final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.racore.biandan.oauth-loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    /// 授权码等待已经有结果（成功、拒绝、超时或取消）。
    private var finished = false
    /// 授权码已交给 App；之后监听只用于显示登录进度。
    private var codeDelivered = false
    private let state: String
    let progress: LoginProgress
    /// 回调页轮询进度用的会话令牌，防止本机其他页面读取状态。
    let session = PKCE.randomToken(bytes: 18)

    private static let staticCSP = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; "
        + "form-action 'none'; frame-ancestors 'none'"

    init(state: String, progress: LoginProgress) {
        self.state = state
        self.progress = progress
    }

    /// 监听就绪后调用 `onReady`（用于打开浏览器），收到合法回调后返回授权码。
    func waitForCode(onReady: @escaping @Sendable () -> Void) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async { self.start(continuation: continuation, onReady: onReady) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            self.finish(.failure(AuthError.cancelled))
            self.stopListening()
        }
    }

    /// 登录流程结束后再保留 `delay` 秒，让回调页拿到最终状态，然后关闭监听。
    func stopServing(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(delay, 0)) {
            self.stopListening()
        }
    }

    /// 只在 queue 上调用。
    private func stopListening() {
        listener?.cancel()
        listener = nil
    }

    private func start(continuation: CheckedContinuation<String, Error>, onReady: @escaping @Sendable () -> Void) {
        if finished {
            continuation.resume(throwing: AuthError.cancelled)
            return
        }
        self.continuation = continuation
        // 先探测端口：被占用时直接提示，不打开浏览器。
        if LoopbackPort.isInUse(OAuthConfig.relayPort) {
            finish(.failure(AuthError.portInUse))
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                         port: NWEndpoint.Port(rawValue: OAuthConfig.relayPort)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    onReady()
                case .failed(let error), .waiting(let error):
                    self.finish(.failure(AuthError.listenerFailure(error, port: OAuthConfig.relayPort)))
                    self.stopListening()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + OAuthConfig.callbackTimeout) { [weak self] in
                guard let self, !self.codeDelivered else { return }
                self.finish(.failure(AuthError.timedOut))
                self.stopListening()
            }
        } catch {
            finish(.failure(AuthError.listenerFailure(error, port: OAuthConfig.relayPort)))
        }
    }

    /// 只在 queue 上调用。成功时保留监听（供进度页轮询），失败时关闭。
    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        if case .success = result {
            codeDelivered = true
            queue.asyncAfter(deadline: .now() + OAuthConfig.progressServingLimit) {
                self.stopListening()
            }
        } else {
            stopListening()
        }
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // 与 Python 一样给每个连接 3 秒读取时间。
        queue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(connection, head: buffer[..<end.lowerBound])
            } else if error != nil || isComplete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let expectedHost = "\(OAuthConfig.relayHost):\(OAuthConfig.relayPort)"
        // 校验 Host，防止 DNS 重绑定的网页访问本机接口。
        guard requestLine.count >= 2, requestLine[0] == "GET", host == expectedHost else {
            respond(connection, status: "404 Not Found", page: .notFound)
            return
        }
        let target = String(requestLine[1])
        guard !target.contains("#") else {
            respond(connection, status: "404 Not Found", page: .notFound)
            return
        }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? ""
        let query = HTTPTransport.parseQuery(parts.count > 1 ? String(parts[1]) : nil)
        switch path {
        case OAuthConfig.relayPath:
            handleCallback(connection, query: query)
        case OAuthConfig.donePath where codeDelivered:
            respondProgressPage(connection)
        case OAuthConfig.statusPath where codeDelivered:
            let tokens = query["s"] ?? []
            if tokens.count == 1, PKCE.constantTimeEqual(tokens[0], session) {
                respond(connection, status: "200 OK", contentType: "application/json; charset=utf-8",
                        body: progress.json(), csp: "default-src 'none'")
            } else {
                respond(connection, status: "403 Forbidden", page: .notFound)
            }
        default:
            respond(connection, status: "404 Not Found", page: .notFound)
        }
    }

    private func handleCallback(_ connection: NWConnection, query: [String: [String]]) {
        let states = query["state"] ?? []
        guard states.count == 1, PKCE.constantTimeEqual(states[0], state) else {
            respond(connection, status: "400 Bad Request", page: .rejected)
            return
        }
        if codeDelivered {
            // 刷新同一个回调地址：只显示进度，不重复交出授权码。
            respondProgressPage(connection)
            return
        }
        guard !finished else {
            respond(connection, status: "400 Bad Request", page: .rejected)
            return
        }
        if query["error"] != nil {
            respond(connection, status: "400 Bad Request", page: .denied)
            finish(.failure(AuthError.denied))
            return
        }
        let codes = query["code"] ?? []
        guard codes.count == 1, !codes[0].isEmpty else {
            respond(connection, status: "400 Bad Request", page: .rejected)
            return
        }
        finish(.success(codes[0]))
        respondProgressPage(connection)
    }

    // MARK: 响应

    private func respondProgressPage(_ connection: NWConnection) {
        let nonce = PKCE.randomToken(bytes: 16)
        let html = AuthCallbackPage.progressHTML(progress.snapshot, session: session, nonce: nonce)
        let csp = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; "
            + "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        respond(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8), csp: csp)
    }

    private func respond(_ connection: NWConnection, status: String, page: AuthCallbackPage.Kind) {
        respond(connection, status: status, contentType: "text/html; charset=utf-8",
                body: Data(AuthCallbackPage.html(page).utf8), csp: Self.staticCSP)
    }

    private func respond(_ connection: NWConnection, status: String, contentType: String, body: Data, csp: String) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: \(csp)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - 授权流程

/// 一次完整的浏览器授权：生成 PKCE → 打开授权页 → 收回调 → 换令牌。
/// 对应 Python `exchange_authorization(WEB_CLIENT_ID, WEB_REDIRECT_URI, offline=True)`。
/// `progress` 由 App 继续更新到首次同步结束，回调页实时显示。
final class OAuthFlow: @unchecked Sendable {
    let verifier: String
    let state: String
    let progress: LoginProgress
    private let receiver: LoopbackReceiver

    init() {
        let verifier = PKCE.randomToken(bytes: 48)
        let state = OAuthConfig.statePrefix + PKCE.randomToken(bytes: 32)
        let progress = LoginProgress()
        self.verifier = verifier
        self.state = state
        self.progress = progress
        receiver = LoopbackReceiver(state: state, progress: progress)
    }

    var authorizationURL: URL {
        let query = HTTPTransport.formEncode([
            ("response_type", "code"),
            ("client_id", OAuthConfig.clientID),
            ("redirect_uri", OAuthConfig.redirectURI),
            ("scope", OAuthConfig.scope),
            ("state", state),
            ("code_challenge", PKCE.challenge(for: verifier)),
            ("code_challenge_method", "S256"),
            ("access_type", "offline"),
        ])
        return URL(string: OAuthConfig.authorizeURL + "?" + query)!
    }

    /// 返回华为令牌响应（access_token、refresh_token、expires_in，可能含 id_token）。
    func run() async throws -> JSONObject {
        let url = authorizationURL
        let code = try await receiver.waitForCode {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        progress.update(.exchanging, detail: "正在用授权码换取华为令牌…")
        let form = HTTPTransport.formEncode([
            ("grant_type", "authorization_code"),
            ("client_id", OAuthConfig.clientID),
            ("redirect_uri", OAuthConfig.redirectURI),
            ("code", code),
            ("code_verifier", verifier),
        ])
        return try await HTTPTransport.requestJSON(
            method: "POST", url: OAuthConfig.tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8)
        )
    }

    func cancel() {
        receiver.cancel()
    }

    /// 登录流程结束：`delay` 秒后关闭本机监听。
    func finishServing(after delay: TimeInterval) {
        receiver.stopServing(after: delay)
    }
}
