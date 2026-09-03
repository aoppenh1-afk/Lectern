import AVFoundation
import XCTest

final class AntigravityACPTests: XCTestCase {
    func testPinnedGoogleReleaseMatchesVerifiedT3CodeAsset() throws {
        let release = try XCTUnwrap(AntigravityACPRelease.current)

        XCTAssertEqual(release.version, "agy_acp_server_20260818_01_RC01")
        XCTAssertEqual(
            release.url.absoluteString,
            "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_20260818_01_RC01-darwin-arm64.zip"
        )
        XCTAssertEqual(release.sha256, "f122ca7e7030a27f9649da4cf1a7d80e12c48c5f6118ff35affc34d56cbf83dd")
        XCTAssertEqual(release.archiveBytes, 314_500_221)
        XCTAssertEqual(release.executable, .init(name: "agy_acp_server.par", bytes: 792_105_680))
        XCTAssertEqual(release.harness, .init(name: "localharness_external", bytes: 101_551_680))
    }

    func testManagedLayoutKeepsRuntimeAndGoogleProfileInsideLectern() {
        let root = URL(fileURLWithPath: "/tmp/Lectern ACP fixture", isDirectory: true)
        let layout = AntigravityACPLayout(root: root)

        XCTAssertEqual(
            layout.managedDirectory.path,
            "/tmp/Lectern ACP fixture/tools/antigravity-acp/darwin-arm64"
        )
        XCTAssertEqual(layout.versionsDirectory.lastPathComponent, "versions")
        XCTAssertEqual(layout.activeRecord.lastPathComponent, "active.json")
        XCTAssertEqual(
            layout.profileDirectory.path,
            "/tmp/Lectern ACP fixture/providers/antigravity/default"
        )
        XCTAssertEqual(layout.token.lastPathComponent, "acp_token.json")
    }

    func testLaunchEnvironmentIsIsolatedFromExistingGoogleCredentials() throws {
        let root = URL(fileURLWithPath: "/tmp/Lectern", isDirectory: true)
        let layout = AntigravityACPLayout(root: root)
        let installation = AntigravityACPInstallation(
            executable: URL(fileURLWithPath: "/tmp/runtime/agy_acp_server.par"),
            harness: URL(fileURLWithPath: "/tmp/runtime/localharness_external"),
            version: "fixture"
        )
        let environment = AntigravityACPProfile.launchEnvironment(
            installation: installation,
            layout: layout,
            base: [
                "PATH": "/usr/bin:/bin",
                "GEMINI_API_KEY": "must-not-leak",
                "GOOGLE_API_KEY": "must-not-leak",
                "GOOGLE_APPLICATION_CREDENTIALS": "/must/not/leak.json",
                "GEMINI_HOME": "/must/not/reuse",
                "BROWSER": "must-not-run",
            ]
        )

        XCTAssertNil(environment["GEMINI_API_KEY"])
        XCTAssertNil(environment["GOOGLE_API_KEY"])
        XCTAssertNil(environment["GOOGLE_APPLICATION_CREDENTIALS"])
        XCTAssertEqual(environment["GEMINI_HOME"], layout.profileDirectory.path)
        XCTAssertEqual(environment["AGY_ACP_FORCE_FILE_STORAGE"], "1")
        XCTAssertEqual(environment["ANTIGRAVITY_HARNESS_PATH"], installation.harness.path)
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    }

    func testACPContentUsesNativeAudioInsteadOfWorkspacePathHint() throws {
        let audio = Data("audio fixture".utf8)
        let block = try AntigravityACPContent.block(
            for: .data(audio, named: "lecture.m4a")
        )

        XCTAssertEqual(
            block,
            .audio(data: audio, mimeType: "audio/m4a")
        )
    }

    func testOversizeACPRecordingIsPlannedAsSafeOrderedChunks() {
        let chunks = AntigravityAudioPreparer.plannedRanges(
            fileBytes: 55_884_344,
            durationSeconds: 3_335.253333
        )

        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks.first?.exportStartSeconds, 0)
        XCTAssertEqual(chunks.last?.exportEndSeconds ?? 0, 3_335.253333, accuracy: 0.001)
        XCTAssertTrue(chunks.allSatisfy {
            $0.estimatedBytes <= AntigravityACPContent.maximumAudioBytes
        })
        XCTAssertEqual(
            zip(chunks, chunks.dropFirst()).map {
                $1.coreStartSeconds - $0.exportEndSeconds
            },
            [-5, -5, -5]
        )
        XCTAssertEqual(
            zip(chunks, chunks.dropFirst()).map {
                $1.exportStartSeconds - $0.coreEndSeconds
            },
            [-5, -5, -5]
        )
    }

    func testQuietBoundarySelectionPrefersNearbySilence() {
        let points = stride(from: 85.0, through: 115.0, by: 0.25).map { time in
            AntigravityAudioPreparer.EnergyPoint(
                timeSeconds: time,
                rootMeanSquare: abs(time - 103.25) < 0.4 ? 0.002 : 0.4
            )
        }

        let boundary = AntigravityAudioPreparer.quietestBoundary(
            near: 100,
            searchRadiusSeconds: 15,
            energy: points
        )

        XCTAssertEqual(boundary, 103.25, accuracy: 0.5)
    }

    func testOverlapShrinksForUnusuallyHighBitrateAudio() {
        let chunks = AntigravityAudioPreparer.plannedRanges(
            fileBytes: 50 * 1_024 * 1_024,
            durationSeconds: 20
        )

        XCTAssertTrue(chunks.allSatisfy {
            $0.estimatedBytes < AntigravityACPContent.maximumAudioBytes
        })
        XCTAssertTrue(chunks.dropFirst().allSatisfy {
            $0.coreStartSeconds - $0.exportStartSeconds < AntigravityAudioPreparer.overlapSeconds
        })
        XCTAssertEqual(
            zip(chunks, chunks.dropFirst()).map { $0.coreEndSeconds == $1.coreStartSeconds },
            [true, true, true]
        )
    }

    func testAudioEnergyInspectionFindsARealSilentBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lectern-Silence-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("silence.wav")
        try makeToneWithSilence(at: audioURL, silenceCenterSeconds: 10)

        let points = try await AntigravityAudioPreparer.energyPoints(
            in: AVURLAsset(url: audioURL),
            around: 8,
            searchRadiusSeconds: 5
        )
        let boundary = AntigravityAudioPreparer.quietestBoundary(
            near: 8,
            searchRadiusSeconds: 5,
            energy: points
        )

        XCTAssertEqual(boundary, 10, accuracy: 0.75)
    }

    func testBoundaryMergeRemovesRepeatedOverlapButPreservesLaterRepetition() {
        let existing = [
            NormalizedTranscriptionSegment(
                startMilliseconds: 1_000,
                endMilliseconds: 2_000,
                text: "Again again."
            ),
            NormalizedTranscriptionSegment(
                startMilliseconds: 8_000,
                endMilliseconds: 12_000,
                text: "The requirements are intent and consideration."
            ),
        ]
        let incoming = [
            NormalizedTranscriptionSegment(
                startMilliseconds: 8_000,
                endMilliseconds: 14_000,
                text: "... Intent and consideration. Capacity matters."
            ),
            NormalizedTranscriptionSegment(
                startMilliseconds: 16_000,
                endMilliseconds: 18_000,
                text: "Again again."
            ),
        ]

        let merged = AntigravityTranscriptMerger.merge(
            accumulated: existing,
            incoming: incoming,
            boundaryMilliseconds: 10_000,
            overlapMilliseconds: 5_000
        )

        XCTAssertEqual(
            merged.map(\.text),
            [
                "Again again.",
                "The requirements are intent and consideration.",
                "Capacity matters.",
                "Again again.",
            ]
        )
        XCTAssertEqual(merged.map(\.startMilliseconds), [1_000, 8_000, 10_000, 16_000])
    }

    func testOAuthHandoffOnlyAcceptsExpectedGoogleLoopbackFlow() throws {
        let valid = try XCTUnwrap(URL(string:
            "https://accounts.google.com/o/oauth2/v2/auth?response_type=code&state=state-123&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2F"
        ))
        XCTAssertNoThrow(try AntigravityACPAuthorization.validate(valid))

        let hostile = try XCTUnwrap(URL(string:
            "https://example.com/o/oauth2/v2/auth?response_type=code&state=state-123&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2F"
        ))
        XCTAssertThrowsError(try AntigravityACPAuthorization.validate(hostile))

        let pending = try AntigravityACPAuthorization.parse(valid)
        XCTAssertNoThrow(try AntigravityACPAuthorization.callback(
            "http://127.0.0.1:49152/?state=state-123&code=secret-code",
            for: pending
        ))
        XCTAssertThrowsError(try AntigravityACPAuthorization.callback(
            "http://127.0.0.1:49152/?state=another-flow&code=secret-code",
            for: pending
        ))
    }

    func testACPAuthenticationSurfacesGoogleURLOnlyToExplicitSignInFlow() async throws {
        let authorizationURL = "https://accounts.google.com/o/oauth2/v2/auth?response_type=code&state=state-123&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2F"
        let script = #"""
import json, sys
authorization_url = "\#(authorizationURL)"
for raw in sys.stdin:
    request = json.loads(raw)
    request_id = request.get("id")
    if request.get("method") == "initialize":
        result = {"protocolVersion":1,"agentInfo":{"name":"antigravity-acp","version":"fixture"},"agentCapabilities":{},"authMethods":[{"id":"oauth-personal","name":"Google"}]}
        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":result}), flush=True)
    elif request.get("method") == "authenticate":
        print("Open the following link to authenticate the ACP server: " + authorization_url, flush=True)
        print(json.dumps({"jsonrpc":"2.0","id":request_id,"result":{}}), flush=True)
"""#
        let recorder = ACPAuthorizationRecorder()
        let interactive = try await ACPConnection.connect(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ProcessInfo.processInfo.environment,
            onAuthorizationURL: { recorder.record($0) }
        )
        defer { interactive.shutdown() }

        try await interactive.authenticate(methodID: "oauth-personal")
        XCTAssertEqual(recorder.url?.absoluteString, authorizationURL)

        let normal = try await ACPConnection.connect(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ProcessInfo.processInfo.environment
        )
        defer { normal.shutdown() }
        do {
            try await normal.authenticate(methodID: "oauth-personal")
            XCTFail("A normal ACP launch must not start an interactive browser sign-in.")
        } catch ACPConnection.ACPError.authRequired(let methods) {
            XCTAssertEqual(methods, ["oauth-personal"])
        }
    }

    func testManagedRuntimeLeaseBlocksRemovalUntilConnectionCloses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lectern-ACP-Installer-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AntigravityACPLayout(root: root)
        let installer = AntigravityACPInstaller(layout: layout)
        let releaseID = String(repeating: "a", count: 64)
        let releaseDirectory = layout.versionsDirectory.appendingPathComponent(releaseID, isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        let executable = releaseDirectory.appendingPathComponent("agy_acp_server.par")
        let harness = releaseDirectory.appendingPathComponent("localharness_external")
        try Data("exec".utf8).write(to: executable)
        try Data("harness".utf8).write(to: harness)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.path)
        let releaseRecord = #"{"releaseId":"\#(releaseID)","version":"fixture","executable":{"name":"agy_acp_server.par","bytes":4},"harness":{"name":"localharness_external","bytes":7}}"#
        try Data(releaseRecord.utf8).write(
            to: releaseDirectory.appendingPathComponent(".install-complete.json")
        )
        try FileManager.default.createDirectory(at: layout.managedDirectory, withIntermediateDirectories: true)
        try Data(#"{"releaseId":"\#(releaseID)"}"#.utf8).write(to: layout.activeRecord)

        let acquired = try await installer.acquire()
        XCTAssertEqual(acquired.installation.version, "fixture")
        do {
            try await installer.removeManagedRuntime()
            XCTFail("A leased runtime must not be removed.")
        } catch let error as AntigravityACPError {
            XCTAssertTrue(error.localizedDescription.contains("currently in use"))
        }

        await installer.release(leaseID: acquired.leaseID)
        try await installer.removeManagedRuntime()
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.managedDirectory.path))
    }

    func testACPHandshakeCorrelationLogoutAndNativeAudioWithMockAgent() async throws {
        let script = #"""
import json, sys
pending_sessions = []
for raw in sys.stdin:
    request = json.loads(raw)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        sys.stdout.write("not-json\n")
        result = {
            "protocolVersion": 1,
            "agentInfo": {"name": "antigravity-acp", "version": "fixture"},
            "agentCapabilities": {
                "loadSession": True,
                "sessionCapabilities": {"resume": {}},
                "auth": {"logout": {}}
            },
            "authMethods": [{"id": "oauth-personal", "name": "Google"}]
        }
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":result}), flush=True)
    elif method == "authenticate" or method == "logout":
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{}}), flush=True)
    elif method == "session/new":
        pending_sessions.append(request)
        if len(pending_sessions) == 2:
            for item in reversed(pending_sessions):
                name = item["params"]["cwd"].rsplit("/", 1)[-1]
                result = {"sessionId": name, "configOptions": []}
                print(json.dumps({"jsonrpc":"2.0", "id":item["id"], "result":result}), flush=True)
    elif method == "session/prompt":
        blocks = request["params"]["prompt"]
        assert any(block.get("type") == "audio" for block in blocks)
        session_id = request["params"]["sessionId"]
        update = {"sessionId":session_id,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"native audio ok"}}}
        print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":update}), flush=True)
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{"stopReason":"end_turn"}}), flush=True)
"""#
        let connection = try await ACPConnection.connect(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            environment: ProcessInfo.processInfo.environment
        )
        defer { connection.shutdown() }

        XCTAssertEqual(connection.identity?.name, "antigravity-acp")
        XCTAssertEqual(connection.initialization?.authMethodIDs, ["oauth-personal"])
        XCTAssertEqual(connection.initialization?.supportsResume, true)
        XCTAssertEqual(connection.initialization?.supportsLogout, true)
        try await connection.authenticate(methodID: "oauth-personal")

        async let first = connection.newSession(workingDirectory: URL(fileURLWithPath: "/tmp/first"))
        async let second = connection.newSession(workingDirectory: URL(fileURLWithPath: "/tmp/second"))
        let (firstSession, secondSession) = try await (first, second)
        let sessionIDs = Set([firstSession.id, secondSession.id])
        XCTAssertEqual(sessionIDs, Set(["first", "second"]))

        let output = try await connection.prompt(
            sessionID: "first",
            blocks: [.text("Transcribe."), .audio(data: Data("audio".utf8), mimeType: "audio/wav")]
        )
        XCTAssertEqual(output, "native audio ok")
        try await connection.logout()
    }

    func testExternalTranscriptionUsesAuthenticatedACPWithNativeAudio() async throws {
        let script = #"""
import base64, json, sys
model = "gemini-3.8-flash-high"
for raw in sys.stdin:
    request = json.loads(raw)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        result = {
            "protocolVersion": 1,
            "agentInfo": {"name": "antigravity-acp", "version": "fixture"},
            "agentCapabilities": {
                "loadSession": True,
                "sessionCapabilities": {"resume": True},
                "auth": {"logout": True}
            },
            "authMethods": [{"id": "oauth-personal", "name": "Google"}]
        }
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":result}), flush=True)
    elif method == "authenticate":
        assert request["params"]["methodId"] == "oauth-personal"
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{}}), flush=True)
    elif method == "session/new":
        option = {
            "id": "model", "category": "model", "currentValue": model,
            "options": [{"value": model, "name": "Gemini 3.8 Flash (High)"}]
        }
        result = {"sessionId": "transcription-session", "configOptions": [option]}
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":result}), flush=True)
    elif method == "session/prompt":
        blocks = request["params"]["prompt"]
        audio = next(block for block in blocks if block.get("type") == "audio")
        assert audio["mimeType"] == "audio/wav"
        assert base64.b64decode(audio["data"]) == b"mock wave bytes"
        text = "\n".join(block.get("text", "") for block in blocks if block.get("type") == "text")
        assert "fixture transcription instructions" in text
        session_id = request["params"]["sessionId"]
        transcript = "[00:00] Professor: Opening words.\n\n[00:05] Student: A question."
        update = {"sessionId":session_id,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":transcript}}}
        print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":update}), flush=True)
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{"stopReason":"end_turn"}}), flush=True)
"""#
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lectern-ACP-Transcription-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let audioURL = fixtureRoot.appendingPathComponent("lecture.wav")
        try Data("mock wave bytes".utf8).write(to: audioURL)
        let skillURL = fixtureRoot.appendingPathComponent("SKILL.md")
        try Data("fixture transcription instructions".utf8).write(to: skillURL)

        let client = AntigravityACPClient(
            connectionFactory: {
                try await ACPConnection.connect(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-u", "-c", script],
                    environment: ProcessInfo.processInfo.environment
                )
            },
            skillURLOverrides: [.transcription: skillURL]
        )
        let engine = ExternalTranscriptionEngine(antigravity: client)
        let request = ExternalTranscriptionRequest(
            audioURL: audioURL,
            durationSeconds: 10,
            lectureLanguage: .english,
            connection: .builtInAntigravity(),
            attemptNumber: 1
        )

        let result = try await engine.transcribe(request) { _ in }

        XCTAssertEqual(result.text, "Opening words.\n\nA question.")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].speakerID, "Professor")
        XCTAssertEqual(result.segments[1].startMilliseconds, 5_000)
        XCTAssertEqual(result.providerInfo.provider, .antigravityCLI)
        XCTAssertEqual(result.providerInfo.resolvedModelID, AntigravityACPClient.transcriptionModelID)
    }

    func testExternalTranscriptionSendsPreparedAudioPartsThroughACPInOrder() async throws {
        let script = #"""
import base64, json, sys
model = "gemini-3.8-flash-high"
for raw in sys.stdin:
    request = json.loads(raw)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        result = {
            "protocolVersion": 1,
            "agentInfo": {"name": "antigravity-acp", "version": "fixture"},
            "agentCapabilities": {},
            "authMethods": [{"id": "oauth-personal", "name": "Google"}]
        }
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":result}), flush=True)
    elif method == "authenticate":
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{}}), flush=True)
    elif method == "session/new":
        option = {
            "id": "model", "category": "model", "currentValue": model,
            "options": [{"value": model, "name": "Gemini 3.8 Flash (High)"}]
        }
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{"sessionId":"part", "configOptions":[option]}}), flush=True)
    elif method == "session/prompt":
        blocks = request["params"]["prompt"]
        audio = next(block for block in blocks if block.get("type") == "audio")
        payload = base64.b64decode(audio["data"])
        transcript = (
            "[00:08] The requirements are intent and consideration."
            if payload == b"part one"
            else "[00:03] Intent and consideration. Capacity matters."
        )
        update = {"sessionId":"part","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":transcript}}}
        print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":update}), flush=True)
        print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{"stopReason":"end_turn"}}), flush=True)
"""#
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lectern-ACP-Parts-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let source = fixtureRoot.appendingPathComponent("source.wav")
        let first = fixtureRoot.appendingPathComponent("first.wav")
        let second = fixtureRoot.appendingPathComponent("second.wav")
        try Data("source".utf8).write(to: source)
        try Data("part one".utf8).write(to: first)
        try Data("part two".utf8).write(to: second)
        let skillURL = fixtureRoot.appendingPathComponent("SKILL.md")
        try Data("fixture transcription instructions".utf8).write(to: skillURL)

        let client = AntigravityACPClient(
            connectionFactory: {
                try await ACPConnection.connect(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-u", "-c", script],
                    environment: ProcessInfo.processInfo.environment
                )
            },
            skillURLOverrides: [.transcription: skillURL]
        )
        let engine = ExternalTranscriptionEngine(
            antigravity: client,
            antigravityAudioPreparation: { _, _ in
                AntigravityAudioPreparer.PreparedAudio(
                    chunks: [
                        .init(
                            url: first,
                            startSeconds: 0,
                            durationSeconds: 15,
                            coreStartSeconds: 0,
                            coreEndSeconds: 10
                        ),
                        .init(
                            url: second,
                            startSeconds: 5,
                            durationSeconds: 15,
                            coreStartSeconds: 10,
                            coreEndSeconds: 20
                        ),
                    ],
                    temporaryDirectory: nil
                )
            }
        )
        let request = ExternalTranscriptionRequest(
            audioURL: source,
            durationSeconds: 20,
            lectureLanguage: .english,
            connection: .builtInAntigravity(),
            attemptNumber: 1
        )

        let result = try await engine.transcribe(request) { _ in }

        XCTAssertEqual(
            result.text,
            "The requirements are intent and consideration.\n\nCapacity matters."
        )
        XCTAssertEqual(result.segments.map(\.startMilliseconds), [8_000, 10_000])
        XCTAssertEqual(result.audioDurationMilliseconds, 20_000)
        XCTAssertEqual(result.providerInfo.provider, .antigravityCLI)
    }

    private func makeToneWithSilence(
        at url: URL,
        silenceCenterSeconds: Double
    ) throws {
        let sampleRate = 8_000.0
        let durationSeconds = 16.0
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            samples[frame] = abs(time - silenceCenterSeconds) <= 0.6
                ? 0
                : Float(sin(2 * Double.pi * 220 * time) * 0.3)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private final class ACPAuthorizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL?

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedURL
    }

    func record(_ url: URL) {
        lock.lock()
        storedURL = url
        lock.unlock()
    }
}
