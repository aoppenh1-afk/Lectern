import XCTest

final class GoogleOAuthConfigurationTests: XCTestCase {
    private let clientID = "lectern-test.apps.googleusercontent.com"
    private let scope = "https://www.googleapis.com/auth/drive.file"

    func testMissingAndUnexpandedBuildConfigurationCannotConnect() {
        XCTAssertFalse(GoogleOAuthConfiguration(info: [:]).isConfigured)
        XCTAssertFalse(GoogleOAuthConfiguration(info: [
            "LecternGoogleOAuthClientID": "$(LECTERN_GOOGLE_CLIENT_ID)"
        ]).isConfigured)
    }

    func testSharedClientAcceptsOnlyItsOwnFileScopedSession() {
        let configuration = GoogleOAuthConfiguration(info: [
            "LecternGoogleOAuthClientID": " \(clientID)\n",
            "LecternGoogleOAuthClientSecret": " desktop-value "
        ])
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertEqual(configuration.clientSecret, "desktop-value")
        XCTAssertTrue(configuration.accepts(clientID: clientID, scope: scope))
        XCTAssertFalse(configuration.accepts(clientID: "other.apps.googleusercontent.com", scope: scope))
        XCTAssertFalse(configuration.accepts(clientID: clientID, scope: nil))
        XCTAssertFalse(configuration.accepts(clientID: clientID, scope: "\(scope) https://www.googleapis.com/auth/documents"))
        XCTAssertFalse(configuration.accepts(clientID: clientID, scope: "openid email \(scope)"))
    }

    @MainActor
    func testAuthorizationRequestsOnlyFileAccess() {
        XCTAssertEqual(GoogleDocsAuth.scopes, [scope])
    }
}
