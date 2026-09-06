import Foundation
import SwiftData
import Testing

@MainActor
struct BundleImportRecoveryTests {
    @Test func failedImportDoesNotLeavePartialLecture() throws {
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let existing = Lecture(title: "Keep this", capturedAt: Date())
        context.insert(existing)
        try context.save()
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data("Reference".utf8).write(to: bundle.appendingPathComponent("reference.txt"))
        let referenceName = UUID().uuidString + ".txt"
        let copiedReference = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Reference Materials/" + referenceName)
        defer { try? FileManager.default.removeItem(at: copiedReference) }
        var manifest: [String: Any] = [
            "version": 1, "title": "Broken import", "capturedAt": "2026-09-01T12:00:00Z",
            "duration": 0, "language": "english", "rawTranscript": "Transcript",
            "flashcards": [], "quiz": [], "bookmarks": [],
            "references": [["name": referenceName, "bundledPath": "reference.txt", "kind": "text", "extractedText": "Reference"],
                           ["name": "\(UUID().uuidString)/reference.txt", "bundledPath": "reference.txt",
                            "kind": "text", "extractedText": "Reference"]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: bundle.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) {
            try LecternBundleService.importBundle(from: bundle, into: nil, context: context)
        }
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Lecture>()).map(\.title) == ["Keep this"])
        #expect(try context.fetch(FetchDescriptor<Artifact>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copiedReference.path))

        manifest["references"] = []
        try JSONSerialization.data(withJSONObject: manifest).write(to: bundle.appendingPathComponent("manifest.json"))
        let imported = try LecternBundleService.importBundle(from: bundle, into: nil, context: context)
        #expect(imported.artifact(of: .rawTranscript)?.content == "Transcript")
        #expect(try context.fetch(FetchDescriptor<Lecture>()).count == 2)
    }
}
