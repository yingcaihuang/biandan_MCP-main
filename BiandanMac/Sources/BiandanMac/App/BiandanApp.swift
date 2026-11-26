import AppKit
import Combine
import CoreSpotlight
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 SwiftPM 可执行文件运行时也显示 Dock 图标和菜单栏；设置里选了隐藏 Dock 图标时只留菜单栏图标。
        NSApp.setActivationPolicy(MenuBarDefaults.activationPolicy)
        // swift run 时没有 .app 包里的 AppIcon.icns，这里把官方图标设为 Dock 图标；打包后两者一致。
        if let icon = BrandIcon.image { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
        // 系统「服务」菜单：选中文字或图片 → 服务 → 用便单识别日程（Info.plist 的 NSServices 由 build_app.sh 写入）。
        NSApp.servicesProvider = ScheduleServiceProvider.shared
        NSUpdateDynamicServices()
        if ReminderScheduler.isAvailable {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().setNotificationCategories([ReminderAction.category()])
        }
    }

    /// 小组件、快捷指令打开的链接：biandan://open、biandan://occurrence/<实例 ID>（开发版是 biandan-dev://）。
    /// 和点通知走同一条路：先记下要打开的位置，登录、加载完再定位。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = WidgetShared.parse(url) else { continue }
            MainActor.assumeIsolated {
                if case .occurrence(let id) = link { ReminderInbox.reveal(.occurrence(id)) }
                NotificationCenter.default.post(name: .biandanOpenOccurrence, object: nil)
            }
        }
    }

    /// 点 Spotlight 里的日程：打开便单定位到这条。
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        MainActor.assumeIsolated { SpotlightIndex.open(userActivity) }
    }

    /// 显示菜单栏图标时，关闭主窗口不退出应用。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarDefaults.isShown
    }

    // MARK: 通知

    /// 应用在前台时也显示横幅。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// 点击通知：打开主窗口并选中对应的执行实例。点操作按钮：完成、放弃本次（后台）或稍后提醒。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let id = content.userInfo["occurrenceID"] as? String
        switch ReminderAction(rawValue: response.actionIdentifier) {
        case .complete?, .abandon?:
            ReminderAcknowledgements.cancelFollowUps(content.userInfo["chainKey"] as? String)
            let abandon = response.actionIdentifier == ReminderAction.abandon.rawValue
            if let id {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if abandon {
                            ReminderInbox.pendingAbandon.append(id)
                        } else {
                            ReminderInbox.pendingComplete.append(id)
                        }
                        NotificationCenter.default.post(name: .biandanCompleteOccurrence, object: nil)
                    }
                }
            }
            completionHandler()
            return
        case let action?:
            if let seconds = action.snoozeSeconds {
                // 点了稍后提醒：这一串不再追加，改由稍后提醒来提醒。
                let chainKey = content.userInfo["chainKey"] as? String
                ReminderAcknowledgements.mark(chainKey)
                ReminderAcknowledgements.cancelFollowUps(chainKey)
                let done = UncheckedCompletion(completionHandler)
                ReminderSnooze.schedule(content, after: seconds) { done.call() }
                return
            }
        case nil:
            break
        }
        let importSource = content.userInfo["importSourceID"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // 先记下要打开的位置：应用刚被通知拉起、还没读完登录状态时，登录后再打开。
                if let id {
                    ReminderInbox.reveal(.occurrence(id))
                } else if importSource != nil {
                    ReminderInbox.reveal(.importer)
                }
                NotificationCenter.default.post(name: .biandanOpenOccurrence, object: nil)
            }
        }
        completionHandler()
    }
}

/// 把系统给的 completionHandler 交给 @Sendable 回调（系统保证它可以在任意线程调用）。
private struct UncheckedCompletion: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}

@main
struct BiandanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // 单实例窗口：从菜单栏或通知打开时切到已有窗口，不会再开一个。
        Window("便单", id: "main") {
            RootView()
                .registersMainWindowOpener()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 680)
                // 打开时铺满屏幕可用区域（菜单栏和 Dock 之外），不是全屏。
                .background(WindowSetup(maximize: true))
                .preferredColorScheme(.light)
                .task {
                    await model.bootstrap()
                    #if DEBUG
                    await model.debugAutoSelect()
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.appBecameActive()
                }
        }
        .defaultSize(width: 1380, height: 840)
        .windowToolbarStyle(.unified)
        .commands { BiandanCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .background(WindowSetup(resizable: true))
                .preferredColorScheme(.light)
        }
        // 去掉系统标题栏和标签栏，整窗使用主题侧栏布局。可以拖动边框放大，最小为默认尺寸。
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: Binding(get: { model.showMenuBarExtra },
                                         set: { model.showMenuBarExtra = $0 })) {
            MenuBarContent()
                .environment(model)
                .preferredColorScheme(.light)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct BiandanCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { AppUpdater.shared.checkForUpdates() }
                .disabled(AppUpdater.shared.unavailableReason != nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("新建任务") { model.newTaskPreset = model.makeNewTaskPreset() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.authState != .signedIn)
            Button("全局快速添加…") { QuickAddPanelController.shared.show(model: model) }
                .disabled(model.authState != .signedIn)
            Button("框选识别日程…") {
                ScheduleCaptureFlow.startRegion(model: model, anchor: FloatingBallController.shared.frame)
            }
            Button("截取整个屏幕识别日程") {
                ScheduleCaptureFlow.startFullScreen(model: model, anchor: FloatingBallController.shared.frame)
            }
            Button("识别剪贴板里的日程") {
                ScheduleCaptureFlow.fromClipboard(model: model, anchor: FloatingBallController.shared.frame)
            }
            Button("立即同步") { Task { await model.syncNow() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.authState != .signedIn)
        }
        CommandGroup(replacing: .importExport) {
            ForEach(ExportFormat.allCases) { format in
                Button("导出" + format.title + "…") { model.exportData(format) }
            }
        }
        CommandMenu("视图") {
            ForEach(Array(ContentMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.setMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(model.showInspector ? "隐藏检查器" : "显示检查器") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(model.pinMainWindow ? "取消窗口置顶" : "窗口置顶") { model.pinMainWindow.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("回到今天") {
                model.today = .today()
                model.calendarMonth = model.today.firstOfMonth
                model.calendarFocus = model.today
            }
            .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("新手指引…") { Onboarding.shared.replayWelcome(model: model) }
            Button("功能导览") { Onboarding.shared.startTour(model: model, bringToFront: true) }
                .disabled(model.authState != .signedIn)
            Button("上手清单") { Onboarding.shared.showChecklist(model: model, bringToFront: true) }
                .disabled(model.authState != .signedIn)
        }
    }
}

/// 按登录状态切换登录页和主窗口。
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.authState {
            case .checking:
                ProgressView("正在读取本机凭据…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            case .signedOut, .signingIn:
                if Onboarding.shared.welcomeSeen || model.authState == .signingIn {
                    LoginView()
                } else {
                    WelcomeView()
                }
            case .signedIn:
                MainView()
            }
        }
        // SwiftUI 窗口接到的 Spotlight 点击（AppDelegate 那边没收到时）。
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            SpotlightIndex.open(activity)
        }
        .onChange(of: model.authState) { old, new in
            guard old == .checking else { return }
            Onboarding.shared.adoptExistingUser(hasData: new == .signedIn || !model.snapshot.tasks.isEmpty)
        }
    }
}
