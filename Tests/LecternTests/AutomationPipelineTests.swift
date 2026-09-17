import AVFoundation
import Foundation
import SwiftData
import Testing

@MainActor
struct AutomationPipelineTests {
    private final class SilentNotifier: CompletionNotifying {
        func prepare(for category: CompletionNotificationCategory) {}
        func deliver(_ notification: CompletionNotification) {}
    }

    private actor FeedProvider: ShiurSourceProvider {
        nonisolated let providerKey = "yutorah"
        nonisolated let displayName = "Fixture"
        var batches: [[RemoteShiurItem]]
        let onResolve: (@MainActor @Sendable () throws -> Void)?
        init(_ batches: [[RemoteShiurItem]], onResolve: (@MainActor @Sendable () throws -> Void)? = nil) {
            self.batches = batches
            self.onResolve = onResolve
        }
        func search(query: String) async throws -> [ShiurDiscoveryResult] { [] }
        func resolveSubscription(for entity: ShiurSubscriptionEntity) async throws -> ResolvedSubscription { throw URLError(.unsupportedURL) }
        func resolveSharedURL(_ url: URL) async throws -> ShiurDiscoveryResult { throw URLError(.unsupportedURL) }
        func fetchFeed(url: URL, eTag: String?, lastModified: String?, maxResults: Int) async throws -> FeedFetchResult {
            .newItems(items: batches.removeFirst(), channelTitle: nil, eTag: "fixture", lastModified: nil)
        }
        func resolveMediaURL(for item: RemoteShiurItem) async throws -> URL {
            try await onResolve?()
            throw URLError(.notConnectedToInternet)
        }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self, ShiurAutomationItem.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func service(_ container: ModelContainer, batches: [[RemoteShiurItem]], generationDefaults: UserDefaults = .standard, onResolve: (@MainActor @Sendable () throws -> Void)? = nil) -> ShiurAutomationService {
        let suite = "LecternAudit-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        preferences.source = .external
        return ShiurAutomationService(
            modelContainer: container, provider: FeedProvider(batches, onResolve: onResolve),
            transcriptionService: TranscriptionService(modelContainer: container, preferences: preferences, completionNotifier: SilentNotifier()),
            transcriptionPreferences: preferences,
            generationService: GenerationService(modelContainer: container, completionNotifier: SilentNotifier()),
            completionNotifier: SilentNotifier(), defaults: generationDefaults)
    }

    private func subscription(_ container: ModelContainer, backlog: Bool = false) -> ShiurSubscription {
        let sub = ShiurSubscription(resolvedFeedURLString: "https://example.test/feed", displayName: "Fixture",
                                    autoTranscribe: false, baselineFutureOnly: !backlog)
        container.mainContext.insert(sub)
        return sub
    }

    @Test func emptyBaselineDoesNotSwallowFirstNewShiur() async throws {
        let container = try container()
        let sub = subscription(container)
        let service = service(container, batches: [[], [.init(shiurID: "1", title: "New")]])
        await service.checkSubscription(sub, ignoreDue: true)
        await service.checkSubscription(sub, ignoreDue: true)
        #expect(try container.mainContext.fetch(FetchDescriptor<ShiurAutomationItem>()).count == 1)
    }

    @Test func backlogChoosesNewestFiveRegardlessOfFeedOrder() async throws {
        let container = try container()
        let sub = subscription(container, backlog: true)
        let items = (1...8).map { RemoteShiurItem(shiurID: String($0), title: "Shiur", date: Date(timeIntervalSince1970: Double($0))) }
        await service(container, batches: [items]).checkSubscription(sub, ignoreDue: true)
        let queued = try container.mainContext.fetch(FetchDescriptor<ShiurAutomationItem>())
        #expect(Set(queued.map(\.shiurID)) == Set(["4", "5", "6", "7", "8"]))
    }

    @Test func overlappingSubscriptionsShareFailedImport() async throws {
        let container = try container()
        let first = subscription(container, backlog: true)
        let second = subscription(container, backlog: true)
        let items = [RemoteShiurItem(shiurID: "1", title: "Same shiur")]
        let service = service(container, batches: [items, items])
        await service.checkSubscription(first, ignoreDue: true)
        await service.checkSubscription(second, ignoreDue: true)
        #expect(try container.mainContext.fetch(FetchDescriptor<ShiurAutomationItem>()).count == 1)
    }

    @Test func resumedDownloadReusesAlreadyImportedLecture() async throws {
        let container = try container()
        let lecture = Lecture(title: "Already imported", capturedAt: Date(), status: .recorded)
        lecture.sourceKey = "yutorah:1"
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: "Already imported", state: .downloading, autoTranscribe: false)
        container.mainContext.insert(item)
        await service(container, batches: []).processItem(item)
        #expect(item.state == .complete)
        #expect(item.downloadAttempts == 0)
    }

    @Test func failedPartialTranscriptIsNotTreatedAsComplete() async throws {
        let container = try container()
        let lecture = Lecture(title: "Interrupted", capturedAt: Date(), status: .failed)
        lecture.sourceKey = "yutorah:1"
        lecture.recording = Recording(filePath: "/nonexistent.wav", sampleRate: 16000, sizeBytes: 1, recordedAt: Date())
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "partial checkpoint", modelInfo: "Fixture"))
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: "Interrupted", state: .waitingForTranscription, autoGenerateNotes: false)
        container.mainContext.insert(item)
        await service(container, batches: []).processItem(item)
        #expect(item.state == .failed)
    }

    @Test func pipelineWaitsForQueuedTranscriptionFailure() async throws {
        let container = try container()
        let lecture = Lecture(title: "Queued", capturedAt: Date(), status: .recorded)
        lecture.sourceKey = "yutorah:1"
        lecture.recording = Recording(filePath: "/nonexistent.wav", sampleRate: 16000, sizeBytes: 1, recordedAt: Date())
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: "Queued", state: .waitingForTranscription, autoGenerateNotes: false)
        container.mainContext.insert(item)
        try container.mainContext.save()
        await service(container, batches: []).processItem(item)
        #expect(item.state == .failed)
    }

    @Test func entireQueueAndCourseAreSavedBeforeFirstDownload() async throws {
        let container = try container()
        let course = Course(name: "Fixture", colorHex: "#000000")
        container.mainContext.insert(course)
        let sub = subscription(container, backlog: true)
        sub.course = course
        try container.mainContext.save()
        let courseID = course.persistentModelID
        let items = (1...3).map { RemoteShiurItem(shiurID: String($0), title: "Shiur") }
        let service = service(container, batches: [items]) {
            let savedContext = ModelContext(container)
            let queued = try savedContext.fetch(FetchDescriptor<ShiurAutomationItem>())
            #expect(queued.count == 3)
            for item in queued {
                let data = try #require(item.targetCourseIDData)
                #expect(try JSONDecoder().decode(PersistentIdentifier.self, from: data) == courseID)
            }
        }
        await service.checkSubscription(sub, ignoreDue: true)
    }

    @Test func retryContinuesCompletedTranscriptWithoutRedownload() async throws {
        let container = try container()
        let lecture = Lecture(title: "Retry", capturedAt: Date(), status: .ready)
        lecture.sourceKey = "yutorah:1"
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "Finished transcript", modelInfo: "Fixture"))
        lecture.artifacts.append(Artifact(kind: .cleanedTranscript, content: "Cleaned transcript", modelInfo: "Fixture"))
        lecture.artifacts.append(Artifact(kind: .notes, content: "Finished notes", modelInfo: "Fixture"))
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: "Retry", state: .failed, stateMessage: "Interrupted")
        container.mainContext.insert(item)
        await service(container, batches: []).retryItem(item)
        #expect(item.state == .complete)
        #expect(item.stateMessage == nil)
        #expect(item.downloadAttempts == 0)
    }

    @Test(arguments: [true, false])
    func completedTranscriptionHonorsGenerationToggle(generate: Bool) async throws {
        let container = try container()
        let suite = "AutomationGeneration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // An unknown profile fails immediately if the generation stage is reached.
        defaults.set("missing-agent", forKey: "generation.agentID")
        let lecture = Lecture(title: "Imported", capturedAt: Date(), status: .ready)
        lecture.sourceKey = "yutorah:1"
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "Finished transcript", modelInfo: "Fixture"))
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: "Imported",
                                       state: .waitingForTranscription, autoGenerateNotes: generate)
        container.mainContext.insert(item)
        await service(container, batches: [], generationDefaults: defaults).processItem(item)
        #expect(item.state == (generate ? .failed : .complete))
        #expect(item.stateMessage == (generate
            ? "Default study agent is not configured. Set one in Settings › Agents." : nil))
        #expect(lecture.hasCompletedRawTranscript)
    }

    @Test(arguments: [ArtifactKind.notes, .cleanedTranscript])
    func partialGenerationStillRequiresTheOtherArtifact(existingKind: ArtifactKind) async throws {
        let container = try container()
        let suite = "AutomationPartialGeneration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("missing-agent", forKey: "generation.agentID")
        let lecture = Lecture(title: "Partial generation", capturedAt: Date(), status: .ready)
        lecture.sourceKey = "yutorah:1"
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "Finished transcript", modelInfo: "Fixture"))
        lecture.artifacts.append(Artifact(kind: existingKind, content: "Existing output", modelInfo: "Fixture"))
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: lecture.title,
                                       state: .waitingForNotes)
        container.mainContext.insert(item)
        await service(container, batches: [], generationDefaults: defaults).processItem(item)
        #expect(item.state == .failed)
        #expect(item.stateMessage == "Default study agent is not configured. Set one in Settings › Agents.")
        #expect(lecture.artifact(of: existingKind)?.content == "Existing output")
    }

    @Test func duplicateFeedEntriesCreateOneQueueItem() async throws {
        let container = try container()
        let sub = subscription(container, backlog: true)
        let remote = RemoteShiurItem(shiurID: "1", title: "Repeated")
        await service(container, batches: [[remote, remote]]).checkSubscription(sub, ignoreDue: true)
        #expect(try container.mainContext.fetch(FetchDescriptor<ShiurAutomationItem>()).count == 1)
    }

    @Test func retentionPrunesCompletedTranscriptAudio() throws {
        let container = try container()
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let lecture = Lecture(title: "Finished", capturedAt: Date(), status: .ready)
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "Finished transcript", modelInfo: "Fixture"))
        let recording = Recording(filePath: audio.path, sampleRate: 16000, sizeBytes: 3, recordedAt: .distantPast)
        lecture.recording = recording
        recording.lecture = lecture
        container.mainContext.insert(lecture)
        try container.mainContext.save()
        #expect(RetentionService(modelContainer: container).sweepNow() == 1)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(recording.prunedAt != nil)
    }

    @Test func emptyReadyTranscriptCanBeRetried() async throws {
        let container = try container()
        let lecture = Lecture(title: "Empty", capturedAt: Date(), status: .ready)
        lecture.sourceKey = "yutorah:1"
        lecture.recording = Recording(filePath: "/nonexistent.wav", sampleRate: 16000, sizeBytes: 1, recordedAt: Date())
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "", modelInfo: "Fixture"))
        container.mainContext.insert(lecture)
        let item = ShiurAutomationItem(sourceKey: "yutorah:1", shiurID: "1", title: "Empty", state: .waitingForTranscription, autoGenerateNotes: false)
        container.mainContext.insert(item)
        await service(container, batches: []).processItem(item)
        // No connection is configured. Actually attempting transcription must
        // report that failure instead of silently accepting the empty artifact.
        #expect(lecture.status == .failed)
    }

    @Test func manualGenerationCannotReplaceActiveAutomaticJob() async throws {
        let container = try container()
        let first = Lecture(title: "Automatic", capturedAt: Date(), status: .ready)
        first.artifacts.append(Artifact(kind: .rawTranscript, content: "Transcript", modelInfo: "Fixture"))
        let second = Lecture(title: "Manual", capturedAt: Date(), status: .ready)
        second.artifacts.append(Artifact(kind: .rawTranscript, content: "Transcript", modelInfo: "Fixture"))
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let service = GenerationService(modelContainer: container, completionNotifier: SilentNotifier())
        let profile = AgentProfile(id: "fixture", title: "Fixture", command: "/bin/sleep 2")
        let job = Task { try await service.generateDirectly(lecture: first, kinds: [.cleanedTranscript], profile: profile) }
        for _ in 0..<100 where service.job(for: first.persistentModelID) == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(service.job(for: first.persistentModelID)?.lectureTitle == "Automatic")
        service.generate(lecture: second, kinds: [.cleanedTranscript], profile: profile)
        #expect(service.job(for: first.persistentModelID)?.lectureTitle == "Automatic")
        #expect(service.job(for: second.persistentModelID)?.lectureTitle == "Manual")
        service.cancel()
        job.cancel()
        _ = await job.result
    }

    @Test func retentionKeepsAudioForIncompleteTranscript() throws {
        let container = try container()
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let lecture = Lecture(title: "Partial", capturedAt: Date(), status: .failed)
        lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "partial checkpoint", modelInfo: "Fixture"))
        let recording = Recording(filePath: audio.path, sampleRate: 16000, sizeBytes: 3, recordedAt: .distantPast)
        lecture.recording = recording
        recording.lecture = lecture
        container.mainContext.insert(lecture)
        try container.mainContext.save()
        #expect(RetentionService(modelContainer: container).sweepNow() == 0)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(recording.prunedAt == nil)
    }

    @Test func rapidAudioImportsHaveUniqueFiles() throws {
        let container = try container()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        let importer = LectureImportService(modelContainer: container, recordingsDirectory: directory.appendingPathComponent("imports"))
        var paths: Set<String> = []
        for _ in 0..<5 {
            let lecture = try importer.importAudio(from: source, metadata: .init())
            paths.insert(lecture.recording!.filePath)
        }
        #expect(paths.count == 5)
    }
}
