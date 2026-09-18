import Foundation
import Darwin
import SwiftData
import XCTest

final class TranscriptionReliabilityTests: XCTestCase {
    func testLiveManagedToolAttemptWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["LECTERN_LIVE_RELIABILITY_AUDIO"] != nil else {
            throw XCTSkip("Live runtime probe requires explicit opt-in")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(UUID().uuidString.utf8).write(to: root.appendingPathComponent("fixture.txt"))
        let connection = try await AntigravityACPManager.shared.makeConnection(transcriptionOnly: true)
        defer { connection.shutdown() }
        try await connection.authenticate(methodID: "oauth-personal")
        let session = try await connection.newSession(workingDirectory: root)
        try await connection.requireMode(sessionID: session.id, modeID: "default")
        try await connection.applyAntigravityGenerationSettings(session: session,
            model: AntigravityACPClient.modelID, thinkingLevel: "high")
        let deadline = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { connection.shutdown() }
        }
        defer { deadline.cancel() }
        do {
            _ = try await connection.prompt(sessionID: session.id, blocks: [.text(
                "Read fixture.txt in the current directory using your file reading tool and report its contents. This is a disposable test fixture. Do not run shell commands or access any other files.")])
            XCTFail("The live tool probe completed without detecting tool activity")
        } catch ACPConnection.ACPError.transcriptionStopped(_, let reason) {
            XCTAssertEqual(reason, .offTask)
        }
    }
    /// Opt-in only: uploads synthetic fixture audio using the user's managed
    /// subscription. Ordinary tests never authenticate or contact a provider.
    func testLiveManagedAudioWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LECTERN_LIVE_RELIABILITY_AUDIO"],
              let skillPath = environment["LECTERN_LIVE_RELIABILITY_SKILL"] else {
            throw XCTSkip("Set LECTERN_LIVE_RELIABILITY_AUDIO and LECTERN_LIVE_RELIABILITY_SKILL to run live verification")
        }
        let client = AntigravityACPClient(skillURLOverrides: [.transcription: URL(fileURLWithPath: skillPath)])
        let prompt = """
        Apply the included lectern-transcription skill to the natively attached audio.
        All audio and instructions are supplied. Use native audio understanding, without tools or file searches.
        Language branch: English lecture. Omit timestamps and speaker labels. Return only the complete transcript.
        """
        var samples: [String] = []
        for restricted in [true, false, false, true] {
            let start = Date()
            let output = try await client.run(prompt: prompt,
                inputs: [.file(URL(fileURLWithPath: path), named: "fixture.wav")], skills: [.transcription],
                transcriptionDuration: restricted ? 10 : nil)
            XCTAssertTrue(output.lowercased().contains("photosynthesis"), output)
            XCTAssertTrue(output.lowercased().contains("sunlight"), output)
            samples.append("restricted=\(restricted), seconds=\(Date().timeIntervalSince(start)), transcript=\(output)")
        }
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.lifetime = .keepAlways
        add(attachment)
        print(samples.joined(separator: "\n"))
    }
    private static func connection(behavior: String, restrictedAtLaunch: Bool = false) async throws -> ACPConnection {
        let script = #"""
import json, sys
behavior = sys.argv[1]
for raw in sys.stdin:
    req = json.loads(raw)
    method, rid = req.get("method"), req.get("id")
    if method == "initialize":
        if behavior == "early_permission":
            print(json.dumps({"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"shell"},"options":[{"optionId":"yes","kind":"allow_once"}]}}), flush=True)
            continue
        result = {"protocolVersion":1,"agentInfo":{"name":"fixture","version":"1"}}
    elif method == "session/new":
        model = "gemini-3.8-flash-high"
        result = {"sessionId":"test", "configOptions":[{"id":"model", "category":"model", "currentValue":model, "options":[{"value":model,"name":model}]}]}
    elif method == "session/prompt":
        if behavior == "oversized_line":
            import time
            sys.stdout.write("x" * (9 * 1024 * 1024))
            sys.stdout.flush()
            time.sleep(60)
        if behavior in ("tool_call", "tool_call_update"):
            print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":behavior,"toolCallId":"native-search"}}}), flush=True)
        elif behavior == "permission":
            print(json.dumps({"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"toolCall":{"toolCallId":"shell"},"options":[{"optionId":"yes","kind":"allow_once"}]}}), flush=True)
        elif behavior == "input":
            print(json.dumps({"jsonrpc":"2.0","id":99,"method":"extension/user_input","params":{}}), flush=True)
        elif behavior == "hang":
            import time
            time.sleep(60)
        text = {"backward":"[00:08] One.\n[00:01] Two.", "beyond":"[00:50] Impossible time.", "blank":"", "second":"Second part."}.get(behavior, "Clean transcript.")
        if behavior == "oversized": text = "x" * (4 * 1024 * 1024 + 1)
        update = {"sessionId":"test","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}
        print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":update}), flush=True)
        result = {"stopReason":"max_tokens" if behavior == "truncated" else "end_turn"}
    else:
        result = {}
    if method is not None:
        print(json.dumps({"jsonrpc":"2.0","id":rid,"result":result}), flush=True)
"""#
        return try await ACPConnection.connect(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script, behavior], environment: ProcessInfo.processInfo.environment,
            transcriptionOnly: restrictedAtLaunch)
    }

    func testRestrictionsApplyBeforeInitializationCompletes() async throws {
        do {
            let connection = try await Self.connection(behavior: "early_permission", restrictedAtLaunch: true)
            connection.shutdown()
            XCTFail("Initialization permission must stop transcription")
        } catch ACPConnection.ACPError.transcriptionStopped(_, let reason) {
            XCTAssertEqual(reason, .offTask)
        }
    }

    func testCheckpointStorageFailureDoesNotLoseSuccessfulTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("audio.wav")
        let skill = root.appendingPathComponent("SKILL.md")
        let unwritable = root.appendingPathComponent("cache")
        try Data("audio".utf8).write(to: source)
        try Data("Transcribe natively.".utf8).write(to: skill)
        try Data("a file cannot contain checkpoint directories".utf8).write(to: unwritable)
        let client = AntigravityACPClient(connectionFactory: { try await Self.connection(behavior: "normal") },
                                         skillURLOverrides: [.transcription: skill])
        let engine = ExternalTranscriptionEngine(antigravity: client, chunkStore: .init(root: unwritable))
        let result = try await engine.transcribe(.init(audioURL: source, durationSeconds: 10,
            lectureLanguage: .english, connection: .builtInAntigravity(), attemptNumber: 1)) { _ in }
        XCTAssertEqual(result.text, "Clean transcript.")
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testShutdownPreservesReasonAndKillsOwnedChildAfterParentExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child.pid")
        let script = #"""
import json, sys, subprocess, time
from pathlib import Path
child_code = "import os, signal, sys, time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)"
for raw in sys.stdin:
    req = json.loads(raw)
    if req.get("method") == "initialize":
        subprocess.Popen([sys.executable, "-c", child_code, sys.argv[1]])
        for _ in range(200):
            if Path(sys.argv[1]).exists(): break
            time.sleep(.01)
        print(json.dumps({"jsonrpc":"2.0", "id":req["id"], "result":{"protocolVersion":1}}), flush=True)
"""#
        let connection = try await ACPConnection.connect(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script, marker.path], environment: ProcessInfo.processInfo.environment,
            transcriptionOnly: true)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        defer { kill(pid, SIGKILL); connection.shutdown() }
        connection.shutdown(error: ACPConnection.ACPError.transcriptionStopped("Fixture timeout", reason: .timeout))
        connection.shutdown()
        do {
            _ = try await connection.newSession(workingDirectory: root)
            XCTFail("Closed connection accepted a request")
        } catch ACPConnection.ACPError.transcriptionStopped(_, let reason) {
            XCTAssertEqual(reason, .timeout)
        }
        for _ in 0..<80 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Owned child survived after its parent exited")
    }

    func testTranscriptionRejectsToolsPermissionsInputAndTruncatedOutput() async throws {
        for behavior in ["tool_call", "tool_call_update", "permission", "input", "truncated", "oversized", "oversized_line"] {
            let connection = try await Self.connection(behavior: behavior, restrictedAtLaunch: true)
            defer { connection.shutdown() }
            connection.restrictToTranscription()
            let session = try await connection.newSession(workingDirectory: FileManager.default.temporaryDirectory)
            do {
                _ = try await connection.prompt(sessionID: session.id, blocks: [.text("Transcribe")])
                XCTFail("Accepted unsafe or incomplete output: \(behavior)")
            } catch ACPConnection.ACPError.transcriptionStopped { }
        }
    }

    func testGenerationStillAcceptsToolNotificationsAndNormalTranscriptionCompletes() async throws {
        for restricted in [false, true] {
            let connection = try await Self.connection(behavior: restricted ? "normal" : "tool_call")
            defer { connection.shutdown() }
            if restricted { connection.restrictToTranscription() }
            let session = try await connection.newSession(workingDirectory: FileManager.default.temporaryDirectory)
            let result = try await connection.prompt(sessionID: session.id, blocks: [.text("Output")])
            XCTAssertEqual(result, "Clean transcript.")
        }
    }

    @MainActor
    func testChunkPercentageUsesAcceptedParts() {
        let progress = TranscriptionService.Progress(message: nil, subtitle: nil, completedChunks: 2, totalChunks: 10)
        XCTAssertEqual(progress.fractionCompleted, 0.2)
        XCTAssertNil(TranscriptionService.Progress(message: nil, subtitle: nil).fractionCompleted)
    }

    @MainActor
    func testCompletedJobRecoveryRevalidatesChunksAndExplicitRetranscriptionStartsFresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        let skill = root.appendingPathComponent("SKILL.md")
        try Data("audio".utf8).write(to: audio)
        try Data("Transcribe natively.".utf8).write(to: skill)
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let lecture = Lecture(title: "Interrupted artifact save", capturedAt: Date(), status: .transcribing)
        lecture.recording = Recording(filePath: audio.path, sampleRate: 16_000, sizeBytes: 5, recordedAt: Date())
        container.mainContext.insert(lecture)
        try container.mainContext.save()
        let suite = "TranscriptionReliabilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        let connection = TranscriptionConnection.builtInAntigravity()
        let jobs = TranscriptionJobStore(fileURL: root.appendingPathComponent("jobs.json"))
        let values = try audio.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var job = PersistentTranscriptionJob(recordingPath: audio.path,
            sourceAudioHash: "\(audio.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)",
            state: .completed, selectedConnectionID: connection.id,
            fallbackPlanSnapshot: [connection.id], policySnapshot: preferences.snapshot())
        job.completedResult = .init(text: "Unverified old result", segments: [.init(text: "Unverified old result")],
            detectedLanguages: ["en"], providerInfo: .init(connectionID: connection.id, provider: .antigravityCLI,
                requestedModelID: connection.modelID, attemptNumber: 1,
                processingMode: connection.processingMode, completedAt: Date()), warnings: [])
        await jobs.upsert(job)
        let observed = Observations()
        let client = AntigravityACPClient(connectionFactory: {
            _ = await observed.call()
            return try await Self.connection(behavior: "normal")
        }, skillURLOverrides: [.transcription: skill])
        let engine = ExternalTranscriptionEngine(antigravity: client, chunkStore: .init(root: root.appendingPathComponent("cache")))
        let service = TranscriptionService(modelContainer: container, preferences: preferences,
            completionNotifier: SilentNotifier(), externalEngine: engine, jobStore: jobs)
        defer { service.cancelAll() }
        service.enqueue(lectureID: lecture.persistentModelID)
        for _ in 0..<500 where service.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(lecture.status, .ready, lecture.statusMessage ?? "")
        XCTAssertEqual(lecture.artifact(of: .rawTranscript)?.content, "Clean transcript.")
        let recoveredCalls = await observed.calls
        XCTAssertEqual(recoveredCalls, 1, "Completed history must not bypass checkpoint verification")
        service.retranscribe(lecture, as: lecture.language)
        for _ in 0..<500 where service.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(lecture.status, .ready, lecture.statusMessage ?? "")
        let freshCalls = await observed.calls
        XCTAssertEqual(freshCalls, 2, "Explicit retranscription must not reuse the completed job's chunks")
    }

    private final class SilentNotifier: CompletionNotifying {
        func prepare(for category: CompletionNotificationCategory) {}
        func deliver(_ notification: CompletionNotification) {}
    }

    func testCheckpointKeyTracksAudioSettingsAndSkillAndSurvivesReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("audio.wav")
        try Data("audio1".utf8).write(to: source)
        let store = TranscriptionChunkStore(root: root.appendingPathComponent("cache"))
        var request = ExternalTranscriptionRequest(audioURL: source, durationSeconds: 20, lectureLanguage: .english,
                                                  connection: .builtInAntigravity(), attemptNumber: 1)
        let first = try await store.key(for: request, skillFingerprint: "skill1")
        let changedSkill = try await store.key(for: request, skillFingerprint: "skill2")
        XCTAssertNotEqual(first, changedSkill)
        request.connection.diarizationEnabled.toggle()
        let changedSettings = try await store.key(for: request, skillFingerprint: "skill1")
        XCTAssertNotEqual(first, changedSettings)
        request.connection.diarizationEnabled.toggle()
        let date = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data("audio2".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let changedAudio = try await store.key(for: request, skillFingerprint: "skill1")
        XCTAssertNotEqual(first, changedAudio, "Same size and modification time must not conceal changed audio")
        try await store.save(.init(ranges: [.init(start: 0, duration: 20, coreStart: 0, coreEnd: 20)]), key: first)
        let reloaded = TranscriptionChunkStore(root: root.appendingPathComponent("cache"))
        let manifest = await reloaded.manifest(key: first)
        XCTAssertEqual(manifest?.ranges.count, 1)
        try Data("broken".utf8).write(to: root.appendingPathComponent("cache/\(first)/manifest.json"))
        let corrupt = await reloaded.manifest(key: first)
        XCTAssertNil(corrupt)
    }

    func testCorruptPartIsIgnoredAndDeletingLectureRemovesOnlyItsCheckpoints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptionChunkStore(root: root)
        let first = String(repeating: "a", count: 64)
        let second = String(repeating: "b", count: 64)
        let ranges = [TranscriptionChunkStore.Range(start: 0, duration: 20, coreStart: 0, coreEnd: 20)]
        try await store.save(.init(ranges: ranges, sourcePath: "/first.wav"), key: first)
        try await store.save(.init(ranges: ranges, sourcePath: "/second.wav"), key: second)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(first + "/part-0.json"))
        let part = await store.result(key: first, index: 0)
        XCTAssertNil(part)
        await store.discard(sourcePath: "/first.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(first).path))
        let surviving = await store.manifest(key: second)
        XCTAssertEqual(surviving?.sourcePath, "/second.wav")
    }

    private actor Observations {
        var calls = 0
        var progress: [Int] = []
        func call() -> Int { calls += 1; return calls }
        func record(_ update: ProviderJobUpdate) {
            if let completed = update.completedChunks { progress.append(completed) }
        }
    }

    func testTimeoutHasOnlyOneFreshSessionRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        let skill = root.appendingPathComponent("SKILL.md")
        try Data("audio".utf8).write(to: audio)
        try Data("Transcribe natively.".utf8).write(to: skill)
        let observed = Observations()
        let client = AntigravityACPClient(connectionFactory: {
            _ = await observed.call()
            return try await Self.connection(behavior: "hang")
        }, skillURLOverrides: [.transcription: skill], transcriptionTimeout: .milliseconds(100))
        let engine = ExternalTranscriptionEngine(antigravity: client, chunkStore: .init(root: root.appendingPathComponent("cache")))
        do {
            _ = try await engine.transcribe(.init(audioURL: audio, durationSeconds: 10,
                lectureLanguage: .english, connection: .builtInAntigravity(), attemptNumber: 1)) { _ in }
            XCTFail("Hung prompts must time out")
        } catch let error as ExternalTranscriptionError {
            XCTAssertEqual(error.code, .timeout)
        }
        let calls = await observed.calls
        XCTAssertEqual(calls, 2, "Outer engine retries must not multiply the chunk retry budget")
    }

    func testManagedProfileAutomationCheckIsBoundedAndReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AntigravityACPLayout(root: root)
        try AntigravityACPProfile.prepare(layout: layout)
        XCTAssertNoThrow(try AntigravityACPProfile.validateTranscriptionConfiguration(layout: layout))
        let settings = layout.acpProfileDirectory.appendingPathComponent("settings.json")
        let data = Data(#"{"hooks":{"afterAgent":"command"}}"#.utf8)
        try data.write(to: settings)
        XCTAssertThrowsError(try AntigravityACPProfile.validateTranscriptionConfiguration(layout: layout))
        XCTAssertEqual(try Data(contentsOf: settings), data)
    }

    func testMalformedTranscriptIsNeverCheckpointed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("audio.wav")
        let skill = root.appendingPathComponent("SKILL.md")
        try Data("audio".utf8).write(to: source)
        try Data("Transcribe natively.".utf8).write(to: skill)
        for behavior in ["backward", "beyond", "blank"] {
            let store = TranscriptionChunkStore(root: root.appendingPathComponent(behavior))
            let client = AntigravityACPClient(connectionFactory: { try await Self.connection(behavior: behavior) },
                                             skillURLOverrides: [.transcription: skill])
            let engine = ExternalTranscriptionEngine(antigravity: client, chunkStore: store)
            let request = ExternalTranscriptionRequest(audioURL: source, durationSeconds: 10, lectureLanguage: .english,
                connection: .builtInAntigravity(), attemptNumber: 1)
            do {
                _ = try await engine.transcribe(request) { _ in }
                XCTFail("Invalid output accepted: \(behavior)")
            } catch let error as ExternalTranscriptionError { XCTAssertEqual(error.code, .malformedResponse) }
            let key = try await store.key(for: request, skillFingerprint: client.transcriptionSkillFingerprint())
            let result = await store.result(key: key, index: 0)
            XCTAssertNil(result)
        }
    }

    func testCheckpointWritesStayBelowLocalLatencyBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptionChunkStore(root: root)
        let connection = TranscriptionConnection.builtInAntigravity()
        let segments = (0..<300).map { NormalizedTranscriptionSegment(text: "Segment \($0): " + String(repeating: "lecture words ", count: 20)) }
        let result = TranscriptionResult(text: segments.map(\.text).joined(separator: "\n"), segments: segments,
            detectedLanguages: ["en"], providerInfo: .init(connectionID: connection.id, provider: .antigravityCLI,
                requestedModelID: connection.modelID, resolvedModelID: connection.modelID,
                attemptNumber: 1, processingMode: connection.processingMode, completedAt: Date()), warnings: [])
        var samples: [Double] = []
        for index in 0..<30 {
            let start = Date()
            try await store.save(result, key: String(repeating: "a", count: 64), index: index)
            samples.append(Date().timeIntervalSince(start))
        }
        let p95 = samples.sorted()[28]
        let attachment = XCTAttachment(string: "Checkpoint atomic write p95: \(p95 * 1000) ms; 300-segment transcript, 30 samples, debug build.")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(p95, 0.1)
    }

    func testFailedSecondPartResumesFromCheckpointInNewEngineWithoutReplayingFirst() async throws {
        try await verifyResume(cancelled: false)
    }

    func testCancelledSecondPartResumesFromCheckpointOnlyWhenRequested() async throws {
        try await verifyResume(cancelled: true)
    }

    private func verifyResume(cancelled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio.wav")
        let skill = root.appendingPathComponent("SKILL.md")
        try Data("fixture audio".utf8).write(to: audio)
        try Data("Transcribe the natively attached audio.".utf8).write(to: skill)
        let initial = Observations()
        let preparation: ExternalTranscriptionEngine.AntigravityAudioPreparation = { _, _ in
            .init(chunks: [
                .init(url: audio, startSeconds: 0, durationSeconds: 10, coreStartSeconds: 0, coreEndSeconds: 10),
                .init(url: audio, startSeconds: 10, durationSeconds: 10, coreStartSeconds: 10, coreEndSeconds: 20)
            ], temporaryDirectory: nil)
        }
        let firstClient = AntigravityACPClient(connectionFactory: {
            let call = await initial.call()
            return try await Self.connection(behavior: call == 1 ? "normal" : (cancelled ? "hang" : "tool_call"))
        }, skillURLOverrides: [.transcription: skill], sessionPool: AISessionPool(limit: 1))
        let cache = root.appendingPathComponent("cache")
        let firstEngine = ExternalTranscriptionEngine(antigravity: firstClient,
            chunkStore: TranscriptionChunkStore(root: cache), antigravityAudioPreparation: preparation)
        let request = ExternalTranscriptionRequest(audioURL: audio, durationSeconds: 20,
            lectureLanguage: .english, connection: .builtInAntigravity(), attemptNumber: 1, checkpointID: UUID())
        let firstRun = Task { try await firstEngine.transcribe(request) { await initial.record($0) } }
        if cancelled {
            for _ in 0..<500 {
                if await initial.calls >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            firstRun.cancel()
        }
        do {
            _ = try await firstRun.value
            XCTFail("Interrupted second chunk must stop the attempt")
        } catch let error as ExternalTranscriptionError {
            XCTAssertEqual(error.code, cancelled ? .cancelled : .offTask)
        }
        let firstCalls = await initial.calls
        let firstProgress = await initial.progress
        XCTAssertEqual(firstCalls, 2, "Policy violations must not trigger nested retries")
        XCTAssertEqual(firstProgress, [0, 1])
        let resumed = Observations()
        let resumedClient = AntigravityACPClient(connectionFactory: {
            _ = await resumed.call()
            return try await Self.connection(behavior: "second")
        }, skillURLOverrides: [.transcription: skill])
        let resumedEngine = ExternalTranscriptionEngine(antigravity: resumedClient,
            chunkStore: TranscriptionChunkStore(root: cache), antigravityAudioPreparation: preparation)
        let result = try await resumedEngine.transcribe(request) { await resumed.record($0) }
        let resumedCalls = await resumed.calls
        let resumedProgress = await resumed.progress
        XCTAssertEqual(resumedCalls, 1)
        XCTAssertEqual(resumedProgress, [1, 2])
        XCTAssertEqual(result.text, "Clean transcript.\n\nSecond part.")
    }
}
