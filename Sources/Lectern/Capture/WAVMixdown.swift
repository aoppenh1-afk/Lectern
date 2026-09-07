import Foundation
@preconcurrency import AVFAudio

/// Mixes 16-bit mono WAVs (Lectern's capture format) into one file.
enum WAVMixdown {
    final class Reader {
        let url: URL
        let sampleRate: UInt32
        let dataBytes: UInt32
        private let handle: FileHandle
        private var remaining: UInt32

        var frameCount: Int { Int(dataBytes / 2) }

        init(url: URL) throws {
            self.url = url
            let handle = try FileHandle(forReadingFrom: url)
            let header = try handle.read(upToCount: 44) ?? Data()
            guard header.count == 44,
                  header[0..<4] == Data("RIFF".utf8),
                  header[8..<12] == Data("WAVE".utf8) else {
                throw CaptureError.mixdownFailed("Not a WAV file.")
            }

            let channels = header.u16(at: 22)
            let bits = header.u16(at: 34)
            guard channels == 1, bits == 16 else {
                throw CaptureError.mixdownFailed("Mixdown needs 16-bit mono WAV.")
            }

            sampleRate = header.u32(at: 24)
            dataBytes = header.u32(at: 40)
            remaining = dataBytes
            self.handle = handle
        }

        func readFrames(_ count: Int) throws -> [Int16] {
            let wanted = min(count * 2, Int(remaining))
            guard wanted > 0 else { return [] }
            let data = try handle.read(upToCount: wanted) ?? Data()
            if data.isEmpty {
                remaining = 0
                return []
            }
            remaining -= UInt32(data.count)
            var samples = [Int16](repeating: 0, count: data.count / 2)
            _ = samples.withUnsafeMutableBytes { dest in
                data.copyBytes(to: dest)
            }
            return samples
        }

        func close() {
            try? handle.close()
        }
    }

    /// Saturating sum of equal-length (padded) 16-bit streams. The longest
    /// source wins; shorter files contribute silence after they end.
    static func mix(urls: [URL], destination: URL) throws -> Int64 {
        let readers = try urls.map(Reader.init)
        defer { readers.forEach { $0.close() } }

        guard let sampleRate = readers.first?.sampleRate, sampleRate > 0 else {
            throw CaptureError.mixdownFailed("Nothing to mix.")
        }
        guard readers.allSatisfy({ $0.sampleRate == sampleRate }) else {
            throw CaptureError.mixdownFailed("Sample rates do not match.")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let writer = try WAVFileWriter(url: destination, sampleRate: Double(sampleRate))
        let chunkFrames = 16_384
        var finished = readers.map { _ in false }

        while finished.contains(false) {
            var mixed = [Int16](repeating: 0, count: chunkFrames)
            var framesThisChunk = 0

            for (index, reader) in readers.enumerated() {
                guard !finished[index] else { continue }
                let samples = try reader.readFrames(chunkFrames)
                if samples.isEmpty {
                    finished[index] = true
                    continue
                }
                framesThisChunk = max(framesThisChunk, samples.count)
                for i in 0..<samples.count {
                    mixed[i] = saturatingAdd(mixed[i], samples[i])
                }
            }

            if framesThisChunk == 0 { break }
            writer.append(int16Samples: mixed[0..<framesThisChunk])
        }

        return try writer.finish()
    }

    static func saturatingAdd(_ lhs: Int16, _ rhs: Int16) -> Int16 {
        let sum = Int32(lhs) + Int32(rhs)
        if sum > Int32(Int16.max) { return Int16.max }
        if sum < Int32(Int16.min) { return Int16.min }
        return Int16(sum)
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
