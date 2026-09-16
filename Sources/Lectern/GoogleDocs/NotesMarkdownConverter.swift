import CryptoKit
import Foundation

/// Turns Lectern notes markdown into a Google Docs `batchUpdate` write:
/// one text insert plus heading, bullet, bold, and paragraph-direction requests.
///
/// Nested list depth is carried by leading tab characters: Docs reads the
/// tabs to choose the nesting level for `createParagraphBullets` and then
/// strips them.
enum NotesMarkdownConverter {
    static let formatVersion = "v9"

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
        // Docs tab labels allow 50 characters. Count UTF-16 conservatively,
        // but truncate only between whole characters, including Hebrew marks.
        if combined.utf16.count <= 50 { return combined }
        var prefix = ""
        for character in combined {
            guard prefix.utf16.count + String(character).utf16.count <= 49 else { break }
            prefix.append(character)
        }
        return prefix + "…"
    }

    static let bulletPreset = "BULLET_DISC_CIRCLE_SQUARE"
    static let numberedPreset = "NUMBERED_DECIMAL_ALPHA_ROMAN"

    static func plan(markdown: String) -> WritePlan {
        let items = parse(NotesDafCitation.normalize(replaceFences(removingDirectionControls(markdown))))
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

    /// Format inline content without interpreting a leading number as a list.
    static func inlinePlan(_ markdown: String) -> (text: String, bold: [(start: Int, end: Int)]) {
        let inline = flattenInline(NotesDafCitation.normalize(removingDirectionControls(markdown)))
        let anchored = anchorHebrewRuns(in: inline.text, boldRanges: inline.bold)
        return (anchored.text, anchored.bold)
    }

    /// Apply the export boundary rules to native notes without losing inline styles.
    static func directionalInline(_ markdown: String) -> AttributedString {
        let clean = NotesDafCitation.normalize(removingDirectionControls(markdown))
        let original = (try? AttributedString(markdown: clean, options:
            AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(clean)
        let text = String(original.characters)
        let bold = original.runs.compactMap { run -> (start: Int, end: Int)? in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else { return nil }
            return (String(original.characters[..<run.range.lowerBound]).utf16.count,
                    String(original.characters[..<run.range.upperBound]).utf16.count)
        }
        let anchored = anchorHebrewRuns(in: text, boldRanges: bold)
        var result = AttributedString()
        var previous = original.startIndex
        for insertion in anchored.insertions {
            let stringIndex = String.Index(utf16Offset: insertion.offset, in: text)
            guard let index = AttributedString.Index(stringIndex, within: original) else { continue }
            result.append(original[previous..<index])
            result.append(AttributedString(insertion.text))
            previous = index
        }
        result.append(original[previous...])
        return result
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

    private struct DirectionInsertion {
        let offset: Int
        let text: String
    }

    private static func anchorHebrewRuns(
        in text: String,
        boldRanges: [(start: Int, end: Int)]
    ) -> (text: String, bold: [(start: Int, end: Int)], insertions: [DirectionInsertion]) {
        let textLength = text.utf16.count
        // A leading bold organizing label is a separate LTR block from its
        // explanation. Emphasis within the explanation keeps its phrase intact.
        let labelEnd = boldRanges.first.flatMap { bold -> Int? in
            let prefix = utf16Substring(text, from: 0, to: bold.start)
            return prefix.trimmingCharacters(in: .whitespaces).isEmpty ? bold.end : nil
        }
        let boundaries = [0] + (labelEnd.map { [$0] } ?? []) + [textLength]
        let segments = zip(boundaries, boundaries.dropFirst()).flatMap { bounds in
            hebrewSegments(in: text, from: bounds.0, to: bounds.1,
                isLabel: bounds.1 == labelEnd)
        }

        // LRM keeps separate outline components in LTR order. RLM inside those
        // boundaries gives quotes and paired punctuation the Hebrew run's
        // direction, including when the run wraps onto another line.
        let insertions = segments.flatMap { segment -> [DirectionInsertion] in
            let content = utf16Substring(text, from: segment.start, to: segment.end)
            let needsRTLBoundary = content.unicodeScalars.first.map { !isHebrew($0) } == true
                || content.unicodeScalars.last.map { !isHebrew($0) } == true
            return [
                DirectionInsertion(offset: segment.start, text: needsRTLBoundary ? "\u{200E}\u{200F}" : "\u{200E}"),
                DirectionInsertion(offset: segment.end, text: needsRTLBoundary ? "\u{200F}\u{200E}" : "\u{200E}"),
            ]
        }
        var output = ""
        var previousEnd = 0
        for insertion in insertions {
            output += utf16Substring(text, from: previousEnd, to: insertion.offset)
            output += insertion.text
            previousEnd = insertion.offset
        }
        output += utf16Substring(text, from: previousEnd, to: textLength)

        let adjustedBold = boldRanges.map { bold in
            let shiftedStart = bold.start + insertions.filter { $0.offset <= bold.start }.reduce(0) { $0 + $1.text.utf16.count }
            let shiftedEnd = bold.end + insertions.filter { $0.offset < bold.end }.reduce(0) { $0 + $1.text.utf16.count }
            return (shiftedStart, shiftedEnd)
        }
        return (output, adjustedBold, insertions)
    }

    /// Hebrew passages are linguistic units, not punctuation-delimited words.
    /// A source label owns its citation; an aside in English prose is separate
    /// from the preceding Hebrew term. Balanced Hebrew quotes/asides own their
    /// delimiters, so a line wrap cannot leave a bracket facing the wrong way.
    private static func hebrewSegments(
        in text: String,
        from lowerBound: Int,
        to upperBound: Int,
        isLabel: Bool
    ) -> [(start: Int, end: Int)] {
        guard upperBound > lowerBound else { return [] }
        let part = utf16Substring(text, from: lowerBound, to: upperBound)
        let scalars = Array(part.unicodeScalars)
        var offsets = [lowerBound]
        for scalar in scalars { offsets.append(offsets.last! + scalar.utf16.count) }

        func hebrewOnly(_ range: Range<Int>) -> Bool {
            let contents = scalars[range]
            return contents.contains(where: isHebrew) && !contents.contains {
                CharacterSet.letters.contains($0) && !isHebrew($0)
            }
        }
        func segment(_ range: Range<Int>) -> (start: Int, end: Int) {
            (offsets[range.lowerBound], offsets[range.upperBound])
        }
        var start = 0
        var end = scalars.count
        while start < end && CharacterSet.whitespacesAndNewlines.contains(scalars[start]) { start += 1 }
        while end > start && CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) { end -= 1 }
        // A source/explanation separator belongs to the outer LTR outline.
        // The daf amud marker is part of the source itself.
        if isLabel && end > start && scalars[end - 1] == ":" {
            let label = String(String.UnicodeScalarView(scalars[start..<end]))
            if label.range(of: #"דף\s+[א-ת״׳]+:$"#, options: .regularExpression) == nil { end -= 1 }
        }
        guard end > start else { return [] }
        if !CharacterSet.decimalDigits.contains(scalars[start]), hebrewOnly(start..<end) {
            return [segment(start..<end)]
        }

        let pairs: [Unicode.Scalar: Unicode.Scalar] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "“": "”"]
        func pairedEnd(at opening: Int) -> Int? {
            guard let closing = pairs[scalars[opening]] else { return nil }
            // ASCII quotes between Hebrew letters are abbreviation marks.
            if scalars[opening] == "\"" && opening > start && isHebrew(scalars[opening - 1]) { return nil }
            var depth = 1
            var cursor = opening + 1
            while cursor < end {
                if scalars[cursor] == closing {
                    if closing == "\"" && cursor > opening + 1 && cursor + 1 < end
                        && isHebrew(scalars[cursor - 1]) && isHebrew(scalars[cursor + 1]) {
                        cursor += 1
                        continue
                    }
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                } else if scalars[cursor] == scalars[opening] { depth += 1 }
                cursor += 1
            }
            return nil
        }

        // A terminal daf amud marker still belongs to its numeral when the
        // surrounding sentence resumes in English.
        let citation = try! NSRegularExpression(
            pattern: #"דף[ \t]+[א-ת״׳]+[.:]?(?:[-–][א-ת״׳]+[.:]?)?"#)
        let citations = citation.matches(in: text,
            range: NSRange(location: lowerBound, length: upperBound - lowerBound)).map(\.range)
        var segments: [(start: Int, end: Int)] = []
        var cursor = start
        while cursor < end {
            if let close = pairedEnd(at: cursor), hebrewOnly((cursor + 1)..<(close - 1)) {
                segments.append(segment(cursor..<close))
                cursor = close
                continue
            }
            guard isHebrew(scalars[cursor]) else { cursor += 1; continue }
            let runStart = cursor
            var runEnd = cursor + 1
            cursor += 1
            while cursor < end {
                let scalar = scalars[cursor]
                if isHebrew(scalar) {
                    runEnd = cursor + 1
                } else if CharacterSet.whitespaces.contains(scalar) {
                    // Retain whitespace only if another Hebrew word follows.
                } else if (scalar == "\"" || scalar == "'") && cursor + 1 < end
                    && isHebrew(scalars[cursor - 1]) && isHebrew(scalars[cursor + 1]) {
                    runEnd = cursor + 1
                } else if citations.contains(where: { NSLocationInRange(offsets[cursor], $0) }) {
                    runEnd = cursor + 1
                } else if ",;:.!?…–-".unicodeScalars.contains(scalar),
                    scalars[(cursor + 1)..<end].first(where: {
                        !CharacterSet.whitespaces.contains($0) && !",;:.!?…–-".unicodeScalars.contains($0)
                    }).map(isHebrew) == true {
                    // Commas, ellipses, colons, and semicolons do not restart
                    // a continuing Hebrew passage.
                    runEnd = cursor + 1
                } else { break }
                cursor += 1
            }
            segments.append(segment(runStart..<runEnd))
        }
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
