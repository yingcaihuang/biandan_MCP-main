import CryptoKit
import Foundation
import Security

// MARK: - 钥匙串凭据

/// 刷新令牌与便单设备凭据，作为一项钥匙串条目一起原子保存。
struct StoredCredential: Codable, Equatable, Sendable {
    var refreshToken: String
    var deviceGrant: String?

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case deviceGrant = "device_grant"
    }
}

struct CredentialStore: Sendable {
    let service = "ai.racore.BiandanMac"
    let account: String

    /// 与 Python 一样按续期地址区分凭据：`huawei-refresh-<sha256(endpoint)[:24]>`。
    init(endpoint: URL = OAuthConfig.renewalRefreshURL) {
        let digest = SHA256.hash(data: Data(endpoint.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        account = "huawei-refresh-" + hex.prefix(24)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> StoredCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 16_384 else {
            throw AuthError.storage("无法读取本机保存的华为凭据（\(status)）")
        }
        guard let credential = try? JSONDecoder().decode(StoredCredential.self, from: data),
              TokenProvider.isValidToken(credential.refreshToken),
              credential.deviceGrant.map(TokenProvider.isValidToken) ?? true else {
            throw AuthError.storage("本机保存的华为凭据无效")
        }
        return credential
    }

    func save(_ credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "便单 华为账号凭据"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AuthError.storage("无法保存华为凭据，请检查钥匙串后重试（\(status)）")
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.storage("无法清除本机华为凭据（\(status)）")
        }
    }
}

// MARK: - 账户资料（展示用，不含凭据）

struct AccountProfile: Codable, Equatable, Sendable {
    var displayName: String
    var avatarURL: String?

    static let placeholder = AccountProfile(displayName: "华为账号", avatarURL: nil)
    private static let defaultsKey = "biandan.accountProfile"

    /// 从 id_token 的 payload 读取昵称和头像；签名不校验，只用于显示。
    static func from(idToken: String?) -> AccountProfile? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONValue.parseObject(data) else { return nil }
        let name = ["display_name", "nickname", "name", "email"].lazy.compactMap { claims.string($0) }
            .first { !$0.isEmpty }
        guard let name else { return nil }
        return AccountProfile(displayName: name, avatarURL: claims.string("picture"))
    }

    static func loadSaved() -> AccountProfile? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(AccountProfile.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AccountProfile.defaultsKey)
        }
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

// MARK: - 访问令牌提供者

/// 对应 Python `RenewingAuthorization(device_gate=True)`。
/// - 访问令牌只保存在内存，按 `expires_in` 提前 min(60, 10%) 过期。
/// - 首次续期调 `/v1/device` 取得设备凭据，之后带设备凭据调 `/v1/refresh`。
/// - 并发请求合并成一次刷新；401 时用 `rejected` 强制换新令牌。
actor TokenProvider {
    private let store: CredentialStore
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var credential: StoredCredential?
    private var refreshTask: Task<String, Error>?

    init(store: CredentialStore = CredentialStore()) {
        self.store = store
        // 读取失败按未登录处理，界面会提示重新登录。
        credential = try? store.load()
    }

    static func isValidToken(_ value: String?) -> Bool {
        guard let value, (1...4096).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { (33...126).contains($0) }
    }

    var isSignedIn: Bool { credential != nil }

    // MARK: 登录 / 退出

    /// 接收浏览器授权后的华为令牌响应。
    @discardableResult
    func completeSignIn(with reply: JSONObject) throws -> AccountProfile {
        accessToken = nil
        credential = nil
        try accept(reply)
        let profile = AccountProfile.from(idToken: reply.string("id_token")) ?? .placeholder
        profile.save()
        return profile
    }

    func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        accessToken = nil
        expiresAt = .distantPast
        credential = nil
        AccountProfile.clearSaved()
        try store.clear()
    }

    // MARK: 取令牌

    func accessToken(rejected: String? = nil) async throws -> String {
        if let token = accessToken, token != rejected, Date() < expiresAt {
            return token
        }
        if let task = refreshTask {
            return try await task.value
        }
        guard let current = credential else { throw AuthError.notSignedIn }
        let task = Task { try await self.renew(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func renew(_ current: StoredCredential) async throws -> String {
        var headers = ["Content-Type": "application/json"]
        let endpoint: URL
        if let grant = current.deviceGrant {
            headers["Authorization"] = "Bearer \(grant)"
            endpoint = OAuthConfig.renewalRefreshURL
        } else {
            endpoint = OAuthConfig.renewalDeviceURL
        }
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": current.refreshToken])
        let reply: JSONObject
        do {
            reply = try await HTTPTransport.requestJSON(method: "POST", url: endpoint, headers: headers, body: body)
        } catch let error as CloudError {
            if error.isReauthorizationRequired {
                accessToken = nil
                expiresAt = .distantPast
                credential = nil
                try? store.clear()
                throw AuthError.reauthorizationRequired
            }
            // 403 / 429 / 503 / 网络错误：保留授权状态，稍后重试。
            throw AuthError.renewalUnavailable(status: error.status)
        }
        guard let grant = reply.string("device_grant"), !grant.isEmpty else {
            throw AuthError.invalidResponse("便单续期服务没有返回设备凭据")
        }
        try accept(reply)
        return accessToken!
    }

    /// 校验并接收令牌；刷新令牌或设备凭据变化时立即写入钥匙串。
    private func accept(_ reply: JSONObject) throws {
        let token = reply.string("access_token")
        let refresh = reply.string("refresh_token") ?? credential?.refreshToken
        let grant = reply.string("device_grant") ?? credential?.deviceGrant
        guard TokenProvider.isValidToken(token), TokenProvider.isValidToken(refresh),
              case .int(let rawExpiry)? = reply["expires_in"], rawExpiry > 0 else {
            throw AuthError.invalidResponse("华为授权没有返回可用的令牌和有效期")
        }
        if let grant, !TokenProvider.isValidToken(grant) {
            throw AuthError.invalidResponse("便单续期服务返回了无效的设备凭据")
        }
        let next = StoredCredential(refreshToken: refresh!, deviceGrant: grant)
        if next != credential {
            try store.save(next)
            credential = next
        }
        let expiresIn = Double(rawExpiry)
        accessToken = token
        expiresAt = Date().addingTimeInterval(expiresIn - min(60, expiresIn / 10))
    }
}
