import Foundation
import CryptoKit

/// Lectern's feature-facing Antigravity provider. It speaks ACP through the
/// managed Google runtime and never shells out to the normal `agy` CLI.
struct AntigravityACPClient: Sendable {
    typealias ConnectionFactory = @Sendable () async throws -> ACPConnection

    static let modelID = "gemini-3.8-flash-high"
    static let displayName = "Gemini 3.8 Flash (High)"
    static let transcriptionModelID = modelID
    static let transcriptionDisplayName = displayName
    static let thinkingLevels: [ThinkingLevel] = [.low, .medium, .high]

    static func effort(for level: ThinkingLevel) -> String {
        switch level {
        case .none, .minimal, .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh, .max, .ultra: return "high"
        }
    }

    static func thinkingLevel(fromModelID id: String) -> ThinkingLevel {
        switch thinkingSuffix(in: id) {
        case "low": return .low
        case "medium": return .medium
        default: return .high
        }
    }

    static func isThinkingVariant(_ id: String) -> Bool {
        thinkingSuffix(in: id) != nil
    }

    static func applyThinking(
        _ level: ThinkingLevel,
        to modelID: String,
        availableIDs: [String] = []
    ) -> String {
        guard let current = thinkingSuffix(in: modelID) else { return modelID }
        let next = "\(String(modelID.dropLast(current.count + 1)))-\(effort(for: level))"
        if availableIDs.isEmpty || availableIDs.contains(next) { return next }
        return modelID
    }

    private static func thinkingSuffix(in id: String) -> String? {
        let pattern = #"^gemini-\d+(?:\.\d+)?-(?:flash|pro)-(low|medium|high)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(id.startIndex..., in: id)
        guard let match = regex.firstMatch(in: id, range: range),
              let suffixRange = Range(match.range(at: 1), in: id) else { return nil }
        return String(id[suffixRange])
    }

    struct AvailableModel: Equatable, Sendable {
        let id: String
        let name: String
    }

    struct WorkspaceInput: Sendable {
        enum Contents: Sendable {
            case data(Data)
            case file(URL)
        }

        let name: String
        let contents: Contents

        static func text(_ text: String, named name: String) -> WorkspaceInput {
            .init(name: name, contents: .data(Data(text.utf8)))
        }

        static func data(_ data: Data, named name: String) -> WorkspaceInput {
            .init(name: name, contents: .data(data))
        }

        static func file(_ url: URL, named name: String) -> WorkspaceInput {
            .init(name: name, contents: .file(url))
        }
    }

    private let connectionFactory: ConnectionFactory
    private let usesManagedProfile: Bool
    private let skillURLOverrides: [LecternAgentSkill: URL]
    private let transcriptionTimeout: Duration?
    private let sessionPool: AISessionPool

    init(
        connectionFactory: ConnectionFactory? = nil,
        skillURLOverrides: [LecternAgentSkill: URL] = [:],
        transcriptionTimeout: Duration? = nil,
        sessionPool: AISessionPool = .shared
    ) {
        self.usesManagedProfile = connectionFactory == nil
        self.connectionFactory = connectionFactory ?? {
            try await AntigravityACPManager.shared.makeConnection()
        }
        self.skillURLOverrides = skillURLOverrides
        self.transcriptionTimeout = transcriptionTimeout
        self.sessionPool = sessionPool
    }

    static func configured(for profile: AgentProfile) -> AntigravityACPClient {
        AntigravityACPClient()
    }

    static func supplementaryReferenceInstruction(for inputs: [WorkspaceInput]) -> String {
        guard !inputs.isEmpty else { return "" }
        let references = inputs.map(\.name).joined(separator: ", ")
        return """
        Supplementary reference files are attached: \(references).
        Use them to correct uncertain names, terminology, quotations, and recognition errors and to improve the requested study material. Treat lecture-reference files as specific to this lecture and course-reference files as broader context. Do not invent claims or attribute material to the speaker unless the transcript supports it.

        """
    }

    func run(
        prompt: String,
        modelID: String = AntigravityACPClient.modelID,
        thinkingLevel: ThinkingLevel = .high,
        inputs: [WorkspaceInput] = [],
        skills: Set<LecternAgentSkill> = [],
        jsonSchema: String? = nil,
        transcriptionDuration: Double? = nil
    ) async throws -> String {
        try await sessionPool.withPermit {
            try await runSession(prompt: prompt, modelID: modelID, thinkingLevel: thinkingLevel,
                                 inputs: inputs, skills: skills, jsonSchema: jsonSchema,
                                 transcriptionDuration: transcriptionDuration)
        }
    }

    func transcriptionSkillFingerprint() throws -> String {
        let data = try Data(contentsOf: resolvedSkillURL(for: .transcription))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func concurrentSessionLimit() async -> Int { await sessionPool.limit }

    private func runSession(
        prompt: String,
        modelID: String = AntigravityACPClient.modelID,
        thinkingLevel: ThinkingLevel = .high,
        inputs: [WorkspaceInput] = [],
        skills: Set<LecternAgentSkill> = [],
        jsonSchema: String? = nil,
        transcriptionDuration: Double? = nil
    ) async throws -> String {
        let connection = try await usesManagedProfile
            ? AntigravityACPManager.shared.makeConnection(transcriptionOnly: transcriptionDuration != nil)
            : connectionFactory()
        defer { connection.shutdown() }
        if transcriptionDuration != nil { connection.restrictToTranscription() }
        // A sleeping deadline costs no polling and cannot consume time waiting
        // for the shared session permit. Leave ample room for high reasoning.
        let deadline = transcriptionDuration.map { duration in
            Task {
                try? await Task.sleep(for: transcriptionTimeout ?? .seconds(max(900, min(7_200, duration * 3))))
                guard !Task.isCancelled else { return }
                connection.shutdown(error: ACPConnection.ACPError.transcriptionStopped("Antigravity timed out transcribing this audio part.", reason: .timeout))
            }
        }
        defer { deadline?.cancel() }

        do {
            try await connection.authenticate(methodID: "oauth-personal")
        } catch ACPConnection.ACPError.authRequired {
            throw AntigravityACPError.authenticationFailed(
                "Sign in to Antigravity in Lectern Settings before you continue."
            )
        }

        let workspace = try AntigravityACPWorkingDirectory()
        defer { workspace.remove() }
        let session = try await connection.newSession(workingDirectory: workspace.url)
        if transcriptionDuration != nil, session.availableModeIDs.contains("default") {
            try await connection.requireMode(sessionID: session.id, modeID: "default")
        } else if transcriptionDuration != nil, !session.availableModeIDs.isEmpty {
            throw ACPConnection.ACPError.transcriptionStopped("Antigravity did not offer its default mode for transcription.", reason: .configuration)
        }
        try await connection.applyAntigravityGenerationSettings(
            session: session,
            model: modelID,
            thinkingLevel: Self.effort(for: thinkingLevel)
        )

        var instructionParts: [String] = []
        for skill in skills.sorted(by: { $0.rawValue < $1.rawValue }) {
            let url = try resolvedSkillURL(for: skill)
            let instructions = try String(contentsOf: url, encoding: .utf8)
            instructionParts.append("Instructions from /\(skill.rawValue):\n\(instructions)")
        }
        instructionParts.append(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        if let jsonSchema {
            instructionParts.append("Return JSON matching this schema exactly:\n\(jsonSchema)")
        }
        if !inputs.isEmpty {
            instructionParts.append(
                "The following named inputs are attached natively: "
                    + inputs.map(\.name).joined(separator: ", ") + "."
            )
        }
        instructionParts.append("Return only the requested final output.")

        var blocks: [AntigravityACPContent.Block] = [.text(instructionParts.joined(separator: "\n\n"))]
        var attachmentBytes = 0
        for input in inputs {
            let content: AntigravityACPContent.Input
            switch input.contents {
            case .data(let data):
                attachmentBytes += data.count
                content = .data(data, named: input.name)
            case .file(let url):
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                attachmentBytes += values.fileSize ?? 0
                content = .file(url, named: input.name)
            }
            guard attachmentBytes <= AntigravityACPContent.maximumTotalBytes else {
                throw AntigravityACPError.unsupportedAttachment(
                    "Antigravity accepts at most 50 MiB of attachments per request."
                )
            }
            blocks.append(try AntigravityACPContent.block(for: content))
        }
        return try await connection.prompt(sessionID: session.id, blocks: blocks)
    }

    func availableModels() async throws -> [String] {
        try await availableModelEntries().map(\.id)
    }

    func availableModelEntries() async throws -> [AvailableModel] {
        let connection = try await connectionFactory()
        defer { connection.shutdown() }
        do {
            try await connection.authenticate(methodID: "oauth-personal")
        } catch ACPConnection.ACPError.authRequired {
            throw AntigravityACPError.authenticationFailed(
                "Sign in to Antigravity in Lectern Settings before loading models."
            )
        }
        let session = try await connection.newSession(workingDirectory: FileManager.default.temporaryDirectory)
        if let option = session.option(category: "model"), !option.values.isEmpty {
            return option.values.map { AvailableModel(id: $0.id, name: $0.name) }
        }
        return session.availableModelIDs.map { AvailableModel(id: $0, name: $0) }
    }

    private func resolvedSkillURL(for skill: LecternAgentSkill) throws -> URL {
        if let override = skillURLOverrides[skill] {
            return override
        }
        guard let bundled = skill.bundledURL() else {
            throw AntigravityACPError.invalidInstallation(
                "Lectern's \(skill.rawValue) skill is missing from the app bundle."
            )
        }
        return bundled
    }
}

private final class AntigravityACPWorkingDirectory: @unchecked Sendable {
    let url: URL

    init(fileManager: FileManager = .default) throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("Lectern-Antigravity-ACP", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove(fileManager: FileManager = .default) {
        guard url.path.hasPrefix(fileManager.temporaryDirectory.path),
              url.lastPathComponent != "Lectern-Antigravity-ACP" else { return }
        try? fileManager.removeItem(at: url)
    }
}
