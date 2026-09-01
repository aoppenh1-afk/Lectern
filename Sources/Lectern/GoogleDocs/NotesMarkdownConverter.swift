import CryptoKit
import Foundation

/// Turns Lectern notes markdown into a Google Docs `batchUpdate` write:
/// one text insert plus heading, bullet, and bold style requests.
///
/// Nested list depth is carried by leading tab characters: Docs reads the
/// tabs to choose the nesting level for `createParagraphBullets` and then
/// strips them.
enum NotesMarkdownConverter {
    static let formatVersion = "v2"

    struct WritePlan {
        let text: String
        let headingRanges: [(start: Int, end: Int, level: Int)]
        let bulletRanges: [(start: Int, end: Int, preset: String)]
        let boldRanges: [(start: Int, end: Int)]

        func requests(tabId: String, existingBodyEndIndex: Int) -> [[String: Any]] {
            var requests: [[String: Any]] = []
            if existingBodyEndIndex > 2 {
                requests.append([
                    "deleteContentRange": [
                        "range": range(start: 1, end: existingBodyEndIndex - 1, tabId: tabId)
                    ]
                ])
            }
            requests.append([
                "insertText": [
                    "text": text,
                    "location": [
                        "index": 1,
                        "tabId": tabId
                    ] as [String: Any]
                ]
            ])
            for heading in headingRanges {
                let named = heading.level <= 1 ? "HEADING_1" : "HEADING_2"
                requests.append([
                    "updateParagraphStyle": [
                        "paragraphStyle": ["namedStyleType": named],
                        "fields": "namedStyleType",
                        "range": range(start: heading.start, end: heading.end, tabId: tabId)
                    ]
                ])
            }
            for bold in boldRanges where bold.end > bold.start {
                requests.append([
                    "updateTextStyle": [
                        "textStyle": ["bold": true],
                        "fields": "bold",
                        "range": range(start: bold.start, end: bold.end, tabId: tabId)
                    ]
                ])
            }
            // Docs deletes the depth tabs while applying bullets, which shifts
            // every later index. Styling first and bulleting from the end of
            // the document backwards keeps all ranges valid.
            for bullet in bulletRanges.sorted(by: { $0.start > $1.start }) {
                requests.append([
                    "createParagraphBullets": [
                        "range": range(start: bullet.start, end: bullet.end, tabId: tabId),
                        "bulletPreset": bullet.preset
                    ]
                ])
            }
            return requests
        }

        private func range(start: Int, end: Int, tabId: String) -> [String: Any] {
            ["startIndex": start, "endIndex": end, "tabId": tabId]
        }
    }

    static func contentHash(of markdown: String) -> String {
        let digest = SHA256.hash(data: Data("\(formatVersion)\n\(markdown)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func tabTitle(date: Date, lectureTitle: String) -> String {
        let datePart = date.formatted(.dateTime.month(.abbreviated).day())
        let title = lectureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = title.isEmpty ? datePart : "\(datePart) · \(title)"
        if combined.count <= 100 { return combined }
        return String(combined.prefix(99)) + "…"
    }

    static let bulletPreset = "BULLET_DISC_CIRCLE_SQUARE"
    static let numberedPreset = "NUMBERED_DECIMAL_ALPHA_ROMAN"

    static func plan(markdown: String) -> WritePlan {
        let items = parse(replaceFences(markdown))
        var headingRanges: [(Int, Int, Int)] = []
        var listParas: [(start: Int, end: Int, preset: String)] = []
        var boldRanges: [(Int, Int)] = []
        var cursor = 1

        for item in items {
            let start = cursor
            let textLen = item.text.utf16.count
            let end = start + textLen + 1
            switch item.kind {
            case .heading(let level):
                headingRanges.append((start, end, level))
            case .list(let marker, _):
                listParas.append((start, end, marker == .bullet ? bulletPreset : numberedPreset))
            case .body:
                break
            }
            for bold in item.bold {
                boldRanges.append((start + bold.start, start + bold.end))
            }
            cursor = end
        }

        return WritePlan(
            text: items.map(\.text).joined(separator: "\n"),
            headingRanges: headingRanges,
            bulletRanges: mergeConsecutive(listParas),
            boldRanges: boldRanges
        )
    }

    // MARK: - Parse

    private enum Kind {
        case heading(Int)
        case list(NotesListLine.Marker, depth: Int)
        case body
    }

    private struct Item {
        var kind: Kind
        var text: String
        var bold: [(start: Int, end: Int)]
    }

    private static func parse(_ markdown: String) -> [Item] {
        var items: [Item] = []
        var lists = NotesListScanner()
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for line in lines {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("---") && trimmed.trimmingCharacters(in: .init(charactersIn: "-")).isEmpty {
                lists.reset()
                continue
            }
            let listItem = lists.scan(raw)
            if let heading = headingMatch(trimmed) {
                let inline = flattenInline(heading.text)
                items.append(Item(kind: .heading(heading.level), text: nonempty(inline.text), bold: inline.bold))
            } else if let listItem {
                let inline = flattenInline(listItem.content)
                // Docs caps list nesting at nine levels.
                let depth = min(listItem.depth, 8)
                let tabs = String(repeating: "\t", count: depth)
                let shifted = inline.bold.map { (start: $0.start + depth, end: $0.end + depth) }
                items.append(Item(
                    kind: .list(listItem.marker, depth: depth),
                    text: tabs + nonempty(inline.text),
                    bold: shifted
                ))
            } else {
                let inline = flattenInline(stripQuote(trimmed))
                let text = inline.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    items.append(Item(kind: .body, text: text, bold: inline.bold))
                }
            }
        }
        if items.isEmpty {
            items.append(Item(kind: .body, text: "(No notes)", bold: []))
        }
        return items
    }

    private static func nonempty(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? " " : text
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let marks = Range(match.range(at: 1), in: line),
              let text = Range(match.range(at: 2), in: line) else { return nil }
        return (line[marks].count, String(line[text]))
    }

    private static func stripQuote(_ line: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #"^>\s?(.*)$"#),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let text = Range(match.range(at: 1), in: line) {
            return String(line[text])
        }
        return line
    }

    private static func replaceFences(_ markdown: String) -> String {
        var result = markdown
        let mermaid = try! NSRegularExpression(
            pattern: #"```mermaid\s*\n.*?```"#,
            options: [.dotMatchesLineSeparators]
        )
        result = mermaid.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "Diagram omitted."
        )
        let fence = try! NSRegularExpression(
            pattern: #"```[^\n]*\n.*?```"#,
            options: [.dotMatchesLineSeparators]
        )
        result = fence.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "Code omitted."
        )
        return result
    }

    private static func flattenInline(_ raw: String) -> (text: String, bold: [(start: Int, end: Int)]) {
        var working = raw
        working = replacePattern(working, #"!\[([^\]]*)\]\([^)]+\)"#, template: "$1")
        working = replacePattern(working, #"\[([^\]]+)\]\([^)]+\)"#, template: "$1")
        working = replacePattern(working, #"`([^`]+)`"#, template: "$1")
        working = replacePattern(working, #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, template: "$1")

        var output = ""
        var bolds: [(Int, Int)] = []
        var index = working.startIndex
        while index < working.endIndex {
            if working[index...].hasPrefix("**"),
               let close = working[working.index(index, offsetBy: 2)...].range(of: "**") {
                let inner = String(working[working.index(index, offsetBy: 2)..<close.lowerBound])
                let start = output.utf16.count
                output += inner
                let end = output.utf16.count
                if end > start { bolds.append((start, end)) }
                index = close.upperBound
            } else {
                output.append(working[index])
                index = working.index(after: index)
            }
        }
        return (output, bolds)
    }

    private static func replacePattern(_ input: String, _ pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return regex.stringByReplacingMatches(
            in: input, range: NSRange(input.startIndex..., in: input),
            withTemplate: template
        )
    }

    private static func mergeConsecutive(
        _ paras: [(start: Int, end: Int, preset: String)]
    ) -> [(start: Int, end: Int, preset: String)] {
        guard var current = paras.first else { return [] }
        var merged: [(start: Int, end: Int, preset: String)] = []
        for para in paras.dropFirst() {
            if para.start == current.end, para.preset == current.preset {
                current.end = para.end
            } else {
                merged.append(current)
                current = para
            }
        }
        merged.append(current)
        return merged
    }
}
