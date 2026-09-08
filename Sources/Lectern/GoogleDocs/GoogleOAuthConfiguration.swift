import Foundation

/// Desktop clients are public clients. These values identify the app and are
/// bundled at build time; they must never be used as proof of app identity.
struct GoogleOAuthConfiguration {
    let clientID: String
    let clientSecret: String

    init(info: [String: Any]) {
        func value(_ key: String) -> String {
            let raw = (info[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.contains("$(") ? "" : raw
        }
        clientID = value("LecternGoogleOAuthClientID")
        clientSecret = value("LecternGoogleOAuthClientSecret")
    }

    var isConfigured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }

    func accepts(clientID: String, scope: String?) -> Bool {
        let scopes = Set((scope ?? "").split(separator: " ").map(String.init))
        return isConfigured && clientID == self.clientID
            && scopes == ["https://www.googleapis.com/auth/drive.file"]
    }
}
