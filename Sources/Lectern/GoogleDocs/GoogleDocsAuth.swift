@preconcurrency import AppAuth
import AppKit
import Foundation
import Security

/// Shared desktop OAuth configuration ships in the app; tokens live in Keychain.
@MainActor
@Observable
final class GoogleDocsAuth {
    private static let keychainService = "com.lectern.google-oauth"
    private static let keychainAccount = "authState"

    static let scopes = ["https://www.googleapis.com/auth/drive.file"]
    private let configuration = GoogleOAuthConfiguration(info: Bundle.main.infoDictionary ?? [:])

    private var authState: OIDAuthState?
    private var redirectHandler: OIDRedirectHTTPHandler?
    private var pendingAuthorization: CheckedContinuation<OIDAuthState, Error>?
    private let changeForwarder = AuthStateForwarder()

    private(set) var isSignedIn = false
    private(set) var email: String?
    private(set) var isSigningIn = false
    private(set) var lastError: String?

    var isConfigured: Bool { configuration.isConfigured }

    init() {
        changeForwarder.onChange = { [weak self] state in
            Task { @MainActor in
                self?.isSignedIn = state.isAuthorized
                self?.persist()
            }
        }
        restore()
    }

    func signIn() async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        do {
            guard isConfigured else { throw GoogleDocsError.missingClientID }
            try await runAuthorization(clientID: configuration.clientID, secret: configuration.clientSecret)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func runAuthorization(clientID: String, secret: String) async throws {
        redirectHandler?.cancelHTTPListener()
        let handler = OIDRedirectHTTPHandler(
            successURL: URL(string: "https://openid.github.io/AppAuth-iOS/redirect/")
        )
        redirectHandler = handler

        var listenerError: NSError?
        let redirectURI = handler.startHTTPListener(&listenerError)
        if let listenerError {
            throw listenerError
        }

        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )

        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: clientID,
            clientSecret: secret.isEmpty ? nil : secret,
            scopes: Self.scopes,
            redirectURL: redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: [
                "access_type": "offline",
                "prompt": "consent"
            ]
        )

        let state: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            pendingAuthorization = continuation
            handler.currentAuthorizationFlow = OIDAuthState.authState(
                byPresenting: request
            ) { [weak self] authState, error in
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    self?.finishAuthorization(authState: authState, error: error)
                }
            }
        }

        apply(state)
        persist()
    }

    /// Aborts a hung browser flow (Google's 403 page never redirects back).
    func cancelSignIn() {
        redirectHandler?.cancelHTTPListener()
        finishAuthorization(authState: nil, error: GoogleDocsError.cancelled)
        redirectHandler = nil
    }

    private func finishAuthorization(authState: OIDAuthState?, error: Error?) {
        guard let continuation = pendingAuthorization else { return }
        pendingAuthorization = nil
        if let error {
            let nsError = error as NSError
            if nsError.domain == OIDGeneralErrorDomain,
               nsError.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue
                || nsError.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
                || error is GoogleDocsError {
                continuation.resume(throwing: GoogleDocsError.cancelled)
            } else {
                continuation.resume(throwing: error)
            }
        } else if let authState {
            continuation.resume(returning: authState)
        } else {
            continuation.resume(throwing: GoogleDocsError.cancelled)
        }
    }

    func signOut() {
        cancelSignIn()
        redirectHandler = nil
        authState = nil
        lastError = nil
        isSignedIn = false
        email = nil
        deleteKeychain()
    }

    func accessToken() async throws -> String {
        guard let authState, authState.isAuthorized else {
            throw GoogleDocsError.notSignedIn
        }
        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction { token, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: GoogleDocsError.notSignedIn)
                }
            }
        }
    }

    // MARK: - Persistence

    private func apply(_ state: OIDAuthState) {
        authState = state
        state.stateChangeDelegate = changeForwarder
        isSignedIn = state.isAuthorized
        email = emailFromIDToken(state.lastTokenResponse?.idToken)
    }

    private func restore() {
        // An unconfigured development build must not erase a working release session.
        guard isConfigured else { return }
        guard let data = loadKeychain() else { return }
        do {
            let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
            if let state {
                let request = state.lastAuthorizationResponse.request
                guard configuration.accepts(clientID: request.clientID, scope: request.scope) else {
                    lastError = "Connect Google Docs again to use Lectern’s updated file permissions. Previously granted access can be removed in your Google Account."
                    deleteKeychain()
                    return
                }
                apply(state)
            }
        } catch {
            deleteKeychain()
        }
    }

    fileprivate func persist() {
        guard let authState else {
            deleteKeychain()
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
            saveKeychain(data)
        } catch {
            // Token stays in memory for this session.
        }
    }

    private func emailFromIDToken(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad > 0 { payload += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    private func saveKeychain(_ data: Data) {
        deleteKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// AppAuth's state-change delegate, kept off `GoogleDocsAuth` so the observable
/// class doesn't have to inherit `NSObject`.
private final class AuthStateForwarder: NSObject, OIDAuthStateChangeDelegate {
    var onChange: ((OIDAuthState) -> Void)?

    func didChange(_ state: OIDAuthState) {
        onChange?(state)
    }
}
