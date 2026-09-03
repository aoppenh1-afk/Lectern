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
/// only. Antigravity is managed separately by `AntigravityACPManager`.
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

    static func detectAll(
        resolve: (String) -> String? = AgentProfiles.resolveExecutable
    ) -> [AgentDetection] {
        candidates.map { candidate in
            let path = candidate.executables.lazy.compactMap(resolve).first
            let status: AgentDetection.Status
            if path == nil {
                status = .notInstalled
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

}
