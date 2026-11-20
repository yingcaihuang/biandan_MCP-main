import SwiftUI

enum FocusRange: String, CaseIterable, Identifiable {
    case week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "全部"
        }
    }
}

/// 专注记录（tomato）：列表、补记、编辑、删除、按日汇总。不提供计时器。
struct FocusListView: View {
    @Environment(AppModel.self) private var model
    @State private var range: FocusRange = .week
    @State private var byDay = false

    private func bounds() -> (LocalDate?, LocalDate?) {
        let today = model.today
        switch range {
        case .week:
            let start = today.adding(days: -floorMod(today.weekday - model.weekStart, 7))
            return (start, start.adding(days: 6))
        case .month:
            return (today.firstOfMonth, today.lastOfMonth)
        case .all:
            return (nil, nil)
        }
    }

    private func filtered() -> [FocusRecord] {
        let window = bounds()
        let needle = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return model.snapshot.focus(from: window.0, to: window.1).filter { record in
            needle.isEmpty || record.parsedLog.eventTitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        let records = filtered()
        let minutes = records.reduce(0) { $0 + $1.minutes }
        let good = records.reduce(0) { $0 + $1.goodCount }
        let bad = records.reduce(0) { $0 + $1.badCount }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("范围", selection: $range) {
                    ForEach(FocusRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Picker("显示", selection: $byDay) {
                    Text("明细").tag(false)
                    Text("按日").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                Text(verbatim: "\(records.count) 条 · 合计 \(Int(minutes)) 分钟 · 🍅 \(good) / \(bad)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4A453C))
                Spacer()
                Button("＋ 补记") { model.focusEditor = FocusEditorRequest() }
                    .buttonStyle(.themed)
                    .disabled(model.authState != .signedIn)
                    .help("补记一段已经完成的专注")
            }

            if records.isEmpty {
                ContentUnavailableView("没有专注记录", systemImage: "timer",
                                       description: Text("在鸿蒙便单里完成的专注会同步到这里，也可以点「补记」手动添加"))
            } else if byDay {
                FocusDayTable(rows: FocusDayRow.group(records))
            } else {
                FocusDetailTable(records: records)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }
}

private struct FocusDetailTable: View {
    @Environment(AppModel.self) private var model
    let records: [FocusRecord]

    var body: some View {
        @Bindable var model = model
        Table(records, selection: $model.selectedFocusID) {
            TableColumn("开始") { (record: FocusRecord) in
                Text(record.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? record.time)
            }
            .width(min: 120, ideal: 150)
            TableColumn("日期") { (record: FocusRecord) in
                Text(record.date)
            }
            .width(min: 80, ideal: 90)
            TableColumn("分钟") { (record: FocusRecord) in
                Text(FocusText.minutes(record.minutes))
            }
            .width(min: 44, ideal: 56)
            TableColumn("好 / 坏") { (record: FocusRecord) in
                Text(verbatim: "\(record.goodCount) / \(record.badCount)")
            }
            .width(min: 50, ideal: 64)
            TableColumn("关联事项") { (record: FocusRecord) in
                FocusTitleCell(record: record)
            }
        }
        // 双击编辑；不弹系统右键菜单，保持主题一致。
        .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { ids in
            guard let id = ids.first, let record = records.first(where: { $0.time == id }) else { return }
            model.focusEditor = FocusEditorRequest(record: record)
        })
        .onDeleteCommand {
            if let record = model.selectedFocus { model.focusDeleteRequest = record }
        }
        .help("双击编辑，按 Delete 删除")
        .onChange(of: model.selectedFocusID) { _, newValue in
            if newValue != nil { model.selectedOccurrenceID = nil }
        }
    }
}

private struct FocusDayTable: View {
    let rows: [FocusDayRow]

    var body: some View {
        Table(rows) {
            TableColumn("日期") { (row: FocusDayRow) in Text(row.date) }
                .width(min: 90, ideal: 110)
            TableColumn("条数") { (row: FocusDayRow) in Text(verbatim: "\(row.count)") }
                .width(min: 44, ideal: 56)
            TableColumn("分钟") { (row: FocusDayRow) in Text(FocusText.minutes(row.minutes)) }
                .width(min: 50, ideal: 64)
            TableColumn("好 / 坏") { (row: FocusDayRow) in Text(verbatim: "\(row.good) / \(row.bad)") }
        }
    }
}

struct FocusTitleCell: View {
    @Environment(AppModel.self) private var model
    let record: FocusRecord

    var body: some View {
        let log = record.parsedLog
        if let linked = model.snapshot.occurrence(forFocus: record) {
            Label(log.eventTitle.isEmpty ? linked.task.taskTitle : log.eventTitle, systemImage: "link")
        } else if !log.eventTitle.isEmpty {
            Text(log.eventID == nil ? "（自填）\(log.eventTitle)" : log.eventTitle)
                .foregroundStyle(Theme.subtext)
        } else {
            Text("—").foregroundStyle(Theme.fieldName)
        }
    }
}
