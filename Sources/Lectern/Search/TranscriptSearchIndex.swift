import Foundation
import SQLite3
import SwiftData

/// A disposable, on-disk index. The transcript remains in SwiftData; FTS stores
/// only tokens and row IDs. Connections are scoped to each operation so search
/// has no permanent SQLite page cache or background worker.
actor TranscriptSearchIndex {
    static let shared = TranscriptSearchIndex()

    struct Document: Sendable {
        let key: String
        let revision: Double
        let text: String
    }

    private var resolvedURL: URL?

    init(fileURL: URL? = nil) {
        self.resolvedURL = fileURL
    }

    static func key(for id: PersistentIdentifier) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(id))?.base64EncodedString()
    }

    private func database(readOnly: Bool = false) throws -> TranscriptSearchDatabase {
        let url: URL
        if let resolvedURL {
            url = resolvedURL
        } else {
            url = try LecternStoreLocation.preparedStoreURL()
                .deletingLastPathComponent()
                .appendingPathComponent("TranscriptSearch.sqlite")
            resolvedURL = url
        }
        return try TranscriptSearchDatabase(url: url, readOnly: readOnly)
    }

    func revisions() throws -> [String: Double] {
        try database().revisions()
    }

    func upsert(_ documents: [Document]) throws {
        guard !documents.isEmpty else { return }
        try database().upsert(documents)
    }

    func removeMissing(keeping keys: Set<String>) throws {
        try database().removeMissing(keeping: keys)
    }

    func search(_ text: String) throws -> [String] {
        guard let query = Self.ftsQuery(text) else { return [] }
        return try database(readOnly: true).search(query)
    }

    /// User text is tokenized before it reaches MATCH, so punctuation and FTS
    /// operators cannot change the query grammar. Only the last word is a
    /// prefix, which makes live typing useful without a larger prefix index.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 }
            .prefix(8)
        guard let last = words.last else { return nil }
        let exact = words.dropLast().map { "\"\($0)\"" }
        return (exact + ["\"\(last)\"*"]).joined(separator: " AND ")
    }
}

private final class TranscriptSearchDatabase {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            throw failure("Open transcript search index")
        }
        // SQLite's default cache is about 2 MB per connection. Short-lived
        // connections and a 512 KiB cap bound the app's search-specific RAM.
        do {
            sqlite3_busy_timeout(handle, 1_000)
            try execute("PRAGMA cache_size=-512")
            try execute("PRAGMA mmap_size=0")
            if !readOnly {
                try execute("CREATE TABLE IF NOT EXISTS documents (id INTEGER PRIMARY KEY, lecture_key TEXT NOT NULL UNIQUE, revision REAL NOT NULL)")
                try execute("CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(body, content='', contentless_delete=1, detail=none, tokenize='unicode61 remove_diacritics 2')")
            }
        } catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func revisions() throws -> [String: Double] {
        let statement = try prepare("SELECT lecture_key, revision FROM documents")
        defer { sqlite3_finalize(statement) }
        var result: [String: Double] = [:]
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure("Read index revisions") }
            guard let key = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: key)] = sqlite3_column_double(statement, 1)
        }
        return result
    }

    func upsert(_ documents: [TranscriptSearchIndex.Document]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for document in documents {
                if let rowID = try rowID(for: document.key) {
                    try withStatement("DELETE FROM transcript_fts WHERE rowid=?") { statement in
                        sqlite3_bind_int64(statement, 1, rowID)
                        try stepDone(statement)
                    }
                    try withStatement("UPDATE documents SET revision=? WHERE id=?") { statement in
                        sqlite3_bind_double(statement, 1, document.revision)
                        sqlite3_bind_int64(statement, 2, rowID)
                        try stepDone(statement)
                    }
                    try insertText(document.text, rowID: rowID)
                } else {
                    try withStatement("INSERT INTO documents(lecture_key, revision) VALUES(?, ?)") { statement in
                        bind(document.key, to: statement, at: 1)
                        sqlite3_bind_double(statement, 2, document.revision)
                        try stepDone(statement)
                    }
                    try insertText(document.text, rowID: sqlite3_last_insert_rowid(handle))
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func removeMissing(keeping keys: Set<String>) throws {
        let statement = try prepare("SELECT id, lecture_key FROM documents")
        var stale: [Int64] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                sqlite3_finalize(statement)
                throw failure("Find stale index entries")
            }
            guard let key = sqlite3_column_text(statement, 1) else { continue }
            if !keys.contains(String(cString: key)) {
                stale.append(sqlite3_column_int64(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        guard !stale.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for rowID in stale {
                try withStatement("DELETE FROM transcript_fts WHERE rowid=?") { statement in
                    sqlite3_bind_int64(statement, 1, rowID)
                    try stepDone(statement)
                }
                try withStatement("DELETE FROM documents WHERE id=?") { statement in
                    sqlite3_bind_int64(statement, 1, rowID)
                    try stepDone(statement)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func search(_ query: String) throws -> [String] {
        let statement = try prepare("SELECT documents.lecture_key FROM transcript_fts JOIN documents ON documents.id=transcript_fts.rowid WHERE transcript_fts MATCH ?")
        defer { sqlite3_finalize(statement) }
        bind(query, to: statement, at: 1)
        var result: [String] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure("Search transcripts") }
            if let key = sqlite3_column_text(statement, 0) {
                result.append(String(cString: key))
            }
        }
        return result
    }

    private func insertText(_ text: String, rowID: Int64) throws {
        try withStatement("INSERT INTO transcript_fts(rowid, body) VALUES(?, ?)") { statement in
            sqlite3_bind_int64(statement, 1, rowID)
            bind(text, to: statement, at: 2)
            try stepDone(statement)
        }
    }

    private func rowID(for key: String) throws -> Int64? {
        let statement = try prepare("SELECT id FROM documents WHERE lecture_key=?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return sqlite3_column_int64(statement, 0) }
        guard status == SQLITE_DONE else { throw failure("Find index entry") }
        return nil
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            if let error { sqlite3_free(error) }
            throw NSError(domain: "TranscriptSearchIndex", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure("Prepare search query") }
        return statement
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("Update search index") }
    }

    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    private func failure(_ operation: String) -> NSError {
        let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return NSError(domain: "TranscriptSearchIndex", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "\(operation): \(detail)"])
    }
}
