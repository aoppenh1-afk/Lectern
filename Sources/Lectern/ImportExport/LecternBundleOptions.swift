import Foundation

struct LecternBundleOptions: Sendable {
    enum TextFormat: String, CaseIterable, Identifiable, Sendable {
        case markdown
        case plainText

        var id: String { rawValue }
        var title: String { self == .markdown ? "Markdown" : "Plain text" }
    }

    var transcriptFormat: TextFormat = .markdown
    var notesFormat: TextFormat = .markdown
    var includeTranscript = true
    var includeNotes = true
    var includeFlashcards = true
    var includeQuiz = true
    var includeBookmarks = true
    var includeReferenceFiles = true
    var includeDiagrams = true
}
