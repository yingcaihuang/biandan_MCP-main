import AppKit
import Combine
import Foundation
import Sparkle

// MARK: - 自动更新（Sparkle 2）
//
// 版本列表 appcast.xml 和更新包放在自己的服务器上（Info.plist 的 SUFeedURL），每个更新包都用 EdDSA 私钥签名，
// App 只安装签名和 SUPublicEDKey 对得上、并且和当前版本同一个 Developer ID 签名的包。
// 界面不用 Sparkle 自带的窗口：AppUpdateUserDriver 把每一步报给 AppUpdater，显示在工具栏的更新按钮上
// （发现新版本、下载进度、下载异常、安装倒计时），点开是更新面板。
// 「自动下载并安装」是便单自己的开关（默认打开），不用 Sparkle 的 automaticallyDownloadsUpdates（那个静默下载、拿不到进度）：
// 发现新版本直接下载，下载完倒计时 60 秒后安装并重启；番茄钟计时中先等它结束。
// 开发版（标识符以 .dev 结尾）、swift run 直接跑的可执行文件、没配置更新地址的包不启用，免得被正式版覆盖。

/// 测试版渠道开关（appcast 里标了 sparkle:channel=beta 的版本只推给打开了它的人）。
let appUpdateBetaKey = "biandan.update.beta"
/// 自动下载并安装（便单自己的开关，没设置过时默认打开）。
/// 1.3.2 用的是 biandan.update.autoInstall，首次启动时会把 Sparkle 默认的「关」写进去，分不清是不是用户自己关的，
/// 所以换了键名：大家都从默认打开开始，旧键删掉。
let appUpdateAutoInstallKey = "biandan.update.autoDownloadInstall"
let appUpdateLegacyAutoInstallKey = "biandan.update.autoInstall"

enum AppUpdatePreferences {
    /// 没设置过就是打开。
    static func automaticDownloads(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: appUpdateAutoInstallKey) as? Bool ?? true
    }
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    /// 发现新版本，等用户决定。
    case found(String)
    /// expected 为 0 表示还不知道总大小。
    case downloading(version: String, received: UInt64, expected: UInt64)
    case extracting(version: String, progress: Double)
    /// 下载好了，到 deadline 自动安装并重启。
    case countdown(version: String, deadline: Date)
    /// 下载好了，等 reason（如「番茄钟结束」）之后再倒计时。
    case waiting(version: String, reason: String)
    case installing(String)
    /// 用户选了退出时再装。
    case installOnQuit(String)
    /// 检查更新失败。
    case failed(String)
    /// 下载或解压更新包失败。
    case downloadFailed(String)
}

extension AppUpdateStatus {
    static let countdownSeconds: TimeInterval = 60

    var version: String? {
        switch self {
        case .found(let v), .installing(let v), .installOnQuit(let v): return v
        case .downloading(let v, _, _), .extracting(let v, _), .countdown(let v, _), .waiting(let v, _): return v
        case .idle, .checking, .upToDate, .failed, .downloadFailed: return nil
        }
    }

    /// 正在下载或解压：这时出错算「下载异常」。
    var isDownloading: Bool {
        switch self {
        case .downloading, .extracting: return true
        default: return false
        }
    }

    /// 下载进度 0–1；还不知道总大小时为 nil。
    var downloadFraction: Double? {
        guard case .downloading(_, let received, let expected) = self, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
    }

    /// 工具栏进度环：下载进度或解压进度；nil 表示转圈。
    var ringFraction: Double? {
        switch self {
        case .downloading: return downloadFraction
        case .extracting(_, let progress): return min(max(progress, 0), 1)
        default: return nil
        }
    }

    /// 倒计时还剩几秒（向上取整）。
    func secondsLeft(at now: Date) -> Int {
        guard case .countdown(_, let deadline) = self else { return 0 }
        return max(Int(deadline.timeIntervalSince(now).rounded(.up)), 0)
    }

    func countdownFraction(at now: Date) -> Double {
        Double(secondsLeft(at: now)) / Self.countdownSeconds
    }

    /// 工具栏按钮上的文字；nil 时只显示图标。
    func toolbarTitle(at now: Date) -> String? {
        switch self {
        case .idle, .checking, .upToDate, .failed: return nil
        case .found(let v): return "发现新版本 \(v)"
        case .downloading:
            guard let fraction = downloadFraction else { return "下载中…" }
            return "下载中 \(Int((fraction * 100).rounded(.down)))%"
        case .extracting: return "准备安装…"
        case .countdown: return "\(secondsLeft(at: now)) 秒后安装"
        case .waiting(_, let reason): return "\(reason)后安装"
        case .installing: return "正在安装…"
        case .installOnQuit: return "退出时更新"
        case .downloadFailed: return "下载异常"
        }
    }

    /// 换了哪一种状态（不管进度），用来做切换动画。
    var stageKey: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .found: return "found"
        case .downloading: return "downloading"
        case .extracting: return "extracting"
        case .countdown: return "countdown"
        case .waiting: return "waiting"
        case .installing: return "installing"
        case .installOnQuit: return "installOnQuit"
        case .failed: return "failed"
        case .downloadFailed: return "downloadFailed"
        }
    }
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
    /// 工具栏的更新面板是否打开。
    var showPanel = false
    /// 新版本的更新说明网页。
    private(set) var releaseNotesURL: URL?
    /// 只能去网页下载的版本（appcast 里只有 infoURL）。
    private(set) var infoOnlyURL: URL?
    var isInformationOnly: Bool { infoOnlyURL != nil }

    /// 每天自动检查（Sparkle 自己记在偏好设置里）。
    var automaticChecks = false {
        didSet { updater?.automaticallyChecksForUpdates = automaticChecks }
    }

    /// 发现新版本就下载（工具栏显示进度），下载完倒计时 60 秒后安装并重启。
    var automaticDownloads = AppUpdatePreferences.automaticDownloads() {
        didSet { UserDefaults.standard.set(automaticDownloads, forKey: appUpdateAutoInstallKey) }
    }

    /// 也接收测试版。
    var betaChannel = UserDefaults.standard.bool(forKey: appUpdateBetaKey) {
        didSet { UserDefaults.standard.set(betaChannel, forKey: appUpdateBetaKey) }
    }

    /// 倒计时到点时问一下现在能不能重启；返回原因（如「番茄钟结束」）表示要等，nil 表示可以装。
    @ObservationIgnored var installBlocker: (@MainActor () -> String?)?

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private let delegate = AppUpdaterDelegate()
    @ObservationIgnored private let driver = AppUpdateUserDriver()
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var started = false
    /// 这次检查是用户点的「检查更新」，有结果时打开更新面板。
    @ObservationIgnored private var revealResult = false
    /// 这次是自动下载的：下载完倒计时再装；用户点「立即更新」的下载完直接装。
    @ObservationIgnored private var automaticSession = false
    /// 用户点了「现在安装」（之前选了退出时再装），下一次发现就直接装。
    @ObservationIgnored private var installImmediately = false
    @ObservationIgnored private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var installReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancelDownloadAction: (() -> Void)?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

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
        driver.owner = self
        let updater = SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main,
                                 userDriver: driver, delegate: delegate)
        self.updater = updater
        automaticChecks = updater.automaticallyChecksForUpdates
        UserDefaults.standard.removeObject(forKey: appUpdateLegacyAutoInstallKey)
        // Sparkle 自己的静默自动下载一直关着（拿不到进度），下载和安装由便单的开关管。
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
        lastCheck = updater.lastUpdateCheckDate
    }

    /// 启动时调用一次：开始按计划检查。
    func start() {
        guard let updater, !started else { return }
        started = true
        do {
            try updater.start()
        } catch {
            status = .failed("更新功能启动失败：\(error.localizedDescription)")
            return
        }
        observation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
        lastCheck = updater.lastUpdateCheckDate
    }

    /// 「检查更新」：有结果时打开工具栏的更新面板（reveal 为 false 时不打开，比如在设置里点的）。
    func checkForUpdates(reveal: Bool = true) {
        guard let updater else { return }
        start()
        revealResult = reveal
        if !updater.sessionInProgress { status = .checking }
        updater.checkForUpdates()
    }

    // MARK: 面板里的操作

    /// 发现新版本后点「立即更新」：下载，下完直接装（只能去网页下载的版本打开网页）。
    func installUpdate() {
        guard let reply = foundReply else { return }
        foundReply = nil
        automaticSession = false
        if let url = infoOnlyURL {
            NSWorkspace.shared.open(url)
            reply(.dismiss)
            status = .idle
            return
        }
        if let version = status.version { status = .downloading(version: version, received: 0, expected: 0) }
        reply(.install)
    }

    /// 稍后再说：下次检查时再提醒。
    func remindLater() {
        guard let reply = foundReply else { return }
        foundReply = nil
        reply(.dismiss)
        status = .idle
        showPanel = false
    }

    /// 跳过这个版本：以后自动检查不再提醒它（手动检查还会看到）。
    func skipVersion() {
        guard let reply = foundReply else { return }
        foundReply = nil
        reply(.skip)
        status = .idle
        showPanel = false
    }

    func cancelDownload() {
        let cancel = cancelDownloadAction
        cancelDownloadAction = nil
        cancel?()
        status = .idle
    }

    /// 不等倒计时，马上安装并重启。
    func installNow() {
        countdownTask?.cancel()
        countdownTask = nil
        guard let reply = installReply else { return }
        installReply = nil
        status = .installing(status.version ?? "")
        reply(.install)
    }

    /// 这次不装，退出便单时再装。
    func installLater() {
        countdownTask?.cancel()
        countdownTask = nil
        guard let reply = installReply else { return }
        installReply = nil
        let version = status.version ?? ""
        reply(.dismiss)
        status = .installOnQuit(version)
    }

    /// 之前选了退出时再装，现在改成马上装。
    func resumeInstall() {
        installImmediately = true
        checkForUpdates(reveal: true)
    }

    /// 关掉出错、已是最新这类提示。
    func dismissNotice() {
        switch status {
        case .failed, .downloadFailed, .upToDate: status = .idle
        default: break
        }
    }

    // MARK: Sparkle 回调（都在主线程）

    fileprivate func checking() {
        status = .checking
    }

    fileprivate func updateFound(_ item: SUAppcastItem, state: SPUUserUpdateState,
                                 reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = item.displayVersionString
        lastCheck = updater?.lastUpdateCheckDate ?? Date()
        releaseNotesURL = item.releaseNotesURL ?? item.fullReleaseNotesURL
        infoOnlyURL = item.isInformationOnlyUpdate ? item.infoURL : nil
        let reveal = revealResult
        revealResult = false
        let immediate = installImmediately
        installImmediately = false
        if infoOnlyURL == nil && (immediate || automaticDownloads) {
            automaticSession = !immediate
            status = state.stage == .notDownloaded
                ? .downloading(version: version, received: 0, expected: 0)
                : .extracting(version: version, progress: 1)
            reply(.install)
            return
        }
        automaticSession = false
        foundReply = reply
        status = .found(version)
        if reveal && state.userInitiated { showPanel = true }
    }

    fileprivate func noUpdate() {
        lastCheck = updater?.lastUpdateCheckDate ?? Date()
        status = .upToDate
        if revealResult { showPanel = true }
        revealResult = false
    }

    fileprivate func failed(_ error: Error) {
        let message = Self.describe(error as NSError)
        let duringDownload = status.isDownloading || installReply != nil
        countdownTask?.cancel()
        countdownTask = nil
        status = duringDownload ? .downloadFailed(message) : .failed(message)
        if revealResult { showPanel = true }
        revealResult = false
    }

    fileprivate func downloadStarted(cancel: @escaping () -> Void) {
        cancelDownloadAction = cancel
        if let version = status.version { status = .downloading(version: version, received: 0, expected: 0) }
    }

    fileprivate func downloadExpected(_ length: UInt64) {
        guard case .downloading(let version, _, _) = status else { return }
        status = .downloading(version: version, received: 0, expected: length)
    }

    fileprivate func downloadReceived(_ length: UInt64) {
        guard case .downloading(let version, let received, let expected) = status else { return }
        status = .downloading(version: version, received: received + length, expected: expected)
    }

    fileprivate func extracting(_ progress: Double) {
        cancelDownloadAction = nil
        guard let version = status.version else { return }
        status = .extracting(version: version, progress: progress)
    }

    fileprivate func readyToInstall(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelDownloadAction = nil
        let version = status.version ?? "新版本"
        installReply = reply
        if automaticSession {
            startCountdown(version)
        } else {
            installNow()
        }
    }

    fileprivate func installing() {
        status = .installing(status.version ?? "")
    }

    fileprivate func installed() {
        status = .idle
    }

    fileprivate func focus() {
        if revealResult { showPanel = true }
        revealResult = false
    }

    fileprivate func dismissed() {
        foundReply = nil
        installReply = nil
        cancelDownloadAction = nil
        countdownTask?.cancel()
        countdownTask = nil
        automaticSession = false
        revealResult = false
        switch status {
        case .checking, .found, .downloading, .extracting, .countdown, .waiting, .installing: status = .idle
        case .idle, .upToDate, .installOnQuit, .failed, .downloadFailed: break
        }
    }

    fileprivate func cycleFinished() {
        lastCheck = updater?.lastUpdateCheckDate ?? lastCheck
        if status == .checking { status = .idle }
    }

    // MARK: 倒计时

    private func startCountdown(_ version: String) {
        countdownTask?.cancel()
        status = .countdown(version: version, deadline: Date().addingTimeInterval(AppUpdateStatus.countdownSeconds))
        countdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AppUpdateStatus.countdownSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.countdownFinished(version)
        }
    }

    /// 倒计时到了：番茄钟计时中先等它结束，结束后重新倒计时 60 秒。
    private func countdownFinished(_ version: String) {
        guard installReply != nil else { return }
        guard let reason = installBlocker?() else {
            installNow()
            return
        }
        status = .waiting(version: version, reason: reason)
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.installBlocker?() == nil {
                    self.startCountdown(version)
                    return
                }
            }
        }
    }

    static func describe(_ error: NSError) -> String {
        switch error.code {
        case 1000, 1002:
            return "更新信息读不出来（服务器上的 appcast.xml 可能有问题）"
        case 2001:
            return "更新包下载失败，检查一下网络再试"
        case 3000:
            return "更新包解压失败"
        case 3001, 3002:
            return "更新包的签名对不上，已拒绝安装"
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Sparkle 的界面回调：都转给 AppUpdater，显示在工具栏上

@MainActor
final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    weak var owner: AppUpdater?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist 里已经打开了自动检查，一般不会走到这里。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.checking()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { return reply(.dismiss) }
        owner.updateFound(appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.noUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        owner?.failed(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.downloadStarted(cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.downloadExpected(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.downloadReceived(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.extracting(0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.extracting(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { return reply(.dismiss) }
        owner.readyToInstall(reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        owner?.installing()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        owner?.installed()
        acknowledgement()
    }

    func showUpdateInFocus() {
        owner?.focus()
    }

    func dismissUpdateInstallation() {
        owner?.dismissed()
    }
}

final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var owner: AppUpdater?

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: appUpdateBetaKey) ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { owner?.cycleFinished() }
    }
}
