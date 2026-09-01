import Foundation

struct AntigravityCLI: Sendable {
    static let modelID = "gemini-3.7-flash-high"
    static let displayName = "Gemini 3.7 Flash (High)"
    static let transcriptionModelID = AntigravityCLI.modelID
    static let transcriptionDisplayName = AntigravityCLI.displayName
    static let reasoningEffort = "high"

    /// `agy` 1.1.23 has no disabled value for `--print-timeout`; omitting the
    /// flag restores its five-minute default. The largest Go duration gives
    /// Lectern an effectively unbounded wait while preserving task cancellation.
    static let effectivelyUnlimitedPrintTimeout = "2562047h47m16.854775807s"

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

    typealias CommandRunner = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ workingDirectory: URL
    ) async throws -> Data

    private let executableURL: URL?
    private let skillURLs: [LecternAgentSkill: URL]
    private let commandRunner: CommandRunner

    init(
        executableURL: URL? = nil,
        transcriptionSkillURL: URL? = nil,
        notesSkillURL: URL? = nil,
        commandRunner: @escaping CommandRunner = AntigravityCLI.launch
    ) {
        self.executableURL = executableURL
        var skillURLs: [LecternAgentSkill: URL] = [:]
        skillURLs[.transcription] = transcriptionSkillURL
        skillURLs[.notes] = notesSkillURL
        self.skillURLs = skillURLs
        self.commandRunner = commandRunner
    }

    static func configured(for profile: AgentProfile) -> AntigravityCLI {
        let path = AgentProfiles.resolveExecutable(profile.executablePath)
        return AntigravityCLI(executableURL: path.map(URL.init(fileURLWithPath:)))
    }

    /// Prompts up to this size travel inside `-p` itself, so the agent reads
    /// the task without a file round trip. Longer prompts (a flashcard or
    /// quiz request carrying a full transcript) fall back to `@request.md`.
    static let inlinePromptLimit = 16_000

    /// Builds the top-level print prompt. A leading `/<skill>` slash command
    /// makes `agy` expand the installed skill into the request deterministically
    /// instead of leaving it to discovery, and every input is named at this
    /// level because that is the attachment path the CLI honors.
    static func printPrompt(
        inline prompt: String?,
        inputs: [WorkspaceInput],
        skills: [LecternAgentSkill]
    ) -> String {
        let command = skills.first.map { "/\($0.rawValue) " } ?? ""
        let references = inputs.map { "@\($0.name)" }.joined(separator: " ")
        let attachments = references.isEmpty ? "" : "\n\nAttached inputs: \(references)."
        if let prompt {
            return command + prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                + attachments
                + "\n\nReturn only the requested final output."
        }
        return command + "Follow the instructions in @request.md." + attachments
            + "\n\nReturn only the requested final output."
    }

    static func supplementaryReferenceInstruction(for inputs: [WorkspaceInput]) -> String {
        guard !inputs.isEmpty else { return "" }
        let references = inputs.map { "@\($0.name)" }.joined(separator: ", ")
        return """
        Supplementary reference files are available in this private workspace: \(references).
        Use them to correct uncertain names, terminology, quotations, and recognition errors and to improve the requested study material. Treat lecture-reference files as specific to this lecture and course-reference files as broader context. Do not invent claims or attribute material to the speaker unless the transcript supports it.

        """
    }

    func run(
        prompt: String,
        modelID: String = AntigravityCLI.modelID,
        inputs: [WorkspaceInput] = [],
        skills: Set<LecternAgentSkill> = [],
        jsonSchema: String? = nil,
        timeout: String = AntigravityCLI.effectivelyUnlimitedPrintTimeout
    ) async throws -> String {
        let executable = try resolvedExecutable()
        let workspace = try PrivateWorkspace()
        defer { workspace.remove() }

        for input in inputs {
            try workspace.install(input)
        }
        let orderedSkills = skills.sorted(by: { $0.rawValue < $1.rawValue })
        for skill in orderedSkills {
            try workspace.installSkill(skill, from: resolvedSkillURL(for: skill))
        }

        let printPrompt: String
        if prompt.utf8.count <= Self.inlinePromptLimit {
            printPrompt = Self.printPrompt(inline: prompt, inputs: inputs, skills: orderedSkills)
        } else {
            try workspace.write(Data(prompt.utf8), named: "request.md")
            printPrompt = Self.printPrompt(inline: nil, inputs: inputs, skills: orderedSkills)
        }
        var arguments = [
            "-p", printPrompt,
            "--new-project",
            "--sandbox",
            "--model", modelID,
            "--effort", AntigravityCLI.reasoningEffort,
            "--output-format", "json",
            "--print-timeout", timeout,
        ]
        if let jsonSchema {
            try workspace.write(Data(jsonSchema.utf8), named: "output-schema.json")
            arguments += ["--json-schema", workspace.url.appendingPathComponent("output-schema.json").path]
        }

        let data = try await commandRunner(executable, arguments, workspace.url)
        return try Self.parseResponse(data)
    }

    func availableModels() async throws -> [String] {
        let executable = try resolvedExecutable()
        let data = try await commandRunner(executable, ["models"], FileManager.default.temporaryDirectory)
        return Self.parseModelList(String(decoding: data, as: UTF8.self))
    }

    static func parseModelList(_ output: String) -> [String] {
        parseModels(output).map(\.id)
    }

    static func parseModels(_ output: String) -> [AvailableModel] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let columns = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard let first = columns.first else { return nil }
            let id = String(first)
            guard !id.isEmpty, id != "Fetching" else { return nil }
            let name = columns.count > 1
                ? String(columns[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : id
            return AvailableModel(id: id, name: name.isEmpty ? id : name)
        }
    }

    static func parseResponse(_ data: Data) throws -> String {
        struct Envelope: Decodable {
            let status: String
            let response: String
            let error: String?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw CLIError.invalidResponse("Antigravity CLI returned malformed JSON.")
        }
        guard envelope.status == "SUCCESS" else {
            throw CLIError.failed(sanitize(envelope.error ?? envelope.response))
        }
        let response = envelope.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else {
            throw CLIError.invalidResponse("Antigravity CLI returned an empty response.")
        }
        let normalized = response
            .replacingOccurrences(of: "request. md", with: "request.md", options: .caseInsensitive)
            .lowercased()
        if normalized.contains("request.md"),
           normalized.contains("not found") || normalized.contains("no active workspace") {
            throw CLIError.failed(
                "Antigravity CLI could not access Lectern's private workspace."
            )
        }
        return response
    }

    static func bundledTranscriptionSkillURL(bundle: Bundle = .main) -> URL? {
        LecternAgentSkill.transcription.bundledURL(bundle: bundle)
    }

    static func bundledNotesSkillURL(bundle: Bundle = .main) -> URL? {
        LecternAgentSkill.notes.bundledURL(bundle: bundle)
    }

    private func resolvedExecutable() throws -> URL {
        if let executableURL,
           FileManager.default.isExecutableFile(atPath: executableURL.path) {
            return executableURL
        }
        guard let path = AgentProfiles.resolveExecutable("agy") else {
            throw CLIError.notInstalled
        }
        return URL(fileURLWithPath: path)
    }

    private func resolvedSkillURL(for skill: LecternAgentSkill) throws -> URL {
        if let configured = skillURLs[skill],
           FileManager.default.fileExists(atPath: configured.path) {
            return configured
        }
        guard let bundled = skill.bundledURL() else {
            throw CLIError.skillMissing(skill.rawValue)
        }
        return bundled
    }

    private static func sanitize(_ value: String) -> String {
        let line = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "Antigravity CLI could not complete the request." : String(line.prefix(500))
    }

    private static func launch(
        executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment(workingDirectory: workingDirectory)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let stdoutRead = Task.detached {
            try stdout.fileHandleForReading.readToEnd() ?? Data()
        }
        let stderrRead = Task.detached {
            try stderr.fileHandleForReading.readToEnd() ?? Data()
        }

        do {
            try process.run()
        } catch {
            stdoutRead.cancel()
            stderrRead.cancel()
            throw CLIError.failed(error.localizedDescription)
        }

        let statusTask = Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }
        let status: Int32 = await withTaskCancellationHandler {
            await statusTask.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let output = (try? await stdoutRead.value) ?? Data()
        let diagnosticData = (try? await stderrRead.value) ?? Data()
        try Task.checkCancellation()
        guard status == 0 else {
            let diagnostic = sanitize(String(decoding: diagnosticData, as: UTF8.self))
            throw CLIError.failed(diagnostic)
        }
        return output
    }

    enum CLIError: LocalizedError, Sendable {
        case notInstalled
        case skillMissing(String)
        case invalidWorkspaceFile(String)
        case invalidResponse(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Antigravity CLI (agy) is not installed or is not executable."
            case .skillMissing(let name):
                return "Lectern's \(name) skill is missing from the app bundle."
            case .invalidWorkspaceFile(let name):
                return "Antigravity workspace input \(name) is invalid."
            case .invalidResponse(let message), .failed(let message):
                return message
            }
        }
    }

    static func environment(workingDirectory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extras = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        environment["PATH"] = (extras + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["PWD"] = workingDirectory.path
        return environment
    }
}

private final class PrivateWorkspace: @unchecked Sendable {
    let url: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = fileManager.temporaryDirectory.appendingPathComponent("Lectern-Antigravity", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func install(_ input: AntigravityCLI.WorkspaceInput) throws {
        let name = try safeName(input.name)
        let destination = url.appendingPathComponent(name)
        switch input.contents {
        case .data(let data):
            try data.write(to: destination, options: [.atomic])
        case .file(let source):
            guard source.isFileURL, fileManager.fileExists(atPath: source.path) else {
                throw AntigravityCLI.CLIError.invalidWorkspaceFile(input.name)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func write(_ data: Data, named name: String) throws {
        try install(.data(data, named: name))
    }

    func installSkill(_ skill: LecternAgentSkill, from skillURL: URL) throws {
        let skillDirectory = url
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skill.rawValue, isDirectory: true)
        try fileManager.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try Data(contentsOf: skillURL)
        let destination = skillDirectory.appendingPathComponent("SKILL.md")
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func remove() {
        guard url.path.hasPrefix(fileManager.temporaryDirectory.path),
              url.lastPathComponent != "Lectern-Antigravity" else { return }
        try? fileManager.removeItem(at: url)
    }

    private func safeName(_ proposed: String) throws -> String {
        let name = URL(fileURLWithPath: proposed).lastPathComponent
        guard name == proposed,
              !name.isEmpty,
              name != ".",
              name != ".." else {
            throw AntigravityCLI.CLIError.invalidWorkspaceFile(proposed)
        }
        return name
    }
}
