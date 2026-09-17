import Foundation
import SwiftData

/// One registrar final exam, cross-checked from a Canvas course.
///
/// Rows are fully refreshed on each Banner sync for the term, so the model
/// carries no uniqueness constraint. Display filters by the selected term and
/// the YU host gate.
@Model
final class YUFinalExam {
    var courseCanvasID: Int64?
    var courseName: String
    var title: String
    var startAt: Date
    var endAt: Date?
    var sectionCode: String?
    var sourceRaw: String?
    var termCode: String?
    var termLabel: String?
    var syncedAt: Date

    init(courseCanvasID: Int64?, courseName: String, title: String, startAt: Date) {
        self.courseCanvasID = courseCanvasID
        self.courseName = courseName
        self.title = title
        self.startAt = startAt
        self.syncedAt = Date()
    }

    var source: String { sourceRaw ?? "registrar" }
}
