import AppKit
import Foundation

/// 本机 MCP 服务的运行状态。
enum MCPStatus: Equatable {
    case off
    case starting
    case running
    case failed(String)

    var title: String {
        switch self {
        case .off: return "未启用"
        case .starting: return "正在启动"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// 本机 MCP 服务：与界面共用同一个业务服务（写操作排队执行），写入后立即更新本地缓存和界面。
extension AppModel {
    func startMCP() {
        guard mcpServer == nil else { return }
        let token: String
        do {
            token = try MCPAccessKey.load()
        } catch {
            mcpStatus = .failed(error.localizedDescription)
            return
        }
        mcpAccessKey = token
        let generation = UUID()
        mcpGeneration = generation
        let dispatcher = MCPDispatcher(runner: makeMCPRunner())
        let server = MCPHTTPServer(
            token: token, versions: MCPDispatcher.httpVersions,
            dispatch: { message, version in await dispatcher.handle(message, version: version) },
            onState: { [weak self] state in
                Task { @MainActor in self?.mcpStateChanged(state, generation: generation) }
            })
        mcpServer = server
        mcpStatus = .starting
        server.start()
    }

    func stopMCP() {
        mcpGeneration = nil
        mcpServer?.stop()
        mcpServer = nil
        mcpStatus = .off
    }

    func restartMCP() {
        stopMCP()
        if mcpEnabled { startMCP() }
    }

    /// 拷贝给 Claude、Codex 等客户端用的配置（含访问密钥）。
    func copyMCPConfig() {
        do {
            let token = try mcpAccessKey ?? MCPAccessKey.load()
            mcpAccessKey = token
            let text = MCPAccessKey.clientConfig(port: MCPHTTP.defaultPort, token: token)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            mcpNotice = "已拷贝客户端配置。配置里含访问密钥，请勿分享。"
        } catch {
            mcpNotice = "读取本机 MCP 密钥失败：\(error.localizedDescription)"
        }
    }

    private func mcpStateChanged(_ state: MCPHTTPServer.State, generation: UUID) {
        guard mcpGeneration == generation else { return }
        switch state {
        case .ready:
            mcpStatus = .running
        case .failed(let message):
            mcpStatus = .failed(message)
            mcpServer = nil
            mcpGeneration = nil
        case .stopped:
            mcpStatus = .off
        }
    }

    private func makeMCPRunner() -> MCPDispatcher.Runner {
        let service = self.service
        return { [weak self] name, arguments in
            do {
                let (value, changes) = try await service.mcpExecute(name, arguments)
                await self?.mcpFinished(changes, error: nil)
                return value
            } catch let failure as MCPCallFailure {
                await self?.mcpFinished(failure.changes, error: failure.underlying)
                throw failure
            }
        }
    }

    private func mcpFinished(_ changes: ChangeSet, error: Error?) {
        mcpCallCount += 1
        mcpLastCallAt = Date()
        applyLocal(changes)
        if let error, Self.mcpNeedsSignIn(error), authState == .signedIn {
            expireSession()
        }
    }

    private static func mcpNeedsSignIn(_ error: Error) -> Bool {
        if let failure = error as? OperationFailure { return failure.needsSignIn }
        if let failure = error as? MCPToolError { return failure.details["action"] == .string(MCPDispatcher.signInAction) }
        if let auth = error as? AuthError { return auth == .reauthorizationRequired || auth == .notSignedIn }
        return false
    }
}
