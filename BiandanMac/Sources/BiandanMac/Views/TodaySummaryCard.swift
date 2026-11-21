import SwiftUI

/// 任务视图顶部的问候卡片：完成率圆环 + 问候 + 维度切换，下方是时间条（今天 0–24 点 / 近 7 天 / 本月）。
struct TodaySummaryCard: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        let progress = model.progressSummary(for: item)
        let label = model.progressLabel(for: item)
        let hour = Calendar.current.component(.hour, from: Date())
        let name = model.profile.displayName
        let greeting: String = name.isEmpty ? Greeting.text(hour: hour) : Greeting.text(hour: hour) + "，" + name
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                SummaryProgressRing(progress: progress, label: label)
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(Greeting.subtitle(progress, label: label))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.subtext)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if item != .undated {
                    ThemedSegmented(selection: Binding(get: { model.summaryRange },
                                                       set: { model.summaryRange = $0 }),
                                    options: ProgressRange.allCases.map { ThemeOption(value: $0, title: $0.title) })
                        .help("完成率与时间条的统计时间范围")
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { model.showSummaryTimeline.toggle() }
                    } label: {
                        Image(systemName: model.showSummaryTimeline ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.subtext)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.showSummaryTimeline ? "收起时间条" : "展开时间条")
                }
            }
            if item != .undated && model.showSummaryTimeline {
                // 每分钟刷新一次「现在」竖线。
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    SummaryTimelineStrip(items: model.timelineItems(for: item), range: model.summaryRange,
                                         today: model.today, now: context.date,
                                         tint: { model.timelineTint(for: $0) },
                                         selectedID: model.selectedOccurrenceID,
                                         onSelect: { occurrence in
                                             model.selectedOccurrenceID = occurrence.id
                                             model.selectedFocusID = nil
                                         },
                                         onShowConflicts: { model.sidebarSelection = .conflicts })
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }
}

