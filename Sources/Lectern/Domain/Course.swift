import Foundation
import SwiftData

@Model
final class Course {
    var name: String
    var colorHex: String
    var createdAt: Date
    /// Google Doc that holds this course's lecture-note tabs. Created on first push.
    var googleDocId: String?

    // Canvas-backed courses remain ordinary Lectern courses. A nil Canvas ID
    // marks a course created locally by the student.
    var canvasID: Int64?
    var courseCode: String?
    var termName: String?
    var syllabusHTML: String?
    var instructorName: String?
    var currentScore: Double?
    var currentGrade: String?
    var canvasURL: String?
    var canvasUpdatedAt: Date?

    /// Default spoken language stamped onto lectures recorded into this
    /// course. Raw-string storage keeps the SwiftData migration lightweight.
    private var languageRaw: String = LectureLanguage.english.rawValue

    var language: LectureLanguage {
        get { LectureLanguage(rawValue: languageRaw) ?? .english }
        set { languageRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .nullify, inverse: \Lecture.course)
    var lectures: [Lecture] = []

    @Relationship(deleteRule: .cascade, inverse: \ReferenceAttachment.course)
    var attachments: [ReferenceAttachment] = []

    @Relationship(deleteRule: .nullify, inverse: \ShiurSubscription.course)
    var subscriptions: [ShiurSubscription] = []

    init(name: String, colorHex: String, language: LectureLanguage = .english) {
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
        self.languageRaw = language.rawValue
    }

    var ankiDeckName: String {
        "School::\(name)"
    }
}

extension Course: Hashable {
    static func == (lhs: Course, rhs: Course) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}
