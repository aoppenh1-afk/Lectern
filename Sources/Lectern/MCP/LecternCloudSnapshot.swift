import Foundation

/// Explicit allowlist for cloud sharing; no recordings, credentials, attachments or chats.
struct LecternCloudSnapshot: Codable {
    struct Course: Codable { let id: String; let name: String }
    struct Lecture: Codable {
        let id: String
        let title: String
        let courseID: String
        let capturedAt: String
        let documents: [String: String]
    }
    let courses: [Course]
    let lectures: [Lecture]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static let maximumBytes = 32 * 1024 * 1024
    static let chunkBytes = 384 * 1024
}

enum LecternCloudError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
