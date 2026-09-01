import Foundation

/// Minimal AnkiConnect (http://localhost:8761) client.
/// All calls are `POST` with `{action, version, params}` envelopes.
struct AnkiConnectClient {
    struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let port: Int

    private var endpoint: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Raw request; returns the decoded `result` payload.
    func invoke(action: String, params: [String: Any] = [:]) async throws -> Any {
        var envelope: [String: Any] = ["action": action, "version": 6]
        if !params.isEmpty { envelope["params"] = params }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: envelope)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError(message: "AnkiBridge: no HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError(message: "AnkiBridge: HTTP \(httpResponse.statusCode)")
        }

        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError(message: "AnkiBridge: unreadable response")
        }
        if let errorText = body["error"] as? String, !errorText.isEmpty {
            throw BridgeError(message: "AnkiBridge: \(errorText)")
        }
        return body["result"] ?? NSNull()
    }

    // MARK: - High-level helpers

    func isReachable() async -> Bool {
        do {
            _ = try await invoke(action: "version")
            return true
        } catch {
            return false
        }
    }

    func ensureDeck(named name: String) async throws {
        let names = try await invoke(action: "deckNames") as? [String] ?? []
        if names.contains(name) { return }
        _ = try await invoke(action: "createDeck", params: ["deck": name])
    }

    /// Adds Basic-model notes; returns per-index outcome aligned with input.
    /// `.right(index)` = added, `.left(message)` = rejected (e.g. duplicate).
    enum NoteOutcome {
        case added
        case rejected(String)
    }

    func addBasicNotes(deck: String, cards: [(front: String, back: String)]) async throws -> [Int: NoteOutcome] {
        let notes: [[String: Any]] = cards.map { card in
            [
                "deckName": deck,
                "modelName": "Basic",
                "fields": ["Front": card.front, "Back": card.back],
                "options": ["allowDuplicate": false],
                "tags": ["lectern"],
            ]
        }

        let results = try await invoke(action: "addNotes", params: ["notes": notes]) as? [Any?] ?? []

        var outcomes: [Int: NoteOutcome] = [:]
        for (index, entry) in results.enumerated() {
            if entry == nil || entry is NSNull {
                outcomes[index] = .rejected("rejected or duplicate")
            } else {
                outcomes[index] = .added
            }
        }
        return outcomes
    }
}
