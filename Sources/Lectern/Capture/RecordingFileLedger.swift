import Foundation

/// Owns WAV crash-recovery and the discard list used when a lecture is deleted.
///
/// Launch recovery used to adopt every unclaimed WAV in the recordings folder.
/// Deleting a lecture only removed the SwiftData row, so the file came back as
/// "Recovered · …" on the next launch. Discarded names are remembered first so
/// a leftover file is never resurrected even if unlink fails.
struct RecordingFileLedger {
    struct Candidate: Equatable {
        let url: URL
        let capturedAt: Date
        let sizeBytes: Int64
    }

    let recordingsDirectory: URL
    var fileManager: FileManager = .default

    private var discardedURL: URL {
        recordingsDirectory.appendingPathComponent(".discarded-recordings")
    }

    func discard(filePath: String) {
        rememberDiscarded(filePath)
        if fileManager.fileExists(atPath: filePath) {
            try? fileManager.removeItem(atPath: filePath)
        }
    }

    func reclaim(filePath: String) {
        var names = discardedNames()
        let name = Self.identity(for: filePath)
        guard names.remove(name) != nil else { return }
        persistDiscarded(names)
    }

    func recoverCandidates(claimedPaths: Set<String>) -> [Candidate] {
        let discarded = discardedNames()
        let claimedIdentities = Set(claimedPaths.map(Self.identity(for:)))
        let claimedStandardized = Set(claimedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })

        let directoryContents = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )) ?? []

        return directoryContents.compactMap { wav -> Candidate? in
            guard wav.pathExtension.lowercased() == "wav" else { return nil }
            let identity = Self.identity(for: wav.path)
            guard !discarded.contains(identity) else { return nil }
            guard !claimedIdentities.contains(identity) else { return nil }
            guard !claimedStandardized.contains(wav.standardizedFileURL.path) else { return nil }

            let attributes = try? wav.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return Candidate(
                url: wav,
                capturedAt: attributes?.creationDate ?? Date(),
                sizeBytes: Int64(attributes?.fileSize ?? 0)
            )
        }
    }

    /// Pairs `-system` / `-mic` sidecars from a crashed mixed capture and
    /// prefers the mixed or system file so recovery does not create two lectures.
    static func collapseRecoveryCandidates(_ candidates: [Candidate]) -> [Candidate] {
        var byStamp: [String: [Candidate]] = [:]
        for candidate in candidates {
            let stamp = recoveryStamp(for: candidate.url)
            byStamp[stamp, default: []].append(candidate)
        }

        var adopted: [Candidate] = []
        for (_, group) in byStamp {
            if let mixed = group.first(where: { !isSidecar($0.url) }) {
                adopted.append(mixed)
                continue
            }
            if let system = group.first(where: { $0.url.lastPathComponent.contains("-system.") }) {
                adopted.append(system)
                continue
            }
            adopted.append(contentsOf: group)
        }
        return adopted.sorted { $0.capturedAt < $1.capturedAt }
    }

    private static func recoveryStamp(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix("-system") {
            name = String(name.dropLast("-system".count))
        } else if name.hasSuffix("-mic") {
            name = String(name.dropLast("-mic".count))
        }
        return name
    }

    private static func isSidecar(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasSuffix("-system") || name.hasSuffix("-mic")
    }

    static func identity(for filePath: String) -> String {
        URL(fileURLWithPath: filePath).standardizedFileURL.lastPathComponent
    }

    private func discardedNames() -> Set<String> {
        guard let data = fileManager.contents(atPath: discardedURL.path),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return Set(text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
    }

    private func rememberDiscarded(_ filePath: String) {
        var names = discardedNames()
        names.insert(Self.identity(for: filePath))
        persistDiscarded(names)
    }

    private func persistDiscarded(_ names: Set<String>) {
        let text = names.sorted().joined(separator: "\n")
        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: discardedURL, options: .atomic)
    }
}
