import Foundation
import XCTest

final class TranscriptionChunkConcurrencyTests: XCTestCase {
    private static let words = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet"]

    private struct Event: Decodable {
        let kind: String
        let run: String
        let index: Int
        let pid: Int
    }

    private actor Progress {
        var completed: [Int] = []
        func record(_ update: ProviderJobUpdate) async {
            guard let count = update.completedChunks else { return }
            // Exercise an asynchronous observer while other chunks complete.
            if count == 1 { try? await Task.sleep(for: .milliseconds(50)) }
            completed.append(count)
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let count: Int
        let jobID = UUID()

        init(count: Int) throws {
            self.count = count
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Lectern-Parallel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("source".utf8).write(to: root.appendingPathComponent("source.wav"))
            try Data("Transcribe all attached audio using native understanding.".utf8).write(to: root.appendingPathComponent("SKILL.md"))
            for index in 0..<count {
                try Data(String(index).utf8).write(to: root.appendingPathComponent("part-\(index).wav"))
            }
        }

        var store: TranscriptionChunkStore { .init(root: root.appendingPathComponent("cache")) }
        var request: ExternalTranscriptionRequest {
            .init(audioURL: root.appendingPathComponent("source.wav"), durationSeconds: Double(count * 10),
                  lectureLanguage: .english, connection: .builtInAntigravity(), attemptNumber: 1, checkpointID: jobID)
        }

        func client(run: String, pool: AISessionPool, failureIndex: Int = -2) -> AntigravityACPClient {
            let directory = root
            return .init(connectionFactory: {
                try await ACPConnection.connect(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-u", "-c", Self.script, directory.path, run, String(failureIndex)],
                    environment: ProcessInfo.processInfo.environment, transcriptionOnly: run != "generation")
            }, skillURLOverrides: [.transcription: root.appendingPathComponent("SKILL.md")],
               transcriptionTimeout: .seconds(15), sessionPool: pool)
        }

        func engine(run: String, pool: AISessionPool, failureIndex: Int = -2) -> ExternalTranscriptionEngine {
            .init(antigravity: client(run: run, pool: pool, failureIndex: failureIndex), chunkStore: store,
                  antigravityAudioPreparation: { _, _ in
                .init(chunks: (0..<count).map { index in
                    .init(url: root.appendingPathComponent("part-\(index).wav"), startSeconds: Double(index * 10),
                          durationSeconds: 10)
                }, temporaryDirectory: nil)
            })
        }

        func release(_ index: Int, run: String) throws {
            try Data().write(to: root.appendingPathComponent("\(run)-\(index).release"))
        }

        func releaseAll(run: String) throws {
            for index in 0..<count { try release(index, run: run) }
        }

        func events() -> [Event] {
            let data = (try? String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
            return data.split(separator: "\n").compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
        }

        func started(run: String) -> [Int] { events().filter { $0.kind == "start" && $0.run == run }.map(\.index) }

        func peakPrompts() -> Int {
            var active = Set<Int>()
            var peak = 0
            for event in events() {
                if event.kind == "start" { active.insert(event.pid) } else { active.remove(event.pid) }
                peak = max(peak, active.count)
            }
            return peak
        }

        func allStopped(run: String) -> Bool {
            // Closing stdin can end a completed fixture before SIGTERM arrives.
            // Check process exit itself, including forced termination of hung siblings.
            events().filter { $0.kind == "start" && $0.run == run }.allSatisfy {
                kill(Int32($0.pid), 0) == -1 && errno == ESRCH
            }
        }

        private static let script = #"""
import base64, json, os, signal, sys, time
from pathlib import Path
root, run, failure = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
index = -1
words = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet"]
def event(kind):
    fd = os.open(root / "events.jsonl", os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    os.write(fd, (json.dumps(dict(kind=kind, run=run, index=index, pid=os.getpid())) + "\n").encode())
    os.close(fd)
def stopped(*args):
    event("stop")
    sys.exit(0)
signal.signal(signal.SIGTERM, stopped)
for raw in sys.stdin:
    req = json.loads(raw)
    method, rid = req.get("method"), req.get("id")
    result = {}
    if method == "initialize":
        result = {"protocolVersion": 1}
    elif method == "session/new":
        model = "gemini-3.8-flash-high"
        result = {"sessionId": "fixture", "configOptions": [{"id":"model", "category":"model", "currentValue":model, "options":[{"value":model,"name":model}]}]}
    elif method == "session/prompt":
        audio = next((b for b in req["params"]["prompt"] if b.get("type") == "audio"), None)
        index = int(base64.b64decode(audio["data"])) if audio else -1
        event("start")
        deadline = time.monotonic() + 20
        while not (root / f"{run}-{index}.release").exists():
            if time.monotonic() > deadline: sys.exit(2)
            time.sleep(.01)
        if index == failure:
            print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"tool_call","toolCallId":"fixture-tool"}}}), flush=True)
            while True: time.sleep(1)
        text = "[00:01] " + words[index] + "." if audio else "Generation complete."
        event("finish")
        print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":text}}}}), flush=True)
        result = {"stopReason":"end_turn"}
    if rid is not None:
        print(json.dumps({"jsonrpc":"2.0","id":rid,"result":result}), flush=True)
"""#
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Concurrency fixture timed out", file: file, line: line)
        throw NSError(domain: "Concurrency fixture timed out at line \(line)", code: 1)
    }

    private func assertOrdered(_ result: TranscriptionResult, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.text, Self.words.prefix(count).map { $0 + "." }.joined(separator: "\n\n"), file: file, line: line)
        XCTAssertEqual(result.segments.map(\.startMilliseconds), (0..<count).map { Int64($0 * 10_000 + 1_000) }, file: file, line: line)
        XCTAssertEqual(result.segments.count, count, file: file, line: line)
    }

    func testTenPartsRunThreeAtATimeAndMergeInOrderDespiteReverseCompletion() async throws {
        let fixture = try Fixture(count: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let progress = Progress()
        let engine = fixture.engine(run: "parallel", pool: AISessionPool(limit: 3))
        let job = Task { try await engine.transcribe(fixture.request) { await progress.record($0) } }
        defer { job.cancel() }
        try await waitFor { fixture.started(run: "parallel").count == 3 }
        XCTAssertEqual(Set(fixture.started(run: "parallel")), [0, 1, 2])
        for (offset, index) in [2, 1, 0].enumerated() {
            try fixture.release(index, run: "parallel")
            try await waitFor { fixture.started(run: "parallel").count == 4 + offset }
        }
        try fixture.releaseAll(run: "parallel")
        let result = try await job.value
        assertOrdered(result, count: 10)
        XCTAssertEqual(fixture.peakPrompts(), 3)
        XCTAssertEqual(fixture.started(run: "parallel").sorted(), Array(0..<10))
        let counts = await progress.completed
        XCTAssertEqual(counts, Array(0...10))
        XCTAssertEqual(Array(fixture.events().filter { $0.kind == "finish" }.prefix(3).map(\.index)), [2, 1, 0])
    }

    func testLimitOnePreservesSequentialProcessing() async throws {
        let fixture = try Fixture(count: 4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.releaseAll(run: "serial")
        let result = try await fixture.engine(run: "serial", pool: AISessionPool(limit: 1)).transcribe(fixture.request) { _ in }
        assertOrdered(result, count: 4)
        XCTAssertEqual(fixture.peakPrompts(), 1)
        XCTAssertEqual(fixture.started(run: "serial"), [0, 1, 2, 3])
    }

    func testTwoLecturesAndGenerationShareOneGlobalLimit() async throws {
        let fixture = try Fixture(count: 4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pool = AISessionPool(limit: 3)
        let generation = Task { try await fixture.client(run: "generation", pool: pool).run(prompt: "Generate") }
        defer { generation.cancel() }
        try await waitFor { fixture.started(run: "generation").count == 1 }
        let first = Task { try await fixture.engine(run: "first", pool: pool).transcribe(fixture.request) { _ in } }
        var secondRequest = fixture.request
        secondRequest.checkpointID = UUID()
        let other = secondRequest
        let second = Task { try await fixture.engine(run: "second", pool: pool).transcribe(other) { _ in } }
        defer { first.cancel(); second.cancel() }
        try await waitFor { fixture.events().filter { $0.kind == "start" }.count == 3 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.events().filter { $0.kind == "start" }.count, 3)
        try fixture.releaseAll(run: "first")
        try fixture.releaseAll(run: "second")
        try fixture.release(-1, run: "generation")
        let generated = try await generation.value
        XCTAssertEqual(generated, "Generation complete.")
        assertOrdered(try await first.value, count: 4)
        assertOrdered(try await second.value, count: 4)
        XCTAssertEqual(fixture.peakPrompts(), 3)
    }

    func testFailurePreservesOutOfOrderCheckpointAndResumeSkipsIt() async throws {
        try await verifyInterruptedResume(cancel: false)
    }

    func testCancellationStopsSiblingsAndResumeSkipsAcceptedParts() async throws {
        try await verifyInterruptedResume(cancel: true)
    }

    private func verifyInterruptedResume(cancel: Bool) async throws {
        let fixture = try Fixture(count: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pool = AISessionPool(limit: 3)
        let progress = Progress()
        let engine = fixture.engine(run: "interrupted", pool: pool, failureIndex: cancel ? -2 : 0)
        let job = Task { try await engine.transcribe(fixture.request) { await progress.record($0) } }
        defer { job.cancel() }
        try await waitFor { fixture.started(run: "interrupted").count == 3 }
        try fixture.release(2, run: "interrupted")
        try await waitFor { fixture.started(run: "interrupted").count == 4 }
        if cancel { job.cancel() } else { try fixture.release(0, run: "interrupted") }
        do {
            _ = try await job.value
            XCTFail("Interrupted transcription returned a partial final result")
        } catch let error as ExternalTranscriptionError {
            XCTAssertEqual(error.code, cancel ? .cancelled : .offTask)
        }
        try await waitFor { fixture.allStopped(run: "interrupted") }
        XCTAssertEqual(Set(fixture.started(run: "interrupted")), [0, 1, 2, 3])
        let before = await progress.completed
        XCTAssertEqual(before, [0, 1])
        // A new client, engine, and store simulate reopening the app.
        try fixture.releaseAll(run: "resumed")
        let resumedProgress = Progress()
        let result = try await fixture.engine(run: "resumed", pool: pool).transcribe(fixture.request) {
            await resumedProgress.record($0)
        }
        assertOrdered(result, count: 5)
        XCTAssertEqual(fixture.started(run: "resumed").sorted(), [0, 1, 3, 4])
        let counts = await resumedProgress.completed
        XCTAssertEqual(counts, [1, 2, 3, 4, 5])
        XCTAssertEqual(fixture.peakPrompts(), 3)
    }
}
