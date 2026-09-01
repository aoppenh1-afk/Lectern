@preconcurrency import AVFAudio
import Foundation
import XCTest
@testable import ParakeetTDT

final class LongFormAudioTests: XCTestCase {
    private let sampleRate = 16_000
    private let windowSamples = 30 * 16_000
    private let overlapSamples = 16_000

    func testEightyMinuteRecordingIsReadWithBoundedWindows() throws {
        let durationSeconds = 80 * 60
        let source = SyntheticSampleReader(
            sampleCount: durationSeconds * sampleRate,
            sampleRate: sampleRate,
            maximumReadSize: windowSamples
        )
        let reader = AudioLoader.WindowReader(
            reader: source,
            sampleRate: sampleRate,
            windowSamples: windowSamples,
            overlapSamples: overlapSamples
        )

        var windowCount = 0
        var maximumWindowSize = 0
        var lastWindow: AudioLoader.Window?

        while let window = try reader.next() {
            windowCount += 1
            maximumWindowSize = max(maximumWindowSize, window.samples.count)
            lastWindow = window

            XCTAssertLessThanOrEqual(window.samples.count, windowSamples)
            XCTAssertEqual(
                window.discardPrefixSamples,
                window.index == 0 ? 0 : overlapSamples
            )
        }

        let finalWindow = try XCTUnwrap(lastWindow)
        XCTAssertEqual(windowCount, 166)
        XCTAssertEqual(maximumWindowSize, windowSamples)
        XCTAssertEqual(finalWindow.index, 165)
        XCTAssertEqual(finalWindow.startSample, 4_785 * sampleRate)
        XCTAssertEqual(finalWindow.samples.count, 15 * sampleRate)
        XCTAssertEqual(finalWindow.completedAudioDurationSeconds, 4_800, accuracy: 0.001)
        XCTAssertTrue(finalWindow.isFinal)
        XCTAssertEqual(source.maximumRequestedCount, windowSamples)
    }

    func testExactWindowLengthDoesNotCreateOverlapOnlyWindow() throws {
        let reader = AudioLoader.WindowReader(
            reader: SyntheticSampleReader(
                sampleCount: windowSamples,
                sampleRate: sampleRate,
                maximumReadSize: windowSamples
            ),
            sampleRate: sampleRate,
            windowSamples: windowSamples,
            overlapSamples: overlapSamples
        )

        let window = try XCTUnwrap(reader.next())
        XCTAssertEqual(window.index, 0)
        XCTAssertEqual(window.samples.count, windowSamples)
        XCTAssertTrue(window.isFinal)
        XCTAssertNil(try reader.next())
    }

    func testPCMFileIsDecodedIncrementallyAcrossWindowBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-window-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilentPCMFile(
            at: url,
            sampleCount: 31 * sampleRate,
            sampleRate: sampleRate,
            channels: 1
        )

        let reader = try AudioLoader.windowReader(
            at: url,
            sampleRate: sampleRate,
            windowSamples: windowSamples,
            overlapSamples: overlapSamples
        )
        let first = try XCTUnwrap(reader.next())
        let second = try XCTUnwrap(reader.next())

        XCTAssertEqual(first.samples.count, windowSamples)
        XCTAssertFalse(first.isFinal)
        XCTAssertEqual(second.startSample, 29 * sampleRate)
        XCTAssertEqual(second.discardPrefixSamples, overlapSamples)
        XCTAssertEqual(second.samples.count, 2 * sampleRate)
        XCTAssertTrue(second.isFinal)
        XCTAssertNil(try reader.next())
    }

    func testStereoFileIsDownmixedAndResampledIncrementally() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-resample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilentPCMFile(
            at: url,
            sampleCount: 44_100,
            sampleRate: 44_100,
            channels: 2
        )

        let samples = try AudioLoader.loadMono16k(at: url)
        XCTAssertLessThanOrEqual(abs(samples.count - 16_000), 128)
    }

    func testOverlapTokensAreRemovedAndFramesBecomeAbsolute() {
        let output = Pipeline.normalizedChunk(
            index: 1,
            tokenIds: [10, 11, 12],
            frameIndices: [2, 12, 13],
            durations: [1, 2, 3],
            startFrame: 363,
            discardBeforeFrame: 13,
            completedAudioDurationSeconds: 59
        )

        XCTAssertEqual(output.tokenIds, [12])
        XCTAssertEqual(output.frameIndices, [376])
        XCTAssertEqual(output.durations, [3])
        XCTAssertEqual(output.completedAudioDurationSeconds, 59)
    }

    private func writeSilentPCMFile(
        at url: URL,
        sampleCount: Int,
        sampleRate: Int,
        channels: AVAudioChannelCount
    ) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: channels,
                interleaved: false
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let frameCapacity: AVAudioFrameCount = 4_096
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        )
        var remaining = sampleCount
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, Int(frameCapacity)))
            if let channelData = buffer.floatChannelData {
                for channel in 0..<Int(channels) {
                    channelData[channel].initialize(
                        repeating: 0,
                        count: Int(buffer.frameLength)
                    )
                }
            }
            try file.write(from: buffer)
            remaining -= Int(buffer.frameLength)
        }
    }
}

private final class SyntheticSampleReader: IncrementalSampleReader {
    let estimatedDurationSeconds: Double
    private(set) var maximumRequestedCount = 0

    private var remainingSamples: Int
    private let maximumReadSize: Int

    init(sampleCount: Int, sampleRate: Int, maximumReadSize: Int) {
        remainingSamples = sampleCount
        estimatedDurationSeconds = Double(sampleCount) / Double(sampleRate)
        self.maximumReadSize = maximumReadSize
    }

    func read(upTo requestedCount: Int) throws -> [Float] {
        maximumRequestedCount = max(maximumRequestedCount, requestedCount)
        XCTAssertLessThanOrEqual(requestedCount, maximumReadSize)
        let count = min(requestedCount, remainingSamples)
        remainingSamples -= count
        return [Float](repeating: 0, count: count)
    }

    func hasMoreSamples() throws -> Bool {
        remainingSamples > 0
    }
}
