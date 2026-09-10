import CryptoKit
import SwiftUI
import WebKit

/// Splits generated notes markdown into renderable blocks: text, mermaid
/// diagrams, and imported local images.
enum NoteBlockParser {
    enum Block {
        case text(String)
        case heading(level: Int, content: String)
        case bullet(depth: Int, content: String)
        case numbered(depth: Int, label: String, content: String)
        case quote(String)
        case divider
        case diagram(code: String)
        case code(language: String?, code: String)
        case table(header: [String], rows: [[String]])
        case image(URL)
    }

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s*(.+)$"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^>\s?(.*)$"#)
    private static let dividerPattern = try! NSRegularExpression(pattern: #"^(-{3,}|\*{3,}|_{3,})$"#)

    static func parse(markdown: String) -> [Block] {
        var blocks: [Block] = []
        var cursor = markdown.startIndex

        // Extract every fenced block so chat and notes share one renderer.
        // Mermaid fences become live diagrams; any other fence becomes a
        // monospaced code block. An unclosed fence (common mid-stream) is
        // left as text so streaming never hides the partial answer.
        let fencePattern = try! NSRegularExpression(pattern: #"```(\w*)\s*\n(.*?)```"#,
                                                      options: [.dotMatchesLineSeparators])
        let fullRange = NSRange(markdown.startIndex..., in: markdown)

        for match in fencePattern.matches(in: markdown, range: fullRange) {
            guard let fenceRange = Range(match.range, in: markdown),
                  let codeRange = Range(match.range(at: 2), in: markdown) else { continue }

            if cursor < fenceRange.lowerBound {
                blocks.append(contentsOf: textAndImageBlocks(String(markdown[cursor..<fenceRange.lowerBound])))
            }
            let language = Range(match.range(at: 1), in: markdown).map { String(markdown[$0]).lowercased() } ?? ""
            let code = String(markdown[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if language == "mermaid" {
                blocks.append(.diagram(code: code))
            } else {
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code))
            }
            cursor = fenceRange.upperBound
        }

        if cursor < markdown.endIndex {
            blocks.append(contentsOf: textAndImageBlocks(String(markdown[cursor...])))
        }
        return blocks
    }

    /// Splits a text run into prose and local-image references.
    private static func textAndImageBlocks(_ input: String) -> [Block] {
        var result: [Block] = []
        var cursor = input.startIndex

        let imagePattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(((?:file://)?/[^\s)]+)\)"#)
        let fullRange = NSRange(input.startIndex..., in: input)

        for match in imagePattern.matches(in: input, range: fullRange) {
            guard let matchRange = Range(match.range, in: input),
                  let pathRange = Range(match.range(at: 1), in: input) else { continue }

            if cursor < matchRange.lowerBound {
                appendText(String(input[cursor..<matchRange.lowerBound]), into: &result)
            }
            result.append(.image(URL(fileURLWithPath: String(input[pathRange]))))
            cursor = matchRange.upperBound
        }

        if cursor < input.endIndex {
            appendText(String(input[cursor...]), into: &result)
        }
        return result
    }

    private static func appendText(_ text: String, into blocks: inout [Block]) {
        blocks.append(contentsOf: structuredBlocks(text))
    }

    /// Breaks a prose run into block-level markdown: headings, list items,
    /// quotes, rules, tables, and paragraphs. Inline formatting stays in the content.
    private static func structuredBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var lists = NotesListScanner()

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            paragraph = []
        }

        func firstMatch(_ pattern: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }

        let lines = NotesDafCitation.normalize(text).components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // GFM table: header row, delimiter row, then data rows.
            if isTableRow(line),
               index + 1 < lines.count,
               isTableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                lists.reset()
                let header = splitTableRow(line)
                var rows: [[String]] = []
                var cursor = index + 2
                while cursor < lines.count,
                      isTableRow(lines[cursor].trimmingCharacters(in: .whitespaces)) {
                    rows.append(splitTableRow(lines[cursor].trimmingCharacters(in: .whitespaces)))
                    cursor += 1
                }
                blocks.append(.table(header: header, rows: rows))
                index = cursor
                continue
            }

            if line.isEmpty {
                flushParagraph()
            } else if firstMatch(dividerPattern, line) != nil {
                flushParagraph()
                lists.reset()
                blocks.append(.divider)
            } else if let match = firstMatch(headingPattern, line),
                      let hashes = Range(match.range(at: 1), in: line),
                      let content = Range(match.range(at: 2), in: line) {
                flushParagraph()
                lists.reset()
                blocks.append(.heading(level: line[hashes].count, content: String(line[content]).trimmingCharacters(in: .whitespaces)))
            } else if let item = lists.scan(rawLine) {
                flushParagraph()
                switch item.marker {
                case .bullet:
                    blocks.append(.bullet(depth: item.depth, content: item.content))
                case .ordered:
                    blocks.append(.numbered(depth: item.depth, label: item.orderedLabel, content: item.content))
                }
            } else if let match = firstMatch(quotePattern, line),
                      let content = Range(match.range(at: 1), in: line) {
                flushParagraph()
                blocks.append(.quote(String(line[content])))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isTableRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        // Avoid treating a single pipe inside prose as a table.
        let cells = splitTableRow(line)
        return cells.count >= 2
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let cells = trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return false }
        let cellPattern = try! NSRegularExpression(pattern: #"^:?-{1,}:?$"#)
        return cells.allSatisfy { cell in
            cellPattern.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) != nil
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Renders parsed note blocks; diagrams go through the offline renderer.
struct NotesContentView: View {
    let markdown: String
    var isCompact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            ForEach(Array(NoteBlockParser.parse(markdown: markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: NoteBlockParser.Block) -> some View {
        switch block {
        case .text(let content):
            inlineMarkdown(content)
                .font(.system(size: isCompact ? 12 : 13))
                .lineSpacing(isCompact ? 2 : 4)
                .textSelection(.enabled)

        case .heading(let level, let content):
            inlineMarkdown(content)
                .font(.system(size: headingSize(level), weight: .bold, design: .serif))
                .padding(.top, headingTopPadding(level))
                .textSelection(.enabled)

        case .bullet(let depth, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bulletGlyph(depth))
                    .font(.system(size: isCompact ? 12 : 13))
                    .foregroundStyle(.secondary)
                inlineMarkdown(content)
                    .font(.system(size: isCompact ? 12 : 13))
                    .lineSpacing(isCompact ? 2 : 4)
                    .textSelection(.enabled)
            }
            .padding(.leading, listIndent(depth))

        case .numbered(let depth, let label, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: isCompact ? 12 : 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                inlineMarkdown(content)
                    .font(.system(size: isCompact ? 12 : 13))
                    .lineSpacing(isCompact ? 2 : 4)
                    .textSelection(.enabled)
            }
            .padding(.leading, listIndent(depth))

        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(LecternTheme.accent.opacity(0.5))
                    .frame(width: 2)
                inlineMarkdown(content)
                    .font(.system(size: isCompact ? 12 : 13).italic())
                    .foregroundStyle(.secondary)
                    .lineSpacing(isCompact ? 2 : 4)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case .divider:
            Rectangle()
                .fill(LecternTheme.hairline)
                .frame(height: 1)
                .padding(.vertical, isCompact ? 4 : 8)

        case .diagram(let code):
            DiagramBlockView(code: code)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LecternTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                    .fill(LecternTheme.surfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                    .strokeBorder(LecternTheme.hairline, lineWidth: 1)
            )

        case .table(let header, let rows):
            let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        inlineMarkdown(header.indices.contains(column) ? header[column] : "")
                            .font(.system(size: isCompact ? 11.5 : 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .background(Color.primary.opacity(0.045))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            inlineMarkdown(row.indices.contains(column) ? row[column] : "")
                                .font(.system(size: isCompact ? 11.5 : 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LecternTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LecternTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .textSelection(.enabled)

        case .image(let url):
            if let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: isCompact ? 380 : 520)
                    .clipShape(RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                            .strokeBorder(LecternTheme.hairline, lineWidth: 1)
                    )
                    .padding(.vertical, 4)
            } else {
                Label("Missing image", systemImage: "photo.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func listIndent(_ depth: Int) -> CGFloat {
        CGFloat(min(depth, 7)) * (isCompact ? 14 : 20)
    }

    private func bulletGlyph(_ depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        if isCompact {
            switch level {
            case 1: return 14
            case 2: return 13
            default: return 12
            }
        } else {
            switch level {
            case 1: return 20
            case 2: return 17
            case 3: return 15
            default: return 14
            }
        }
    }

    private func headingTopPadding(_ level: Int) -> CGFloat {
        if isCompact {
            return level <= 2 ? 6 : 3
        } else {
            return level <= 2 ? 10 : 6
        }
    }

    /// Inline markdown (bold, italic, code) without block-level interpretation,
    /// since blocks were already split by the parser.
    private func inlineMarkdown(_ content: String) -> Text {
        var attributed = (try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
        // Shiur notes are English sentences that often open with a Hebrew
        // source name. Without a fixed base direction the whole line is laid
        // out right-to-left and the English words render in reverse order.
        attributed.writingDirection = .leftToRight
        return Text(attributed)
    }
}

private struct DiagramBlockView: View {
    let code: String

    @State private var svgData: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let svgData {
                DiagramSVGView(svgData: svgData)
                    .frame(maxWidth: 560)
            } else if failed {
                // Rendering failed: keep the source readable instead of
                // surfacing a scary warning.
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "Diagram")
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                        .fill(LecternTheme.surfaceFill)
                )
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rendering diagram…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            }
        }
        .task(id: code) {
            do {
                svgData = try await DiagramRenderer.shared.render(code: code)
            } catch {
                failed = true
            }
        }
    }
}

/// Wraps mermaid's SVG output for native display.
struct DiagramSVGView: NSViewRepresentable {
    let svgData: Data

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>body{margin:0;background:transparent;display:flex;justify-content:center;}
        svg{max-width:100%;height:auto;}</style></head>
        <body>\(String(decoding: svgData, as: UTF8.self))</body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}
