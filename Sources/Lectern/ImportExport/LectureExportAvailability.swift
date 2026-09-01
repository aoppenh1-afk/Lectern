import Foundation

struct LectureExportAvailability: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case transcript
        case notes
        case flashcards
        case quiz
        case bookmarks
        case attachments
    }

    struct Component: Identifiable, Equatable, Sendable {
        let kind: Kind
        let count: Int

        var id: Kind { kind }
    }

    let hasTranscript: Bool
    let hasNotes: Bool
    let flashcardCount: Int
    let quizCount: Int
    let bookmarkCount: Int
    let attachmentCount: Int

    var components: [Component] {
        var result: [Component] = []
        if hasTranscript { result.append(Component(kind: .transcript, count: 1)) }
        if hasNotes { result.append(Component(kind: .notes, count: 1)) }
        if flashcardCount > 0 { result.append(Component(kind: .flashcards, count: flashcardCount)) }
        if quizCount > 0 { result.append(Component(kind: .quiz, count: quizCount)) }
        if bookmarkCount > 0 { result.append(Component(kind: .bookmarks, count: bookmarkCount)) }
        if attachmentCount > 0 { result.append(Component(kind: .attachments, count: attachmentCount)) }
        return result
    }

    func normalized(_ proposed: LecternBundleOptions) -> LecternBundleOptions {
        var result = proposed
        result.includeTranscript = proposed.includeTranscript && hasTranscript
        result.includeNotes = proposed.includeNotes && hasNotes
        result.includeFlashcards = proposed.includeFlashcards && flashcardCount > 0
        result.includeQuiz = proposed.includeQuiz && quizCount > 0
        result.includeBookmarks = proposed.includeBookmarks && bookmarkCount > 0
        result.includeReferenceFiles = proposed.includeReferenceFiles && attachmentCount > 0
        result.includeDiagrams = proposed.includeDiagrams && result.includeNotes
        return result
    }
}
