import XCTest
import Darwin

final class AntigravityCLITests: XCTestCase {
    func testModelListParserFindsVerifiedHighModelSlug() {
        let output = """
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
        """
        XCTAssertEqual(
            AntigravityCLI.parseModelList(output),
            ["gemini-3.8-flash-high", "gemini-3.8-flash-medium"]
        )
        XCTAssertEqual(
            AntigravityCLI.parseModels(output),
            [
                .init(id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)"),
                .init(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash (Medium)"),
            ]
        )
    }

    func testResponseParserRequiresSuccessfulJSONEnvelope() throws {
        let success = Data(#"{"status":"SUCCESS","response":"notes\n","error":null}"#.utf8)
        XCTAssertEqual(try AntigravityCLI.parseResponse(success), "notes")

        let failure = Data(#"{"status":"ERROR","response":"","error":"authentication required"}"#.utf8)
        XCTAssertThrowsError(try AntigravityCLI.parseResponse(failure)) { error in
            XCTAssertTrue(error.localizedDescription.contains("authentication required"))
        }

        let missingWorkspace = try JSONSerialization.data(withJSONObject: [
            "status": "SUCCESS",
            "response": "Missing request.md. The file was not found and there is no active workspace set.",
        ])
        XCTAssertThrowsError(try AntigravityCLI.parseResponse(missingWorkspace)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Antigravity CLI could not access Lectern's private workspace."
            )
        }
    }

    func testTranscriptionUsesDirectTimestampedOutputWithoutSchemaLoop() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternAntigravityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let audio = fixtureRoot.appendingPathComponent("fixture.wav")
        try Data("synthetic-audio".utf8).write(to: audio)
        let skill = fixtureRoot.appendingPathComponent("SKILL.md")
        try Data("---\nname: lectern-transcription\ndescription: Test fixture\n---\nTranscribe.\n".utf8).write(to: skill)

        let recorder = InvocationRecorder()
        let cli = AntigravityCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            transcriptionSkillURL: skill
        ) { _, arguments, workspace in
            let requestFileExists = FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("request.md").path
            )
            let workspaceMode = try Self.permissions(of: workspace)
            let audioMode = try Self.permissions(of: workspace.appendingPathComponent("lecture-audio.wav"))
            let installedSkill = workspace.appendingPathComponent(".agents/skills/lectern-transcription/SKILL.md")
            recorder.record(
                workspace: workspace,
                arguments: arguments,
                request: requestFileExists ? "request.md present" : "",
                workspaceMode: workspaceMode,
                audioMode: audioMode,
                skillInstalled: FileManager.default.fileExists(atPath: installedSkill.path)
            )

            let transcript = """
            [00:00] Professor: Hello world.
            [00:01] Student: Is this a question?
            """
            return try JSONSerialization.data(withJSONObject: [
                "status": "SUCCESS",
                "response": transcript,
            ])
        }
        let connection = TranscriptionConnection(
            displayName: "Antigravity",
            provider: .antigravityCLI,
            modelID: "gemini-3.8-flash-low",
            diarizationEnabled: true,
            cloudUploadConsent: true
        )
        let request = ExternalTranscriptionRequest(
            audioURL: audio,
            durationSeconds: 1,
            lectureLanguage: .english,
            connection: connection,
            attemptNumber: 1
        )

        let result = try await ExternalTranscriptionEngine(antigravity: cli).transcribe(request) { _ in }
        XCTAssertEqual(result.text, "Hello world.\n\nIs this a question?")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].startMilliseconds, 0)
        XCTAssertEqual(result.segments[0].endMilliseconds, 1_000)
        XCTAssertEqual(result.segments[0].speakerID, "Professor")
        XCTAssertEqual(result.segments[1].startMilliseconds, 1_000)
        XCTAssertEqual(result.segments[1].endMilliseconds, 1_000)
        XCTAssertEqual(result.segments[1].speakerID, "Student")
        XCTAssertEqual(result.providerInfo.provider, .antigravityCLI)
        XCTAssertEqual(result.providerInfo.requestedModelID, "gemini-3.8-flash-low")
        XCTAssertEqual(result.providerInfo.resolvedModelID, "gemini-3.8-flash-low")

        let invocation = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(invocation.request, "", "Short prompts travel inline instead of through request.md.")
        XCTAssertFalse(
            invocation.arguments.contains("--json-schema"),
            "Structured-output mode makes Antigravity loop after it has already transcribed the audio."
        )
        let printArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "-p"))
        let printPrompt = invocation.arguments[printArgument + 1]
        XCTAssertTrue(
            printPrompt.hasPrefix("/lectern-transcription "),
            "The slash command expands the installed skill deterministically."
        )
        XCTAssertTrue(
            printPrompt.contains("@lecture-audio.wav"),
            "Antigravity only uploads media referenced by the top-level print prompt."
        )
        XCTAssertTrue(invocation.arguments.contains("--sandbox"))
        XCTAssertTrue(printPrompt.contains("Do not invoke whisper-cli"))
        let modelArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "--model"))
        XCTAssertEqual(invocation.arguments[modelArgument + 1], "gemini-3.8-flash-low")
        let effortArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "--effort"))
        XCTAssertEqual(invocation.arguments[effortArgument + 1], "low")
        let timeoutArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "--print-timeout"))
        XCTAssertEqual(
            invocation.arguments[timeoutArgument + 1],
            AntigravityCLI.defaultPrintTimeout
        )
        let newProjectArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "--new-project"))
        XCTAssertGreaterThan(newProjectArgument, printArgument + 1)
        XCTAssertEqual(invocation.workspaceMode & 0o777, 0o700)
        XCTAssertEqual(invocation.audioMode & 0o777, 0o600)
        XCTAssertTrue(invocation.skillInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.workspace.path))
    }

    func testAgentProfileAndTranscriptionUseHighEffort() throws {
        let profile = try XCTUnwrap(AgentProfiles.profile(id: AgentProfiles.antigravityID))
        XCTAssertEqual(profile.model, AntigravityCLI.modelID)
        XCTAssertEqual(AntigravityCLI.modelID, "gemini-3.8-flash-high")

        let provider = try XCTUnwrap(TranscriptionProviderCatalog.provider(.antigravityCLI))
        XCTAssertEqual(provider.models.map(\.id), [AntigravityCLI.transcriptionModelID])
        XCTAssertEqual(BuiltInTranscriptionModel.antigravity.id, AntigravityCLI.transcriptionModelID)
        XCTAssertFalse(TranscriptionProviderID.antigravityCLI.requiresAPIKey)
    }

    func testStoredGemini37HighDefaultMigratesToCurrentHighModel() throws {
        let defaults = UserDefaults(suiteName: "LecternTests-antigravity-\(UUID().uuidString)")!
        defaults.set(["antigravity": "gemini-3.7-flash-high"], forKey: AgentProfiles.modelsKey)
        let profile = try XCTUnwrap(AgentProfiles.profile(id: AgentProfiles.antigravityID, userDefaults: defaults))
        XCTAssertEqual(profile.model, AntigravityCLI.modelID)
    }

    func testGeminiThinkingVariantsRewriteModelAndEffort() {
        XCTAssertEqual(AntigravityCLI.effort(for: .low), "low")
        XCTAssertEqual(AntigravityCLI.effort(for: .medium), "medium")
        XCTAssertEqual(AntigravityCLI.effort(for: .high), "high")
        XCTAssertEqual(AntigravityCLI.effort(for: .xhigh), "high")
        XCTAssertTrue(AntigravityCLI.isThinkingVariant("gemini-3.8-flash-high"))
        XCTAssertTrue(AntigravityCLI.isThinkingVariant("gemini-3.1-pro-low"))
        XCTAssertFalse(AntigravityCLI.isThinkingVariant("claude-sonnet-4-6"))
        XCTAssertEqual(
            AntigravityCLI.applyThinking(.medium, to: "gemini-3.8-flash-high"),
            "gemini-3.8-flash-medium"
        )
        XCTAssertEqual(
            AntigravityCLI.applyThinking(
                .low,
                to: "gemini-3.8-flash-high",
                availableIDs: ["gemini-3.8-flash-high", "gemini-3.8-flash-medium"]
            ),
            "gemini-3.8-flash-high",
            "Do not invent a sibling the catalog does not list."
        )
        XCTAssertEqual(
            AntigravityCLI.applyThinking(.high, to: "claude-sonnet-4-6"),
            "claude-sonnet-4-6"
        )
    }

    func testCleanupPromptAsksForParagraphProseWithoutTimestamps() {
        let prompt = Prompts.cleanedTranscript(
            rawTranscript: "[00:01] um so today we will cover osmosis",
            language: .english
        )
        XCTAssertTrue(prompt.contains("continuous prose paragraphs"))
        XCTAssertTrue(prompt.contains("no timestamps"))
        XCTAssertFalse(prompt.contains("Keep every existing `[mm:ss]` timestamp marker"))
    }

    func testNotesUseAtFilesInPrivateWorkspaceAndInstallNotesSkill() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternAntigravityNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let skill = fixtureRoot.appendingPathComponent("SKILL.md")
        try Data("---\nname: lectern-notes\ndescription: Test fixture\n---\nWrite notes.\n".utf8).write(to: skill)
        let reference = fixtureRoot.appendingPathComponent("professor-outline.txt")
        try Data("Mitochondria produce ATP.".utf8).write(to: reference)
        let referenceInput = AntigravityCLI.WorkspaceInput.file(
            reference,
            named: "lecture-reference-1-professor-outline.txt"
        )

        let recorder = NotesInvocationRecorder()
        let cli = AntigravityCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            notesSkillURL: skill
        ) { _, arguments, workspace in
            let requestURL = workspace.appendingPathComponent("request.md")
            let request = (try? String(contentsOf: requestURL, encoding: .utf8)) ?? ""
            let source = try String(contentsOf: workspace.appendingPathComponent("lecture-source.md"), encoding: .utf8)
            let supplementaryReference = try String(
                contentsOf: workspace.appendingPathComponent("lecture-reference-1-professor-outline.txt"),
                encoding: .utf8
            )
            let installedSkill = workspace.appendingPathComponent(".agents/skills/lectern-notes/SKILL.md")
            recorder.record(
                workspace: workspace,
                request: request,
                source: source,
                supplementaryReference: supplementaryReference,
                sourceMode: try Self.permissions(of: workspace.appendingPathComponent("lecture-source.md")),
                skillInstalled: FileManager.default.fileExists(atPath: installedSkill.path),
                arguments: arguments
            )
            return try JSONSerialization.data(withJSONObject: [
                "status": "SUCCESS",
                "response": "# Cells\n\n## Organelles\n\n- **Nucleus:** Stores DNA.",
            ])
        }

        let output = try await cli.run(
            prompt: AntigravityCLI.supplementaryReferenceInstruction(for: [referenceInput])
                + Prompts.antigravityNotesRequest(language: .english),
            inputs: [.text("A cell contains organelles.", named: "lecture-source.md"), referenceInput],
            skills: [.notes]
        )
        XCTAssertTrue(output.hasPrefix("# Cells"))

        let invocation = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(invocation.request, "", "Short prompts travel inline instead of through request.md.")
        let printArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "-p"))
        let printPrompt = invocation.arguments[printArgument + 1]
        XCTAssertTrue(printPrompt.hasPrefix("/lectern-notes "))
        XCTAssertTrue(printPrompt.contains("@lecture-source.md"))
        XCTAssertTrue(printPrompt.contains("@lecture-reference-1-professor-outline.txt"))
        XCTAssertTrue(printPrompt.contains("Language branch: English lecture."))
        XCTAssertEqual(invocation.source, "A cell contains organelles.")
        XCTAssertEqual(invocation.supplementaryReference, "Mitochondria produce ATP.")
        XCTAssertEqual(invocation.sourceMode & 0o777, 0o600)
        XCTAssertTrue(invocation.skillInstalled)
        XCTAssertTrue(invocation.arguments.contains("--output-format"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation.workspace.path))
    }

    func testLongPromptFallsBackToRequestFile() async throws {
        let recorder = NotesInvocationRecorder()
        let cli = AntigravityCLI(executableURL: URL(fileURLWithPath: "/usr/bin/true")) { _, arguments, workspace in
            let request = try String(contentsOf: workspace.appendingPathComponent("request.md"), encoding: .utf8)
            recorder.record(
                workspace: workspace,
                request: request,
                source: "",
                supplementaryReference: "",
                sourceMode: 0,
                skillInstalled: false,
                arguments: arguments
            )
            return try JSONSerialization.data(withJSONObject: ["status": "SUCCESS", "response": "[]"])
        }

        let longPrompt = String(repeating: "Transcript sentence. ", count: 2_000)
        XCTAssertGreaterThan(longPrompt.utf8.count, AntigravityCLI.inlinePromptLimit)
        _ = try await cli.run(prompt: longPrompt)

        let invocation = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(invocation.request, longPrompt)
        let printArgument = try XCTUnwrap(invocation.arguments.firstIndex(of: "-p"))
        let printPrompt = invocation.arguments[printArgument + 1]
        XCTAssertTrue(printPrompt.contains("@request.md"))
        XCTAssertFalse(printPrompt.hasPrefix("/"), "No skill was requested, so no slash command is emitted.")
    }

    func testAntigravityEnvironmentMatchesPrivateWorkspace() {
        let workspace = URL(fileURLWithPath: "/tmp/Lectern-Antigravity/test-workspace", isDirectory: true)
        let environment = AntigravityCLI.environment(workingDirectory: workspace)

        XCTAssertEqual(environment["PWD"], workspace.path)
    }

    func testCancellationTerminatesAntigravityProcessTree() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternAntigravityCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let executable = fixtureRoot.appendingPathComponent("fake-agy.sh")
        let parentPIDFile = fixtureRoot.appendingPathComponent("parent.pid")
        let childPIDFile = fixtureRoot.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        echo $$ > '\(parentPIDFile.path)'
        /bin/sh -c 'trap "" HUP TERM; while :; do sleep 1; done' &
        child=$!
        echo $child > '\(childPIDFile.path)'
        wait $child
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var observedPIDs: [pid_t] = []
        defer {
            for pid in observedPIDs where Self.processExists(pid) {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        let task = Task {
            try await AntigravityCLI(executableURL: executable).run(prompt: "Wait for cancellation.")
        }
        let parentPID = try await Self.waitForPID(in: parentPIDFile)
        let childPID = try await Self.waitForPID(in: childPIDFile)
        observedPIDs = [childPID, parentPID]

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation should stop the Antigravity command.")
        } catch is CancellationError {
            // Expected.
        }

        try await Self.waitUntilStopped(parentPID)
        try await Self.waitUntilStopped(childPID)
        XCTAssertFalse(Self.processExists(parentPID))
        XCTAssertFalse(Self.processExists(childPID))
    }

    func testTranscriptionTimeoutIsNotRetried() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternAntigravityTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let audio = fixtureRoot.appendingPathComponent("fixture.wav")
        try Data("synthetic-audio".utf8).write(to: audio)
        let skill = fixtureRoot.appendingPathComponent("SKILL.md")
        try Data("---\nname: lectern-transcription\ndescription: Test fixture\n---\nTranscribe.\n".utf8)
            .write(to: skill)

        let attempts = InvocationCounter()
        let cli = AntigravityCLI(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            transcriptionSkillURL: skill
        ) { _, _, _ in
            attempts.increment()
            throw AntigravityCLI.CLIError.failed("print timeout exceeded")
        }
        let connection = TranscriptionConnection(
            displayName: "Antigravity",
            provider: .antigravityCLI,
            modelID: "gemini-3.8-flash-high",
            cloudUploadConsent: true
        )
        let request = ExternalTranscriptionRequest(
            audioURL: audio,
            durationSeconds: 60,
            lectureLanguage: .english,
            connection: connection,
            attemptNumber: 1
        )

        do {
            _ = try await ExternalTranscriptionEngine(antigravity: cli).transcribe(request) { _ in }
            XCTFail("A timed-out Antigravity run should fail.")
        } catch let error as ExternalTranscriptionError {
            XCTAssertEqual(error.code, .timeout)
            XCTAssertFalse(error.retryable)
        }
        XCTAssertEqual(attempts.value, 1, "A stuck local agent should not be launched again automatically.")
    }

    func testSharedPromptUsesStableCorpusDerivedNotesContract() {
        let contract = """
        Begin with exactly one # source title. Use ## topic sections. Use a chronological numbered outline when the lecture is chronological. Use source-first shiur structure with Q:, A1:, רש״י, תוס׳, מיגו, and נ״מ. Never force Summary or Key Takeaways. If an image-generation tool is available, create a textbook-style labeled diagram or illustration at /absolute/local/path.png.
        """
        let prompt = Prompts.notes(
            cleanedTranscript: "The גמ׳ asks a question and רש״י gives two answers.",
            language: .hebrewEnglish,
            skillInstructions: contract
        )

        XCTAssertTrue(prompt.contains(contract))
        XCTAssertTrue(prompt.contains("English-Hebrew shiur"))
        XCTAssertTrue(prompt.contains("<lecture-source>"))
        XCTAssertFalse(prompt.contains("End with a \"## Summary\""))
    }

    func testNotesValidatorRejectsGenericOrUnstructuredDrafts() {
        let source = String(repeating: "The lecture develops a detailed causal argument. ", count: 80)
        let invalid = "Here are your notes.\n\n## Summary\nA short paragraph."
        let violations = NotesOutputValidator.violations(
            in: invalid,
            source: source,
            language: .english
        )

        XCTAssertTrue(violations.contains(where: { $0.contains("source-derived # title") }))
        XCTAssertTrue(violations.contains(where: { $0.contains("structured bullet or numbered outline") }))
        XCTAssertTrue(violations.contains(where: { $0.contains("generic headings") }))
        XCTAssertTrue(violations.contains(where: { $0.contains("too sparse") }))
    }

    func testNotesValidatorAcceptsTopicalAndShiurLayouts() {
        let topical = "# Cell Transport\n\n## Passive Transport\n\n- **Diffusion:** Material moves down its gradient."
        XCTAssertEqual(
            NotesOutputValidator.violations(in: topical, source: "Short source", language: .english),
            []
        )

        let shiur = "# מיגו במקום עדים\n\n## שאלת היסוד\n\n- **Q:** Can מיגו overcome עדים?\n    - **A:** רש״י says it cannot."
        XCTAssertEqual(
            NotesOutputValidator.violations(
                in: shiur,
                source: "The Gemara asks about migo and Rashi answers.",
                language: .hebrewEnglish
            ),
            []
        )
    }

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private static func waitForPID(in file: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "AntigravityCLITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for fixture process ID."
        ])
    }

    private static func waitUntilStopped(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, processExists(pid) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

private final class NotesInvocationRecorder: @unchecked Sendable {
    struct Invocation {
        let workspace: URL
        let request: String
        let source: String
        let supplementaryReference: String
        let sourceMode: Int
        let skillInstalled: Bool
        let arguments: [String]
    }

    private let lock = NSLock()
    private var value: Invocation?

    func record(
        workspace: URL,
        request: String,
        source: String,
        supplementaryReference: String,
        sourceMode: Int,
        skillInstalled: Bool,
        arguments: [String]
    ) {
        lock.lock()
        value = .init(
            workspace: workspace,
            request: request,
            source: source,
            supplementaryReference: supplementaryReference,
            sourceMode: sourceMode,
            skillInstalled: skillInstalled,
            arguments: arguments
        )
        lock.unlock()
    }

    func snapshot() -> Invocation? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    struct Invocation {
        let workspace: URL
        let arguments: [String]
        let request: String
        let workspaceMode: Int
        let audioMode: Int
        let skillInstalled: Bool
    }

    private let lock = NSLock()
    private var value: Invocation?

    func record(
        workspace: URL,
        arguments: [String],
        request: String,
        workspaceMode: Int,
        audioMode: Int,
        skillInstalled: Bool
    ) {
        lock.lock()
        value = .init(
            workspace: workspace,
            arguments: arguments,
            request: request,
            workspaceMode: workspaceMode,
            audioMode: audioMode,
            skillInstalled: skillInstalled
        )
        lock.unlock()
    }

    func snapshot() -> Invocation? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
