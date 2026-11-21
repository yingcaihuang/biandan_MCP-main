import AppKit
import SwiftUI

/// 不抢焦点的浮动面板：在任何 App 前面弹出，自己能接收键盘输入，失去焦点就收起。
final class QuickAddPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    /// 点到面板外面（切到别的窗口）时收起。
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

@MainActor
final class QuickAddPanelController {
    static let shared = QuickAddPanelController()
    private var panel: QuickAddPanel?

    func toggle(model: AppModel) {
        if panel?.isVisible == true { hide() } else { show(model: model) }
    }

    func show(model: AppModel) {
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        model.globalQuickAddSession += 1
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 放在鼠标所在屏幕的上方三分之一处。
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.28 - size.height))
    }

    private func makePanel(_ model: AppModel) -> QuickAddPanel {
        let panel = QuickAddPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 90),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.hide() }
        let root = GlobalQuickAddView(onClose: { [weak self] in self?.hide() })
            .environment(model)
            .preferredColorScheme(.light)
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        return panel
    }
}

/// 全局快速添加的输入框。写法与内容区快速添加栏相同，没写日期时默认今天、未分类。
struct GlobalQuickAddView: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @State private var added: String?
    @FocusState private var focused: Bool

    private var preset: NewTaskPreset {
        var preset = NewTaskPreset()
        preset.date = model.today
        return preset
    }

    var body: some View {
        let draft = model.parseQuickAdd(text)
        let signedIn = model.authState == .signedIn
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                TextField("", text: $text, prompt: Text("记一件事，回车保存"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { submit(draft) }
                    .onExitCommand { onClose() }
                    .disabled(saving || !signedIn)
                if saving { ProgressView().controlSize(.small) }
            }
            Group {
                if !signedIn {
                    Text("请先在便单主窗口登录华为账号").foregroundStyle(Theme.overdue)
                } else if let added {
                    Text(verbatim: "已添加「\(added)」").foregroundStyle(Theme.done)
                } else if let error {
                    Text(verbatim: error).foregroundStyle(Theme.overdue)
                } else if !draft.title.isEmpty {
                    Text(verbatim: model.quickAddHint(draft, preset: preset)).foregroundColor(Theme.subtext)
                        + Text(verbatim: model.quickAddConflictText(draft, preset: preset).map { "  " + $0 } ?? "")
                        .foregroundColor(Theme.overdue)
                } else {
                    Text("可写：明天下午3点、周五、每周一、@分类、#重要 · Esc 关闭").foregroundStyle(Theme.fieldName)
                }
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
            .padding(.leading, 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 600, alignment: .leading)
        // 面板窗口本身透明（NSPanel backgroundColor = .clear），玻璃能透出桌面。阴影由窗口提供。
        .floatingSurface(RoundedRectangle(cornerRadius: 14, style: .continuous),
                         border: Theme.accent.opacity(0.6), shadowRadius: 0, glassBorder: true)
        // 每次弹出都清空并聚焦输入框。
        .task(id: model.globalQuickAddSession) {
            text = ""
            error = nil
            added = nil
            saving = false
            try? await Task.sleep(for: .milliseconds(30))
            focused = true
        }
    }

    private func submit(_ draft: QuickAddDraft) {
        guard !saving, let input = QuickAddParser.input(draft, preset: preset) else { return }
        saving = true
        error = nil
        Task {
            let ok = await model.createTask(input)
            saving = false
            if ok {
                added = input.title
                text = ""
                try? await Task.sleep(for: .milliseconds(600))
                onClose()
            } else {
                error = model.operationError ?? "添加失败，请稍后重试"
                model.operationError = nil
            }
        }
    }
}
