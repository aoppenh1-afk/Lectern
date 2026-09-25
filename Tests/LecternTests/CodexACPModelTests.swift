import Foundation
import XCTest

final class CodexACPModelTests: XCTestCase {
    func testCodexACPUsesTheCLIChosenForItsModelCatalog() throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        defer { try? FileManager.default.removeItem(at: cli) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let profile = AgentProfile(
            id: AgentProfiles.codexID, title: "ChatGPT (Codex)",
            command: "/opt/homebrew/bin/codex-acp", authMethodID: "chat-gpt", model: "gpt-6-sol"
        )
        let environment = ACPConnection.spawnEnvironment(
            profile: profile, base: ["PATH": "/usr/bin", "CODEX_PATH": cli.path]
        )

        XCTAssertEqual(AgentModelCatalogLoader.resolveCodexCLI(from: profile, environment: environment), cli.path)
        XCTAssertEqual(environment["CODEX_PATH"], cli.path)

        if let discoveredCLI = AgentProfiles.resolveExecutable("codex") {
            let discoveredEnvironment = ACPConnection.spawnEnvironment(profile: profile, base: ["PATH": "/usr/bin"])
            XCTAssertEqual(discoveredEnvironment["CODEX_PATH"], discoveredCLI)
        }
    }

    func testUnavailableSelectedModelStopsBeforePrompt() async throws {
        let script = #"""
import json, sys
for raw in sys.stdin:
    request = json.loads(raw)
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion": 1, "agentInfo": {"name": "codex-acp", "version": "fixture"}}
    elif method == "session/new":
        result = {"sessionId": "fixture-session", "configOptions": [{"id": "model", "category": "model", "currentValue": "gpt-6-luna", "options": [{"value": "gpt-6-luna", "name": "GPT-6 Luna"}]}]}
    elif method == "session/set_config_option":
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32602, "message": "Invalid params"}}), flush=True)
        continue
    else:
        result = {"stopReason": "end_turn"}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
"""#
        let connection = try await ACPConnection.connect(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ProcessInfo.processInfo.environment
        )
        defer { connection.shutdown() }
        let session = try await connection.newSession(workingDirectory: FileManager.default.temporaryDirectory)

        do {
            try await connection.applyGenerationSettings(
                session: session, model: "gpt-6-sol", thinkingLevel: "high"
            )
            XCTFail("An unavailable selected model must stop generation before prompting.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("gpt-6-sol"))
        }
    }
}
