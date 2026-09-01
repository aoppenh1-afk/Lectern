import Foundation

/// One spawned ACP agent process speaking newline-delimited JSON-RPC 2.0
/// over stdio. All I/O and state is confined to internal serial queues; the
/// public API is async and safe to call from anywhere.
final class ACPConnection: @unchecked Sendable {
    enum ACPError: LocalizedError {
        case spawnFailed(String)
        case connectionClosed
        case requestFailed(code: Int, message: String)
        case authRequired(methods: [String])
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let detail): return "Could not launch agent: \(detail)"
            case .connectionClosed: return "Agent process exited unexpectedly."
            case .requestFailed(_, let message): return message
            case .authRequired(let methods): return "Authentication required (\(methods.joined(separator: ", ")))."
            case .unexpectedResponse: return "Agent returned an unexpected response."
            }
        }
    }

    struct AgentIdentity: @unchecked Sendable {
        var name: String
        var version: String
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
    private var chunkBuffers: [String: StringAccumulator] = [:]

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutQueue = DispatchQueue(label: "com.lectern.acp.stdout")
    private let writeQueue = DispatchQueue(label: "com.lectern.acp.write")
    private let stderrTail = StderrTail()

    private(set) var identity: AgentIdentity?

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = profile.arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

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

        let connection = ACPConnection(process: process,
                                       stdinHandle: stdinPipe.fileHandleForWriting,
                                       stderrPipe: stderrPipe)
        connection.startReading(stdoutPipe.fileHandleForReading)

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

        if let dict = result as? [String: Any],
           let info = dict["agentInfo"] as? [String: Any] {
            connection.mutex.with {
                connection.identity = AgentIdentity(
                    name: info["name"] as? String ?? "agent",
                    version: info["version"] as? String ?? "?"
                )
            }
        }

        return connection
    }

    private init(process: Process, stdinHandle: FileHandle, stderrPipe: Pipe) {
        self.process = process
        self.stdinHandle = stdinHandle

        // Drain stderr (capped) so a chatty agent can never fill the pipe.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                self?.stderrTail.append(text)
            }
        }
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
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

    /// Legacy ACP model switch, used when the agent has no configOptions.
    func setModel(sessionID: String, modelID: String) async {
        _ = try? await request(
            method: "session/set_model",
            params: ["sessionId": sessionID, "modelId": modelID]
        )
    }

    /// Applies the user's model and thinking selections through config
    /// options (T3 Code's path), falling back to `session/set_model`.
    func applyGenerationSettings(session: SessionInfo, model: String?, thinkingLevel: String) async {
        if let model, !model.isEmpty {
            if let option = session.option(category: "model") {
                let value = Self.bestValueMatch(target: model, in: option.values.map(\.id)) ?? model
                await setConfigOption(sessionID: session.id, configID: option.id, value: value)
            } else {
                let value = Self.bestValueMatch(target: model, in: session.availableModelIDs) ?? model
                await setModel(sessionID: session.id, modelID: value)
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

    /// Exact match first. Avoids substring traps (`high` vs `xhigh`).
    static func bestValueMatch(target: String, in values: [String]) -> String? {
        guard !target.isEmpty else { return nil }
        let needle = target.lowercased()
        return values.first(where: { $0.lowercased() == needle })
    }

    func authenticate(methodID: String) async throws {
        _ = try await request(method: "authenticate", params: ["methodId": methodID])
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
        let accumulator = StringAccumulator(onChunk: onChunk)
        mutex.with { chunkBuffers[sessionID] = accumulator }
        defer { _ = mutex.with { chunkBuffers.removeValue(forKey: sessionID) } }

        var prompt: [[String: Any]] = [["type": "text", "text": text]]
        prompt.append(contentsOf: images.map { image in
            [
                "type": "image",
                "data": image.data.base64EncodedString(),
                "mimeType": image.mimeType,
            ]
        })

        let result = try await request(
            method: "session/prompt",
            params: ["sessionId": sessionID,
                     "prompt": prompt]
        )

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

    func shutdown() {
        let waiters: [PendingCall] = mutex.with {
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        waiters.forEach { $0.continuation.resume(throwing: ACPError.connectionClosed) }

        writeQueue.async { [stdinHandle] in
            try? stdinHandle.close()
        }
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Wire plumbing

    private func request(method: String, params: [String: Any]) async throws -> Any {
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

        return try await withCheckedThrowingContinuation { continuation in
            let call = PendingCall(continuation: continuation)
            mutex.with { pending[id] = call }

            writeQueue.async { [stdinHandle] in
                stdinHandle.write(payload)
            }
        }
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
                self.stdoutQueue.async { [weak self] in
                    self?.handleLine(line)
                }
            }
        }
    }

    private func handleLine(_ line: Data) {
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
                send(["jsonrpc": "2.0",
                      "id": obj["id"] as Any,
                      "error": ["code": -32601, "message": "Lectern does not support \(method)"]])
            }
        }
    }

    private func handleSessionUpdate(_ params: [String: Any]?) {
        guard let params,
              let sessionID = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              content["type"] as? String == "text",
              let text = content["text"] as? String else { return }

        let accumulator = mutex.with { chunkBuffers[sessionID] }
        accumulator?.append(text)
    }

    /// Auto-permit tool calls so a chatty agent never deadlocks waiting on us.
    private func respondToPermissionRequest(_ envelope: [String: Any]) {
        guard let params = envelope["params"] as? [String: Any],
              let options = params["options"] as? [[String: Any]],
              let optionID = options.first?["optionId"] else { return }

        send(["jsonrpc": "2.0",
              "id": envelope["id"] as Any,
              "result": ["outcome": ["outcome": "selected", "optionId": optionID]]])
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let serialized = try? JSONSerialization.data(withJSONObject: message) else { return }
        var mutablePayload = serialized
        mutablePayload.append(0x0A)
        let payload = mutablePayload
        writeQueue.async { [stdinHandle] in
            stdinHandle.write(payload)
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

    func append(_ data: Data) -> [Data] {
        mutex.with {
            buffer.append(data)

            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty {
                    lines.append(Data(line))
                }
            }
            return lines
        }
    }
}
