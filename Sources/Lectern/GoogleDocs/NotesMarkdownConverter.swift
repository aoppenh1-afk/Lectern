import CryptoKit
import Foundation

/// Turns Lectern notes markdown into a Google Docs `batchUpdate` write:
/// one text insert plus heading, bullet, bold, and paragraph-direction requests.
///
/// Nested list depth is carried by leading tab characters: Docs reads the
/// tabs to choose the nesting level for `createParagraphBullets` and then
/// strips them.
enum NotesMarkdownConverter {
    static let formatVersion = "v8"

    struct WritePlan {
        let text: String
        let headingRanges: [(start: Int, end: Int, level: Int)]
        let bulletRanges: [(start: Int, end: Int, preset: String)]
        let boldRanges: [(start: Int, end: Int)]
        let directionRanges: [(start: Int, end: Int, direction: String)]

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
            // The final paragraph survives deleting the old body. Docs can
            // retain its list membership and copy it to every inserted line.
            // Clear inherited bullets before applying this outline's list ranges.
            let bodyRange = range(start: 1, end: text.utf16.count + 1, tabId: tabId)
            requests.append([
                "deleteParagraphBullets": ["range": bodyRange]
            ])
            // Removing bullets preserves their visual indentation. Reset that
            // too, so headings/body text stay flush left across repeated syncs.
            // Depth tabs remain in the text for createParagraphBullets below.
            requests.append([
                "updateParagraphStyle": [
                    "paragraphStyle": [
                        "indentStart": ["magnitude": 0, "unit": "PT"],
                        "indentEnd": ["magnitude": 0, "unit": "PT"],
                        "indentFirstLine": ["magnitude": 0, "unit": "PT"],
                    ],
                    "fields": "indentStart,indentEnd,indentFirstLine",
                    "range": bodyRange,
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
            // The outline always flows left to right, including Hebrew-first
            // headings. Hebrew phrases are bounded by invisible strong LTR marks.
            for paragraph in directionRanges {
                requests.append([
                    "updateParagraphStyle": [
                        "paragraphStyle": [
                            "direction": paragraph.direction,
                            "alignment": paragraph.direction == "RIGHT_TO_LEFT" ? "END" : "START",
                        ],
                        "fields": "direction,alignment",
                        "range": range(start: paragraph.start, end: paragraph.end, tabId: tabId),
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
        let items = parse(replaceFences(removingDirectionControls(markdown)))
        var headingRanges: [(Int, Int, Int)] = []
        var listParas: [(start: Int, end: Int, preset: String)] = []
        var boldRanges: [(Int, Int)] = []
        var directionRanges: [(start: Int, end: Int, direction: String)] = []
        var renderedItems: [String] = []
        var cursor = 1

        for item in items {
            let anchored = anchorHebrewRuns(in: item.text, boldRanges: item.bold)
            let renderedText = anchored.text
            let renderedBold = anchored.bold

            let start = cursor
            let textLen = renderedText.utf16.count
            let end = start + textLen + 1
            switch item.kind {
            case .heading(let level):
                headingRanges.append((start, end, level))
            case .list(let marker, _):
                listParas.append((start, end, marker == .bullet ? bulletPreset : numberedPreset))
            case .body:
                break
            }
            for bold in renderedBold {
                boldRanges.append((start + bold.start, start + bold.end))
            }
            directionRanges.append((
                start,
                end,
                "LEFT_TO_RIGHT"
            ))
            renderedItems.append(renderedText)
            cursor = end
        }

        return WritePlan(
            text: renderedItems.joined(separator: "\n"),
            headingRanges: headingRanges,
            bulletRanges: mergeConsecutive(listParas),
            boldRanges: boldRanges,
            directionRanges: directionRanges
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
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})\s*(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let marks = Range(match.range(at: 1), in: line),
              let text = Range(match.range(at: 2), in: line) else { return nil }
        return (line[marks].count, String(line[text]).trimmingCharacters(in: .whitespaces))
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

    private static func removingDirectionControls(_ text: String) -> String {
        // Rebuild direction at the export boundary, before calculating Markdown
        // and UTF-16 ranges. Replace pasted controls with the export boundary marks.
        String(text.unicodeScalars.filter {
            switch $0.value {
            case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
                return false
            default:
                return true
            }
        })
    }

    private static func isHebrew(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return true
        default:
            return false
        }
    }

    private static func anchorHebrewRuns(
        in text: String,
        boldRanges: [(start: Int, end: Int)]
    ) -> (text: String, bold: [(start: Int, end: Int)]) {
        let textLength = text.utf16.count
        // Bold changes presentation, not Hebrew word order. Splitting a phrase
        // at a bold boundary would reorder its parts within the LTR paragraph.
        let segments = hebrewSegments(in: text, from: 0, to: textLength)

        // Google Docs does not reliably honor RLI/PDI isolates: adjacent Hebrew
        // labels reorder and brackets mirror despite an LTR paragraph. U+200E
        // has the direction of an English letter but no visible glyph or width.
        // Mark both edges so punctuation and numbers stay in the LTR context.
        // Verified in Docs with "חנניה: נותנים" and "גירסא 1 (רש״י ורוב ראשונים)".
        var output = ""
        var previousEnd = 0
        for segment in segments {
            output += utf16Substring(text, from: previousEnd, to: segment.start)
            output += "\u{200E}"
            output += utf16Substring(text, from: segment.start, to: segment.end)
            output += "\u{200E}"
            previousEnd = segment.end
        }
        output += utf16Substring(text, from: previousEnd, to: textLength)

        let insertionOffsets = segments.flatMap { [$0.start, $0.end] }
        let adjustedBold = boldRanges.map { bold in
            let shiftedStart = bold.start + insertionOffsets.count(where: { $0 <= bold.start })
            let shiftedEnd = bold.end + insertionOffsets.count(where: { $0 < bold.end })
            return (shiftedStart, shiftedEnd)
        }
        return (output, adjustedBold)
    }

    private static func hebrewSegments(
        in text: String,
        from lowerBound: Int,
        to upperBound: Int
    ) -> [(start: Int, end: Int)] {
        guard upperBound > lowerBound else { return [] }
        let lowerIndex = String.Index(utf16Offset: lowerBound, in: text)
        let upperIndex = String.Index(utf16Offset: upperBound, in: text)
        var segments: [(start: Int, end: Int)] = []
        var segmentStart: Int?
        var lastHebrewEnd = lowerBound
        var offset = lowerBound

        func finishSegment() {
            guard let start = segmentStart else { return }
            segments.append((start, lastHebrewEnd))
            segmentStart = nil
        }

        let scalars = Array(text[lowerIndex..<upperIndex].unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let scalarEnd = offset + scalar.utf16.count
            if isHebrew(scalar) {
                if segmentStart == nil { segmentStart = offset }
                lastHebrewEnd = scalarEnd
            } else if (scalar == "\"" || scalar == "'") && index > 0
                && index + 1 < scalars.count
                && isHebrew(scalars[index - 1]) && isHebrew(scalars[index + 1]) {
                // Legacy ASCII abbreviation quotes belong inside the word.
                lastHebrewEnd = scalarEnd
            } else if !CharacterSet.whitespaces.contains(scalar) {
                // Sentence punctuation, paired brackets, and numbers belong to
                // the LTR sentence. Never swallow one side of a bracket pair,
                // or join comma/semicolon-separated Hebrew phrases into one run.
                finishSegment()
            }
            offset = scalarEnd
        }
        finishSegment()
        return segments
    }

    private static func utf16Substring(_ text: String, from start: Int, to end: Int) -> String {
        let startIndex = String.Index(utf16Offset: start, in: text)
        let endIndex = String.Index(utf16Offset: end, in: text)
        return String(text[startIndex..<endIndex])
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
