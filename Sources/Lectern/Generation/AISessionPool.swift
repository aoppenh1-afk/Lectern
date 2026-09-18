import Foundation

/// Shared by transcription and study-material requests. Waiting jobs are cancellable.
actor AISessionPool {
    static let settingsKey = "ai.maximumConcurrentSessions"
    static let defaultLimit = 3
    static let shared = AISessionPool()

    private let fixedLimit: Int?
    private var running = 0
    private var waiting: [UUID] = []

    init(limit: Int? = nil) { fixedLimit = limit.map { max(1, $0) } }

    var limit: Int { fixedLimit ?? Self.configuredLimit() }

    static func configuredLimit(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: settingsKey) != nil else { return defaultLimit }
        return min(20, max(1, defaults.integer(forKey: settingsKey)))
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        waiting.append(id)
        defer { waiting.removeAll { $0 == id } }
        while true {
            try Task.checkCancellation()
            if waiting.first == id, running < limit { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        waiting.removeFirst()
        running += 1
        defer { running -= 1 }
        return try await operation()
    }
}
