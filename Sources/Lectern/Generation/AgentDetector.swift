import Foundation

/// Result of probing this Mac for one of the agents Lectern can drive.
struct AgentDetection: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case ready
        case installedNotSignedIn
        case notInstalled

        var title: String {
            switch self {
            case .ready: return "Ready"
            case .installedNotSignedIn: return "Installed, not signed in"
            case .notInstalled: return "Not installed"
            }
        }
    }

    let profileID: String
    let title: String
    /// Absolute path of the executable that was found, if any.
    let executablePath: String?
    /// The spawn command Lectern should store for this agent when it was found.
    let suggestedCommand: String?
    let status: Status
    /// Shell command a user can paste to install the agent.
    let installHint: String

    var id: String { profileID }
    var isInstalled: Bool { status != .notInstalled }
}

/// Finds which agent CLIs exist on this machine so a fresh install does not
/// have to hand-type paths for tools it does not own. Detection is filesystem
/// only; nothing is launched except the optional Antigravity sign-in probe.
enum AgentDetector {
    struct Candidate: Sendable {
        let profileID: String
        let title: String
        /// Executable names to try, in order of preference.
        let executables: [String]
        /// Arguments appended after the resolved path to form the spawn command.
        let arguments: String
        let installHint: String
    }

    static let candidates: [Candidate] = [
        Candidate(
            profileID: AgentProfiles.antigravityID,
            title: "Antigravity CLI",
            executables: ["agy"],
            arguments: "",
            installHint: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        ),
        Candidate(
            profileID: AgentProfiles.codexID,
            title: "ChatGPT (Codex)",
            executables: ["codex-acp"],
            arguments: "",
            installHint: "brew install codex-acp"
        ),
        Candidate(
            profileID: AgentProfiles.opencodeID,
            title: "opencode",
            executables: ["opencode"],
            arguments: "acp",
            installHint: "brew install opencode"
        ),
    ]

    /// Antigravity keeps its OAuth profile here after the first interactive
    /// `agy` launch. Presence is a cheap, reliable signed-in signal.
    static var antigravityTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    static func detectAll(
        resolve: (String) -> String? = AgentProfiles.resolveExecutable,
        antigravitySignedIn: () -> Bool = { FileManager.default.fileExists(atPath: antigravityTokenURL.path) }
    ) -> [AgentDetection] {
        candidates.map { candidate in
            let path = candidate.executables.lazy.compactMap(resolve).first
            let status: AgentDetection.Status
            if path == nil {
                status = .notInstalled
            } else if candidate.profileID == AgentProfiles.antigravityID, !antigravitySignedIn() {
                status = .installedNotSignedIn
            } else {
                status = .ready
            }
            let command = path.map { candidate.arguments.isEmpty ? $0 : "\($0) \(candidate.arguments)" }
            return AgentDetection(
                profileID: candidate.profileID,
                title: candidate.title,
                executablePath: path,
                suggestedCommand: command,
                status: status,
                installHint: candidate.installHint
            )
        }
    }

    /// Stores the detected spawn commands so every generation path uses the
    /// paths that actually exist. Agents that were not found keep their
    /// current command so a later manual edit is not clobbered.
    @discardableResult
    static func applyDetected(
        _ detections: [AgentDetection],
        userDefaults: UserDefaults = .standard
    ) -> [AgentDetection] {
        for detection in detections {
            if let command = detection.suggestedCommand {
                AgentProfiles.setCommand(command, for: detection.profileID, userDefaults: userDefaults)
            }
        }
        return detections
    }

    /// Runs `agy models`, which succeeds only for a signed-in CLI. Used as the
    /// "Check again" probe after the user signs in from Terminal.
    static func verifyAntigravitySignIn(timeout: Duration = .seconds(20)) async -> Bool {
        guard let path = AgentProfiles.resolveExecutable("agy") else { return false }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["models"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:"
                + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
            process.environment = environment

            let finished = ContinuationGuard(continuation)
            process.terminationHandler = { process in
                finished.resume(process.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                finished.resume(false)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
                finished.resume(false)
            }
        }
    }

    private final class ContinuationGuard: @unchecked Sendable {
        private var continuation: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
