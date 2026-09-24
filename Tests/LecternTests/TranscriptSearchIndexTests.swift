import Foundation
import XCTest

final class TranscriptSearchIndexTests: XCTestCase {
    func testSearchUpdatesAndRemovesTranscriptWithoutKeepingContentCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternTranscriptSearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("search.sqlite")
        let index = TranscriptSearchIndex(fileURL: url)

        try await index.upsert([
            .init(key: "lecture-1", revision: 1, text: "[00:10] Mitochondria produce energy in cells."),
            .init(key: "lecture-2", revision: 1, text: "[00:10] Cell walls protect bacteria.")
        ])
        let firstMatch = try await index.search("mitoch")
        let secondMatch = try await index.search("cell walls")
        let injectedQuery = try await index.search("mitochondria OR")
        let firstRevisions = try await index.revisions()
        XCTAssertEqual(firstMatch, ["lecture-1"])
        XCTAssertEqual(secondMatch, ["lecture-2"])
        XCTAssertEqual(injectedQuery, [])
        XCTAssertEqual(firstRevisions, ["lecture-1": 1, "lecture-2": 1])

        try await index.upsert([
            .init(key: "lecture-1", revision: 2, text: "[00:10] Ribosomes make proteins.")
        ])
        let obsoleteMatch = try await index.search("mitochondria")
        let replacementMatch = try await index.search("ribos")
        XCTAssertEqual(obsoleteMatch, [])
        XCTAssertEqual(replacementMatch, ["lecture-1"])

        try await index.removeMissing(keeping: ["lecture-1"])
        let removedMatch = try await index.search("bacteria")
        let persistedMatch = try await TranscriptSearchIndex(fileURL: url).search("ribosomes")
        XCTAssertEqual(removedMatch, [])
        XCTAssertEqual(persistedMatch, ["lecture-1"])
    }

    func testShortAndPunctuatedQueries() {
        XCTAssertNil(TranscriptSearchIndex.ftsQuery("m"))
        XCTAssertEqual(TranscriptSearchIndex.ftsQuery("microbio"), "\"microbio\"*")
        XCTAssertEqual(TranscriptSearchIndex.ftsQuery("cell-wall"), "\"cell\" AND \"wall\"*")
        XCTAssertEqual(TranscriptSearchIndex.ftsQuery("שלום"), "\"שלום\"*")
    }
}
