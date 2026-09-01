import XCTest

final class ExportAvailabilityTests: XCTestCase {
    func testTranscriptOnlyLectureDoesNotOfferEmptyStudyMaterials() {
        let availability = LectureExportAvailability(
            hasTranscript: true,
            hasNotes: false,
            flashcardCount: 0,
            quizCount: 0,
            bookmarkCount: 0,
            attachmentCount: 0
        )

        XCTAssertEqual(availability.components.map(\.kind), [.transcript])

        let normalized = availability.normalized(LecternBundleOptions())
        XCTAssertTrue(normalized.includeTranscript)
        XCTAssertFalse(normalized.includeNotes)
        XCTAssertFalse(normalized.includeFlashcards)
        XCTAssertFalse(normalized.includeQuiz)
        XCTAssertFalse(normalized.includeBookmarks)
        XCTAssertFalse(normalized.includeReferenceFiles)
        XCTAssertFalse(normalized.includeDiagrams)
    }
}
