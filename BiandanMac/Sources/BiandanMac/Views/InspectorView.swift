import SwiftUI

/// 右侧检查器。P3 只读，逐项展示四张表的全部字段，旁边标注云端字段名。
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let focus = model.selectedFocus {
                FocusInspector(record: focus)
            } else if let item = model.selectedItem {
                TaskInspector(item: item)
            } else {
                ContentUnavailableView("未选择", systemImage: "sidebar.trailing",
                                       description: Text("点击任务卡片或专注记录查看全部字段"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
    }
}

// MARK: - 通用组件

struct InspectorSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.subtext)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
    }
}

struct FieldRow: View {
    @Environment(AppModel.self) private var model
    let label: String
    var field: String? = nil
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Color(hex: 0x4A453C))
            if model.showFieldNames, let field {
                FieldTag(field)
            }
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
        }
    }
}

struct StatusBadge: View {
    let status: OccurrenceStatus

    var body: some View {
        Text(status.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(status.badgeFill))
    }
}

/// 传输层信息：云记录 ID、版本、创建与修改时间。
struct MetaRows: View {
    let meta: RecordMeta?

    var body: some View {
        FieldRow(label: "云记录 ID", value: meta?.cloudID ?? "—")
        FieldRow(label: "版本", field: "version", value: meta?.version.map { String($0) } ?? "—")
        FieldRow(label: "创建时间", field: "createdTime", value: meta?.createdTime ?? "—")
        FieldRow(label: "修改时间", field: "editedTime", value: meta?.editedTime ?? "—")
    }
}

/// 云端返回了文档以外的字段时列出来，写回时原样保留。
struct ExtraFieldsSection: View {
    let kind: RecordKind
    let raw: JSONObject

    var body: some View {
        let known = Set(StoreSchema.columns(kind).map(\.key))
        let keys = raw.keys.filter { !known.contains($0) }.sorted()
        if !keys.isEmpty {
            InspectorSection("其他字段（\(kind.rawValue)，写回时原样保留）") {
                ForEach(keys, id: \.self) { key in
                    FieldRow(label: key, value: raw[key]?.displayText ?? "")
                }
            }
        }
    }
}

struct RawJSONSection: View {
    let title: String
    let raw: JSONObject
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(JSONValue.object(raw).serializedString(pretty: true))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.subtext)
        }
    }
}

private func flag(_ value: Int) -> String {
    value != 0 ? "是（\(value)）" : "否（0）"
}

private func text(_ value: String?) -> String {
    guard let value else { return "—" }
    return value.isEmpty ? "（空）" : value
}

// MARK: - 任务 + 执行实例

struct TaskInspector: View {
    @Environment(AppModel.self) private var model
    @AppStorage("biandan.showReadonlyFields") private var showReadonly = false
    let item: OccurrenceItem

    var body: some View {
        let task = item.task
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.taskTitle.isEmpty ? "（无标题）" : task.taskTitle)
                        .font(.system(size: 18, weight: .bold))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        StatusBadge(status: item.status)
                        if item.isOverdue(today: model.today) {
                            Text("已逾期").font(.system(size: 11)).foregroundStyle(Theme.overdue)
                        }
                        Spacer()
                        if model.isBusy || model.isSavingInBackground {
                            ProgressView().controlSize(.mini)
                                .help("正在保存到云端，可以继续操作")
                        }
                    }
                }
                OccurrenceActionsPanel(item: item)
                TaskEditPanel(task: task, occurrence: item.occurrence)
                    // 云端版本变化或切换实例时重置草稿。
                    .id("\(task.id1)#\(task.meta?.version ?? 0)#\(item.id)#\(item.occurrence.meta?.version ?? 0)")
                // 只读字段默认折叠，避免和上面能编辑的项混在一起。
                DisclosureGroup(isExpanded: $showReadonly) {
                    VStack(alignment: .leading, spacing: 14) {
                basics(task)
                schedule(task)
                recurrence(task)
                goal(task)
                reminders(task)
                currentOccurrence(task)
                allOccurrences(task)
                InspectorSection("高级 · Task") {
                    FieldRow(label: "任务 ID", field: "id1", value: task.id1)
                    FieldRow(label: "汇总完成", field: "isFinish", value: flag(task.isFinish))
                    MetaRows(meta: task.meta)
                }
                ExtraFieldsSection(kind: .task, raw: task.meta?.raw ?? [:])
                ExtraFieldsSection(kind: .showTask, raw: item.occurrence.meta?.raw ?? [:])
                RawJSONSection(title: "原始 JSON · Task", raw: task.meta?.raw ?? [:])
                RawJSONSection(title: "原始 JSON · showTask", raw: item.occurrence.meta?.raw ?? [:])
                    }
                    .padding(.top, 8)
                } label: {
                    Text("全部字段（只读，仅供查看）")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.subtext)
                }
                .padding(.top, 6)
            }
            // 内容宽度跟随检查器这一栏，不允许被子视图撑宽。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    // MARK: 分区

    private func basics(_ task: TaskDef) -> some View {
        let content = task.content
        let list = model.snapshot.list(task.id3)
        return InspectorSection("基本") {
            FieldRow(label: "备注", field: "taskContent", value: content.remark.isEmpty ? "—" : content.remark)
            FieldRow(label: "附件", field: "taskContent",
                     value: content.attachments.isEmpty ? "无" : content.attachments.joined(separator: "\n"),
                     valueColor: Theme.subtext)
            FieldRow(label: "待办单", field: "id3",
                     value: "\(list?.displayName ?? "未知待办单")（\(task.id3)）")
            FieldRow(label: "收藏", field: "isCollectible", value: flag(task.isCollectible))
            FieldRow(label: "重要", field: "isImportant", value: flag(task.isImportant))
            FieldRow(label: "紧急", field: "isUrgency", value: flag(task.isUrgency))
            FieldRow(label: "四象限", value: task.quadrant.title, valueColor: task.quadrant.titleColor)
        }
    }

    private func schedule(_ task: TaskDef) -> some View {
        InspectorSection("时间") {
            FieldRow(label: "无指定时间", field: "haveNoTime", value: flag(task.haveNoTime))
            FieldRow(label: "开始日期", field: "startTime", value: text(task.startTime))
            FieldRow(label: "结束日期", field: "endTime", value: text(task.endTime))
            FieldRow(label: "开始时刻", field: "validStartTime", value: text(task.validStartTime))
            FieldRow(label: "结束时刻", field: "validEndTime", value: text(task.validEndTime))
        }
    }

    private func recurrence(_ task: TaskDef) -> some View {
        let unit = task.unit
        return InspectorSection("重复") {
            FieldRow(label: "类型", field: "isLoop", value: "\(task.loopKind.title)（\(task.isLoop)）")
            FieldRow(label: "预设", field: "loopSet",
                     value: "\(task.repeatSet?.title ?? "未知")（\(task.loopSet)）")
            FieldRow(label: "间隔", field: "loopBaseNumber", value: "\(task.loopBaseNumber)")
            FieldRow(label: "单位 · 筛选", field: "loopUnit",
                     value: "\(unit.unit?.title ?? "未知") · \(unit.filter?.title ?? "未知")（\(task.loopUnit)）")
            FieldRow(label: "选中日期", field: "loopDate", value: text(task.loopDate))
            FieldRow(label: "每次持续", field: "duration", value: "\(task.duration) 天")
            if task.isRepeating {
                FieldRow(label: "规则摘要", value: RuleSummary.describe(task), valueColor: Theme.subtext)
            }
        }
    }

    private func goal(_ task: TaskDef) -> some View {
        let content = task.content
        let progress = item.progress
        let goalText: String
        switch task.goal {
        case .count(let n):
            goalText = "次数目标 \(n)（\(task.unitTimeNumber)）"
        case .checklist(let mask):
            goalText = "子任务 \(mask.nonzeroBitCount) 项，掩码 \(String(mask, radix: 2))（\(task.unitTimeNumber)）"
        }
        return InspectorSection("完成目标") {
            FieldRow(label: "模式", field: "unitTimeNumber", value: goalText)
            ForEach(Array(content.subtasks.enumerated()), id: \.offset) { index, title in
                let checked = progress.completedSubtaskIndices.contains(index)
                HStack(spacing: 8) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(checked ? Theme.done : Color(hex: 0xB9B09C))
                    Text(title)
                        .strikethrough(checked)
                        .foregroundStyle(checked ? Theme.subtext : Theme.text)
                    Spacer()
                    if !task.goal.includes(subtask: index) {
                        Text("不在目标内").font(.system(size: 10.5)).foregroundStyle(Theme.overdue)
                    }
                    FieldTag("bit \(index)")
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
                }
            }
        }
    }

    private func reminders(_ task: TaskDef) -> some View {
        InspectorSection("提醒") {
            FieldRow(label: "提醒位", field: "isRemind", value: "\(task.isRemind)")
            FieldRow(label: "时间提醒", field: "isRemind bit0", value: task.hasTimeReminder ? "开" : "关")
            FieldRow(label: "提醒日期", field: "remindDate", value: text(task.remindDate))
            FieldRow(label: "提醒时刻", field: "remindTime", value: text(task.remindTime))
            FieldRow(label: "地点提醒", field: "isRemind bit1", value: task.hasLocationReminder ? "开" : "关")
            FieldRow(label: "地点", field: "location", value: text(task.location))
            FieldRow(label: "坐标 GCJ-02", field: "latitude·longitude",
                     value: task.hasCoordinate
                        ? String(format: "%.6f, %.6f", task.latitude, task.longitude)
                        : "未设置（-1, -1）")
            if task.hasLocationReminder {
                Text("地点提醒只会在已授权的鸿蒙设备上触发")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
    }

    private func currentOccurrence(_ task: TaskDef) -> some View {
        let occurrence = item.occurrence
        let progress = item.progress
        let progressText = task.goal.isChecklist
            ? "\(progress.completedCount)/\(progress.targetCount) 项（\(occurrence.completedCount)）"
            : "\(progress.completedCount)/\(progress.targetCount) 次（\(occurrence.completedCount)）"
        return InspectorSection("本次执行 · showTask") {
            FieldRow(label: "实例 ID", field: "id2", value: occurrence.id2)
            FieldRow(label: "所属任务", field: "id1", value: occurrence.id1)
            FieldRow(label: "开始日期", field: "startTime", value: text(occurrence.startTime))
            FieldRow(label: "结束日期", field: "endTime", value: text(occurrence.endTime))
            FieldRow(label: "开始时刻", field: "validStartTime", value: text(occurrence.validStartTime))
            FieldRow(label: "结束时刻", field: "validEndTime", value: text(occurrence.validEndTime))
            FieldRow(label: "进度", field: "completedCount",
                     value: occurrence.completedCount < 0 ? "已放弃（-1）" : progressText)
            FieldRow(label: "最近记录", field: "recentFinishedTime", value: text(occurrence.recentFinishedTime))
            FieldRow(label: "实例完成", field: "isFinish", value: flag(occurrence.isFinish))
            MetaRows(meta: occurrence.meta)
        }
    }

    private func allOccurrences(_ task: TaskDef) -> some View {
        let all = model.snapshot.occurrences(ofTask: task.id1)
        let shown = Array(all.prefix(60))
        return InspectorSection("全部实例（\(all.count)）") {
            ForEach(shown) { occurrence in
                let selected = occurrence.id2 == item.occurrence.id2
                HStack(spacing: 8) {
                    Text(occurrence.startTime ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                    if occurrence.endTime != occurrence.startTime {
                        Text("→ " + (occurrence.endTime ?? "—"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                    }
                    Spacer()
                    StatusBadge(status: occurrence.status)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Theme.accent.opacity(0.15) : Color.clear)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(hex: 0xF0EADD)).frame(height: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectedOccurrenceID = occurrence.id2 }
            }
            if all.count > shown.count {
                Text("还有 \(all.count - shown.count) 个实例未列出")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .padding(8)
            }
        }
    }
}

// MARK: - 专注记录

struct FocusInspector: View {
    @Environment(AppModel.self) private var model
    let record: FocusRecord

    var body: some View {
        let log = record.parsedLog
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(log.eventTitle.isEmpty ? "专注记录" : log.eventTitle)
                    .font(.system(size: 18, weight: .bold))
                    .textSelection(.enabled)
                InspectorSection("专注 · tomato") {
                    FieldRow(label: "开始", field: "time", value: startedText)
                    FieldRow(label: "毫秒时间戳", field: "time", value: record.time)
                    FieldRow(label: "日期", field: "date", value: text(record.date))
                    FieldRow(label: "分钟", field: "minutes", value: minutesText)
                    FieldRow(label: "好番茄", field: "goodCount", value: "\(record.goodCount)")
                    FieldRow(label: "坏番茄", field: "badCount", value: "\(record.badCount)")
                }
                InspectorSection("关联事项 · log") {
                    FieldRow(label: "实例 ID", field: "log.eventId", value: log.eventID ?? "未关联（-1）")
                    FieldRow(label: "标题", field: "log.eventTitle", value: log.eventTitle.isEmpty ? "—" : log.eventTitle)
                    FieldRow(label: "待办单", field: "log.eventType", value: eventTypeText(log))
                    FieldRow(label: "结束时间", field: "log.endTime", value: log.endTime ?? "—")
                    if let linked = model.snapshot.occurrence(forFocus: record) {
                        Button {
                            model.selectedFocusID = nil
                            model.selectedOccurrenceID = linked.id
                        } label: {
                            Label("查看关联任务：\(linked.task.taskTitle)", systemImage: "arrow.up.right")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    } else if log.eventID != nil {
                        Text("关联的实例已不存在，专注记录仍按日期统计")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.subtext)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                InspectorSection("高级") {
                    MetaRows(meta: record.meta)
                }
                ExtraFieldsSection(kind: .tomato, raw: record.meta?.raw ?? [:])
                RawJSONSection(title: "原始 JSON · tomato", raw: record.meta?.raw ?? [:])
            }
            // 内容宽度跟随检查器这一栏，不允许被子视图撑宽。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var startedText: String {
        record.startedAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "—"
    }

    private var minutesText: String {
        let value = record.minutes
        return value.rounded() == value ? "\(Int(value)) 分钟" : String(format: "%.1f 分钟", value)
    }

    private func eventTypeText(_ log: FocusLog) -> String {
        guard let type = log.eventType else { return "—" }
        if type == -1 { return "无（-1）" }
        return "\(model.snapshot.list(String(type))?.displayName ?? "未知待办单")（\(type)）"
    }
}
