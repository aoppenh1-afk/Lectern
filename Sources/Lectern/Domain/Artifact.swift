import Foundation
import SwiftData

@Model
final class Artifact {
    var kind: ArtifactKind
    var content: String
    var modelInfo: String
    var generatedAt: Date

    var lecture: Lecture?

    init(kind: ArtifactKind, content: String, modelInfo: String) {
        self.kind = kind
        self.content = content
        self.modelInfo = modelInfo
        self.generatedAt = Date()
    }
}
