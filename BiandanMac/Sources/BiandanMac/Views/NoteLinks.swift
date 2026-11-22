import AppKit
import SwiftUI

// MARK: - 备注里的网址和邮箱：识别、变成可点的链接；备注编辑框按内容变高

struct NoteLink: Equatable {
    /// 原文里的那一段（邮箱不带 mailto:）。
    var text: String
    var url: URL

    var isEmail: Bool { url.scheme?.lowercased() == "mailto" }
}

enum NoteLinks {
    /// 链接文字的颜色：主题强调色是黄色，在米色底上看不清，链接单独用蓝色。
    static let color = Color(hex: 0x2B6CD4)

    static func detect(_ text: String) -> [NoteLink] { matches(text).map(\.link) }

    /// 只认 http(s) 网址（原文要带「://」或以「www.」开头，免得把「Biandan.app」这种文件名当成链接）和邮箱。
    /// 网址后面紧跟的中文和标点不算进链接（「https://a.com/j/1请准时」）。
    static func matches(_ text: String) -> [(range: Range<String.Index>, link: NoteLink)] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var result: [(range: Range<String.Index>, link: NoteLink)] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let found = match.url, var range = Range(match.range, in: text) else { continue }
            let scheme = found.scheme?.lowercased() ?? ""
            if scheme == "mailto" {
                let raw = String(text[range])
                let address = raw.lowercased().hasPrefix("mailto:") ? String(raw.dropFirst(7)) : raw
                guard address.contains("@"), let url = URL(string: "mailto:" + address) else { continue }
                result.append((range, NoteLink(text: address, url: url)))
                continue
            }
            guard scheme == "http" || scheme == "https" else { continue }
            if let cut = text[range].firstIndex(where: { !$0.isASCII }) { range = range.lowerBound..<cut }
            var raw = String(text[range])
            while let last = raw.last, ".,;:!?)]}'\"".contains(last) {
                raw.removeLast()
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            let lower = raw.lowercased()
            guard lower.contains("://") || lower.hasPrefix("www.") else { continue }
            guard let url = URL(string: lower.hasPrefix("www.") ? "https://" + raw : raw), url.host != nil else { continue }
            result.append((range, NoteLink(text: raw, url: url)))
        }
        return result
    }

    /// 带链接的文字：网址和邮箱可以点（网址用浏览器打开，邮箱新建邮件）。
    static func attributed(_ text: String, linkColor: Color = NoteLinks.color) -> AttributedString {
        var result = AttributedString(text)
        for match in matches(text) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[lower..<upper].link = match.link.url
            result[lower..<upper].foregroundColor = linkColor
        }
        return result
    }

    /// 把网址和邮箱从一句话里拿出来：返回剩下的文字（去掉首尾空格和冒号、逗号）和拿出来的链接。
    static func strip(_ text: String) -> (rest: String, links: [String]) {
        let found = matches(text)
        guard !found.isEmpty else { return (text, []) }
        var rest = ""
        var cursor = text.startIndex
        for match in found where match.range.lowerBound >= cursor {
            rest += text[cursor..<match.range.lowerBound]
            cursor = match.range.upperBound
        }
        rest += text[cursor...]
        while rest.contains("  ") { rest = rest.replacingOccurrences(of: "  ", with: " ") }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：,，;；|-—"))
        return (rest.trimmingCharacters(in: trim), found.map(\.link.text))
    }
}

/// 备注里的网址、邮箱列在编辑框下面，点了直接打开。
struct NoteLinkChips: View {
    let text: String

    var body: some View {
        let links = NoteLinks.detect(text)
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Link(destination: link.url) {
                        HStack(spacing: 5) {
                            Image(systemName: link.isEmail ? "envelope" : "link")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(verbatim: link.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(NoteLinks.color)
                    }
                    .buttonStyle(.plain)
                    .help(link.isEmail ? "写邮件给 " + link.text : "在浏览器中打开")
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct NoteHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 按内容自动变高的备注编辑框：最矮两行，最高 maxHeight，再长就在框里滚动。长网址会折行显示，不会被截掉。
struct GrowingNoteEditor: View {
    @Binding var text: String
    var placeholder = "备注"
    var minHeight: CGFloat = 44
    var maxHeight: CGFloat = 240
    @State private var measured: CGFloat = 0

    private let font = Font.system(size: 13)
    private var height: CGFloat { min(max(measured + 10, minHeight), maxHeight) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        TextEditor(text: $text)
            .font(font)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .frame(height: height)
            .background(alignment: .topLeading) {
                // 同字体、同宽度的隐藏文字，用来量内容有多高。
                Text(verbatim: text.isEmpty ? " " : text)
                    .font(font)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: NoteHeightKey.self, value: proxy.size.height)
                    })
            }
            .onPreferenceChange(NoteHeightKey.self) { value in measured = value }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(Theme.fieldName)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .background(shape.fill(Color.white))
            .overlay(shape.stroke(Theme.line))
    }
}
