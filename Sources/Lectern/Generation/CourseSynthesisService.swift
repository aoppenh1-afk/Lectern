import Foundation
import SwiftData

struct CourseChatCanvasSource {
    let label: String
    let content: String
}

struct CourseChatSource {
    let title: String
    let labels: [String]
    let documents: [CourseChatDocument]

    @MainActor
    static func make(course: Course,
                     lectures: [Lecture],
                     canvasSources: [CourseChatCanvasSource] = [],
                     attachments: [ReferenceAttachment]? = nil) -> CourseChatSource? {
        var sources: [CourseChatDocument] = []

        sources.append(contentsOf: canvasSources.enumerated().map {
            CourseChatDocument(id: "canvas-\($0.offset)-\($0.element.label)",
                               label: $0.element.label, content: $0.element.content)
        })

        for attachment in (attachments ?? course.attachments).sorted(by: { $0.addedAt < $1.addedAt }) {
            sources.append(.init(id: sourceID(attachment.persistentModelID), label: "Course file: \(attachment.name)", content: attachment.extractedText))
        }

        for lecture in lectures.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            let lectureID = sourceID(lecture.persistentModelID)
            if let notes = lecture.artifact(of: .notes)?.content,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(.init(id: "\(lectureID)-notes", label: "\(lecture.title) notes", content: notes))
            }
            if let cleaned = lecture.artifact(of: .cleanedTranscript)?.content,
               !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(.init(id: "\(lectureID)-transcript", label: "\(lecture.title) transcript", content: cleaned))
            } else if let raw = lecture.artifact(of: .rawTranscript)?.content,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(.init(id: "\(lectureID)-raw transcript", label: "\(lecture.title) raw transcript", content: raw))
            }
            sources.append(contentsOf: ChatStudyMaterial.studySources(for: lecture).map {
                CourseChatDocument(id: "\(lectureID)-\($0.0)", label: "\(lecture.title) \($0.0.lowercased())", content: $0.1)
            })
            for attachment in lecture.attachments.sorted(by: { $0.addedAt < $1.addedAt }) {
                sources.append(.init(id: sourceID(attachment.persistentModelID), label: "\(lecture.title) file: \(attachment.name)", content: attachment.extractedText))
            }
        }

        sources.removeAll { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !sources.isEmpty else { return nil }
        return CourseChatSource(title: course.name, labels: sources.map(\.label), documents: sources)
    }

    private static func sourceID(_ id: PersistentIdentifier) -> String {
        // PersistentIdentifier's Codable representation includes its store identity.
        // The encoder cannot fail for this type, but keep the fallback unique in memory.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(id)).map { CourseChatWorkspace.digest($0) } ?? String(describing: id)
    }
}

@MainActor
@Observable
final class CourseSynthesisService {
    struct Turn: Identifiable, Codable {
        var id = UUID()
        let question: String
        let answer: String
        var material: ChatStudyMaterial?
        var sourceLabels: [String] = []
    }

    private(set) var isResponding = false
    private(set) var response = ""
    private(set) var pendingQuestion: String?
    private(set) var lastError: String?
    private(set) var turns: [Turn] = []
    private var task: Task<Void, Never>?
    private var currentCourseID: PersistentIdentifier?
    private var currentCourse: Course?
    private var activeTurnID: UUID?
    private var retryAction: (() -> Void)?
    var canRetry: Bool { retryAction != nil && lastError != nil && !isResponding }
    private let workspaceDirectory: URL
    private let chatSession: CourseChatSession

    init(workspaceDirectory: URL? = nil, chatSession: CourseChatSession = CourseChatSession()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.workspaceDirectory = workspaceDirectory ?? support.appendingPathComponent("Lectern/Workspace/Courses", isDirectory: true)
        self.chatSession = chatSession
    }

    func send(_ question: String,
              course: Course,
              lectures: [Lecture],
              canvasSources: [CourseChatCanvasSource] = [],
              canvasResources: [CanvasResourceReference] = [],
              canvasCredentials: CanvasCredentials? = nil,
              attachments: [ReferenceAttachment]? = nil,
              profile: AgentProfile,
              thinkingLevel: ThinkingLevel,
              modelOverride: String?,
              studyRequest: ChatStudyRequest? = nil) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        let hasLocalSources = CourseChatSource.make(
            course: course,
            lectures: lectures,
            canvasSources: canvasSources,
            attachments: attachments
        ) != nil
        guard hasLocalSources || !canvasResources.isEmpty || studyRequest?.usesTopicOnly == true else {
            retryAction = nil
            lastError = "Select a lecture, course file, or Canvas resource before sending."
            return
        }

        activate(course)
        guard currentCourseID == course.persistentModelID else { return }
        let turnID = UUID()
        activeTurnID = turnID
        retryAction = { [weak self] in
            self?.send(question, course: course, lectures: lectures, canvasSources: canvasSources,
                       canvasResources: canvasResources, canvasCredentials: canvasCredentials,
                       attachments: attachments, profile: profile, thinkingLevel: thinkingLevel,
                       modelOverride: modelOverride, studyRequest: studyRequest)
        }

        isResponding = true
        response = ""
        pendingQuestion = trimmed
        lastError = nil
        let priorConversation = turns.suffix(6).map {
            "Student: \($0.question)\n\nAssistant: \($0.material?.preview ?? $0.answer)"
        }.joined(separator: "\n\n")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var resolvedCanvasSources = canvasSources
                var canvasImages: [ACPConnection.PromptImage] = []
                if !canvasResources.isEmpty {
                    guard let canvasCredentials else { throw CanvasResourceContentError.notConnected }
                    let loader = CanvasResourceContentLoader(credentials: canvasCredentials)
                    for resource in canvasResources {
                        let loaded = try await loader.source(for: resource)
                        resolvedCanvasSources.append(.init(label: loaded.label, content: loaded.content))
                        canvasImages.append(contentsOf: loaded.images.map {
                            ACPConnection.PromptImage(data: $0.data, mimeType: $0.mimeType)
                        })
                    }
                }
                guard let source = CourseChatSource.make(
                    course: course,
                    lectures: lectures,
                    canvasSources: resolvedCanvasSources,
                    attachments: attachments
                ) ?? (studyRequest?.usesTopicOnly == true ? CourseChatSource(
                    title: course.name,
                    labels: ["Student topic and conversation; no course sources"],
                    documents: []
                ) : nil) else { throw CanvasResourceContentError.invalidResponse }
                try Task.checkCancellation()
                guard self.activeTurnID == turnID else { return }
                let workspace = try CourseChatWorkspace.prepare(
                    root: workspaceDirectory, courseID: course.persistentModelID,
                    source: source, images: canvasImages
                )
                let answer = try await chatSession.answer(
                    question: trimmed,
                    workspace: workspace,
                    history: priorConversation,
                    studyInstruction: studyRequest?.instruction,
                    profile: profile,
                    thinkingLevel: thinkingLevel,
                    modelOverride: modelOverride
                ) { [weak self] chunk in
                    Task { @MainActor in
                        guard let self, self.activeTurnID == turnID, studyRequest == nil else { return }
                        self.response += chunk
                    }
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard activeTurnID == turnID else { return }
                guard !answer.isEmpty else { throw ACPConnection.ACPError.unexpectedResponse }
                let material = try studyRequest.map {
                    try ChatStudyMaterial.parse(answer, request: $0, sourceLabels: source.labels,
                                                modelInfo: modelOverride ?? profile.title)
                }
                turns.append(Turn(question: trimmed, answer: material?.preview ?? answer,
                                  material: material, sourceLabels: source.labels))
                try persistHistory()
                response = ""
                pendingQuestion = nil
            } catch {
                guard activeTurnID == turnID else { return }
                chatSession.close()
                lastError = error.localizedDescription
                response = ""
                pendingQuestion = nil
            }
            guard activeTurnID == turnID else { return }
            activeTurnID = nil
            isResponding = false
            task = nil
        }
    }

    func retry() {
        guard !isResponding else { return }
        retryAction?()
    }

    func cancel() {
        chatSession.close()
        activeTurnID = nil
        task?.cancel()
        task = nil
        isResponding = false
        response = ""
        pendingQuestion = nil
    }

    func clear() {
        cancel()
        retryAction = nil
        let previous = turns
        turns = []
        lastError = nil
        do { try persistHistory() }
        catch { turns = previous; lastError = error.localizedDescription }
    }

    func activate(_ course: Course) {
        guard currentCourseID != course.persistentModelID else { return }
        cancel()
        retryAction = nil
        do {
            let history = try course.studyChatHistory.map { try JSONDecoder().decode([Turn].self, from: $0) } ?? []
            turns = history
            currentCourse = course
            currentCourseID = course.persistentModelID
            lastError = nil
        } catch {
            turns = []
            currentCourse = nil
            currentCourseID = nil
            lastError = "Could not read this course's saved chat: \(error.localizedDescription)"
        }
    }

    private func persistHistory() throws {
        guard let course = currentCourse, let context = course.modelContext else { return }
        let previous = course.studyChatHistory
        course.studyChatHistory = try JSONEncoder().encode(turns)
        do { try context.save() }
        catch { course.studyChatHistory = previous; throw error }
    }

    /// Appends to the latest destination content and commits the save receipt with the material.
    /// Failure restores only changes made here, preserving unrelated pending edits.
    @discardableResult
    func saveMaterial(_ edited: ChatStudyMaterial, turnID: UUID,
                      course: Course, lectureID: PersistentIdentifier?, newLectureTitle: String) throws -> Lecture {
        guard currentCourseID == course.persistentModelID, !course.isDeleted,
              let context = course.modelContext,
              let index = turns.firstIndex(where: { $0.id == turnID }),
              turns[index].material?.savedLectureTitle == nil else {
            throw ChatStudyMaterial.MaterialError.invalid("This draft has already been saved or its conversation is no longer open.")
        }
        try edited.validate()
        let lecture: Lecture
        let isNew = lectureID == nil
        if let lectureID {
            guard let existing = context.model(for: lectureID) as? Lecture,
                  !existing.isDeleted, existing.course == course, existing.status == .ready else {
                throw ChatStudyMaterial.MaterialError.invalid("Choose a ready lecture in this course. The previous destination is no longer available.")
            }
            lecture = existing
        } else {
            let title = newLectureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ChatStudyMaterial.MaterialError.invalid("Give the new lecture a title.") }
            lecture = Lecture(title: title, capturedAt: Date(), status: .ready, language: course.language)
            context.insert(lecture)
            lecture.course = course
        }

        let oldArtifacts = lecture.artifacts
        let oldCards = lecture.flashcards
        let oldQuestions = lecture.quizItems
        let notes = lecture.artifact(of: .notes)
        let oldContent = notes?.content
        let oldGeneratedAt = notes?.generatedAt
        let oldModelInfo = notes?.modelInfo
        let oldHistory = course.studyChatHistory
        let oldTurn = turns[index]
        var addedArtifacts: [Artifact] = []
        var addedCards: [Flashcard] = []
        var addedQuestions: [QuizItem] = []

        switch edited.kind {
        case .notes, .studyGuide:
            let section = "# \(edited.title)\n\n\(NotesMarkdownNormalizer.normalize(edited.markdown))"
            if let notes {
                notes.content = notes.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? section : notes.content + "\n\n---\n\n" + section
                notes.generatedAt = Date()
                notes.modelInfo = edited.modelInfo
            } else {
                let artifact = Artifact(kind: .notes, content: section, modelInfo: edited.modelInfo)
                context.insert(artifact)
                artifact.lecture = lecture
                lecture.artifacts.append(artifact)
                addedArtifacts.append(artifact)
            }
        case .flashcards:
            var seen = Set(oldCards.map { $0.front.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{0}" + $0.back.trimmingCharacters(in: .whitespacesAndNewlines) })
            for card in edited.cards {
                let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
                let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
                guard seen.insert(front + "\u{0}" + back).inserted else { continue }
                let item = Flashcard(front: front, back: back)
                context.insert(item)
                item.lecture = lecture
                lecture.flashcards.append(item)
                addedCards.append(item)
            }
        case .quiz:
            let quizID = UUID()
            for question in edited.questions {
                let options = question.options.flatMap { $0.isEmpty ? nil : $0 }
                let item = QuizItem(prompt: question.prompt, options: options, answer: question.answer,
                                    explanation: question.explanation, kind: options == nil ? .shortAnswer : .multipleChoice)
                item.quizID = quizID
                context.insert(item)
                item.lecture = lecture
                lecture.quizItems.append(item)
                addedQuestions.append(item)
            }
        }
        var saved = edited
        saved.savedLectureTitle = lecture.title
        turns[index].material = saved
        do {
            course.studyChatHistory = try JSONEncoder().encode(turns)
            try context.save()
        } catch {
            turns[index] = oldTurn
            course.studyChatHistory = oldHistory
            if let notes, let oldContent, let oldGeneratedAt, let oldModelInfo {
                notes.content = oldContent
                notes.generatedAt = oldGeneratedAt
                notes.modelInfo = oldModelInfo
            }
            lecture.artifacts = oldArtifacts
            lecture.flashcards = oldCards
            lecture.quizItems = oldQuestions
            for artifact in addedArtifacts { context.delete(artifact) }
            for card in addedCards { context.delete(card) }
            for question in addedQuestions { context.delete(question) }
            if isNew { context.delete(lecture) }
            throw error
        }
        return lecture
    }

}
