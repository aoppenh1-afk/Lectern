import Foundation
import os

/// Transcribes with the whisper.cpp CLI for lectures that mix Hebrew and
/// English (shiurim). Parakeet stays the engine for English-only lectures;
/// this engine exists because Parakeet has no Hebrew support.
///
/// Mirrors `TranscriptionEngine`'s contract: callers hand over a file URL and
/// receive transcript segments plus live progress. Binary discovery, model
/// download, audio conversion, and process plumbing stay inside.
final class WhisperTranscriptionEngine: @unchecked Sendable {
    static let modelInfo = "whisper.cpp/large-v3-q5_0"

    /// Full large-v3 Q5 preserves Hebrew source terms much more reliably than
    /// turbo Q8 while adding only about 206 MB to the on-device model.
    static let modelFileName = "ggml-large-v3-q5_0.bin"
    static let modelDownloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"
    )!

    /// A transcript-style spelling guide, not an instruction. With
    /// `--carry-initial-prompt` and a 128-token context budget whisper.cpp
    /// retains the last 127 prompt tokens and has no remaining budget for
    /// decoded-history feedback. The text is intentionally longer than that
    /// retained window.
    private static let bilingualSpellingPrompt = """
        The rabbi teaches a shiur in English with Hebrew and Aramaic terms. \
        Gemara גמ׳. Mishnah משנה. Rashi רש״י. Tosafos תוס׳. Ramban רמב״ן. \
        Rambam רמב״ם. Rosh רא״ש. Rashba רשב״א. halacha הלכה. din דין. \
        safek ספק. derabbanan דרבנן. lekula לקולא. meikel מיקל. Rishonim \
        ראשונים. Acharonim אחרונים. kal vachomer ק״ו. dibur hamaschil ד״ה. \
        beis din ב״ד. nafka mina נ״מ. hamotzi mechaveiro alav haraaya המע״ה. \
        migo מיגו. shevuah שבועה. chazaka חזקה. eidim עדים. muchzak מוחזק. \
        yachloku יחלוקו. mamon ממון. tefisa תפיסה. kinyan קנין. taana טענה. \
        The גמ׳ asks on תוס׳, and רש״י says the מוחזק keeps the ממון.
        """

    /// Optional user override for a whisper-cli outside the Homebrew paths.
    static let cliPathDefaultsKey = "transcription.whisperCLIPath"

    private static let signpostLog = OSLog(
        subsystem: "com.lectern",
        category: .pointsOfInterest
    )

    private let queue = DispatchQueue(
        label: "com.lectern.transcription.whisper",
        qos: .utility
    )

    // MARK: - Binary discovery

    /// First executable whisper-cli among the user override and Homebrew
    /// install locations, or nil when whisper.cpp is not installed.
    static func locateCLI() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        if let custom = UserDefaults.standard.string(forKey: cliPathDefaultsKey),
           !custom.isEmpty {
            candidates.insert(custom, at: 0)
        }
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isCLIInstalled: Bool { locateCLI() != nil }

    // MARK: - Model cache

    static var modelURL: URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches
            .appendingPathComponent("com.lectern/whisper-models", isDirectory: true)
            .appendingPathComponent(modelFileName)
    }

    var isModelCached: Bool {
        FileManager.default.fileExists(atPath: Self.modelURL.path)
    }

    /// Downloads the ggml model (~1.1 GB) to the cache. Streams to a
    /// temporary file so an interrupted download never poses as complete.
    func downloadModel(
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws {
        guard !isModelCached else { return }
        let destination = Self.modelURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        let temporary: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: Self.modelDownloadURL) { url, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let url else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    continuation.resume(throwing: Self.error("Model download failed (HTTP \(code))."))
                    return
                }
                // The completion handler deletes the file when it returns, so
                // claim it before resuming.
                let holding = url.deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString + ".bin")
                do {
                    try FileManager.default.moveItem(at: url, to: holding)
                    continuation.resume(returning: holding)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                guard let progress else { return }
                let fraction = taskProgress.fractionCompleted
                Task { @MainActor in
                    progress(fraction)
                }
            }
            task.resume()
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try FileManager.default.copyItem(at: temporary, to: destination)
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    // MARK: - Transcription

    /// Runs whisper-cli over the audio file and parses segments from its
    /// stdout as they stream in. `durationSeconds` drives the progress
    /// fraction because whisper prints segments, not percentages.
    func transcribe(
        fileURL: URL,
        durationSeconds: Double,
        progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard let cli = Self.locateCLI() else { throw Self.cliMissing }
        guard isModelCached else {
            throw Self.error("The Whisper model has not been downloaded yet.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let audio = try preparedAudio(from: fileURL)
                    defer {
                        if audio.isTemporary {
                            try? FileManager.default.removeItem(at: audio.url)
                        }
                    }
                    let segments = try run(
                        cli: cli,
                        audioURL: audio.url,
                        durationSeconds: durationSeconds,
                        progress: progress
                    )
                    continuation.resume(returning: segments)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(
        cli: URL,
        audioURL: URL,
        durationSeconds: Double,
        progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?
    ) throws -> [TranscriptSegment] {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Whisper transcription",
                    signpostID: signpostID)
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "Whisper transcription",
                        signpostID: signpostID)
        }

        let process = Process()
        process.executableURL = cli
        process.arguments = Self.cliArguments(
            modelURL: Self.modelURL,
            audioURL: audioURL,
            threadCount: max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = SegmentCollector(
            durationSeconds: durationSeconds,
            progress: progress
        )
        stdout.fileHandleForReading.readabilityHandler = { handle in
            collector.ingest(handle.availableData)
        }

        try process.run()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        collector.ingest(stdout.fileHandleForReading.readDataToEndOfFile())
        collector.finishLine()

        guard process.terminationStatus == 0 else {
            let log = String(decoding: stderrData, as: UTF8.self)
            let tail = log.split(separator: "\n").suffix(4).joined(separator: " ")
            throw Self.error("whisper-cli exited with status \(process.terminationStatus). \(tail)")
        }
        let segments = collector.segments
        if let issue = Self.transcriptQualityIssue(in: segments) {
            throw Self.error(
                "Whisper produced an unusable repeated transcript (\(issue)). "
                    + "Lectern kept the last good checkpoint; retranscribe to try again."
            )
        }
        return segments
    }

    /// Stable CLI policy for long-form mixed-language lectures. A carried
    /// spelling guide occupies the whole bounded prompt-history budget, so
    /// Hebrew terms keep their script without carrying decoded text forward.
    static func cliArguments(
        modelURL: URL,
        audioURL: URL,
        threadCount: Int
    ) -> [String] {
        [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-l", "auto",
            "-t", String(max(1, threadCount)),
            "-mc", "128",
            "--carry-initial-prompt",
            "--prompt", bilingualSpellingPrompt,
            "-sns",
        ]
    }

    /// Rejects decoder collapse before a transcript can be marked ready. The
    /// limits are deliberately above ordinary spoken repetition: at least 20
    /// repeated words, or more than 80 output characters per decoded second in
    /// a long segment. This still catches decoder collapse without rejecting an
    /// otherwise complete lecture for one brief verbal or decoding stumble.
    static func transcriptQualityIssue(
        in segments: [TranscriptSegment]
    ) -> String? {
        for segment in segments {
            let duration = max(segment.endSeconds - segment.startSeconds, 0.1)
            if segment.text.count >= 500,
               Double(segment.text.count) / duration > 80 {
                return "impossible text density near \(formatTimestamp(segment.startSeconds))"
            }
        }

        let words = segments
            .map(\.text)
            .joined(separator: " ")
            .split { character in
                !character.isLetter && !character.isNumber && character != "'"
            }
            .map { $0.lowercased() }

        guard words.count >= 10 else { return nil }
        let maximumPhraseLength = min(12, words.count / 5)

        for phraseLength in 1...maximumPhraseLength {
            let requiredRepeats = max(5, Int(ceil(20.0 / Double(phraseLength))))
            var start = 0

            while start + phraseLength * requiredRepeats <= words.count {
                var repeatCount = 1
                while start + phraseLength * (repeatCount + 1) <= words.count {
                    let firstStart = start
                    let nextStart = start + phraseLength * repeatCount
                    var matches = true
                    for offset in 0..<phraseLength where
                        words[firstStart + offset] != words[nextStart + offset] {
                        matches = false
                        break
                    }
                    guard matches else { break }
                    repeatCount += 1
                }

                if repeatCount >= requiredRepeats {
                    let phrase = words[start..<(start + phraseLength)]
                        .joined(separator: " ")
                    return "\(repeatCount)x phrase '\(phrase)'"
                }
                start += 1
            }
        }
        return nil
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// whisper-cli reads wav/mp3/flac/ogg. Anything else (m4a imports) is
    /// converted to 16 kHz mono WAV with the system's afconvert.
    private func preparedAudio(from source: URL) throws -> (url: URL, isTemporary: Bool) {
        let supported: Set<String> = ["wav", "mp3", "flac", "ogg"]
        if supported.contains(source.pathExtension.lowercased()) {
            return (source, false)
        }

        let converted = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
            source.path, converted.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Self.error("Couldn't convert the audio for Whisper (afconvert status \(process.terminationStatus)).")
        }
        return (converted, true)
    }

    // MARK: - Output parsing

    /// Parses one whisper-cli stdout line of the form
    /// `[00:01:02.480 --> 00:01:07.200]   spoken text`.
    static func parseSegmentLine(_ line: String) -> TranscriptSegment? {
        guard let match = line.wholeMatch(of: segmentPattern) else { return nil }
        let rawText = String(match.output.9).trimmingCharacters(in: .whitespaces)
        let text = collapseExactModelEcho(rawText)
        guard !text.isEmpty else { return nil }

        func seconds(_ h: Substring, _ m: Substring, _ s: Substring, _ ms: Substring) -> Double {
            (Double(h) ?? 0) * 3600 + (Double(m) ?? 0) * 60
                + (Double(s) ?? 0) + (Double(ms) ?? 0) / 1000
        }
        return TranscriptSegment(
            startSeconds: seconds(match.output.1, match.output.2, match.output.3, match.output.4),
            endSeconds: seconds(match.output.5, match.output.6, match.output.7, match.output.8),
            text: text
        )
    }

    /// Full large-v3 can occasionally emit a prompted sentence twice in one
    /// segment. Collapse only exact, substantial half-for-half echoes.
    private static func collapseExactModelEcho(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 8, words.count.isMultiple(of: 2) else { return text }
        let midpoint = words.count / 2
        guard words[..<midpoint].elementsEqual(words[midpoint...]) else { return text }
        return words[..<midpoint].joined(separator: " ")
    }

    // Regex is immutable after creation; the annotation only silences the
    // conservative Sendable diagnostic.
    nonisolated(unsafe) private static let segmentPattern =
        /\[(\d{2,}):(\d{2}):(\d{2})\.(\d{3}) --> (\d{2,}):(\d{2}):(\d{2})\.(\d{3})\]\s*(.*)/

    // MARK: - Errors

    static let cliMissing = error(
        "whisper-cli was not found. Install it with: brew install whisper-cpp"
    )

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "com.lectern.transcription.whisper",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// Accumulates whisper-cli stdout across chunk boundaries, emitting parsed
/// segments and a duration-based progress fraction.
private final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let durationSeconds: Double
    private let progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?
    private var buffer = ""
    private(set) var segments: [TranscriptSegment] = []

    init(
        durationSeconds: Double,
        progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?
    ) {
        self.durationSeconds = durationSeconds
        self.progress = progress
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer += String(decoding: data, as: UTF8.self)

        var emitted = false
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let segment = WhisperTranscriptionEngine.parseSegmentLine(line) {
                segments.append(segment)
                emitted = true
            }
        }
        let snapshot = segments
        lock.unlock()

        if emitted { report(snapshot) }
    }

    /// Flushes a trailing line that arrived without a final newline.
    func finishLine() {
        lock.lock()
        let line = buffer
        buffer = ""
        if let segment = WhisperTranscriptionEngine.parseSegmentLine(line) {
            segments.append(segment)
        }
        let snapshot = segments
        lock.unlock()
        report(snapshot)
    }

    private func report(_ snapshot: [TranscriptSegment]) {
        guard let progress else { return }
        // Keep streaming checks bounded. The engine validates the complete
        // transcript once more before returning it.
        let recentSegments = Array(snapshot.suffix(12))
        guard WhisperTranscriptionEngine.transcriptQualityIssue(in: recentSegments) == nil else {
            return
        }
        let fraction: Double
        if durationSeconds > 0, let last = snapshot.last {
            fraction = min(last.endSeconds / durationSeconds, 1)
        } else {
            fraction = 0
        }
        Task { @MainActor in
            progress(snapshot, fraction)
        }
    }
}
