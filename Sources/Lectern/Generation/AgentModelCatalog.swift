import Foundation

/// One selectable model from an agent's live catalog.
struct AgentModel: Identifiable, Hashable, Codable, Sendable {
    /// Wire id sent to the agent (`gpt-5.6-sol`, `openai/gpt-5.6-sol`).
    var id: String
    var name: String
    /// Provider grouping for OpenCode (`OpenAI`, `Nvidia`). Nil for Codex.
    var provider: String?
    var isDefault: Bool
    var supportedThinkingLevels: [ThinkingLevel] = []
    var defaultThinkingLevel: ThinkingLevel?

    var searchText: String {
        [id, name, provider].compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

struct AgentModelCatalog: Sendable {
    var models: [AgentModel]
    var currentID: String?

    static let empty = AgentModelCatalog(models: [], currentID: nil)
}

/// Loads the models ChatGPT (Codex) and OpenCode actually expose, the same
/// way T3 Code does: Codex `app-server` `model/list`, OpenCode `opencode models`
/// filtered to signed-in providers.
enum AgentModelCatalogLoader {
    private static let cacheTTL: TimeInterval = 5 * 60
    private static let mutex = Mutex()
    nonisolated(unsafe) private static var memory: [String: (fetchedAt: Date, catalog: AgentModelCatalog)] = [:]

    static func load(for profile: AgentProfile) async -> AgentModelCatalog {
        if let cached = mutex.with({ memory[profile.id] }),
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.catalog
        }

        let catalog: AgentModelCatalog
        switch profile.id {
        case AgentProfiles.codexID:
            catalog = await firstNonEmptyCatalog {
                try await loadCodex(profile: profile)
            } or: {
                try await loadFromACP(profile: profile)
            }
        case AgentProfiles.opencodeID:
            catalog = await firstNonEmptyCatalog {
                try await loadOpenCode(profile: profile)
            } or: {
                try await loadFromACP(profile: profile)
            }
        case AgentProfiles.antigravityID:
            catalog = await loadAntigravity(profile: profile)
        default:
            catalog = .empty
        }

        if !catalog.models.isEmpty {
            mutex.with { memory[profile.id] = (Date(), catalog) }
        }
        return catalog
    }

    private static func firstNonEmptyCatalog(
        _ primary: () async throws -> AgentModelCatalog,
        or fallback: () async throws -> AgentModelCatalog
    ) async -> AgentModelCatalog {
        if let loaded = try? await primary(), !loaded.models.isEmpty {
            return loaded
        }
        if let loaded = try? await fallback(), !loaded.models.isEmpty {
            return loaded
        }
        return .empty
    }

    // MARK: - Codex (ChatGPT)

    /// Probe `codex app-server` with `model/list`, paginating on `nextCursor`.
    static func loadCodex(profile: AgentProfile) async throws -> AgentModelCatalog {
        guard let executable = resolveCodexCLI(from: profile) else {
            throw CatalogError.missingCLI("codex")
        }

        let client = try JSONRPCProcess.spawn(
            executable: executable,
            arguments: ["app-server"],
            timeout: 12
        )
        defer { client.shutdown() }

        _ = try await client.request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "lectern",
                    "title": "Lectern",
                    "version": "0.1.0",
                ],
                "capabilities": ["experimentalApi": true],
            ]
        )
        client.notify(method: "initialized", params: [:])

        var models: [AgentModel] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await client.request(method: "model/list", params: params)
            let page = parseCodexModelList(result)
            models.append(contentsOf: page.models)
            cursor = page.nextCursor
        } while cursor != nil && !cursor!.isEmpty

        return AgentModelCatalog(models: models, currentID: models.first(where: \.isDefault)?.id)
    }

    struct CodexPage {
        var models: [AgentModel]
        var nextCursor: String?
    }

    static func parseCodexModelList(_ result: Any) -> CodexPage {
        guard let dict = result as? [String: Any] else {
            return CodexPage(models: [], nextCursor: nil)
        }
        let rows = dict["data"] as? [[String: Any]] ?? []
        let models: [AgentModel] = rows.compactMap { row in
            if row["hidden"] as? Bool == true { return nil }
            let id = (row["model"] as? String) ?? (row["id"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let display = (row["displayName"] as? String)?.trimmingCharacters(in: .whitespaces)
            return AgentModel(
                id: id,
                name: (display?.isEmpty == false ? display! : id),
                provider: nil,
                isDefault: row["isDefault"] as? Bool ?? false,
                supportedThinkingLevels: ((row["supportedReasoningEfforts"] as? [[String: Any]]) ?? [])
                    .compactMap { option in
                        (option["reasoningEffort"] as? String).flatMap(ThinkingLevel.advertised)
                    },
                defaultThinkingLevel: (row["defaultReasoningEffort"] as? String)
                    .flatMap(ThinkingLevel.advertised)
            )
        }
        let cursor = dict["nextCursor"] as? String
        return CodexPage(models: models, nextCursor: cursor?.isEmpty == true ? nil : cursor)
    }

    static func resolveCodexCLI(from profile: AgentProfile) -> String? {
        if let found = AgentProfiles.resolveExecutable("codex") { return found }

        let spawn = profile.executablePath
        if spawn.hasSuffix("codex-acp") {
            let candidate = String(spawn.dropLast("codex-acp".count)) + "codex"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if spawn.lowercased().contains("codex"), FileManager.default.isExecutableFile(atPath: spawn) {
            return spawn
        }
        return nil
    }

    // MARK: - OpenCode

    static func loadOpenCode(profile: AgentProfile) async throws -> AgentModelCatalog {
        guard let executable = AgentProfiles.resolveExecutable(profile.executablePath) else {
            throw CatalogError.missingCLI("opencode")
        }

        let stdout = try await runProcess(
            executable: executable,
            arguments: ["models"],
            timeout: 20
        )
        let allowed = openCodeConnectedProviders()
        let models = parseOpenCodeModels(stdout: stdout, allowedProviders: allowed)
        return AgentModelCatalog(models: models, currentID: models.first?.id)
    }

    /// Provider ids OpenCode is signed into, plus the built-in `opencode` catalog.
    static func openCodeConnectedProviders(authJSON: Data? = nil) -> Set<String>? {
        let data: Data?
        if let authJSON {
            data = authJSON
        } else {
            data = try? Data(contentsOf: openCodeAuthURL())
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var ids = Set(object.keys.map { $0.lowercased() }.filter { !$0.isEmpty })
        ids.insert("opencode")
        return ids.isEmpty ? nil : ids
    }

    static func parseOpenCodeModels(stdout: String, allowedProviders: Set<String>?) -> [AgentModel] {
        var models: [AgentModel] = []
        var seen = Set<String>()
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let slug = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard slug.contains("/"), !slug.hasPrefix("┌"), !slug.hasPrefix("│"), !slug.hasPrefix("└") else {
                continue
            }
            let slash = slug.firstIndex(of: "/")!
            let providerID = String(slug[..<slash]).lowercased()
            if let allowedProviders, !allowedProviders.contains(providerID) {
                continue
            }
            if seen.contains(slug) { continue }
            seen.insert(slug)
            let remainder = String(slug[slug.index(after: slash)...])
            models.append(AgentModel(
                id: slug,
                name: remainder,
                provider: titleCaseProvider(providerID),
                isDefault: false
            ))
        }
        return models.sorted { lhs, rhs in
            let lp = providerRank(lhs.provider)
            let rp = providerRank(rhs.provider)
            if lp != rp { return lp < rp }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Antigravity ACP

    static func loadAntigravity(profile: AgentProfile) async -> AgentModelCatalog {
        let fallback = AgentModel(
            id: AntigravityACPClient.modelID,
            name: AntigravityACPClient.displayName,
            provider: "Google",
            isDefault: true,
            supportedThinkingLevels: AntigravityACPClient.thinkingLevels,
            defaultThinkingLevel: .high
        )
        guard let available = try? await AntigravityACPClient.configured(for: profile).availableModelEntries(),
              !available.isEmpty else {
            return .init(models: [fallback], currentID: fallback.id)
        }

        // Keep a saved selection even when Google stops advertising it. The
        // picker then has no matching row and generation reports that the user
        // must choose an available model; it never silently changes accounts/models.
        let preferredID = profile.model ?? available.first(where: {
            $0.id == AntigravityACPClient.modelID
        })?.id
        let models = available.map { listing in
            let thinkingVariant = AntigravityACPClient.isThinkingVariant(listing.id)
            return AgentModel(
                id: listing.id,
                name: listing.name,
                provider: antigravityProviderName(for: listing.id),
                isDefault: listing.id == preferredID,
                supportedThinkingLevels: thinkingVariant ? AntigravityACPClient.thinkingLevels : [],
                defaultThinkingLevel: thinkingVariant ? AntigravityACPClient.thinkingLevel(fromModelID: listing.id) : nil
            )
        }
        return .init(models: models, currentID: preferredID)
    }

    private static func antigravityProviderName(for modelID: String) -> String? {
        if modelID.hasPrefix("gemini-") { return "Google" }
        if modelID.hasPrefix("claude-") { return "Anthropic" }
        if modelID.hasPrefix("gpt-") { return "OpenAI" }
        return nil
    }

    /// Last-resort catalog: the models the ACP agent itself advertises.
    static func loadFromACP(profile: AgentProfile) async throws -> AgentModelCatalog {
        let connection = try await ACPConnection.connect(profile: profile)
        defer { connection.shutdown() }

        let cwd = FileManager.default.temporaryDirectory
        let session: ACPConnection.SessionInfo
        do {
            session = try await connection.newSession(workingDirectory: cwd)
        } catch ACPConnection.ACPError.authRequired(let methods) {
            guard let methodID = profile.authMethodID ?? methods.first else {
                throw ACPConnection.ACPError.authRequired(methods: methods)
            }
            try await connection.authenticate(methodID: methodID)
            session = try await connection.newSession(workingDirectory: cwd)
        }

        let allowed = profile.id == AgentProfiles.opencodeID ? openCodeConnectedProviders() : nil
        return catalogFromSession(session, allowedProviders: allowed)
    }

    static func catalogFromSession(_ session: ACPConnection.SessionInfo,
                                   allowedProviders: Set<String>?) -> AgentModelCatalog {
        guard let option = session.option(category: "model"), !option.values.isEmpty else {
            return .empty
        }
        let thoughtOption = session.option(category: "thought_level")
        let supportedThinkingLevels = thoughtOption?.values.compactMap {
            ThinkingLevel.advertised($0.id == "extra-high" ? "xhigh" : $0.id)
        } ?? []
        let defaultThinkingLevel = thoughtOption?.currentValue.flatMap {
            ThinkingLevel.advertised($0 == "extra-high" ? "xhigh" : $0)
        }
        var models: [AgentModel] = option.values.compactMap { value in
            if let allowedProviders, let slash = value.id.firstIndex(of: "/") {
                let providerID = String(value.id[..<slash]).lowercased()
                if !allowedProviders.contains(providerID) { return nil }
            }
            let provider: String?
            let name: String
            if let slash = value.id.firstIndex(of: "/") {
                provider = titleCaseProvider(String(value.id[..<slash]))
                let remainder = String(value.id[value.id.index(after: slash)...])
                name = value.name.isEmpty ? remainder : value.name
            } else {
                provider = nil
                name = value.name.isEmpty ? value.id : value.name
            }
            return AgentModel(
                id: value.id,
                name: name,
                provider: provider,
                isDefault: value.id == option.currentValue,
                supportedThinkingLevels: supportedThinkingLevels,
                defaultThinkingLevel: defaultThinkingLevel
            )
        }
        if allowedProviders != nil, models.isEmpty {
            models = option.values.map { value in
                AgentModel(
                    id: value.id,
                    name: value.name,
                    provider: nil,
                    isDefault: value.id == option.currentValue,
                    supportedThinkingLevels: supportedThinkingLevels,
                    defaultThinkingLevel: defaultThinkingLevel
                )
            }
        }
        return AgentModelCatalog(models: models, currentID: option.currentValue)
    }

    private static func providerRank(_ provider: String?) -> Int {
        switch provider?.lowercased() {
        case "opencode": return 0
        case "openai": return 1
        case "google": return 2
        default: return 3
        }
    }

    static func titleCaseProvider(_ id: String) -> String {
        switch id.lowercased() {
        case "openai": return "OpenAI"
        case "opencode": return "OpenCode"
        case "google": return "Google"
        default:
            return id.split(separator: "-").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: "-")
        }
    }

    private static func openCodeAuthURL() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    // MARK: - Process helpers

    enum CatalogError: LocalizedError {
        case missingCLI(String)
        case processFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .missingCLI(let name): return "\(name) is not installed."
            case .processFailed(let detail): return detail
            case .timeout: return "Timed out asking the agent for its model list."
            }
        }
    }

    private static func runProcess(executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = agentEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = Pipe()

            let box = CompletionBox<String>()
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    box.resume(returning: text, continuation)
                } else {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    box.resume(throwing: CatalogError.processFailed(err.isEmpty ? "\(executable) exited \(proc.terminationStatus)" : err), continuation)
                }
            }

            do {
                try process.run()
            } catch {
                box.resume(throwing: CatalogError.processFailed(error.localizedDescription), continuation)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    box.resume(throwing: CatalogError.timeout, continuation)
                }
            }
        }
    }

    static func agentEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extras = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        environment["PATH"] = (extras + [environment["PATH"] ?? ""]).joined(separator: ":")
        return environment
    }
}

/// Minimal newline-delimited JSON-RPC 2.0 client over a child process stdio.
final class JSONRPCProcess: @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let mutex = Mutex()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private let timeout: TimeInterval

    static func spawn(executable: String, arguments: [String], timeout: TimeInterval) throws -> JSONRPCProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = AgentModelCatalogLoader.agentEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let client = JSONRPCProcess(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            timeout: timeout
        )
        client.startReading(stdoutPipe.fileHandleForReading)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        return client
    }

    private init(process: Process, stdinHandle: FileHandle, timeout: TimeInterval) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.timeout = timeout
    }

    func request(method: String, params: [String: Any]?) async throws -> Any {
        let id: Int = mutex.with {
            let id = nextID
            nextID += 1
            return id
        }
        var envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { envelope["params"] = params }
        return try await withCheckedThrowingContinuation { continuation in
            mutex.with { pending[id] = continuation }
            do {
                try write(envelope)
            } catch {
                let stale = mutex.with { pending.removeValue(forKey: id) }
                stale?.resume(throwing: error)
                return
            }
            let timeout = self.timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let stale = self.mutex.with { self.pending.removeValue(forKey: id) }
                stale?.resume(throwing: AgentModelCatalogLoader.CatalogError.timeout)
            }
        }
    }

    func notify(method: String, params: [String: Any]?) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { envelope["params"] = params }
        try? write(envelope)
    }

    func shutdown() {
        let waiters: [CheckedContinuation<Any, Error>] = mutex.with {
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        waiters.forEach { $0.resume(throwing: AgentModelCatalogLoader.CatalogError.processFailed("Process closed")) }
        if process.isRunning { process.terminate() }
    }

    private func write(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else {
            throw AgentModelCatalogLoader.CatalogError.processFailed("Invalid JSON-RPC payload")
        }
        data.append(0x0A)
        stdinHandle.write(data)
    }

    private func startReading(_ handle: FileHandle) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            for line in buffer.append(data) {
                self.handleLine(line)
            }
        }
    }

    private func handleLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let id = jsonRPCID(obj["id"]) else { return }
        let call = mutex.with { pending.removeValue(forKey: id) }
        guard let call else { return }
        if let errorDict = obj["error"] as? [String: Any] {
            let message = errorDict["message"] as? String ?? "JSON-RPC error"
            call.resume(throwing: AgentModelCatalogLoader.CatalogError.processFailed(message))
        } else {
            call.resume(returning: obj["result"] as Any)
        }
    }
}

private func jsonRPCID(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

/// One-shot resume guard so a process timeout and terminationHandler can't
/// both complete the same continuation.
private final class CompletionBox<T>: @unchecked Sendable {
    private let mutex = Mutex()
    private var finished = false

    func resume(returning value: sending T, _ continuation: CheckedContinuation<T, Error>) {
        let go = mutex.with { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if go { continuation.resume(returning: value) }
    }

    func resume(throwing error: Error, _ continuation: CheckedContinuation<T, Error>) {
        let go = mutex.with { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if go { continuation.resume(throwing: error) }
    }
}
