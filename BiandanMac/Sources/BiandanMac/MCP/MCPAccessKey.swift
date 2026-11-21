import Foundation

struct MCPAccessKeyError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 本机 MCP 访问密钥，对应 Python `biandan_http.local_access_key`。
/// 与 Python 版共用 `~/.biandan-mcp/http-access-key`，已配置好的 AI 客户端无需修改。
enum MCPAccessKey {
    static let tokenLength = 43
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// 与 Python 一致：`BIANDAN_MCP_STATE_DIR` 优先，否则为 `~/.biandan-mcp`。
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BIANDAN_MCP_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".biandan-mcp", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("http-access-key") }

    static func isValid(_ token: String) -> Bool {
        token.count == tokenLength && token.allSatisfy { alphabet.contains($0) }
    }

    /// 读取已有密钥；没有时新建（O_EXCL + 0600，避免与 Python 进程同时创建时互相覆盖）。
    static func load() throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = fileURL.path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            let code = errno
            guard code == EEXIST else {
                throw MCPAccessKeyError("无法创建本机 MCP 密钥文件：\(String(cString: strerror(code)))")
            }
            for _ in 0..<10 {
                let text = (try? String(contentsOfFile: path, encoding: .ascii)) ?? ""
                let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isValid(token) { return token }
                // 另一个进程可能刚创建了文件、还没写入内容。
                if !token.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw MCPAccessKeyError("本机 MCP 密钥文件内容无效：\(path)")
        }
        let token = generate()
        let data = Data(token.utf8)
        let written = data.withUnsafeBytes { buffer in write(fd, buffer.baseAddress, buffer.count) }
        close(fd)
        guard written == data.count else {
            throw MCPAccessKeyError("写入本机 MCP 密钥文件失败：\(path)")
        }
        return token
    }

    /// 32 字节随机数的 base64url（无填充），与 Python `secrets.token_urlsafe(32)` 等长。
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 给 AI 客户端用的配置，对应 Python `http_config`。
    static func clientConfig(port: UInt16, token: String) -> String {
        let server: JSONObject = [
            "url": .string("http://127.0.0.1:\(port)/mcp"),
            "headers": .object(["Authorization": .string("Bearer \(token)")]),
        ]
        return JSONValue.object(["mcpServers": .object(["biandan": .object(server)])]).serializedString(pretty: true)
    }
}
