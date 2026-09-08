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
            return "Google Docs is not configured in this build. Ask the app distributor for a configured build."
        case .notSignedIn:
            return "Sign in to Google in Settings, then try again."
        case .cancelled:
            return "Sign-in did not finish. Try connecting Google Docs again."
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
