import Foundation
import SwiftData
import Testing

@MainActor
struct GenerationConcurrencyTests {
    @Test func twoLecturesGenerateConcurrentlyAndCancelIndependently() async throws {
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
        result = {"sessionId": str(os.getpid())}
    elif method == "session/prompt":
        (root / (str(os.getpid()) + ".started")).write_text("started")
        while not (root / "release").exists(): time.sleep(0.01)
        print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":str(os.getpid()),"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Cleaned lecture."}}}}), flush=True)
        result = {"stopReason":"end_turn"}
    print(json.dumps({"jsonrpc":"2.0", "id":req["id"], "result":result}), flush=True)
"""#.write(to: script, atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = Lecture(title: "First", capturedAt: Date(), status: .ready)
        let second = Lecture(title: "Second", capturedAt: Date(), status: .ready)
        for lecture in [first, second] {
            lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "Recorded lecture", modelInfo: "Test"))
            container.mainContext.insert(lecture)
        }
        try container.mainContext.save()
        let service = GenerationService(modelContainer: container, completionNotifier: SilentNotifier())
        defer { service.cancel() }
        let profile = AgentProfile(id: "test", title: "Mock ACP", command: "/usr/bin/python3 -u \(script.path)")
        service.generate(lecture: first, kinds: [.cleanedTranscript], profile: profile)
        let direct = Task { try await service.generateDirectly(lecture: second, kinds: [.cleanedTranscript], profile: profile) }
        for _ in 0..<500 {
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if files.filter({ $0.hasSuffix(".started") }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".started") }.count == 2)
        #expect(service.activeJobs.count == 2)
        service.cancel(lectureID: first.persistentModelID)
        for _ in 0..<200 where service.job(for: first.persistentModelID) != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(service.job(for: first.persistentModelID) == nil)
        #expect(service.job(for: second.persistentModelID) != nil)
        try Data().write(to: directory.appendingPathComponent("release"))
        try await direct.value
        #expect(first.artifact(of: .cleanedTranscript) == nil)
        #expect(second.artifact(of: .cleanedTranscript)?.content == "Cleaned lecture.")
        #expect(service.activeJobs.isEmpty)
        #expect(service.errors.isEmpty)
    }

    private final class SilentNotifier: CompletionNotifying {
        func prepare(for category: CompletionNotificationCategory) {}
        func deliver(_ notification: CompletionNotification) {}
    }
}
