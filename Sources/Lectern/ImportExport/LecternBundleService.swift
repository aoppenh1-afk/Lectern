import Foundation
import SwiftData
import UniformTypeIdentifiers

extension UTType {
    static let lecternBundle = UTType(exportedAs: "com.lectern.bundle", conformingTo: .package)
}

enum LecternBundleService {
    enum BundleError: LocalizedError {
        case invalidBundle
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalidBundle: return "This is not a valid Lectern bundle."
            case .newerVersion(let version): return "This bundle uses format version \(version), which this version of Lectern cannot import."
            }
        }
    }

    private struct Manifest: Codable {
        let version: Int
        let title: String
        let capturedAt: Date
        let duration: TimeInterval
        let language: LectureLanguage
        var rawTranscript: String?
        var cleanedTranscript: String?
        var notes: String?
        var flashcards: [Card]
        var quiz: [Question]
        var bookmarks: [Bookmark]
        var references: [Reference]
    }

    private struct Card: Codable { let front: String; let back: String }
    private struct Question: Codable {
        let quizID: UUID?
        let prompt: String
        let options: [String]?
        let answer: String
        let explanation: String
        let kind: QuizQuestionKind
    }
    private struct Bookmark: Codable {
        let offset: TimeInterval
        let note: String
        let isExamAlert: Bool
    }
    private struct Reference: Codable {
        let name: String
        let bundledPath: String?
        let kind: ReferenceAttachmentKind
        let extractedText: String
    }

    @MainActor
    static func export(_ lecture: Lecture, to destination: URL, options: LecternBundleOptions) throws {
        let options = LectureExportAvailability(lecture: lecture).normalized(options)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let assetsDirectory = destination.appendingPathComponent("Assets", isDirectory: true)
        let referencesDirectory = destination.appendingPathComponent("References", isDirectory: true)

        func formatted(_ value: String?, as format: LecternBundleOptions.TextFormat) -> String? {
            guard let value else { return nil }
            return format == .markdown ? value : plainText(from: value)
        }

        var manifest = Manifest(
            version: 1,
            title: lecture.title,
            capturedAt: lecture.capturedAt,
            duration: lecture.duration,
            language: lecture.language,
            rawTranscript: options.includeTranscript
                ? formatted(lecture.artifact(of: .rawTranscript)?.content, as: options.transcriptFormat) : nil,
            cleanedTranscript: options.includeTranscript
                ? formatted(lecture.artifact(of: .cleanedTranscript)?.content, as: options.transcriptFormat) : nil,
            notes: options.includeNotes
                ? formatted(lecture.artifact(of: .notes)?.content, as: options.notesFormat) : nil,
            flashcards: options.includeFlashcards
                ? lecture.flashcards.map { Card(front: $0.front, back: $0.back) } : [],
            quiz: options.includeQuiz
                ? lecture.quizItems.map { Question(quizID: $0.quizID, prompt: $0.prompt,
                                                   options: $0.options, answer: $0.answer,
                                                   explanation: $0.explanation, kind: $0.kind) } : [],
            bookmarks: options.includeBookmarks
                ? lecture.orderedBookmarks.map { Bookmark(offset: $0.offset, note: $0.note, isExamAlert: $0.isExamAlert) } : [],
            references: []
        )

        if options.includeDiagrams, let notes = manifest.notes {
            manifest.notes = try bundleImages(in: notes, into: assetsDirectory)
        }

        if options.includeReferenceFiles {
            try fileManager.createDirectory(at: referencesDirectory, withIntermediateDirectories: true)
            manifest.references = try lecture.attachments.map { attachment in
                let source = URL(fileURLWithPath: attachment.filePath)
                let filename = uniqueName(for: attachment.name, in: referencesDirectory)
                let target = referencesDirectory.appendingPathComponent(filename)
                var bundledPath: String?
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: target)
                    bundledPath = "References/\(filename)"
                }
                return Reference(name: attachment.name, bundledPath: bundledPath,
                                 kind: attachment.kind, extractedText: attachment.extractedText)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    }

    @MainActor
    static func importBundle(from source: URL, into course: Course?, context: ModelContext) throws -> Lecture {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        let manifestURL = source.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw BundleError.invalidBundle }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.version <= 1 else { throw BundleError.newerVersion(manifest.version) }

        let lecture = Lecture(title: manifest.title, capturedAt: manifest.capturedAt,
                              duration: manifest.duration, status: .ready, language: manifest.language)
        lecture.course = course
        context.insert(lecture)

        func addArtifact(_ kind: ArtifactKind, _ content: String?) {
            guard let content, !content.isEmpty else { return }
            let artifact = Artifact(kind: kind, content: content, modelInfo: "Imported Lectern bundle")
            artifact.lecture = lecture
            lecture.artifacts.append(artifact)
        }
        addArtifact(.rawTranscript, manifest.rawTranscript)
        addArtifact(.cleanedTranscript, manifest.cleanedTranscript)

        if let notes = manifest.notes {
            let importedNotes = try restoreImages(in: notes, from: source, lecture: lecture)
            addArtifact(.notes, importedNotes)
        }
        for cardData in manifest.flashcards {
            let card = Flashcard(front: cardData.front, back: cardData.back)
            card.lecture = lecture
            lecture.flashcards.append(card)
        }
        for item in manifest.quiz {
            let question = QuizItem(prompt: item.prompt, options: item.options, answer: item.answer,
                                    explanation: item.explanation, kind: item.kind)
            question.quizID = item.quizID
            question.lecture = lecture
            lecture.quizItems.append(question)
        }
        for item in manifest.bookmarks {
            let bookmark = LiveBookmark(offset: item.offset, note: item.note, isExamAlert: item.isExamAlert)
            bookmark.lecture = lecture
            lecture.bookmarks.append(bookmark)
        }
        try restoreReferences(manifest.references, source: source, lecture: lecture, context: context)
        try context.save()
        return lecture
    }

    private static func plainText(from markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`>]"#, with: "", options: .regularExpression)
    }

    private static func bundleImages(in markdown: String, into directory: URL) throws -> String {
        let regex = try NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
        var output = markdown
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
            guard let range = Range(match.range(at: 2), in: markdown) else { continue }
            let reference = String(markdown[range])
            let source = URL(fileURLWithPath: reference)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = uniqueName(for: source.lastPathComponent, in: directory)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
            output.replaceSubrange(range, with: "Assets/\(name)")
        }
        return output
    }

    @MainActor
    private static func restoreImages(in markdown: String, from bundle: URL, lecture: Lecture) throws -> String {
        let regex = try NSRegularExpression(pattern: #"!\[([^\]]*)\]\((Assets/[^)]+)\)"#)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let target = support.appendingPathComponent("Lectern/Attachments/Imported-\(UUID().uuidString)", isDirectory: true)
        var output = markdown
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
            guard let range = Range(match.range(at: 2), in: markdown) else { continue }
            let relative = String(markdown[range])
            let source = bundle.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let name = uniqueName(for: source.lastPathComponent, in: target)
            let copied = target.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: copied)
            output.replaceSubrange(range, with: copied.path)
        }
        return output
    }

    @MainActor
    private static func restoreReferences(_ references: [Reference], source: URL,
                                          lecture: Lecture, context: ModelContext) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let target = support.appendingPathComponent("Lectern/Reference Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for item in references {
            var path = ""
            if let bundledPath = item.bundledPath {
                let bundled = source.appendingPathComponent(bundledPath)
                if FileManager.default.fileExists(atPath: bundled.path) {
                    let name = uniqueName(for: item.name, in: target)
                    let copied = target.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: bundled, to: copied)
                    path = copied.path
                }
            }
            let attachment = ReferenceAttachment(name: item.name, filePath: path,
                                                 kind: item.kind, extractedText: item.extractedText)
            attachment.lecture = lecture
            lecture.attachments.append(attachment)
            context.insert(attachment)
        }
    }

    private static func uniqueName(for proposed: String, in directory: URL) -> String {
        let source = proposed as NSString
        var candidate = proposed
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(source.deletingPathExtension)-\(index).\(source.pathExtension)"
            index += 1
        }
        return candidate
    }
}
