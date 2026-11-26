import Foundation
import os
import WidgetKit

// MARK: - 主程序写给小组件的数据
//
// 本机数据、登录状态变化后 1 秒，把今天起 3 天的待办写成 App Group 里的 widget.json，再让小组件刷新。
// 内容没变不写、不刷新。启动时还在读凭据（checking）不写，免得小组件闪一下「没登录」。
// 跨天日程每天各列一条；有具体时刻的只在开始那天带时刻，其余天按全天。逾期的单独计数，不列。

enum WidgetPayload {
    static let days = 3
    /// 最多写这么多条，小组件最大尺寸也用不完。
    static let maxItems = 60

    static func build(snapshot: DataSnapshot, today: LocalDate, signedIn: Bool, now: Date,
                      calendar: Calendar = .current) -> WidgetSnapshot {
        guard signedIn else { return WidgetSnapshot(generatedAt: now, signedIn: false, overdue: 0, items: []) }
        var names: [String: String] = [:]
        for list in snapshot.lists where names[list.id3] == nil { names[list.id3] = list.displayName }
        let last = today.adding(days: days - 1)
        let pending = snapshot.items(OccurrenceQuery())
            .filter { $0.occurrence.overlaps(today, last) && !$0.isOverdue(today: today) }
        var items: [WidgetSnapshot.Item] = []
        for item in pending {
            let title = item.task.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            for offset in 0..<days {
                let day = today.adding(days: offset)
                guard item.occurrence.overlaps(day, day) else { continue }
                var start: Date?
                var end: Date?
                if item.occurrence.startDate == day, let slot = MenuBarAgenda.slot(item, calendar: calendar) {
                    start = slot.start
                    end = slot.end
                }
                items.append(WidgetSnapshot.Item(id: item.id, title: title.isEmpty ? "（无标题）" : title, day: day.iso,
                                                 start: start, end: end, quadrant: item.task.quadrant.rawValue,
                                                 list: names[item.task.id3] ?? "未分类"))
            }
        }
        items.sort { $0.day == $1.day ? WidgetSnapshot.order($0, $1) : $0.day < $1.day }
        return WidgetSnapshot(generatedAt: now, signedIn: true, overdue: snapshot.counts(today: today).overdue,
                              items: Array(items.prefix(maxItems)))
    }
}

@MainActor
final class WidgetPublisher {
    static let logger = Logger(subsystem: "ai.racore.BiandanMac", category: "widget")

    private weak var model: AppModel?
    private var pending: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    /// 上次写入的内容（去掉生成时间），一样就不再写。
    private var lastContent: Data?

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        noteChange()
        // 过了零点「今天」变了、逾期数也会变：每 15 分钟检查一次，内容没变不会写。
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard let self, !Task.isCancelled else { return }
                self.publish()
            }
        }
    }

    func noteChange() {
        guard model != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    func publish() {
        guard let model, model.authState != .checking, let url = WidgetShared.fileURL() else { return }
        let snapshot = WidgetPayload.build(snapshot: model.snapshot, today: LocalDate.today(),
                                           signedIn: model.authState == .signedIn, now: Date())
        var probe = snapshot
        probe.generatedAt = .distantPast
        do {
            let content = try WidgetShared.encode(probe)
            guard content != lastContent else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WidgetShared.encode(snapshot).write(to: url, options: .atomic)
            lastContent = content
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind)
            Self.logger.info("小组件数据已更新：\(snapshot.items.count) 条，逾期 \(snapshot.overdue)")
        } catch {
            Self.logger.error("写小组件数据失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
