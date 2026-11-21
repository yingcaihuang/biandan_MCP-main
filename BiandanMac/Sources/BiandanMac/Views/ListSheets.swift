import SwiftUI

// MARK: - 待办单新建 / 编辑（遵循 ThemeKit 主题规范）

struct ListEditorRequest: Identifiable {
    let id = UUID()
    /// nil 表示新建。
    var list: TodoList?
}

struct ListEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ListEditorRequest

    @State private var name: String
    @State private var colorIndex: Int
    @State private var saving = false

    init(request: ListEditorRequest) {
        self.request = request
        _name = State(initialValue: request.list?.favoritesName ?? "")
        _colorIndex = State(initialValue: request.list?.color.colorIndex ?? 1)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let swatchColor = ListColor(sortIndex: 0, colorIndex: colorIndex).color
        ThemedSheet(request.list == nil ? "新建待办单" : "编辑待办单",
                    subtitle: "待办单会同步到你的便单账号",
                    tag: ThemeTag(text: trimmed.isEmpty ? "未命名" : trimmed, color: swatchColor)) {
            InspectorSection("名称") {
                TextField("", text: $name, prompt: Text("例如：工作"))
                    .themedField()
                    .padding(10)
            }

            InspectorSection("颜色") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        swatch(0)
                        Text("默认色").font(.system(size: 11.5)).foregroundStyle(Theme.subtext)
                        Spacer()
                        FieldTag("favoritesColor % 100")
                    }
                    ForEach(0..<3, id: \.self) { group in
                        HStack(spacing: 8) {
                            Text(ListColor.groupNames[group])
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.subtext)
                                .frame(width: 40, alignment: .leading)
                            ForEach(1...8, id: \.self) { hue in
                                swatch(group * 8 + hue)
                            }
                        }
                    }
                }
                .padding(12)
            }

            ThemedErrorText(message: model.operationError)
        } footer: {
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button(request.list == nil ? "创建" : "保存") { save() }
                .buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || trimmed.isEmpty)
        }
        .frame(width: 440, height: 440)
        .onAppear { model.operationError = nil }
    }

    private func swatch(_ index: Int) -> some View {
        Button {
            colorIndex = index
        } label: {
            Circle()
                .fill(ListColor(sortIndex: 0, colorIndex: index).color)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Theme.text, lineWidth: colorIndex == index ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "默认色" : "\(ListColor.groupNames[(index - 1) / 8])\(ListColor.hueNames[(index - 1) % 8])（\(index)）")
    }

    private func save() {
        let newName = trimmed
        let color = colorIndex
        saving = true
        Task {
            let ok: Bool
            if let list = request.list {
                ok = await model.updateList(list.id3,
                                            name: newName != list.favoritesName ? newName : nil,
                                            colorIndex: color != list.color.colorIndex ? color : nil)
            } else {
                ok = await model.createList(name: newName, colorIndex: color) != nil
            }
            saving = false
            if ok { dismiss() }
        }
    }
}

// MARK: - 待办单删除

struct ListDeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let list: TodoList
    @State private var working = false

    var body: some View {
        let count = model.snapshot.tasks.values.filter { $0.id3 == list.id3 }.count
        ThemedSheet("删除待办单", subtitle: list.displayName,
                    tag: ThemeTag(text: "无法撤销", color: Theme.overdue)) {
            InspectorSection("影响范围") {
                HStack(spacing: 8) {
                    Circle().fill(list.swatch).frame(width: 10, height: 10)
                    Text(verbatim: count == 0 ? "这个待办单里没有任务。" : "其中有 \(count) 个任务。")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0x4A453C))
                .padding(10)
            }
            if count > 0 {
                Text("可以把任务移回「未分类」，也可以连同任务一起删除。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
            Text("删除会同步到云端和其他设备。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.overdue)
            ThemedErrorText(message: model.operationError)
        } footer: {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            if count > 0 {
                Button("连同任务删除", role: .destructive) { run(deleteTasks: true) }
                    .buttonStyle(.themedDestructive)
                    .disabled(working)
            }
            Button(count > 0 ? "删除，任务移回未分类" : "删除") { run(deleteTasks: false) }
                .buttonStyle(count > 0 ? .themedPrimary : .themedDestructive)
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        }
        .frame(width: 480, height: 320)
        .onAppear { model.operationError = nil }
    }

    private func run(deleteTasks: Bool) {
        working = true
        let id = list.id3
        Task {
            let ok = await model.deleteList(id, deleteTasks: deleteTasks)
            working = false
            if ok { dismiss() }
        }
    }
}
