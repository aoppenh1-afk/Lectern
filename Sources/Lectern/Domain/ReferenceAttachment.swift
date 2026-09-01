import Foundation
import SwiftData

enum ReferenceAttachmentKind: String, Codable, Sendable {
    case text
    case markdown
    case word
    case pdf
}

@Model
final class ReferenceAttachment {
    var name: String
    var filePath: String
    var kind: ReferenceAttachmentKind
    var extractedText: String
    var addedAt: Date
    var course: Course?
    var lecture: Lecture?

    init(name: String,
         filePath: String,
         kind: ReferenceAttachmentKind,
         extractedText: String) {
        self.name = name
        self.filePath = filePath
        self.kind = kind
        self.extractedText = extractedText
        self.addedAt = Date()
    }
}
