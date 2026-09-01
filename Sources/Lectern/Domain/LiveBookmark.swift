import Foundation
import SwiftData

@Model
final class LiveBookmark {
    var createdAt: Date
    var offset: TimeInterval
    var note: String
    var isExamAlert: Bool
    var lecture: Lecture?

    init(offset: TimeInterval, note: String = "", isExamAlert: Bool = false) {
        self.createdAt = Date()
        self.offset = max(0, offset)
        self.note = note
        self.isExamAlert = isExamAlert
    }
}
