import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 SwiftPM 可执行文件运行时也显示 Dock 图标和菜单栏。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct BiandanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("便单", id: "main") {
            RootView()
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
