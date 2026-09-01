import XCTest

final class TranscriptionProviderTests: XCTestCase {
    func testLocalTranscriptionCatalogExposesEverySelectableEngine() throws {
        let local = try XCTUnwrap(TranscriptionProviderCatalog.provider(.local))

        XCTAssertEqual(
            local.models.map(\.id),
            [
                "parakeet-tdt-0.6b-v3-coreml",
                "whisper-large-v3-q5_0",
                AntigravityCLI.transcriptionModelID,
            ]
        )
    }

    func testProviderUnavailableUsesSanitizedProviderMessage() throws {
        let secret = "test-secret"
        let data = Data(#"{"error":{"code":503,"message":"This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later. test-secret","status":"UNAVAILABLE"}}"#.utf8)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://generativelanguage.googleapis.com")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: nil
        ))

        let error = ProviderHTTP.classify(status: 503, data: data, response: response, secret: secret)

        XCTAssertEqual(error.code, .providerUnavailable)
        XCTAssertEqual(
            error.userMessage,
            "This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later. [REDACTED]"
        )
        XCTAssertFalse(error.userMessage.contains(secret))
    }

    func testGeminiTruncatedTranscriptReportsOutputLimit() throws {
        let response = Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"{\"text\":\"unfinished"}]}}]}"#.utf8)

        XCTAssertThrowsError(try ProviderNormalization.gemini(
            response,
            request: request(provider: .googleGemini, model: "gemini-3.5-flash-lite")
        )) { thrown in
            guard let error = thrown as? ExternalTranscriptionError else {
                return XCTFail("Expected an ExternalTranscriptionError, got \(thrown)")
            }
            XCTAssertEqual(error.code, .malformedResponse)
            XCTAssertFalse(error.retryable)
            XCTAssertTrue(error.fallbackEligible)
            XCTAssertEqual(
                error.userMessage,
                "Gemini stopped before finishing the transcript because its output limit was reached."
            )
            XCTAssertEqual(error.safeDiagnostics, "Gemini finish reason: MAX_TOKENS; transcript response: invalid JSON.")
        }
    }

    func testGeminiInvalidTranscriptReportsMalformedResponse() throws {
        let response = Data(#"{"candidates":[{"content":{"parts":[{"text":"not JSON"}]}}]}"#.utf8)

        XCTAssertThrowsError(try ProviderNormalization.gemini(
            response,
            request: request(provider: .googleGemini, model: "gemini-3.5-flash-lite")
        )) { thrown in
            guard let error = thrown as? ExternalTranscriptionError else {
                return XCTFail("Expected an ExternalTranscriptionError, got \(thrown)")
            }
            XCTAssertEqual(error.code, .malformedResponse)
            XCTAssertEqual(error.userMessage, "Gemini returned transcript text that was not valid JSON.")
        }
    }

    func testGeminiFileUploadTimeoutRemainsRetryable() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimedOutUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data("audio".utf8)

        do {
            _ = try await ProviderHTTP.perform(
                request,
                session: session,
                secret: "test-secret",
                operation: .fileUpload
            )
            XCTFail("Expected the simulated upload timeout to throw")
        } catch let error as ExternalTranscriptionError {
            XCTAssertEqual(error.code, .timeout)
            XCTAssertTrue(error.retryable)
            XCTAssertTrue(error.fallbackEligible)
        }
    }

    func testCompletedLocalCheckpointCanClearLegacyGeminiFailureBanner() {
        let markdown = "[00:00] Start\n\n"
            + String(repeating: "lecture words ", count: 20)
            + "\n\n[78:59] Done"
        XCTAssertTrue(LocalCheckpointRecovery.isNearlyComplete(
            markdown: markdown,
            durationSeconds: 4_743.6,
            source: .local,
            failureMessage: LocalCheckpointRecovery.legacyAmbiguousUploadMessage
        ))
        XCTAssertFalse(LocalCheckpointRecovery.isNearlyComplete(
            markdown: "[00:00] Partial",
            durationSeconds: 4_743.6,
            source: .local,
            failureMessage: LocalCheckpointRecovery.legacyAmbiguousUploadMessage
        ))
    }

    func testCatalogContainsEveryTranscriptionProvider() {
        XCTAssertEqual(
            Set(TranscriptionProviderCatalog.providers.map(\.id)),
            Set(TranscriptionProviderID.allCases)
        )
        XCTAssertTrue(TranscriptionProviderCatalog.providers.allSatisfy { !$0.models.isEmpty })
    }

    func testBuiltInTranscriptionModelResolvesAutomaticAndExplicitChoices() {
        XCTAssertEqual(BuiltInTranscriptionModel.resolve(nil, language: .english), .parakeet)
        XCTAssertEqual(BuiltInTranscriptionModel.resolve(nil, language: .hebrewEnglish), .whisper)
        XCTAssertEqual(
            BuiltInTranscriptionModel.resolve(BuiltInTranscriptionModel.antigravity.id, language: .english),
            .antigravity
        )
        XCTAssertEqual(
            BuiltInTranscriptionModel.resolve(BuiltInTranscriptionModel.antigravity.id, language: .hebrewEnglish),
            .antigravity
        )
        XCTAssertEqual(
            BuiltInTranscriptionModel.resolve(AntigravityCLI.modelID, language: .hebrewEnglish),
            .antigravity
        )
        XCTAssertEqual(
            BuiltInTranscriptionModel.resolve("gemini-3.7-flash-low", language: .hebrewEnglish),
            .antigravity
        )
        XCTAssertEqual(
            BuiltInTranscriptionModel.resolve("Gemini 3.7 Flash (Low)", language: .hebrewEnglish),
            .antigravity
        )
    }

    func testHebrewAudioImportUsesExplicitGeminiSettingInsteadOfWhisper() {
        let plan = TranscriptionJobPlan.resolve(
            preferenceSource: .local,
            preferenceBuiltInModelID: BuiltInTranscriptionModel.antigravity.id,
            lectureSource: nil,
            lectureModelID: nil,
            language: .hebrewEnglish
        )

        XCTAssertEqual(plan, .local(.antigravity))
        XCTAssertTrue(plan.usesAntigravityCLI)
        XCTAssertFalse(plan.usesWhisperCLI)
        XCTAssertFalse(plan.progressSubtitle().localizedCaseInsensitiveContains("whisper"))
        XCTAssertTrue(plan.progressSubtitle().localizedCaseInsensitiveContains("antigravity"))
    }

    func testAutomaticHebrewImportStillUsesWhisper() {
        let plan = TranscriptionJobPlan.resolve(
            preferenceSource: .local,
            preferenceBuiltInModelID: nil,
            lectureSource: nil,
            lectureModelID: nil,
            language: .hebrewEnglish
        )

        XCTAssertEqual(plan, .local(.whisper))
        XCTAssertTrue(plan.usesWhisperCLI)
        XCTAssertFalse(plan.usesAntigravityCLI)
        XCTAssertTrue(plan.progressSubtitle().localizedCaseInsensitiveContains("whisper.cpp"))
    }

    func testStaleWhisperModelDoesNotOverrideGeminiPreferenceWhenLectureFollowsSettings() {
        let plan = TranscriptionJobPlan.resolve(
            preferenceSource: .local,
            preferenceBuiltInModelID: BuiltInTranscriptionModel.antigravity.id,
            lectureSource: nil,
            lectureModelID: BuiltInTranscriptionModel.whisper.modelInfo,
            language: .hebrewEnglish
        )
        XCTAssertEqual(plan, .local(.antigravity))
        XCTAssertFalse(plan.usesWhisperCLI)
    }

    func testExplicitLocalWhisperOverrideStillUsesWhisper() {
        let plan = TranscriptionJobPlan.resolve(
            preferenceSource: .local,
            preferenceBuiltInModelID: BuiltInTranscriptionModel.antigravity.id,
            lectureSource: .local,
            lectureModelID: BuiltInTranscriptionModel.whisper.id,
            language: .hebrewEnglish
        )
        XCTAssertEqual(plan, .local(.whisper))
        XCTAssertTrue(plan.usesWhisperCLI)
    }

    @MainActor
    func testBuiltInTranscriptionModelSelectionPersists() throws {
        let suiteName = "LecternTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TranscriptionPreferences(defaults: defaults)
        preferences.source = .local
        preferences.builtInModelID = BuiltInTranscriptionModel.whisper.id

        let restored = TranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(restored.builtInModelID, BuiltInTranscriptionModel.whisper.id)
        XCTAssertEqual(restored.snapshot().builtInModelID, BuiltInTranscriptionModel.whisper.id)

        preferences.builtInModelID = BuiltInTranscriptionModel.antigravity.id
        let gemini = TranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(gemini.builtInModelID, BuiltInTranscriptionModel.antigravity.id)
        XCTAssertEqual(
            TranscriptionJobPlan.resolve(
                preferenceSource: gemini.source,
                preferenceBuiltInModelID: gemini.builtInModelID,
                lectureSource: nil,
                lectureModelID: nil,
                language: .hebrewEnglish
            ),
            .local(.antigravity)
        )
    }

    @MainActor
    func testConnectionPersistenceContainsOnlyCredentialReference() throws {
        let suiteName = "LecternTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        let connection = TranscriptionConnection(
            displayName: "Groq free",
            provider: .groq,
            modelID: "whisper-large-v3-turbo",
            credentialReference: "opaque-reference"
        )
        preferences.upsert(connection)
        let data = try XCTUnwrap(defaults.data(forKey: TranscriptionPreferences.settingsKey))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(encoded.contains("opaque-reference"))
        XCTAssertFalse(encoded.contains("gsk_"))
    }

    @MainActor
    func testFreeConnectionCannotFallThroughToPaidConnection() throws {
        let suiteName = "LecternTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        let free = TranscriptionConnection(displayName: "Free", provider: .groq, modelID: "whisper-large-v3-turbo", costTier: .free)
        let paid = TranscriptionConnection(displayName: "Paid", provider: .deepgram, modelID: "nova-3", costTier: .paid)
        preferences.upsert(free)
        preferences.upsert(paid)
        preferences.allowFallbackProviders = true
        preferences.neverFallbackFromFreeToPaid = true
        XCTAssertEqual(preferences.fallbackPlan(startingWith: free).map(\.id), [free.id])
    }

    @MainActor
    func testFallbackOrderAndDuplicateProviderConnectionsPersist() throws {
        let suiteName = "LecternTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = TranscriptionConnection(displayName: "Groq personal", provider: .groq, modelID: "whisper-large-v3-turbo")
        let second = TranscriptionConnection(displayName: "Groq backup", provider: .groq, modelID: "whisper-large-v3")

        let preferences = TranscriptionPreferences(defaults: defaults)
        preferences.upsert(first)
        preferences.upsert(second)
        preferences.allowFallbackProviders = true
        preferences.fallbackConnectionIDs = [second.id, first.id]

        let restored = TranscriptionPreferences(defaults: defaults)
        XCTAssertEqual(restored.connections.map(\.provider), [.groq, .groq])
        XCTAssertEqual(restored.fallbackConnectionIDs, [second.id, first.id])
        XCTAssertEqual(restored.fallbackPlan(startingWith: second).map(\.id), [second.id, first.id])
    }

    @MainActor
    func testFreeOnlyPolicyRejectsPaidDefaultAndSelectedConnection() throws {
        let suiteName = "LecternTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let paid = TranscriptionConnection(displayName: "Paid", provider: .deepgram, modelID: "nova-3", costTier: .paid)
        let free = TranscriptionConnection(displayName: "Free", provider: .groq, modelID: "whisper-large-v3-turbo", costTier: .free)
        let preferences = TranscriptionPreferences(defaults: defaults)
        preferences.upsert(paid)
        preferences.upsert(free)
        preferences.defaultConnectionID = paid.id
        preferences.freeConnectionsOnly = true

        XCTAssertEqual(preferences.defaultConnection?.id, free.id)
        XCTAssertTrue(preferences.fallbackPlan(startingWith: paid).isEmpty)
    }

    func testPersistentJobStoreRestoresSubmittedJobAndProviderID() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("jobs.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let connectionID = UUID()
        var job = PersistentTranscriptionJob(
            recordingPath: "/tmp/lecture.m4a",
            sourceAudioHash: "audio-identity",
            state: .submitted,
            selectedConnectionID: connectionID,
            fallbackPlanSnapshot: [connectionID],
            policySnapshot: .init()
        )
        job.attempts = [.init(
            connectionID: connectionID,
            provider: .assemblyAI,
            requestedModelID: "universal-3-5-pro",
            providerJobID: "provider-job-42"
        )]

        let firstStore = TranscriptionJobStore(fileURL: fileURL)
        await firstStore.upsert(job)
        let restoredStore = TranscriptionJobStore(fileURL: fileURL)
        let restored = await restoredStore.recoverableJob(
            recordingPath: job.recordingPath,
            sourceAudioHash: job.sourceAudioHash,
            includeCompleted: false
        )

        XCTAssertEqual(restored?.id, job.id)
        XCTAssertEqual(restored?.attempts.first?.providerJobID, "provider-job-42")
    }

    func testFailedJobIsNotResumed() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LecternTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("jobs.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let connectionID = UUID()
        let job = PersistentTranscriptionJob(
            recordingPath: "/tmp/failed.m4a",
            sourceAudioHash: "failed-audio",
            state: .failed,
            selectedConnectionID: connectionID,
            fallbackPlanSnapshot: [connectionID],
            policySnapshot: .init()
        )
        let store = TranscriptionJobStore(fileURL: fileURL)
        await store.upsert(job)

        let restored = await store.recoverableJob(
            recordingPath: job.recordingPath,
            sourceAudioHash: job.sourceAudioHash,
            includeCompleted: false
        )
        XCTAssertNil(restored)
    }

    func testAllProviderFixturesNormalizeWithoutInventingMissingMetadata() throws {
        let deepgram = try normalizeDeepgram()
        XCTAssertEqual(deepgram.words?.first?.confidence, 0.98)
        XCTAssertNil(deepgram.segments.first?.languageCode)

        let gemini = try normalizeGemini()
        XCTAssertEqual(gemini.detectedLanguages, ["en", "he"])
        XCTAssertNil(gemini.words)

        let assembly = try normalizeAssemblyAI()
        XCTAssertEqual(assembly.providerInfo.providerJobID, "job-1")
        XCTAssertEqual(assembly.segments.first?.speakerID, "A")

        let modulate = try normalizeModulate()
        XCTAssertEqual(modulate.segments.first?.endMilliseconds, 2_000)
        XCTAssertNil(modulate.words)

        let groq = try normalizeOpenAI(provider: .groq)
        let mistral = try normalizeOpenAI(provider: .mistral)
        XCTAssertEqual(groq.segments.first?.startMilliseconds, 250)
        XCTAssertEqual(mistral.providerInfo.provider, .mistral)

        let elevenLabs = try normalizeElevenLabs()
        XCTAssertEqual(elevenLabs.words?.first?.speakerID, "speaker_0")
        XCTAssertNil(elevenLabs.words?.first?.confidence)
    }

    private func request(provider: TranscriptionProviderID, model: String) -> ExternalTranscriptionRequest {
        .init(
            audioURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
            durationSeconds: 5,
            lectureLanguage: .hebrewEnglish,
            connection: .init(displayName: provider.rawValue, provider: provider, modelID: model, cloudUploadConsent: true),
            attemptNumber: 1
        )
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func normalizeDeepgram() throws -> TranscriptionResult {
        try ProviderNormalization.deepgram(data(#"{"metadata":{},"results":{"utterances":[{"start":0,"end":1,"transcript":"Hello","speaker":0}],"channels":[{"alternatives":[{"transcript":"Hello","words":[{"start":0,"end":1,"word":"Hello","confidence":0.98}]}]}]}}"#), request: request(provider: .deepgram, model: "nova-3"))
    }

    private func normalizeGemini() throws -> TranscriptionResult {
        try ProviderNormalization.gemini(data(#"{"candidates":[{"content":{"parts":[{"text":"{\"text\":\"Hello שלום\",\"detectedLanguages\":[\"en\",\"he\"],\"segments\":[{\"startMs\":0,\"endMs\":1000,\"text\":\"Hello שלום\"}]}"}]}}]}"#), request: request(provider: .googleGemini, model: "gemini-3.7-flash"))
    }

    private func normalizeAssemblyAI() throws -> TranscriptionResult {
        try ProviderNormalization.assemblyAI(data(#"{"status":"completed","text":"Hello","language_code":"en","utterances":[{"start":0,"end":1000,"text":"Hello","speaker":"A","confidence":0.9}],"words":[{"start":0,"end":1000,"text":"Hello","confidence":0.9}]}"#), request: request(provider: .assemblyAI, model: "universal-3-5-pro"), jobID: "job-1")
    }

    private func normalizeModulate() throws -> TranscriptionResult {
        try ProviderNormalization.modulate(data(#"{"text":"Hello","duration_ms":5000,"utterances":[{"text":"Hello","start_ms":0,"duration_ms":2000,"speaker":1,"language":"en"}]}"#), request: request(provider: .modulate, model: "multilingual-batch"))
    }

    private func normalizeOpenAI(provider: TranscriptionProviderID) throws -> TranscriptionResult {
        try ProviderNormalization.openAICompatible(data(#"{"text":"Hello","language":"en","duration":5,"segments":[{"start":0.25,"end":1.5,"text":"Hello"}]}"#), request: request(provider: provider, model: provider == .groq ? "whisper-large-v3-turbo" : "voxtral-mini-latest"))
    }

    private func normalizeElevenLabs() throws -> TranscriptionResult {
        try ProviderNormalization.elevenLabs(data(#"{"text":"Hello","language_code":"en","words":[{"type":"word","text":"Hello","start":0,"end":1,"speaker_id":"speaker_0"}]}"#), request: request(provider: .elevenLabs, model: "scribe_v2"))
    }
}

private final class TimedOutUploadURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}
