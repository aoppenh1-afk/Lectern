import CryptoKit
import Foundation

/// Turns Lectern notes markdown into a Google Docs `batchUpdate` write:
/// one text insert plus heading, bullet, bold, and paragraph-direction requests.
///
/// Nested list depth is carried by leading tab characters: Docs reads the
/// tabs to choose the nesting level for `createParagraphBullets` and then
/// strips them.
enum NotesMarkdownConverter {
    static let formatVersion = "v5"

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
            // Hebrew headings and body paragraphs use RTL flow with physical
            // left alignment. Hebrew-led list paragraphs are emitted as LTR
            // so Docs keeps their bullets on the left; their text is wrapped
            // in a Unicode RTL isolate by `plan(markdown:)`.
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
        let items = parse(replaceFences(markdown))
        var headingRanges: [(Int, Int, Int)] = []
        var listParas: [(start: Int, end: Int, preset: String)] = []
        var boldRanges: [(Int, Int)] = []
        var directionRanges: [(start: Int, end: Int, direction: String)] = []
        var renderedItems: [String] = []
        var cursor = 1

        for item in items {
            let naturalDirection = paragraphDirection(for: item.text)
            let isHebrewList: Bool
            let renderedText: String
            let renderedBold: [(start: Int, end: Int)]
            if case .list = item.kind, naturalDirection == "RIGHT_TO_LEFT" {
                isHebrewList = true
                let isolated = isolateHebrewRuns(in: item.text, splitAt: item.bold)
                renderedText = isolated.text
                renderedBold = isolated.bold
            } else {
                isHebrewList = false
                renderedText = item.text
                renderedBold = item.bold
            }

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
                isHebrewList ? "LEFT_TO_RIGHT" : naturalDirection
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

    private static func paragraphDirection(for text: String) -> String {
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            return isHebrew(scalar) ? "RIGHT_TO_LEFT" : "LEFT_TO_RIGHT"
        }
        return "LEFT_TO_RIGHT"
    }

    private static func isHebrew(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return true
        default:
            return false
        }
    }

    private static func isolateHebrewRuns(
        in text: String,
        splitAt boldRanges: [(start: Int, end: Int)]
    ) -> (text: String, bold: [(start: Int, end: Int)]) {
        let textLength = text.utf16.count
        let boundaries = Set(
            [0, textLength] + boldRanges.flatMap { [$0.start, $0.end] }
        ).sorted()
        var segments: [(start: Int, end: Int)] = []

        for index in 0..<(boundaries.count - 1) {
            segments += hebrewSegments(
                in: text,
                from: boundaries[index],
                to: boundaries[index + 1]
            )
        }

        var output = ""
        var previousEnd = 0
        for segment in segments {
            output += utf16Substring(text, from: previousEnd, to: segment.start)
            output += "\u{2067}"
            output += utf16Substring(text, from: segment.start, to: segment.end)
            output += "\u{2069}"
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

        func finishSegment(at boundary: Int) {
            guard let start = segmentStart else { return }
            let end = hebrewSegmentEnd(
                in: text,
                afterLastHebrew: lastHebrewEnd,
                before: boundary
            )
            segments.append((start, end))
            segmentStart = nil
        }

        for scalar in text[lowerIndex..<upperIndex].unicodeScalars {
            let scalarEnd = offset + scalar.utf16.count
            if isHebrew(scalar) {
                if segmentStart == nil { segmentStart = offset }
                lastHebrewEnd = scalarEnd
            } else if CharacterSet.letters.contains(scalar) {
                finishSegment(at: offset)
            }
            offset = scalarEnd
        }
        finishSegment(at: upperBound)
        return segments
    }

    private static func hebrewSegmentEnd(
        in text: String,
        afterLastHebrew lastHebrewEnd: Int,
        before boundary: Int
    ) -> Int {
        let pending = utf16Substring(text, from: lastHebrewEnd, to: boundary)
        guard let lastNonspace = pending.rangeOfCharacter(
            from: .whitespacesAndNewlines.inverted,
            options: .backwards
        ) else {
            return lastHebrewEnd
        }
        let meaningful = String(pending[..<lastNonspace.upperBound])
        if meaningful.contains(where: { "([{<".contains($0) }) {
            return lastHebrewEnd
        }
        return lastHebrewEnd + meaningful.utf16.count
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
