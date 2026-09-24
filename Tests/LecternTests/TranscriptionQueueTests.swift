import Foundation
import SwiftData
import Testing

@MainActor
struct TranscriptionQueueTests {
    @Test func continuousSpeechKeepsRegularTimestampAnchors() {
        let segments = (0..<6).map { index in
            TranscriptSegment(startSeconds: Double(index * 5),
                              endSeconds: Double(index * 5 + 4),
                              text: "Concept \(index)")
        }
        let paragraphs = TranscriptParagraph.parse(TranscriptionService.markdown(from: segments))
        #expect(paragraphs.map(\.timestampLabel) == ["00:00", "00:20"])
        #expect(TranscriptParagraph.closestIndex(to: 23, in: paragraphs) == 1)
    }

    @Test(arguments: [true, false])
    func deletedQueuedLectureIsSkipped(saveDeletion: Bool) async throws {
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let lecture = Lecture(title: "Deleted while queued", capturedAt: Date(), status: .transcribing)
        let next = Lecture(title: "Next lecture", capturedAt: Date(), status: .transcribing)
        next.recording = Recording(filePath: "/unused-test-recording.wav", sampleRate: 16_000,
                                   sizeBytes: 0, recordedAt: Date())
        context.insert(lecture)
        context.insert(next)
        try context.save()
        let id = lecture.persistentModelID
        let suite = "TranscriptionQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        // Exercise a valid job without downloading a model or invoking a provider.
        preferences.source = .askEachTime
        let service = TranscriptionService(modelContainer: container,
                                           preferences: preferences,
                                           completionNotifier: SilentNotifier())
        service.enqueue(lectureID: id)
        service.enqueue(lectureID: next.persistentModelID)
        context.delete(lecture)
        if saveDeletion { try context.save() }
        for _ in 0..<100 where service.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!service.isRunning)
        #expect(!service.isQueuedOrRunning(lectureID: id))
        #expect(service.lastError == nil)
        #expect(next.status == .failed)
        #expect(next.statusMessage?.hasPrefix("Choose Parakeet") == true)
        #expect(try context.fetch(FetchDescriptor<Lecture>()).map(\.title) == ["Next lecture"])
    }

    @Test(arguments: [true, false])
    func deletionCancelsActiveAndQueuedWork(lateFailure: Bool) async throws {
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let lectures = (0..<3).map { index in
            let lecture = Lecture(title: "Lecture \(index)", capturedAt: Date(), status: .transcribing)
            lecture.recording = Recording(filePath: "/test-\(index).wav", sampleRate: 16_000,
                                          sizeBytes: 0, recordedAt: Date())
            context.insert(lecture)
            return lecture
        }
        try context.save()
        lectures[2].transcriptionSourceOverride = .askEachTime
        let ids = lectures.map(\.persistentModelID)
        let suite = "TranscriptionQueueTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        preferences.source = .local
        preferences.builtInModelID = BuiltInTranscriptionModel.parakeet.rawValue
        let engine = SuspendedEngine()
        let notifier = SilentNotifier()
        let service = TranscriptionService(modelContainer: container, preferences: preferences,
                                           completionNotifier: notifier, engine: engine)
        ids.forEach { service.enqueue(lectureID: $0) }
        for _ in 0..<100 where !engine.started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.started)
        #expect(engine.calls == 1)
        service.cancel(lectureID: ids[1])
        #expect(!service.isQueuedOrRunning(lectureID: ids[1]))
        context.delete(lectures[1])
        service.cancel(lectureID: ids[0])
        context.delete(lectures[0])
        try context.save()
        // Progress can arrive from a separate callback task after cancellation.
        engine.progress?([], 0.5)
        preferences.source = .askEachTime
        engine.finish(lateFailure: lateFailure)
        for _ in 0..<100 where service.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!service.isRunning)
        #expect(engine.wasCancelled)
        #expect(engine.calls == 1)
        #expect(service.lastError == nil)
        #expect(notifier.delivered == 0)
        #expect(lectures[2].statusMessage?.hasPrefix("Choose Parakeet") == true)
        #expect(try context.fetch(FetchDescriptor<Lecture>()).map(\.title) == ["Lecture 2"])
        #expect(try context.fetch(FetchDescriptor<Artifact>()).isEmpty)
    }

    @Test func cancellationReachesSynchronousWorkAndLateHandlers() throws {
        let cancellation = TranscriptionCancellation()
        try cancellation.check()
        cancellation.cancel()
        #expect(throws: CancellationError.self) { try cancellation.check() }
        let invoked = TranscriptionCancellation()
        cancellation.onCancel { invoked.cancel() }
        #expect(throws: CancellationError.self) { try invoked.check() }
    }

    @Test func cancellingWhisperStopsItsProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-whisper")
        let started = directory.appendingPathComponent("started")
        let stopped = directory.appendingPathComponent("stopped")
        let script = """
        #!/bin/sh
        trap 'touch "\(stopped.path)"; exit 0' TERM
        touch "\(started.path)"
        while :; do sleep 0.05; done
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let cancellation = TranscriptionCancellation()
        defer { cancellation.cancel() }
        let engine = WhisperTranscriptionEngine()
        let task = Task.detached {
            try engine.run(cli: cli, audioURL: directory.appendingPathComponent("unused.wav"),
                           durationSeconds: 1, cancellation: cancellation, progress: nil)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path))
        cancellation.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled Whisper returned a transcript")
        } catch is CancellationError {
            #expect(FileManager.default.fileExists(atPath: stopped.path))
        }
    }

    @MainActor
    private final class SuspendedEngine: LocalTranscribing {
        nonisolated let isModelCached = true
        var started = false
        var calls = 0
        var wasCancelled = false
        var progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?
        private var continuation: CheckedContinuation<Bool, Never>?

        func transcribe(fileURL: URL, progress: (@MainActor @Sendable ([TranscriptSegment], Double) -> Void)?) async throws -> [TranscriptSegment] {
            calls += 1
            self.progress = progress
            let lateFailure = await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
            wasCancelled = Task.isCancelled
            if lateFailure { throw NSError(domain: "Late engine failure", code: 1) }
            return []
        }

        func finish(lateFailure: Bool) {
            continuation?.resume(returning: lateFailure)
            continuation = nil
        }

        func unload() async {}
    }

    private final class SilentNotifier: CompletionNotifying {
        var delivered = 0
        func prepare(for category: CompletionNotificationCategory) {}
        func deliver(_ notification: CompletionNotification) { delivered += 1 }
    }
}
