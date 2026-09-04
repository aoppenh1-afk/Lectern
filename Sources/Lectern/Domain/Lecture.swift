import Foundation
import SwiftData

@Model
final class Lecture {
    var title: String
    var capturedAt: Date
    var duration: TimeInterval
    var status: LectureStatus
    var statusMessage: String?

    /// Optional per-lecture override. Nil follows the current app preference.
    var transcriptionSourceRaw: String?
    var requestedTranscriptionConnectionID: UUID?

    /// The connection that actually produced the current raw transcript.
    var transcriptProviderRaw: String?
    var transcriptConnectionName: String?
    var transcriptModelID: String?
    var transcriptCompletedAt: Date?
    var transcriptFallbackSummary: String?

    /// Spoken language, stamped at creation from the course (or a manual
    /// override) so transcription and generation stay consistent for the
    /// lecture's lifetime. Raw-string storage keeps migration lightweight.
    private var languageRaw: String = LectureLanguage.english.rawValue

    var language: LectureLanguage {
        get { LectureLanguage(rawValue: languageRaw) ?? .english }
        set { languageRaw = newValue.rawValue }
    }

    var course: Course?

    /// Tab inside the course Google Doc that holds this lecture's notes.
    var googleTabId: String?
    /// SHA-256 of the notes markdown last pushed; unchanged hash skips a rewrite.
    var googleNotesHash: String?

    /// One-level note history for the last AI proposal the user applied.
    var lastNotesUndoContent: String?
    var lastNotesUndoAppliedHash: String?

    /// Optional remote provenance metadata (e.g. for YU Torah shiur imports).
    var sourceProviderRaw: String?
    var sourceKey: String?
    var sourcePageURL: String?
    var sourceMediaURL: String?
    var sourceTeacherName: String?
    var sourceSeriesName: String?
    var sourceImportedAt: Date?
    var sourceSubscriptionID: UUID?

    @Relationship(deleteRule: .cascade)
    var recording: Recording?

    @Relationship(deleteRule: .cascade)
    var artifacts: [Artifact] = []

    @Relationship(deleteRule: .cascade)
    var flashcards: [Flashcard] = []

    @Relationship(deleteRule: .cascade)
    var quizItems: [QuizItem] = []

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.lecture)
    var chatMessages: [ChatMessage] = []

    @Relationship(deleteRule: .cascade, inverse: \LiveBookmark.lecture)
    var bookmarks: [LiveBookmark] = []

    @Relationship(deleteRule: .cascade, inverse: \ReferenceAttachment.lecture)
    var attachments: [ReferenceAttachment] = []

    init(title: String, capturedAt: Date, duration: TimeInterval = 0, status: LectureStatus = .recording, language: LectureLanguage = .english) {
        self.title = title
        self.capturedAt = capturedAt
        self.duration = duration
        self.status = status
        self.statusMessage = nil
        self.transcriptionSourceRaw = nil
        self.requestedTranscriptionConnectionID = nil
        self.transcriptProviderRaw = nil
        self.transcriptConnectionName = nil
        self.transcriptModelID = nil
        self.transcriptCompletedAt = nil
        self.transcriptFallbackSummary = nil
        self.languageRaw = language.rawValue
    }

    var transcriptionSourceOverride: TranscriptionSource? {
        get { transcriptionSourceRaw.flatMap(TranscriptionSource.init(rawValue:)) }
        set { transcriptionSourceRaw = newValue?.rawValue }
    }

    var isRemoteImport: Bool {
        sourceProviderRaw != nil || sourceKey != nil
    }

    var sourceProviderName: String? {
        guard let sourceProviderRaw else { return nil }
        switch sourceProviderRaw.lowercased() {
        case "yutorah": return "YU Torah"
        default: return sourceProviderRaw
        }
    }

    var sourceProvenanceSummary: String? {
        guard isRemoteImport else { return nil }
        var parts: [String] = []
        if let provider = sourceProviderName { parts.append(provider) }
        if let teacher = sourceTeacherName, !teacher.isEmpty { parts.append(teacher) }
        if let series = sourceSeriesName, !series.isEmpty { parts.append(series) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isUnfiled: Bool { course == nil }

    var recordingSizeBytes: Int64 {
        recording?.sizeBytes ?? 0
    }

    func artifact(of kind: ArtifactKind) -> Artifact? {
        artifacts.first(where: { $0.kind == kind })
    }

    var orderedChatMessages: [ChatMessage] {
        chatMessages.sorted { $0.createdAt < $1.createdAt }
    }

    var orderedBookmarks: [LiveBookmark] {
        bookmarks.sorted { $0.offset < $1.offset }
    }

    /// Quizzes grouped by generation batch, oldest first. Items predating
    /// batch tracking (quizID nil) form one legacy set.
    var quizSets: [QuizSet] {
        let grouped = Dictionary(grouping: quizItems) { $0.quizID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
        return grouped
            .map { QuizSet(id: $0.key, items: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

extension Lecture: Hashable {
    static func == (lhs: Lecture, rhs: Lecture) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}
