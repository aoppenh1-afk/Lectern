import Foundation

struct ExternalTranscriptionRequest: Sendable {
    var audioURL: URL
    var durationSeconds: Double
    var lectureLanguage: LectureLanguage
    var connection: TranscriptionConnection
    var attemptNumber: Int
    var resumeProviderJobID: String?
}

struct ProviderJobUpdate: Sendable {
    var state: TranscriptionJobState
    var providerJobID: String?
}

struct CredentialValidationResult: Sendable {
    var isValid: Bool
    var message: String
}

protocol TranscriptionProviderAdapter: Sendable {
    var providerID: TranscriptionProviderID { get }
    func transcribe(
        _ request: ExternalTranscriptionRequest,
        apiKey: String,
        onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void
    ) async throws -> TranscriptionResult
    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult
}

struct ExternalTranscriptionEngine: Sendable {
    private let session: URLSession
    private let antigravity: AntigravityCLI

    init(session: URLSession = .shared, antigravity: AntigravityCLI = AntigravityCLI()) {
        self.session = session
        self.antigravity = antigravity
    }

    func transcribe(
        _ request: ExternalTranscriptionRequest,
        onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void
    ) async throws -> TranscriptionResult {
        try preflight(request)
        let apiKey = request.connection.provider.requiresAPIKey
            ? try KeychainCredentialStore.read(reference: request.connection.credentialReference)
            : ""
        let adapter = adapter(for: request.connection.provider)

        var lastError: ExternalTranscriptionError?
        for retry in 0..<3 {
            do {
                return try await adapter.transcribe(request, apiKey: apiKey, onUpdate: onUpdate)
            } catch is CancellationError {
                throw ExternalTranscriptionError(
                    code: .cancelled, retryable: false, fallbackEligible: false,
                    userMessage: "Transcription was cancelled."
                )
            } catch let error as ExternalTranscriptionError {
                lastError = error
                guard error.retryable, retry < 2 else { throw error }
                await onUpdate(.init(state: .waitingForRetry, providerJobID: request.resumeProviderJobID))
                let delay = error.retryAfter.map { max(0, $0.timeIntervalSinceNow) }
                    ?? pow(2, Double(retry)) + Double.random(in: 0...0.4)
                try await Task.sleep(for: .seconds(min(delay, 30)))
            } catch {
                let classified = ProviderHTTP.classify(error)
                lastError = classified
                guard classified.retryable, retry < 2 else { throw classified }
                try await Task.sleep(for: .seconds(pow(2, Double(retry))))
            }
        }
        throw lastError ?? ExternalTranscriptionError(
            code: .unknown, retryable: false, fallbackEligible: true,
            userMessage: "The transcription provider did not return a result."
        )
    }

    func validate(_ connection: TranscriptionConnection) async -> CredentialValidationResult {
        do {
            let apiKey = connection.provider.requiresAPIKey
                ? try KeychainCredentialStore.read(reference: connection.credentialReference)
                : ""
            return await adapter(for: connection.provider).validate(connection: connection, apiKey: apiKey)
        } catch {
            return .init(isValid: false, message: error.localizedDescription)
        }
    }

    private func preflight(_ request: ExternalTranscriptionRequest) throws {
        let capabilities = request.connection.capabilities
        guard request.connection.cloudUploadConsent else {
            throw ExternalTranscriptionError(
                code: .permissionDenied, retryable: false, fallbackEligible: false,
                userMessage: "Allow audio uploads for this connection before using it."
            )
        }
        if let maxBytes = capabilities.maxUploadBytes,
           let bytes = try? request.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(bytes) > maxBytes {
            throw ExternalTranscriptionError(
                code: .fileTooLarge, retryable: false, fallbackEligible: true,
                userMessage: "This recording is larger than the selected connection accepts."
            )
        }
        if let maxDuration = capabilities.maxAudioDurationMilliseconds,
           Int64(request.durationSeconds * 1_000) > maxDuration {
            throw ExternalTranscriptionError(
                code: .audioTooLong, retryable: false, fallbackEligible: true,
                userMessage: "This recording is longer than the selected model accepts."
            )
        }
        if request.connection.languageMode == .fixed,
           let language = request.connection.languageCode,
           let supported = capabilities.supportedLanguageCodes,
           !supported.contains(language) {
            throw ExternalTranscriptionError(
                code: .unsupportedLanguage, retryable: false, fallbackEligible: true,
                userMessage: "The selected model does not support \(language)."
            )
        }
    }

    private func adapter(for provider: TranscriptionProviderID) -> any TranscriptionProviderAdapter {
        switch provider {
        case .deepgram: return DeepgramTranscriptionAdapter(session: session)
        case .googleGemini: return GeminiTranscriptionAdapter(session: session)
        case .antigravityCLI: return AntigravityTranscriptionAdapter(cli: antigravity)
        case .assemblyAI: return AssemblyAITranscriptionAdapter(session: session)
        case .modulate: return ModulateTranscriptionAdapter(session: session)
        case .mistral: return MistralTranscriptionAdapter(session: session)
        case .groq: return GroqTranscriptionAdapter(session: session)
        case .elevenLabs: return ElevenLabsTranscriptionAdapter(session: session)
        case .local: return UnsupportedCloudAdapter()
        }
    }
}

private struct AntigravityTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.antigravityCLI
    let cli: AntigravityCLI

    func transcribe(
        _ request: ExternalTranscriptionRequest,
        apiKey: String,
        onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void
    ) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        let audioName = "lecture-audio" + (request.audioURL.pathExtension.isEmpty ? "" : ".\(request.audioURL.pathExtension.lowercased())")
        let languageBranch = request.lectureLanguage == .hebrewEnglish
            ? "English-Hebrew shiur"
            : "English lecture"
        let speakerRule = request.connection.diarizationEnabled
            ? "When distinct speakers can be tracked, use stable role labels such as Professor, Student, or Speaker 1 after each timestamp."
            : "Omit speaker labels."
        let timestampRule: String
        switch request.connection.timestampGranularity {
        case .none:
            timestampRule = "Omit timestamps and return natural transcript paragraphs."
        case .segment:
            timestampRule = "Start every natural segment with a grounded [HH:MM:SS] timestamp."
        case .word:
            timestampRule = "Start every natural segment with a grounded [HH:MM:SS] timestamp; word timestamps are not needed."
        }
        let prompt = """
        Apply the lectern-transcription skill to @\(audioName).
        Transcribe with Gemini's native audio understanding. Do not invoke whisper-cli, ffmpeg, or another local speech-to-text tool.

        Language branch: \(languageBranch).
        \(speakerRule)
        \(timestampRule)
        Return only the complete transcript text. Do not return JSON, a schema, an overview, commentary, or a completion report. Once the final spoken passage is transcribed, return the transcript immediately without creating scripts or performing a second formatting pass.
        """

        await onUpdate(.init(state: .processing))
        do {
            let modelID = request.connection.modelID.isEmpty
                ? AntigravityCLI.transcriptionModelID
                : request.connection.modelID
            let output = try await cli.run(
                prompt: prompt,
                modelID: modelID,
                thinkingLevel: AntigravityCLI.thinkingLevel(fromModelID: modelID),
                inputs: [.file(request.audioURL, named: audioName)],
                skills: [.transcription]
            )
            return try Self.result(from: output, request: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExternalTranscriptionError {
            throw error
        } catch {
            throw Self.classify(error)
        }
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        do {
            let models = try await cli.availableModels()
            guard models.contains(connection.modelID) else {
                return .init(isValid: false, message: "Antigravity CLI does not currently expose \(connection.modelID).")
            }
            return .init(isValid: true, message: "Antigravity CLI signed in; model available.")
        } catch {
            return .init(isValid: false, message: error.localizedDescription)
        }
    }

    static func result(from output: String, request: ExternalTranscriptionRequest) throws -> TranscriptionResult {
        let transcript = removingOptionalMarkdownFence(from: output)
        guard !transcript.isEmpty else {
            throw ExternalTranscriptionError(
                code: .malformedResponse,
                retryable: false,
                fallbackEligible: true,
                userMessage: "Antigravity CLI returned an empty transcript."
            )
        }

        let audioDuration = request.durationSeconds > 0
            ? Int64((request.durationSeconds * 1_000).rounded())
            : nil
        let segments = parsedSegments(
            from: transcript,
            audioDurationMilliseconds: audioDuration,
            includeSpeakers: request.connection.diarizationEnabled,
            lectureLanguage: request.lectureLanguage
        )
        let resolvedText = segments.map(\.text).joined(separator: "\n\n")
        return .init(
            text: resolvedText,
            segments: segments,
            words: nil,
            detectedLanguages: detectedLanguages(in: resolvedText, branch: request.lectureLanguage),
            providerInfo: .init(
                connectionID: request.connection.id,
                provider: request.connection.provider,
                requestedModelID: request.connection.modelID,
                resolvedModelID: request.connection.modelID.isEmpty
                    ? AntigravityCLI.transcriptionModelID
                    : request.connection.modelID,
                providerJobID: nil,
                attemptNumber: request.attemptNumber,
                processingMode: request.connection.processingMode,
                completedAt: Date()
            ),
            audioDurationMilliseconds: audioDuration,
            warnings: []
        )
    }

    private struct ParsedSegment {
        var startMilliseconds: Int64
        var text: String
        var speakerID: String?
    }

    private static func parsedSegments(
        from transcript: String,
        audioDurationMilliseconds: Int64?,
        includeSpeakers: Bool,
        lectureLanguage: LectureLanguage
    ) -> [NormalizedTranscriptionSegment] {
        let pattern = #"(?m)^[ \t]*\[(\d{1,3}(?::\d{1,2}){1,2})(?:[.,](\d{1,3}))?\][ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.init(text: transcript)]
        }
        let fullRange = NSRange(transcript.startIndex..., in: transcript)
        let matches = regex.matches(in: transcript, range: fullRange)
        guard !matches.isEmpty else {
            return [.init(
                text: transcript,
                languageCode: languageCode(for: transcript, branch: lectureLanguage)
            )]
        }

        let source = transcript as NSString
        var drafts: [ParsedSegment] = []
        var previousStart: Int64 = 0
        for (index, match) in matches.enumerated() {
            let bodyStart = NSMaxRange(match.range)
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            guard bodyEnd >= bodyStart else { continue }
            let rawBody = source.substring(
                with: NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawBody.isEmpty else { continue }

            let timestamp = source.substring(with: match.range(at: 1))
            let fraction = match.range(at: 2).location == NSNotFound
                ? nil
                : source.substring(with: match.range(at: 2))
            guard let parsedStart = timestampMilliseconds(timestamp, fraction: fraction) else { continue }
            var start = max(previousStart, parsedStart)
            if let audioDurationMilliseconds {
                start = min(start, audioDurationMilliseconds)
            }
            previousStart = start

            let parsedBody = speakerAndText(from: rawBody, enabled: includeSpeakers)
            guard !parsedBody.text.isEmpty else { continue }
            drafts.append(.init(
                startMilliseconds: start,
                text: parsedBody.text,
                speakerID: parsedBody.speaker
            ))
        }

        guard !drafts.isEmpty else {
            return [.init(
                text: transcript,
                languageCode: languageCode(for: transcript, branch: lectureLanguage)
            )]
        }
        return drafts.enumerated().map { index, draft in
            let nextStart = drafts.indices.contains(index + 1)
                ? drafts[index + 1].startMilliseconds
                : audioDurationMilliseconds
            return .init(
                startMilliseconds: draft.startMilliseconds,
                endMilliseconds: nextStart.map { max(draft.startMilliseconds, $0) },
                text: draft.text,
                speakerID: draft.speakerID,
                languageCode: languageCode(for: draft.text, branch: lectureLanguage),
                confidence: nil
            )
        }
    }

    private static func timestampMilliseconds(_ timestamp: String, fraction: String?) -> Int64? {
        let parts = timestamp.split(separator: ":").compactMap { Int64($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let seconds = parts.count == 3
            ? parts[0] * 3_600 + parts[1] * 60 + parts[2]
            : parts[0] * 60 + parts[1]
        let fractional = fraction.flatMap { value -> Int64? in
            let padded = String((value + "000").prefix(3))
            return Int64(padded)
        } ?? 0
        return seconds * 1_000 + fractional
    }

    private static func speakerAndText(from body: String, enabled: Bool) -> (speaker: String?, text: String) {
        guard enabled else { return (nil, body) }
        let pattern = #"(?is)^(?:\*\*)?([^:\n]{1,40}):(?:\*\*)?[ \t]+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let speakerRange = Range(match.range(at: 1), in: body),
              let textRange = Range(match.range(at: 2), in: body) else {
            return (nil, body)
        }
        let speaker = body[speakerRange].trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = speaker.lowercased()
        let knownRoles = ["speaker", "professor", "teacher", "student", "rabbi", "rav", "rebbe", "audience", "questioner"]
        guard knownRoles.contains(where: normalized.contains) else { return (nil, body) }
        return (speaker, body[textRange].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func removingOptionalMarkdownFence(from output: String) -> String {
        var lines = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detectedLanguages(in text: String, branch: LectureLanguage) -> [String] {
        guard branch == .hebrewEnglish else { return ["en"] }
        let hasHebrew = containsHebrew(text)
        let hasLatin = text.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        if hasHebrew && hasLatin { return ["en", "he"] }
        if hasHebrew { return ["he"] }
        return ["en"]
    }

    private static func languageCode(for text: String, branch: LectureLanguage) -> String? {
        guard branch == .hebrewEnglish else { return "en" }
        let hasHebrew = containsHebrew(text)
        let hasLatin = text.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        if hasHebrew == hasLatin { return nil }
        return hasHebrew ? "he" : "en"
    }

    private static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x0590...0x05FF).contains($0.value) || (0xFB1D...0xFB4F).contains($0.value)
        }
    }

    private static func classify(_ error: Error) -> ExternalTranscriptionError {
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("authentication") || lower.contains("sign in") || lower.contains("signed in") {
            return .init(code: .invalidCredentials, retryable: false, fallbackEligible: true, userMessage: message)
        }
        if lower.contains("model") && (lower.contains("unknown") || lower.contains("unavailable")) {
            return .init(code: .unsupportedModel, retryable: false, fallbackEligible: true, userMessage: message)
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return .init(code: .timeout, retryable: false, fallbackEligible: true, userMessage: message)
        }
        return .init(code: .providerUnavailable, retryable: false, fallbackEligible: true, userMessage: message)
    }

}

private struct UnsupportedCloudAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.local
    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        throw ExternalTranscriptionError(code: .unsupportedModel, retryable: false, fallbackEligible: false, userMessage: "Local transcription does not use an API adapter.")
    }
    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        .init(isValid: false, message: "Local transcription does not need credentials.")
    }
}

private struct DeepgramTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.deepgram
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query = [
            URLQueryItem(name: "model", value: request.connection.modelID),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
            URLQueryItem(name: "diarize", value: String(request.connection.diarizationEnabled)),
        ]
        if request.connection.languageMode == .fixed, let language = request.connection.languageCode {
            query.append(.init(name: "language", value: language))
        } else if request.lectureLanguage == .hebrewEnglish {
            query.append(.init(name: "detect_language", value: "true"))
        }
        components.queryItems = query
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(ProviderHTTP.mimeType(for: request.audioURL), forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Data(contentsOf: request.audioURL, options: .mappedIfSafe)
        let data = try await ProviderHTTP.perform(
            urlRequest, session: session, secret: apiKey, operation: .transcriptionSubmission
        )
        return try ProviderNormalization.deepgram(data, request: request)
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        await ProviderHTTP.validate(url: URL(string: "https://api.deepgram.com/v1/projects")!, header: ("Authorization", "Token \(apiKey)"), session: session, secret: apiKey)
    }
}

private struct GeminiTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.googleGemini
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        let audioData = try Data(contentsOf: request.audioURL, options: .mappedIfSafe)
        let mime = ProviderHTTP.mimeType(for: request.audioURL)
        let startURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(audioData.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": request.audioURL.lastPathComponent]])
        let (_, response) = try await ProviderHTTP.performWithResponse(
            start, session: session, secret: apiKey, operation: .fileUpload
        )
        guard let uploadValue = response.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadValue) else {
            throw ProviderHTTP.malformed("Google did not return an upload URL.")
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(String(audioData.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = audioData
        let uploadedData = try await ProviderHTTP.perform(
            upload, session: session, secret: apiKey, operation: .fileUpload
        )
        let uploaded = try ProviderHTTP.object(uploadedData)
        guard let file = uploaded["file"] as? [String: Any],
              let fileURI = file["uri"] as? String else {
            throw ProviderHTTP.malformed("Google did not return an uploaded file reference.")
        }

        await onUpdate(.init(state: .processing))
        let languageBranch = request.lectureLanguage == .hebrewEnglish
            ? "English-Hebrew shiur"
            : "English lecture"
        let speakerRule = request.connection.diarizationEnabled
            ? "Add stable speaker labels only when distinct speakers can be tracked reliably."
            : "Omit speaker labels."
        let timestampRule: String
        switch request.connection.timestampGranularity {
        case .none: timestampRule = "Omit timestamps that are not required by the response schema."
        case .segment: timestampRule = "Include grounded segment timestamps in milliseconds."
        case .word: timestampRule = "Include grounded segment timestamps; word timestamps are not required by this response schema."
        }
        let prompt = """
        \(LecternAgentSkill.transcription.instructions())

        <task>
        Mode: audio transcription.
        Language branch: \(languageBranch).
        \(speakerRule)
        \(timestampRule)
        Return only the complete transcript JSON object defined by the response schema.
        </task>
        """
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "text": ["type": "STRING"],
                "detectedLanguages": ["type": "ARRAY", "items": ["type": "STRING"]],
                "segments": ["type": "ARRAY", "items": [
                    "type": "OBJECT",
                    "properties": [
                        "startMs": ["type": "INTEGER"], "endMs": ["type": "INTEGER"],
                        "text": ["type": "STRING"], "speakerID": ["type": "STRING"],
                        "languageCode": ["type": "STRING"]
                    ],
                    "required": ["text"]
                ]]
            ],
            "required": ["text", "segments"]
        ]
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": prompt]]],
            "contents": [["role": "user", "parts": [["text": "Transcribe the complete recording according to the task and language branch."], ["file_data": ["mime_type": mime, "file_uri": fileURI]]]]],
            "generationConfig": ["response_mime_type": "application/json", "response_schema": schema, "temperature": 0]
        ]
        let generateURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(request.connection.modelID):generateContent")!
        var generate = URLRequest(url: generateURL)
        generate.httpMethod = "POST"
        generate.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        generate.setValue("application/json", forHTTPHeaderField: "Content-Type")
        generate.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await ProviderHTTP.perform(
            generate, session: session, secret: apiKey, operation: .transcriptionSubmission
        )
        return try ProviderNormalization.gemini(data, request: request)
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(connection.modelID)")!
        return await ProviderHTTP.validate(url: url, header: ("x-goog-api-key", apiKey), session: session, secret: apiKey)
    }
}

private struct AssemblyAITranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.assemblyAI
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        let jobID: String
        if let resumed = request.resumeProviderJobID {
            jobID = resumed
        } else {
            await onUpdate(.init(state: .uploading))
            var upload = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
            upload.httpMethod = "POST"
            upload.setValue(apiKey, forHTTPHeaderField: "Authorization")
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload.httpBody = try Data(contentsOf: request.audioURL, options: .mappedIfSafe)
            let uploadData = try await ProviderHTTP.perform(
                upload, session: session, secret: apiKey, operation: .fileUpload
            )
            guard let audioURL = try ProviderHTTP.object(uploadData)["upload_url"] as? String else {
                throw ProviderHTTP.malformed("AssemblyAI did not return an upload URL.")
            }
            var payload: [String: Any] = [
                "audio_url": audioURL,
                "speech_models": [request.connection.modelID],
                "speaker_labels": request.connection.diarizationEnabled,
            ]
            if request.connection.languageMode == .fixed, let language = request.connection.languageCode {
                payload["language_code"] = language
            } else {
                payload["language_detection"] = true
            }
            var submit = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
            submit.httpMethod = "POST"
            submit.setValue(apiKey, forHTTPHeaderField: "Authorization")
            submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
            submit.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let submittedData = try await ProviderHTTP.perform(
                submit, session: session, secret: apiKey, operation: .transcriptionSubmission
            )
            guard let id = try ProviderHTTP.object(submittedData)["id"] as? String else {
                throw ProviderHTTP.malformed("AssemblyAI did not return a job ID.")
            }
            jobID = id
            await onUpdate(.init(state: .submitted, providerJobID: id))
        }

        while true {
            try Task.checkCancellation()
            var poll = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript/\(jobID)")!)
            poll.setValue(apiKey, forHTTPHeaderField: "Authorization")
            let data = try await ProviderHTTP.perform(
                poll, session: session, secret: apiKey, operation: .readOnly
            )
            let object = try ProviderHTTP.object(data)
            switch object["status"] as? String {
            case "completed": return try ProviderNormalization.assemblyAI(data, request: request, jobID: jobID)
            case "error":
                throw ExternalTranscriptionError(code: .malformedResponse, retryable: false, fallbackEligible: true, userMessage: object["error"] as? String ?? "AssemblyAI could not transcribe the recording.", providerRequestID: jobID)
            default:
                await onUpdate(.init(state: .processing, providerJobID: jobID))
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        await ProviderHTTP.validate(url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!, header: ("Authorization", apiKey), session: session, secret: apiKey)
    }
}

private struct ModulateTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.modulate
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        let endpoint: String
        switch request.connection.modelID {
        case "english-vfast": endpoint = "velma-2-stt-batch-english-vfast"
        case "multilingual-vfast": endpoint = "velma-2-stt-batch-multilingual-vfast"
        default: endpoint = "velma-2-stt-batch"
        }
        let fields = [
            "speaker_diarization": String(request.connection.diarizationEnabled),
            "time_stamps": String(request.connection.timestampGranularity == .word),
        ]
        var urlRequest = try ProviderHTTP.multipartRequest(
            url: URL(string: "https://platform.modulate.ai/api/\(endpoint)")!, audioURL: request.audioURL,
            fileField: "upload_file", fields: fields
        )
        urlRequest.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let data = try await ProviderHTTP.perform(
            urlRequest, session: session, secret: apiKey, operation: .transcriptionSubmission
        )
        return try ProviderNormalization.modulate(data, request: request)
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        guard apiKey.count >= 8 else { return .init(isValid: false, message: "The API key looks incomplete.") }
        return .init(isValid: true, message: "Key saved. Modulate validates access with the first transcription request.")
    }
}

private struct MistralTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.mistral
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        var fields = ["model": request.connection.modelID]
        if request.connection.languageMode == .fixed, let language = request.connection.languageCode { fields["language"] = language }
        if request.connection.timestampGranularity == .word { fields["timestamp_granularities[]"] = "word" }
        var urlRequest = try ProviderHTTP.multipartRequest(url: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!, audioURL: request.audioURL, fileField: "file", fields: fields)
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await ProviderHTTP.perform(
            urlRequest, session: session, secret: apiKey, operation: .transcriptionSubmission
        )
        return try ProviderNormalization.openAICompatible(data, request: request)
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        await ProviderHTTP.validate(url: URL(string: "https://api.mistral.ai/v1/models/\(connection.modelID)")!, header: ("Authorization", "Bearer \(apiKey)"), session: session, secret: apiKey)
    }
}

private struct GroqTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.groq
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        var fields = ["model": request.connection.modelID, "response_format": "verbose_json"]
        if request.connection.languageMode == .fixed, let language = request.connection.languageCode { fields["language"] = language }
        if request.connection.timestampGranularity == .word { fields["timestamp_granularities[]"] = "word" }
        var urlRequest = try ProviderHTTP.multipartRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!, audioURL: request.audioURL, fileField: "file", fields: fields)
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await ProviderHTTP.perform(
            urlRequest, session: session, secret: apiKey, operation: .transcriptionSubmission
        )
        return try ProviderNormalization.openAICompatible(data, request: request)
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        await ProviderHTTP.validate(url: URL(string: "https://api.groq.com/openai/v1/models/\(connection.modelID)")!, header: ("Authorization", "Bearer \(apiKey)"), session: session, secret: apiKey)
    }
}

private struct ElevenLabsTranscriptionAdapter: TranscriptionProviderAdapter {
    let providerID = TranscriptionProviderID.elevenLabs
    let session: URLSession

    func transcribe(_ request: ExternalTranscriptionRequest, apiKey: String, onUpdate: @escaping @Sendable (ProviderJobUpdate) async -> Void) async throws -> TranscriptionResult {
        await onUpdate(.init(state: .uploading))
        var fields = [
            "model_id": request.connection.modelID,
            "diarize": String(request.connection.diarizationEnabled),
            "timestamps_granularity": request.connection.timestampGranularity == .none ? "none" : "word",
            "tag_audio_events": "false",
        ]
        if request.connection.languageMode == .fixed, let language = request.connection.languageCode { fields["language_code"] = language }
        var urlRequest = try ProviderHTTP.multipartRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!, audioURL: request.audioURL, fileField: "file", fields: fields)
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let data = try await ProviderHTTP.perform(
            urlRequest, session: session, secret: apiKey, operation: .transcriptionSubmission
        )
        return try ProviderNormalization.elevenLabs(data, request: request)
    }

    func validate(connection: TranscriptionConnection, apiKey: String) async -> CredentialValidationResult {
        await ProviderHTTP.validate(url: URL(string: "https://api.elevenlabs.io/v1/models")!, header: ("xi-api-key", apiKey), session: session, secret: apiKey)
    }
}

enum ProviderHTTP {
    enum Operation {
        case readOnly
        case fileUpload
        case transcriptionSubmission
    }

    static func perform(
        _ request: URLRequest,
        session: URLSession,
        secret: String,
        operation: Operation
    ) async throws -> Data {
        let (data, _) = try await performWithResponse(
            request, session: session, secret: secret, operation: operation
        )
        return data
    }

    static func performWithResponse(
        _ request: URLRequest,
        session: URLSession,
        secret: String,
        operation: Operation
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if operation != .readOnly {
            request.timeoutInterval = max(request.timeoutInterval, 30 * 60)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw malformed("The provider returned an invalid response.") }
            guard (200..<300).contains(http.statusCode) else {
                throw classify(status: http.statusCode, data: data, response: http, secret: secret)
            }
            return (data, http)
        } catch let error as ExternalTranscriptionError {
            throw error
        } catch let error as URLError
            where operation == .transcriptionSubmission
                && request.httpMethod == "POST"
                && request.httpBody?.isEmpty == false
                && (error.code == .timedOut || error.code == .networkConnectionLost) {
            throw ExternalTranscriptionError(
                code: .acceptedStateUnknown,
                retryable: false,
                fallbackEligible: false,
                userMessage: "The transcription request may have been accepted, so Lectern stopped before retrying or using a paid fallback. Check the provider dashboard before trying again."
            )
        } catch {
            throw classify(error)
        }
    }

    static func validate(url: URL, header: (String, String), session: URLSession, secret: String) async -> CredentialValidationResult {
        var request = URLRequest(url: url)
        request.setValue(header.1, forHTTPHeaderField: header.0)
        do {
            _ = try await perform(
                request, session: session, secret: secret, operation: .readOnly
            )
            return .init(isValid: true, message: "Credentials valid; model available.")
        } catch let error as ExternalTranscriptionError {
            return .init(isValid: false, message: error.userMessage)
        } catch {
            return .init(isValid: false, message: error.localizedDescription)
        }
    }

    static func multipartRequest(url: URL, audioURL: URL, fileField: String, fields: [String: String]) throws -> URLRequest {
        let boundary = "Lectern-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let filename = audioURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType(for: audioURL))\r\n\r\n")
        body.append(try Data(contentsOf: audioURL, options: .mappedIfSafe))
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw malformed("The provider returned malformed JSON.")
        }
        return object
    }

    static func malformed(_ message: String) -> ExternalTranscriptionError {
        .init(code: .malformedResponse, retryable: false, fallbackEligible: true, userMessage: message)
    }

    static func classify(_ error: Error) -> ExternalTranscriptionError {
        if let urlError = error as? URLError {
            let code: TranscriptionErrorCode = urlError.code == .timedOut ? .timeout : .networkUnavailable
            return .init(code: code, retryable: true, fallbackEligible: true, userMessage: "The provider could not be reached. Check your connection and try again.")
        }
        return .init(code: .unknown, retryable: false, fallbackEligible: true, userMessage: error.localizedDescription)
    }

    static func classify(status: Int, data: Data, response: HTTPURLResponse, secret: String) -> ExternalTranscriptionError {
        let message = redactedMessage(data, secret: secret)
        let providerMessage = providerErrorMessage(data, secret: secret)
        let requestID = response.value(forHTTPHeaderField: "x-request-id") ?? response.value(forHTTPHeaderField: "request-id")
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Date().addingTimeInterval($0) }
        switch status {
        case 401: return .init(code: .invalidCredentials, retryable: false, fallbackEligible: true, userMessage: "The API key was rejected.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        case 403: return .init(code: .permissionDenied, retryable: false, fallbackEligible: true, userMessage: "This key cannot use the selected model.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        case 404: return .init(code: .unsupportedModel, retryable: false, fallbackEligible: true, userMessage: "The selected model or endpoint is unavailable.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        case 408: return .init(code: .timeout, retryable: true, fallbackEligible: true, userMessage: "The provider timed out.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        case 413: return .init(code: .fileTooLarge, retryable: false, fallbackEligible: true, userMessage: "The recording is too large for this connection.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        case 429: return .init(code: message?.lowercased().contains("quota") == true ? .quotaExceeded : .rateLimited, retryable: retryAfter != nil, fallbackEligible: true, retryAfter: retryAfter, userMessage: providerMessage ?? "The provider's quota or rate limit was reached.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        case 500...599: return .init(code: .providerUnavailable, retryable: true, fallbackEligible: true, userMessage: providerMessage ?? "The provider is temporarily unavailable.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        default: return .init(code: .unknown, retryable: false, fallbackEligible: true, userMessage: providerMessage ?? "The provider rejected the transcription request.", safeDiagnostics: message, providerStatusCode: status, providerRequestID: requestID)
        }
    }

    private static func providerErrorMessage(_ data: Data, secret: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = root["error"] as? [String: Any]
        let rawMessage = error?["message"] as? String
            ?? root["message"] as? String
            ?? root["error"] as? String
        guard var rawMessage, !rawMessage.isEmpty else { return nil }

        if !secret.isEmpty {
            rawMessage = rawMessage.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        let singleLine = rawMessage
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(500))
    }

    private static func redactedMessage(_ data: Data, secret: String) -> String? {
        guard var text = String(data: data.prefix(1_000), encoding: .utf8), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
        return text
    }
}

enum ProviderNormalization {
    static func deepgram(_ data: Data, request: ExternalTranscriptionRequest) throws -> TranscriptionResult {
        let root = try ProviderHTTP.object(data)
        let results = root["results"] as? [String: Any]
        let utterances = results?["utterances"] as? [[String: Any]] ?? []
        let channels = results?["channels"] as? [[String: Any]] ?? []
        let alternative = (channels.first?["alternatives"] as? [[String: Any]])?.first
        let text = alternative?["transcript"] as? String ?? utterances.compactMap { $0["transcript"] as? String }.joined(separator: " ")
        let segments = utterances.map {
            NormalizedTranscriptionSegment(
                startMilliseconds: milliseconds($0["start"]), endMilliseconds: milliseconds($0["end"]),
                text: $0["transcript"] as? String ?? "", speakerID: string($0["speaker"]),
                languageCode: $0["language"] as? String, confidence: number($0["confidence"])
            )
        }
        let words = (alternative?["words"] as? [[String: Any]])?.map(word(seconds: true))
        return result(text: text, segments: segments, words: words, languages: [], request: request, resolvedModel: (root["metadata"] as? [String: Any])?["model_info"] as? String)
    }

    static func gemini(_ data: Data, request: ExternalTranscriptionRequest) throws -> TranscriptionResult {
        let root = try ProviderHTTP.object(data)
        let candidate = (root["candidates"] as? [[String: Any]])?.first
        let finishReason = candidate?["finishReason"] as? String
        guard let content = candidate?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let jsonText = parts.first?["text"] as? String,
              let jsonData = jsonText.data(using: .utf8) else {
            throw geminiMalformedResponse(finishReason: finishReason, invalidJSON: false)
        }
        let transcript: [String: Any]
        do {
            transcript = try ProviderHTTP.object(jsonData)
        } catch {
            throw geminiMalformedResponse(finishReason: finishReason, invalidJSON: true)
        }
        let segments = (transcript["segments"] as? [[String: Any]] ?? []).map {
            NormalizedTranscriptionSegment(
                startMilliseconds: int64($0["startMs"]), endMilliseconds: int64($0["endMs"]),
                text: $0["text"] as? String ?? "", speakerID: $0["speakerID"] as? String,
                languageCode: $0["languageCode"] as? String, confidence: nil
            )
        }
        return result(text: transcript["text"] as? String ?? segments.map(\.text).joined(separator: " "), segments: segments, words: nil, languages: transcript["detectedLanguages"] as? [String] ?? [], request: request)
    }

    private static func geminiMalformedResponse(finishReason: String?, invalidJSON: Bool) -> ExternalTranscriptionError {
        let userMessage: String
        if finishReason == "MAX_TOKENS" {
            userMessage = "Gemini stopped before finishing the transcript because its output limit was reached."
        } else if let finishReason, finishReason != "STOP" {
            userMessage = "Gemini stopped before finishing the transcript (reason: \(finishReason))."
        } else if invalidJSON {
            userMessage = "Gemini returned transcript text that was not valid JSON."
        } else {
            userMessage = "Gemini did not return the transcript schema."
        }
        let diagnosticReason = finishReason ?? "not supplied"
        let responseDescription = invalidJSON ? "invalid JSON" : "transcript schema missing"
        return .init(
            code: .malformedResponse,
            retryable: false,
            fallbackEligible: true,
            userMessage: userMessage,
            safeDiagnostics: "Gemini finish reason: \(diagnosticReason); transcript response: \(responseDescription)."
        )
    }

    static func assemblyAI(_ data: Data, request: ExternalTranscriptionRequest, jobID: String) throws -> TranscriptionResult {
        let root = try ProviderHTTP.object(data)
        let utterances = root["utterances"] as? [[String: Any]] ?? []
        let segments = utterances.map {
            NormalizedTranscriptionSegment(startMilliseconds: int64($0["start"]), endMilliseconds: int64($0["end"]), text: $0["text"] as? String ?? "", speakerID: string($0["speaker"]), languageCode: $0["language_code"] as? String, confidence: number($0["confidence"]))
        }
        let words = (root["words"] as? [[String: Any]])?.map(word(seconds: false))
        return result(text: root["text"] as? String ?? "", segments: segments, words: words, languages: [root["language_code"] as? String].compactMap { $0 }, request: request, jobID: jobID)
    }

    static func modulate(_ data: Data, request: ExternalTranscriptionRequest) throws -> TranscriptionResult {
        let root = try ProviderHTTP.object(data)
        let utterances = root["utterances"] as? [[String: Any]] ?? []
        let segments = utterances.map { object in
            let start = int64(object["start_ms"])
            let duration = int64(object["duration_ms"])
            return NormalizedTranscriptionSegment(startMilliseconds: start, endMilliseconds: start.flatMap { startValue in duration.map { startValue + $0 } }, text: object["text"] as? String ?? "", speakerID: string(object["speaker"]), languageCode: object["language"] as? String, confidence: nil)
        }
        let words = (root["words"] as? [[String: Any]])?.map(word(seconds: true))
        return result(text: root["text"] as? String ?? "", segments: segments, words: words, languages: Array(Set(segments.compactMap(\.languageCode))), request: request, duration: int64(root["duration_ms"]))
    }

    static func openAICompatible(_ data: Data, request: ExternalTranscriptionRequest) throws -> TranscriptionResult {
        let root = try ProviderHTTP.object(data)
        let rawSegments = root["segments"] as? [[String: Any]] ?? []
        let segments = rawSegments.map {
            NormalizedTranscriptionSegment(startMilliseconds: milliseconds($0["start"]), endMilliseconds: milliseconds($0["end"]), text: $0["text"] as? String ?? "", speakerID: string($0["speaker"]), languageCode: $0["language"] as? String, confidence: number($0["confidence"]))
        }
        let words = (root["words"] as? [[String: Any]])?.map(word(seconds: true))
        return result(text: root["text"] as? String ?? "", segments: segments, words: words, languages: [root["language"] as? String].compactMap { $0 }, request: request, duration: milliseconds(root["duration"]))
    }

    static func elevenLabs(_ data: Data, request: ExternalTranscriptionRequest) throws -> TranscriptionResult {
        let root = try ProviderHTTP.object(data)
        let words = (root["words"] as? [[String: Any]])?.filter { ($0["type"] as? String) == "word" }.map(word(seconds: true))
        let segments = segmentsFromWords(words ?? [])
        return result(text: root["text"] as? String ?? "", segments: segments, words: words, languages: [root["language_code"] as? String].compactMap { $0 }, request: request)
    }

    private static func result(text: String, segments: [NormalizedTranscriptionSegment], words: [NormalizedTranscriptionWord]?, languages: [String], request: ExternalTranscriptionRequest, resolvedModel: String? = nil, jobID: String? = nil, duration: Int64? = nil) -> TranscriptionResult {
        let normalizedSegments = segments.isEmpty && !text.isEmpty ? [.init(text: text)] : segments
        return .init(text: text, segments: normalizedSegments, words: words, detectedLanguages: languages, providerInfo: .init(connectionID: request.connection.id, provider: request.connection.provider, requestedModelID: request.connection.modelID, resolvedModelID: resolvedModel, providerJobID: jobID, attemptNumber: request.attemptNumber, processingMode: request.connection.processingMode, completedAt: Date()), audioDurationMilliseconds: duration ?? Int64(request.durationSeconds * 1_000), warnings: [])
    }

    private static func word(seconds: Bool) -> ([String: Any]) -> NormalizedTranscriptionWord {
        { object in
            .init(startMilliseconds: seconds ? milliseconds(object["start"]) : int64(object["start"]), endMilliseconds: seconds ? milliseconds(object["end"]) : int64(object["end"]), text: object["word"] as? String ?? object["text"] as? String ?? "", speakerID: string(object["speaker"] ?? object["speaker_id"]), languageCode: object["language"] as? String ?? object["language_code"] as? String, confidence: number(object["confidence"] ?? object["probability"]))
        }
    }

    private static func segmentsFromWords(_ words: [NormalizedTranscriptionWord]) -> [NormalizedTranscriptionSegment] {
        guard !words.isEmpty else { return [] }
        var groups: [[NormalizedTranscriptionWord]] = []
        for word in words {
            if groups.last?.last?.speakerID == word.speakerID { groups[groups.count - 1].append(word) } else { groups.append([word]) }
        }
        return groups.map { group in
            .init(startMilliseconds: group.first?.startMilliseconds, endMilliseconds: group.last?.endMilliseconds, text: group.map(\.text).joined(separator: " "), speakerID: group.first?.speakerID, languageCode: group.first?.languageCode, confidence: nil)
        }
    }

    private static func milliseconds(_ value: Any?) -> Int64? { number(value).map { Int64($0 * 1_000) } }
    private static func int64(_ value: Any?) -> Int64? { number(value).map(Int64.init) }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
