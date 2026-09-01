import Foundation
import ParakeetTDT
import SwiftData

/// Orchestrates transcription jobs for lectures, including recovery of a job
/// with a partially persisted Raw Transcript artifact after an app restart.
@MainActor
@Observable
final class TranscriptionService {
    private(set) var isRunning = false
    private(set) var activeLectureTitle: String?
    private(set) var lastError: String?

    private let modelContainer: ModelContainer
    private let preferences: TranscriptionPreferences
    private let engine = TranscriptionEngine()
    private let whisperEngine = WhisperTranscriptionEngine()
    private let externalEngine: ExternalTranscriptionEngine
    private let jobStore = TranscriptionJobStore()
    private var pendingIDs: [PersistentIdentifier] = []
    private var activeID: PersistentIdentifier?

    init(modelContainer: ModelContainer, preferences: TranscriptionPreferences) {
        self.modelContainer = modelContainer
        self.preferences = preferences
        let antigravityProfile = AgentProfiles.profile(id: AgentProfiles.antigravityID)
        self.externalEngine = ExternalTranscriptionEngine(
            antigravity: antigravityProfile.map { AntigravityCLI.configured(for: $0) } ?? AntigravityCLI()
        )
    }

    /// Enqueue a lecture after the user has requested transcription, or resume
    /// a transcription job that was already running when the app closed.
    func enqueue(lectureID: PersistentIdentifier) {
        guard activeID != lectureID,
              !pendingIDs.contains(lectureID) else {
            return
        }
        pendingIDs.append(lectureID)
        drainQueue()
    }

    /// Scan the store for lectures that need transcription and enqueue them.
    func processPending() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Lecture>(sortBy: [SortDescriptor(\Lecture.capturedAt)])
        let lectures = (try? context.fetch(descriptor)) ?? []

        for lecture in lectures {
            _ = recoverCompletedLocalCheckpointIfPossible(lecture)
        }
        try? context.save()

        for lecture in lectures where lecture.status == .transcribing {
            enqueue(lectureID: lecture.persistentModelID)
        }
    }

    @discardableResult
    func recoverCompletedLocalCheckpointIfPossible(_ lecture: Lecture) -> Bool {
        guard lecture.status == .failed,
              lecture.transcriptCompletedAt == nil,
              let artifact = lecture.artifact(of: .rawTranscript),
              LocalCheckpointRecovery.isNearlyComplete(
                markdown: artifact.content,
                durationSeconds: lecture.duration,
                source: lecture.transcriptionSourceOverride,
                failureMessage: lecture.statusMessage
              ) else {
            return false
        }

        let recoveredModel = BuiltInTranscriptionModel.resolve(
            lecture.transcriptModelID,
            language: lecture.language
        )
        let modelInfo = recoveredModel.modelInfo
        artifact.modelInfo = modelInfo
        lecture.transcriptProviderRaw = TranscriptionProviderID.local.rawValue
        lecture.transcriptConnectionName = "On this Mac"
        lecture.transcriptModelID = modelInfo
        lecture.transcriptCompletedAt = artifact.generatedAt
        lecture.transcriptFallbackSummary = "Recovered the near-complete on-device transcript after the cloud fallback failed. Review any repeated passage before using it as a final transcript."
        lecture.status = .ready
        lecture.statusMessage = nil
        try? modelContainer.mainContext.save()
        return true
    }

    /// Re-runs transcription, optionally in a different language (e.g. a shiur
    /// that was recorded before its course was marked English + Hebrew). The
    /// existing Raw Transcript artifact is overwritten.
    func retranscribe(
        _ lecture: Lecture,
        as language: LectureLanguage,
        source: TranscriptionSource? = nil,
        connectionID: UUID? = nil,
        builtInModelID: String? = nil
    ) {
        guard lecture.recording != nil,
              lecture.status == .recorded ||
              lecture.status == .ready ||
              lecture.status == .failed else {
            return
        }
        lecture.language = language
        lecture.transcriptionSourceOverride = source
        lecture.requestedTranscriptionConnectionID = connectionID
        if source == .local {
            lecture.transcriptModelID = builtInModelID
        }
        lecture.status = .transcribing
        lecture.statusMessage = nil
        try? modelContainer.mainContext.save()
        enqueue(lectureID: lecture.persistentModelID)
    }

    // MARK: - Queue

    private func drainQueue() {
        guard !isRunning else { return }
        guard let nextID = pendingIDs.first else { return }
        pendingIDs.removeFirst()
        isRunning = true
        activeID = nextID
        Task { await self.run(nextID) }
    }

    private func run(_ id: PersistentIdentifier) async {
        await performJob(id)

        if pendingIDs.isEmpty {
            await engine.unload()
        }
        isRunning = false
        activeID = nil
        activeLectureTitle = nil
        drainQueue()
    }

    private func performJob(_ id: PersistentIdentifier) async {
        let context = modelContainer.mainContext
        guard let lecture = context.model(for: id) as? Lecture,
              let recordingPath = lecture.recording?.filePath else {
            return
        }
        let existingArtifact = lecture.artifact(of: .rawTranscript)
        if existingArtifact != nil, lecture.status == .ready {
            return
        }

        activeLectureTitle = lecture.title
        lastError = nil

        let language = lecture.language
        let plan = TranscriptionJobPlan.resolve(
            preferenceSource: preferences.source,
            preferenceBuiltInModelID: preferences.builtInModelID,
            lectureSource: lecture.transcriptionSourceOverride,
            lectureModelID: lecture.transcriptionSourceOverride == .local
                ? lecture.transcriptModelID
                : nil,
            language: language
        )
        let selectedBuiltInModel: BuiltInTranscriptionModel? = {
            if case .local(let model) = plan { return model }
            return nil
        }()

        if case .askEachTime = plan {
            lecture.status = .failed
            lecture.statusMessage = "Choose Parakeet, Whisper, Gemini through Antigravity, or an API connection for this recording."
            try? context.save()
            return
        }

        let modelInfo = selectedBuiltInModel?.modelInfo ?? "External transcription"

        let artifact: Artifact
        if let existingArtifact {
            artifact = existingArtifact
        } else {
            artifact = Artifact(
                kind: .rawTranscript,
                content: "",
                modelInfo: modelInfo
            )
            artifact.lecture = lecture
            lecture.artifacts.append(artifact)
        }
        lecture.status = .transcribing
        switch plan {
        case .local(.antigravity):
            lecture.transcriptProviderRaw = TranscriptionProviderID.antigravityCLI.rawValue
            lecture.transcriptConnectionName = "Antigravity CLI"
            lecture.transcriptModelID = BuiltInTranscriptionModel.antigravity.id
            lecture.statusMessage = "Preparing Antigravity transcription"
        case .local(let model):
            lecture.transcriptProviderRaw = TranscriptionProviderID.local.rawValue
            lecture.transcriptConnectionName = "On this Mac"
            lecture.transcriptModelID = model.modelInfo
            lecture.statusMessage = "Preparing on-device transcription"
        case .external:
            lecture.statusMessage = "Preparing secure API transcription"
        case .askEachTime:
            break
        }
        try? context.save()

        let checkpoint = TranscriptionCheckpointState()
        let persistProgress: @MainActor @Sendable ([TranscriptSegment], Double) -> Void = { partialSegments, fraction in
            guard lecture.status == .transcribing,
                  checkpoint.shouldPersist(fraction) else {
                return
            }

            artifact.content = Self.markdown(from: partialSegments)
            artifact.generatedAt = Date()
            let percent = Int((fraction * 100).rounded())
            lecture.statusMessage = language == .hebrewEnglish
                ? "Transcribing (English + Hebrew): \(percent)%"
                : "Transcribing on device: \(percent)%"
            try? context.save()
        }

        do {
            switch plan {
            case .askEachTime:
                break
            case .local(let model) where model.usesAntigravity:
                let connection = TranscriptionConnection.builtInAntigravity()
                let result = try await transcribeExternally(
                    recordingPath: recordingPath,
                    lecture: lecture,
                    selectedConnection: connection,
                    recoverCompletedResult: artifact.content.isEmpty
                )
                apply(result, to: artifact, lecture: lecture, selectedConnection: connection)
            case .local(let model):
                do {
                    let segments = try await transcribeLocally(
                        recordingPath: recordingPath,
                        lecture: lecture,
                        model: model,
                        progress: persistProgress
                    )
                    artifact.content = Self.markdown(from: segments)
                    artifact.modelInfo = modelInfo
                    lecture.transcriptProviderRaw = TranscriptionProviderID.local.rawValue
                    lecture.transcriptConnectionName = "On this Mac"
                    lecture.transcriptModelID = model.modelInfo
                    lecture.transcriptCompletedAt = Date()
                    lecture.transcriptFallbackSummary = nil
                } catch {
                    guard preferences.allowFallbackProviders,
                          preferences.allowCloudFallbackAfterLocalFailure,
                          let connection = preferences.defaultConnection else {
                        throw error
                    }
                    let result = try await transcribeExternally(
                        recordingPath: recordingPath,
                        lecture: lecture,
                        selectedConnection: connection,
                        initialFailure: error.localizedDescription,
                        recoverCompletedResult: artifact.content.isEmpty
                    )
                    apply(result, to: artifact, lecture: lecture, selectedConnection: connection)
                }
            case .external:
                guard let connection = preferences.connection(id: lecture.requestedTranscriptionConnectionID)
                        ?? preferences.defaultConnection else {
                    throw ExternalTranscriptionError(
                        code: .invalidCredentials,
                        retryable: false,
                        fallbackEligible: false,
                        userMessage: "Add an API connection in Settings before using external transcription."
                    )
                }
                let result = try await transcribeExternally(
                    recordingPath: recordingPath,
                    lecture: lecture,
                    selectedConnection: connection,
                    recoverCompletedResult: artifact.content.isEmpty
                )
                apply(result, to: artifact, lecture: lecture, selectedConnection: connection)
            }

            artifact.generatedAt = Date()
            lecture.status = .ready
            lecture.statusMessage = nil
            try? context.save()
        } catch {
            lecture.status = .failed
            lecture.statusMessage = error.localizedDescription
            lastError = "Transcription failed: \(error.localizedDescription)"
            try? context.save()
        }
    }

    private func transcribeLocally(
        recordingPath: String,
        lecture: Lecture,
        model: BuiltInTranscriptionModel,
        progress: @escaping @MainActor @Sendable ([TranscriptSegment], Double) -> Void
    ) async throws -> [TranscriptSegment] {
        switch model {
        case .parakeet:
            if !engine.isModelCached {
                _ = try await ModelDownloader().download(repoId: TranscriptionEngine.repoId)
            }
            return try await engine.transcribe(
                fileURL: URL(fileURLWithPath: recordingPath),
                progress: progress
            )
        case .whisper:
            guard WhisperTranscriptionEngine.isCLIInstalled else {
                throw WhisperTranscriptionEngine.cliMissing
            }
            if !whisperEngine.isModelCached {
                lecture.statusMessage = "Downloading Hebrew-capable Whisper model (~1.1 GB)…"
                try? modelContainer.mainContext.save()
                try await whisperEngine.downloadModel { fraction in
                    guard lecture.status == .transcribing else { return }
                    let percent = Int((fraction * 100).rounded())
                    lecture.statusMessage = "Downloading Whisper model: \(percent)%"
                }
            }
            return try await whisperEngine.transcribe(
                fileURL: URL(fileURLWithPath: recordingPath),
                durationSeconds: lecture.duration,
                progress: progress
            )
        case .antigravity:
            preconditionFailure("Antigravity transcription must use the external adapter.")
        }
    }

    private func transcribeExternally(
        recordingPath: String,
        lecture: Lecture,
        selectedConnection: TranscriptionConnection,
        initialFailure: String? = nil,
        recoverCompletedResult: Bool
    ) async throws -> TranscriptionResult {
        let audioIdentity = Self.audioIdentity(path: recordingPath)
        let recoveredJob = await jobStore.recoverableJob(
            recordingPath: recordingPath,
            sourceAudioHash: audioIdentity,
            includeCompleted: recoverCompletedResult
        )
        var job = recoveredJob ?? PersistentTranscriptionJob(
            recordingPath: recordingPath,
            sourceAudioHash: audioIdentity,
            state: .queued,
            selectedConnectionID: selectedConnection.id,
            fallbackPlanSnapshot: preferences.fallbackPlan(startingWith: selectedConnection).map(\.id),
            policySnapshot: preferences.snapshot()
        )
        if job.state == .completed, let result = job.completedResult {
            return result
        }

        let planIDs = recoveredJob?.fallbackPlanSnapshot
            ?? preferences.fallbackPlan(startingWith: selectedConnection).map(\.id)
        let plan: [TranscriptionConnection]
        if recoveredJob != nil {
            plan = try planIDs.map { id in
                if id == selectedConnection.id { return selectedConnection }
                guard let connection = preferences.connection(id: id) else {
                    throw ExternalTranscriptionError(
                        code: .invalidCredentials,
                        retryable: false,
                        fallbackEligible: false,
                        userMessage: "A connection needed to resume this transcription was removed. Choose a transcriber and try again."
                    )
                }
                return connection
            }
        } else {
            plan = planIDs.compactMap { id in
                id == selectedConnection.id ? selectedConnection : preferences.connection(id: id)
            }
        }
        guard !plan.isEmpty else {
            throw ExternalTranscriptionError(
                code: .invalidCredentials, retryable: false, fallbackEligible: false,
                userMessage: "No enabled transcription connection is available."
            )
        }

        let jobID = job.id
        var lastError: ExternalTranscriptionError?
        let startIndex = min(job.currentAttemptIndex, max(0, plan.count - 1))

        for index in startIndex..<plan.count {
            let connection = plan[index]
            if index > 0, connection.costTier.isPaid, preferences.askBeforePaidFallback {
                throw ExternalTranscriptionError(
                    code: .permissionDenied, retryable: false, fallbackEligible: false,
                    userMessage: "A paid fallback is next. Select it explicitly to approve that upload."
                )
            }

            job.currentAttemptIndex = index
            job.state = .preparing
            while !job.attempts.indices.contains(index) {
                job.attempts.append(.init(
                    connectionID: connection.id,
                    provider: connection.provider,
                    requestedModelID: connection.modelID
                ))
            }
            await jobStore.upsert(job)
            lecture.transcriptProviderRaw = connection.provider.rawValue
            lecture.transcriptConnectionName = connection.displayName
            lecture.transcriptModelID = connection.modelID
            lecture.statusMessage = "Transcribing with \(connection.displayName)"
            try? modelContainer.mainContext.save()

            let resumeID = job.attempts[index].providerJobID
            let request = ExternalTranscriptionRequest(
                audioURL: URL(fileURLWithPath: recordingPath),
                durationSeconds: lecture.duration,
                lectureLanguage: lecture.language,
                connection: connection,
                attemptNumber: index + 1,
                resumeProviderJobID: resumeID
            )

            do {
                let store = jobStore
                let result = try await externalEngine.transcribe(request) { update in
                    await store.update(id: jobID, state: update.state, providerJobID: update.providerJobID)
                }
                if let persisted = await jobStore.job(id: jobID) { job = persisted }
                job.state = .completed
                job.completedAt = Date()
                job.completedResult = result
                job.attempts[index].resolvedModelID = result.providerInfo.resolvedModelID
                job.attempts[index].providerJobID = result.providerInfo.providerJobID
                await jobStore.upsert(job)

                let failedNames = job.attempts.prefix(index).map { attempt in
                    TranscriptionProviderCatalog.provider(attempt.provider)?.name ?? attempt.provider.rawValue
                }
                lecture.transcriptFallbackSummary = initialFailure.map { "Local failed: \($0)" }
                    ?? (failedNames.isEmpty ? nil : "Fallback used after \(failedNames.joined(separator: ", "))")
                return result
            } catch let error as ExternalTranscriptionError {
                if let persisted = await jobStore.job(id: jobID) { job = persisted }
                lastError = error
                job.attempts[index].error = error
                if error.code == .acceptedStateUnknown {
                    job.attempts[index].acceptedStateUnknown = true
                }
                let hasNext = index + 1 < plan.count
                job.state = hasNext && error.fallbackEligible ? .waitingForFallback : .failed
                await jobStore.upsert(job)
                guard hasNext, error.fallbackEligible, error.code != .acceptedStateUnknown else {
                    throw error
                }
            }
        }
        throw lastError ?? ExternalTranscriptionError(
            code: .unknown, retryable: false, fallbackEligible: false,
            userMessage: "Every allowed transcription connection failed."
        )
    }

    private func apply(
        _ result: TranscriptionResult,
        to artifact: Artifact,
        lecture: Lecture,
        selectedConnection: TranscriptionConnection
    ) {
        artifact.content = Self.markdown(from: result)
        artifact.modelInfo = "\(result.providerInfo.provider.rawValue) / \(result.providerInfo.resolvedModelID ?? result.providerInfo.requestedModelID)"
        lecture.transcriptProviderRaw = result.providerInfo.provider.rawValue
        lecture.transcriptConnectionName = preferences.connection(id: result.providerInfo.connectionID)?.displayName
            ?? selectedConnection.displayName
        lecture.transcriptModelID = result.providerInfo.resolvedModelID ?? result.providerInfo.requestedModelID
        lecture.transcriptCompletedAt = result.providerInfo.completedAt
    }

    private static func audioIdentity(path: String) -> String {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    // MARK: - Markdown formatting

    static func markdown(from segments: [TranscriptSegment]) -> String {
        var lines: [String] = []
        var currentLine = ""
        var previousEnd: Double?

        for segment in segments {
            let startsNewParagraph = previousEnd.map { segment.startSeconds - $0 > 2.0 } ?? true
            if startsNewParagraph {
                if !currentLine.isEmpty { lines.append(currentLine) }
                currentLine = "[\(timestamp(segment.startSeconds))] \(segment.text)"
            } else {
                currentLine += " " + segment.text
            }
            previousEnd = segment.endSeconds
        }
        if !currentLine.isEmpty { lines.append(currentLine) }
        return lines.joined(separator: "\n\n")
    }

    static func markdown(from result: TranscriptionResult) -> String {
        let timed = result.segments.filter { $0.startMilliseconds != nil }
        guard !timed.isEmpty else { return result.text }
        return timed.map { segment in
            let seconds = Double(segment.startMilliseconds ?? 0) / 1_000
            let speaker = segment.speakerID.map { "**\($0):** " } ?? ""
            return "[\(timestamp(seconds))] \(speaker)\(segment.text)"
        }.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@MainActor
private final class TranscriptionCheckpointState {
    private var lastFraction = 0.0

    func shouldPersist(_ fraction: Double) -> Bool {
        guard fraction > lastFraction else { return false }
        lastFraction = fraction
        return true
    }
}
