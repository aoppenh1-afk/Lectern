import Foundation

/// Uses the student's existing ACP account. The model returns content; Lectern saves it.
enum NotesStyleLearningService {
    typealias Request = @Sendable (String, AgentProfile, ThinkingLevel, String?) async throws -> String

    static func learn(samples: [NotesStyleSample], adjustments: String, profile: AgentProfile,
                      thinkingLevel: ThinkingLevel = .medium, model: String? = nil,
                      request: Request = run) async throws -> NotesStyleDraft {
        let samples = try NotesStyleDraft.validatedSamples(samples)
        guard adjustments.count <= 4_000 else {
            throw NotesStyleError.invalid("Keep style adjustments to at most 4,000 characters.")
        }
        let prompt = try NotesStylePrompts.creation(samples: samples, adjustments: adjustments)
        let output = try await request(prompt, profile, thinkingLevel, model)
        try Task.checkCancellation()
        do {
            return try NotesStyleDraft.parse(output, samples: samples)
        } catch {
            // One bounded repair carries the same examples and the original creation contract.
            let repaired = try await request(prompt + "\n\nYour previous response failed validation: "
                + error.localizedDescription + "\nReturn the valid JSON object now. Use exact excerpts from the samples.",
                profile, thinkingLevel, model)
            try Task.checkCancellation()
            return try NotesStyleDraft.parse(repaired, samples: samples)
        }
    }

    static func preview(draft: NotesStyleDraft, samples: [NotesStyleSample], profile: AgentProfile,
                        thinkingLevel: ThinkingLevel = .medium, model: String? = nil,
                        request: Request = run) async throws -> String {
        let personal = try PersonalNotesStyle(draft: draft, samples: samples,
                                             creatorAgent: profile.title, creatorModel: model ?? profile.model)
        let style = NotesStyleSnapshot(personal: personal)
        let prompt = Prompts.notes(cleanedTranscript: NotesStylePrompts.previewTranscript,
                                   skillInstructions: style.instructions)
        var output = NotesMarkdownNormalizer.normalize(try await request(prompt, profile, thinkingLevel, model))
        try Task.checkCancellation()
        var failures = NotesOutputValidator.violations(in: output, source: NotesStylePrompts.previewTranscript,
                                                       language: .english, personalStyle: true)
        if !failures.isEmpty {
            output = NotesMarkdownNormalizer.normalize(try await request(
                prompt + "\n\n" + Prompts.notesRepair(violations: failures, style: style), profile, thinkingLevel, model))
            try Task.checkCancellation()
            failures = NotesOutputValidator.violations(in: output, source: NotesStylePrompts.previewTranscript,
                                                       language: .english, personalStyle: true)
        }
        guard failures.isEmpty else { throw NotesStyleError.invalid(failures.joined(separator: " ")) }
        return output
    }

    static func run(_ prompt: String, profile: AgentProfile, thinkingLevel: ThinkingLevel,
                    model: String?) async throws -> String {
        try Task.checkCancellation()
        if profile.id == AgentProfiles.antigravityID {
            return try await AntigravityACPClient.configured(for: profile).run(
                prompt: prompt, modelID: AntigravityACPClient.applyThinking(
                    thinkingLevel, to: model ?? profile.model ?? AntigravityACPClient.modelID),
                thinkingLevel: thinkingLevel)
        }
        return try await AISessionPool.shared.withPermit {
            let connection = try await ACPConnection.connect(profile: profile)
            defer { connection.shutdown() }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Lectern-Style-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let session: ACPConnection.SessionInfo
            do {
                session = try await connection.newSession(workingDirectory: directory)
            } catch ACPConnection.ACPError.authRequired(let methods) {
                guard let method = profile.authMethodID ?? methods.first else { throw ACPConnection.ACPError.authRequired(methods: methods) }
                try await connection.authenticate(methodID: method)
                session = try await connection.newSession(workingDirectory: directory)
            }
            try await connection.applyGenerationSettings(session: session, model: model ?? profile.model,
                                                           thinkingLevel: thinkingLevel.rawValue)
            return try await connection.prompt(sessionID: session.id, text: prompt)
        }
    }
}
