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

/// 专注记录列表（tomato）。只管理记录，不提供计时器。P3 只读。
struct FocusListView: View {
    @Environment(AppModel.self) private var model
    @State private var range: FocusRange = .week

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

    var body: some View {
        @Bindable var model = model
        let window = bounds()
        let start = window.0
        let end = window.1
        let needle = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let records = model.snapshot.focus(from: start, to: end).filter { record in
            needle.isEmpty || record.parsedLog.eventTitle.lowercased().contains(needle)
        }
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
                Text(verbatim: "\(records.count) 条 · 合计 \(Int(minutes)) 分钟 · 🍅 \(good) / \(bad)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x4A453C))
                Spacer()
                Button("＋ 补记") {}
                    .disabled(true)
                    .help("补记将在 P6 开放")
            }

            if records.isEmpty {
                ContentUnavailableView("没有专注记录", systemImage: "timer",
                                       description: Text("在鸿蒙便单里完成的专注会同步到这里"))
            } else {
                Table(records, selection: $model.selectedFocusID) {
                    TableColumn("开始") { record in
                        Text(record.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? record.time)
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("日期") { record in
                        Text(record.date)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("分钟") { record in
                        Text(record.minutes.rounded() == record.minutes
                             ? "\(Int(record.minutes))" : String(format: "%.1f", record.minutes))
                    }
                    .width(min: 44, ideal: 56)
                    TableColumn("好 / 坏") { record in
                        Text(verbatim: "\(record.goodCount) / \(record.badCount)")
                    }
                    .width(min: 50, ideal: 64)
                    TableColumn("关联事项") { record in
                        FocusTitleCell(record: record)
                    }
                }
                .onChange(of: model.selectedFocusID) { _, newValue in
                    if newValue != nil { model.selectedOccurrenceID = nil }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
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
