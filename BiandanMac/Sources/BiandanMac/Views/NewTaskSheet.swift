import SwiftUI

// MARK: - Date ↔ LocalDate / LocalTime

extension LocalTime {
    static func from(_ date: Date, calendar: Calendar = .current) -> LocalTime {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return LocalTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) ?? .startOfDay
    }

    func date(on day: LocalDate, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                           hour: hour, minute: minute)) ?? Date()
    }
}

extension AppModel {
    /// 按当前侧栏位置生成新建任务的预设。
    func makeNewTaskPreset() -> NewTaskPreset {
        var preset = NewTaskPreset()
        switch sidebarSelection {
        case .list(let id)?:
            preset.listID = id
            preset.date = today
        case .undated?:
            preset.date = nil
        case .important?:
            // 在「重要待办」里新建的任务默认标为重要。
            preset.important = true
            preset.date = today
        // 在「逾期」里新建的任务也默认今天（新建的不会是逾期的，会出现在「今天」里）。
        case .overdue?, .collected?, .today?, .next7?, .all?, .quadrant?, .calendar?, .completed?, .abandoned?, .focus?, .habits?, .stats?, .conflicts?, .importer?, nil:
            preset.date = today
        }
        return preset
    }
}

private struct SubtaskDraft: Identifiable {
    let id = UUID()
    var title: String
}

private enum GoalMode: String, CaseIterable, Identifiable {
    case count, checklist
    var id: String { rawValue }
    var title: String { self == .count ? "按次数" : "子任务" }
}

// MARK: - 新建任务

/// 新建任务（一次性或重复）。外观沿用四象限主题，标题栏随所选象限变色。
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var remark = ""
    @State private var listID: String
    @State private var quadrant: Quadrant
    @State private var hasDate: Bool
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var hasTime = false
    @State private var startClock: Date
    @State private var endClock: Date
    @State private var goalMode: GoalMode = .count
    @State private var targetCount = 1
    @State private var subtasks: [SubtaskDraft] = []
    @State private var remind = false
    @State private var remindAt: Date
    @State private var saving = false
    @State private var repeats = false
    @State private var ruleDraft: RuleDraft

    init(preset: NewTaskPreset) {
        let day = preset.date ?? LocalDate.today()
        let hour = (Calendar.current.component(.hour, from: Date()) + 1) % 24
        let start = (LocalTime(hour: hour, minute: 0) ?? .startOfDay).date(on: day)
        _listID = State(initialValue: preset.listID)
        _quadrant = State(initialValue: Quadrant(important: preset.important, urgent: preset.urgent))
        _hasDate = State(initialValue: preset.date != nil)
        _startDay = State(initialValue: day.date())
        _endDay = State(initialValue: day.date())
        _startClock = State(initialValue: start)
        _endClock = State(initialValue: start.addingTimeInterval(30 * 60))
        _remindAt = State(initialValue: start)
        _ruleDraft = State(initialValue: RuleDraft(start: day))
    }

    private var validStart: String { hasTime ? BiandanService.clockText(LocalTime.from(startClock)) : "00:00:00" }
    private var validEnd: String { hasTime ? BiandanService.clockText(LocalTime.from(endClock)) : "23:59:00" }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ThemedSheet("新建任务", subtitle: "保存后同步到你的便单账号，手机和其他设备都能看到",
                    tag: ThemeTag(text: quadrant.title, color: quadrant.tint),
                    headerFill: quadrant.fill, titleColor: quadrant.titleColor) {
            InspectorSection("内容") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("", text: $title, prompt: Text("要做什么？"))
                        .themedField()
                    TextField("", text: $remark, prompt: Text("备注（可选）"), axis: .vertical)
                        .lineLimit(2...5)
                        .themedField()
                }
                .padding(10)
            }

            InspectorSection("四象限") {
                QuadrantPicker(selection: $quadrant)
                    .padding(10)
            }

            InspectorSection("归类") {
                ThemedRow("分类", field: "id3") {
                    ThemedListPicker(selection: $listID, tint: quadrant.tint)
                }
            }

            InspectorSection("时间") {
                ThemedRow("指定日期", field: "haveNoTime") { ThemedSwitch(isOn: $hasDate) }
                if hasDate {
                    ThemedRow("开始日期", field: "startTime") {
                        ThemedDateField(date: $startDay, tint: quadrant.tint)
                    }
                    ThemedRow(repeats ? "重复截止" : "结束日期", field: "endTime") {
                        ThemedDateField(date: $endDay, minimum: startDay, tint: quadrant.tint)
                    }
                    ThemedRow("指定时刻") { ThemedSwitch(isOn: $hasTime) }
                    if hasTime {
                        ThemedRow("开始时刻", field: "validStartTime") {
                            ThemedTimeField(time: $startClock, tint: quadrant.tint)
                        }
                        ThemedRow("结束时刻", field: "validEndTime") {
                            ThemedTimeField(time: $endClock, tint: quadrant.tint)
                        }
                    }
                    ThemedRow("时间提醒", field: "isRemind") { ThemedSwitch(isOn: $remind) }
                    if remind {
                        ThemedRow("提醒于", field: "remindDate·remindTime") {
                            HStack(spacing: 6) {
                                ThemedDateField(date: $remindAt, tint: quadrant.tint)
                                ThemedTimeField(time: $remindAt, tint: quadrant.tint)
                            }
                                .labelsHidden()
                        }
                    }
                }
            }

            if hasDate {
                InspectorSection("重复") {
                    ThemedRow("重复", field: "isLoop") { ThemedSwitch(isOn: $repeats) }
                }
                if repeats {
                    RepeatRuleEditor(draft: $ruleDraft, start: LocalDate.today(startDay), end: LocalDate.today(endDay),
                                     validStart: validStart, validEnd: validEnd, tint: quadrant.tint)
                }
            }

            InspectorSection("完成目标") {
                ThemedRow("方式", field: "unitTimeNumber") {
                    ThemedSegmented(selection: $goalMode,
                                    options: GoalMode.allCases.map { ThemeOption(value: $0, title: $0.title) })
                }
                if goalMode == .count {
                    ThemedRow("每次需完成") {
                        Stepper(value: $targetCount, in: 1...99) {
                            Text(verbatim: "\(targetCount) 次")
                        }
                        .fixedSize()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($subtasks) { $draft in
                            HStack(spacing: 6) {
                                TextField("", text: $draft.title, prompt: Text("子任务"))
                                    .themedField()
                                Button {
                                    subtasks.removeAll { $0.id == draft.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(Theme.subtext)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button("＋ 添加子任务") { subtasks.append(SubtaskDraft(title: "")) }
                            .buttonStyle(.themed)
                            .disabled(subtasks.count >= 20)
                    }
                    .padding(10)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
                    }
                }
            }

            ThemedErrorText(message: model.operationError)
        } footer: {
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("创建") { save() }
                .buttonStyle(.themedPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty || saving)
        }
        .frame(width: 520, height: 660)
        // 开始日期晚于结束日期时，结束日期跟着移。
        .onChange(of: startDay) { _, newValue in
            if endDay < newValue { endDay = newValue }
        }
        // 打开重复时，截止日期默认延后一个月。
        .onChange(of: repeats) { _, on in
            let start = LocalDate.today(startDay)
            if on && LocalDate.today(endDay) <= start {
                endDay = start.adding(months: 1).date()
            }
        }
        // 同一天里结束时刻不晚于开始时刻时，结束时刻自动设为开始后 30 分钟。
        .onChange(of: startClock) { _, newValue in
            guard LocalDate.today(startDay) == LocalDate.today(endDay) else { return }
            let start = LocalTime.from(newValue)
            guard LocalTime.from(endClock) <= start else { return }
            let total = min(start.hour * 60 + start.minute + 30, 23 * 60 + 59)
            if let shifted = LocalTime(hour: total / 60, minute: total % 60) {
                endClock = shifted.date(on: LocalDate.today(endClock))
            }
        }
        .onAppear { model.operationError = nil }
    }

    private func save() {
        var input = CreateTaskInput(title: trimmedTitle)
        input.remark = remark
        input.listID = listID
        input.important = quadrant.isImportant
        input.urgent = quadrant.isUrgent
        if hasDate {
            let start = LocalDate.today(startDay)
            let end = max(LocalDate.today(endDay), start)
            input.startDate = start
            input.endDate = end
            if hasTime {
                input.startTime = LocalTime.from(startClock)
                input.endTime = LocalTime.from(endClock)
            }
            if remind {
                input.reminderDate = LocalDate.today(remindAt)
                input.reminderTime = LocalTime.from(remindAt)
            }
            if repeats {
                input.repeatRule = ruleDraft.rule
                input.habit = ruleDraft.habit
            }
        }
        switch goalMode {
        case .count:
            input.targetCount = targetCount
        case .checklist:
            let titles = subtasks.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if titles.isEmpty {
                input.targetCount = 1
            } else {
                input.subtasks = titles
            }
        }
        saving = true
        let final = input
        Task {
            let ok = await model.createTask(final)
            saving = false
            if ok { dismiss() }
        }
    }
}

// MARK: - 删除确认

/// 删除前先预览影响范围；重复任务需要选择范围。
struct DeleteTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: OccurrenceItem

    @State private var scope: DeleteScope = .occurrence
    @State private var plan: DeletePlan?
    @State private var loading = false
    @State private var working = false

    var body: some View {
        let quadrant = item.task.quadrant
        ThemedSheet("删除任务",
                    subtitle: item.task.taskTitle.isEmpty ? "（无标题）" : item.task.taskTitle,
                    tag: ThemeTag(text: "无法撤销", color: Theme.overdue),
                    headerFill: quadrant.fill, titleColor: quadrant.titleColor) {
            if item.task.isRepeating {
                InspectorSection("删除范围") {
                    ThemedChoiceList(selection: $scope,
                                     options: DeleteScope.allCases.map { ThemeOption(value: $0, title: $0.title) })
                }
                if scope == .futurePending, let start = item.occurrence.startDate {
                    Text(verbatim: "从 \(start.iso) 起，未完成的实例会被删除。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.subtext)
                }
            }

            InspectorSection("影响范围") {
                HStack(spacing: 6) {
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("正在计算影响范围…")
                    } else if let plan {
                        Image(systemName: "info.circle").foregroundStyle(Theme.subtext)
                        Text(verbatim: "将删除 \(plan.occurrenceIDs.count) 个执行实例"
                             + (plan.deletesTaskDefinition ? "，并删除任务定义。" : "，保留任务定义。"))
                    } else {
                        Text("无法计算影响范围")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0x4A453C))
                .padding(10)
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
            Button("删除", role: .destructive) { confirm() }
                .buttonStyle(.themedDestructive)
                .keyboardShortcut(.defaultAction)
                .disabled(working || loading || plan == nil)
        }
        .frame(width: 440, height: item.task.isRepeating ? 440 : 330)
        .onAppear { model.operationError = nil }
        .task(id: scope) { await refresh() }
    }

    private func refresh() async {
        loading = true
        plan = await model.deletePlan(item, scope: scope)
        loading = false
    }

    private func confirm() {
        working = true
        Task {
            let ok = await model.deleteTask(item, scope: scope)
            working = false
            if ok { dismiss() }
        }
    }
}
