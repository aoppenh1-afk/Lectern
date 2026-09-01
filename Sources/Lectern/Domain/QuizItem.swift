import Foundation
import SwiftData

@Model
final class QuizItem {
    /// Groups items that were generated together into one quiz.
    var quizID: UUID?
    var prompt: String
    var options: [String]?
    var answer: String
    var explanation: String
    var kind: QuizQuestionKind
    var createdAt: Date

    var lecture: Lecture?

    init(prompt: String, options: [String]? = nil, answer: String, explanation: String = "", kind: QuizQuestionKind) {
        self.prompt = prompt
        self.options = options
        self.answer = answer
        self.explanation = explanation
        self.kind = kind
        self.createdAt = Date()
    }
}

/// One generated quiz: the batch of items sharing a quizID, oldest first.
struct QuizSet: Identifiable {
    let id: UUID
    let items: [QuizItem]

    var createdAt: Date { items.map(\.createdAt).min() ?? .distantPast }

    var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
