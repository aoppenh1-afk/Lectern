import CoreML
import Dispatch
import Foundation
import os

private let pipelineLog = OSLog(
    subsystem: "com.parakeet-tdt",
    category: .pointsOfInterest
)

/// Pipelined long-form transcription fed by a lazy chunk provider.
///
/// Raw audio is consumed and released a window at a time. The mel and encoder
/// queues remain capacity-bounded so a fast producer cannot accumulate Core ML
/// inputs or IOSurface-backed outputs for a long recording.
enum Pipeline {
    struct ChunkInput: Sendable {
        let index: Int
        let samples: [Float]
        let startFrame: Int
        let discardBeforeFrame: Int
        let completedAudioDurationSeconds: Double
    }

    struct ChunkOutput: Sendable {
        let index: Int
        let tokenIds: [Int]
        let frameIndices: [Int]
        let durations: [Int]
        let completedAudioDurationSeconds: Double
    }

    struct Result {
        var tokens: [Int]
        var frames: [Int]
        var durations: [Int]
        var melElapsed: Double
        var encoderElapsed: Double
        var decodeElapsed: Double
    }

    static func run(
        nextChunk: @escaping @Sendable () throws -> ChunkInput?,
        featureExtractor: MelFeatureExtractor,
        runner: ModelRunner,
        qualityOfService: DispatchQoS.QoSClass = .userInitiated,
        onChunk: (@Sendable (ChunkOutput) -> Void)? = nil
    ) throws -> Result {
        let queueQoS = DispatchQoS(
            qosClass: qualityOfService,
            relativePriority: 0
        )
        let melQueue = BlockingQueue<MelItem>(capacity: 1)
        let encQueue = BlockingQueue<EncoderItem>(
            capacity: max(1, min(2, runner.decoderWorkers.count))
        )
        let globalError = ErrorSlot()

        // Stage 1: lazy file read plus CPU mel extraction.
        let melQ = DispatchQueue(label: "parakeet.mel", qos: queueQoS)
        let melTotal = AtomicDouble()
        melQ.async {
            while !globalError.hasError {
                do {
                    guard let chunk = try nextChunk() else { break }
                    let signpostID = OSSignpostID(log: pipelineLog)
                    os_signpost(
                        .begin,
                        log: pipelineLog,
                        name: "Mel extraction",
                        signpostID: signpostID,
                        "chunk=%{public}d",
                        chunk.index
                    )
                    let t0 = Date()
                    let features = featureExtractor.extract(from: chunk.samples)
                    melTotal.add(Date().timeIntervalSince(t0))
                    os_signpost(
                        .end,
                        log: pipelineLog,
                        name: "Mel extraction",
                        signpostID: signpostID
                    )
                    melQueue.put(MelItem(input: chunk, features: features))
                } catch {
                    globalError.set(error)
                    break
                }
            }
            melQueue.close()
        }

        // Stage 2: one Core ML encoder prediction at a time.
        let encQ = DispatchQueue(label: "parakeet.encoder", qos: queueQoS)
        let encTotal = AtomicDouble()
        encQ.async {
            while let mel = melQueue.take() {
                if globalError.hasError { break }
                do {
                    let signpostID = OSSignpostID(log: pipelineLog)
                    os_signpost(
                        .begin,
                        log: pipelineLog,
                        name: "Encoder prediction",
                        signpostID: signpostID,
                        "chunk=%{public}d",
                        mel.input.index
                    )
                    let t0 = Date()
                    let (hidden, mask) = try runner.runEncoder(
                        features: mel.features.mel,
                        mask: mel.features.attentionMask
                    )
                    encTotal.add(Date().timeIntervalSince(t0))
                    os_signpost(
                        .end,
                        log: pipelineLog,
                        name: "Encoder prediction",
                        signpostID: signpostID
                    )
                    encQueue.put(
                        EncoderItem(input: mel.input, hidden: hidden, mask: mask)
                    )
                } catch {
                    globalError.set(error)
                    break
                }
            }
            encQueue.close()
        }

        // Stage 3: bounded CPU decode worker pool.
        let decodeQ = DispatchQueue(
            label: "parakeet.decode",
            qos: queueQoS,
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let decodeTotal = AtomicDouble()
        let results = ChunkResultAccumulator()

        while let item = encQueue.take() {
            if globalError.hasError { break }
            guard let worker = runner.acquireWorker() else { break }

            group.enter()
            decodeQ.async {
                defer {
                    runner.releaseWorker(worker)
                    group.leave()
                }
                do {
                    let signpostID = OSSignpostID(log: pipelineLog)
                    os_signpost(
                        .begin,
                        log: pipelineLog,
                        name: "TDT decode",
                        signpostID: signpostID,
                        "chunk=%{public}d",
                        item.input.index
                    )
                    let decoded = try autoreleasepool {
                        try GreedyTDTDecoder.decode(
                            encoderHidden: item.hidden,
                            encoderMask: item.mask,
                            worker: worker,
                            blankTokenId: runner.blankTokenId,
                            durations: runner.durations,
                            maxSymbolsPerStep: runner.maxSymbolsPerStep
                        )
                    }
                    decodeTotal.add(decoded.elapsedSeconds)
                    os_signpost(
                        .end,
                        log: pipelineLog,
                        name: "TDT decode",
                        signpostID: signpostID
                    )

                    let chunk = normalizedChunk(
                        index: item.input.index,
                        tokenIds: decoded.tokenIds,
                        frameIndices: decoded.frameIndices,
                        durations: decoded.durations,
                        startFrame: item.input.startFrame,
                        discardBeforeFrame: item.input.discardBeforeFrame,
                        completedAudioDurationSeconds: item.input.completedAudioDurationSeconds
                    )
                    results.set(index: item.input.index, chunk: chunk, onReady: onChunk)
                } catch {
                    globalError.set(error)
                }
            }
        }

        group.wait()
        melQueue.close()
        encQueue.close()

        if let error = globalError.error {
            throw error
        }

        var tokens = [Int]()
        var frames = [Int]()
        var durations = [Int]()
        for chunk in results.ordered() {
            tokens.append(contentsOf: chunk.tokenIds)
            frames.append(contentsOf: chunk.frameIndices)
            durations.append(contentsOf: chunk.durations)
        }

        return Result(
            tokens: tokens,
            frames: frames,
            durations: durations,
            melElapsed: melTotal.value,
            encoderElapsed: encTotal.value,
            decodeElapsed: decodeTotal.value
        )
    }

    /// Removes tokens emitted from the left-context overlap and translates the
    /// retained timestamps into the full recording's frame space.
    static func normalizedChunk(
        index: Int,
        tokenIds: [Int],
        frameIndices: [Int],
        durations: [Int],
        startFrame: Int,
        discardBeforeFrame: Int,
        completedAudioDurationSeconds: Double
    ) -> ChunkOutput {
        let count = min(tokenIds.count, frameIndices.count, durations.count)
        var keptTokens = [Int]()
        var keptFrames = [Int]()
        var keptDurations = [Int]()
        keptTokens.reserveCapacity(count)
        keptFrames.reserveCapacity(count)
        keptDurations.reserveCapacity(count)

        for position in 0..<count {
            guard frameIndices[position] >= discardBeforeFrame else { continue }
            keptTokens.append(tokenIds[position])
            keptFrames.append(frameIndices[position] + startFrame)
            keptDurations.append(durations[position])
        }

        return ChunkOutput(
            index: index,
            tokenIds: keptTokens,
            frameIndices: keptFrames,
            durations: keptDurations,
            completedAudioDurationSeconds: completedAudioDurationSeconds
        )
    }
}

// MARK: - Helpers

private struct MelItem {
    let input: Pipeline.ChunkInput
    let features: MelFeatureExtractor.Features
}

private struct EncoderItem {
    let input: Pipeline.ChunkInput
    let hidden: MLMultiArray
    let mask: MLMultiArray
}

/// Capacity-bounded MPSC blocking queue.
private final class BlockingQueue<T>: @unchecked Sendable {
    private var buffer: [T] = []
    private var closed = false
    private let lock = NSLock()
    private let freeSlots: DispatchSemaphore
    private let itemsAvailable = DispatchSemaphore(value: 0)

    init(capacity: Int) {
        freeSlots = DispatchSemaphore(value: max(1, capacity))
    }

    func put(_ value: T) {
        freeSlots.wait()
        lock.lock()
        if closed {
            lock.unlock()
            freeSlots.signal()
            return
        }
        buffer.append(value)
        lock.unlock()
        itemsAvailable.signal()
    }

    func take() -> T? {
        itemsAvailable.wait()
        lock.lock()
        if buffer.isEmpty {
            lock.unlock()
            itemsAvailable.signal()
            return nil
        }
        let value = buffer.removeFirst()
        lock.unlock()
        freeSlots.signal()
        return value
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed {
            itemsAvailable.signal()
            freeSlots.signal()
        }
    }
}

/// Collects out-of-order decoder results and emits only the contiguous,
/// completed prefix to progress observers.
private final class ChunkResultAccumulator: @unchecked Sendable {
    private var map: [Int: Pipeline.ChunkOutput] = [:]
    private var nextProgressIndex = 0
    private let lock = NSLock()

    func set(
        index: Int,
        chunk: Pipeline.ChunkOutput,
        onReady: (@Sendable (Pipeline.ChunkOutput) -> Void)?
    ) {
        lock.lock()
        map[index] = chunk
        while let ready = map[nextProgressIndex] {
            onReady?(ready)
            nextProgressIndex += 1
        }
        lock.unlock()
    }

    func ordered() -> [Pipeline.ChunkOutput] {
        lock.lock(); defer { lock.unlock() }
        return map.keys.sorted().compactMap { map[$0] }
    }
}

private final class ErrorSlot: @unchecked Sendable {
    private var storedError: Error?
    private let lock = NSLock()

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return storedError
    }

    var hasError: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedError != nil
    }

    func set(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if storedError == nil { storedError = error }
    }
}

private final class AtomicDouble: @unchecked Sendable {
    private var storedValue: Double = 0
    private let lock = NSLock()

    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func add(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        storedValue += value
    }
}
