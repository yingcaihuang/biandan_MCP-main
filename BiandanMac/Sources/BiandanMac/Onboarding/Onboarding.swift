import AppKit
import SwiftUI

// MARK: - 新人指引：欢迎页 → 功能导览 → 上手清单。完成状态按指引版本存在本机。

enum ChecklistItem: String, CaseIterable, Identifiable, Sendable {
    case firstTask, quadrant, capture, notifications, importCalendar, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstTask: return "添加第一条任务"
        case .quadrant: return "看一眼四象限"
        case .capture: return "用浮窗球识别一次日程"
        case .notifications: return "打开时间提醒"
        case .importCalendar: return "导入一个外部日历"
        case .ai: return "接入 AI 识别"
        }
    }

    var detail: String {
        switch self {
        case .firstTask: return "在快速添加里输入「明天下午3点 评审」，回车就保存"
        case .quadrant: return "按重要、紧急把任务分进四格，先做要紧的"
        case .capture: return "框选聊天记录，本机识别出日程，确认后添加"
        case .notifications: return "允许便单发通知，到点弹出提醒"
        case .importCalendar: return "飞书、钉钉、iCloud、邮箱日历或 .ics 文件"
        case .ai: return "可选：填 DeepSeek API Key，识别更准"
        }
    }

    var icon: String {
        switch self {
        case .firstTask: return "plus.circle"
        case .quadrant: return "square.grid.2x2"
        case .capture: return "viewfinder"
        case .notifications: return "bell.badge"
        case .importCalendar: return "square.and.arrow.down.on.square"
        case .ai: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .firstTask: return Theme.accent
        case .quadrant: return Quadrant.importantUrgent.tint
        case .capture: return Color(hex: 0xFA8B36)
        case .notifications: return Quadrant.notImportantUrgent.tint
        case .importCalendar: return Quadrant.neither.tint
        case .ai: return Color(hex: 0x8E5BD6)
        }
    }

    var actionTitle: String {
        switch self {
        case .firstTask: return "去添加"
        case .quadrant: return "去看看"
        case .capture: return "试一试"
        case .notifications: return "去打开"
        case .importCalendar: return "去导入"
        case .ai: return "去设置"
        }
    }

    /// 可选项不算进完成度。
    var optional: Bool { self == .ai }

    static var required: [ChecklistItem] { allCases.filter { !$0.optional } }
}

struct TourStep: Identifiable {
    let id: Int
    /// nil 表示不指向具体控件，卡片放在窗口中间。
    let target: TourTarget?
    /// 高亮区域横向拉到这个目标的宽度（侧栏的行用侧栏宽度）。
    let stretch: TourTarget?
    /// 需要用户亲手完成的操作；nil 表示只看说明。
    let action: TourAction?
    let prompt: String?
    let icon: String
    let tint: Color
    let title: String
    let body: String
    let tip: String?

    init(_ id: Int, target: TourTarget?, icon: String, tint: Color, title: String, body: String, tip: String? = nil,
         stretch: TourTarget? = nil, action: TourAction? = nil, prompt: String? = nil) {
        self.id = id
        self.target = target
        self.stretch = stretch
        self.action = action
        self.prompt = prompt
        self.icon = icon
        self.tint = tint
        self.title = title
        self.body = body
        self.tip = tip
    }
}

@MainActor
@Observable
final class Onboarding {
    static let shared = Onboarding()
    /// 指引内容有大改时加 1，已看过旧版的用户会再看到一次。
    nonisolated static let version = 1

    enum Key {
        static let welcome = "biandan.onboarding.welcomeVersion"
        static let tour = "biandan.onboarding.tourVersion"
        static let checklistHidden = "biandan.onboarding.checklistHidden"
        static let checklistCollapsed = "biandan.onboarding.checklistCollapsed"
        static let marked = "biandan.onboarding.checklistMarked"
        static let taskBaseline = "biandan.onboarding.taskBaseline"
        static let all = [welcome, tour, checklistHidden, checklistCollapsed, marked, taskBaseline]
    }

    let defaults: UserDefaults
    private(set) var welcomeSeen: Bool
    private(set) var tourSeen: Bool
    var checklistHidden: Bool {
        didSet { defaults.set(checklistHidden, forKey: Key.checklistHidden) }
    }
    var checklistCollapsed: Bool {
        didSet { defaults.set(checklistCollapsed, forKey: Key.checklistCollapsed) }
    }
    private(set) var marked: Set<String>
    /// 清单开始时的任务数；之后多出来就算「添加了第一条任务」。
    private(set) var taskBaseline: Int?
    /// 正在进行的导览走到第几步；nil 表示不在导览中。
    private(set) var tourIndex: Int?
    /// 当前这一步要求的操作已经完成（显示「做得好」，稍后自动进入下一步）。
    private(set) var stepCompleted = false
    /// 登录后从「帮助」菜单重看欢迎页。
    var welcomeReplay = false
    @ObservationIgnored weak var tourModel: AppModel?
    @ObservationIgnored private var stepBaseline = 0
    @ObservationIgnored private var autoStartPending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        welcomeSeen = defaults.integer(forKey: Key.welcome) >= Self.version
        tourSeen = defaults.integer(forKey: Key.tour) >= Self.version
        checklistHidden = defaults.bool(forKey: Key.checklistHidden)
        checklistCollapsed = defaults.bool(forKey: Key.checklistCollapsed)
        marked = Set(defaults.stringArray(forKey: Key.marked) ?? [])
        taskBaseline = defaults.object(forKey: Key.taskBaseline) as? Int
    }

    // MARK: 老用户

    /// 升级上来的老用户（本机已有同步过的数据、但没有任何指引记录）：不再自动弹出，帮助菜单里随时可以重看。
    func adoptExistingUser(hasData: Bool) {
        guard hasData, defaults.object(forKey: Key.welcome) == nil, defaults.object(forKey: Key.tour) == nil else {
            return
        }
        finishWelcome()
        markTourSeen()
        checklistHidden = true
    }

    // MARK: 欢迎页

    func finishWelcome() {
        welcomeSeen = true
        welcomeReplay = false
        defaults.set(Self.version, forKey: Key.welcome)
    }

    /// 「帮助 → 新手指引」：登录后在主窗口弹出欢迎页，没登录时回到欢迎页。
    func replayWelcome(model: AppModel) {
        model.showMainWindow()
        if model.authState == .signedIn {
            welcomeReplay = true
        } else {
            welcomeSeen = false
        }
    }

    // MARK: 功能导览

    var isTouring: Bool { tourIndex != nil }

    var currentStep: TourStep? {
        guard let tourIndex, Self.tourSteps.indices.contains(tourIndex) else { return nil }
        let step = Self.tourSteps[tourIndex]
        // 浮窗球隐藏着时没法点：只看说明，并告诉用户去哪里打开。
        if step.target == .floatingBall && FloatingBallController.shared.frame == nil {
            return TourStep(step.id, target: nil, icon: step.icon, tint: step.tint, title: step.title,
                            body: step.body + "浮窗球现在是隐藏的，可以在「设置 → 高级 → 桌面浮窗球与识别日程」里打开。",
                            tip: step.tip)
        }
        return step
    }

    /// bringToFront：从设置窗口或菜单栏打开时，先切到主窗口。
    func startTour(model: AppModel, bringToFront: Bool = false) {
        guard model.authState == .signedIn else { return }
        if bringToFront { model.showMainWindow() }
        welcomeReplay = false
        tourModel = model
        if model.selectionMode { model.exitSelectionMode() }
        model.sidebarSelection = .today
        model.setMode(.list)
        tourIndex = 0
        enterStep(model: model)
        TourController.shared.start(model: model)
    }

    /// 第一次登录、首次同步完成后自动开始一次。
    func autoStartTourIfNeeded(model: AppModel) {
        guard !tourSeen, !isTouring, !autoStartPending, !welcomeReplay, model.authState == .signedIn,
              model.lastSyncedAt != nil else { return }
        autoStartPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.autoStartPending = false
            guard !self.tourSeen, !self.isTouring, model.newTaskPreset == nil else { return }
            self.startTour(model: model)
        }
    }

    func nextStep(model: AppModel) {
        guard let tourIndex else { return }
        if tourIndex + 1 < Self.tourSteps.count {
            self.tourIndex = tourIndex + 1
            enterStep(model: model)
        } else {
            endTour(model: model)
        }
    }

    func previousStep() {
        guard let tourIndex, tourIndex > 0 else { return }
        self.tourIndex = tourIndex - 1
        if let tourModel { enterStep(model: tourModel) }
    }

    /// 完成或跳过导览：回到「今天」，之后在顶部显示上手清单。
    func endTour(model: AppModel) {
        tourIndex = nil
        stepCompleted = false
        TourController.shared.stop()
        if model.selectionMode { model.exitSelectionMode() }
        model.sidebarSelection = .today
        model.setMode(.list)
        markTourSeen()
        beginChecklist(model: model)
    }

    /// 进入一步：让要高亮的控件看得见；要求的操作已经满足时先复原，免得一进来就算完成。
    private func enterStep(model: AppModel) {
        stepCompleted = false
        guard let step = currentStep else { return }
        if model.selectionMode { model.exitSelectionMode() }
        let page = model.sidebarSelection ?? .all
        if step.target?.needsTaskPage == true && page.isRecordPage { model.sidebarSelection = .today }
        if let action = step.action, Self.isSatisfied(action, model: model, baseline: model.snapshot.tasks.count) {
            model.sidebarSelection = .today
            model.setMode(.list)
        }
        stepBaseline = model.snapshot.tasks.count
    }

    private static func isSatisfied(_ action: TourAction, model: AppModel, baseline: Int) -> Bool {
        switch action {
        case .select(let item): return model.sidebarSelection == item
        case .mode(let mode): return model.effectiveMode == mode
        case .selectionMode: return model.selectionMode
        case .addTask: return model.snapshot.tasks.count > baseline
        case .capture: return RegionSelector.shared.isActive || SchedulePreviewController.shared.state.loading
        }
    }

    /// 导览定时调用：用户做到了这一步要求的操作，就打勾并稍后进入下一步。
    func checkAction(model: AppModel) {
        guard let step = currentStep, let action = step.action, !stepCompleted,
              Self.isSatisfied(action, model: model, baseline: stepBaseline) else { return }
        stepCompleted = true
        if action == .capture {
            // 已经开始识别：直接结束导览，不挡着框选。
            endTour(model: model)
            return
        }
        if action == .addTask { mark(.firstTask) }
        if case .mode(.quadrant) = action { mark(.quadrant) }
        let index = tourIndex
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard let self, self.tourIndex == index, self.stepCompleted else { return }
            self.nextStep(model: model)
        }
    }

    private func markTourSeen() {
        tourSeen = true
        defaults.set(Self.version, forKey: Key.tour)
    }

    // MARK: 上手清单

    func beginChecklist(model: AppModel) {
        guard taskBaseline == nil else { return }
        taskBaseline = model.snapshot.tasks.count
        defaults.set(model.snapshot.tasks.count, forKey: Key.taskBaseline)
    }

    func showChecklist(model: AppModel, bringToFront: Bool = false) {
        if bringToFront { model.showMainWindow() }
        checklistHidden = false
        checklistCollapsed = false
        beginChecklist(model: model)
        model.sidebarSelection = .today
    }

    func checklistVisible(on item: SidebarItem) -> Bool {
        item == .today && tourSeen && !isTouring && !checklistHidden
    }

    func mark(_ item: ChecklistItem) {
        guard marked.insert(item.rawValue).inserted else { return }
        defaults.set(Array(marked).sorted(), forKey: Key.marked)
    }

    func isDone(_ item: ChecklistItem, model: AppModel) -> Bool {
        if marked.contains(item.rawValue) { return true }
        switch item {
        case .firstTask: return taskBaseline.map { model.snapshot.tasks.count > $0 } ?? false
        case .quadrant: return false
        case .capture: return !CaptureTimingLog.records(defaults).isEmpty
        case .notifications: return model.reminderStatus == .authorized
        case .importCalendar: return !model.importSources.isEmpty
        case .ai: return model.aiKeyConfigured
        }
    }

    func doneItems(model: AppModel) -> Set<ChecklistItem> {
        Set(ChecklistItem.allCases.filter { isDone($0, model: model) })
    }

    /// 必做项完成了几项、共几项（可选项不算）。
    nonisolated static func progress(_ done: Set<ChecklistItem>) -> (done: Int, total: Int) {
        let required = ChecklistItem.required
        return (required.filter(done.contains).count, required.count)
    }

    // MARK: 重置

    /// 设置里「重新开始新人指引」：清掉全部记录，下次登录后（或马上）重新走一遍。
    func resetAll() {
        TourController.shared.stop()
        Key.all.forEach { defaults.removeObject(forKey: $0) }
        // 留下「看过第 0 版」的记录，免得下次启动又被当成老用户自动跳过。
        defaults.set(0, forKey: Key.welcome)
        defaults.set(0, forKey: Key.tour)
        welcomeSeen = false
        tourSeen = false
        checklistHidden = false
        checklistCollapsed = false
        marked = []
        taskBaseline = nil
        tourIndex = nil
        stepCompleted = false
    }
}

// MARK: - 导览步骤

extension Onboarding {
    static let tourSteps: [TourStep] = [
        TourStep(0, target: nil, icon: "hand.wave", tint: Theme.accent, title: "欢迎来到便单",
                 body: "花一分钟认识主要的地方。有几步会请你亲手点一下，点对了自动进入下一步；不想做也可以点「跳过这步」。",
                 tip: "Esc 退出导览 · ← → 切换步骤"),
        TourStep(1, target: .rowNext7, icon: "sidebar.left", tint: Quadrant.importantNotUrgent.tint,
                 title: "侧栏：换个角度看任务",
                 body: "今天、近 7 天、全部待办、重要待办、四象限、日历、日程冲突都在侧栏。下面是你的分类，右键可以新建、改名、换颜色；把任务拖到分类上就能移过去。",
                 stretch: .sidebar, action: .select(.next7), prompt: "点一下侧栏里的「近 7 天」"),
        TourStep(2, target: .summary, icon: "chart.bar.doc.horizontal", tint: Theme.done, title: "今天的进度",
                 body: "完成率和一条时间轴：每个圆点是一项定时日程，红色斜纹表示时间冲突。把鼠标移到圆点上能看详情。"),
        TourStep(3, target: .quickAdd, icon: "text.cursor", tint: Theme.accent, title: "一句话快速添加",
                 body: "像说话一样写，日期、时刻、分类、重要程度会自动识别。在别的应用里也能用「文件 → 全局快速添加」。",
                 action: .addTask, prompt: "点输入框，输入「明天下午3点 评审」后按回车"),
        TourStep(4, target: .modeSwitch, icon: "rectangle.3.group", tint: Quadrant.notImportantUrgent.tint,
                 title: "列表、四象限、日历",
                 body: "同一批任务，三种看法：列表按时间排好，四象限按重要和紧急分格，日历看一整月的安排。",
                 tip: "⌘1 – ⌘3 切换", action: .mode(.quadrant), prompt: "点「四象限」看看"),
        TourStep(5, target: .selection, icon: "checklist", tint: Quadrant.neither.tint, title: "批量选择",
                 body: "进入选择模式后可以一次勾选多项，批量完成、改期、移动分类或删除。⇧ 点击可以连选。",
                 action: .selectionMode, prompt: "点「选择」进入批量选择"),
        TourStep(6, target: .newTask, icon: "plus.circle.fill", tint: Theme.accent, title: "新建任务",
                 body: "需要设置重复、时间提醒、地点、子任务或完成目标时，点这个按钮打开完整的新建窗口。",
                 tip: "⌘N 新建"),
        TourStep(7, target: .importer, icon: "square.and.arrow.down.on.square", tint: Color(hex: 0xFA8B36),
                 title: "导入外部日历",
                 body: "把飞书、钉钉、企业微信、iCloud、邮箱账户的日程导进来，也支持订阅地址和 .ics 文件，之后定时自动同步。",
                 stretch: .sidebar, action: .select(.importer), prompt: "点侧栏里的「导入日程」"),
        TourStep(8, target: .stats, icon: "chart.bar.xaxis", tint: Color(hex: 0x8E5BD6), title: "统计",
                 body: "完成趋势、按期完成率、专注时长，还有 AI 识别用量和导入同步的情况。图表上移动鼠标就能看到具体数值。",
                 stretch: .sidebar, action: .select(.stats), prompt: "点侧栏里的「统计」"),
        TourStep(9, target: .syncBar, icon: "arrow.triangle.2.circlepath", tint: Quadrant.notImportantUrgent.tint,
                 title: "和手机、平板保持同步",
                 body: "这里显示同步状态。便单会自动和你的鸿蒙手机、平板同步，断网时的修改会排队，联网后再写入云端。",
                 tip: "⌘R 立即同步"),
        TourStep(10, target: .account, icon: "gearshape", tint: Quadrant.importantNotUrgent.tint, title: "账户与设置",
                 body: "点账户卡片或按 ⌘, 打开设置：同步间隔、一周起始与节假日调休、AI 识别日程、通知与菜单栏、本机 MCP 服务都在里面。",
                 tip: "⌘, 打开设置"),
        TourStep(11, target: .floatingBall, icon: "viewfinder.circle", tint: Color(hex: 0xFA8B36), title: "桌面浮窗球：从聊天里抓日程",
                 body: "桌面边上那个小光球：单击框选聊天区域，双击截整块屏幕，右键看更多，也可以把文字或截图直接拖上去。识别在本机完成，确认后才添加。",
                 tip: "「文件 → 框选识别日程」也能用", action: .capture,
                 prompt: "点一下高亮的浮窗球，框选一块聊天区域试试"),
    ]
}
