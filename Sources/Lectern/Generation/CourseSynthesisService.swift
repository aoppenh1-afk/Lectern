import Foundation
import SwiftData

struct CourseChatCanvasSource {
    let label: String
    let content: String
}

struct CourseChatSource {
    let title: String
    let labels: [String]
    let chunks: [String]

    @MainActor
    static func make(course: Course,
                     lectures: [Lecture],
                     canvasSources: [CourseChatCanvasSource] = [],
                     attachments: [ReferenceAttachment]? = nil) -> CourseChatSource? {
        var sources: [(String, String)] = []

        sources.append(contentsOf: canvasSources.map { ($0.label, $0.content) })

        for attachment in (attachments ?? course.attachments).sorted(by: { $0.addedAt < $1.addedAt }) {
            sources.append(("Course file: \(attachment.name)", attachment.extractedText))
        }

        for lecture in lectures.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            if let notes = lecture.artifact(of: .notes)?.content,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(("\(lecture.title) notes", notes))
            }
            if let cleaned = lecture.artifact(of: .cleanedTranscript)?.content,
               !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(("\(lecture.title) transcript", cleaned))
            } else if let raw = lecture.artifact(of: .rawTranscript)?.content,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sources.append(("\(lecture.title) raw transcript", raw))
            }
            for attachment in lecture.attachments.sorted(by: { $0.addedAt < $1.addedAt }) {
                sources.append(("\(lecture.title) file: \(attachment.name)", attachment.extractedText))
            }
        }

        guard !sources.isEmpty else { return nil }
        var labels: [String] = []
        var chunks: [String] = []
        var current = ""
        let chunkLimit = 300_000

        func appendToChunks(label: String, content: String) {
            var remainder = content[...]
            var part = 1
            while !remainder.isEmpty {
                let room = max(1, chunkLimit - current.count - label.count - 64)
                let end = remainder.index(remainder.startIndex,
                                          offsetBy: min(room, remainder.count))
                let excerpt = String(remainder[..<end])
                let partLabel = content.count > excerpt.count ? "\(label), part \(part)" : label
                let rendered = "<source name=\"\(partLabel)\">\n\(excerpt)\n</source>"
                if !current.isEmpty, current.count + rendered.count > chunkLimit {
                    chunks.append(current)
                    current = ""
                    continue
                }
                current += current.isEmpty ? rendered : "\n\n\(rendered)"
                remainder = remainder[end...]
                part += 1
            }
        }

        for (label, content) in sources {
            guard !content.isEmpty else { continue }
            labels.append(label)
            appendToChunks(label: label, content: content)
        }
        if !current.isEmpty { chunks.append(current) }
        return CourseChatSource(title: course.name,
                                labels: labels,
                                chunks: chunks)
    }
}

@MainActor
@Observable
final class CourseSynthesisService {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    private(set) var isResponding = false
    private(set) var response = ""
    private(set) var lastError: String?
    private(set) var turns: [Turn] = []
    private var task: Task<Void, Never>?
    private var currentCourseID: PersistentIdentifier?
    private let workspaceDirectory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        workspaceDirectory = support.appendingPathComponent("Lectern/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
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
              modelOverride: String?) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        let hasLocalSources = CourseChatSource.make(
            course: course,
            lectures: lectures,
            canvasSources: canvasSources,
            attachments: attachments
        ) != nil
        guard hasLocalSources || !canvasResources.isEmpty else { return }

        if currentCourseID != course.persistentModelID {
            turns = []
            currentCourseID = course.persistentModelID
        }

        isResponding = true
        response = ""
        lastError = nil
        let priorConversation = turns.suffix(6).map {
            "Student: \($0.question)\n\nAssistant: \($0.answer)"
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
                ) else { throw CanvasResourceContentError.invalidResponse }
                let promptImages = canvasImages
                let sourceMaterial: String
                if source.chunks.count == 1 {
                    sourceMaterial = source.chunks[0]
                } else {
                    let findings = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                        for (index, chunk) in source.chunks.enumerated() {
                            let subsetImages = index == 0 ? promptImages : []
                            group.addTask {
                                let prompt = """
                                Analyze this subset of course sources for the student's question. Return only grounded findings that help answer it. Preserve source names and note disagreements or missing evidence.

                                Student question:
                                \(trimmed)

                                Course source subset \(index + 1) of \(source.chunks.count):
                                \(chunk)
                                """
                                let finding = try await Self.request(
                                    prompt: prompt,
                                    profile: profile,
                                    thinkingLevel: thinkingLevel,
                                    modelOverride: modelOverride,
                                    workspaceDirectory: self.workspaceDirectory,
                                    images: subsetImages
                                )
                                return (index, finding)
                            }
                        }
                        var values: [(Int, String)] = []
                        for try await finding in group { values.append(finding) }
                        return values.sorted(by: { $0.0 < $1.0 }).map(\.1)
                    }
                    sourceMaterial = findings.enumerated().map {
                        "<subset-findings index=\"\($0.offset + 1)\">\n\($0.element)\n</subset-findings>"
                    }.joined(separator: "\n\n")
                }
                let prompt = """
                You are Lectern's course study assistant. Answer using the supplied course sources.

                Rules:
                - Compare lectures by name when the question asks for differences or development over time.
                - Distinguish lecture material from attached class notes or slides.
                - If the sources do not support a claim, say so.
                - Cite source names inline. Do not invent citations.
                - Use concise Markdown when it helps.

                Course: \(source.title)

                \(sourceMaterial)

                Previous conversation:
                \(priorConversation.isEmpty ? "None" : priorConversation)

                Student question:
                \(trimmed)
                """
                let answer = try await Self.request(
                    prompt: prompt,
                    profile: profile,
                    thinkingLevel: thinkingLevel,
                    modelOverride: modelOverride,
                    workspaceDirectory: workspaceDirectory,
                    images: source.chunks.count == 1 ? promptImages : []
                ) { [weak self] chunk in
                    Task { @MainActor in self?.response += chunk }
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                turns.append(Turn(question: trimmed, answer: answer))
                response = ""
            } catch {
                lastError = error.localizedDescription
            }
            isResponding = false
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isResponding = false
        response = ""
    }

    func clear() {
        cancel()
        turns = []
        lastError = nil
    }

    private nonisolated static func request(
        prompt: String,
        profile: AgentProfile,
        thinkingLevel: ThinkingLevel,
        modelOverride: String?,
        workspaceDirectory: URL,
        images: [ACPConnection.PromptImage] = [],
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        if profile.id == AgentProfiles.antigravityID {
            var prompt = prompt
            let inputs = images.enumerated().map { index, image in
                let ext: String
                switch image.mimeType {
                case "image/jpeg": ext = "jpg"
                case "image/gif": ext = "gif"
                case "image/webp": ext = "webp"
                default: ext = "png"
                }
                let name = "course-image-\(index + 1).\(ext)"
                prompt += "\n\nCourse image \(index + 1): @\(name)"
                return AntigravityACPClient.WorkspaceInput.data(image.data, named: name)
            }
            let modelID = AntigravityACPClient.applyThinking(
                thinkingLevel,
                to: modelOverride ?? profile.model ?? AntigravityACPClient.modelID
            )
            let output = try await AntigravityACPClient.configured(for: profile).run(
                prompt: prompt,
                modelID: modelID,
                thinkingLevel: thinkingLevel,
                inputs: inputs
            )
            onChunk?(output)
            return output
        }

        let connection = try await ACPConnection.connect(profile: profile)
        defer { connection.shutdown() }
        let session: ACPConnection.SessionInfo
        do {
            session = try await connection.newSession(workingDirectory: workspaceDirectory)
        } catch ACPConnection.ACPError.authRequired(let methods) {
            guard let methodID = profile.authMethodID ?? methods.first else {
                throw ACPConnection.ACPError.authRequired(methods: methods)
            }
            try await connection.authenticate(methodID: methodID)
            session = try await connection.newSession(workingDirectory: workspaceDirectory)
        }
        await connection.applyGenerationSettings(
            session: session,
            model: modelOverride,
            thinkingLevel: thinkingLevel.rawValue
        )
        return try await connection.prompt(sessionID: session.id, text: prompt, images: images, onChunk: onChunk)
    }
}
