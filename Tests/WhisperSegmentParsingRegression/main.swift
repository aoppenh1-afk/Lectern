import Foundation

// Whisper stdout parsing: whisper-cli prints one segment per line as
// `[hh:mm:ss.mmm --> hh:mm:ss.mmm]   text`. Everything else (backend load
// logs, system info, blank lines) must be ignored.

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

// Plain English segment.
guard let plain = WhisperTranscriptionEngine.parseSegmentLine(
    "[00:00:00.000 --> 00:00:07.760]   Today we are going to continue from last week."
) else { fail("plain segment line should parse") }
guard plain.startSeconds == 0, plain.endSeconds == 7.76,
      plain.text == "Today we are going to continue from last week." else {
    fail("plain segment parsed wrong values: \(plain)")
}

// Mixed Hebrew/English mid-sentence (the shiur case).
guard let mixed = WhisperTranscriptionEngine.parseSegmentLine(
    "[00:01:02.480 --> 00:01:07.200]   The גמרא asks on רש\"י why this הלכה applies."
) else { fail("mixed Hebrew/English segment should parse") }
guard mixed.startSeconds == 62.48, mixed.endSeconds == 67.2,
      mixed.text.contains("גמרא"), mixed.text.contains("applies.") else {
    fail("mixed segment parsed wrong values: \(mixed)")
}

// Hour-long shiur timestamps.
guard let long = WhisperTranscriptionEngine.parseSegmentLine(
    "[01:15:30.500 --> 01:15:33.000] ends here"
) else { fail("hour-plus timestamps should parse") }
guard long.startSeconds == 4530.5, long.endSeconds == 4533.0 else {
    fail("hour-plus timestamps parsed wrong values: \(long)")
}

// Non-segment output must be ignored.
let noise = [
    "",
    "whisper_init_from_file_with_params_no_state: loading model from 'ggml-large-v3-turbo-q8_0.bin'",
    "ggml_metal_device_init: GPU name:   MTL0 (Apple M3)",
    "system_info: n_threads = 6 / 8",
    "main: processing 'lecture.wav' (92735913 samples, 5795.9 sec)",
    "[00:00:00.000 --> 00:00:01.000]   ",  // empty text
]
for line in noise where WhisperTranscriptionEngine.parseSegmentLine(line) != nil {
    fail("noise line should not parse as a segment: \(line)")
}

// Long-form decoding must not carry a bad text window into the next one. The
// real 79-minute shiur repeated the same three-word phrase 548 times once the
// decoder history became poisoned.
let arguments = WhisperTranscriptionEngine.cliArguments(
    modelURL: URL(fileURLWithPath: "/model.bin"),
    audioURL: URL(fileURLWithPath: "/lecture.wav"),
    threadCount: 6
)
guard WhisperTranscriptionEngine.modelFileName == "ggml-large-v3-q5_0.bin" else {
    fail("mixed Hebrew-English lectures must use the full large-v3 Q5 model")
}
guard arguments.containsPair("-mc", "128"),
      arguments.contains("--carry-initial-prompt"),
      let promptIndex = arguments.firstIndex(of: "--prompt"),
      arguments.indices.contains(promptIndex + 1),
      arguments[promptIndex + 1].contains("ספק דרבנן לקולא") else {
    fail("Whisper must use a bounded carried bilingual spelling prompt")
}
guard !arguments.containsPair("-mc", "0") else {
    fail("the static prompt needs a bounded context budget")
}

// Full large-v3 can echo a prompted sentence twice. Remove one exact echo,
// while preserving ordinary human repetition that is not an exact full copy.
guard let echoed = WhisperTranscriptionEngine.parseSegmentLine(
    "[00:00:00.000 --> 00:00:04.000]   Yeah, let's start the Mishnah. Yeah, let's start the Mishnah."
) else { fail("echoed full-model segment should parse") }
guard echoed.text == "Yeah, let's start the Mishnah." else {
    fail("exact full-sentence model echo must be collapsed once: \(echoed.text)")
}

let loopingText = Array(repeating: "Hanukkah Tishiyo yamei", count: 548)
    .joined(separator: " ")
let loopingSegment = TranscriptSegment(
    startSeconds: 4_004,
    endSeconds: 4_034,
    text: loopingText
)
guard WhisperTranscriptionEngine.transcriptQualityIssue(
    in: [plain, loopingSegment]
) != nil else {
    fail("the 548-repeat shiur failure must be rejected")
}

let ordinaryRepetition = TranscriptSegment(
    startSeconds: 70,
    endSeconds: 76,
    text: "No, no, no. The Gemara gives a different answer."
)
guard WhisperTranscriptionEngine.transcriptQualityIssue(
    in: [plain, mixed, ordinaryRepetition, long]
) == nil else {
    fail("ordinary spoken repetition must remain valid")
}

// A long lecture can contain a brief decoder stumble without making the
// otherwise complete transcript unusable. This exact two-word repetition was
// an early quality-gate match in a useful 79-minute mixed-language lecture.
let isolatedStumble = TranscriptSegment(
    startSeconds: 4_469,
    endSeconds: 4_475,
    text: "because the candles correspond to the eight days that the that the that the that the that the miracle lasted"
)
guard WhisperTranscriptionEngine.transcriptQualityIssue(
    in: [plain, mixed, isolatedStumble, long]
) == nil else {
    fail("an isolated five-repeat two-word stumble must not reject a long transcript")
}

if let fixturePath = ProcessInfo.processInfo.environment["LECTERN_BAD_TRANSCRIPT_FIXTURE"] {
    let fixtureText = try String(contentsOfFile: fixturePath, encoding: .utf8)
    let fixtureSegment = TranscriptSegment(
        startSeconds: 0,
        endSeconds: 4_743,
        text: fixtureText
    )
    guard WhisperTranscriptionEngine.transcriptQualityIssue(
        in: [fixtureSegment]
    ) != nil else {
        fail("the supplied shiur transcript fixture must be rejected")
    }
}

if let fixturePath = ProcessInfo.processInfo.environment["LECTERN_GOOD_TRANSCRIPT_FIXTURE"] {
    let fixtureText = try String(contentsOfFile: fixturePath, encoding: .utf8)
    let fixtureSegments = fixtureText
        .split(separator: "\n", omittingEmptySubsequences: false)
        .compactMap { WhisperTranscriptionEngine.parseSegmentLine(String($0)) }
    guard !fixtureSegments.isEmpty else {
        fail("the candidate Whisper output must contain timestamped segments")
    }
    if let issue = WhisperTranscriptionEngine.transcriptQualityIssue(in: fixtureSegments) {
        fail("the candidate Whisper output failed the quality gate: \(issue)")
    }
}

print("PASS: whisper parsing, safe decoding policy, and quality gate")

private extension Array where Element == String {
    func containsPair(_ first: String, _ second: String) -> Bool {
        indices.dropLast().contains { self[$0] == first && self[$0 + 1] == second }
    }
}
