import SwiftUI

/// 轻量 Markdown 渲染。只处理模型回答里真正常见的那几种：
/// 标题、无序/有序列表、引用、围栏代码块，以及行内的粗体、斜体、行内代码、链接。
/// 不引入第三方依赖，流式过程中也能安全地反复解析。
struct MarkdownText: View {
    let raw: String
    var font: Font = DS.body

    private static let parseLimit = 40_000

    var body: some View {
        if raw.count > Self.parseLimit {
            Text(raw).font(font).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(MarkdownBlock.parse(raw).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level <= 1 ? 15 : (level == 2 ? 14 : 13), weight: .semibold))
                .padding(.top, 2)

        case .paragraph(let text):
            inline(text).font(font)

        case .quote(let text):
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 2)
                inline(text).font(font).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(font)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 12, alignment: .trailing)
                        inline(item.text).font(font)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 3) {
                if let language, !language.isEmpty {
                    Text(language).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous).fill(DS.faint))
            .overlay(RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 0.5))

        case .rule:
            Rectangle().fill(DS.hairline).frame(height: 0.5).padding(.vertical, 2)
        }
    }

    private func inline(_ text: String) -> Text {
        Text(MarkdownBlock.attributed(text))
    }
}

// MARK: - 解析

enum MarkdownBlock {
    struct ListItem {
        var marker: String
        var text: String
        var depth: Int
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case list([ListItem])
    case code(language: String?, text: String)
    case rule

    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items.removeAll()
        }
        func flushAll() { flushParagraph(); flushQuote(); flushList() }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushAll()
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if let headingLevel = headingLevel(of: trimmed) {
                flushAll()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: headingLevel, text: text))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = listItem(from: line) {
                flushParagraph(); flushQuote()
                items.append(item)
                continue
            }

            flushQuote(); flushList()
            paragraph.append(trimmed)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func headingLevel(of line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6, line.count > count else { return nil }
        let next = line[line.index(line.startIndex, offsetBy: count)]
        return next == " " ? count : nil
    }

    private static func listItem(from line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let depth = min(indent / 2, 3)

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return ListItem(marker: "•",
                            text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                            depth: depth)
        }
        // 有序列表：1. 或 1)
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ListItem(marker: "\(digits).",
                                text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                                depth: depth)
            }
        }
        return nil
    }

    /// 行内格式。解析失败就原样返回，流式过程中半截的语法不会炸。
    static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}
