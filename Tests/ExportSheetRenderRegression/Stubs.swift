import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ArtifactKind: Hashable {
    case rawTranscript
    case cleanedTranscript
    case notes
}

struct Artifact {
    let kind: ArtifactKind
    let content: String
}

final class Lecture {
    var title: String
    var artifacts: [Artifact]

    init(title: String, artifacts: [Artifact]) {
        self.title = title
        self.artifacts = artifacts
    }

    func artifact(of kind: ArtifactKind) -> Artifact? {
        artifacts.first { $0.kind == kind }
    }
}

extension LectureExportAvailability {
    @MainActor
    init(lecture: Lecture) {
        self.init(
            hasTranscript: lecture.artifact(of: .rawTranscript) != nil || lecture.artifact(of: .cleanedTranscript) != nil,
            hasNotes: lecture.artifact(of: .notes) != nil,
            flashcardCount: 0,
            quizCount: 0,
            bookmarkCount: 0,
            attachmentCount: 0
        )
    }
}

enum LectureShareFormat: String, CaseIterable, Identifiable {
    case lectern
    case markdown
    case pdf
    case docx

    var id: String { rawValue }
    var title: String {
        switch self {
        case .lectern: return "Lectern"
        case .markdown: return "Markdown"
        case .pdf: return "PDF"
        case .docx: return "Word"
        }
    }
    var fileExtension: String { rawValue == "markdown" ? "md" : rawValue }
    var contentType: UTType { .data }
}

enum LecternBundleService {
    static func export(_ lecture: Lecture, to destination: URL, options: LecternBundleOptions) throws {}
}

enum LectureDocumentExportService {
    static func export(_ lecture: Lecture, to destination: URL,
                       format: LectureShareFormat, options: LecternBundleOptions) throws {}
}

enum LecternTheme {
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let accent = Color(red: 0.23, green: 0.45, blue: 0.32)
    static let standardAnimation = Animation.easeInOut(duration: 0.18)
}
