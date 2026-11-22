import SwiftUI

// MARK: - 欢迎页：第一次打开、登录前的几屏介绍；登录后可从「帮助」菜单重看

struct WelcomePoint: Hashable {
    let icon: String
    let text: String
}

struct WelcomePage: Identifiable {
    let id: Int
    let icon: String
    let tint: Color
    let eyebrow: String
    let title: String
    let body: String
    let points: [WelcomePoint]
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    /// 登录后从「帮助」菜单重看：最后一步改为开始功能导览。
    var replay = false
    @State private var page = 0

    static let pages: [WelcomePage] = [
        WelcomePage(id: 0, icon: "sparkles", tint: Theme.accent, eyebrow: "欢迎", title: "欢迎使用便单",
                    body: "Mac 上的待办与日程，和你的鸿蒙手机、平板实时同步。",
                    points: [
                        WelcomePoint(icon: "person.badge.key", text: "华为账号登录，任务、分类、专注记录自动双向同步"),
                        WelcomePoint(icon: "wifi.slash", text: "断网时照常记，联网后自动写入云端"),
                        WelcomePoint(icon: "lock.shield", text: "凭据存在钥匙串；识别截图、日历密码都只在本机处理"),
                    ]),
        WelcomePage(id: 1, icon: "square.grid.2x2", tint: Quadrant.importantUrgent.tint, eyebrow: "安排",
                    title: "换个角度安排时间", body: "列表、四象限、日历三种视图，同一批任务随时切换。",
                    points: [
                        WelcomePoint(icon: "text.cursor", text: "一句话快速添加：「明天下午3点 评审 @工作 #重要」"),
                        WelcomePoint(icon: "repeat", text: "重复、时间提醒、地点提醒、子任务、完成目标"),
                        WelcomePoint(icon: "calendar.badge.exclamationmark", text: "自动发现日程冲突，时间轴上一眼看到"),
                    ]),
        WelcomePage(id: 2, icon: "viewfinder", tint: Color(hex: 0xFA8B36), eyebrow: "识别",
                    title: "从聊天里一键抓日程", body: "桌面上的小光球：框选微信、飞书聊天，自动提取时间和地点。",
                    points: [
                        WelcomePoint(icon: "cursorarrow.click", text: "单击框选、双击截整屏，也能把文字或截图拖到球上"),
                        WelcomePoint(icon: "cpu", text: "在本机识别文字和日程，截图不存盘、不上传"),
                        WelcomePoint(icon: "checkmark.circle", text: "确认卡片里核对后才添加；可选接入 AI，识别更准"),
                    ]),
        WelcomePage(id: 3, icon: "square.and.arrow.down.on.square", tint: Quadrant.neither.tint, eyebrow: "导入",
                    title: "把外部日历搬进来", body: "飞书、钉钉、企业微信、iCloud、邮箱日历，导入后定时自动同步。",
                    points: [
                        WelcomePoint(icon: "calendar.badge.plus", text: "CalDAV、邮箱账户、订阅地址、.ics 文件四种方式"),
                        WelcomePoint(icon: "list.bullet.rectangle", text: "同步日志、异常通知，失败时自动放慢重试"),
                        WelcomePoint(icon: "chart.bar.xaxis", text: "统计页看完成趋势、专注时长和同步情况"),
                    ]),
        WelcomePage(id: 4, icon: "checkmark.seal", tint: Theme.done, eyebrow: "开始", title: "准备好了",
                    body: "登录后，便单会花一分钟带你认识主要功能，再给你一份上手清单。",
                    points: [
                        WelcomePoint(icon: "hand.point.up.left", text: "功能导览：逐个指出侧栏、快速添加、视图切换在哪里"),
                        WelcomePoint(icon: "flag.checkered", text: "上手清单：添加第一条任务、试一次识别、打开提醒…"),
                        WelcomePoint(icon: "questionmark.circle", text: "随时可以在「帮助」菜单里重看"),
                    ]),
    ]

    private var onboarding: Onboarding { .shared }
    private var last: Bool { page == Self.pages.count - 1 }

    var body: some View {
        let current = Self.pages[page]
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            pageView(current)
                .id(page)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 28)), removal: .opacity))
            Spacer(minLength: 12)
            bottomBar
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(.easeInOut(duration: 0.25), value: page)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            BrandLogo(size: 28)
            Text("便单").font(.system(size: 16, weight: .heavy)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if !last {
                Button(replay ? "关闭" : "跳过介绍") { onboarding.finishWelcome() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func pageView(_ item: WelcomePage) -> some View {
        HStack(alignment: .center, spacing: 44) {
            hero(item)
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: item.eyebrow)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(item.tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(item.tint.opacity(0.14)))
                Text(verbatim: item.title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Theme.text)
                Text(verbatim: item.body)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(item.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: point.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(item.tint)
                                .frame(width: 22)
                            Text(verbatim: point.text)
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: 0x4A453C))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .frame(maxWidth: 840)
    }

    private func hero(_ item: WelcomePage) -> some View {
        ZStack {
            Circle().stroke(item.tint.opacity(0.22), lineWidth: 1.5).frame(width: 260, height: 260)
            Circle().fill(item.tint.opacity(0.12)).frame(width: 220, height: 220)
            if item.id == 0 {
                BrandLogo(size: 120)
            } else {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Theme.card)
                    .frame(width: 140, height: 140)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
                    .overlay(Image(systemName: item.icon)
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(item.tint))
            }
        }
        .frame(width: 280, height: 280)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TourProgressDots(index: page, count: Self.pages.count)
            Spacer(minLength: 0)
            if last && !replay {
                Text("登录后会带你认识主要功能")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtext)
            }
            if page > 0 {
                Button("上一步") { page -= 1 }.buttonStyle(.themed)
            }
            if last && !replay {
                Button(action: finish) {
                    Text("使用华为账号登录")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.huawei))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(last ? "开始功能导览" : "下一步") { last ? finish() : (page += 1) }
                    .buttonStyle(.themedPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        onboarding.finishWelcome()
        if replay {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                Onboarding.shared.startTour(model: model)
            }
        } else {
            model.signIn()
        }
    }
}
