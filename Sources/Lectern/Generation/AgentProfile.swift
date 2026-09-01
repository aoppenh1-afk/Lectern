import Foundation

/// A configured ACP agent Lectern can spawn for study-material generation.
struct AgentProfile: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    /// Full spawn command, e.g. `/opt/homebrew/bin/codex-acp`.
    var command: String
    /// ACP auth method id to use if the agent reports authentication required.
    var authMethodID: String?
    /// Optional model override (agent default when nil/empty). For opencode
    /// this is `provider/model`; for ChatGPT/Codex it's the live catalog id
    /// from `codex app-server` `model/list`.
    var model: String?

    var executablePath: String {
        command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)[0]
    }

    var arguments: [String] {
        Array(command.split(separator: " ", omittingEmptySubsequences: true).map(String.init).dropFirst())
    }
}

enum AgentProfiles {
    static let codexID = "codex"
    static let opencodeID = "opencode"
    static let antigravityID = "antigravity"

    static func defaultModelID(for profileID: String) -> String? {
        switch profileID {
        case codexID:
            return "gpt-5.6-luna"
        case opencodeID:
            return "opencode/hy3-free"
        case antigravityID:
            return AntigravityCLI.modelID
        default:
            return nil
        }
    }

    static let defaultsKey = "agentCommands"
    static let modelsKey = "agentModels"

    /// Built-in profiles. Commands resolve against PATH plus common Homebrew
    /// locations, because GUI apps inherit a minimal environment.
    static func all(userDefaults: UserDefaults = .standard) -> [AgentProfile] {
        let stored = userDefaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let models = userDefaults.dictionary(forKey: modelsKey) as? [String: String] ?? [:]

        func model(_ id: String) -> String? {
            guard let value = models[id], !value.isEmpty else { return nil }
            return value
        }

        return [
            AgentProfile(
                id: codexID,
                title: "ChatGPT (Codex)",
                command: stored[codexID] ?? "/opt/homebrew/bin/codex-acp",
                authMethodID: "chat-gpt",
                model: model(codexID) ?? defaultModelID(for: codexID)
            ),
            AgentProfile(
                id: opencodeID,
                title: "opencode",
                command: stored[opencodeID] ?? "/opt/homebrew/bin/opencode acp",
                authMethodID: nil,
                model: model(opencodeID) ?? defaultModelID(for: opencodeID)
            ),
            AgentProfile(
                id: antigravityID,
                title: "Antigravity CLI",
                command: stored[antigravityID] ?? "agy",
                authMethodID: nil,
                model: model(antigravityID) ?? defaultModelID(for: antigravityID)
            ),
        ]
    }

    static func profile(id: String, userDefaults: UserDefaults = .standard) -> AgentProfile? {
        all(userDefaults: userDefaults).first(where: { $0.id == id })
    }

    static func setCommand(_ command: String, for id: String, userDefaults: UserDefaults = .standard) {
        var stored = (userDefaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        stored[id] = command
        userDefaults.set(stored, forKey: defaultsKey)
    }

    static func setModel(_ model: String?, for id: String, userDefaults: UserDefaults = .standard) {
        var stored = (userDefaults.dictionary(forKey: modelsKey) as? [String: String]) ?? [:]
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            stored.removeValue(forKey: id)
        } else {
            stored[id] = trimmed
        }
        userDefaults.set(stored, forKey: modelsKey)
    }

    /// Resolve an executable name against PATH and common install roots.
    static func resolveExecutable(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }

        var searchDirs = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }

        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
