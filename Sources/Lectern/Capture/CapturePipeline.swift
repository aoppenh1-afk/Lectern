import Foundation
@preconcurrency import AVFAudio

/// Incremental WAV (PCM 16-bit mono) writer. Not thread-safe by itself:
/// confine all calls to a single queue (see `CapturePipeline`).
final class WAVFileWriter {
    let url: URL
    let sampleRate: Double

    private let handle: FileHandle
    private var dataBytes: Int64 = 0
    private var finished = false

    init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileNoSuchFile,
                             userInfo: [NSFilePathErrorKey: url.path])
        }
        self.handle = handle
        handle.write(Self.header(dataBytes: 0, sampleRate: UInt32(sampleRate)))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !finished, buffer.format.commonFormat == .pcmFormatFloat32,
              let channel = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var samples = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, channel[index]))
            samples[index] = Int16(clamped * Float(32767))
        }

        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        handle.write(data)
        dataBytes += Int64(frameCount * MemoryLayout<Int16>.size)
    }

    /// Rewrites RIFF chunk sizes with the final byte count and closes the file.
    /// Returns the total on-disk size.
    func finish() throws -> Int64 {
        guard !finished else { return 44 + dataBytes }
        finished = true
        try handle.seek(toOffset: 0)
        handle.write(Self.header(dataBytes: UInt32(dataBytes), sampleRate: UInt32(sampleRate)))
        try handle.close()
        return 44 + dataBytes
    }

    /// Closes and deletes a partial capture (failed start or cancelled session).
    func abort() {
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private static func header(dataBytes: UInt32, sampleRate: UInt32) -> Data {
        var data = Data()

        func ascii(_ string: String) { data.append(string.data(using: .ascii)!) }
        func u32(_ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func u16(_ value: UInt16) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 2)) }

        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(dataBytes)

        return data
    }
}

/// Live conversion chain: hardware mic buffers in, 16 kHz mono WAV on disk.
/// All work is confined to one serial queue, so `ingest` is safe to call
/// directly from the audio render thread.
final class CapturePipeline: @unchecked Sendable {
    private let writer: WAVFileWriter
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "com.lectern.capture.pipeline")

    init(sourceFormat: AVAudioFormat, destinationURL: URL) throws {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.unsupportedOutputFormat
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: output) else {
            throw CaptureError.conversionUnavailable
        }

        self.writer = try WAVFileWriter(url: destinationURL, sampleRate: output.sampleRate)
        self.converter = converter
        self.outputFormat = output
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        queue.async { self.convertAndAppend(buffer) }
    }

    /// Blocks until every queued chunk has been written and the header patched.
    func finish() -> Result<(URL, Int64), Error> {
        queue.sync {
            do {
                let totalBytes = try writer.finish()
                return .success((writer.url, totalBytes))
            } catch {
                return .failure(error)
            }
        }
    }

    func abort() {
        queue.sync { writer.abort() }
    }

    private func convertAndAppend(_ input: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside convert(), on this queue.
        final class InputFeed: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            func next() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
        }
        let feed = InputFeed()
        feed.buffer = input

        while true {
            var conversionError: NSError?
            let status = converter.convert(to: scratch, error: &conversionError) { _, flags in
                if let next = feed.next() {
                    flags.pointee = .haveData
                    return next
                }
                flags.pointee = .noDataNow
                return nil
            }

            if let conversionError {
                // Drop this chunk rather than kill the capture mid-lecture.
                NSLog("Lectern capture conversion error: \(conversionError)")
                return
            }

            if scratch.frameLength > 0 {
                writer.append(scratch)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream, .error:
                return
            @unknown default:
                return
            }
        }
    }
}

enum CaptureError: LocalizedError {
    case unsupportedOutputFormat
    case conversionUnavailable
    case noInputHardware
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOutputFormat: return "Could not build the 16 kHz mono output format."
        case .conversionUnavailable: return "This microphone's format cannot be converted for transcription."
        case .noInputHardware: return "No input device is available."
        case .importFailed(let message): return message
        }
    }
}
