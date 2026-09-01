import Foundation

/// One timed span of transcribed speech, produced by either transcription
/// engine (Parakeet or whisper.cpp).
struct TranscriptSegment: Sendable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}
