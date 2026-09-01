import CoreML
import Dispatch
import Foundation

/// End-to-end Parakeet TDT transcriber.
///
/// Expects a directory laid out like this (matching the HuggingFace repo):
///
/// ```
/// modelsRoot/
///   encoder.mlpackage/    (or encoder.mlmodelc, if already compiled)
///   decoder.mlpackage/
///   joint.mlpackage/
///   tokenizer.json
/// ```
///
/// The first call compiles each ``.mlpackage`` into a cached ``.mlmodelc``.
/// Subsequent launches find the cached compiled bundle and skip the compile
/// step.
///
/// Three convenience entry points, in order of "how little work do I want
/// to do":
///
/// ```swift
/// // 1. Zero-setup: fetch the default model from HuggingFace + transcribe.
/// let t = try await ParakeetTranscriber.fromHuggingFace()
/// let result = try t.transcribe(audioURL: audio)
///
/// // 2. Specify a HF repo (useful for pinning / private mirrors).
/// let t = try await ParakeetTranscriber.fromHuggingFace(
///     repoId: "mweinbach1/parakeet-tdt-0.6b-v3-coreml",
///     computeUnits: .gpu
/// )
///
/// // 3. Fully local: point at a directory you staged yourself.
/// let t = try ParakeetTranscriber(modelsRoot: localURL)
/// ```
public final class ParakeetTranscriber {

    /// Default HuggingFace repo used by ``fromHuggingFace()`` when no
    /// `repoId` is supplied.
    public static let defaultRepoId = "mweinbach1/parakeet-tdt-0.6b-v3-coreml"
    public let computeUnits: ParakeetComputeUnits
    public let chunkMelFrames: Int    // must match the encoder's traced shape
    public let sampleRate: Int

    private let runner: ModelRunner
    private let tokenizer: Tokenizer
    private let featureExtractor: MelFeatureExtractor
    private let cacheURL: URL
    private let qualityOfService: DispatchQoS.QoSClass

    /// Load the transcriber. Compiles any `.mlpackage`s that aren't already
    /// in the cache. Use `deleteSourceAfterCompile: true` to drop the raw
    /// `.mlpackage` from disk once compilation succeeds (halves peak disk
    /// usage on space-constrained devices).
    ///
    /// ``decoderWorkers`` controls how many parallel decode-loop threads
    /// the pipeline uses. ``nil`` (the default) picks 2 for ANE / GPU / all
    /// and 1 for CPU-only (because on CPU the encoder contends with the
    /// decode workers on the same cores). Higher values can help GPU
    /// further if decode is the bottleneck.
    public init(
        modelsRoot: URL,
        computeUnits: ParakeetComputeUnits = .ane,
        chunkMelFrames: Int = 3000,
        sampleRate: Int = 16_000,
        deleteSourceAfterCompile: Bool = false,
        cacheDirectory: URL? = nil,
        decoderWorkers: Int? = nil,
        qualityOfService: DispatchQoS.QoSClass = .userInitiated
    ) throws {
        self.computeUnits = computeUnits
        self.chunkMelFrames = chunkMelFrames
        self.sampleRate = sampleRate
        self.qualityOfService = qualityOfService

        let cache = ModelCache(
            cacheDirectory: cacheDirectory,
            deleteSourceAfterCompile: deleteSourceAfterCompile
        )
        self.cacheURL = cache.cacheDirectory

        let encoderURL = try ParakeetTranscriber.resolveModel(
            under: modelsRoot, named: "encoder"
        )
        let decoderURL = try ParakeetTranscriber.resolveModel(
            under: modelsRoot, named: "decoder"
        )
        let jointURL = try ParakeetTranscriber.resolveModel(
            under: modelsRoot, named: "joint"
        )
        let tokenizerURL = modelsRoot.appendingPathComponent("tokenizer.json")

        let encCompiled = try cache.compiledURL(for: encoderURL)
        let decCompiled = try cache.compiledURL(for: decoderURL)
        let joiCompiled = try cache.compiledURL(for: jointURL)

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits.mlComputeUnits

        let encoder = try MLModel(contentsOf: encCompiled, configuration: config)
        let decoder = try MLModel(contentsOf: decCompiled, configuration: config)
        let joint = try MLModel(contentsOf: joiCompiled, configuration: config)

        // Decoder stateful sizes are encoded in the spec's hidden / cell
        // input shapes: [num_layers, 1, hidden].
        let (decLayers, decHidden) = ParakeetTranscriber.readDecoderStateShape(
            from: decoder
        )

        // Per-target worker defaults tuned on M-class silicon. Measured
        // scaling on `test_audio.mp3` (see README):
        //   - CPU:  1 worker  (2+ contends with the on-CPU encoder)
        //   - ANE:  2 workers (encoder-bound; more doesn't help)
        //   - GPU:  4 workers (diminishing returns past 4)
        //   - all:  4 workers (assume GPU involved)
        let workerCount: Int = {
            if let override = decoderWorkers { return max(1, override) }
            switch computeUnits {
            case .cpu: return 1
            case .ane: return 2
            case .gpu, .all: return 4
            }
        }()

        self.runner = try ModelRunner(
            encoder: encoder,
            decoder: decoder,
            joint: joint,
            encoderShapes: ModelRunner.EncoderShapes(
                batch: 1, maxTime: chunkMelFrames, numMelBins: 128
            ),
            decoderHiddenLayers: decLayers,
            decoderHiddenSize: decHidden,
            blankTokenId: 8192,
            durations: [0, 1, 2, 3, 4],
            vocabSize: 8193,
            maxSymbolsPerStep: 10,
            numDecoderWorkers: workerCount
        )
        self.tokenizer = try Tokenizer(tokenizerJSONURL: tokenizerURL)
        self.featureExtractor = try MelFeatureExtractor(
            sampleRate: sampleRate,
            hopLength: 160,
            winLength: 400,
            nFFT: 512,
            numMelFilters: 128,
            preemphasis: 0.97
        )
    }

    // MARK: - High-level transcription

    /// Transcribe a file through lazy, overlapping model windows.
    ///
    /// The default 30-second model window keeps one second of left context.
    /// Tokens emitted inside that overlap are discarded before timestamps are
    /// translated into the full recording timeline. The source file itself is
    /// never materialized as one `[Float]`.
    public func transcribe(
        audioURL: URL,
        overlapSeconds: Double = 1,
        beforeChunk: (@Sendable () throws -> Void)? = nil,
        progress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) throws -> Transcription {
        let chunkSamples = chunkMelFrames * featureExtractor.hopLength
        let maximumOverlap = max(
            0,
            Double(chunkSamples - 1) / Double(sampleRate)
        )
        let safeOverlap = min(max(0, overlapSeconds), maximumOverlap)
        let overlapSamples = Int((safeOverlap * Double(sampleRate)).rounded())
        let reader = try AudioLoader.windowReader(
            at: audioURL,
            sampleRate: sampleRate,
            windowSamples: chunkSamples,
            overlapSamples: overlapSamples
        )
        let state = LongFormState()
        let frameStrideSamples = featureExtractor.hopLength * 8
        let totalDuration = reader.totalDurationSeconds

        let start = Date()
        let result = try Pipeline.run(
            nextChunk: { [reader] in
                try beforeChunk?()
                guard let window = try reader.next() else { return nil }
                state.sawAudio = true

                let samples = window.isFinal
                    ? Self.trimmingTrailingRoomTone(from: window.samples)
                    : window.samples
                let startFrame = Int(
                    (Double(window.startSample) / Double(frameStrideSamples)).rounded()
                )
                let discardBeforeFrame = Int(
                    ceil(Double(window.discardPrefixSamples) / Double(frameStrideSamples))
                )

                return Pipeline.ChunkInput(
                    index: window.index,
                    samples: samples,
                    startFrame: startFrame,
                    discardBeforeFrame: discardBeforeFrame,
                    completedAudioDurationSeconds: min(
                        max(totalDuration, 0),
                        window.completedAudioDurationSeconds
                    )
                )
            },
            featureExtractor: featureExtractor,
            runner: runner,
            qualityOfService: qualityOfService,
            onChunk: { chunk in
                progress?(
                    TranscriptionProgress(
                        chunkIndex: chunk.index,
                        tokenIds: chunk.tokenIds,
                        frameIndices: chunk.frameIndices,
                        durations: chunk.durations,
                        completedAudioDurationSeconds: chunk.completedAudioDurationSeconds,
                        totalAudioDurationSeconds: totalDuration
                    )
                )
            }
        )
        let elapsed = Date().timeIntervalSince(start)

        guard state.sawAudio else {
            throw ParakeetError.audioEmpty(url: audioURL)
        }
        return makeTranscription(
            result: result,
            audioDuration: totalDuration,
            inferenceDuration: elapsed
        )
    }

    /// Transcribe an already-loaded mono Float buffer without making full-size
    /// trimmed and pre-sliced copies. The caller still owns the original
    /// buffer, while this method creates model windows only as the pipeline
    /// requests them.
    public func transcribe(samples: [Float]) throws -> Transcription {
        let chunkSamples = chunkMelFrames * featureExtractor.hopLength
        let cursor = InMemoryChunkCursor(
            samples: samples,
            windowSamples: chunkSamples
        )
        let frameStrideSamples = featureExtractor.hopLength * 8

        let start = Date()
        let result = try Pipeline.run(
            nextChunk: {
                guard let window = cursor.next() else { return nil }
                let chunk = window.isFinal
                    ? Self.trimmingTrailingRoomTone(from: window.samples)
                    : window.samples
                return Pipeline.ChunkInput(
                    index: window.index,
                    samples: chunk,
                    startFrame: Int(
                        (Double(window.startSample) / Double(frameStrideSamples)).rounded()
                    ),
                    discardBeforeFrame: 0,
                    completedAudioDurationSeconds:
                        Double(window.startSample + chunk.count) / Double(self.sampleRate)
                )
            },
            featureExtractor: featureExtractor,
            runner: runner,
            qualityOfService: qualityOfService
        )
        let elapsed = Date().timeIntervalSince(start)

        return makeTranscription(
            result: result,
            audioDuration: Double(samples.count) / Double(sampleRate),
            inferenceDuration: elapsed
        )
    }

    private func makeTranscription(
        result: Pipeline.Result,
        audioDuration: Double,
        inferenceDuration: Double
    ) -> Transcription {
        let detokenizeStart = Date()
        let text = cleanedText(
            tokenizer.decode(result.tokens, skipSpecial: true)
        )
        let detokenizeElapsed = Date().timeIntervalSince(detokenizeStart)

        return Transcription(
            text: text,
            tokenIds: result.tokens,
            frameIndices: result.frames,
            durations: result.durations,
            audioDurationSeconds: audioDuration,
            inferenceDurationSeconds: inferenceDuration,
            timing: TranscriptionTiming(
                melExtract: result.melElapsed,
                encoder: result.encoderElapsed,
                decoderLoop: result.decodeElapsed,
                detokenize: detokenizeElapsed
            )
        )
    }

    private static func trimmingTrailingRoomTone(from samples: [Float]) -> [Float] {
        var validCount = samples.count
        let measurementWindow = 4_000
        while validCount > measurementWindow {
            var sum: Float = 0
            for index in (validCount - measurementWindow)..<validCount {
                sum += samples[index] * samples[index]
            }
            let rms = sqrtf(sum / Float(measurementWindow))
            if rms > 0.012 {
                validCount = min(samples.count, validCount + 8_000)
                break
            }
            validCount -= measurementWindow
        }
        return validCount < samples.count
            ? Array(samples.prefix(validCount))
            : samples
    }

    private func cleanedText(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "…", with: ".")
        while text.contains("..") {
            text = text.replacingOccurrences(of: "..", with: ".")
        }

        if let regex = try? NSRegularExpression(pattern: "\\p{Cyrillic}+") {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: ""
            )
        }

        let bannedArtifacts = [
            "Субтитры", "сделал", "DimaTorzoklend", "Amara.org",
            "Subtitles by", "Translated by", "Thank you for watching",
        ]
        for artifact in bannedArtifacts {
            text = text.replacingOccurrences(
                of: artifact,
                with: "",
                options: [.caseInsensitive]
            )
        }

        let cleanupPatterns: [(String, NSRegularExpression.Options, String)] = [
            ("(\\b[A-Z]{2,}\\b\\s*){3,}.*$", [], ""),
            ("(\\b.{1,30}\\b\\s+)\\1{2,}\\s*$", [.caseInsensitive], ""),
            ("(\\b\\w\\s+)\\1{2,}\\s*$", [.caseInsensitive], ""),
            ("([.!?,;:])\\1{2,}", [], "$1"),
        ]
        for (pattern, options, replacement) in cleanupPatterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: options
            ) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: replacement
            )
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text.last?.isPunctuation == false {
            text += "."
        }
        return text
    }

    // MARK: - Helpers

    /// Look for ``<name>.mlmodelc`` (preferred; already compiled) then
    /// ``<name>.mlpackage`` inside ``modelsRoot``.
    private static func resolveModel(
        under root: URL, named: String
    ) throws -> URL {
        let candidates = [
            root.appendingPathComponent("\(named).mlmodelc"),
            root.appendingPathComponent("\(named).mlpackage"),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw ParakeetError.modelNotFound(url: candidates[1])
    }

    /// Sniff the decoder's ``hidden`` input shape to figure out the LSTM's
    /// (num_layers, hidden_size). The spec records it as the symbolic
    /// shape ``[num_layers, 1, hidden]``.
    private static func readDecoderStateShape(
        from model: MLModel
    ) -> (layers: Int, hidden: Int) {
        if let desc = model.modelDescription.inputDescriptionsByName["hidden"],
           let con = desc.multiArrayConstraint
        {
            let shape = con.shape.map(\.intValue)
            if shape.count == 3 {
                return (shape[0], shape[2])
            }
        }
        return (2, 640)  // Parakeet TDT 0.6B defaults.
    }

    /// Cache directory where compiled `.mlmodelc`s live. Exposed so callers
    /// can clear it if they want to force a recompile or free disk.
    public var compiledCacheDirectory: URL { cacheURL }

    // MARK: - HuggingFace convenience

    /// Download the default model from HuggingFace (or `repoId` if
    /// supplied) on first call, then construct a fully-ready
    /// ``ParakeetTranscriber``. Subsequent calls hit the on-disk cache
    /// and skip the download.
    ///
    /// The downloaded `.mlpackage`s live under
    /// ``ModelDownloader.defaultCacheDirectory()``; the compiled
    /// `.mlmodelc`s live under ``ModelCache.defaultCacheDirectory()``.
    /// Both persist across launches.
    public static func fromHuggingFace(
        repoId: String = defaultRepoId,
        branch: String = "main",
        computeUnits: ParakeetComputeUnits = .ane,
        chunkMelFrames: Int = 3000,
        sampleRate: Int = 16_000,
        decoderWorkers: Int? = nil,
        qualityOfService: DispatchQoS.QoSClass = .userInitiated,
        progress: ModelDownloader.ProgressHandler? = nil
    ) async throws -> ParakeetTranscriber {
        let downloader = ModelDownloader()
        let modelsRoot = try await downloader.download(
            repoId: repoId,
            branch: branch,
            progress: progress
        )
        return try ParakeetTranscriber(
            modelsRoot: modelsRoot,
            computeUnits: computeUnits,
            chunkMelFrames: chunkMelFrames,
            sampleRate: sampleRate,
            decoderWorkers: decoderWorkers,
            qualityOfService: qualityOfService
        )
    }
}

private final class LongFormState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSawAudio = false

    var sawAudio: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedSawAudio
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storedSawAudio = newValue
        }
    }
}

private final class InMemoryChunkCursor: @unchecked Sendable {
    struct Window {
        let index: Int
        let startSample: Int
        let samples: [Float]
        let isFinal: Bool
    }

    private let samples: [Float]
    private let windowSamples: Int
    private var index = 0
    private var cursor = 0

    init(samples: [Float], windowSamples: Int) {
        self.samples = samples
        self.windowSamples = max(1, windowSamples)
    }

    func next() -> Window? {
        guard cursor < samples.count else { return nil }
        let start = cursor
        let end = min(start + windowSamples, samples.count)
        let window = Window(
            index: index,
            startSample: start,
            samples: Array(samples[start..<end]),
            isFinal: end == samples.count
        )
        cursor = end
        index += 1
        return window
    }
}
