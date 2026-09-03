import AppKit
import SwiftUI

/// 轻量 Markdown 渲染。处理标题、无序/有序列表、引用、围栏代码块、表格，
/// 以及行内的粗体、斜体、行内代码、链接。
/// 不引入第三方依赖，流式过程中也能安全地反复解析。
struct MarkdownText: View {
    let raw: String
    var font: Font = DS.body
    var flat: Bool = false
    /// 流式输出时在正文末尾接一个光标。接在文字里而不是并排放一个视图，
    /// 否则在 850pt 宽的面板里它会被推到整行最右边，离真正的行尾十万八千里。
    var showsCaret: Bool = false

    private static let parseLimit = 40_000

    var body: some View {
        if raw.count > Self.parseLimit {
            Text(raw).font(font).textSelection(.enabled)
        } else {
            let blocks = MarkdownBlock.parse(raw)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    view(for: block, caret: showsCaret && index == blocks.count - 1)
                }
                // 代码块和表格是独立卡片，光标塞不进去，只能另起一行。
                if showsCaret, let last = blocks.last, !last.acceptsInlineCaret {
                    BlinkingCaret()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, caret: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, caret: caret)
                .font(.system(size: level <= 1 ? 16 : (level == 2 ? 14.5 : 13.5),
                              weight: level <= 1 ? .bold : .semibold))
                .padding(.top, level <= 1 ? 4 : 2)

        case .paragraph(let text):
            inline(text, caret: caret)
                .font(font)
                .lineSpacing(3.5)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 2.5)
                inline(text, caret: caret)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3.5)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(font)
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                            .monospacedDigit()
                            .frame(minWidth: 12, alignment: .trailing)
                        inline(item.text, caret: caret && index == items.count - 1)
                            .font(font)
                            .lineSpacing(3.5)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }

        case .code(let language, let text):
            CodeBlockView(language: language, text: text, flat: flat)

        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)

        case .rule:
            Rectangle().fill(DS.hairline).frame(height: 0.5).padding(.vertical, 3)
        }
    }

    private func inline(_ text: String, caret: Bool = false) -> Text {
        let base = Text(MarkdownBlock.attributed(text))
        guard caret else { return base }
        return base + Text(verbatim: "\u{2007}▍").foregroundColor(.accentColor)
    }
}

// MARK: - 代码块精致卡片

private struct CodeBlockView: View {
    let language: String?
    let text: String
    var flat: Bool = false
    @State private var copied = false

    private var cleanLanguage: String {
        let lang = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lang.isEmpty ? "code" : lang
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 代码卡片顶部控制栏
            HStack {
                Text(cleanLanguage)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(copied ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(copied ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .help("复制代码块")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.03))

            Divider().opacity(0.3)

            if flat {
                Text(text)
                    .font(DS.code)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .padding(9)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(DS.code)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .padding(9)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .fill(DS.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - 表格组件

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        // 每行各画一个 HStack 的话，列宽由各自内容决定，行与行对不上，
        // 看起来就是一堆错位的文字。Grid 会统一算列宽，这是表格的最低要求。
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    cell(header, weight: .semibold, vertical: 5)
                        .background(Color.primary.opacity(0.05))
                }
            }
            Divider().opacity(0.4)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(headers.indices), id: \.self) { column in
                        cell(column < row.count ? row[column] : "", weight: .regular, vertical: 4.5)
                            .background(rowIndex.isMultiple(of: 2) ? Color.clear
                                                                   : Color.primary.opacity(0.025))
                    }
                }
                if rowIndex < rows.count - 1 {
                    Divider().opacity(0.15)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardCorner, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 0.5)
        )
        .padding(.vertical, 3)
    }

    /// 撑满整格再上底色，否则交替行的底色会缺一块。
    private func cell(_ text: String, weight: Font.Weight, vertical: CGFloat) -> some View {
        Text(MarkdownBlock.attributed(text))
            .font(.system(size: 11.5, weight: weight))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    case table(headers: [String], rows: [[String]])
    case rule

    /// 光标能不能直接跟在这个块的文字后面。代码块和表格是带边框的卡片，不行。
    var acceptsInlineCaret: Bool {
        switch self {
        case .heading, .paragraph, .quote, .list: return true
        case .code, .table, .rule: return false
        }
    }

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

        let lines = raw.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
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
                i += 1
                continue
            }
            if inCode {
                codeLines.append(line)
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                i += 1
                continue
            }

            // 表格检测：当前行含 | 且下一行为 |---| 分隔线
            if trimmed.contains("|") && i + 1 < lines.count {
                let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if isTableSeparator(nextTrimmed) {
                    flushAll()
                    let headers = parseTableRow(trimmed)
                    var tableRows: [[String]] = []
                    i += 2 // 跳过表头和分隔线
                    while i < lines.count {
                        let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                        if rowLine.isEmpty || !rowLine.contains("|") { break }
                        tableRows.append(parseTableRow(rowLine))
                        i += 1
                    }
                    blocks.append(.table(headers: headers, rows: tableRows))
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let headingLevel = headingLevel(of: trimmed) {
                flushAll()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: headingLevel, text: text))
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            if let item = listItem(from: line) {
                flushParagraph(); flushQuote()
                items.append(item)
                i += 1
                continue
            }

            flushQuote(); flushList()
            paragraph.append(trimmed)
            i += 1
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(language: codeLanguage, text: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = parseTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return marker.count >= 3 && marker.allSatisfy { $0 == "-" }
        }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|")
        if parts.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            parts.removeFirst()
        }
        if parts.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            parts.removeLast()
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
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
