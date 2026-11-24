import AppKit
import Foundation
import Observation

enum AuthState: Equatable {
    case checking, signedOut, signingIn, signedIn
}

enum SyncStatus: Equatable {
    case idle
    case syncing(String)
    case failed(String)

    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

enum ContentMode: String, CaseIterable, Identifiable {
    case list, quadrant, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表"
        case .quadrant: return "四象限"
        case .calendar: return "日历"
        }
    }
}

/// 四象限的时间范围（截图里的「近1天」）。
enum QuadrantRange: Int, CaseIterable, Identifiable {
    case day1 = 1, day3 = 3, day7 = 7, all = 0

    var id: Int { rawValue }

    var title: String {
        self == .all ? "全部" : "近\(rawValue)天"
    }
}

enum SidebarItem: Hashable {
    case overdue, today, next7, all, important, quadrant, calendar, undated, collected, completed, abandoned, focus, habits, stats
    case importer
    case conflicts
    case list(String)

    static let views: [SidebarItem] = [.overdue, .today, .next7, .all, .important, .quadrant, .calendar, .conflicts, .undated, .collected, .completed, .abandoned]

    var title: String {
        switch self {
        case .overdue: return "逾期"
        case .today: return "今天"
        case .next7: return "近 7 天"
        case .all: return "全部待办"
        case .important: return "重要待办"
        case .quadrant: return "四象限"
        case .calendar: return "日历"
        case .undated: return "无日期"
        case .collected: return "收藏"
        case .completed: return "已完成"
        case .abandoned: return "已放弃"
        case .focus: return "专注记录"
        case .habits: return "习惯打卡"
        case .stats: return "统计"
        case .importer: return "导入日程"
        case .conflicts: return "日程冲突"
        case .list: return "分类"
        }
    }

    var systemImage: String {
        switch self {
        case .overdue: return "clock.badge.exclamationmark"
        case .today: return "sun.max"
        case .next7: return "calendar.badge.clock"
        case .all: return "tray.full"
        case .important: return "exclamationmark.circle"
        case .quadrant: return "square.grid.2x2"
        case .calendar: return "calendar"
        case .undated: return "circle.dashed"
        case .collected: return "star"
        case .completed: return "checkmark.circle"
        case .abandoned: return "slash.circle"
        case .focus: return "timer"
        case .habits: return "leaf"
        case .stats: return "chart.bar.xaxis"
        case .importer: return "square.and.arrow.down.on.square"
        case .conflicts: return "calendar.badge.exclamationmark"
        case .list: return "list.bullet"
        }
    }

    /// 可以把任务卡片拖到侧栏的这一项上。
    var acceptsDrop: Bool {
        switch self {
        case .today, .important, .undated, .collected, .list: return true
        default: return false
        }
    }

    var dropHelp: String? {
        switch self {
        case .today: return "把任务拖到这里改到今天（重复任务只改这一次）"
        case .important: return "把任务拖到这里设为重要"
        case .undated: return "把一次性任务拖到这里清除日期"
        case .collected: return "把任务拖到这里收藏"
        case .list: return "把任务拖到这里移到这个分类"
        default: return nil
        }
    }

    /// 专注记录、习惯打卡是记录页：不显示快速添加栏和视图切换。
    /// 不是任务列表的独立页面（不显示问候卡片、快速添加栏和视图切换）。日程冲突页也算。
    var isRecordPage: Bool { self == .focus || self == .habits || self == .stats || self == .conflicts || self == .importer }

    /// 侧栏里的「四象限」「日历」固定使用对应视图，其余项可以切换视图。
    var fixedMode: ContentMode? {
        switch self {
        case .quadrant: return .quadrant
        case .calendar: return .calendar
        default: return nil
        }
    }
}

private enum DefaultsKey {
    static let weekStart = "biandan.weekStart"
    static let syncInterval = "biandan.syncIntervalMinutes"
    static let importSyncInterval = "biandan.importSyncIntervalMinutes"
    static let importNotify = "biandan.importNotifyFailures"
    static let chinaMakeup = "biandan.chinaMakeup"
    static let showFieldNames = "biandan.showFieldNames"
    static let quadrantRange = "biandan.quadrantRange"
    static let mcpEnabled = "biandan.mcpEnabled"
    static let remindersEnabled = "biandan.remindersEnabled"
    static let pinMainWindow = "biandan.pinMainWindow"
    static let showCompletedInList = "biandan.showCompletedInList"
    static let pomodoroMinutes = "biandan.pomodoroMinutes"
    static let tintCheckboxByList = "biandan.tintCheckboxByList"
    static let summaryRange = "biandan.summaryRange"
    static let showSummaryTimeline = "biandan.showSummaryTimeline"
    static let quickAddHotKey = "biandan.quickAddHotKey"
}

/// 应用状态。P3 只读：登录、同步、浏览和选中。
@MainActor
@Observable
final class AppModel {
    let tokens: TokenProvider
    let store: LocalStore
    private let engine: SyncEngine
    /// 写操作的业务服务（串行执行、写后读回）。
    let service: BiandanService
    /// 把日程快照推到远程 biandan-api，给 ESP32 等设备读取。
    let schedulePusher = SchedulePusher()
    @ObservationIgnored private var signInFlow: OAuthFlow?
    /// 回调页仍在本机显示登录进度的流程（登录结束后再保留一会儿）。
    @ObservationIgnored private var servingFlow: OAuthFlow?
    /// 首次同步期间的登录进度，供回调页轮询。
    @ObservationIgnored private var loginProgress: LoginProgress?
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapped = false

    // 账户与同步
    var authState: AuthState = .checking
    var profile: AccountProfile = .placeholder
    var pendingAuthorizationURL: URL?
    var syncStatus: SyncStatus = .idle
    var lastSyncedAt: Date?
    var lastError: String?
    /// 续期状态（下次续期时间、还有几天要重新登录），每次同步后刷新。
    var renewal: RenewalStatus?

    // 待同步队列
    /// 等待写入云端的命令数（断网或云端暂时不可用时入队）。
    var outboxPending = 0
    /// 重放时遇到永久错误、已放弃的命令数。
    var outboxFailed = 0
    var outboxLastError: String?
    /// 待同步队列明细（待同步 + 已放弃，按入队顺序）。
    var outboxEntries: [OutboxEntry] = []
    /// 导出、备份的结果提示（设置页显示）。
    var exportNotice: String?
    /// 最近一次本地自动备份的时间。
    var lastBackupAt: Date? = LocalBackup.latestDate()
    /// 入队命令 → 它的乐观修改，重放成功或放弃时移除。
    @ObservationIgnored var queuedEdits: [String: UUID] = [:]
    @ObservationIgnored var isFlushingOutbox = false
    @ObservationIgnored var outboxRetryTask: Task<Void, Never>?

    /// 全量拉取节流状态。
    var syncThrottle = SyncThrottle()

    /// 主窗口的撤销管理器，⌘Z / ⇧⌘Z 用。
    @ObservationIgnored weak var undoManager: UndoManager?

    // 调休数据
    /// 调休数据覆盖到的最后一年（内置 + 远程补充）。
    var holidayLastYear: Int = ChinaMakeup.builtinLastYear
    var holidayStatus: String?
    var isCheckingHolidays = false

    // 写操作状态
    /// 前台写操作（弹窗、检查器保存按钮）。
    var busyOperations = 0
    /// 后台写操作（完成、拖动等乐观更新），不打断界面。
    var backgroundOperations = 0
    /// 尚未得到云端确认的乐观修改；每次重新加载快照后按顺序重放。
    @ObservationIgnored var optimisticEdits: [OptimisticEdit] = []
    var operationError: String?
    /// 新建的定时日程和已有日程时间重叠时的提醒。
    var conflictNotice: ConflictNotice?
    /// 待确认删除的执行实例（弹出删除范围对话框）。
    var deleteRequest: OccurrenceItem?
    /// 新建任务弹窗的预设值；非 nil 时弹出。
    var newTaskPreset: NewTaskPreset?
    /// 待办单新建 / 编辑弹窗。
    var listEditor: ListEditorRequest?
    /// 待确认删除的待办单。
    var listDeleteRequest: TodoList?
    /// 退出登录确认弹窗。
    var signOutRequested = false
    /// 编辑重复规则弹窗（也用于把一次性任务设为重复）。
    var recurrenceRequest: TaskDef?
    /// 补记 / 编辑专注记录弹窗。
    var focusEditor: FocusEditorRequest?
    /// 待确认删除的专注记录。
    var focusDeleteRequest: FocusRecord?

    // 数据
    var snapshot: DataSnapshot = .empty
    var today: LocalDate = .today()

    // 浏览状态
    var sidebarSelection: SidebarItem? = .quadrant
    var viewMode: ContentMode = .list
    /// 默认「全部」，记住上次的选择。
    var quadrantRange: QuadrantRange = QuadrantRange(
        rawValue: UserDefaults.standard.object(forKey: DefaultsKey.quadrantRange) as? Int ?? QuadrantRange.all.rawValue
    ) ?? .all {
        didSet { UserDefaults.standard.set(quadrantRange.rawValue, forKey: DefaultsKey.quadrantRange) }
    }
    var searchText = ""
    var selectedOccurrenceID: String?
    var selectedFocusID: String?
    /// ⌘ 点击多选的执行实例 ID；非空时显示批量操作栏。
    var multiSelection: Set<String> = []
    /// 选择模式：标题栏点「选择」进入。卡片显示勾选框，直接点击即可勾选（不用按 ⌘），底部常驻批量操作栏。
    var selectionMode = false
    /// ⇧ 连选的起点（最近一次单选或 ⌘ 点击的那项）。
    @ObservationIgnored var selectionAnchor: String?
    /// 键盘移动选中后要滚动到的实例（只由键盘设置，鼠标点击不滚动）。
    var keyboardScrollTarget: String?
    /// 点通知打开某条时让列表滚过去（见 NotificationReveal.swift）。
    var revealRequest: RevealRequest?
    /// 回车编辑标题：递增后检查器的标题输入框获得焦点。
    var titleFocusRequest = 0
    @ObservationIgnored var pendingTitleFocus = false
    /// 批量删除确认弹窗。
    var batchDeleteRequested = false
    /// 批量操作期间暂存各步的撤销，结束后合并登记成一步。
    @ObservationIgnored var undoCollector: [UndoStep]?
    var showInspector = true
    var showRawJSON = false
    var calendarMonth: LocalDate = LocalDate.today().firstOfMonth
    /// 日历显示月还是周，记住上次的选择。
    var calendarScope: CalendarScope = CalendarScope(
        rawValue: UserDefaults.standard.string(forKey: "biandan.calendarScope") ?? ""
    ) ?? .month {
        didSet { UserDefaults.standard.set(calendarScope.rawValue, forKey: "biandan.calendarScope") }
    }
    /// 周视图显示的那一周里的任意一天。
    var calendarFocus: LocalDate = .today()

    // 设置
    var weekStart: Int = UserDefaults.standard.integer(forKey: DefaultsKey.weekStart) {
        didSet { UserDefaults.standard.set(weekStart, forKey: DefaultsKey.weekStart) }
    }
    var syncIntervalMinutes: Int = max(UserDefaults.standard.integer(forKey: DefaultsKey.syncInterval), 0) == 0
        ? 5 : UserDefaults.standard.integer(forKey: DefaultsKey.syncInterval) {
        didSet {
            UserDefaults.standard.set(syncIntervalMinutes, forKey: DefaultsKey.syncInterval)
            if authState == .signedIn { startAutoSync() }
        }
    }
    var chinaMakeup: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.chinaMakeup) {
        didSet { UserDefaults.standard.set(chinaMakeup, forKey: DefaultsKey.chinaMakeup) }
    }
    var showFieldNames: Bool = UserDefaults.standard.object(forKey: DefaultsKey.showFieldNames) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFieldNames, forKey: DefaultsKey.showFieldNames) }
    }
    /// 任务卡片的完成圆圈使用所属待办单的颜色（默认打开）。
    var tintCheckboxByList: Bool = UserDefaults.standard.object(forKey: DefaultsKey.tintCheckboxByList) as? Bool ?? true {
        didSet { UserDefaults.standard.set(tintCheckboxByList, forKey: DefaultsKey.tintCheckboxByList) }
    }
    /// 完成率卡片的时间维度（默认今天），会记住。
    var summaryRange: ProgressRange = ProgressRange(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.summaryRange) ?? ""
    ) ?? .today {
        didSet { UserDefaults.standard.set(summaryRange.rawValue, forKey: DefaultsKey.summaryRange) }
    }
    /// 完成率卡片下方的时间条是否展开（默认展开），会记住。
    var showSummaryTimeline: Bool = UserDefaults.standard.object(forKey: DefaultsKey.showSummaryTimeline) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSummaryTimeline, forKey: DefaultsKey.showSummaryTimeline) }
    }

    // 本机 MCP 服务（默认关闭）
    var mcpEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.mcpEnabled) {
        didSet {
            guard mcpEnabled != oldValue else { return }
            UserDefaults.standard.set(mcpEnabled, forKey: DefaultsKey.mcpEnabled)
            if mcpEnabled { startMCP() } else { stopMCP() }
        }
    }
    var mcpStatus: MCPStatus = .off
    var mcpCallCount = 0
    var mcpLastCallAt: Date?
    var mcpNotice: String?
    /// 本机 MCP 访问密钥（设置页显示，需要可观察）。
    var mcpAccessKey: String?
    @ObservationIgnored var mcpServer: MCPHTTPServer?
    @ObservationIgnored var mcpGeneration: UUID?

    // 时间提醒通知（默认关闭）与菜单栏组件（默认显示）
    /// 提醒声音（来源、语音、文案、四象限）。改了就重新排提醒。
    var reminderSound: ReminderSoundSettings = ReminderSoundSettings.load() {
        didSet {
            guard reminderSound != oldValue else { return }
            reminderSound.save()
            scheduleReminders()
        }
    }

    var remindersEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.remindersEnabled) {
        didSet {
            guard remindersEnabled != oldValue else { return }
            UserDefaults.standard.set(remindersEnabled, forKey: DefaultsKey.remindersEnabled)
            remindersToggled()
        }
    }
    var showMenuBarExtra: Bool = MenuBarDefaults.isShown {
        didSet {
            UserDefaults.standard.set(showMenuBarExtra, forKey: MenuBarDefaults.showKey)
            MenuBarDefaults.applyDockPolicy()
        }
    }
    /// 菜单栏图标旁显示下一场倒计时（默认显示）。
    var menuBarCountdown: Bool = MenuBarDefaults.showsCountdown {
        didSet { UserDefaults.standard.set(menuBarCountdown, forKey: MenuBarDefaults.countdownKey) }
    }
    /// 隐藏 Dock 图标，只留菜单栏图标（菜单栏图标关掉时不生效）。
    var hideDockIcon: Bool = MenuBarDefaults.hidesDock {
        didSet {
            UserDefaults.standard.set(hideDockIcon, forKey: MenuBarDefaults.hideDockKey)
            MenuBarDefaults.applyDockPolicy()
        }
    }
    /// 桌面浮窗球（默认显示）：单击框选识别日程，右键更多。
    /// 识别日程时，情景对应的分类不存在就建议新建（关掉后只在已有分类里选）。
    var autoCreateCaptureCategory: Bool =
        UserDefaults.standard.object(forKey: "biandan.capture.autoCreateCategory") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCreateCaptureCategory, forKey: "biandan.capture.autoCreateCategory") }
    }

    /// AI 识别日程（DeepSeek 或其他 OpenAI 兼容接口）。API Key 存在钥匙串里，见 AIKeyStore。
    var aiExtractionMode: AIExtractionMode =
        AIExtractionMode(rawValue: UserDefaults.standard.string(forKey: "biandan.ai.mode") ?? "") ?? .fallback {
        didSet { UserDefaults.standard.set(aiExtractionMode.rawValue, forKey: "biandan.ai.mode") }
    }

    var aiModelName: String = UserDefaults.standard.string(forKey: "biandan.ai.model") ?? AIModelOption.flash.rawValue {
        didSet { UserDefaults.standard.set(aiModelName, forKey: "biandan.ai.model") }
    }

    var aiBaseURL: String = UserDefaults.standard.string(forKey: "biandan.ai.baseURL") ?? AIExtractionSettings.defaultBaseURL {
        didSet { UserDefaults.standard.set(aiBaseURL, forKey: "biandan.ai.baseURL") }
    }

    /// 钥匙串里有没有 API Key（打开设置、开始识别时刷新）。
    var aiKeyConfigured = false

    /// 快速添加栏、全局快速添加、菜单栏快速添加：回车后先让 AI 整理（默认打开，见 QuickAddAI）。
    var quickAddUsesAI: Bool = UserDefaults.standard.object(forKey: "biandan.quickAdd.ai") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quickAddUsesAI, forKey: "biandan.quickAdd.ai") }
    }

    /// AI 决策：调用 AI 之前先用百炼决策模型判断有没有日程。API Key 存在钥匙串里，见 DecisionKeyStore。
    var decisionEnabled: Bool = UserDefaults.standard.bool(forKey: "biandan.decision.enabled") {
        didSet { UserDefaults.standard.set(decisionEnabled, forKey: "biandan.decision.enabled") }
    }

    var decisionWorkspace: String = UserDefaults.standard.string(forKey: "biandan.decision.workspace") ?? "" {
        didSet { UserDefaults.standard.set(decisionWorkspace, forKey: "biandan.decision.workspace") }
    }

    var decisionRegion: DecisionRegion =
        DecisionRegion(rawValue: UserDefaults.standard.string(forKey: "biandan.decision.region") ?? "") ?? .beijing {
        didSet { UserDefaults.standard.set(decisionRegion.rawValue, forKey: "biandan.decision.region") }
    }

    var decisionSensitivity: DecisionSensitivity =
        DecisionSensitivity(rawValue: UserDefaults.standard.string(forKey: "biandan.decision.sensitivity") ?? "") ?? .balanced {
        didSet { UserDefaults.standard.set(decisionSensitivity.rawValue, forKey: "biandan.decision.sensitivity") }
    }

    /// 钥匙串里有没有 DashScope API Key。
    var decisionKeyConfigured = false

    /// 导入日程：已连接的来源、待确认的导入预览、进行中的导入和结果提示。
    var importSources: [ImportSource] = []
    var importPreview: ImportPreview?
    var importBusy = false
    var importNotice: String?
    /// 正在同步的来源；各来源上次同步失败的原因。
    var importSyncing: Set<String> = []
    var importSyncErrors: [String: String] = [:]
    var caldavSheetShown = false
    var urlSheetShown = false
    var systemSheetShown = false
    var importEditing: ImportSource?
    var importLogShown = false
    /// 导入来源同步失败、自动暂停、恢复时发系统通知。
    var importNotifyFailures: Bool = UserDefaults.standard.object(forKey: DefaultsKey.importNotify) as? Bool ?? true {
        didSet { UserDefaults.standard.set(importNotifyFailures, forKey: DefaultsKey.importNotify) }
    }
    /// 订阅类来源（CalDAV）的自动同步间隔（分钟）；0 表示只手动同步。改动后立即按新间隔重新计时。
    var importSyncIntervalMinutes: Int = UserDefaults.standard.object(forKey: DefaultsKey.importSyncInterval) as? Int
        ?? AppModel.defaultImportSyncMinutes {
        didSet {
            guard importSyncIntervalMinutes != oldValue else { return }
            UserDefaults.standard.set(importSyncIntervalMinutes, forKey: DefaultsKey.importSyncInterval)
            if authState == .signedIn { startImportAutoSync() }
        }
    }
    @ObservationIgnored var importSyncTask: Task<Void, Never>?

    /// 打开设置时要滚动到的位置（用完即清）。
    var settingsAnchor: SettingsAnchor?
    /// 跳过去之后短暂高亮的分组。
    var settingsHighlight: SettingsAnchor?

    func refreshAIKeyStatus() {
        aiKeyConfigured = AIKeyStore.load() != nil
    }

    func refreshDecisionKeyStatus() {
        decisionKeyConfigured = DecisionKeyStore.load() != nil
    }

    func decisionSettings() -> DecisionSettings {
        DecisionSettings(enabled: decisionEnabled, workspace: decisionWorkspace, region: decisionRegion,
                         sensitivity: decisionSensitivity, apiKey: DecisionKeyStore.load())
    }

    func aiExtractionSettings() -> AIExtractionSettings {
        AIExtractionSettings(mode: aiExtractionMode, model: aiModelName, baseURL: aiBaseURL, apiKey: AIKeyStore.load())
    }

    /// 识别出地点后自动在地图上查坐标（MapKit，查询词会发给 Apple 地图服务）。
    var autoLocateCapturePlace: Bool =
        UserDefaults.standard.object(forKey: "biandan.capture.autoLocate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoLocateCapturePlace, forKey: "biandan.capture.autoLocate") }
    }

    var showFloatingBall: Bool = UserDefaults.standard.object(forKey: "biandan.showFloatingBall") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showFloatingBall, forKey: "biandan.showFloatingBall")
            FloatingBallController.shared.apply(model: self)
        }
    }
    /// 全局快速添加的快捷键（默认 ⌃⌥N）。
    var quickAddHotKey: QuickAddHotKey = QuickAddHotKey(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.quickAddHotKey) ?? ""
    ) ?? .controlOptionN {
        didSet {
            UserDefaults.standard.set(quickAddHotKey.rawValue, forKey: DefaultsKey.quickAddHotKey)
            applyQuickAddHotKey()
        }
    }
    /// 快捷键注册失败（被占用等）时的提示。
    var quickAddHotKeyStatus: String?
    /// 每次弹出全局快速添加时递增，输入框据此清空并聚焦。
    var globalQuickAddSession = 0
    var reminderStatus: ReminderStatus = .notDetermined
    /// 上次读取系统授权的时间（设置页显示）。
    var reminderCheckedAt: Date?
    /// 授权、测试通知的结果提示。
    var reminderNotice: String?
    var scheduledReminderCount = 0
    /// 主窗口置顶（浮动在其他窗口之上）。
    var pinMainWindow: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.pinMainWindow) {
        didSet { UserDefaults.standard.set(pinMainWindow, forKey: DefaultsKey.pinMainWindow) }
    }
    /// 列表底部「已完成」分组是否展开（默认展开）。
    var showCompletedInList: Bool = UserDefaults.standard.object(forKey: DefaultsKey.showCompletedInList) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCompletedInList, forKey: DefaultsKey.showCompletedInList) }
    }
    /// 番茄钟：进行中的计时，nil 表示没有在计时。
    var pomodoro: PomodoroSession?
    @ObservationIgnored var pomodoroTicker: Task<Void, Never>?
    var showPomodoro = false
    /// 番茄钟时长（分钟），会记住。
    var pomodoroMinutes: Int = (UserDefaults.standard.object(forKey: DefaultsKey.pomodoroMinutes) as? Int) ?? 25 {
        didSet { UserDefaults.standard.set(pomodoroMinutes, forKey: DefaultsKey.pomodoroMinutes) }
    }
    let reminders = ReminderScheduler()
    /// 由界面注册的「打开主窗口」动作（SwiftUI openWindow）。
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var revealObserver: NSObjectProtocol?
    @ObservationIgnored var completeObserver: NSObjectProtocol?
    /// 睡眠 / 醒来、正式版启动 / 退出的观察者。
    @ObservationIgnored var workspaceObservers: [NSObjectProtocol] = []

    init() {
        // 先装好本地缓存的调休数据，重复规则展开时要用。
        HolidayUpdater.loadCache()
        tokens = TokenProvider()
        if let url = try? LocalStore.defaultURL(), let disk = try? LocalStore(url: url) {
            store = disk
        } else {
            // 磁盘库打不开时退回内存库，至少保证能浏览当次同步的数据。
            store = try! LocalStore()
        }
        engine = SyncEngine(client: SyncAPIClient(tokens: tokens), store: store)
        service = BiandanService(cloud: SyncAPIClient(tokens: tokens), store: store)
    }

    // MARK: - 启动

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        FloatingBallController.shared.apply(model: self)
        // 自动更新：按计划检查（开发版、没配置更新地址的包不启用）。
        AppUpdater.shared.start()
        // 自动安装的倒计时到点时，番茄钟还在计时就先不重启，等它结束再倒计时。
        AppUpdater.shared.installBlocker = { [weak self] in self?.pomodoro == nil ? nil : "番茄钟结束" }
        if DebugFlags.offline {
            // 仅 Debug 排查：不读钥匙串、不联网、不启 MCP、不排提醒，只用本地库显示主界面。
            reloadSnapshot()
            profile = .placeholder
            authState = .signedIn
            return
        }
        if mcpEnabled { startMCP() }
        schedulePusher.attach(self)
        installReminderObserver()
        applyQuickAddHotKey()
        Task { await refreshReminderStatus() }
        reloadSnapshot()
        refreshOutboxCounts()
        Task { await checkHolidayUpdates(force: false) }
        if await tokens.isSignedIn {
            profile = AccountProfile.loadSaved() ?? .placeholder
            authState = .signedIn
            // 通知上点「完成」把应用拉起时，登录状态读完再处理。
            drainReminderInbox()
            drainPendingReveal()
            scheduleReminders()
            startAutoSync()
            await refreshRenewal()
            syncThrottle.lastSuccess = snapshot.lastPulledAt
            await syncNow(.startup)
        } else {
            authState = .signedOut
        }
    }

    /// 窗口重新激活：刷新「今天」，距上次同步超过 1 分钟则同步一次。
    func appBecameActive() {
        let now = LocalDate.today()
        if now != today { today = now }
        guard authState == .signedIn, !syncStatus.isSyncing else { return }
        if let last = lastSyncedAt, Date().timeIntervalSince(last) < 60 { return }
        Task { await syncNow(.automatic) }
    }

    // MARK: - 登录 / 退出

    func signIn() {
        guard authState != .signingIn else { return }
        servingFlow?.finishServing(after: 0)
        let flow = OAuthFlow()
        signInFlow = flow
        servingFlow = flow
        pendingAuthorizationURL = flow.authorizationURL
        lastError = nil
        authState = .signingIn
        Task {
            do {
                let reply = try await flow.run()
                flow.progress.update(.exchanging, detail: "正在保存到钥匙串…")
                profile = try await tokens.completeSignIn(with: reply)
                finishSignInAttempt()
                authState = .signedIn
                startAutoSync()
                // 回调页轮询这里的进度，实时显示首次同步。
                loginProgress = flow.progress
                let synced = await syncNow()
                loginProgress = nil
                if synced {
                    flow.progress.update(.done, detail: "同步完成", counts: LoginProgress.Counts(
                        lists: snapshot.lists.count, tasks: snapshot.tasks.count,
                        occurrences: snapshot.occurrences.count, focus: snapshot.focus.count))
                } else {
                    flow.progress.update(.failed, detail: "首次同步没有完成", error: syncFailureText)
                }
                flow.finishServing(after: 60)
                // 先让回调页显示完成状态，再切回 App。
                try? await Task.sleep(for: .seconds(1.5))
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                finishSignInAttempt()
                authState = .signedOut
                let cancelled = (error as? AuthError) == .cancelled
                flow.progress.update(.failed, detail: "登录没有完成", error: error.localizedDescription)
                flow.finishServing(after: cancelled ? 0 : 60)
                if !cancelled {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    private var syncFailureText: String {
        if case .failed(let message) = syncStatus { return message }
        return lastError ?? "同步没有完成，请在 App 里重试。"
    }

    private func finishSignInAttempt() {
        signInFlow = nil
        pendingAuthorizationURL = nil
    }

    func cancelSignIn() {
        signInFlow?.cancel()
    }

    /// 写操作遇到授权失效：停止自动同步，回到登录页。
    func expireSession() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        stopImportAutoSync()
        syncStatus = .idle
        lastError = AuthError.reauthorizationRequired.localizedDescription
        authState = .signedOut
    }

    func reopenAuthorizationPage() {
        if let url = pendingAuthorizationURL { NSWorkspace.shared.open(url) }
    }

    func signOut(keepCache: Bool) async {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        stopImportAutoSync()
        await engine.cancel()
        do {
            try await tokens.signOut()
        } catch {
            lastError = error.localizedDescription
        }
        if !keepCache {
            try? store.wipe()
            reloadSnapshot()
            lastSyncedAt = nil
        }
        selectedOccurrenceID = nil
        selectedFocusID = nil
        multiSelection = []
        syncStatus = .idle
        profile = .placeholder
        authState = .signedOut
        renewal = nil
        discardOutbox()
        undoManager?.removeAllActions()
        scheduleReminders()
    }

    // MARK: - 同步

    /// 从令牌提供者读取最新的续期时间；未登录时清空。
    func refreshRenewal() async {
        let status = await tokens.renewalStatus()
        renewal = authState == .signedIn ? status : nil
    }

    /// 返回本次同步是否成功。
    @discardableResult
    func syncNow(_ reason: SyncReason = .manual) async -> Bool {
        // 排查用离线模式没有令牌：不同步，否则会因 notSignedIn 退回登录页。
        if DebugFlags.offline { return false }
        guard authState == .signedIn else { return false }
        switch syncThrottle.decide(reason) {
        case .allow:
            break
        case .skip:
            return false
        case .wait(let seconds):
            syncStatus = .failed("云端繁忙，请 \(Int(seconds.rounded(.up))) 秒后再同步。")
            return false
        }
        // 同步过程中可能续期过，结束后刷新显示。
        defer { Task { await self.refreshRenewal() } }
        // 先把排队的修改写回云端，再拉取。
        if outboxPending > 0 {
            await flushOutbox()
            guard authState == .signedIn else { return false }
        }
        syncStatus = .syncing("正在同步…")
        loginProgress?.update(.syncing, detail: "正在同步…")
        do {
            let report = try await engine.syncNow { message in
                Task { @MainActor in self.updateProgress(message) }
            }
            lastSyncedAt = report.finishedAt
            reloadSnapshot()
            autoBackupIfNeeded()
            backfillRemindersIfNeeded()
            drainPendingReveal(afterSync: true)
            syncThrottle.recordSuccess(at: report.finishedAt,
                                       records: snapshot.lists.count + snapshot.tasks.count
                                           + snapshot.occurrences.count + snapshot.focus.count)
            syncStatus = .idle
            lastError = nil
            return true
        } catch AuthError.reauthorizationRequired, AuthError.notSignedIn {
            autoSyncTask?.cancel()
            autoSyncTask = nil
            stopImportAutoSync()
            syncStatus = .idle
            lastError = AuthError.reauthorizationRequired.localizedDescription
            authState = .signedOut
            return false
        } catch is CancellationError {
            syncStatus = .idle
            return false
        } catch {
            syncThrottle.recordFailure(at: Date(), retryAfter: (error as? CloudError)?.retryAfter)
            syncStatus = .failed(error.localizedDescription)
            return false
        }
    }

    private func updateProgress(_ message: String) {
        if syncStatus.isSyncing { syncStatus = .syncing(message) }
        loginProgress?.update(.syncing, detail: message)
    }

    private func startAutoSync() {
        autoSyncTask?.cancel()
        startImportAutoSync()
        let minutes = max(syncIntervalMinutes, 1)
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled, let self else { return }
                await self.syncNow(.automatic)
            }
        }
    }

    func reloadSnapshot() {
        do {
            var loaded = try store.loadSnapshot()
            for edit in optimisticEdits { edit.apply(&loaded) }
            snapshot = loaded
        } catch {
            snapshot = .empty
            lastError = "读取本地数据库失败：\(error.localizedDescription)"
        }
        if lastSyncedAt == nil { lastSyncedAt = snapshot.lastPulledAt }
        if let id = selectedOccurrenceID, snapshot.item(occurrenceID: id) == nil { selectedOccurrenceID = nil }
        if !multiSelection.isEmpty {
            multiSelection = multiSelection.filter { snapshot.item(occurrenceID: $0) != nil }
        }
        if let id = selectedFocusID, !snapshot.focus.contains(where: { $0.time == id }) { selectedFocusID = nil }
        scheduleReminders()
        schedulePusher.noteChange()
    }

    // MARK: - 视图数据

    var counts: SidebarCounts { snapshot.counts(today: today, weekStart: weekStart) }

    var effectiveMode: ContentMode { sidebarSelection?.fixedMode ?? viewMode }

    /// 内容区标题上方切换视图。当前在「四象限」「日历」固定项时，切到「全部待办」再换视图。
    func setMode(_ mode: ContentMode) {
        if sidebarSelection?.fixedMode != nil {
            sidebarSelection = mode == .quadrant ? .quadrant : (mode == .calendar ? .calendar : .all)
        }
        viewMode = mode
    }

    func title(for item: SidebarItem) -> String {
        if case .list(let id) = item { return snapshot.list(id)?.displayName ?? "分类" }
        return item.title
    }

    var selectedItem: OccurrenceItem? {
        selectedOccurrenceID.flatMap { snapshot.item(occurrenceID: $0) }
    }

    var selectedFocus: FocusRecord? {
        selectedFocusID.flatMap { id in snapshot.focus.first { $0.time == id } }
    }

    func query(for item: SidebarItem) -> OccurrenceQuery? {
        var query = OccurrenceQuery()
        query.text = searchText
        switch item {
        case .overdue:
            query.start = .minSupported
            query.end = today.adding(days: -1)
        case .today:
            query.start = .minSupported
            query.end = today
        case .next7:
            query.start = .minSupported
            query.end = today.adding(days: 6)
        case .all, .quadrant, .undated:
            query.includeUndated = true
        case .calendar:
            query.status = .all
        case .important:
            query.important = true
            query.includeUndated = true
        case .collected:
            query.collected = true
            query.includeUndated = true
        case .completed:
            query.status = .completed
        case .abandoned:
            query.status = .abandoned
            // 无日期任务放弃后也要能在这里找回来（与「已完成」一致）。
            query.includeUndated = true
        case .list(let id):
            query.listID = id
            query.includeUndated = true
        case .focus, .habits, .stats, .conflicts, .importer:
            return nil
        }
        return query
    }

    func items(for item: SidebarItem) -> [OccurrenceItem] {
        guard let query = query(for: item) else { return [] }
        var result = snapshot.items(query)
        if item == .undated { result = result.filter { $0.task.undated } }
        // 逾期的只在「逾期」里显示（日历除外），见 OverdueFilter。
        return OverdueFilter.apply(result, for: item, today: today)
    }

    /// 四象限：按当前侧栏范围取实例，再按「近 N 天」过滤（不含逾期和无日期；逾期的在「逾期」里）。
    /// 四象限取数的侧栏范围：日历、专注记录按「全部待办」处理。
    private var quadrantScope: SidebarItem {
        let scope = sidebarSelection ?? .all
        return scope == .calendar || scope.isRecordPage ? .all : scope
    }

    /// 当前「近 N 天」范围外（更晚或无日期）被隐藏的待办数。
    var quadrantHiddenCount: Int {
        guard quadrantRange != .all else { return 0 }
        let total = items(for: quadrantScope).count
        let shown = quadrantItems().values.reduce(0) { $0 + $1.count }
        return max(total - shown, 0)
    }

    func quadrantItems() -> [Quadrant: [OccurrenceItem]] {
        var base = items(for: quadrantScope)
        if quadrantRange != .all {
            let limit = today.adding(days: quadrantRange.rawValue - 1)
            base = base.filter { item in
                guard !item.task.undated, let start = item.occurrence.startDate else { return false }
                return start <= limit
            }
        }
        return Dictionary(grouping: base) { $0.task.quadrant }
    }
}
