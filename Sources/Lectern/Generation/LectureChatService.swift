import Foundation
import PDFKit
import SwiftData

struct LectureChatSource {
    let title: String
    let labels: [String]
    let content: String

    static func make(for lecture: Lecture) -> LectureChatSource? {
        var sections: [(label: String, content: String)] = []

        if let notes = lecture.artifact(of: .notes)?.content,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(("Notes", notes))
        }

        if let cleaned = lecture.artifact(of: .cleanedTranscript)?.content,
           !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(("Cleaned transcript", cleaned))
        } else if sections.isEmpty,
                  let raw = lecture.artifact(of: .rawTranscript)?.content,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(("Raw transcript", raw))
        }

        for attachment in lecture.attachments.sorted(by: { $0.addedAt < $1.addedAt }) {
            sections.append(("Lecture file: \(attachment.name)", attachment.extractedText))
        }
        for attachment in (lecture.course?.attachments ?? []).sorted(by: { $0.addedAt < $1.addedAt }) {
            sections.append(("Course file: \(attachment.name)", attachment.extractedText))
        }

        guard !sections.isEmpty else { return nil }

        // Keep Notes whole whenever possible, then spend the remaining
        // context budget on the transcript. The cap avoids oversized agent
        // turns without introducing an embedding dependency.
        let characterBudget = 120_000
        var remaining = characterBudget
        var rendered: [String] = []
        var includedLabels: [String] = []

        for section in sections where remaining > 0 {
            let excerpt = String(section.content.prefix(remaining))
            guard !excerpt.isEmpty else { continue }
            rendered.append("<source name=\"\(section.label)\">\n\(excerpt)\n</source>")
            includedLabels.append(section.label)
            remaining -= excerpt.count
        }

        return LectureChatSource(
            title: lecture.title,
            labels: includedLabels,
            content: rendered.joined(separator: "\n\n")
        )
    }
}

struct ChatAttachment: Identifiable, Hashable, Sendable {
    let name: String
    let url: URL
    let kind: ChatAttachmentKind

    var id: String { url.path }
}

/// Owns the one live ACP conversation used by the lecture chat pane. Stored
/// messages survive relaunch; the process-backed ACP session does not.
@MainActor
@Observable
final class LectureChatService {
    private struct Runtime {
        let lectureID: PersistentIdentifier
        let sourceContent: String
        let profileID: String
        let model: String?
        let thinkingLevel: ThinkingLevel
        let connection: ACPConnection
        let sessionID: String
    }

    private let modelContainer: ModelContainer
    private let workspaceDirectory: URL
    private var runtime: Runtime?
    private var responseTask: Task<Void, Never>?
    private var activeTurnID: UUID?

    private(set) var isResponding = false
    private(set) var partialResponse = ""
    private(set) var lastError: String?
    private(set) var proposingMessageID: PersistentIdentifier?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        workspaceDirectory = support.appendingPathComponent("Lectern/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    static func hasSource(_ lecture: Lecture) -> Bool {
        LectureChatSource.make(for: lecture) != nil
    }

    func importAttachments(from urls: [URL]) throws -> [ChatAttachment] {
        let destinationDirectory = workspaceDirectory
            .appendingPathComponent("Chat Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        return try urls.map { sourceURL in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

            let kind = try attachmentKind(for: sourceURL)
            let destination = uniqueDestination(
                named: sourceURL.lastPathComponent,
                in: destinationDirectory
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return ChatAttachment(name: sourceURL.lastPathComponent, url: destination, kind: kind)
        }
    }

    func send(_ question: String,
              lecture: Lecture,
              profile: AgentProfile,
              thinkingLevel: ThinkingLevel,
              modelOverride: String?,
              attachments: [ChatAttachment] = []) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding,
              let source = LectureChatSource.make(for: lecture) else { return }

        let lectureID = lecture.persistentModelID
        let priorMessages = Array(lecture.orderedChatMessages.suffix(8))
        let userMessage = ChatMessage(
            role: .user,
            content: trimmed,
            attachmentNames: attachments.map(\.name),
            attachmentPaths: attachments.map(\.url.path),
            attachmentKinds: attachments.map { $0.kind.rawValue }
        )
        do {
            _ = try persist(userMessage, for: lectureID)
        } catch {
            lastError = error.localizedDescription
            return
        }

        isResponding = true
        partialResponse = ""
        lastError = nil
        let turnID = UUID()
        activeTurnID = turnID

        responseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let usesAntigravity = profile.id == AgentProfiles.antigravityID
                let needsBootstrap = usesAntigravity || !self.runtimeMatches(
                    lecture: lecture,
                    source: source,
                    profile: profile,
                    thinkingLevel: thinkingLevel,
                    modelOverride: modelOverride
                )

                let prompt = needsBootstrap
                    ? self.initialPrompt(
                        source: source,
                        history: priorMessages,
                        question: trimmed,
                        attachments: self.attachments(in: priorMessages) + attachments
                    )
                    : self.followUpPrompt(question: trimmed, attachments: attachments)
                let promptAttachments = needsBootstrap
                    ? self.attachments(in: priorMessages) + attachments
                    : attachments

                let images = try self.promptImages(from: promptAttachments)
                let answer: String
                if usesAntigravity {
                    self.closeRuntime()
                    answer = try await Self.promptAntigravity(
                        prompt: prompt,
                        images: images,
                        profile: profile,
                        thinkingLevel: thinkingLevel,
                        modelOverride: modelOverride
                    )
                } else {
                    let runtime = try await self.runtime(
                        for: lecture,
                        source: source,
                        profile: profile,
                        thinkingLevel: thinkingLevel,
                        modelOverride: modelOverride
                    )
                    answer = try await runtime.connection.prompt(
                        sessionID: runtime.sessionID,
                        text: prompt,
                        images: images
                    ) { [weak self] chunk in
                        Task { @MainActor in
                            guard let self, self.activeTurnID == turnID else { return }
                            self.partialResponse += chunk
                        }
                    }
                }

                guard self.activeTurnID == turnID else { return }
                let parsedResponse = ChatNoteEditIntent.parseAgentResponse(
                    answer.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard !parsedResponse.content.isEmpty else {
                    throw ACPConnection.ACPError.unexpectedResponse
                }

                let assistantMessage = ChatMessage(
                    role: .assistant,
                    content: parsedResponse.content,
                    modelInfo: modelOverride ?? profile.title,
                    sourceLabels: source.labels
                )
                let currentLecture = try self.persist(assistantMessage, for: lectureID)
                self.partialResponse = ""

                if currentLecture.artifact(of: .notes) != nil,
                   (parsedResponse.requestsEdit || ChatNoteEditIntent.isRequested(trimmed)) {
                    self.activeTurnID = nil
                    self.isResponding = false
                    self.responseTask = nil
                    self.proposeNoteChange(
                        from: assistantMessage,
                        lecture: currentLecture,
                        profile: profile,
                        thinkingLevel: thinkingLevel,
                        modelOverride: modelOverride
                    )
                    return
                }
            } catch {
                guard self.activeTurnID == turnID else { return }
                self.partialResponse = ""
                self.lastError = error.localizedDescription
                self.closeRuntime()
            }

            if self.activeTurnID == turnID {
                self.activeTurnID = nil
                self.isResponding = false
                self.responseTask = nil
            }
        }
    }

    func proposeNoteChange(from message: ChatMessage,
                           lecture: Lecture,
                           profile: AgentProfile,
                           thinkingLevel: ThinkingLevel,
                           modelOverride: String?) {
        guard !isResponding,
              message.role == .assistant,
              message.noteChangeState == nil,
              let notes = lecture.artifact(of: .notes),
              let source = LectureChatSource.make(for: lecture) else { return }

        let ordered = lecture.orderedChatMessages
        let messageIndex = ordered.firstIndex(where: { $0.persistentModelID == message.persistentModelID })
        let request = messageIndex.flatMap { index in
            ordered[..<index].last(where: { $0.role == .user })
        }
        let baseNotes = notes.content
        let baseHash = NotesMarkdownConverter.contentHash(of: baseNotes)
        let turnID = UUID()

        isResponding = true
        proposingMessageID = message.persistentModelID
        lastError = nil
        activeTurnID = turnID

        responseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let proposalPrompt = self.noteProposalPrompt(
                    request: request?.content ?? message.content,
                    assistantAnswer: message.content,
                    notes: baseNotes,
                    lectureSource: source.content
                )
                let relatedAttachments = request.map { self.attachments(in: [$0]) } ?? []
                let images = try self.promptImages(from: relatedAttachments)
                let answer: String
                if profile.id == AgentProfiles.antigravityID {
                    self.closeRuntime()
                    answer = try await Self.promptAntigravity(
                        prompt: proposalPrompt,
                        images: images,
                        profile: profile,
                        thinkingLevel: thinkingLevel,
                        modelOverride: modelOverride
                    )
                } else {
                    let runtime = try await self.runtime(
                        for: lecture,
                        source: source,
                        profile: profile,
                        thinkingLevel: thinkingLevel,
                        modelOverride: modelOverride
                    )
                    answer = try await runtime.connection.prompt(
                        sessionID: runtime.sessionID,
                        text: proposalPrompt,
                        images: images
                    )
                }
                guard self.activeTurnID == turnID else { return }

                let proposed = try self.extractProposedNotes(from: answer)
                guard proposed != baseNotes else { throw NoteEditError.noChanges }
                message.proposedNotes = proposed
                message.proposalBaseNotes = baseNotes
                message.proposalBaseHash = baseHash
                message.noteChangeState = .proposed
                do {
                    try self.modelContainer.mainContext.save()
                } catch {
                    message.proposedNotes = nil
                    message.proposalBaseNotes = nil
                    message.proposalBaseHash = nil
                    message.noteChangeState = nil
                    throw NoteEditError.persistence(error)
                }
            } catch {
                guard self.activeTurnID == turnID else { return }
                self.lastError = error.localizedDescription
            }

            if self.activeTurnID == turnID {
                self.activeTurnID = nil
                self.proposingMessageID = nil
                self.isResponding = false
                self.responseTask = nil
            }
        }
    }

    @discardableResult
    func applyProposal(_ message: ChatMessage, to lecture: Lecture) -> Bool {
        guard message.noteChangeState == .proposed,
              let proposed = message.proposedNotes,
              let baseHash = message.proposalBaseHash,
              let notes = lecture.artifact(of: .notes) else { return false }

        guard NotesMarkdownConverter.contentHash(of: notes.content) == baseHash else {
            message.noteChangeState = .stale
            lastError = NoteEditError.staleProposal.localizedDescription
            try? modelContainer.mainContext.save()
            return false
        }

        let appliedNotes = GenerationService.importReferencedImages(
            markdown: NotesMarkdownNormalizer.normalize(proposed),
            lectureID: lecture.persistentModelID
        )
        let previous = notes.content
        let previousGeneratedAt = notes.generatedAt
        let previousModelInfo = notes.modelInfo
        let priorUndoContent = lecture.lastNotesUndoContent
        let priorUndoHash = lecture.lastNotesUndoAppliedHash
        let appliedHash = NotesMarkdownConverter.contentHash(of: appliedNotes)
        lecture.lastNotesUndoContent = previous
        lecture.lastNotesUndoAppliedHash = appliedHash
        message.appliedPreviousNotes = previous
        message.appliedNotesHash = appliedHash
        message.noteChangeState = .applied
        notes.content = appliedNotes
        notes.generatedAt = Date()
        notes.modelInfo = message.modelInfo ?? notes.modelInfo
        do {
            try modelContainer.mainContext.save()
        } catch {
            notes.content = previous
            notes.generatedAt = previousGeneratedAt
            notes.modelInfo = previousModelInfo
            lecture.lastNotesUndoContent = priorUndoContent
            lecture.lastNotesUndoAppliedHash = priorUndoHash
            message.appliedPreviousNotes = nil
            message.appliedNotesHash = nil
            message.noteChangeState = .proposed
            lastError = NoteEditError.persistence(error).localizedDescription
            return false
        }
        closeRuntime()
        return true
    }

    func discardProposal(_ message: ChatMessage) {
        guard message.noteChangeState == .proposed else { return }
        message.noteChangeState = .discarded
        try? modelContainer.mainContext.save()
    }

    func proposalIsStale(_ message: ChatMessage, lecture: Lecture) -> Bool {
        guard let baseHash = message.proposalBaseHash,
              let notes = lecture.artifact(of: .notes)?.content else { return true }
        return NotesMarkdownConverter.contentHash(of: notes) != baseHash
    }

    func canUndoLastNoteChange(in lecture: Lecture) -> Bool {
        guard let appliedHash = lecture.lastNotesUndoAppliedHash,
              lecture.lastNotesUndoContent != nil,
              let notes = lecture.artifact(of: .notes)?.content else { return false }
        return NotesMarkdownConverter.contentHash(of: notes) == appliedHash
    }

    @discardableResult
    func undoLastNoteChange(in lecture: Lecture) -> Bool {
        guard canUndoLastNoteChange(in: lecture),
              let previous = lecture.lastNotesUndoContent,
              let notes = lecture.artifact(of: .notes) else {
            lastError = NoteEditError.undoConflict.localizedDescription
            return false
        }

        let appliedHash = lecture.lastNotesUndoAppliedHash
        let current = notes.content
        let previousGeneratedAt = notes.generatedAt
        notes.content = previous
        notes.generatedAt = Date()
        lecture.lastNotesUndoContent = nil
        lecture.lastNotesUndoAppliedHash = nil
        let appliedMessage = lecture.orderedChatMessages.last(where: {
            $0.noteChangeState == .applied && $0.appliedNotesHash == appliedHash
        })
        appliedMessage?.noteChangeState = .undone
        do {
            try modelContainer.mainContext.save()
        } catch {
            notes.content = current
            notes.generatedAt = previousGeneratedAt
            lecture.lastNotesUndoContent = previous
            lecture.lastNotesUndoAppliedHash = appliedHash
            appliedMessage?.noteChangeState = .applied
            lastError = NoteEditError.persistence(error).localizedDescription
            return false
        }
        closeRuntime()
        return true
    }

    func cancelResponse() {
        guard isResponding else { return }
        activeTurnID = nil
        runtime?.connection.cancel(sessionID: runtime?.sessionID ?? "")
        responseTask?.cancel()
        responseTask = nil
        partialResponse = ""
        isResponding = false
        proposingMessageID = nil
        closeRuntime()
    }

    func clearConversation(for lecture: Lecture) {
        cancelResponse()
        closeRuntime()
        for message in lecture.chatMessages {
            modelContainer.mainContext.delete(message)
        }
        try? modelContainer.mainContext.save()
        lastError = nil
    }

    func dismissError() {
        lastError = nil
    }

    private func runtime(for lecture: Lecture,
                         source: LectureChatSource,
                         profile: AgentProfile,
                         thinkingLevel: ThinkingLevel,
                         modelOverride: String?) async throws -> Runtime {
        if runtimeMatches(
            lecture: lecture,
            source: source,
            profile: profile,
            thinkingLevel: thinkingLevel,
            modelOverride: modelOverride
        ), let runtime {
            return runtime
        }

        closeRuntime()
        let connection = try await ACPConnection.connect(profile: profile)
        let session: ACPConnection.SessionInfo
        do {
            session = try await connection.newSession(workingDirectory: workspaceDirectory)
        } catch ACPConnection.ACPError.authRequired(let methods) {
            guard let methodID = profile.authMethodID ?? methods.first else {
                connection.shutdown()
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

        let opened = Runtime(
            lectureID: lecture.persistentModelID,
            sourceContent: source.content,
            profileID: profile.id,
            model: modelOverride,
            thinkingLevel: thinkingLevel,
            connection: connection,
            sessionID: session.id
        )
        runtime = opened
        return opened
    }

    private nonisolated static func promptAntigravity(
        prompt: String,
        images: [ACPConnection.PromptImage],
        profile: AgentProfile,
        thinkingLevel: ThinkingLevel,
        modelOverride: String?
    ) async throws -> String {
        var request = prompt
        let inputs = images.enumerated().map { index, image in
            let ext: String
            switch image.mimeType {
            case "image/jpeg": ext = "jpg"
            case "image/gif": ext = "gif"
            case "image/webp": ext = "webp"
            default: ext = "png"
            }
            let name = "chat-image-\(index + 1).\(ext)"
            request += "\n\nAttached image \(index + 1): @\(name)"
            return AntigravityCLI.WorkspaceInput.data(image.data, named: name)
        }
        let modelID = AntigravityCLI.applyThinking(
            thinkingLevel,
            to: modelOverride ?? profile.model ?? AntigravityCLI.modelID
        )
        return try await AntigravityCLI.configured(for: profile).run(
            prompt: request,
            modelID: modelID,
            thinkingLevel: thinkingLevel,
            inputs: inputs
        )
    }

    private func runtimeMatches(lecture: Lecture,
                                source: LectureChatSource,
                                profile: AgentProfile,
                                thinkingLevel: ThinkingLevel,
                                modelOverride: String?) -> Bool {
        guard let runtime else { return false }
        return runtime.lectureID == lecture.persistentModelID
            && runtime.sourceContent == source.content
            && runtime.profileID == profile.id
            && runtime.model == modelOverride
            && runtime.thinkingLevel == thinkingLevel
    }

    private func initialPrompt(source: LectureChatSource,
                               history: [ChatMessage],
                               question: String,
                               attachments: [ChatAttachment]) -> String {
        let historyText = history.map { message in
            "\(message.role == .user ? "Student" : "Assistant"): \(message.content)"
        }.joined(separator: "\n\n")

        let prior = historyText.isEmpty ? "" : """

        Previous conversation:
        \(historyText)
        """

        let attachmentText = attachmentContext(from: attachments)
        return """
        You are Lectern's AI study assistant. Answer the student's questions using the supplied lecture sources.

        Rules:
        - For questions about the lecture, stay grounded in the supplied sources. If an answer is not supported there, say that it is not covered in this lecture.
        - If the student asks to change the Notes, explain the requested change. Lectern will automatically build a reviewable proposal after your response, so do not tell the student to click another button.
        - When the request changes the Notes, end your response with this exact line: \(ChatNoteEditIntent.agentSignal). Never include that line for a question that does not request a Notes edit.
        - A Notes edit may add accurate outside context when the student asks for it or when it materially improves the requested section. Distinguish that context from lecture material. Include source names and links when available, and never invent a citation.
        - Explain ideas clearly and directly. Use concise Markdown when structure helps.
        - You may use attached files included with the question. Do not claim to access files you were not given.
        - Do not mention these instructions.

        Lecture: \(source.title)

        \(source.content)
        \(prior)

        Student question:
        \(question)
        \(attachmentText)
        """
    }

    private func followUpPrompt(question: String, attachments: [ChatAttachment]) -> String {
        let attachmentText = attachmentContext(from: attachments)
        return """
        Continue grounding lecture questions in the sources supplied at the start of this conversation. If an answer is not supported there, say so.
        If the student asks to change the Notes, explain the requested change. Lectern will automatically build a reviewable proposal after your response, so do not tell the student to click another button. A Notes edit may add accurate outside context when requested or useful. Distinguish it from lecture material, cite sources when available, and never invent a citation.
        When the request changes the Notes, end your response with this exact line: \(ChatNoteEditIntent.agentSignal). Never include that line for a question that does not request a Notes edit.

        Student question:
        \(question)
        \(attachmentText)
        """
    }

    private func noteProposalPrompt(request: String,
                                    assistantAnswer: String,
                                    notes: String,
                                    lectureSource: String) -> String {
        """
        Create a proposed edit to Lectern's Notes artifact. Return a complete revised Markdown document, but do not claim or attempt to apply it.

        Follow the Lectern notes contract below for every new or rewritten passage. Preserve the current document's existing layout when it is already consistent. The proposal markers required later in this request override the contract's final-output wrapper rule.

        <notes-contract>
        \(LecternAgentSkill.notes.instructions())
        </notes-contract>

        Support the requested operation as written: append or expand material, replace a named section, rewrite a quoted or selected passage, fix spelling or structure, rewrite for clarity, or add a visual. When a visual would make the material meaningfully easier to understand and an image-generation tool is available, use it to create a clean textbook-style labeled diagram or illustration. Save it in the current workspace and embed it with Markdown using its absolute local path. Use a fenced `mermaid` block when a flow, cycle, hierarchy, or comparison is better represented as a diagram or image generation is unavailable. Preserve unrelated Markdown exactly whenever possible. Do not edit the transcript.

        You may add accurate outside context when the request calls for it or it materially improves the requested section. Distinguish it from lecture material and add source names and links when available. Never invent sources or citations.

        Put the complete revised notes between these exact markers and write nothing outside them:
        <<<LECTERN_NOTE>>>
        revised Markdown
        <<<END_LECTERN_NOTE>>>

        Student request:
        \(request)

        Assistant's explanation:
        \(assistantAnswer)

        Current Notes artifact:
        <<<CURRENT_NOTES>>>
        \(notes)
        <<<END_CURRENT_NOTES>>>

        Lecture sources for factual grounding:
        \(lectureSource)
        """
    }

    private func extractProposedNotes(from response: String) throws -> String {
        let startMarker = "<<<LECTERN_NOTE>>>"
        let endMarker = "<<<END_LECTERN_NOTE>>>"
        guard let start = response.range(of: startMarker),
              let end = response.range(of: endMarker, range: start.upperBound..<response.endIndex) else {
            throw NoteEditError.invalidProposal
        }
        var proposed = String(response[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if proposed.hasPrefix("```markdown"), proposed.hasSuffix("```") {
            proposed.removeFirst("```markdown".count)
            proposed.removeLast(3)
            proposed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !proposed.isEmpty else { throw NoteEditError.invalidProposal }
        return proposed
    }

    private func attachments(in messages: [ChatMessage]) -> [ChatAttachment] {
        messages.flatMap { message in
            zip(message.attachmentPaths.indices, message.attachmentPaths).compactMap { index, path in
                guard message.attachmentNames.indices.contains(index),
                      message.attachmentKinds.indices.contains(index),
                      let kind = ChatAttachmentKind(rawValue: message.attachmentKinds[index]) else { return nil }
                return ChatAttachment(
                    name: message.attachmentNames[index],
                    url: URL(fileURLWithPath: path),
                    kind: kind
                )
            }
        }
    }

    private func attachmentContext(from attachments: [ChatAttachment]) -> String {
        let rendered = attachments.compactMap { attachment -> String? in
            switch attachment.kind {
            case .image:
                return "Attached image: \(attachment.name) (local path: \(attachment.url.path))"
            case .markdown, .text:
                guard let text = readTextAttachment(at: attachment.url) else {
                    return fileReference(for: attachment)
                }
                return "<attachment name=\"\(attachment.name)\" path=\"\(attachment.url.path)\">\n\(text)\n</attachment>"
            case .pdf:
                guard let document = PDFDocument(url: attachment.url) else { return nil }
                let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
                    .joined(separator: "\n\n")
                return "<attachment name=\"\(attachment.name)\" path=\"\(attachment.url.path)\">\n\(String(text.prefix(120_000)))\n</attachment>"
            case .file:
                return fileReference(for: attachment)
            case .folder:
                return folderReference(for: attachment)
            }
        }
        return rendered.isEmpty ? "" : "\n\nAttachments:\n" + rendered.joined(separator: "\n\n")
    }

    private func promptImages(from attachments: [ChatAttachment]) throws -> [ACPConnection.PromptImage] {
        try attachments.compactMap { attachment in
            guard attachment.kind == .image else { return nil }
            let data = try Data(contentsOf: attachment.url)
            return ACPConnection.PromptImage(data: data, mimeType: imageMIMEType(for: attachment.url))
        }
    }

    private func attachmentKind(for url: URL) throws -> ChatAttachmentKind {
        try ChatAttachmentKind.classify(url)
    }

    private func persist(_ message: ChatMessage,
                         for lectureID: PersistentIdentifier) throws -> Lecture {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Lecture>(
            predicate: #Predicate { $0.persistentModelID == lectureID }
        )
        guard let lecture = try context.fetch(descriptor).first,
              lecture.modelContext != nil,
              !context.deletedModelsArray.contains(where: {
                  $0.persistentModelID == lectureID
              }) else {
            throw NoteEditError.lectureUnavailable
        }

        context.insert(message)
        message.lecture = lecture
        try context.save()
        return lecture
    }

    private func uniqueDestination(named name: String, in directory: URL) -> URL {
        let proposed = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }

        let extensionName = proposed.pathExtension
        let stem = proposed.deletingPathExtension().lastPathComponent
        for suffix in 2...10_000 {
            let candidateName = extensionName.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString + "-" + name)
    }

    private func readTextAttachment(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512_000) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return String(text.prefix(120_000))
    }

    private func fileReference(for attachment: ChatAttachment) -> String {
        "<attached-file name=\"\(attachment.name)\" path=\"\(attachment.url.path)\" />"
    }

    private func folderReference(for attachment: ChatAttachment) -> String {
        let root = attachment.url.standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        var entries: [String] = []
        while let item = files?.nextObject() as? URL, entries.count < 500 {
            let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
            let isDirectory = (try? item.resourceValues(forKeys: Set(keys)).isDirectory) == true
            entries.append(relative + (isDirectory ? "/" : ""))
        }
        let manifest = entries.isEmpty ? "(empty folder)" : entries.joined(separator: "\n")
        return "<attached-folder name=\"\(attachment.name)\" path=\"\(root.path)\">\n\(manifest)\n</attached-folder>"
    }

    private func imageMIMEType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private func closeRuntime() {
        runtime?.connection.shutdown()
        runtime = nil
    }
}

private enum NoteEditError: LocalizedError {
    case invalidProposal
    case noChanges
    case staleProposal
    case undoConflict
    case lectureUnavailable
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .invalidProposal: return "The assistant did not return a valid note proposal. Try proposing again."
        case .noChanges: return "The proposed note is identical to the current note."
        case .staleProposal: return "The note changed after this proposal was created. Create a new proposal."
        case .undoConflict: return "Undo is unavailable because the note changed after the last proposal was applied."
        case .lectureUnavailable: return "This lecture is no longer available. The response was not saved."
        case .persistence(let error): return "Lectern could not save the note change: \(error.localizedDescription)"
        }
    }
}
