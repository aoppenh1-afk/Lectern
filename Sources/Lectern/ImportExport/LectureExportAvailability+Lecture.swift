import Foundation

extension LectureExportAvailability {
    @MainActor
    init(lecture: Lecture) {
        let transcriptKinds: Set<ArtifactKind> = [.rawTranscript, .cleanedTranscript]
        self.init(
            hasTranscript: lecture.artifacts.contains { transcriptKinds.contains($0.kind) },
            hasNotes: lecture.artifact(of: .notes) != nil,
            flashcardCount: lecture.flashcards.count,
            quizCount: lecture.quizItems.count,
            bookmarkCount: lecture.bookmarks.count,
            attachmentCount: lecture.attachments.count
        )
    }
}
