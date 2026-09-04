import Foundation
import RegexBuilder
import SwiftData

/// Runs study-material generation through ACP agent profiles. Transcript
/// cleanup is the dependency gate; the remaining selected artifacts run in
/// independent ACP sessions so they can finish concurrently.
@MainActor
@Observable
final class GenerationService {
    struct ActiveJob {
        var lectureTitle: String
        var remaining: [GenerationJobKind]
    }

    private(set) var activeJob: ActiveJob?
    private(set) var lastError: String?
    private var generationTask: Task<Void, Never>?

    private let modelContainer: ModelContainer
    private let completionNotifier: any CompletionNotifying

    private struct GeneratedOutput: Sendable {
        let kind: GenerationJobKind
        let content: String
    }

    private struct InvalidNotesOutput: LocalizedError, Sendable {
        let violations: [String]

        var errorDescription: String? {
            "Notes still missed the required structure after one repair: "
                + violations.joined(separator: " ")
        }
    }

    /// Directory agents work in and where imported images land.
    private let workspaceDirectory: URL

    init(
        modelContainer: ModelContainer,
        completionNotifier: any CompletionNotifying = SystemCompletionNotifier.shared
    ) {
        self.modelContainer = modelContainer
        self.completionNotifier = completionNotifier

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        workspaceDirectory = support.appendingPathComponent("Lectern/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
    }

    func generate(lecture: Lecture,
                  kinds: [GenerationJobKind],
                  profile: AgentProfile,
                  quizOptions: QuizOptions = QuizOptions(),
                  thinkingLevel: ThinkingLevel = .medium,
                  modelOverride: String? = nil,
                  quizFocus: String? = nil) {
        guard generationTask == nil else { return }
        let ordered = GenerationJobKind.ordered.filter { kinds.contains($0) }
        guard !ordered.isEmpty else { return }

        activeJob = ActiveJob(lectureTitle: lecture.title, remaining: ordered)
        lastError = nil
        completionNotifier.prepare(for: .generation)

        generationTask = Task {
            await run(lectureID: lecture.persistentModelID,
                      lectureTitle: lecture.title,
                      kinds: ordered,
                      profile: profile,
                      quizOptions: quizOptions,
                      thinkingLevel: thinkingLevel,
                      modelOverride: modelOverride,
                      quizFocus: quizFocus)
        }
    }

    func cancel() {
        guard generationTask != nil else { return }
        lastError = nil
        generationTask?.cancel()
    }

    /// Runs generation synchronously within an async context, serialized with other generation jobs.
    func generateDirectly(
        lecture: Lecture,
        kinds: [GenerationJobKind],
        profile: AgentProfile,
        quizOptions: QuizOptions = QuizOptions(),
        thinkingLevel: ThinkingLevel = .medium,
        modelOverride: String? = nil,
        quizFocus: String? = nil
    ) async throws {
        while activeJob != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }

        let ordered = GenerationJobKind.ordered.filter { kinds.contains($0) }
        guard !ordered.isEmpty else { return }

        activeJob = ActiveJob(lectureTitle: lecture.title, remaining: ordered)
        lastError = nil
        defer { activeJob = nil }

        try await executeGenerationCore(
            lectureID: lecture.persistentModelID,
            lectureTitle: lecture.title,
            kinds: ordered,
            profile: profile,
            quizOptions: quizOptions,
            thinkingLevel: thinkingLevel,
            modelOverride: modelOverride,
            quizFocus: quizFocus
        )
    }

    // MARK: - Job runner

    private func run(lectureID: PersistentIdentifier,
                     lectureTitle: String,
                     kinds: [GenerationJobKind],
                     profile: AgentProfile,
                     quizOptions: QuizOptions,
                     thinkingLevel: ThinkingLevel,
                     modelOverride: String?,
                     quizFocus: String?) async {
        defer {
            activeJob = nil
            generationTask = nil
        }

        do {
            try await executeGenerationCore(
                lectureID: lectureID,
                lectureTitle: lectureTitle,
                kinds: kinds,
                profile: profile,
                quizOptions: quizOptions,
                thinkingLevel: thinkingLevel,
                modelOverride: modelOverride,
                quizFocus: quizFocus
            )
        } catch is CancellationError {
            lastError = nil
        } catch {
            lastError = "\(profile.title): \(error.localizedDescription)"
        }
    }

    private func executeGenerationCore(
        lectureID: PersistentIdentifier,
        lectureTitle: String,
        kinds: [GenerationJobKind],
        profile: AgentProfile,
        quizOptions: QuizOptions,
        thinkingLevel: ThinkingLevel,
        modelOverride: String?,
        quizFocus: String?
    ) async throws {
        let context = modelContainer.mainContext
        guard let lecture = context.model(for: lectureID) as? Lecture,
              let rawTranscript = lecture.artifact(of: .rawTranscript)?.content else {
            throw NSError(
                domain: "GenerationService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No raw transcript to generate from."]
            )
        }

        let effortHint = "Reasoning effort: \(thinkingLevel.rawValue).\n\n"
        let language = lecture.language
        let supplementaryInputs = antigravityReferenceInputs(for: lecture)
        let rawSource = sourceWithReferences(transcript: rawTranscript, lecture: lecture)

        if kinds.contains(.cleanedTranscript) {
            activeJob?.remaining = kinds
            let cleaned = try await Self.requestOutput(
                kind: .cleanedTranscript,
                transcript: rawSource,
                profile: profile,
                quizOptions: quizOptions,
                thinkingLevel: thinkingLevel,
                modelOverride: modelOverride,
                quizFocus: quizFocus,
                workspaceDirectory: workspaceDirectory,
                effortHint: effortHint,
                language: language,
                supplementaryInputs: supplementaryInputs
            ).content.trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            upsertArtifact(kind: .cleanedTranscript,
                           content: cleaned,
                           modelInfo: profile.title,
                           lecture: lecture,
                           context: context)
            try context.save()
        }

        let transcript = lecture.artifact(of: .cleanedTranscript)?.content ?? rawTranscript
        let generationSource = sourceWithReferences(transcript: transcript, lecture: lecture)
        let independentKinds = kinds.filter { $0 != .cleanedTranscript }
        activeJob?.remaining = independentKinds

        let outputs = try await withThrowingTaskGroup(of: GeneratedOutput.self) { group in
            for kind in independentKinds {
                group.addTask {
                    try await Self.requestOutput(
                        kind: kind,
                        transcript: generationSource,
                        profile: profile,
                        quizOptions: quizOptions,
                        thinkingLevel: thinkingLevel,
                        modelOverride: modelOverride,
                        quizFocus: quizFocus,
                        workspaceDirectory: self.workspaceDirectory,
                        effortHint: effortHint,
                        language: language,
                        supplementaryInputs: supplementaryInputs
                    )
                }
            }

            var completed: [GeneratedOutput] = []
            for try await output in group {
                completed.append(output)
                activeJob?.remaining.removeAll { $0 == output.kind }
            }
            return completed
        }
        try Task.checkCancellation()

        for output in outputs.sorted(by: { orderedIndex($0.kind) < orderedIndex($1.kind) }) {
            switch output.kind {
            case .cleanedTranscript:
                break
            case .notes:
                storeNotes(lecture: lecture, markdown: output.content, profile: profile, context: context)
            case .flashcards:
                try storeFlashcards(lecture: lecture, output: output.content, context: context)
            case .quiz:
                try storeQuiz(lecture: lecture, output: output.content)
            }
        }
        try context.save()
        completionNotifier.deliver(.generationFinished(
            lectureTitle: lectureTitle,
            items: kinds.map(\.title)
        ))
    }

    private func orderedIndex(_ kind: GenerationJobKind) -> Int {
        GenerationJobKind.ordered.firstIndex(of: kind) ?? .max
    }

    private func sourceWithReferences(transcript: String, lecture: Lecture) -> String {
        let references = lecture.attachments.map { ("Lecture file: \($0.name)", $0.extractedText) }
            + (lecture.course?.attachments ?? []).map { ("Course file: \($0.name)", $0.extractedText) }
        guard !references.isEmpty else { return transcript }

        var remaining = 160_000
        var rendered: [String] = ["<lecture-transcript>\n\(transcript)\n</lecture-transcript>"]
        for (label, content) in references where remaining > 0 {
            let excerpt = String(content.prefix(remaining))
            guard !excerpt.isEmpty else { continue }
            rendered.append("<reference-source name=\"\(label)\">\n\(excerpt)\n</reference-source>")
            remaining -= excerpt.count
        }
        rendered.append("Use reference sources to correct uncertain wording, names, technical terms, and recognition errors. Do not add reference-only claims to a cleaned transcript or attribute them to the professor. For notes and study materials, use them as supporting context while distinguishing them from what the professor said in this lecture.")
        return rendered.joined(separator: "\n\n")
    }

    private func antigravityReferenceInputs(for lecture: Lecture) -> [AntigravityACPClient.WorkspaceInput] {
        let references = lecture.attachments
            .sorted { $0.addedAt < $1.addedAt }
            .map { (scope: "lecture", attachment: $0) }
            + (lecture.course?.attachments ?? [])
                .sorted { $0.addedAt < $1.addedAt }
                .map { (scope: "course", attachment: $0) }

        return references.enumerated().compactMap { index, reference in
            guard !reference.attachment.filePath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: reference.attachment.filePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let name = Self.referenceWorkspaceName(
                scope: reference.scope,
                index: index,
                originalName: reference.attachment.name
            )
            return .file(url, named: name)
        }
    }

    private nonisolated static func referenceWorkspaceName(
        scope: String,
        index: Int,
        originalName: String
    ) -> String {
        let originalURL = URL(fileURLWithPath: originalName)
        let originalExtension = originalURL.pathExtension
        let originalStem = originalURL.deletingPathExtension().lastPathComponent
        let sanitizedStem = originalStem.map { character in
            character.isLetter || character.isNumber || ".-_".contains(character)
                ? character
                : "-"
        }
        let compactStem = String(sanitizedStem).prefix(72)
        let stem = compactStem.isEmpty ? "file" : String(compactStem)
        let sanitizedExtension = originalExtension.filter {
            $0.isLetter || $0.isNumber
        }
        let suffix = sanitizedExtension.isEmpty ? "" : ".\(sanitizedExtension)"
        return "\(scope)-reference-\(index + 1)-\(stem)\(suffix)"
    }

    private nonisolated static func requestOutput(
        kind: GenerationJobKind,
        transcript: String,
        profile: AgentProfile,
        quizOptions: QuizOptions,
        thinkingLevel: ThinkingLevel,
        modelOverride: String?,
        quizFocus: String?,
        workspaceDirectory: URL,
        effortHint: String,
        language: LectureLanguage,
        supplementaryInputs: [AntigravityACPClient.WorkspaceInput]
    ) async throws -> GeneratedOutput {
        if profile.id == AgentProfiles.antigravityID, kind == .notes {
            let cli = AntigravityACPClient.configured(for: profile)
            let modelID = AntigravityACPClient.applyThinking(
                thinkingLevel,
                to: modelOverride ?? profile.model ?? AntigravityACPClient.modelID
            )
            let source = AntigravityACPClient.WorkspaceInput.text(transcript, named: "lecture-source.md")
            let referenceInstruction = AntigravityACPClient.supplementaryReferenceInstruction(
                for: supplementaryInputs
            )
            var output = NotesMarkdownNormalizer.normalize(try await cli.run(
                prompt: effortHint + referenceInstruction + Prompts.antigravityNotesRequest(language: language),
                modelID: modelID,
                thinkingLevel: thinkingLevel,
                inputs: [source] + supplementaryInputs,
                skills: [.notes]
            ))
            var violations = NotesOutputValidator.violations(
                in: output,
                source: transcript,
                language: language
            )
            if !violations.isEmpty {
                output = NotesMarkdownNormalizer.normalize(try await cli.run(
                    prompt: effortHint + referenceInstruction + Prompts.antigravityNotesRepair(
                        violations: violations,
                        language: language
                    ),
                    modelID: modelID,
                    thinkingLevel: thinkingLevel,
                    inputs: [source, .text(output, named: "draft-notes.md")] + supplementaryInputs,
                    skills: [.notes]
                ))
                violations = NotesOutputValidator.violations(
                    in: output,
                    source: transcript,
                    language: language
                )
            }
            guard violations.isEmpty else {
                throw InvalidNotesOutput(violations: violations)
            }
            return GeneratedOutput(kind: kind, content: output)
        }

        let prompt: String
        switch kind {
        case .cleanedTranscript:
            prompt = Prompts.cleanedTranscript(rawTranscript: transcript, language: language)
        case .notes:
            prompt = Prompts.notes(cleanedTranscript: transcript, language: language)
        case .flashcards:
            prompt = Prompts.flashcards(cleanedTranscript: transcript, language: language)
        case .quiz:
            prompt = Prompts.quiz(cleanedTranscript: transcript, options: quizOptions, focus: quizFocus, language: language)
        }

        if profile.id == AgentProfiles.antigravityID {
            let antigravityPrompt = effortHint
                + AntigravityACPClient.supplementaryReferenceInstruction(for: supplementaryInputs)
                + prompt
            let modelID = AntigravityACPClient.applyThinking(
                thinkingLevel,
                to: modelOverride ?? profile.model ?? AntigravityACPClient.modelID
            )
            var output = try await AntigravityACPClient.configured(for: profile).run(
                prompt: antigravityPrompt,
                modelID: modelID,
                thinkingLevel: thinkingLevel,
                inputs: supplementaryInputs
            )
            if kind == .flashcards, parseCards(output) == nil {
                output = try await AntigravityACPClient.configured(for: profile).run(
                    prompt: antigravityPrompt + "\n\nReturn ONLY the strict JSON array, with no fences or commentary.",
                    modelID: modelID,
                    thinkingLevel: thinkingLevel,
                    inputs: supplementaryInputs
                )
            } else if kind == .quiz, parseQuestions(output) == nil {
                output = try await AntigravityACPClient.configured(for: profile).run(
                    prompt: antigravityPrompt + "\n\nReturn ONLY the strict quiz JSON array in the specified schema, with no fences or commentary.",
                    modelID: modelID,
                    thinkingLevel: thinkingLevel,
                    inputs: supplementaryInputs
                )
            }
            return GeneratedOutput(kind: kind, content: output)
        }

        let connection = try await ACPConnection.connect(profile: profile)
        defer { connection.shutdown() }
        let session = try await newSession(
            connection: connection,
            profile: profile,
            workspaceDirectory: workspaceDirectory
        )
        await connection.applyGenerationSettings(
            session: session,
            model: modelOverride,
            thinkingLevel: thinkingLevel.rawValue
        )

        var output = try await connection.prompt(sessionID: session.id, text: effortHint + prompt)
        if kind == .flashcards, parseCards(output) == nil {
            output = try await connection.prompt(
                sessionID: session.id,
                text: "Your previous reply was not a strict JSON array of {\"front\",\"back\"} objects. Respond again with ONLY the JSON array, no fences or commentary."
            )
        } else if kind == .quiz, parseQuestions(output) == nil {
            output = try await connection.prompt(
                sessionID: session.id,
                text: "Your previous reply was not a strict JSON array of quiz question objects. Respond again with ONLY the JSON array in the specified schema, no fences or commentary."
            )
        } else if kind == .notes {
            output = NotesMarkdownNormalizer.normalize(output)
            var violations = NotesOutputValidator.violations(
                in: output,
                source: transcript,
                language: language
            )
            if !violations.isEmpty {
                output = NotesMarkdownNormalizer.normalize(try await connection.prompt(
                    sessionID: session.id,
                    text: Prompts.notesRepair(violations: violations)
                ))
                violations = NotesOutputValidator.violations(
                    in: output,
                    source: transcript,
                    language: language
                )
            }
            guard violations.isEmpty else {
                throw InvalidNotesOutput(violations: violations)
            }
        }
        return GeneratedOutput(kind: kind, content: output)
    }

    private nonisolated static func newSession(connection: ACPConnection,
                                               profile: AgentProfile,
                                               workspaceDirectory: URL) async throws -> ACPConnection.SessionInfo {
        do {
            return try await connection.newSession(workingDirectory: workspaceDirectory)
        } catch ACPConnection.ACPError.authRequired(let methods) {
            guard let methodID = profile.authMethodID ?? methods.first else {
                throw ACPConnection.ACPError.authRequired(methods: methods)
            }
            try await connection.authenticate(methodID: methodID)
            return try await connection.newSession(workingDirectory: workspaceDirectory)
        }
    }

    // MARK: - Flashcards

    private nonisolated static func parseCards(_ output: String) -> [(front: String, back: String)]? {
        guard let data = Prompts.extractJSONArray(from: output),
                  let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }

            var array: [[String: Any]]
            if let list = raw as? [[String: Any]] {
                array = list
            } else if let single = raw as? [String: Any] {
                array = [single]
            } else {
                return nil
            }

            let pairs = array.compactMap { entry -> (String, String)? in
                guard let front = entry["front"] as? String,
                      let back = entry["back"] as? String,
                      !front.trimmingCharacters(in: .whitespaces).isEmpty,
                      !back.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return (front, back)
            }
        return pairs.isEmpty ? nil : pairs
    }

    private func storeFlashcards(lecture: Lecture, output: String, context: ModelContext) throws {
        guard let cards = Self.parseCards(output) else {
            throw AnkiConnectClient.BridgeError(message: "Flashcards came back unparseable after one retry.")
        }

        // Replace non-pushed cards; pushed ones stay untouched (they already
        // live in Anki).
        for card in lecture.flashcards where card.syncState != .pushed {
            context.delete(card)
        }
        lecture.flashcards.removeAll { $0.syncState != .pushed }

        for pair in cards {
            let card = Flashcard(front: pair.front, back: pair.back)
            card.lecture = lecture
            lecture.flashcards.append(card)
        }
    }

    // MARK: - Quiz

    private nonisolated static func parseQuestions(_ output: String) -> [[String: Any]]? {
        guard let data = Prompts.extractJSONArray(from: output),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let valid = raw.filter { entry in
                guard let prompt = entry["prompt"] as? String,
                      let answer = entry["answer"] as? String,
                      !prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                      !answer.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

                let kindRaw = entry["kind"] as? String ?? ""
                if kindRaw == "multipleChoice" {
                    guard let options = entry["options"] as? [String],
                          options.count >= 2,
                          options.contains(answer) else { return false }
                    return true
                }
                return kindRaw == "shortAnswer"
        }
        return valid.count == raw.count && !valid.isEmpty ? raw : nil
    }

    private func storeQuiz(lecture: Lecture, output: String) throws {
        guard let rawQuestions = Self.parseQuestions(output) else {
            throw AnkiConnectClient.BridgeError(message: "Quiz came back unparseable after one retry.")
        }

        let questions = rawQuestions.compactMap { entry -> QuizItem? in
            guard let prompt = entry["prompt"] as? String,
                  let answer = entry["answer"] as? String else { return nil }
            let explanation = entry["explanation"] as? String ?? ""
            if entry["kind"] as? String == "multipleChoice",
               let options = entry["options"] as? [String] {
                return QuizItem(prompt: prompt, options: options, answer: answer,
                                explanation: explanation, kind: .multipleChoice)
            }
            return QuizItem(prompt: prompt, answer: answer,
                            explanation: explanation, kind: .shortAnswer)
        }

        // Each run appends a new quiz; existing ones stay untouched.
        let quizID = UUID()
        for question in questions {
            question.quizID = quizID
            question.lecture = lecture
            lecture.quizItems.append(question)
        }
    }

    // MARK: - Storage

    private func upsertArtifact(kind: ArtifactKind, content: String, modelInfo: String, lecture: Lecture, context: ModelContext) {
        if let existing = lecture.artifact(of: kind) {
            existing.content = content
            existing.modelInfo = modelInfo
            existing.generatedAt = Date()
        } else {
            let artifact = Artifact(kind: kind, content: content, modelInfo: modelInfo)
            artifact.lecture = lecture
            lecture.artifacts.append(artifact)
        }
    }

    /// Copies any local image files the agent referenced into the lecture's
    /// attachment folder and rewrites references to absolute paths.
    private func storeNotes(lecture: Lecture, markdown: String, profile: AgentProfile, context: ModelContext) {
        let processed = Self.importReferencedImages(markdown: markdown, lectureID: lecture.persistentModelID)
        upsertArtifact(kind: .notes, content: processed, modelInfo: profile.title, lecture: lecture, context: context)
    }

    static func importReferencedImages(markdown: String, lectureID: PersistentIdentifier) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) else { return markdown }
        let fullRange = NSRange(markdown.startIndex..., in: markdown)

        let attachmentsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Attachments/\(lectureID)", isDirectory: true)

        var output = markdown
        let matches = regex.matches(in: markdown, range: fullRange).reversed()

        for match in matches {
            guard let pathRange = Range(match.range(at: 2), in: markdown) else { continue }
            var reference = String(markdown[pathRange])

            guard !reference.hasPrefix("http"), !reference.hasPrefix("lectern-attachment://") else { continue }
            if reference.hasPrefix("file://"), let url = URL(string: reference) {
                reference = url.path
            }
            guard FileManager.default.fileExists(atPath: reference),
                  let copied = copyIntoAttachments(sourcePath: reference, directory: attachmentsDir) else { continue }

            output = output.replacingCharacters(in: pathRange, with: copied.path)
        }

        return output
    }

    private static func copyIntoAttachments(sourcePath: String, directory: URL) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "." + (sourcePath as NSString).pathExtension)
        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destination.path)
            return destination
        } catch {
            return nil
        }
    }
}
