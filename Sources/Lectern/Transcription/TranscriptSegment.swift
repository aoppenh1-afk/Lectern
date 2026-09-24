import Foundation

/// One timed span of transcribed speech, produced by either transcription
/// engine (Parakeet or whisper.cpp).
struct TranscriptSegment: Sendable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

/// Raw transcript paragraphs retain the timestamps used in the reading view.
/// The recording offset is kept separately because displayed times are rounded.
struct TranscriptParagraph: Sendable {
    let startSeconds: Double?
    let timestampLabel: String?
    let text: String

    static func parse(_ content: String) -> [TranscriptParagraph] {
        content.components(separatedBy: "\n\n").compactMap { raw in
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else {
                return .init(startSeconds: nil, timestampLabel: nil, text: trimmed)
            }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let parts = label.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else {
                return .init(startSeconds: nil, timestampLabel: nil, text: trimmed)
            }
            let text = trimmed[trimmed.index(after: close)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(startSeconds: parts[0] * 60 + parts[1],
                         timestampLabel: label, text: text)
        }
    }

    static func closestIndex(to offset: TimeInterval, in paragraphs: [TranscriptParagraph]) -> Int? {
        let timed = paragraphs.enumerated().compactMap { index, paragraph -> (Int, Double)? in
            paragraph.startSeconds.map { (index, $0) }
        }
        guard !timed.isEmpty else { return paragraphs.isEmpty ? nil : 0 }
        return timed.min { left, right in
            let leftDistance = abs(left.1 - offset)
            let rightDistance = abs(right.1 - offset)
            return leftDistance == rightDistance ? left.1 < right.1 : leftDistance < rightDistance
        }?.0
    }

    static func timeLabel(_ offset: TimeInterval) -> String {
        let seconds = max(0, Int(offset))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func link(_ offset: TimeInterval) -> String {
        "lectern://bookmark/\(max(0, Int((offset * 1_000).rounded())))"
    }
}
