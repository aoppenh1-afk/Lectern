import Foundation
import Darwin

/// One spawned ACP agent process speaking newline-delimited JSON-RPC 2.0
/// over stdio. All I/O and state is confined to internal serial queues; the
/// public API is async and safe to call from anywhere.
final class ACPConnection: @unchecked Sendable {
    enum TranscriptionStopReason: String, Sendable {
        case offTask, timeout, outputLimit, incompleteOutput, configuration
    }
    enum ACPError: LocalizedError {
        case spawnFailed(String)
        case connectionClosed
        case requestFailed(code: Int, message: String)
        case authRequired(methods: [String])
        case unexpectedResponse
        case transcriptionStopped(String, reason: TranscriptionStopReason = .offTask)

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let detail): return "Could not launch agent: \(detail)"
            case .connectionClosed: return "Agent process exited unexpectedly."
            case .requestFailed(_, let message): return message
            case .authRequired(let methods): return "Authentication required (\(methods.joined(separator: ", ")))."
            case .unexpectedResponse: return "Agent returned an unexpected response."
            case .transcriptionStopped(let message, _): return message
            }
        }
    }

    struct AgentIdentity: @unchecked Sendable {
        var name: String
        var version: String
    }

    struct Initialization: Sendable {
        let protocolVersion: Int
        let supportsLoadSession: Bool
        let supportsResume: Bool
        let supportsLogout: Bool
        let authMethodIDs: [String]
    }

    private final class StringAccumulator: @unchecked Sendable {
        private let mutex = Mutex()
        private var chunks: [String] = []
        private let onChunk: (@Sendable (String) -> Void)?

        init(onChunk: (@Sendable (String) -> Void)? = nil) {
            self.onChunk = onChunk
        }

        var value: String { mutex.with { chunks.joined() } }
        func append(_ piece: String) {
            mutex.with { chunks.append(piece) }
            onChunk?(piece)
        }
    }

    private let mutex = Mutex()
    private var nextRequestID = 1
    private var pending: [Int: PendingCall] = [:]
    private var isClosed = false
    private var transcriptionOnly = false
    private var closeError: Error = ACPError.connectionClosed
    private var transcriptionOutputBytes = 0
    private var transcriptionFailure: ACPError?

    /// This is a protocol policy, not a sandbox for the agent's native tools.
    func restrictToTranscription() {
        mutex.with { transcriptionOnly = true }
    }

    func requireMode(sessionID: String, modeID: String) async throws {
        _ = try await request(method: "session/set_mode", params: ["sessionId": sessionID, "modeId": modeID])
    }
    private var chunkBuffers: [String: StringAccumulator] = [:]

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutQueue = DispatchQueue(label: "com.lectern.acp.stdout")
    private let writeQueue = DispatchQueue(label: "com.lectern.acp.write")
    private let stderrTail = StderrTail()
    private let onAuthorizationURL: (@Sendable (URL) -> Void)?
    private let onSessionCreated: (@Sendable (String) -> Void)?
    private let onClose: (@Sendable () -> Void)?
    private var didNotifyClose = false

    private(set) var identity: AgentIdentity?
    private(set) var initialization: Initialization?

    private final class PendingCall: @unchecked Sendable {
        let continuation: CheckedContinuation<Any, Error>
        init(continuation: CheckedContinuation<Any, Error>) {
            self.continuation = continuation
        }
    }

    // MARK: - Spawn + handshake

    static func connect(profile: AgentProfile) async throws -> ACPConnection {
        guard let executable = AgentProfiles.resolveExecutable(profile.executablePath) else {
            throw ACPError.spawnFailed("\(profile.executablePath) not found")
        }

        let environment = spawnEnvironment(profile: profile)
        return try await connect(
            executableURL: URL(fileURLWithPath: executable),
            arguments: profile.arguments,
            environment: environment
        )
    }

    static func spawnEnvironment(
        profile: AgentProfile,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        if profile.id == AgentProfiles.codexID,
           let codex = AgentModelCatalogLoader.resolveCodexCLI(from: profile, environment: environment) {
            environment["CODEX_PATH"] = codex
        }
        return environment
    }

    static func connect(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        transcriptionOnly: Bool = false,
        onAuthorizationURL: (@Sendable (URL) -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil,
        onSessionCreated: (@Sendable (String) -> Void)? = nil,
        onProcessExit: (@Sendable () -> Void)? = nil
    ) async throws -> ACPConnection {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ACPError.spawnFailed(error.localizedDescription)
        }

        let connection = ACPConnection(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stderrPipe: stderrPipe,
            onAuthorizationURL: onAuthorizationURL,
            onClose: onClose,
            onSessionCreated: onSessionCreated,
            onProcessExit: onProcessExit
        )
        if transcriptionOnly { connection.restrictToTranscription() }
        connection.startReading(stdoutPipe.fileHandleForReading)

        let initializeTimeout = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            connection.shutdown()
        }
        defer { initializeTimeout.cancel() }

        do {
            let result = try await connection.request(
                method: "initialize",
                params: [
                    "protocolVersion": 1,
                    "clientCapabilities": [
                        "fs": ["readTextFile": false, "writeTextFile": false],
                        "terminal": false,
                    ],
                    "clientInfo": ["name": "lectern", "title": "Lectern", "version": "0.1.0"],
                ]
            )

            if let dict = result as? [String: Any] {
                let info = dict["agentInfo"] as? [String: Any]
                let capabilities = dict["agentCapabilities"] as? [String: Any]
                let sessions = capabilities?["sessionCapabilities"] as? [String: Any]
                let auth = capabilities?["auth"] as? [String: Any]
                let methods = dict["authMethods"] as? [[String: Any]] ?? []
                connection.mutex.with {
                    connection.identity = AgentIdentity(
                        name: info?["name"] as? String ?? "agent",
                        version: info?["version"] as? String ?? "?"
                    )
                    connection.initialization = Initialization(
                        protocolVersion: dict["protocolVersion"] as? Int ?? 0,
                        supportsLoadSession: capabilities?["loadSession"] as? Bool ?? false,
                        supportsResume: capabilityIsSupported(sessions?["resume"]),
                        supportsLogout: capabilityIsSupported(auth?["logout"]),
                        authMethodIDs: methods.compactMap { $0["id"] as? String }
                    )
                }
            }

            return connection
        } catch {
            connection.shutdown()
            throw error
        }
    }

    /// ACP represents some capabilities as configuration objects rather than
    /// Boolean flags. Google currently advertises `resume` and `logout` as
    /// empty objects, matching the protocol schema used by T3 Code.
    private static func capabilityIsSupported(_ value: Any?) -> Bool {
        if let boolean = value as? Bool { return boolean }
        return value is [String: Any]
    }

    private init(
        process: Process,
        stdinHandle: FileHandle,
        stderrPipe: Pipe,
        onAuthorizationURL: (@Sendable (URL) -> Void)?,
        onClose: (@Sendable () -> Void)?,
        onSessionCreated: (@Sendable (String) -> Void)?,
        onProcessExit: (@Sendable () -> Void)?
    ) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.onAuthorizationURL = onAuthorizationURL
        self.onClose = onClose
        self.onSessionCreated = onSessionCreated

        // ACP 1.1.1 emits OAuth links on stderr; the browser helper does too.
        let stderrLines = LineBuffer(maximumLineBytes: 16_512)
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in stderrLines.append(data) {
                self?.stdoutQueue.async { [weak self] in
                    guard let self else { return }
                    if !handleAuthorizationLine(line) {
                        stderrTail.append(String(decoding: line, as: UTF8.self) + "\n")
                    }
                }
            }
        }

        let exitCallback = ProcessExitCallback(onProcessExit)
        process.terminationHandler = { [weak self] _ in
            self?.processDidExit()
            exitCallback.run()
        }
        if !process.isRunning {
            processDidExit()
            exitCallback.run()
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
        notifyClosed()
    }

    // MARK: - Sessions

    struct ConfigOption {
        let id: String
        let category: String?
        let currentValue: String?
        let values: [ConfigValue]
    }

    struct ConfigValue {
        let id: String
        let name: String
    }

    struct SessionInfo {
        let id: String
        let availableModeIDs: [String]
        let configOptions: [ConfigOption]
        let availableModelIDs: [String]
        let currentModelID: String?
    }

    func newSession(workingDirectory: URL) async throws -> SessionInfo {
        do {
            let result = try await request(
                method: "session/new",
                params: ["cwd": workingDirectory.path, "mcpServers": [] as [Any]]
            )
            guard let dict = result as? [String: Any],
                  let sessionID = dict["sessionId"] as? String else {
                throw ACPError.unexpectedResponse
            }
            onSessionCreated?(sessionID)
            return SessionInfo.parse(sessionID: sessionID, from: dict)
        } catch let error as RPCError where error.code == 401 || error.isAuthError {
            throw ACPError.authRequired(methods: error.authMethodIDs())
        }
    }

    /// Best-effort mode switch (e.g. reasoning effort). Fails silently when
    /// the agent doesn't support the requested mode.
    func setMode(sessionID: String, modeID: String) async {
        _ = try? await request(
            method: "session/set_mode",
            params: ["sessionId": sessionID, "modeId": modeID]
        )
    }

    /// Preferred model/thinking switch: ACP session config options.
    func setConfigOption(sessionID: String, configID: String, value: String) async {
        _ = try? await request(
            method: "session/set_config_option",
            params: ["sessionId": sessionID, "configId": configID, "value": value]
        )
    }

    private func requireConfigOption(sessionID: String, configID: String, value: String) async throws {
        _ = try await request(
            method: "session/set_config_option",
            params: ["sessionId": sessionID, "configId": configID, "value": value]
        )
    }

    /// Legacy ACP model switch, used when the agent has no configOptions.
    func setModel(sessionID: String, modelID: String) async {
        _ = try? await request(
            method: "session/set_model",
            params: ["sessionId": sessionID, "modelId": modelID]
        )
    }

    /// Applies the user's model and thinking selections through ACP config
    /// options, falling back to `session/set_model` for older agents.
    func applyGenerationSettings(session: SessionInfo, model: String?, thinkingLevel: String) async throws {
        if let model, !model.isEmpty {
            let option = session.option(category: "model")
            let available = option?.values.map(\.id) ?? session.availableModelIDs
            guard available.isEmpty || Self.bestValueMatch(target: model, in: available) != nil else {
                throw ACPError.requestFailed(
                    code: -32602,
                    message: "Model '\(model)' is unavailable in the ACP session. Choose an available model or update the agent."
                )
            }
            let value = Self.bestValueMatch(target: model, in: available) ?? model
            do {
                if let option {
                    try await requireConfigOption(sessionID: session.id, configID: option.id, value: value)
                } else {
                    _ = try await request(
                        method: "session/set_model",
                        params: ["sessionId": session.id, "modelId": value]
                    )
                }
            } catch {
                throw ACPError.requestFailed(
                    code: -32602,
                    message: "Could not select model '\(model)' in the ACP session: \(error.localizedDescription)"
                )
            }
        }

        if let option = session.option(category: "thought_level") {
            let aliases: [String]
            switch thinkingLevel {
            case "xhigh": aliases = ["xhigh", "extra-high"]
            case "minimal": aliases = ["minimal", "low"]
            default: aliases = [thinkingLevel]
            }
            if let value = aliases.lazy.compactMap({
                Self.bestValueMatch(target: $0, in: option.values.map(\.id))
            }).first {
                await setConfigOption(sessionID: session.id, configID: option.id, value: value)
            }
        }
    }

    /// Antigravity's advertised configuration is authoritative. A saved model
    /// that disappeared must surface an error instead of silently changing it.
    func applyAntigravityGenerationSettings(
        session: SessionInfo,
        model: String?,
        thinkingLevel: String
    ) async throws {
        if let model, !model.isEmpty {
            guard let option = session.option(category: "model") else {
                throw ACPError.requestFailed(
                    code: -32602,
                    message: "Antigravity did not advertise a model selector for this account."
                )
            }
            guard option.values.contains(where: { $0.id == model }) else {
                throw ACPError.requestFailed(
                    code: -32602,
                    message: "Antigravity model '\(model)' is unavailable for this Google account. Choose an available model."
                )
            }
            if option.currentValue != model {
                try await requireConfigOption(sessionID: session.id, configID: option.id, value: model)
            }
        }

        if let option = session.option(category: "thought_level") {
            let aliases = thinkingLevel == "xhigh" ? ["xhigh", "extra-high"] : [thinkingLevel]
            if let value = aliases.first(where: { alias in
                option.values.contains(where: { $0.id == alias })
            }), option.currentValue != value {
                try await requireConfigOption(sessionID: session.id, configID: option.id, value: value)
            }
        }
    }

    /// Exact match first. Avoids substring traps (`high` vs `xhigh`).
    static func bestValueMatch(target: String, in values: [String]) -> String? {
        guard !target.isEmpty else { return nil }
        let needle = target.lowercased()
        return values.first(where: { $0.lowercased() == needle })
    }

    func authenticate(methodID: String) async throws {
        _ = try await request(method: "authenticate", params: ["methodId": methodID])
    }

    func logout() async throws {
        _ = try await request(method: "logout", params: [:])
    }

    /// Runs one prompt turn, optionally publishing streamed text chunks while
    /// still returning the complete sanitized answer at the end.
    struct PromptImage: Sendable {
        let data: Data
        let mimeType: String
    }

    func prompt(sessionID: String,
                text: String,
                images: [PromptImage] = [],
                onChunk: (@Sendable (String) -> Void)? = nil) async throws -> String {
        var encoded: [[String: Any]] = [["type": "text", "text": text]]
        encoded.append(contentsOf: images.map { image in
            [
                "type": "image",
                "data": image.data.base64EncodedString(),
                "mimeType": image.mimeType,
            ]
        })

        return try await prompt(sessionID: sessionID, encodedBlocks: encoded, onChunk: onChunk)
    }

    func prompt(
        sessionID: String,
        blocks: [AntigravityACPContent.Block],
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let encoded = blocks.map { block -> [String: Any] in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let data, let mimeType):
                return ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
            case .audio(let data, let mimeType):
                return ["type": "audio", "data": data.base64EncodedString(), "mimeType": mimeType]
            case .resource(let text, let uri, let mimeType):
                return [
                    "type": "resource",
                    "resource": ["uri": uri, "mimeType": mimeType, "text": text],
                ]
            case .resourceLink(let uri, let name, let mimeType):
                return ["type": "resource_link", "uri": uri, "name": name, "mimeType": mimeType]
            }
        }
        return try await prompt(sessionID: sessionID, encodedBlocks: encoded, onChunk: onChunk)
    }

    private func prompt(
        sessionID: String,
        encodedBlocks: [[String: Any]],
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let accumulator = StringAccumulator(onChunk: onChunk)
        mutex.with { chunkBuffers[sessionID] = accumulator }
        defer { _ = mutex.with { chunkBuffers.removeValue(forKey: sessionID) } }

        let result = try await withTaskCancellationHandler {
            try await request(
                method: "session/prompt",
                params: ["sessionId": sessionID,
                         "prompt": encodedBlocks]
            )
        } onCancel: {
            cancel(sessionID: sessionID)
        }
        try Task.checkCancellation()

        if let failure = mutex.with({ transcriptionFailure }) { throw failure }
        if mutex.with({ transcriptionOnly }),
           (result as? [String: Any])?["stopReason"] as? String != "end_turn" {
            throw ACPError.transcriptionStopped("Antigravity did not finish the audio part successfully.", reason: .incompleteOutput)
        }
        if let dict = result as? [String: Any],
           dict["stopReason"] as? String == "refusal" {
            throw ACPError.requestFailed(code: -32000, message: "The agent refused this request.")
        }

        return Self.sanitizeAgentOutput(accumulator.value)
    }

    /// Best-effort ACP cancellation for an in-flight prompt turn.
    func cancel(sessionID: String) {
        send([
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": ["sessionId": sessionID],
        ])
    }

    /// Strips agent chrome (startup warnings, banner lines) that some agents
    /// stream as message chunks before the real content.
    static func sanitizeAgentOutput(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Warning:"), trimmed.lowercased().contains("skill") { return false }
            if trimmed.hasPrefix("⚠") { return false }
            return true
        }
        return filtered.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func shutdown(error: Error = ACPError.connectionClosed) {
        let waiters: [PendingCall]? = mutex.with {
            guard !isClosed else { return nil }
            isClosed = true
            closeError = error
            if let failure = error as? ACPError { transcriptionFailure = failure }
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        guard let waiters else { return }
        waiters.forEach { $0.continuation.resume(throwing: error) }

        writeQueue.async { [stdinHandle] in
            try? stdinHandle.close()
        }
        if process.isRunning {
            let pid = process.processIdentifier
            // Never signal another job's group. Foundation normally owns a
            // group for its child; verify that ownership before using it.
            let ownsGroup = mutex.with { transcriptionOnly } && getpgid(pid) == pid
            if ownsGroup { kill(-pid, SIGTERM) } else { process.terminate() }
            if mutex.with({ transcriptionOnly }) {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [process] in
                    // A child may ignore TERM after the group leader has exited.
                    // A surviving group retains its ID; never signal a reused PID.
                    let group = getpgid(pid)
                    if ownsGroup, group == pid || (group == -1 && errno == ESRCH) {
                        kill(-pid, SIGKILL)
                    } else if process.isRunning {
                        process.terminate()
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
        notifyClosed()
    }

    // MARK: - Wire plumbing

    private func request(method: String, params: [String: Any]) async throws -> Any {
        try Task.checkCancellation()
        let id: Int = mutex.with {
            let id = nextRequestID
            nextRequestID += 1
            return id
        }

        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(envelope),
              let serialized = try? JSONSerialization.data(withJSONObject: envelope),
              !serialized.isEmpty else {
            throw ACPError.unexpectedResponse
        }
        var mutablePayload = serialized
        mutablePayload.append(0x0A)
        let payload = mutablePayload

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let call = PendingCall(continuation: continuation)
                let registered = mutex.with {
                    guard !isClosed else { return false }
                    pending[id] = call
                    return true
                }
                guard registered else {
                    continuation.resume(throwing: mutex.with { closeError })
                    return
                }
                writeQueue.async { [self] in
                    guard !mutex.with({ isClosed }) else { return }
                    do { try stdinHandle.write(contentsOf: payload) }
                    catch { shutdown() }
                }
            }
        } onCancel: {
            // Each generation request owns its connection. Do not wait for an
            // unresponsive agent to acknowledge session/cancel.
            self.shutdown()
        }
    }

    private func startReading(_ handle: FileHandle) {
        let buffer = LineBuffer(maximumLineBytes: mutex.with { transcriptionOnly } ? 8 * 1_024 * 1_024 : nil)
        handle.readabilityHandler = { [self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            let lines = buffer.append(data)
            if buffer.exceededLimit {
                stdoutQueue.async { [weak self] in
                    self?.shutdown(error: ACPError.transcriptionStopped("Antigravity exceeded the protocol output limit.", reason: .outputLimit))
                }
                return
            }
            for line in lines {
                self.stdoutQueue.async { [weak self] in
                    self?.handleLine(line)
                }
            }
        }
    }

    private func handleAuthorizationLine(_ line: Data) -> Bool {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
        let prefixes = [
            "Open the following link to authenticate the ACP server: ",
            "__LECTERN_ANTIGRAVITY_AUTH_URL__",
        ]
        guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { return false }
        // Never retain sign-in URLs in diagnostics, including malformed ones.
        guard let url = URL(string: String(text.dropFirst(prefix.count))) else { return true }
        do {
            try AntigravityACPAuthorization.validate(url)
            if let onAuthorizationURL {
                onAuthorizationURL(url)
            } else {
                failPendingAuthentication(message: nil)
                shutdown()
            }
        } catch {
            failPendingAuthentication(message: error.localizedDescription)
            shutdown()
        }
        return true
    }

    private func handleLine(_ line: Data) {
        if handleAuthorizationLine(line) { return }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        let method = obj["method"] as? String
        let hasID = obj["id"] != nil

        if hasID, method == nil {
            guard let id = obj["id"] as? Int else { return }
            let call = mutex.with { pending.removeValue(forKey: id) }
            guard let call else { return }

            if let errorDict = obj["error"] as? [String: Any] {
                let code = errorDict["code"] as? Int ?? -32603
                let message = errorDict["message"] as? String ?? "Unknown agent error"
                let detail = errorDict["data"]
                call.continuation.resume(throwing: RPCError(code: code, message: message, detail: detail))
            } else if let result = obj["result"] {
                call.continuation.resume(returning: result)
            } else {
                call.continuation.resume(throwing: ACPError.unexpectedResponse)
            }
            return
        }

        switch method {
        case "session/update":
            handleSessionUpdate(obj["params"] as? [String: Any])
        case "session/request_permission":
            respondToPermissionRequest(obj)
        default:
            if hasID, let method {
                if mutex.with({ transcriptionOnly }) {
                    let failure = ACPError.transcriptionStopped("Antigravity requested a tool or user input during transcription.")
                    mutex.with { transcriptionFailure = failure }
                    send(["jsonrpc": "2.0", "id": obj["id"] as Any,
                          "error": ["code": -32601, "message": "Transcription does not support client tools or user input"]])
                    writeQueue.async { [self] in shutdown(error: failure) }
                    return
                }
                send(["jsonrpc": "2.0",
                      "id": obj["id"] as Any,
                      "error": ["code": -32601, "message": "Lectern does not support \(method)"]])
            }
        }
    }

    private func handleSessionUpdate(_ params: [String: Any]?) {
        if mutex.with({ transcriptionOnly }),
           let update = params?["update"] as? [String: Any],
           let kind = update["sessionUpdate"] as? String,
           kind == "tool_call" || kind == "tool_call_update" {
            shutdown(error: ACPError.transcriptionStopped("Antigravity attempted tool work during transcription. The audio part was stopped."))
            return
        }
        guard let params,
              let sessionID = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String else { return }

        let exceeded = mutex.with {
            guard transcriptionOnly else { return false }
            transcriptionOutputBytes += text.utf8.count
            return transcriptionOutputBytes > 4 * 1_024 * 1_024
        }
        if exceeded {
            shutdown(error: ACPError.transcriptionStopped("Antigravity exceeded the transcript output limit.", reason: .outputLimit))
            return
        }

        let accumulator = mutex.with { chunkBuffers[sessionID] }
        accumulator?.append(text)
    }

    /// One-off generation may approve a single action, but never grants a
    /// permanent permission or mistakes an Antigravity user question for one.
    private func respondToPermissionRequest(_ envelope: [String: Any]) {
        if mutex.with({ transcriptionOnly }) {
            let failure = ACPError.transcriptionStopped("Antigravity requested tool permission during transcription. The audio part was stopped.")
            mutex.with { transcriptionFailure = failure }
            // Queue the denial before closing stdin. Never select allow_once.
            send(["jsonrpc": "2.0", "id": envelope["id"] as Any,
                  "result": ["outcome": ["outcome": "cancelled"]]])
            writeQueue.async { [self] in
                shutdown(error: failure)
            }
            return
        }
        guard let params = envelope["params"] as? [String: Any],
              let options = params["options"] as? [[String: Any]],
              let toolCall = params["toolCall"] as? [String: Any],
              let toolCallID = toolCall["toolCallId"] as? String,
              !toolCallID.hasPrefix("interaction_"),
              let optionID = options.first(where: { $0["kind"] as? String == "allow_once" })?["optionId"] else {
            if envelope["id"] != nil {
                send(["jsonrpc": "2.0", "id": envelope["id"] as Any,
                      "result": ["outcome": ["outcome": "cancelled"]]])
            }
            return
        }

        send(["jsonrpc": "2.0",
              "id": envelope["id"] as Any,
              "result": ["outcome": ["outcome": "selected", "optionId": optionID]]])
    }

    private func processDidExit() {
        let waiters: [PendingCall] = mutex.with {
            isClosed = true
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        waiters.forEach { $0.continuation.resume(throwing: ACPError.connectionClosed) }
        notifyClosed()
    }

    private func notifyClosed() {
        let callback: (@Sendable () -> Void)? = mutex.with {
            guard !didNotifyClose else { return nil }
            didNotifyClose = true
            return onClose
        }
        callback?()
    }

    private func failPendingAuthentication(message: String?) {
        let waiters: [PendingCall] = mutex.with {
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        waiters.forEach {
            if let message {
                $0.continuation.resume(throwing: ACPError.requestFailed(code: -32000, message: message))
            } else {
                $0.continuation.resume(throwing: ACPError.authRequired(methods: ["oauth-personal"]))
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let serialized = try? JSONSerialization.data(withJSONObject: message) else { return }
        var mutablePayload = serialized
        mutablePayload.append(0x0A)
        let payload = mutablePayload
        writeQueue.async { [self] in
            guard !mutex.with({ isClosed }) else { return }
            do { try stdinHandle.write(contentsOf: payload) }
            catch { shutdown() }
        }
    }

    private final class ProcessExitCallback: @unchecked Sendable {
        private let mutex = Mutex()
        private var callback: (@Sendable () -> Void)?

        init(_ callback: (@Sendable () -> Void)?) { self.callback = callback }

        func run() {
            let action = mutex.with {
                let action = callback
                callback = nil
                return action
            }
            action?()
        }
    }

    /// Ring-buffer of recent agent stderr output, for diagnostics.
    final class StderrTail: @unchecked Sendable {
        private let mutex = Mutex()
        private var text = ""

        func append(_ chunk: String) {
            mutex.with {
                text = String((text + chunk).suffix(4_000))
            }
        }

        var value: String {
            mutex.with { text }
        }
    }
}

extension ACPConnection.SessionInfo {
    func option(category: String) -> ACPConnection.ConfigOption? {
        configOptions.first(where: { $0.category == category })
            ?? configOptions.first(where: { $0.id == category })
    }

    static func parse(sessionID: String, from dict: [String: Any]) -> ACPConnection.SessionInfo {
        var modeIDs: [String] = []
        if let modes = dict["modes"] as? [String: Any],
           let available = modes["availableModes"] as? [[String: Any]] {
            modeIDs = available.compactMap { $0["id"] as? String }
        }

        let configOptions = parseConfigOptions(dict["configOptions"] as? [[String: Any]] ?? [])

        var modelIDs: [String] = []
        var currentModel: String?
        if let models = dict["models"] as? [String: Any] {
            currentModel = models["currentModelId"] as? String
            if let available = models["availableModels"] as? [[String: Any]] {
                modelIDs = available.compactMap { $0["modelId"] as? String ?? $0["id"] as? String }
            }
        }
        if modelIDs.isEmpty, let option = configOptions.first(where: { $0.category == "model" || $0.id == "model" }) {
            modelIDs = option.values.map(\.id)
            currentModel = currentModel ?? option.currentValue
        }

        return ACPConnection.SessionInfo(
            id: sessionID,
            availableModeIDs: modeIDs,
            configOptions: configOptions,
            availableModelIDs: modelIDs,
            currentModelID: currentModel
        )
    }

    private static func parseConfigOptions(_ rows: [[String: Any]]) -> [ACPConnection.ConfigOption] {
        rows.compactMap { row in
            let id = (row["id"] as? String) ?? (row["configId"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let values: [ACPConnection.ConfigValue] = (row["options"] as? [[String: Any]] ?? []).compactMap { option in
                let value = option["value"] as? String ?? ""
                guard !value.isEmpty else { return nil }
                return ACPConnection.ConfigValue(id: value, name: option["name"] as? String ?? value)
            }
            return ACPConnection.ConfigOption(
                id: id,
                category: row["category"] as? String,
                currentValue: stringify(row["currentValue"]),
                values: values
            )
        }
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}

struct RPCError: Error, LocalizedError, @unchecked Sendable {
    let code: Int
    let message: String
    let detail: Any?

    var errorDescription: String? { message }

    var isAuthError: Bool {
        message.lowercased().contains("auth")
    }

    func authMethodIDs() -> [String] {
        guard let array = detail as? [[String: Any]] else { return [] }
        let ids = array.compactMap { $0["id"] as? String }
        return ids.isEmpty ? array.compactMap { $0["methodId"] as? String } : ids
    }
}

/// Synchronous lock wrapper usable from any context.
final class Mutex: @unchecked Sendable {
    private let nsLock = NSLock()
    func with<T>(_ body: () throws -> T) rethrows -> T {
        nsLock.lock()
        defer { nsLock.unlock() }
        return try body()
    }
}


/// Splits streamed stdout bytes into newline-delimited messages.
final class LineBuffer: @unchecked Sendable {
    private let mutex = Mutex()
    private var buffer = Data()
    private let maximumLineBytes: Int?
    private var droppingOversizeLine = false
    private var didExceedLimit = false

    var exceededLimit: Bool { mutex.with { didExceedLimit } }

    init(maximumLineBytes: Int? = nil) {
        self.maximumLineBytes = maximumLineBytes
    }

    func append(_ data: Data) -> [Data] {
        mutex.with {
            buffer.append(data)

            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if let maximumLineBytes, line.count > maximumLineBytes { didExceedLimit = true }
                buffer.removeSubrange(buffer.startIndex...newline)
                if !droppingOversizeLine, !line.isEmpty,
                   maximumLineBytes.map({ line.count <= $0 }) ?? true {
                    lines.append(Data(line))
                }
                droppingOversizeLine = false
            }
            if let maximumLineBytes, buffer.count > maximumLineBytes {
                didExceedLimit = true
                buffer.removeAll(keepingCapacity: false)
                droppingOversizeLine = true
            }
            return lines
        }
    }
}
