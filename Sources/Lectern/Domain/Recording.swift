import Foundation
import SwiftData

@Model
final class Recording {
    var filePath: String
    var sampleRate: Double
    var sizeBytes: Int64
    var recordedAt: Date
    var prunedAt: Date?

    var lecture: Lecture?

    init(filePath: String, sampleRate: Double, sizeBytes: Int64, recordedAt: Date) {
        self.filePath = filePath
        self.sampleRate = sampleRate
        self.sizeBytes = sizeBytes
        self.recordedAt = recordedAt
    }

    var isPruned: Bool { prunedAt != nil }
}
