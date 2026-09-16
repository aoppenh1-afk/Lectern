import Foundation
import SwiftData
import Testing

@MainActor
struct TranscriptionConcurrentACPTests {
    @Test func geminiLecturesRunTogetherAndCancelSeparately() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agent.py")
        try #"""
import json, sys, os, time
from pathlib import Path
root = Path(__file__).parent
for raw in sys.stdin:
    req = json.loads(raw)
    method = req.get("method")
    if "id" not in req: continue
    result = {}
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}
    elif method == "session/new":
        model = "gemini-3.8-flash-high"
        option = {"id": "model", "category": "model", "currentValue": model,
                  "options": [{"value": model, "name": "Gemini Flash High"}]}
        result = {"sessionId": str(os.getpid()), "configOptions": [option]}
    elif method == "session/prompt":
        (root / (str(os.getpid()) + ".started")).write_text("started")
        while not (root / "release").exists(): time.sleep(0.01)
        print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":str(os.getpid()),"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Cleaned lecture."}}}}), flush=True)
        result = {"stopReason":"end_turn"}
    print(json.dumps({"jsonrpc":"2.0", "id":req["id"], "result":result}), flush=True)
"""#.write(to: script, atomically: true, encoding: .utf8)
        let audio = directory.appendingPathComponent("audio.wav")
        let skill = directory.appendingPathComponent("SKILL.md")
        try Data("audio".utf8).write(to: audio)
        try Data("Transcribe the audio.".utf8).write(to: skill)
        let client = AntigravityACPClient(connectionFactory: {
            try await ACPConnection.connect(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                            arguments: ["-u", script.path], environment: ProcessInfo.processInfo.environment)
        }, skillURLOverrides: [.transcription: skill])
        let external = ExternalTranscriptionEngine(antigravity: client, antigravityAudioPreparation: { _, _ in
            AntigravityAudioPreparer.PreparedAudio(chunks: [.init(url: audio, startSeconds: 0,
                durationSeconds: 1, coreStartSeconds: 0, coreEndSeconds: 1)], temporaryDirectory: nil)
        })
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = Lecture(title: "First", capturedAt: Date(), status: .transcribing)
        let second = Lecture(title: "Second", capturedAt: Date(), status: .transcribing)
        for (index, lecture) in [first, second].enumerated() {
            let file = directory.appendingPathComponent("audio-\(index).wav")
            try Data("audio".utf8).write(to: file)
            lecture.recording = Recording(filePath: file.path, sampleRate: 16_000, sizeBytes: 5, recordedAt: Date())
            container.mainContext.insert(lecture)
        }
        try container.mainContext.save()
        let suite = "TranscriptionConcurrentACPTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TranscriptionPreferences(defaults: defaults)
        // No model override: exercise the app's default Gemini ACP route.
        let service = TranscriptionService(modelContainer: container, preferences: preferences,
            completionNotifier: SilentNotifier(), externalEngine: external,
            jobStore: TranscriptionJobStore(fileURL: directory.appendingPathComponent("jobs.json")))
        defer { service.cancelAll() }
        service.enqueue(lectureID: first.persistentModelID)
        service.enqueue(lectureID: second.persistentModelID)
        for _ in 0..<500 {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if files.filter({ $0.hasSuffix(".started") }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".started") }.count == 2)
        #expect(service.progressByLecture.count == 2, "First: \(first.statusMessage ?? "none"); second: \(second.statusMessage ?? "none")")
        service.cancelTranscription(for: first)
        service.retranscribe(first, as: first.language)
        #expect(first.status == .recorded)
        for _ in 0..<200 where service.progressByLecture[first.persistentModelID] != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(first.status == .recorded)
        #expect(service.isQueuedOrRunning(lectureID: second.persistentModelID))
        try Data().write(to: directory.appendingPathComponent("release"))
        for _ in 0..<300 where service.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!service.isRunning)
        #expect(first.transcriptCompletedAt == nil)
        #expect(second.status == .ready)
        #expect(second.artifact(of: .rawTranscript)?.content.contains("Cleaned lecture.") == true)
        service.processPending()
        #expect(!service.isQueuedOrRunning(lectureID: first.persistentModelID))
    }

    private final class SilentNotifier: CompletionNotifying {
        func prepare(for category: CompletionNotificationCategory) {}
        func deliver(_ notification: CompletionNotification) {}
    }
}
