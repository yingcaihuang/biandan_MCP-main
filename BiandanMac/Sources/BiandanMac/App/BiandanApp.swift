import AppKit
import Combine
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 SwiftPM 可执行文件运行时也显示 Dock 图标和菜单栏。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if ReminderScheduler.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
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

    /// 点击通知：打开主窗口并选中对应的执行实例。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["occurrenceID"] as? String
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .biandanOpenOccurrence, object: nil,
                                            userInfo: id.map { ["occurrenceID": $0] })
        }
        completionHandler()
    }
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
                .preferredColorScheme(.light)
                .task { await model.bootstrap() }
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
                .preferredColorScheme(.light)
        }
        // 去掉系统标题栏和标签栏，整窗使用主题侧栏布局。
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

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
        CommandGroup(replacing: .newItem) {
            Button("新建任务") { model.newTaskPreset = model.makeNewTaskPreset() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.authState != .signedIn)
            Button("立即同步") { Task { await model.syncNow() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.authState != .signedIn)
        }
        CommandMenu("视图") {
            ForEach(Array(ContentMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.setMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(model.showInspector ? "隐藏检查器" : "显示检查器") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("回到今天") {
                model.today = .today()
                model.calendarMonth = model.today.firstOfMonth
                model.calendarFocus = model.today
            }
            .keyboardShortcut("t", modifiers: .command)
        }
    }
}

/// 按登录状态切换登录页和主窗口。
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.authState {
        case .checking:
            ProgressView("正在读取本机凭据…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        case .signedOut, .signingIn:
            LoginView()
        case .signedIn:
            MainView()
        }
    }
}
