import Foundation
import SwiftData

/// Pushes pending flashcards into Anki via AnkiConnect, with per-Course deck
/// mapping and an `School::Unfiled` fallback. CSV export covers the case
/// where Anki isn't running.
@MainActor
@Observable
final class CardSyncService {
    private(set) var isSyncing = false
    private(set) var lastMessage: String?
    private(set) var lastSyncSucceeded = true

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private var port: Int {
        let stored = UserDefaults.standard.integer(forKey: "ankiPort")
        guard stored != 0 else { return 8_761 }
        return max(1024, min(stored, 65_535))
    }

    var client: AnkiConnectClient {
        AnkiConnectClient(port: port)
    }

    /// Deck for a lecture: its Course's deck, or the Unfiled fallback.
    static func deck(for lecture: Lecture) -> String {
        lecture.course?.ankiDeckName ?? "School::Unfiled"
    }

    func sync(lecture: Lecture) async {
        guard !isSyncing else { return }

        let dueCards = lecture.flashcards.filter { $0.syncState != .pushed }
        guard !dueCards.isEmpty else {
            lastMessage = "All cards are already in Anki."
            lastSyncSucceeded = true
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        let client = self.client
        let deckName = Self.deck(for: lecture)

        do {
            guard await client.isReachable() else {
                throw AnkiConnectClient.BridgeError(
                    message: "Anki isn't reachable at 127.0.0.1:\(port). Open Anki (with the AnkiConnect add-on), or export a CSV."
                )
            }
            try await client.ensureDeck(named: deckName)

            let cards = dueCards.map { ($0.front, $0.back) }
            let outcomes = try await client.addBasicNotes(deck: deckName, cards: cards)

            var added = 0
            var rejected = 0
            for (index, card) in dueCards.enumerated() {
                switch outcomes[index] {
                case .added:
                    card.syncState = .pushed
                    added += 1
                case nil, .rejected:
                    card.syncState = .failed
                    rejected += 1
                }
            }
            try? modelContainer.mainContext.save()

            lastMessage = Self.summary(added: added, rejected: rejected, deck: deckName)
            lastSyncSucceeded = rejected == 0
        } catch {
            // Leave states as-is so a later sync retries everything.
            lastMessage = error.localizedDescription
            lastSyncSucceeded = false
        }
    }

    static func summary(added: Int, rejected: Int, deck: String) -> String {
        var parts: [String] = []
        parts.append("\(added) card\(added == 1 ? "" : "s") pushed to \(deck)")
        if rejected > 0 {
            parts.append("\(rejected) rejected (likely duplicates already in Anki)")
        }
        return parts.joined(separator: " · ")
    }

    /// Writes front/back CSV to a temp file; returns the file URL for sharing.
    @discardableResult
    func exportCSV(lecture: Lecture) throws -> URL? {
        let cards = lecture.flashcards.sorted { $0.createdAt < $1.createdAt }
        guard !cards.isEmpty else { return nil }

        var rows = ["Front,Back"]
        for card in cards {
            rows.append("\(Self.csvEscape(card.front)),\(Self.csvEscape(card.back))")
        }

        let sanitizedTitle = lecture.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitizedTitle) — Flashcards.csv")

        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Convenience: writes the CSV and copies it onto the Desktop.
    @discardableResult
    func exportToDesktop(lecture: Lecture) -> URL? {
        guard let temporaryURL = try? exportCSV(lecture: lecture) else { return nil }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = desktop.appendingPathComponent(temporaryURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            lastMessage = "Exported \(lecture.flashcards.count) cards to Desktop."
            lastSyncSucceeded = true
            return destination
        } catch {
            lastMessage = "Couldn't write to Desktop: \(error.localizedDescription)"
            lastSyncSucceeded = false
            return nil
        }
    }

    static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

