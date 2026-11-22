import AppKit
import Combine
import Foundation
import Sparkle

// MARK: - 自动更新（Sparkle 2）
//
// 版本列表 appcast.xml 和更新包放在自己的服务器上（Info.plist 的 SUFeedURL），每个更新包都用 EdDSA 私钥签名，
// App 只安装签名和 SUPublicEDKey 对得上、并且和当前版本同一个 Developer ID 签名的包。
// 默认每天自动检查一次，发现新版本弹窗显示更新说明，装不装由用户决定；也可以打开「自动下载并安装」。
// 开发版（标识符以 .dev 结尾）、swift run 直接跑的可执行文件、没配置更新地址的包不启用，免得被正式版覆盖。

/// 测试版渠道开关（appcast 里标了 sparkle:channel=beta 的版本只推给打开了它的人）。
let appUpdateBetaKey = "biandan.update.beta"

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case found(String)
    case failed(String)
}

@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// 用不了更新的原因；nil 表示可以用。
    let unavailableReason: String?
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    private(set) var status: AppUpdateStatus = .idle

    /// 每天自动检查（Sparkle 自己记在偏好设置里）。
    var automaticChecks = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    /// 发现新版本后在后台下载，退出时安装，不再弹窗询问。
    var automaticDownloads = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticDownloads }
    }

    /// 也接收测试版。
    var betaChannel = UserDefaults.standard.bool(forKey: appUpdateBetaKey) {
        didSet { UserDefaults.standard.set(betaChannel, forKey: appUpdateBetaKey) }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = AppUpdaterDelegate()
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var started = false

    static var feedURL: String? { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if Bundle.main.bundleURL.pathExtension != "app" {
            unavailableReason = "直接运行的可执行文件没有更新功能，用打包好的 App 才能检查更新"
        } else if bundleID.hasSuffix(".dev") {
            unavailableReason = "开发版不检查更新，免得被正式版覆盖"
        } else if info["SUFeedURL"] == nil || info["SUPublicEDKey"] == nil {
            unavailableReason = "这个安装包没有配置更新地址"
        } else {
            unavailableReason = nil
        }
        guard unavailableReason == nil else { return }
        delegate.owner = self
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate,
                                                      userDriverDelegate: nil)
        self.controller = controller
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        automaticDownloads = controller.updater.automaticallyDownloadsUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    /// 启动时调用一次：开始按计划检查。
    func start() {
        guard let controller, !started else { return }
        started = true
        controller.startUpdater()
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    /// 「检查更新」按钮和菜单：有新版本弹窗，没有也会告诉你已是最新。
    func checkForUpdates() {
        guard let controller else { return }
        start()
        status = .checking
        controller.checkForUpdates(nil)
    }

    // MARK: 回调（Sparkle 在主线程调用）

    fileprivate func found(_ version: String) {
        status = .found(version)
    }

    fileprivate func finished(found: Bool, error: Error?) {
        lastCheck = controller?.updater.lastUpdateCheckDate ?? Date()
        guard let error else {
            if !found, status == .checking { status = .upToDate }
            return
        }
        let ns = error as NSError
        switch ns.code {
        case 1001:  // SUNoUpdateError：已是最新
            status = .upToDate
        case 4007:  // SUInstallationCanceledError：用户选了稍后
            break
        default:
            status = .failed(Self.describe(ns))
        }
    }

    static func describe(_ error: NSError) -> String {
        switch error.code {
        case 1000, 2001, 2002:
            return "更新信息读不出来（服务器上的 appcast.xml 可能还没放好）"
        case 3001, 3002:
            return "更新包的签名对不上，已拒绝安装"
        default:
            return error.localizedDescription
        }
    }
}

final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var owner: AppUpdater?
    private var foundInCycle = false

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: appUpdateBetaKey) ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundInCycle = true
        let version = item.displayVersionString
        MainActor.assumeIsolated { owner?.found(version) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let found = foundInCycle
        foundInCycle = false
        MainActor.assumeIsolated { owner?.finished(found: found, error: error) }
    }
}
