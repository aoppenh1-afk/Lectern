import XCTest

final class AgentSetupTests: XCTestCase {
    func testCustomAgentCommandIsDetectedAndPreserved() {
        let detections = AgentDetector.detectAll(
            resolve: { name in
                switch name {
                case "/custom/codex-acp": return name
                case "codex-acp": return "/default/codex-acp"
                default: return nil
                }
            },
            commands: [AgentProfiles.codexID: "/custom/codex-acp --verbose"]
        )
        let codex = detections.first { $0.profileID == AgentProfiles.codexID }
        XCTAssertEqual(codex?.executablePath, "/custom/codex-acp")
        XCTAssertEqual(codex?.suggestedCommand, "/custom/codex-acp --verbose")
        XCTAssertTrue(codex?.isInstalled == true)
    }

    func testMissingConfiguredCommandFallsBackToInstalledAgent() {
        let detections = AgentDetector.detectAll(
            resolve: { $0 == "opencode" ? "/usr/local/bin/opencode" : nil },
            commands: [AgentProfiles.opencodeID: "/missing/opencode acp", AgentProfiles.codexID: "  "]
        )
        XCTAssertEqual(detections.first { $0.profileID == AgentProfiles.opencodeID }?.suggestedCommand, "/usr/local/bin/opencode acp")
        XCTAssertFalse(detections.first { $0.profileID == AgentProfiles.codexID }?.isInstalled == true)
    }

    func testTerminalScriptQuotesPathsAndDeletesItself() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("quote' dollar$ backtick` space.txt")
        let script = directory.appendingPathComponent("setup.command")
        try AgentSetup.terminalScript(command: "/usr/bin/touch \(AgentSetup.shellQuote(destination.path))")
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    func testTerminalScriptReportsFailedSetup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("setup.command")
        try AgentSetup.terminalScript(command: "/usr/bin/false")
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(message.contains("Setup did not finish"))
        XCTAssertFalse(message.contains("Done."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    @MainActor
    func testCodexSignInAuthenticatesWithoutCreatingStudySession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeAgent(in: directory, supportsChatGPT: true)
        try await CodexSignIn.authenticate(profile: fixture.profile)
        let requests = try readRequests(fixture.log)
        XCTAssertEqual(requests.map { $0["method"] as? String }, ["initialize", "authenticate"])
        XCTAssertEqual((requests.last?["params"] as? [String: Any])?["methodId"] as? String, "chat-gpt")
    }

    @MainActor
    func testCodexSignInRejectsUnsupportedAuthenticationMethod() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeAgent(in: directory, supportsChatGPT: false)
        do {
            try await CodexSignIn.authenticate(profile: fixture.profile)
            XCTFail("An adapter without ChatGPT auth should not report successful sign-in.")
        } catch AgentSetup.SetupError.chatGPTUnavailable {
            XCTAssertEqual(try readRequests(fixture.log).count, 1)
        }
    }

    @MainActor
    func testCodexSignInCanBeCancelledWhileWaitingForBrowser() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try makeAgent(in: directory, supportsChatGPT: true, respondsToAuth: false)
        let task = Task { try await CodexSignIn.authenticate(profile: fixture.profile) }
        defer { task.cancel() }
        for _ in 0..<200 {
            if (try? readRequests(fixture.log).count) == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try readRequests(fixture.log).count, 2)
        task.cancel()
        switch await task.result {
        case .success: XCTFail("Cancelled sign-in must not report success.")
        case .failure: break
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-agent-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeAgent(in directory: URL, supportsChatGPT: Bool, respondsToAuth: Bool = true) throws -> (profile: AgentProfile, log: URL) {
        let executable = directory.appendingPathComponent("mock-agent")
        let log = directory.appendingPathComponent("requests.jsonl")
        let authMethods = supportsChatGPT ? #"[{"id":"chat-gpt","name":"ChatGPT"}]"# : "[]"
        let source = """
        #!/bin/sh
        while IFS= read -r line; do
            printf '%s\\n' "$line" >> \(AgentSetup.shellQuote(log.path))
            request_id=$(printf '%s\\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\\1/')
            case "$line" in
                *'"method":"initialize"'*)
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"authMethods":\(authMethods)}}\\n' "$request_id"
                    ;;
                *'"method":"authenticate"'*)
                    \(respondsToAuth ? "printf '{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{}}\\n' \"$request_id\"" : ":")
                    ;;
            esac
        done
        """
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (AgentProfile(id: AgentProfiles.codexID, title: "Mock Codex", command: executable.path, authMethodID: "chat-gpt"), log)
    }

    private func readRequests(_ log: URL) throws -> [[String: Any]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
