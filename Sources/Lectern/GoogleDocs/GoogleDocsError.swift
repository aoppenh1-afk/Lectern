import Foundation

enum GoogleDocsError: LocalizedError {
    case missingClientID
    case notSignedIn
    case cancelled
    case noNotes
    case api(status: Int, message: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Add a Google OAuth client ID in Settings before pushing notes."
        case .notSignedIn:
            return "Sign in to Google in Settings, then try again."
        case .cancelled:
            return "Sign-in didn’t finish. If Google said access_denied, add that Gmail as a test user under Audience, then try again."
        case .noNotes:
            return "Generate notes for this lecture before pushing to Google Docs."
        case .api(_, let message):
            return message
        case .malformed(let detail):
            return detail
        }
    }

    var isNotFound: Bool {
        if case .api(status: 404, _) = self { return true }
        return false
    }
}
