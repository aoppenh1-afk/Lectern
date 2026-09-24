import Foundation
import SwiftData

enum LiveBookmarkKind: String, CaseIterable, Identifiable, Sendable {
    case important, clarify, question, quiz

    var id: String { rawValue }
    var title: String {
        switch self {
        case .important: "Important"
        case .clarify: "Clarify"
        case .question: "Question"
        case .quiz: "Test / Quiz"
        }
    }

    var symbol: String {
        switch self {
        case .important: "bookmark.fill"
        case .clarify: "questionmark.circle"
        case .question: "bubble.left"
        case .quiz: "exclamationmark.triangle.fill"
        }
    }
}

@Model
final class LiveBookmark {
    var createdAt: Date
    var offset: TimeInterval
    var note: String
    var isExamAlert: Bool
    /// Optional for existing stores; their exam alerts become Quiz and plain flags Important.
    var kindRaw: String?
    var lecture: Lecture?

    var kind: LiveBookmarkKind {
        get { kindRaw.flatMap(LiveBookmarkKind.init(rawValue:)) ?? (isExamAlert ? .quiz : .important) }
        set {
            kindRaw = newValue.rawValue
            isExamAlert = newValue == .quiz
        }
    }

    init(offset: TimeInterval, note: String = "", isExamAlert: Bool = false,
         kind: LiveBookmarkKind? = nil) {
        self.createdAt = Date()
        self.offset = max(0, offset)
        self.note = note
        self.isExamAlert = kind.map { $0 == .quiz } ?? isExamAlert
        self.kindRaw = kind?.rawValue
    }
}
