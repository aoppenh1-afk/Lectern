import Foundation
@preconcurrency import AVFAudio

/// Incremental audio decoding and resampling for long-form transcription.
///
/// `WindowReader` is the long-form path. It keeps one model window, one
/// overlap tail, and a 4,096-frame conversion buffer in memory regardless of
/// the source file's duration. `loadMono16k` remains for callers that
/// explicitly need a complete in-memory buffer.
public enum AudioLoader {
    struct Window: Sendable {
        let index: Int
        let startSample: Int
        let discardPrefixSamples: Int
        let samples: [Float]
        let isFinal: Bool
        let completedAudioDurationSeconds: Double
    }

    final class WindowReader: @unchecked Sendable {
        let totalDurationSeconds: Double

        private let reader: any IncrementalSampleReader
        private let sampleRate: Int
        private let windowSamples: Int
        private let overlapSamples: Int

        private var overlapTail: [Float] = []
        private var nextWindowIndex = 0
        private var nextStartSample = 0
        private var emittedWindow = false

        convenience init(
            url: URL,
            sampleRate: Int,
            windowSamples: Int,
            overlapSamples: Int
        ) throws {
            try self.init(
                reader: ConvertedSampleReader(url: url, sampleRate: sampleRate),
                sampleRate: sampleRate,
                windowSamples: windowSamples,
                overlapSamples: overlapSamples
            )
        }

        init(
            reader: any IncrementalSampleReader,
            sampleRate: Int,
            windowSamples: Int,
            overlapSamples: Int
        ) {
            self.reader = reader
            self.sampleRate = sampleRate
            self.windowSamples = max(1, windowSamples)
            self.overlapSamples = min(
                max(0, overlapSamples),
                max(0, self.windowSamples - 1)
            )
            self.totalDurationSeconds = reader.estimatedDurationSeconds
        }

        func next() throws -> Window? {
            let prefix = emittedWindow ? overlapTail : []
            let needed = windowSamples - prefix.count
            let fresh = try reader.read(upTo: needed)

            // Reaching EOF after a full window must not emit an overlap-only
            // duplicate window.
            guard !fresh.isEmpty else { return nil }

            var samples = prefix
            samples.reserveCapacity(windowSamples)
            samples.append(contentsOf: fresh)

            let isFinal = try !reader.hasMoreSamples()
            let startSample = nextStartSample
            let completedSamples = startSample + samples.count
            let window = Window(
                index: nextWindowIndex,
                startSample: startSample,
                discardPrefixSamples: emittedWindow ? prefix.count : 0,
                samples: samples,
                isFinal: isFinal,
                completedAudioDurationSeconds: Double(completedSamples) / Double(sampleRate)
            )

            emittedWindow = true
            nextWindowIndex += 1

            if isFinal {
                overlapTail.removeAll(keepingCapacity: false)
            } else {
                let tailCount = min(overlapSamples, samples.count)
                overlapTail = Array(samples.suffix(tailCount))
                nextStartSample += samples.count - tailCount
            }

            return window
        }
    }

    static func windowReader(
        at url: URL,
        sampleRate: Int = 16_000,
        windowSamples: Int,
        overlapSamples: Int
    ) throws -> WindowReader {
        try WindowReader(
            url: url,
            sampleRate: sampleRate,
            windowSamples: windowSamples,
            overlapSamples: overlapSamples
        )
    }

    public static func loadMono16k(at url: URL) throws -> [Float] {
        let reader = try ConvertedSampleReader(url: url, sampleRate: 16_000)
        var output = [Float]()
        output.reserveCapacity(
            max(0, Int((reader.estimatedDurationSeconds * 16_000).rounded(.up)))
        )

        while true {
            let samples = try reader.read(upTo: 16_384)
            guard !samples.isEmpty else { break }
            output.append(contentsOf: samples)
        }

        if output.isEmpty {
            throw ParakeetError.audioEmpty(url: url)
        }
        return output
    }
}

/// Pulls mono Float32 samples at the requested rate without retaining source
/// audio that the caller has already consumed.
protocol IncrementalSampleReader: AnyObject {
    var estimatedDurationSeconds: Double { get }
    func read(upTo requestedCount: Int) throws -> [Float]
    func hasMoreSamples() throws -> Bool
}

private final class ConvertedSampleReader: IncrementalSampleReader {
    let estimatedDurationSeconds: Double

    private let url: URL
    private let file: AVAudioFile
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer
    private let framesPerRead: AVAudioFrameCount = 4_096

    private var pending: [Float] = []
    private var pendingOffset = 0
    private var reachedEnd = false

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        do {
            self.file = try AVAudioFile(forReading: url)
        } catch {
            throw ParakeetError.audioLoadFailed(url: url, underlying: error)
        }

        self.inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: NSError(
                    domain: "ParakeetTDT.AudioLoader",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to create the 16 kHz mono format."]
                )
            )
        }
        self.outputFormat = outputFormat

        let canReadDirectly = inputFormat.commonFormat == .pcmFormatFloat32
            && inputFormat.channelCount == 1
            && abs(inputFormat.sampleRate - Double(sampleRate)) < 0.5

        if canReadDirectly {
            self.converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw ParakeetError.audioLoadFailed(
                    url: url,
                    underlying: NSError(
                        domain: "ParakeetTDT.AudioLoader",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The source audio cannot be converted to 16 kHz mono."]
                    )
                )
            }
            converter.sampleRateConverterQuality = Int(AVAudioQuality.high.rawValue)
            self.converter = converter
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: framesPerRead
        ) else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: NSError(
                    domain: "ParakeetTDT.AudioLoader",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to allocate an audio conversion buffer."]
                )
            )
        }
        self.inputBuffer = inputBuffer
        self.estimatedDurationSeconds = inputFormat.sampleRate > 0
            ? Double(file.length) / inputFormat.sampleRate
            : 0
    }

    func read(upTo requestedCount: Int) throws -> [Float] {
        guard requestedCount > 0 else { return [] }

        var output = [Float]()
        output.reserveCapacity(requestedCount)

        while output.count < requestedCount {
            if pendingOffset < pending.count {
                let available = pending.count - pendingOffset
                let count = min(available, requestedCount - output.count)
                output.append(contentsOf: pending[pendingOffset..<(pendingOffset + count)])
                pendingOffset += count
                continue
            }

            pending.removeAll(keepingCapacity: true)
            pendingOffset = 0
            try refill()
            if pending.isEmpty { break }
        }

        return output
    }

    func hasMoreSamples() throws -> Bool {
        if pendingOffset < pending.count { return true }
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
        try refill()
        return !pending.isEmpty
    }

    private func refill() throws {
        guard !reachedEnd else { return }

        inputBuffer.frameLength = 0
        do {
            try file.read(into: inputBuffer, frameCount: framesPerRead)
        } catch {
            // AVAudioFile can throw `nilError` after advancing to the exact
            // end of a PCM file. Any partial buffer is still valid; an empty
            // buffer at that position is ordinary EOF.
            guard file.framePosition >= file.length else {
                throw ParakeetError.audioLoadFailed(url: url, underlying: error)
            }
            reachedEnd = true
        }

        guard inputBuffer.frameLength > 0 else {
            reachedEnd = true
            return
        }

        if converter == nil {
            guard let channel = inputBuffer.floatChannelData?[0] else {
                throw ParakeetError.audioLoadFailed(
                    url: url,
                    underlying: NSError(
                        domain: "ParakeetTDT.AudioLoader",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "The source audio has no readable samples."]
                    )
                )
            }
            pending.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(inputBuffer.frameLength)
                )
            )
            return
        }

        let outputCapacity = AVAudioFrameCount(
            ceil(
                Double(inputBuffer.frameLength)
                    * outputFormat.sampleRate
                    / inputFormat.sampleRate
            )
        ) + 64
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: NSError(
                    domain: "ParakeetTDT.AudioLoader",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to allocate a resampling buffer."]
                )
            )
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter?.convert(
            to: outputBuffer,
            error: &conversionError
        ) { [inputBuffer] _, flags in
            if suppliedInput {
                flags.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            flags.pointee = .haveData
            return inputBuffer
        } ?? .error

        if let conversionError {
            throw ParakeetError.audioLoadFailed(url: url, underlying: conversionError)
        }
        if status == .error {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: NSError(
                    domain: "ParakeetTDT.AudioLoader",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]
                )
            )
        }

        if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
            pending.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(outputBuffer.frameLength)
                )
            )
        }
    }
}
