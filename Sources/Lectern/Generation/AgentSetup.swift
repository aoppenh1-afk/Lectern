import AppKit
import Observation

/// Setup links and commands for the externally installed ACP agents.
struct AgentSetup: Sendable {
    let profileID: String
    let downloadURL: URL
    let installCommand: String
    let installRequirement: String

    static let codex = AgentSetup(
        profileID: AgentProfiles.codexID,
        downloadURL: URL(string: "https://github.com/agentclientprotocol/codex-acp#installation")!,
        installCommand: "npm install -g @agentclientprotocol/codex-acp",
        installRequirement: "Requires Node.js and npm. Includes the Codex CLI."
    )

    static let opencode = AgentSetup(
        profileID: AgentProfiles.opencodeID,
        downloadURL: URL(string: "https://opencode.ai/docs/#install")!,
        installCommand: "brew install anomalyco/tap/opencode",
        installRequirement: "Requires Homebrew. Other installers are available under Download."
    )

    static func forProfile(_ id: String) -> AgentSetup? {
        switch id {
        case AgentProfiles.codexID: return codex
        case AgentProfiles.opencodeID: return opencode
        default: return nil
        }
    }

    /// Quotes a single shell argument, including paths with spaces or metacharacters.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func terminalScript(command: String) -> String {
        """
        #!/bin/zsh
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        cd "$HOME" || exit 1
        printf '%s\\n' \(shellQuote(command))
        \(command)
        lectern_setup_status=$?
        if [[ $lectern_setup_status -eq 0 ]]; then
            printf '\\n%s\\n' 'Done. Return to Lectern and click Refresh.'
        else
            printf '\\n%s\\n' 'Setup did not finish. Check the message above, then try again in Lectern.'
        fi
        /bin/rm -f -- "$0"
        exit $lectern_setup_status
        """
    }

    /// Terminal owns the interactive provider selection and credential prompts.
    @MainActor
    static func openTerminal(command: String) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw SetupError.terminalUnavailable
        }
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lectern-Agent-Setup-\(UUID().uuidString).command")
        try terminalScript(command: command).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        do {
            _ = try await NSWorkspace.shared.open(
                [script],
                withApplicationAt: terminal,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } catch {
            try? FileManager.default.removeItem(at: script)
            throw error
        }
    }

    enum SetupError: LocalizedError {
        case terminalUnavailable
        case chatGPTUnavailable
        case signInTimedOut

        var errorDescription: String? {
            switch self {
            case .terminalUnavailable: return "Terminal could not be opened. Copy the setup command and run it in your terminal."
            case .chatGPTUnavailable: return "This adapter does not offer ChatGPT sign-in. Install the current Codex ACP adapter, then try again."
            case .signInTimedOut: return "ChatGPT sign-in timed out. Try again and finish signing in in your browser."
            }
        }
    }
}

@MainActor
@Observable
final class CodexSignIn {
    enum State: Equatable {
        case idle
        case signingIn
        case signedIn
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var attemptID: UUID?

    func start(profile: AgentProfile) {
        guard state != .signingIn else { return }
        let attempt = UUID()
        attemptID = attempt
        state = .signingIn
        task = Task {
            do {
                try await Self.authenticate(profile: profile)
                guard attemptID == attempt else { return }
                state = .signedIn
            } catch {
                guard attemptID == attempt else { return }
                state = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() {
        attemptID = nil
        task?.cancel()
        task = nil
        if state == .signingIn { state = .idle }
    }

    func reset() {
        cancel()
        state = .idle
    }

    /// Authenticate without creating a study session or sending a prompt.
    static func authenticate(profile: AgentProfile) async throws {
        guard !profile.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ACPConnection.ACPError.spawnFailed("Set an agent command before signing in.")
        }
        let connection = try await ACPConnection.connect(profile: profile)
        defer { connection.shutdown() }
        try Task.checkCancellation()
        let method = profile.authMethodID ?? "chat-gpt"
        guard connection.initialization?.authMethodIDs.contains(method) == true else {
            throw AgentSetup.SetupError.chatGPTUnavailable
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            connection.shutdown(error: AgentSetup.SetupError.signInTimedOut)
        }
        defer { timeout.cancel() }
        try await connection.authenticate(methodID: method)
        try Task.checkCancellation()
    }
}
