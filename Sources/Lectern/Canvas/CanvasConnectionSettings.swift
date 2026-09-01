import Foundation
import Observation
import Security

enum CanvasAutomaticSyncPolicy {
    static let maxAge: TimeInterval = 60 * 60
    // Increment when a release needs to populate new Canvas-backed data.
    static let dataVersion = 2

    static func shouldSync(lastSyncAt: Date?,
                           lastSyncedDataVersion: Int = dataVersion,
                           now: Date = Date(),
                           maxAge: TimeInterval = maxAge) -> Bool {
        guard lastSyncedDataVersion == dataVersion else { return true }
        guard let lastSyncAt else { return true }
        return now.timeIntervalSince(lastSyncAt) >= maxAge
    }
}

enum AcademicScopeMatcher {
    static let preferredTerm = "Fall 2026"

    static func matches(term: String?, selectedTerm: String) -> Bool {
        guard let term else { return false }
        return term.compare(selectedTerm, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func contains(courseID: Int64, allowedCourseIDs: Set<Int64>) -> Bool {
        allowedCourseIDs.contains(courseID)
    }

    /// Local courses are not tied to a Canvas academic term, so they remain
    /// available in the course library while Canvas courses follow the active term.
    static func includesInCoursesLibrary(canvasID: Int64?, term: String?, selectedTerm: String) -> Bool {
        guard canvasID != nil else { return true }
        return matches(term: term, selectedTerm: selectedTerm)
    }

    static func resolvedTerm(selectedTerm: String, availableTerms: [String]) -> String {
        if availableTerms.contains(selectedTerm) { return selectedTerm }
        if let preferred = availableTerms.first(where: {
            $0.compare(preferredTerm, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return preferred
        }
        return availableTerms.first ?? selectedTerm
    }
}

@MainActor
@Observable
final class CanvasConnectionSettings {
    private static let domainKey = "canvas.domain"
    private static let tokenAccount = "primary"

    var domain: String {
        didSet { UserDefaults.standard.set(domain, forKey: Self.domainKey) }
    }
    private(set) var hasToken: Bool

    init() {
        domain = UserDefaults.standard.string(forKey: Self.domainKey) ?? ""
        hasToken = CanvasTokenStore.exists(account: Self.tokenAccount)
    }

    var isConnected: Bool { !domain.isEmpty && hasToken }
    var maskedToken: String? { CanvasTokenStore.maskedSuffix(account: Self.tokenAccount) }

    func save(domain: String, token: String) throws {
        let normalized = try CanvasClient.normalizedBaseURL(domain)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw CanvasConnectionError.emptyToken }
        try CanvasTokenStore.save(trimmedToken, account: Self.tokenAccount)
        self.domain = normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        hasToken = true
    }

    func credentials() throws -> CanvasCredentials {
        guard !domain.isEmpty else { throw CanvasConnectionError.missingDomain }
        return CanvasCredentials(
            baseURL: try CanvasClient.normalizedBaseURL(domain),
            token: try CanvasTokenStore.read(account: Self.tokenAccount)
        )
    }

    func disconnect() throws {
        try CanvasTokenStore.remove(account: Self.tokenAccount)
        domain = ""
        hasToken = false
    }
}

struct CanvasCredentials: Sendable {
    let baseURL: URL
    let token: String
}

enum CanvasConnectionError: LocalizedError {
    case missingDomain
    case invalidDomain
    case insecureDomain
    case emptyToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingDomain: return "Enter your school's Canvas address."
        case .invalidDomain: return "Enter a valid Canvas address, such as school.instructure.com."
        case .insecureDomain: return "Canvas connections must use HTTPS."
        case .emptyToken: return "Paste a Canvas access token."
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "The Canvas token could not be stored in Keychain."
        }
    }
}

private enum CanvasTokenStore {
    private static let service = "com.lectern.canvas"

    static func save(_ token: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CanvasConnectionError.keychain(status) }
    }

    static func read(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CanvasConnectionError.keychain(status)
        }
        return value
    }

    static func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CanvasConnectionError.keychain(status)
        }
    }

    static func exists(account: String) -> Bool { (try? read(account: account)) != nil }

    static func maskedSuffix(account: String) -> String? {
        guard let token = try? read(account: account), !token.isEmpty else { return nil }
        return "•••• \(token.suffix(4))"
    }
}
