import Foundation
import os

/// 华为帐号「获取用户信息」：用访问令牌查昵称和头像。
enum AccountProfileFetcher {
    static let url = URL(string: "https://account.cloud.huawei.com/rest.php?nsp_svc=GOpen.User.getInfo")!

    static func fetch(accessToken: String) async throws -> AccountProfile? {
        let form = HTTPTransport.formEncode([("access_token", accessToken), ("getNickName", "1")])
        let reply = try await HTTPTransport.requestJSON(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8))
        return AccountProfile.from(userInfo: reply)
    }
}

extension AppModel {
    /// 昵称只在登录时从 id_token 读一次，续期不再返回。偏好和钥匙串里都没有时（比如偏好文件被删），
    /// 用当前访问令牌向华为帐号查一次；失败不打扰，下次启动再试。日志里不写令牌。
    func refreshProfileIfNeeded() async {
        guard authState == .signedIn, profile == .placeholder, !DebugFlags.offline else { return }
        let log = Logger(subsystem: "ai.racore.BiandanMac", category: "account")
        do {
            let token = try await tokens.accessToken()
            guard let fetched = try await AccountProfileFetcher.fetch(accessToken: token) else {
                log.info("华为帐号没有返回昵称")
                return
            }
            guard authState == .signedIn else { return }
            fetched.save()
            profile = fetched
            log.info("已从华为帐号恢复昵称和头像")
        } catch {
            log.error("查询华为帐号资料失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
