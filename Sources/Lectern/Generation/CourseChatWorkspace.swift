import CryptoKit
import Foundation
import SwiftData

struct CourseChatDocument: Sendable {
    let id: String
    let label: String
    let content: String
}

/// Materializes only the current selection. The index contains paths and hashes,
/// never document bodies, so agents can retrieve passages without a prompt dump.
struct CourseChatWorkspace: Sendable {
    struct Entry: Codable, Sendable {
        let label: String
        let path: String
        let sha256: String
    }

    private struct Index: Codable {
        let course: String
        let sources: [Entry]
    }

    let directory: URL
    let title: String
    let entries: [Entry]
    let fingerprint: String
    let images: [ACPConnection.PromptImage]

    var referencePrompt: String {
        let references = entries.map { "- \($0.label): \($0.path)" }.joined(separator: "\n")
        return """
        Course: \(title)
        Selected source index: sources.json
        \(references.isEmpty ? "No course sources selected. Use the student's topic and conversation." : references)
        """
    }

    @MainActor
    static func prepare(root: URL, courseID: PersistentIdentifier,
                        source: CourseChatSource, images: [ACPConnection.PromptImage]) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let key = digest(try encoder.encode(courseID))
        let directory = root.appendingPathComponent("course-\(key)", isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        var entries: [Entry] = []
        for document in source.documents {
            let name = "\(filename(document.label))-\(digest(Data(document.id.utf8))).txt"
            let data = Data(document.content.utf8)
            let path = "sources/\(name)"
            try writeIfChanged(data, to: directory.appendingPathComponent(path))
            entries.append(Entry(label: document.label, path: path, sha256: digest(data)))
        }
        // Sorting prevents picker order changes from unnecessarily replacing a session.
        entries.sort { $0.path < $1.path }
        let index = try encoder.encode(Index(course: source.title, sources: entries))
        try writeIfChanged(index, to: directory.appendingPathComponent("sources.json"))

        // This directory is owned by Lectern. Do not leave deselected or deleted
        // documents discoverable when the next session searches its workspace.
        let selected = Set(entries.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        for file in try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        where !selected.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }

        var signature = index
        for image in images {
            signature.append(Data("\n\(image.mimeType):\(digest(image.data))".utf8))
        }
        return Self(directory: directory, title: source.title, entries: entries,
                    fingerprint: digest(signature), images: images)
    }

    /// Antigravity's established native-attachment route, sent once per session.
    /// Split large text files losslessly to respect its per-resource byte limit.
    func nativeBlocks() throws -> [AntigravityACPContent.Block] {
        var blocks: [AntigravityACPContent.Block] = []
        var total = images.reduce(0) { $0 + $1.data.count }
        guard total <= AntigravityACPContent.maximumTotalBytes,
              images.allSatisfy({ $0.data.count <= AntigravityACPContent.maximumImageBytes }) else {
            throw AntigravityACPError.unsupportedAttachment(
                "The selected images exceed Antigravity's attachment limits. Select fewer sources."
            )
        }
        for entry in entries {
            let url = directory.appendingPathComponent(entry.path)
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= AntigravityACPContent.maximumTotalBytes else {
                throw AntigravityACPError.unsupportedAttachment(
                    "The selected sources exceed Antigravity's 50 MiB attachment limit. Select fewer sources or use another agent."
                )
            }
            var remainder = String(decoding: data, as: UTF8.self)[...]
            var part = 1
            while !remainder.isEmpty {
                // A Swift Character may contain arbitrarily many scalars. Split
                // at Unicode scalar boundaries and enforce the actual byte cap.
                let scalars = remainder.unicodeScalars
                var end = scalars.startIndex
                var bytes = 0
                while end < scalars.endIndex {
                    let next = scalars[end].utf8.count
                    if bytes + next > AntigravityACPContent.maximumTextBytes { break }
                    bytes += next
                    end = scalars.index(after: end)
                }
                blocks.append(.resource(text: String(remainder[..<end]),
                                        uri: url.absoluteString + "#part-\(part)", mimeType: "text/plain"))
                remainder = remainder[end...]
                part += 1
            }
        }
        return blocks
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func filename(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = label.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return String(safe.prefix(36))
    }

    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}
