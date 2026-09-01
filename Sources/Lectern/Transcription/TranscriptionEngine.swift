import Foundation
import os
import ParakeetTDT

enum TranscriptionPerformancePolicy: String, CaseIterable, Identifiable {
    static let defaultsKey = "transcription.performancePolicy"

    case cool
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cool: return "Cool"
        case .fast: return "Fast"
        }
    }

    var caption: String {
        switch self {
        case .cool:
            return "Neural Engine with one decoder worker. Lower peak power and memory."
        case .fast:
            return "GPU with four decoder workers. Finishes sooner but uses more power at once."
        }
    }

    var computeUnits: ParakeetComputeUnits {
        switch self {
        case .cool: return .ane
        case .fast: return .gpu
        }
    }

    var decoderWorkers: Int {
        switch self {
        case .cool: return 1
        case .fast: return 4
        }
    }

    static var current: TranscriptionPerformancePolicy {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .cool
        }
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey)
        return TranscriptionPerformancePolicy(rawValue: rawValue ?? "") ?? .cool
    }
}

/// Owns model loading, thermal pacing, long-form progress, and model lifetime.
/// Callers provide a file URL and receive transcript segments. They do not
/// need to know about model windows or compute scheduling.
final class TranscriptionEngine: @unchecked Sendable {
    static let repoId = "mweinbach1/parakeet-tdt-0.6b-v3-coreml"

    /// Parakeet TDT stride: hopLength 160 x encoder subsampling 8.
    private static let secondsPerFrame = 0.08
    private static let signpostLog = OSLog(
        subsystem: "com.lectern",
        category: .pointsOfInterest
    )

    private let queue = DispatchQueue(
        label: "com.lectern.transcription",
        qos: .utility
    )
    private let thermalGate = TranscriptionThermalGate()

    private var transcriber: ParakeetTranscriber?
    private var tokenizer: Tokenizer?
    private var loadedPolicy: TranscriptionPerformancePolicy?

    /// Directory of the cached HuggingFace checkout.
    private var modelsRoot: URL {
        ModelDownloader.defaultCacheDirectory()
            .appendingPathComponent(Self.repoId.replacingOccurrences(of: "/", with: "_"))
    }

    /// True when the model weights are already on disk.
    var isModelCached: Bool {
        FileManager.default.fileExists(
            atPath: modelsRoot.appendingPathComponent("tokenizer.json").path
        )
    }

    func transcribe(
        fileURL: URL,
        progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        let policy = TranscriptionPerformancePolicy.current
        try await ensureLoaded(policy: policy)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let transcriber, let tokenizer else {
                    continuation.resume(throwing: Self.engineUnavailable)
                    return
                }

                let progressAccumulator = TranscriptionProgressAccumulator(
                    tokenizer: tokenizer,
                    progress: progress
                )
                let signpostID = OSSignpostID(log: Self.signpostLog)
                os_signpost(
                    .begin,
                    log: Self.signpostLog,
                    name: "Lecture transcription",
                    signpostID: signpostID,
                    "policy=%{public}s",
                    policy.rawValue
                )

                do {
                    let result = try transcriber.transcribe(
                        audioURL: fileURL,
                        overlapSeconds: 1,
                        beforeChunk: { [thermalGate] in
                            thermalGate.waitUntilSafe()
                        },
                        progress: { update in
                            os_signpost(
                                .event,
                                log: Self.signpostLog,
                                name: "Transcription chunk complete",
                                "chunk=%{public}d progress=%{public}.3f",
                                update.chunkIndex,
                                update.fractionCompleted
                            )
                            progressAccumulator.receive(update)
                        }
                    )
                    let segments = Self.buildSegments(
                        tokenIDs: result.tokenIds,
                        frameIndices: result.frameIndices,
                        durations: result.durations,
                        tokenizer: tokenizer
                    )
                    os_signpost(
                        .end,
                        log: Self.signpostLog,
                        name: "Lecture transcription",
                        signpostID: signpostID
                    )
                    continuation.resume(returning: segments)
                } catch {
                    os_signpost(
                        .end,
                        log: Self.signpostLog,
                        name: "Lecture transcription",
                        signpostID: signpostID,
                        "failed"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Releases Core ML models after the job queue drains. Core ML's compiled
    /// specialization remains cached on disk, so a later load avoids the
    /// first-run compile path.
    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                transcriber = nil
                tokenizer = nil
                loadedPolicy = nil
                continuation.resume()
            }
        }
    }

    private func ensureLoaded(
        policy: TranscriptionPerformancePolicy
    ) async throws {
        if transcriber != nil, tokenizer != nil, loadedPolicy == policy {
            return
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    transcriber = nil
                    tokenizer = nil
                    loadedPolicy = nil

                    let signpostID = OSSignpostID(log: Self.signpostLog)
                    os_signpost(
                        .begin,
                        log: Self.signpostLog,
                        name: "Parakeet model load",
                        signpostID: signpostID,
                        "policy=%{public}s",
                        policy.rawValue
                    )
                    let root = modelsRoot
                    transcriber = try ParakeetTranscriber(
                        modelsRoot: root,
                        computeUnits: policy.computeUnits,
                        deleteSourceAfterCompile: true,
                        decoderWorkers: policy.decoderWorkers,
                        qualityOfService: .utility
                    )
                    tokenizer = try Tokenizer(
                        tokenizerJSONURL: root.appendingPathComponent("tokenizer.json")
                    )
                    loadedPolicy = policy
                    os_signpost(
                        .end,
                        log: Self.signpostLog,
                        name: "Parakeet model load",
                        signpostID: signpostID
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let engineUnavailable = NSError(
        domain: "com.lectern.transcription",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Transcription engine is not loaded."]
    )

    static func buildSegments(
        from transcription: Transcription,
        tokenizer: Tokenizer
    ) -> [TranscriptSegment] {
        buildSegments(
            tokenIDs: transcription.tokenIds,
            frameIndices: transcription.frameIndices,
            durations: transcription.durations,
            tokenizer: tokenizer
        )
    }

    fileprivate static func buildSegments(
        tokenIDs: [Int],
        frameIndices: [Int],
        durations: [Int],
        tokenizer: Tokenizer
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentText = ""
        var currentStartFrame: Int?

        let count = min(tokenIDs.count, frameIndices.count)

        func close(at endFrame: Int) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let startFrame = currentStartFrame, !text.isEmpty {
                segments.append(
                    TranscriptSegment(
                        startSeconds: Double(startFrame) * secondsPerFrame,
                        endSeconds: Double(max(startFrame, endFrame)) * secondsPerFrame,
                        text: text
                    )
                )
            }
            currentText = ""
            currentStartFrame = nil
        }

        for index in 0..<count {
            let id = tokenIDs[index]
            guard id >= 0, id < tokenizer.idToPiece.count,
                  !tokenizer.specialIDs.contains(id) else {
                continue
            }

            if currentStartFrame == nil {
                currentStartFrame = frameIndices[index]
            }
            for character in tokenizer.idToPiece[id] {
                if character == Tokenizer.metaSpace {
                    if !currentText.isEmpty { currentText.append(" ") }
                } else {
                    currentText.append(character)
                }
            }

            if currentText.count > 400 {
                close(at: frameIndices[index])
            } else if let last = currentText.last, ".!?".contains(last) {
                let duration = index < durations.count ? durations[index] : 0
                close(at: frameIndices[index] + duration)
            }
        }

        close(at: frameIndices.prefix(count).last.map { $0 + 8 } ?? 0)
        return mergeFragmented(segments)
    }

    private static func mergeFragmented(
        _ input: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !input.isEmpty else { return input }

        var merged = [input[0]]
        for segment in input.dropFirst() {
            let lastIndex = merged.count - 1
            let eitherSideShort = segment.text.count < 25
                || merged[lastIndex].text.count < 25
            if eitherSideShort,
               segment.startSeconds - merged[lastIndex].endSeconds < 1 {
                merged[lastIndex].text += " " + segment.text
                merged[lastIndex].endSeconds = segment.endSeconds
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}

private final class TranscriptionProgressAccumulator: @unchecked Sendable {
    private let tokenizer: Tokenizer
    private let progress:
        (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?
    private let lock = NSLock()

    private var tokenIDs: [Int] = []
    private var frameIndices: [Int] = []
    private var durations: [Int] = []

    init(
        tokenizer: Tokenizer,
        progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?
    ) {
        self.tokenizer = tokenizer
        self.progress = progress
    }

    func receive(_ update: TranscriptionProgress) {
        lock.lock()
        tokenIDs.append(contentsOf: update.tokenIds)
        frameIndices.append(contentsOf: update.frameIndices)
        durations.append(contentsOf: update.durations)
        let segments = TranscriptionEngine.buildSegments(
            tokenIDs: tokenIDs,
            frameIndices: frameIndices,
            durations: durations,
            tokenizer: tokenizer
        )
        let fraction = update.fractionCompleted
        lock.unlock()

        guard let progress else { return }
        Task { @MainActor in
            progress(segments, fraction)
        }
    }
}

private final class TranscriptionThermalGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func waitUntilSafe() {
        condition.lock()
        while Self.shouldPause(ProcessInfo.processInfo.thermalState) {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 5))
        }
        condition.unlock()
    }

    private static func shouldPause(
        _ state: ProcessInfo.ThermalState
    ) -> Bool {
        state == .serious || state == .critical
    }
}
