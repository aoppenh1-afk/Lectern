import Foundation
import SwiftData

@Model
final class Flashcard {
    var front: String
    var back: String
    var syncState: AnkiSyncState
    var createdAt: Date

    var lecture: Lecture?

    init(front: String, back: String, syncState: AnkiSyncState = .pending) {
        self.front = front
        self.back = back
        self.syncState = syncState
        self.createdAt = Date()
    }
}
