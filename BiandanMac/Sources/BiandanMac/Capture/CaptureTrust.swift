import SwiftUI

// MARK: - 识别日程的可信度：哪些字段不太确定（确认卡片里单独标黄）、文字有没有离开这台 Mac、候选拖到日历上定日期

enum CandidateField: Hashable, Sendable {
    case title, date, time, location
}

extension ScheduleCandidate {
    /// 确认卡片里的候选拖到主窗口日历时带的文字。
    static let dragPrefix = "biandan-candidate:"

    var dragID: String { Self.dragPrefix + id.uuidString }

    static func candidateID(fromDrag text: String) -> UUID? {
        guard text.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(dragPrefix.count)))
    }

    /// 不太确定的字段和原因。改过之后原因消失，标黄也就跟着去掉。
    func doubts(today: LocalDate) -> [CandidateField: String] {
        var result: [CandidateField: String] = [:]
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "日程" {
            result[.title] = "没识别出要做什么，补一个标题"
        } else if name.count > RuleScheduleExtractor.longTitle {
            result[.title] = "标题很长，可能把整段话当成了标题"
        }
        if date == nil {
            result[.date] = "没识别出日期"
        } else if let vague = vagueDate {
            result[.date] = "原文只说了「" + vague + "」，日期是估的"
        } else if let date, date < today, !(note ?? "").hasPrefix("截止日") {
            result[.date] = "日期已经过去"
        }
        if start == nil, let vague = vagueTime {
            result[.time] = "原文只说了「" + vague + "」，没写具体时刻"
        }
        if lookup == .notFound {
            result[.location] = "地图上没找到这个地点"
        }
        return result
    }
}

// MARK: - 文字去了哪里

struct CapturePrivacyNote: Equatable {
    let text: String
    /// 文字离开过这台 Mac（发给了决策模型或大模型）。截图始终不上传。
    let uploaded: Bool
}

enum CapturePrivacy {
    static func note(source: ScheduleExtractionSource?, decision: DecisionRecord?, aiModel: String) -> CapturePrivacyNote? {
        guard let source else { return nil }
        if source == .ai {
            return CapturePrivacyNote(text: ["识别出的文字已发给 ", aiModel, " 提取（不含截图）"].joined(), uploaded: true)
        }
        if let decision {
            let decider = decision.decisionModel ?? DecisionSettings.model
            let text = ["文字发给 ", decider, " 判断过有没有日程（不含截图），提取在本机完成"].joined()
            return CapturePrivacyNote(text: text, uploaded: true)
        }
        return CapturePrivacyNote(text: "本机识别，未上传：截图和文字都只在这台 Mac 上", uploaded: false)
    }
}

struct CapturePrivacyLabel: View {
    let note: CapturePrivacyNote

    var body: some View {
        let icon: String = note.uploaded ? "arrow.up.doc.fill" : "lock.shield.fill"
        let tint: Color = note.uploaded ? DecisionPalette.model : Theme.done
        Label(note.text, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 标黄

private struct CandidateDoubtMark: ViewModifier {
    let reason: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let reason {
            content
                .background(Color(hex: 0xFFF1B8).opacity(0.6))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(hex: 0xE0A800)).frame(width: 3)
                }
                .help("不太确定：" + reason)
        } else {
            content
        }
    }
}

extension View {
    /// 有原因时整行浅黄底、左侧黄条，鼠标移上去显示原因。
    func candidateDoubt(_ reason: String?) -> some View {
        modifier(CandidateDoubtMark(reason: reason))
    }
}

struct CandidateDragPreview: View {
    let title: String

    var body: some View {
        Label(title.isEmpty ? "日程" : title, systemImage: "calendar")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.accent))
    }
}
