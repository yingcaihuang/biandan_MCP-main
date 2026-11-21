import SwiftUI

// MARK: - 通用编辑行

private struct EditRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    let label: String
    let field: String?
    let stacked: Bool
    let content: Content

    init(_ label: String, field: String? = nil, stacked: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.field = field
        self.stacked = stacked
        self.content = content()
    }

    private var labelView: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Color(hex: 0x4A453C))
                .fixedSize()
            if model.showFieldNames, let field {
                // 空间不够时字段名先缩成省略号，不撑宽检查器。
                FieldTag(field).layoutPriority(-1)
            }
        }
    }

    var body: some View {
        // 一行放不下时把控件换到下一行，不撑宽检查器。
        // 撑宽会让检查器整体溢出、居中，显示位置和点击位置错开（控件点不动、输入法气泡跑到别处）。
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    labelView
                    content.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 8) {
                    labelView
                    Spacer(minLength: 6)
                    content.layoutPriority(1)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

/// 保存栏左侧的次要按钮（例如「清除地点」）。
private struct SecondaryAction {
    let title: String
    let action: () -> Void
}

private struct SaveBar: View {
    let title: String
    let enabled: Bool
    var secondary: SecondaryAction? = nil
    let action: () -> Void

    var body: some View {
        HStack {
            if let secondary {
                Button(secondary.title, role: .destructive, action: secondary.action)
                    .buttonStyle(.themed)
            }
            Spacer()
            Button(title, action: action)
                .buttonStyle(.themedPrimary)
                .disabled(!enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

private func asyncBinding<T>(_ value: T, _ apply: @escaping (T) async -> Void) -> Binding<T> {
    Binding(get: { value }, set: { newValue in Task { await apply(newValue) } })
}

// MARK: - 本次操作（showTask）

struct OccurrenceActionsPanel: View {
    @Environment(AppModel.self) private var model
    let item: OccurrenceItem

    var body: some View {
        let progress = item.progress
        let subtasks = item.task.content.subtasks
        InspectorSection("本次操作") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    switch item.status {
                    case .pending:
                        Button("✓ 完成本次") { Task { await model.toggleCompletion(item) } }
                            .buttonStyle(.themedPrimary)
                        Button("放弃本次") { Task { await model.abandon(item) } }
                        if progress.completedCount > 0 {
                            Button("清零进度") { Task { await model.reopen(item) } }
                        }
                    case .completed:
                        Button("撤销完成") { Task { await model.toggleCompletion(item) } }
                    case .abandoned:
                        Button("恢复") { Task { await model.toggleCompletion(item) } }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.deleteRequest = item
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("删除…")
                }
                .buttonStyle(.themed)

                if item.task.goal.isChecklist {
                    ForEach(Array(subtasks.enumerated()), id: \.offset) { index, title in
                        Toggle(isOn: asyncBinding(progress.completedSubtaskIndices.contains(index)) { checked in
                            await model.setSubtask(item, index: index, checked: checked)
                        }) {
                            Text(title)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!item.task.goal.includes(subtask: index) || item.status == .abandoned)
                    }
                } else if progress.targetCount > 1 && item.status != .abandoned {
                    Stepper(value: asyncBinding(progress.completedCount) { count in
                        await model.setCount(item, count: count)
                    }, in: 0...progress.targetCount) {
                        Text(verbatim: "已完成 \(progress.completedCount) / \(progress.targetCount) 次")
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(10)
        }
    }
}

// MARK: - 编辑任务定义（Task）

struct TaskEditPanel: View {
    @Environment(AppModel.self) private var model
    let task: TaskDef
    let occurrence: Occurrence

    @State private var title: String
    @State private var remark: String
    @State private var hasDate: Bool
    @State private var hasTime: Bool
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var startClock: Date
    @State private var endClock: Date
    @State private var remindOn: Bool
    @State private var remindAt: Date
    @State private var locationName: String
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var locationRemind: Bool
    @State private var showMapPicker = false
    @State private var checklist: Bool
    @State private var targetCount: Int
    @State private var subtasks: [String]

    init(task: TaskDef, occurrence: Occurrence) {
        self.task = task
        self.occurrence = occurrence
        let content = task.content
        let start = (task.undated ? nil : occurrence.startDate) ?? LocalDate.today()
        let end = (task.undated ? nil : occurrence.endDate) ?? start
        let startTime = occurrence.startClock ?? .startOfDay
        let endTime = occurrence.endClock ?? LocalTime(hour: 23, minute: 59)!
        _title = State(initialValue: task.taskTitle)
        _remark = State(initialValue: content.remark)
        _hasDate = State(initialValue: !task.undated)
        _hasTime = State(initialValue: !(startTime.hour == 0 && startTime.minute == 0
                                         && endTime.hour == 23 && endTime.minute == 59))
        _startDay = State(initialValue: start.date())
        _endDay = State(initialValue: end.date())
        _startClock = State(initialValue: startTime.date(on: start))
        _endClock = State(initialValue: endTime.date(on: end))
        let remindDay = LocalDate(iso: task.remindDate) ?? start
        let remindTime = LocalTime(text: task.remindTime) ?? LocalTime(hour: 9, minute: 0)!
        _remindOn = State(initialValue: task.hasTimeReminder)
        _remindAt = State(initialValue: remindTime.date(on: remindDay))
        _locationName = State(initialValue: task.location)
        _latitudeText = State(initialValue: task.hasCoordinate ? String(task.latitude) : "")
        _longitudeText = State(initialValue: task.hasCoordinate ? String(task.longitude) : "")
        _locationRemind = State(initialValue: task.hasLocationReminder)
        _checklist = State(initialValue: task.goal.isChecklist)
        _targetCount = State(initialValue: task.goal.isChecklist ? 1 : task.goal.targetCount)
        _subtasks = State(initialValue: content.subtasks)
    }

    @FocusState private var titleFocused: Bool

    private var taskID: String { task.id1 }

    /// 保存标题和备注（保存按钮、标题框回车共用）。
    private func saveText() {
        let content = task.content
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRemark = remark
        guard !newTitle.isEmpty, newTitle != task.taskTitle || newRemark != content.remark else { return }
        let id = taskID
        let oldTitle = task.taskTitle
        Task {
            await model.updateTask(id,
                                   title: newTitle != oldTitle ? newTitle : nil,
                                   remark: newRemark != content.remark ? newRemark : nil)
        }
    }

    /// 主窗口按回车后，把焦点放到标题框（检查器刚打开时稍等它出现）。
    private func focusTitleIfRequested() async {
        guard model.pendingTitleFocus else { return }
        model.pendingTitleFocus = false
        try? await Task.sleep(for: .milliseconds(120))
        titleFocused = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            textSection
            flagsSection
            scheduleSection
            reminderSection
            locationSection
            goalSection
        }
        // 不再整块禁用：保存都是后台 + 乐观，界面立即生效，可以继续编辑。
    }

    // MARK: 标题、备注

    private var textSection: some View {
        let content = task.content
        let changed = title.trimmingCharacters(in: .whitespacesAndNewlines) != task.taskTitle || remark != content.remark
        return InspectorSection("编辑 · 标题与备注") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("标题", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit { saveText() }
                    .task(id: model.titleFocusRequest) { await focusTitleIfRequested() }
                TextField("备注", text: $remark, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                if !content.attachments.isEmpty {
                    Text(verbatim: "附件 \(content.attachments.count) 个，修改备注时会保留")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                }
            }
            .padding(10)
            SaveBar(title: "保存", enabled: changed && !title.trimmingCharacters(in: .whitespaces).isEmpty) {
                saveText()
            }
        }
    }

    // MARK: 标志、待办单（即时生效）

    private var flagsSection: some View {
        let id = taskID
        return InspectorSection("编辑 · 分类") {
            EditRow("分类", field: "id3") {
                ThemedListPicker(selection: asyncBinding(task.id3) { listID in
                    await model.moveTask(id, to: listID)
                })
            }
            EditRow("重要", field: "isImportant") {
                Toggle("", isOn: asyncBinding(task.important) { await model.updateTask(id, important: $0) })
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            EditRow("紧急", field: "isUrgency") {
                Toggle("", isOn: asyncBinding(task.urgent) { await model.updateTask(id, urgent: $0) })
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            EditRow("收藏", field: "isCollectible") {
                Toggle("", isOn: asyncBinding(task.collected) { await model.updateTask(id, collected: $0) })
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
        }
    }

    // MARK: 时间

    private var scheduleSection: some View {
        InspectorSection("编辑 · 时间") {
            if task.isRepeating {
                EditRow("规则", field: "loopSet") {
                    Text(RuleSummary.describe(task))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(1)
                }
                if occurrence.status == .pending {
                    EditRow("这一次", field: "showTask.startTime") {
                        ThemedDateField(date: $startDay)
                    }
                    EditRow("指定时刻") {
                        Toggle("", isOn: $hasTime).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    }
                    if hasTime {
                        EditRow("开始时刻", field: "validStartTime") { ThemedTimeField(time: $startClock) }
                        EditRow("结束时刻", field: "validEndTime") { ThemedTimeField(time: $endClock) }
                    }
                    Text("只改这一次：它会脱离重复系列，变成单独的一次性任务，其他日期不变。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.subtext)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    SaveBar(title: "只改这一次", enabled: true,
                            secondary: SecondaryAction(title: "编辑规则…", action: { model.recurrenceRequest = task })) {
                        saveSchedule()
                    }
                } else {
                    SaveBar(title: "编辑重复规则…", enabled: true) { model.recurrenceRequest = task }
                }
            } else if occurrence.status != .pending {
                Text("只有待完成的任务可以改期。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                EditRow("指定日期", field: "haveNoTime") {
                    Toggle("", isOn: $hasDate).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                }
                if hasDate {
                    EditRow("开始", field: "startTime") {
                        ThemedDateField(date: $startDay)
                    }
                    EditRow("结束", field: "endTime") {
                        ThemedDateField(date: $endDay, minimum: startDay)
                    }
                    EditRow("指定时刻") {
                        Toggle("", isOn: $hasTime).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    }
                    if hasTime {
                        EditRow("开始时刻", field: "validStartTime") {
                            ThemedTimeField(time: $startClock)
                        }
                        EditRow("结束时刻", field: "validEndTime") {
                            ThemedTimeField(time: $endClock)
                        }
                    }
                }
                SaveBar(title: "保存时间", enabled: true,
                        secondary: SecondaryAction(title: "设为重复…", action: { model.recurrenceRequest = task })) {
                    saveSchedule()
                }
            }
        }
    }

    private func saveSchedule() {
        let item = OccurrenceItem(occurrence: occurrence, task: task)
        guard hasDate else {
            Task { await model.clearSchedule(taskID) }
            return
        }
        let start = LocalDate.today(startDay)
        let end = max(LocalDate.today(endDay), start)
        let from = hasTime ? LocalTime.from(startClock) : LocalTime.startOfDay
        let to = hasTime ? LocalTime.from(endClock) : LocalTime(hour: 23, minute: 59)!
        Task { await model.reschedule(item, start: start, end: end, startTime: from, endTime: to) }
    }

    // MARK: 时间提醒

    private var reminderSection: some View {
        InspectorSection("编辑 · 时间提醒") {
            EditRow("时间提醒", field: "isRemind bit0") {
                Toggle("", isOn: $remindOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            if remindOn {
                EditRow("提醒于", field: "remindDate·remindTime", stacked: true) {
                    HStack(spacing: 6) {
                        ThemedDateField(date: $remindAt)
                        ThemedTimeField(time: $remindAt)
                    }
                }
            }
            SaveBar(title: "保存提醒", enabled: true) {
                let enabled = remindOn
                let day = LocalDate.today(remindAt)
                let time = LocalTime.from(remindAt)
                Task { await model.setTimeReminder(taskID, date: day, time: time, enabled: enabled) }
            }
        }
    }

    // MARK: 地点

    private var locationSection: some View {
        let id = taskID
        let clear: SecondaryAction?
        if task.hasLocation {
            clear = SecondaryAction(title: "清除地点", action: { Task { await model.clearLocation(id) } })
        } else {
            clear = nil
        }
        return InspectorSection("编辑 · 地点") {
            EditRow("地点", field: "location") {
                TextField("名称或地址", text: $locationName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            EditRow("地图", field: "MapKit") {
                Button("在地图上选点…") { showMapPicker = true }
                    .buttonStyle(.themed)
            }
            EditRow("纬度", field: "latitude") {
                TextField("GCJ-02", text: $latitudeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }
            EditRow("经度", field: "longitude") {
                TextField("GCJ-02", text: $longitudeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
            }
            EditRow("地点提醒", field: "isRemind bit1") {
                Toggle("", isOn: $locationRemind).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            SaveBar(title: "保存地点", enabled: true, secondary: clear) {
                saveLocation()
            }
        }
        .sheet(isPresented: $showMapPicker) {
            LocationPickerSheet(initialName: locationName,
                                initial: GeoText.coordinate(latitude: latitudeText, longitude: longitudeText)) { picked in
                if !picked.name.isEmpty { locationName = picked.name }
                latitudeText = GeoText.format(picked.latitude)
                longitudeText = GeoText.format(picked.longitude)
            }
            .environment(model)
        }
    }

    private func saveLocation() {
        let latText = latitudeText.trimmingCharacters(in: .whitespaces)
        let lonText = longitudeText.trimmingCharacters(in: .whitespaces)
        var latitude: Double?
        var longitude: Double?
        if latText.isEmpty && lonText.isEmpty {
            // 清空坐标：原来有坐标时写回 -1, -1。
            if task.hasCoordinate {
                latitude = -1
                longitude = -1
            }
        } else {
            guard let lat = Double(latText), let lon = Double(lonText) else {
                model.operationError = "纬度和经度需要一起填写，并且是数字。"
                return
            }
            latitude = lat
            longitude = lon
        }
        let name = locationName
        let remind = locationRemind
        Task {
            await model.setLocation(taskID, name: name, latitude: latitude, longitude: longitude, remind: remind)
        }
    }

    // MARK: 完成目标

    private var goalSection: some View {
        InspectorSection("编辑 · 完成目标") {
            EditRow("方式", field: "unitTimeNumber") {
                ThemedSegmented(selection: $checklist,
                                options: [ThemeOption(value: false, title: "按次数"),
                                          ThemeOption(value: true, title: "子任务")])
            }
            if checklist {
                ForEach(subtasks.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        FieldTag("bit \(index)")
                        TextField("子任务", text: Binding(
                            get: { index < subtasks.count ? subtasks[index] : "" },
                            set: { if index < subtasks.count { subtasks[index] = $0 } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button {
                            if index < subtasks.count { subtasks.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                Button("＋ 添加子任务") { subtasks.append("") }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .disabled(subtasks.count >= 20)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Text("已有进度时只能原位改名、在末尾追加或从末尾删减。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            } else {
                EditRow("每次次数") {
                    Stepper(value: $targetCount, in: 1...99) {
                        Text(verbatim: "\(targetCount) 次")
                    }
                    .fixedSize()
                }
            }
            SaveBar(title: "保存目标", enabled: true) {
                let titles = subtasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let useChecklist = checklist && !titles.isEmpty
                let count = targetCount
                Task {
                    await model.editGoal(taskID, subtasks: useChecklist ? titles : nil,
                                         targetCount: useChecklist ? nil : (checklist ? 1 : count))
                }
            }
        }
    }
}
