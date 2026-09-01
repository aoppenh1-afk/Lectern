import Foundation
import SwiftData

@Model
final class CanvasAssignment {
    @Attribute(.unique) var canvasID: Int64
    var courseCanvasID: Int64
    var courseName: String
    var courseCode: String?
    var title: String
    var detailsHTML: String?
    var dueAt: Date?
    var lockAt: Date?
    var pointsPossible: Double?
    var htmlURL: String?
    var submissionState: String?
    var score: Double?
    var grade: String?
    var isMissing: Bool
    var isExcused: Bool
    var syncedAt: Date

    init(canvasID: Int64, courseCanvasID: Int64, courseName: String, title: String) {
        self.canvasID = canvasID
        self.courseCanvasID = courseCanvasID
        self.courseName = courseName
        self.title = title
        self.isMissing = false
        self.isExcused = false
        self.syncedAt = Date()
    }

    var isComplete: Bool {
        isExcused || submissionState == "submitted" || submissionState == "graded"
    }
}

@Model
final class CanvasEvent {
    @Attribute(.unique) var canvasID: Int64
    var courseCanvasID: Int64?
    var courseName: String?
    var title: String
    var detailsHTML: String?
    var startAt: Date
    var endAt: Date?
    var locationName: String?
    var locationAddress: String?
    var htmlURL: String?
    var syncedAt: Date

    init(canvasID: Int64, title: String, startAt: Date) {
        self.canvasID = canvasID
        self.title = title
        self.startAt = startAt
        self.syncedAt = Date()
    }
}

@Model
final class CanvasResource {
    @Attribute(.unique) var syncKey: String
    var canvasID: Int64?
    var courseCanvasID: Int64
    var courseName: String
    var moduleName: String
    var title: String
    var kind: String
    var htmlURL: String?
    var apiURL: String?
    var position: Int
    var syncedAt: Date

    init(syncKey: String, courseCanvasID: Int64, courseName: String,
         moduleName: String, title: String, kind: String, position: Int) {
        self.syncKey = syncKey
        self.courseCanvasID = courseCanvasID
        self.courseName = courseName
        self.moduleName = moduleName
        self.title = title
        self.kind = kind
        self.position = position
        self.syncedAt = Date()
    }
}

@Model
final class CanvasAnnouncement {
    @Attribute(.unique) var canvasID: Int64
    var courseCanvasID: Int64
    var courseName: String
    var title: String
    var messageHTML: String?
    var postedAt: Date
    var authorName: String?
    var htmlURL: String?
    var syncedAt: Date

    init(canvasID: Int64, courseCanvasID: Int64, courseName: String,
         title: String, postedAt: Date) {
        self.canvasID = canvasID
        self.courseCanvasID = courseCanvasID
        self.courseName = courseName
        self.title = title
        self.postedAt = postedAt
        self.syncedAt = Date()
    }
}
