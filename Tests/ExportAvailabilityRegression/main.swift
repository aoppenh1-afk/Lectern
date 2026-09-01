import Foundation

let transcriptOnly = LectureExportAvailability(
    hasTranscript: true,
    hasNotes: false,
    flashcardCount: 0,
    quizCount: 0,
    bookmarkCount: 0,
    attachmentCount: 0
)

precondition(transcriptOnly.components.map(\.kind) == [.transcript])

let normalized = transcriptOnly.normalized(LecternBundleOptions())
precondition(normalized.includeTranscript)
precondition(!normalized.includeNotes)
precondition(!normalized.includeFlashcards)
precondition(!normalized.includeQuiz)
precondition(!normalized.includeBookmarks)
precondition(!normalized.includeReferenceFiles)
precondition(!normalized.includeDiagrams)

print("PASS: export choices and options contain only material the lecture actually has")
