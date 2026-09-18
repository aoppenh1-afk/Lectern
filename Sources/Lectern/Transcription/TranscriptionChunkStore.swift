import CryptoKit
import Foundation

/// Small independent files: a completed part never rewrites the job history.
actor TranscriptionChunkStore {
    struct Range: Codable, Equatable, Sendable {
        var start: Double
        var duration: Double
        var coreStart: Double
        var coreEnd: Double
    }
    struct Manifest: Codable, Sendable {
        var version = 1
        var ranges: [Range]
        var sourcePath: String? = nil
        var rangesDigest: String? = nil
    }
    private struct StoredPart: Codable {
        var index: Int
        var payload: Data
        var digest: String
    }
    struct Failure: Codable, Sendable {
        var date: Date
        var chunk: Int
        var attempt: Int
        var elapsedSeconds: Double
        var reason: String
    }
    static let shared = TranscriptionChunkStore()
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/TranscriptionChunks", isDirectory: true)
    }

    func key(for request: ExternalTranscriptionRequest, skillFingerprint: String) throws -> String {
        pruneExpired()
        // Stream once per attempt, off the UI actor; never retain the audio in memory.
        let handle = try FileHandle(forReadingFrom: request.audioURL)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        let audioDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let values = try? request.audioURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let connection = request.connection
        let identity = ["checkpoint-v2", "prompt-v1", "parser-v1", "audio-preparation-v1",
                        AntigravityACPRelease.current?.version ?? "unknown", request.checkpointID?.uuidString ?? "", request.audioURL.path,
                        String(values?.fileSize ?? 0), String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
                        String(request.durationSeconds), connection.id.uuidString, connection.provider.rawValue,
                        connection.modelID, String(describing: connection.processingMode),
                        AntigravityACPClient.effort(for: AntigravityACPClient.thinkingLevel(fromModelID: connection.modelID)),
                        String(describing: request.lectureLanguage), String(connection.diarizationEnabled),
                        String(describing: connection.timestampGranularity), String(describing: connection.languageMode),
                        connection.languageCode ?? "", audioDigest, skillFingerprint].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func manifest(key: String) -> Manifest? {
        guard let manifest = read(Manifest.self, key: key, name: "manifest.json"),
              manifest.version == 1, !manifest.ranges.isEmpty,
              manifest.ranges.count <= 10_000,
              let data = try? Self.rangeData(manifest.ranges),
              manifest.rangesDigest == Self.digest(data) else { return nil }
        var previousEnd = 0.0
        for range in manifest.ranges {
            guard [range.start, range.duration, range.coreStart, range.coreEnd].allSatisfy(\.isFinite),
                  range.start >= 0, range.duration >= 0,
                  abs(range.coreStart - previousEnd) < 0.001,
                  range.start <= range.coreStart, range.coreEnd >= range.coreStart,
                  range.coreEnd <= range.start + range.duration + 0.001 else { return nil }
            previousEnd = range.coreEnd
        }
        return manifest
    }
    func result(key: String, index: Int) -> TranscriptionResult? {
        guard let part = read(StoredPart.self, key: key, name: "part-\(index).json"),
              part.index == index, part.digest == Self.digest(part.payload),
              let result = try? JSONDecoder().decode(TranscriptionResult.self, from: part.payload),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.segments.isEmpty else { return nil }
        return result
    }
    func save(_ manifest: Manifest, key: String) throws {
        var manifest = manifest
        manifest.rangesDigest = Self.digest(try Self.rangeData(manifest.ranges))
        try write(manifest, key: key, name: "manifest.json")
    }
    func save(_ result: TranscriptionResult, key: String, index: Int) throws {
        let data = try JSONEncoder().encode(result)
        try write(StoredPart(index: index, payload: data, digest: Self.digest(data)), key: key, name: "part-\(index).json")
    }
    func saveFailure(_ failure: Failure, key: String) {
        // One bounded, payload-free summary; never store commands or thought text.
        try? write(failure, key: key, name: "last-failure.json")
    }
    func reset(key: String) throws {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    func discard(sourcePath: String) {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        for directory in directories {
            let key = directory.lastPathComponent
            guard key.count == 64, key.allSatisfy({ $0.isHexDigit }),
                  (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  read(Manifest.self, key: key, name: "manifest.json")?.sourcePath == sourcePath else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func read<T: Decodable>(_ type: T.Type, key: String, name: String) -> T? {
        let file = root.appendingPathComponent(key).appendingPathComponent(name)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16 * 1_024 * 1_024,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func rangeData(_ ranges: [Range]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(ranges)
    }
    private func write<T: Encodable>(_ value: T, key: String, name: String) throws {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    private var lastPrune: Date?
    private func pruneExpired() {
        guard lastPrune.map({ Date().timeIntervalSince($0) > 3_600 }) ?? true else { return }
        lastPrune = Date()
        let files = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])) ?? []
        for directory in files {
            let name = directory.lastPathComponent
            guard name.count == 64, name.allSatisfy({ $0.isHexDigit }),
                  let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            let expired = values.contentModificationDate.map { Date().timeIntervalSince($0) > 30 * 86_400 } ?? false
            let manifest = read(Manifest.self, key: name, name: "manifest.json")
            let removedSource = manifest?.sourcePath.map { !FileManager.default.fileExists(atPath: $0) } ?? false
            if expired || removedSource { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
