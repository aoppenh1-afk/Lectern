@preconcurrency import AppAuth
import AppKit
import Foundation
import Observation
import Security

@MainActor
@Observable
final class LecternCloudAuth {
    static let origin = URL(string: "https://lectern-app.vercel.app")!
    static let clientID = "lectern-macos"
    private static let service = "com.lectern.hosted-sharing"
    private var state: OIDAuthState?
    private var handler: OIDRedirectHTTPHandler?
    private var pending: CheckedContinuation<Void, Error>?
    private(set) var isSignedIn = false
    private(set) var isSigningIn = false
    private(set) var credentialWarning: String?

    init() {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data),
           saved.lastAuthorizationResponse.request.clientID == Self.clientID,
           saved.lastAuthorizationResponse.request.configuration.authorizationEndpoint == Self.origin.appendingPathComponent("oauth/authorize") {
            state = saved
            isSignedIn = saved.isAuthorized
        }
    }

    func signIn() async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        let listener = OIDRedirectHTTPHandler(successURL: Self.origin.appendingPathComponent("connect"))
        handler = listener
        var error: NSError?
        let callback = listener.startHTTPListener(&error)
        if let error { throw error }
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: Self.origin.appendingPathComponent("oauth/authorize"),
            tokenEndpoint: Self.origin.appendingPathComponent("oauth/token")
        )
        let request = OIDAuthorizationRequest(configuration: configuration, clientId: Self.clientID,
            clientSecret: nil, scopes: ["library:sync"], redirectURL: callback,
            responseType: OIDResponseTypeCode,
            additionalParameters: ["resource": Self.origin.appendingPathComponent("api/library").absoluteString])
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            listener.currentAuthorizationFlow = OIDAuthState.authState(byPresenting: request) { [weak self, weak listener] saved, error in
                Task { @MainActor in
                    guard let self, let listener, self.handler === listener, let continuation = self.pending else { return }
                    self.pending = nil
                    self.handler?.cancelHTTPListener()
                    self.handler = nil
                    NSApp.activate(ignoringOtherApps: true)
                    if let saved {
                        self.state = saved
                        self.isSignedIn = saved.isAuthorized
                        self.persist()
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? LecternCloudError.message("Sign-in was cancelled."))
                    }
                }
            }
        }
    }

    func cancelSignIn() {
        handler?.cancelHTTPListener()
        handler = nil
        pending?.resume(throwing: LecternCloudError.message("Sign-in was cancelled."))
        pending = nil
        isSigningIn = false
    }

    func accessToken() async throws -> String {
        guard let state, state.isAuthorized else { throw LecternCloudError.message("Sign in to Lectern to share your library.") }
        do {
            let token: String = try await withCheckedThrowingContinuation { continuation in
                state.performAction { token, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let token { continuation.resume(returning: token) }
                    else { continuation.resume(throwing: LecternCloudError.message("Sign in again to reconnect Lectern.")) }
                }
            }
            persist() // Persist rotated refresh tokens before the next request.
            return token
        } catch {
            isSignedIn = state.isAuthorized
            persist()
            throw error
        }
    }

    /// Caller revokes/deletes on the server first. Forgetting credentials alone cannot revoke access.
    func forget() {
        cancelSignIn()
        state = nil
        isSignedIn = false
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "oauth"]
    }

    private func persist() {
        guard let state, let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true) else { return }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(keychainQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        credentialWarning = status == errSecSuccess ? nil : "Could not save the connection in Keychain. You may need to sign in again after quitting."
    }
}
