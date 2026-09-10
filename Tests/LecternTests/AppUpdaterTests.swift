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

    func testDevTagDetection() {
        XCTAssertTrue(AppUpdater.isDevTag("v2.3-dev.20260910-143000-a1b2c3d"))
        XCTAssertTrue(AppUpdater.isDevTag("dev-20260910-a1b2c3d"))
        XCTAssertFalse(AppUpdater.isDevTag("v2.3"))
        XCTAssertFalse(AppUpdater.isDevTag("v1.2.0"))
    }

    func testParseReleaseMarksDevAndKeepsFullTag() throws {
        let json = """
        {
          "tag_name": "v2.3-dev.20260910-143000-a1b2c3d",
          "name": "Lectern Dev 20260910-143000 (a1b2c3d)",
          "body": "Dev notes",
          "html_url": "https://github.com/o/r/releases/tag/v2.3-dev.20260910-143000-a1b2c3d",
          "prerelease": true,
          "published_at": "2026-09-10T14:30:00Z",
          "assets": [
            {"name": "Lectern-v2.3-dev.20260910-143000-a1b2c3d.zip", "url": "https://api.github.com/repos/o/r/releases/assets/2"},
            {"name": "Lectern-v2.3-dev.20260910-143000-a1b2c3d.zip.sha256", "url": "https://api.github.com/repos/o/r/releases/assets/3"}
          ]
        }
        """
        let release = try AppUpdater.parseRelease(Data(json.utf8))
        XCTAssertTrue(release.isDev)
        XCTAssertEqual(release.tag, "v2.3-dev.20260910-143000-a1b2c3d")
        XCTAssertEqual(release.version, "2.3-dev.20260910-143000-a1b2c3d")
        XCTAssertEqual(release.assetName, "Lectern-v2.3-dev.20260910-143000-a1b2c3d.zip")
    }

    func testParseReleaseMarksStable() throws {
        let json = """
        {
          "tag_name": "v1.2.0",
          "name": "Lectern 1.2.0",
          "body": "Stable notes",
          "html_url": "https://github.com/o/r/releases/tag/v1.2.0",
          "prerelease": false,
          "published_at": "2026-09-09T10:00:00Z",
          "assets": [
            {"name": "Lectern-1.2.0.zip", "url": "https://api.github.com/repos/o/r/releases/assets/2"}
          ]
        }
        """
        let release = try AppUpdater.parseRelease(Data(json.utf8))
        XCTAssertFalse(release.isDev)
        XCTAssertEqual(release.tag, "v1.2.0")
        XCTAssertEqual(release.version, "1.2.0")
    }

    func testParseNewestDevReleasePicksNewestPrerelease() throws {
        let json = """
        [
          {
            "tag_name": "v2.3",
            "name": "Lectern 2.3",
            "body": "Stable",
            "html_url": "https://github.com/o/r/releases/tag/v2.3",
            "prerelease": false,
            "published_at": "2026-09-10T15:00:00Z",
            "assets": [
              {"name": "Lectern-2.3.zip", "url": "https://api.github.com/repos/o/r/releases/assets/1"}
            ]
          },
          {
            "tag_name": "v2.3-dev.20260910-120000-older01",
            "name": "Lectern Dev older",
            "body": "Older dev",
            "html_url": "https://github.com/o/r/releases/tag/v2.3-dev.20260910-120000-older01",
            "prerelease": true,
            "published_at": "2026-09-10T12:00:00Z",
            "assets": [
              {"name": "Lectern-v2.3-dev.20260910-120000-older01.zip", "url": "https://api.github.com/repos/o/r/releases/assets/2"}
            ]
          },
          {
            "tag_name": "v2.3-dev.20260910-143000-newer01",
            "name": "Lectern Dev newer",
            "body": "Newer dev",
            "html_url": "https://github.com/o/r/releases/tag/v2.3-dev.20260910-143000-newer01",
            "prerelease": true,
            "published_at": "2026-09-10T14:30:00Z",
            "assets": [
              {"name": "Lectern-v2.3-dev.20260910-143000-newer01.zip", "url": "https://api.github.com/repos/o/r/releases/assets/3"}
            ]
          },
          {
            "tag_name": "v2.3-rc.1",
            "name": "Not a dev tag",
            "body": "A non-dev prerelease must be ignored",
            "html_url": "https://github.com/o/r/releases/tag/v2.3-rc.1",
            "prerelease": true,
            "published_at": "2026-09-10T16:00:00Z",
            "assets": []
          }
        ]
        """
        let newest = try AppUpdater.parseNewestDevRelease(Data(json.utf8))
        XCTAssertEqual(newest?.tag, "v2.3-dev.20260910-143000-newer01")
        XCTAssertEqual(newest?.isDev, true)
    }

    func testParseNewestDevReleaseReturnsNilWithoutDev() throws {
        let json = """
        [
          {
            "tag_name": "v2.3",
            "name": "Lectern 2.3",
            "body": "Stable only",
            "html_url": "https://github.com/o/r/releases/tag/v2.3",
            "prerelease": false,
            "published_at": "2026-09-10T15:00:00Z",
            "assets": [
              {"name": "Lectern-2.3.zip", "url": "https://api.github.com/repos/o/r/releases/assets/1"}
            ]
          }
        ]
        """
        XCTAssertNil(try AppUpdater.parseNewestDevRelease(Data(json.utf8)))
    }

    func testSkippedKeysDifferPerChannel() {
        XCTAssertEqual(AppUpdater.skippedKey(for: .stable), AppUpdater.skippedVersionKey)
        XCTAssertNotEqual(AppUpdater.skippedKey(for: .stable), AppUpdater.skippedKey(for: .dev))
    }
}

final class AgentDetectorTests: XCTestCase {
    func testDetectionStatusesAndSuggestedCommands() {
        let detections = AgentDetector.detectAll(
            resolve: { name in
                switch name {
                case "opencode": return "/opt/homebrew/bin/opencode"
                default: return nil
                }
            }
        )
        let byID = Dictionary(uniqueKeysWithValues: detections.map { ($0.profileID, $0) })
        XCTAssertNil(byID[AgentProfiles.antigravityID], "The CLI detector must not stand in for managed ACP state.")
        XCTAssertEqual(byID[AgentProfiles.opencodeID]?.status, .ready)
        XCTAssertEqual(byID[AgentProfiles.opencodeID]?.suggestedCommand, "/opt/homebrew/bin/opencode acp")
        XCTAssertEqual(byID[AgentProfiles.codexID]?.status, .notInstalled)
        XCTAssertNil(byID[AgentProfiles.codexID]?.suggestedCommand)
    }

    func testApplyDetectedOnlyOverwritesFoundAgents() {
        let defaults = UserDefaults(suiteName: "AgentDetectorTests-\(UUID().uuidString)")!
        AgentProfiles.setCommand("/custom/codex-acp", for: AgentProfiles.codexID, userDefaults: defaults)
        let detections = AgentDetector.detectAll(
            resolve: { $0 == "opencode" ? "/found/opencode" : nil }
        )
        AgentDetector.applyDetected(detections, userDefaults: defaults)
        XCTAssertEqual(AgentProfiles.profile(id: AgentProfiles.antigravityID, userDefaults: defaults)?.command, "managed://antigravity-acp")
        XCTAssertEqual(AgentProfiles.profile(id: AgentProfiles.codexID, userDefaults: defaults)?.command, "/custom/codex-acp")
    }
}
