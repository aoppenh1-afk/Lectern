import XCTest

final class AppUpdaterTests: XCTestCase {
    func testVersionParsingAndOrdering() {
        XCTAssertEqual(AppVersion("v1.2.3")?.parts, [1, 2, 3])
        XCTAssertEqual(AppVersion("1.2.3-beta.1")?.parts, [1, 2, 3])
        XCTAssertNil(AppVersion("latest"))
        XCTAssertTrue(AppVersion("1.0")! < AppVersion("1.0.1")!)
        XCTAssertTrue(AppVersion("1.9")! < AppVersion("1.10")!)
        XCTAssertFalse(AppVersion("1.1.0")! < AppVersion("1.1")!)
        XCTAssertEqual(AppVersion("1.1.0")!, AppVersion("1.1.0")!)
    }

    func testParseReleasePicksLecternZipAndChecksum() throws {
        let json = """
        {
          "tag_name": "v1.2.0",
          "name": "Lectern 1.2.0",
          "body": "Nested notes",
          "html_url": "https://github.com/o/r/releases/tag/v1.2.0",
          "assets": [
            {"name": "Source.zip", "url": "https://api.github.com/repos/o/r/releases/assets/1"},
            {"name": "Lectern-1.2.0.zip", "url": "https://api.github.com/repos/o/r/releases/assets/2"},
            {"name": "Lectern-1.2.0.zip.sha256", "url": "https://api.github.com/repos/o/r/releases/assets/3"}
          ]
        }
        """
        let release = try AppUpdater.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.assetName, "Lectern-1.2.0.zip")
        XCTAssertEqual(release.assetAPIURL?.absoluteString, "https://api.github.com/repos/o/r/releases/assets/2")
        XCTAssertEqual(release.checksumAPIURL?.absoluteString, "https://api.github.com/repos/o/r/releases/assets/3")
        XCTAssertEqual(release.notes, "Nested notes")
    }

    func testChecksumVerification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-checksum-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertNoThrow(try AppUpdater.verifyChecksum(of: file, against: Data("\(sha)  Lectern.zip\n".utf8)))
        XCTAssertThrowsError(try AppUpdater.verifyChecksum(of: file, against: Data("deadbeef".utf8)))
    }

    func testFindAppBundleInsideExpandedArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-bundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("nested/Lectern.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(AppUpdater.findAppBundle(in: root)?.lastPathComponent, "Lectern.app")
    }
}

final class AgentDetectorTests: XCTestCase {
    func testDetectionStatusesAndSuggestedCommands() {
        let detections = AgentDetector.detectAll(
            resolve: { name in
                switch name {
                case "agy": return "/Users/me/.local/bin/agy"
                case "opencode": return "/opt/homebrew/bin/opencode"
                default: return nil
                }
            },
            antigravitySignedIn: { false }
        )
        let byID = Dictionary(uniqueKeysWithValues: detections.map { ($0.profileID, $0) })
        XCTAssertEqual(byID[AgentProfiles.antigravityID]?.status, .installedNotSignedIn)
        XCTAssertEqual(byID[AgentProfiles.antigravityID]?.suggestedCommand, "/Users/me/.local/bin/agy")
        XCTAssertEqual(byID[AgentProfiles.opencodeID]?.status, .ready)
        XCTAssertEqual(byID[AgentProfiles.opencodeID]?.suggestedCommand, "/opt/homebrew/bin/opencode acp")
        XCTAssertEqual(byID[AgentProfiles.codexID]?.status, .notInstalled)
        XCTAssertNil(byID[AgentProfiles.codexID]?.suggestedCommand)
    }

    func testApplyDetectedOnlyOverwritesFoundAgents() {
        let defaults = UserDefaults(suiteName: "AgentDetectorTests-\(UUID().uuidString)")!
        AgentProfiles.setCommand("/custom/codex-acp", for: AgentProfiles.codexID, userDefaults: defaults)
        let detections = AgentDetector.detectAll(
            resolve: { $0 == "agy" ? "/found/agy" : nil },
            antigravitySignedIn: { true }
        )
        AgentDetector.applyDetected(detections, userDefaults: defaults)
        XCTAssertEqual(AgentProfiles.profile(id: AgentProfiles.antigravityID, userDefaults: defaults)?.command, "/found/agy")
        XCTAssertEqual(AgentProfiles.profile(id: AgentProfiles.codexID, userDefaults: defaults)?.command, "/custom/codex-acp")
    }
}
