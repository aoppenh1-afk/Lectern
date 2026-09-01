import Foundation

/// One Markdown list item with its nesting depth resolved. Lectern's notes
/// renderer, document exporter, and Google Docs converter all read list
/// structure through this type so nested outlines look the same everywhere.
struct NotesListLine: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case bullet
        case ordered
    }

    /// Zero-based nesting level.
    let depth: Int
    let marker: Marker
    /// One-based position among consecutive ordered siblings; `0` for bullets.
    let ordinal: Int
    let content: String

    /// Spaces that move a list item one level deeper in canonical Lectern Markdown.
    static let indentUnit = 4

    /// Label shown for an ordered item, cycling decimal → alpha → roman by depth
    /// the way the student's own outlines do (1. / a. / i.).
    var orderedLabel: String {
        switch depth % 3 {
        case 0: return "\(ordinal)."
        case 1: return Self.alphaLabel(ordinal) + "."
        default: return Self.romanLabel(ordinal) + "."
        }
    }

    /// Canonical Markdown for this item: four-space indentation, `-` bullets,
    /// and the written ordinal for numbered items.
    var canonicalMarkdown: String {
        let indent = String(repeating: " ", count: depth * Self.indentUnit)
        switch marker {
        case .bullet: return indent + "- " + content
        case .ordered: return indent + "\(ordinal). " + content
        }
    }

    static func alphaLabel(_ ordinal: Int) -> String {
        guard ordinal >= 1 else { return "a" }
        var value = ordinal
        var label = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            label = String(UnicodeScalar(UInt8(97 + remainder))) + label
            value = (value - 1) / 26
        }
        return label
    }

    static func romanLabel(_ ordinal: Int) -> String {
        guard ordinal >= 1 else { return "i" }
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var value = ordinal
        var label = ""
        for (weight, glyph) in table where value > 0 {
            while value >= weight {
                label += glyph
                value -= weight
            }
        }
        return label
    }

    /// Raw shape of a list line before its depth is resolved.
    struct Raw: Equatable {
        let indentWidth: Int
        let marker: Marker
        let writtenNumber: Int?
        let content: String
    }

    private static let bulletPattern = try! NSRegularExpression(pattern: #"^([-*+•▪◦●○])\s+(.*)$"#)
    private static let orderedPattern = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)]\s+(.*)$"#)

    /// Recognizes `- item`, `* item`, `• item`, `1. item`, and `1) item` after
    /// any leading whitespace. Tabs count as one indent unit.
    static func raw(_ line: String) -> Raw? {
        var width = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += indentUnit
            } else {
                break
            }
            index = line.index(after: index)
        }
        let body = String(line[index...])
        guard !body.isEmpty else { return nil }
        let range = NSRange(body.startIndex..., in: body)

        if let match = bulletPattern.firstMatch(in: body, range: range),
           let contentRange = Range(match.range(at: 2), in: body) {
            return Raw(indentWidth: width, marker: .bullet, writtenNumber: nil, content: String(body[contentRange]))
        }
        if let match = orderedPattern.firstMatch(in: body, range: range),
           let numberRange = Range(match.range(at: 1), in: body),
           let contentRange = Range(match.range(at: 2), in: body) {
            return Raw(
                indentWidth: width,
                marker: .ordered,
                writtenNumber: Int(body[numberRange]),
                content: String(body[contentRange])
            )
        }
        return nil
    }
}

/// Walks a Markdown document line by line and resolves each list item's
/// depth from the indentation actually used, so two-space, four-space, and
/// tab-indented outlines all nest correctly.
struct NotesListScanner {
    private var indentWidths: [Int] = []
    private var ordinals: [Int] = []

    private static let headingPattern = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)

    init() {}

    mutating func reset() {
        indentWidths.removeAll()
        ordinals.removeAll()
    }

    /// Returns the resolved list item for `line`, or `nil` for headings,
    /// paragraphs, and blank lines. Headings and flush-left paragraphs end the
    /// current list; blank lines do not, so loose lists keep their nesting.
    mutating func scan(_ line: String) -> NotesListLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        if Self.headingPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            reset()
            return nil
        }

        guard let raw = NotesListLine.raw(line) else {
            if line.first.map({ $0 != " " && $0 != "\t" }) ?? false {
                reset()
            }
            return nil
        }

        while let last = indentWidths.last, last > raw.indentWidth {
            indentWidths.removeLast()
            ordinals.removeLast()
        }
        if indentWidths.isEmpty || indentWidths.last! < raw.indentWidth {
            indentWidths.append(raw.indentWidth)
            ordinals.append(0)
        }
        let depth = indentWidths.count - 1

        let ordinal: Int
        switch raw.marker {
        case .bullet:
            ordinals[depth] = 0
            ordinal = 0
        case .ordered:
            ordinals[depth] += 1
            ordinal = ordinals[depth]
        }

        return NotesListLine(depth: depth, marker: raw.marker, ordinal: ordinal, content: raw.content)
    }
}

/// Rewrites model-generated notes into Lectern's canonical Markdown before
/// validation, storage, and rendering. The rewrite is structural only: text
/// content, headings, and fenced blocks are preserved verbatim.
enum NotesMarkdownNormalizer {
    static func normalize(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrapperFence(text)

        var scanner = NotesListScanner()
        var output: [String] = []
        var inFence = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                output.append(line)
                continue
            }
            if inFence {
                output.append(line)
                continue
            }

            for piece in splitInlineBullets(line) {
                if let item = scanner.scan(piece) {
                    output.append(item.canonicalMarkdown)
                } else {
                    output.append(piece.trimmingCharacters(in: .whitespaces).isEmpty ? "" : piece)
                }
            }
        }

        return output.joined(separator: "\n")
    }

    /// Removes a single ```markdown fence wrapped around the entire document.
    private static func stripWrapperFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
              let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("```"),
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return text }
        let interiorFences = lines.dropFirst().dropLast().filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        // A fence that closes early is a real code block, not a wrapper.
        guard interiorFences.count % 2 == 0 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a line that packs several `•` bullets together into separate
    /// items at the same indentation. Hyphens are left alone because they
    /// appear inside ordinary prose.
    private static func splitInlineBullets(_ line: String) -> [String] {
        guard line.contains("•") else { return [line] }
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)
        guard body.hasPrefix("•") else { return [line] }
        let parts = body.split(separator: "•", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return [line] }
        return parts.map { "\(leading)- \($0)" }
    }
}
