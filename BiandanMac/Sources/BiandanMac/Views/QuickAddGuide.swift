import SwiftUI

/// 快速添加栏的 ＋ 号：鼠标移上去弹出写法说明，点示例填进输入框。
struct QuickAddGuideAnchor: View {
    @Environment(AppModel.self) private var model
    let onPick: (String) -> Void

    /// 示例里用用户自己的第一个分类名，没有就用「工作」。
    private var listName: String {
        model.snapshot.lists.first { $0.id3 != TodoList.defaultID }?.displayName ?? "工作"
    }

    var body: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 15))
            .foregroundStyle(Theme.accent)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .hoverPopover(arrowEdge: .bottom) { _ in
                QuickAddGuide(listName: listName, onPick: onPick)
            }
    }
}

private struct GuideSection: Identifiable {
    let title: String
    let icon: String
    let examples: [String]
    let note: String
    var id: String { title }
}

/// 写法说明：日期、时刻、重复、分类与标记、组合示例。同主题白卡片、分类色板以外只用强调色。
struct QuickAddGuide: View {
    let listName: String
    let onPick: (String) -> Void

    private var sections: [GuideSection] {
        [
            GuideSection(title: "日期", icon: "calendar",
                         examples: ["今天", "明天", "后天", "周五", "下周三", "11月30日", "25号", "无日期"],
                         note: "写在标题前后都行，如「后天跟腾讯开会」；「明天的会议」「周一例会」不会被拆开"),
            GuideSection(title: "时刻", icon: "clock",
                         examples: ["下午3点", "3点半", "十点一刻", "15:30-16:30", "今晚8点"],
                         note: "写了时刻会设成从该时刻起 30 分钟的时段并准时提醒；没写上下午的 1–5 点按下午算"),
            GuideSection(title: "重复", icon: "repeat",
                         examples: ["每天", "工作日", "每周一三五", "每周末", "每两周", "每月15号", "每月最后一天", "每年3月5日"],
                         note: "可以跟时刻，如「每周一8点」"),
            GuideSection(title: "分类与标记", icon: "tag",
                         examples: ["@" + listName, "#" + listName, "#重要", "#紧急", "#习惯"],
                         note: "@分类 和 #分类 按名称匹配（可以只写开头）；对不上的 #词 会留在标题里"),
        ]
    }

    private var combos: [String] {
        ["后天下午1点跟腾讯开会 #重要", "明天下午2点到4点评审 @" + listName, "每周一8点 周会", "交材料 11月30日 #紧急"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("快速添加写法")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("在输入框里直接写，回车保存；识别出来的部分会从标题里去掉")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
            }
            ForEach(sections) { section in
                GuideSectionView(section: section, onPick: onPick)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            GuideSectionView(section: GuideSection(title: "组合示例", icon: "sparkles", examples: combos,
                                                   note: "几种写法可以连着写，用空格隔开"),
                             onPick: onPick)
            Text("点示例可以填进输入框 · 回车前右侧会预览识别结果，时间冲突会标红")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.fieldName)
        }
        .padding(14)
        .frame(width: 430, alignment: .leading)
    }
}

private struct GuideSectionView: View {
    let section: GuideSection
    let onPick: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: section.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: section.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
                GuideFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(section.examples, id: \.self) { example in
                        GuideChip(text: example, onPick: onPick)
                    }
                }
                Text(verbatim: section.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GuideChip: View {
    let text: String
    let onPick: (String) -> Void
    @State private var hovering = false

    var body: some View {
        let fill: Color = hovering ? Theme.accent.opacity(0.14) : Theme.panel
        let stroke: Color = hovering ? Theme.accent : Theme.line
        Button {
            onPick(text)
        } label: {
            Text(verbatim: text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 自动换行的横排：放不下就换到下一行。
struct GuideFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
