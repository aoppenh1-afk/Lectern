import Foundation
import SwiftData
import Testing

@MainActor
struct CourseChatWorkspaceTests {
    private func fixture() throws -> (ModelContainer, Course, URL) {
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let course = Course(name: "Drashos", colorHex: "#123456")
        container.mainContext.insert(course)
        try container.mainContext.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CourseChat-\(UUID())")
        return (container, course, root)
    }

    private func source(_ documents: [CourseChatDocument]) -> CourseChatSource {
        .init(title: "Drashos", labels: documents.map(\.label), documents: documents)
    }

    @Test func storesFullDocumentsWithoutPuttingTheirContentsInReferences() throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "Unique source text שלום.\n", count: 70_000)
        let document = CourseChatDocument(id: "doc", label: "../Drashos / notes", content: body)
        let workspace = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
                                                         source: source([document]), images: [])
        let entry = try #require(workspace.entries.first)
        #expect(!workspace.referencePrompt.contains("Unique source text"))
        #expect(workspace.referencePrompt.count < 500)
        #expect(!entry.path.contains(".."))
        #expect(try String(contentsOf: workspace.directory.appendingPathComponent(entry.path), encoding: .utf8) == body)
        let index = try String(contentsOf: workspace.directory.appendingPathComponent("sources.json"), encoding: .utf8)
        #expect(!index.contains("Unique source text"))
        #expect(index.contains("sha256"))
        let nativeText = try workspace.nativeBlocks().compactMap { block -> String? in
            guard case .resource(let text, _, _) = block else { return nil }
            #expect(text.utf8.count <= AntigravityACPContent.maximumTextBytes)
            return text
        }.joined()
        #expect(nativeText == body)
        withExtendedLifetime(container) {}
    }

    @Test func updatesEditsRemovesDeselectedFilesAndSeparatesSameNamedCourses() throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = CourseChatDocument(id: "a", label: "Same name", content: "First")
        let b = CourseChatDocument(id: "b", label: "Same name", content: "Second")
        let initial = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
                                                       source: source([a, b]), images: [])
        #expect(Set(initial.entries.map(\.path)).count == 2)
        let reversed = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
                                                        source: source([b, a]), images: [])
        #expect(initial.fingerprint == reversed.fingerprint)
        let edited = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
            source: source([.init(id: "a", label: "Same name", content: "Edited")]), images: [])
        #expect(edited.fingerprint != initial.fingerprint)
        #expect(edited.directory == initial.directory)
        let removed = try #require(initial.entries.first { $0.sha256 == CourseChatWorkspace.digest(Data(b.content.utf8)) })
        #expect(!FileManager.default.fileExists(atPath: edited.directory.appendingPathComponent(removed.path).path))
        let other = Course(name: course.name, colorHex: "#123456")
        container.mainContext.insert(other)
        try container.mainContext.save()
        let separate = try CourseChatWorkspace.prepare(root: root, courseID: other.persistentModelID,
                                                        source: source([b]), images: [])
        #expect(separate.directory != edited.directory)
        #expect(try String(contentsOf: edited.directory.appendingPathComponent(edited.entries[0].path), encoding: .utf8) == "Edited")
        let empty = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID, source: source([]), images: [])
        #expect(empty.entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.directory.appendingPathComponent("sources").path).isEmpty)
    }

    @Test func sourcePickerExcludesUnselectedCourseMaterial() throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = ReferenceAttachment(name: "Selected", filePath: "", kind: .text, extractedText: "Chosen")
        let excluded = ReferenceAttachment(name: "Excluded", filePath: "", kind: .text, extractedText: "Private")
        for item in [selected, excluded] {
            container.mainContext.insert(item)
            item.course = course
        }
        course.attachments = [selected, excluded]
        try container.mainContext.save()
        let selectedSource = try #require(CourseChatSource.make(course: course, lectures: [], attachments: [selected]))
        #expect(selectedSource.documents.map(\.content) == ["Chosen"])
        #expect(CourseChatSource.make(course: course, lectures: [], attachments: []) == nil)
    }

    @Test func reusesSessionWithoutResendingDocumentsOrHistoryAndRefreshesOnEdits() async throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
            source: source([.init(id: "doc", label: "Notes", content: "DOCUMENT_SENTINEL")]), images: [])
        let log = root.appendingPathComponent("requests.jsonl")
        let session = CourseChatSession(connect: Self.factory(log: log))
        defer { session.close() }
        let profile = AgentProfile(id: "fake", title: "Fake", command: "fake")
        let first = try await session.answer(question: "Explain", workspace: workspace, history: "HISTORY_SENTINEL",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        #expect(first.contains("DOCUMENT_SENTINEL")) // Fake agent reads the referenced file from cwd.
        _ = try await session.answer(question: "Follow up", workspace: workspace, history: "HISTORY_SENTINEL",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        var requests = try Self.requests(log)
        #expect(requests.filter { $0["method"] as? String == "session/new" }.count == 1)
        var prompts = Self.prompts(requests)
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("HISTORY_SENTINEL"))
        #expect(!prompts[1].contains("HISTORY_SENTINEL"))
        #expect(prompts.allSatisfy { !$0.contains("DOCUMENT_SENTINEL") })
        let edited = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
            source: source([.init(id: "doc", label: "Notes", content: "UPDATED_DOCUMENT")]), images: [])
        let result = try await session.answer(question: "Explain again", workspace: edited, history: "Restored history",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        #expect(result.contains("UPDATED_DOCUMENT"))
        requests = try Self.requests(log)
        #expect(requests.filter { $0["method"] as? String == "session/new" }.count == 2)
        prompts = Self.prompts(requests)
        #expect(prompts[2].contains("Restored history"))
        withExtendedLifetime(container) {}
    }

    @Test func antigravityReceivesNativeSourcesAndImagesOncePerSession() async throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
            source: source([.init(id: "doc", label: "Notes", content: "NATIVE_DOCUMENT")]),
            images: [.init(data: Data("image".utf8), mimeType: "image/png")])
        let log = root.appendingPathComponent("requests.jsonl")
        let session = CourseChatSession(connect: Self.factory(log: log))
        defer { session.close() }
        let profile = AgentProfile(id: AgentProfiles.antigravityID, title: "Fake native", command: "fake", model: "test-model")
        for question in ["First", "Second"] {
            _ = try await session.answer(question: question, workspace: workspace, history: "",
                studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: "test-model")
        }
        let requests = try Self.requests(log)
        #expect(requests.filter { $0["method"] as? String == "authenticate" }.count == 1)
        #expect(requests.filter { $0["method"] as? String == "session/new" }.count == 1)
        let prompts = Self.prompts(requests)
        #expect(prompts[0].contains("NATIVE_DOCUMENT"))
        #expect(prompts[0].contains("image/png"))
        #expect(!prompts[1].contains("NATIVE_DOCUMENT"))
        #expect(!prompts[1].contains("image/png"))
        withExtendedLifetime(container) {}
    }

    @Test func failuresAndExplicitCloseRebootstrapInsteadOfReusingBrokenSession() async throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
            source: source([.init(id: "doc", label: "Notes", content: "Source")]), images: [])
        let log = root.appendingPathComponent("requests.jsonl")
        let session = CourseChatSession(connect: Self.factory(log: log))
        defer { session.close() }
        let profile = AgentProfile(id: "fake", title: "Fake", command: "fake")
        do {
            _ = try await session.answer(question: "FAIL_REQUEST", workspace: workspace, history: "",
                studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
            Issue.record("Expected an agent failure")
        } catch {}
        _ = try await session.answer(question: "Retry", workspace: workspace, history: "History after failure",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        session.close()
        _ = try await session.answer(question: "Restart", workspace: workspace, history: "History after close",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        let requests = try Self.requests(log)
        #expect(requests.filter { $0["method"] as? String == "session/new" }.count == 3)
        #expect(Self.prompts(requests)[1].contains("History after failure"))
        #expect(Self.prompts(requests)[2].contains("History after close"))
        withExtendedLifetime(container) {}
    }

    @Test func courseAndModelChangesStartNewSessions() async throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = source([.init(id: "doc", label: "Notes", content: "Source")])
        let first = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID, source: docs, images: [])
        let other = Course(name: "Biology", colorHex: "#123456")
        container.mainContext.insert(other)
        try container.mainContext.save()
        let second = try CourseChatWorkspace.prepare(root: root, courseID: other.persistentModelID, source: docs, images: [])
        let log = root.appendingPathComponent("requests.jsonl")
        let session = CourseChatSession(connect: Self.factory(log: log))
        defer { session.close() }
        let profile = AgentProfile(id: "fake", title: "Fake", command: "fake")
        for (workspace, model) in [(first, "model-a"), (first, "model-b"), (second, "model-b")] {
            _ = try await session.answer(question: "Explain", workspace: workspace, history: "",
                studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: model)
        }
        let requests = try Self.requests(log)
        let sessions = requests.filter { $0["method"] as? String == "session/new" }
        #expect(sessions.count == 3)
        #expect((sessions[0]["params"] as? [String: Any])?["cwd"] as? String == first.directory.path)
        #expect((sessions[2]["params"] as? [String: Any])?["cwd"] as? String == second.directory.path)
        let selectedModels = requests.filter { $0["method"] as? String == "session/set_config_option" }
            .compactMap { ($0["params"] as? [String: Any])?["value"] as? String }
        #expect(selectedModels == ["model-a", "model-b", "model-b"])
    }

    @Test func cancellationDuringConnectionDoesNotReplaceTheNextSession() async throws {
        let (container, course, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try CourseChatWorkspace.prepare(root: root, courseID: course.persistentModelID,
            source: source([.init(id: "doc", label: "Notes", content: "Source")]), images: [])
        let log = root.appendingPathComponent("requests.jsonl")
        let factory = Self.factory(log: log)
        let session = CourseChatSession(connect: { profile in
            // Simulate a connection factory that finishes even after cancellation.
            if profile.id == "slow" { try? await Task.sleep(for: .milliseconds(150)) }
            return try await factory(profile)
        })
        defer { session.close() }
        var started = false
        let slow = Task {
            started = true
            return try await session.answer(question: "Cancelled question", workspace: workspace, history: "",
                studyInstruction: nil, profile: .init(id: "slow", title: "Slow", command: "fake"),
                thinkingLevel: .medium, modelOverride: nil)
        }
        while !started { await Task.yield() }
        session.close()
        slow.cancel()
        let profile = AgentProfile(id: "fake", title: "Fake", command: "fake")
        _ = try await session.answer(question: "New question", workspace: workspace, history: "",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        do {
            _ = try await slow.value
            Issue.record("Cancelled work should not return a response")
        } catch {}
        _ = try await session.answer(question: "Follow up", workspace: workspace, history: "",
            studyInstruction: nil, profile: profile, thinkingLevel: .medium, modelOverride: nil)
        let requests = try Self.requests(log)
        #expect(requests.filter { $0["method"] as? String == "session/new" }.count == 1)
        #expect(Self.prompts(requests).count == 2)
        #expect(Self.prompts(requests).allSatisfy { !$0.contains("Cancelled question") })
        withExtendedLifetime(container) {}
    }

    private static func requests(_ log: URL) throws -> [[String: Any]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private static func prompts(_ requests: [[String: Any]]) -> [String] {
        requests.filter { $0["method"] as? String == "session/prompt" }.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0["params"]!, options: [.withoutEscapingSlashes]), encoding: .utf8)!
        }
    }

    private static func factory(log: URL) -> CourseChatSession.ConnectionFactory {
        { _ in
            var environment = ProcessInfo.processInfo.environment
            environment["LECTERN_TEST_LOG"] = log.path
            return try await ACPConnection.connect(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-u", "-c", fakeAgent], environment: environment)
        }
    }

    private static let fakeAgent = #"""
import json, os, sys
cwd = None
for line in sys.stdin:
    req = json.loads(line)
    with open(os.environ['LECTERN_TEST_LOG'], 'a') as log:
        log.write(json.dumps(req) + '\n')
    method = req.get('method')
    if 'id' not in req:
        continue
    result = {}
    if method == 'initialize':
        result = {'protocolVersion': 1, 'agentCapabilities': {}, 'authMethods': []}
    elif method == 'session/new':
        cwd = req['params']['cwd']
        result = {'sessionId': 'fixture', 'configOptions': [{'id': 'model', 'name': 'Model', 'category': 'model', 'type': 'select', 'currentValue': 'test-model', 'options': [{'value': value, 'name': value} for value in ['test-model', 'model-a', 'model-b']]}]}
    elif method == 'session/prompt':
        if 'FAIL_REQUEST' in json.dumps(req['params']['prompt']):
            print(json.dumps({'jsonrpc': '2.0', 'id': req['id'], 'error': {'code': -32000, 'message': 'Fixture failure'}}), flush=True)
            continue
        with open(os.path.join(cwd, 'sources.json')) as index:
            entries = json.load(index)['sources']
        answer = 'Read: '
        for entry in entries:
            with open(os.path.join(cwd, entry['path'])) as source:
                answer += source.read()
        print(json.dumps({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': 'fixture', 'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': answer}}}}), flush=True)
        result = {'stopReason': 'end_turn'}
    print(json.dumps({'jsonrpc': '2.0', 'id': req['id'], 'result': result}), flush=True)
"""#
}
