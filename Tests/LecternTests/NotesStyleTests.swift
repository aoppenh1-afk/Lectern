import Foundation
import SwiftData
import Testing
import AppKit
import SwiftUI

@MainActor
struct NotesStyleTests {
    private let sample = NotesStyleSample(name: "My notes", text: "# Earlier subject\n\n## Key Takeaways\n\nExplain the idea in short connected paragraphs.\n\nKeep Q: and A: labels.")
    private var draft: NotesStyleDraft {
        NotesStyleDraft(name: "Connected paragraphs", summary: "Short explanations with question labels.",
                        instructions: "Use connected paragraphs and a Key Takeaways section. Keep Q: and A: labels.",
                        examples: ["Explain the idea in short connected paragraphs."])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lectern-style-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func savedStyleSurvivesRestartAndExplicitDefaultWins() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let revision = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: "model")
        let restored = NotesStyleStore(directory: directory)
        #expect(restored.preferredSelection == .personal)
        #expect(restored.current == revision)
        #expect(restored.resolve().snapshot.personal == revision)
        #expect(restored.resolve(.lecternDefault).snapshot.personal == nil)
        #expect(restored.resolve(.lecternDefault).warning == nil)
        try restored.select(.lecternDefault)
        let again = NotesStyleStore(directory: directory)
        #expect(!again.resolve().snapshot.isPersonal)
        #expect(again.resolve(.personal).snapshot.personal == revision)
        #expect(again.samples == [sample])
    }

    @Test func revisionsAreRestorableAndJobSnapshotDoesNotChange() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let first = try store.save(draft: draft, samples: [sample], creatorAgent: "Agent A", creatorModel: nil)
        let snapshot = store.resolve().snapshot
        var changed = draft
        changed.instructions = "Use numbered lists with child details."
        let second = try store.save(draft: changed, samples: [sample], creatorAgent: "Agent B", creatorModel: nil)
        #expect(store.current?.id == second.id)
        #expect(snapshot.personal?.id == first.id)
        #expect(snapshot.instructions.contains(first.draft.instructions))
        try store.restore(first.id)
        #expect(NotesStyleStore(directory: directory).current?.id == first.id)
        #expect(store.revisions.count == 2)
    }

    @Test func failedRevisionPreservesUsableStyleAndPreference() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let first = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        var invalid = draft
        invalid.examples = ["This was never in the user's notes."]
        #expect(throws: NotesStyleError.self) {
            try store.save(draft: invalid, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        }
        #expect(store.current?.id == first.id)
        #expect(NotesStyleStore(directory: directory).current?.id == first.id)
        #expect(store.preferredSelection == .personal)
    }

    @Test func savingWithoutSwitchingPreservesActivePersonalRevision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let first = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        var changed = draft
        changed.instructions = "Use numbered lists."
        let second = try store.save(draft: changed, samples: [sample], creatorAgent: "Creator", creatorModel: nil, activate: false)
        #expect(store.resolve().snapshot.personal?.id == first.id)
        #expect(store.revisions.contains { $0.id == second.id })
        #expect(NotesStyleStore(directory: directory).resolve().snapshot.personal?.id == first.id)
        try store.restore(second.id)
        #expect(store.resolve().snapshot.personal?.id == second.id)
    }

    @Test func failedFileCommitLeavesPreviousRevisionActive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let first = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        let index = directory.appendingPathComponent("library.json")
        try FileManager.default.moveItem(at: index, to: directory.appendingPathComponent("old-library.json"))
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        }
        #expect(store.current?.id == first.id)
        #expect(store.resolve().snapshot.personal?.id == first.id)
        let folders = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Revisions").path)
        #expect(folders == [first.id.uuidString])
    }

    @Test func missingOrChangedSkillFallsBackWithReason() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let style = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        try "Different file".write(to: store.skillURL(for: style.id), atomically: true, encoding: .utf8)
        #expect(!store.resolve().snapshot.isPersonal)
        #expect(store.resolve().warning != nil)
        #expect(store.resolve(.lecternDefault).warning == nil)
        try FileManager.default.removeItem(at: store.skillURL(for: style.id))
        #expect(!NotesStyleStore(directory: directory).resolve().snapshot.isPersonal)
    }

    @Test func corruptLibraryIsRecoverableWithoutUsingItsContents() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("broken JSON".utf8).write(to: directory.appendingPathComponent("library.json"))
        let store = NotesStyleStore(directory: directory)
        #expect(store.loadError != nil)
        #expect(!store.resolve().snapshot.isPersonal)
        #expect(store.resolve().warning != nil)
        try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        #expect(store.loadError == nil)
        #expect(NotesStyleStore(directory: directory).resolve().snapshot.isPersonal)
    }

    @Test func removalDeletesSamplesAndSkillFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        let style = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        try store.removePersonalStyle()
        #expect(!FileManager.default.fileExists(atPath: store.skillURL(for: style.id).path))
        let reloaded = NotesStyleStore(directory: directory)
        #expect(reloaded.samples.isEmpty)
        #expect(reloaded.current == nil)
        #expect(reloaded.preferredSelection == .lecternDefault)
    }

    @Test func settingsPaneRendersTheSavedStyle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotesStyleStore(directory: directory)
        try store.save(draft: draft, samples: [sample], creatorAgent: "Fixture agent", creatorModel: "Fixture model")
        let hosting = NSHostingView(rootView: VStack(alignment: .leading) {
            Text("Notes").font(.system(size: 28, weight: .bold, design: .serif))
            NotesStyleSettingsPane(store: store)
        }.padding(32).frame(width: 760).background(LecternTheme.paper))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 1_550),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 1_550)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000)
        let output = ProcessInfo.processInfo.environment["LECTERN_STYLE_UI_OUTPUT"] ?? "/tmp/lectern-custom-style-ui.png"
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        window.close()
    }

    @Test func personalValidationAcceptsParagraphsAndDefaultStillRequiresOutline() {
        let notes = "# Catalysts\n\n## Key Takeaways\n\nCatalysts lower activation energy."
        #expect(NotesOutputValidator.violations(in: notes, source: "short", language: .english, personalStyle: true).isEmpty)
        #expect(!NotesOutputValidator.violations(in: notes, source: "short", language: .english).isEmpty)
        #expect(!NotesOutputValidator.violations(in: "# Catalysts", source: "short", language: .english, personalStyle: true).isEmpty)
        #expect(!NotesOutputValidator.violations(in: "# Catalysts\n\n| A | B |", source: "short", language: .english, personalStyle: true).isEmpty)
        #expect(!NotesOutputValidator.violations(in: "# Catalysts\n\n\u{202E}Text", source: "short", language: .english, personalStyle: true).isEmpty)
    }

    @Test func skillContainsOnlySelectedExcerptsAndCoreKeepsContentGrounded() throws {
        let personal = try PersonalNotesStyle(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        let snapshot = NotesStyleSnapshot(personal: personal)
        #expect(snapshot.instructions.contains("The lecture is the authority"))
        #expect(snapshot.instructions.contains(draft.instructions))
        #expect(snapshot.instructions.contains(draft.examples[0]))
        #expect(!snapshot.instructions.contains("# Earlier subject"))
        #expect(!snapshot.instructions.contains("Concept, science, or terminology lecture"))
        let repair = Prompts.notesRepair(violations: ["Missing title"], style: snapshot)
        #expect(repair.contains(draft.instructions))
        #expect(repair.contains("Missing title"))
    }

    @Test func sampleImportIsSeparateFromCourseReferencesAndRejectsUnreadablePDF() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        try sample.text.write(to: file, atomically: true, encoding: .utf8)
        let imported = try ReferenceMaterialService.readStyleSamples([file])
        #expect(imported.first?.text == sample.text)
        #expect(imported.first?.name == "notes.md")
        let unreadable = directory.appendingPathComponent("scan.pdf")
        try Data().write(to: unreadable)
        #expect(throws: (any Error).self) { try ReferenceMaterialService.readStyleSamples([unreadable]) }
        #expect(throws: NotesStyleError.self) {
            try NotesStyleDraft.validatedSamples([NotesStyleSample(name: "Long", text: String(repeating: "x", count: 60_001))])
        }
    }

    @Test func learnerPerformsOneRepairAndRetainsSamplesAndAdjustments() async throws {
        let responses = ResponseQueue([ "invalid", String(decoding: try JSONEncoder().encode(draft), as: UTF8.self) ])
        let learned = try await NotesStyleLearningService.learn(samples: [sample], adjustments: "Preserve my Q: label",
            profile: AgentProfile(id: "fixture", title: "Fixture", command: "unused"),
            request: { prompt, _, _, _ in await responses.next(prompt) })
        #expect(learned == draft)
        let prompts = await responses.prompts
        #expect(prompts.count == 2)
        #expect(prompts.allSatisfy { $0.contains("Preserve my Q: label") && $0.contains("Earlier subject") })
        #expect(prompts.last?.contains("failed validation") == true)
    }

    @Test func creationAndPreviewRunThroughAnExistingACPProfile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try fixtureScript(in: directory)
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("draft.json"))
        let profile = AgentProfile(id: "fixture", title: "Existing ACP", command: "/usr/bin/python3 -u \(script.path)")
        let learned = try await NotesStyleLearningService.learn(samples: [sample], adjustments: "", profile: profile)
        #expect(learned == draft)
        let preview = try await NotesStyleLearningService.preview(draft: learned, samples: [sample], profile: profile)
        #expect(preview.contains("Key Takeaways"))
        #expect(!preview.contains("Earlier subject"))
    }

    @Test func generationCapturesStyleBeforeTaskAndExplicitDefaultUsesDefaultContract() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try fixtureScript(in: directory)
        let store = NotesStyleStore(directory: directory.appendingPathComponent("styles"))
        let revision = try store.save(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = Lecture(title: "Personal", capturedAt: Date(), status: .ready)
        let second = Lecture(title: "Default", capturedAt: Date(), status: .ready)
        for lecture in [first, second] {
            lecture.artifacts.append(Artifact(kind: .rawTranscript, content: "Catalysts lower activation energy.", modelInfo: "Fixture"))
            container.mainContext.insert(lecture)
        }
        try container.mainContext.save()
        let service = GenerationService(modelContainer: container, completionNotifier: SilentNotifier(), notesStyles: store)
        let profile = AgentProfile(id: "fixture", title: "Generation ACP", command: "/usr/bin/python3 -u \(script.path)")
        // Automatic and manual generation share this entry point and default selection.
        service.generate(lecture: first, kinds: [.notes], profile: profile)
        try store.select(.lecternDefault)
        for _ in 0..<500 where service.job(for: first.persistentModelID) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.job(for: first.persistentModelID) == nil)
        #expect(service.errors.isEmpty)
        #expect(first.artifact(of: .notes)?.content.contains("Key Takeaways") == true)
        #expect(first.artifact(of: .notes)?.modelInfo.contains(revision.id.uuidString) == true)
        try store.select(.personal)
        try await service.generateDirectly(lecture: second, kinds: [.notes], profile: profile, notesStyle: .lecternDefault)
        #expect(second.artifact(of: .notes)?.content.contains("- Catalysts") == true)
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        #expect(requests.count == 4)
        #expect(requests[0].contains("personal-notes-style"))
        #expect(requests[1].contains("personal-notes-style"))
        #expect(!requests[2].contains("personal-notes-style"))
        #expect(!requests[3].contains("personal-notes-style"))
    }

    @Test func antigravityCarriesSelectedInstructionsIntoBothRequests() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try fixtureScript(in: directory)
        let personal = try PersonalNotesStyle(draft: draft, samples: [sample], creatorAgent: "Creator", creatorModel: nil)
        let snapshot = NotesStyleSnapshot(personal: personal)
        let client = AntigravityACPClient(connectionFactory: {
            try await ACPConnection.connect(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                            arguments: ["-u", script.path], environment: ProcessInfo.processInfo.environment)
        })
        for prompt in [Prompts.antigravityNotesRequest(language: .english),
                       Prompts.antigravityNotesRepair(violations: ["Missing title"], language: .english)] {
            _ = try await client.run(prompt: prompt, modelID: "gemini-3.8-flash-high",
                                     inputs: [.text("Catalysts lower activation energy.", named: "lecture-source.md")],
                                     skills: [.notes], skillInstructions: [.notes: snapshot.instructions])
        }
        let requests = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.contains("personal-notes-style") && $0.contains("Connected paragraphs") })
        #expect(requests.allSatisfy { !$0.contains("Concept, science, or terminology lecture") })
    }

    private func fixtureScript(in directory: URL) throws -> URL {
        let script = directory.appendingPathComponent("agent.py")
        try #"""
import json, sys
from pathlib import Path
root = Path(__file__).parent
count = 0
for raw in sys.stdin:
    req = json.loads(raw)
    if "id" not in req: continue
    method = req.get("method")
    result = {}
    if method == "initialize":
        result = {"protocolVersion":1, "agentCapabilities":{}, "authMethods":[]}
    elif method == "session/new":
        result = {"sessionId":"fixture", "configOptions":[{"id":"model", "category":"model",
                  "currentValue":"gemini-3.8-flash-high",
                  "options":[{"value":"gemini-3.8-flash-high", "name":"Fixture"}]}]}
    elif method == "session/prompt":
        text = "\n".join(b.get("text", "") for b in req["params"]["prompt"] if b.get("type") == "text")
        with (root / "requests.jsonl").open("a") as log: log.write(json.dumps(text) + "\n")
        count += 1
        if "style-samples-json" in text:
            output = (root / "draft.json").read_text()
        elif count == 1 and "Repair the previous notes" not in text:
            output = "Draft missing the title."
        elif "personal-notes-style" in text:
            output = "# Catalysts\n\n## Key Takeaways\n\nCatalysts lower activation energy."
        else:
            output = "# Catalysts\n\n## Action\n\n- Catalysts lower activation energy"
        print(json.dumps({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":output}}}}), flush=True)
        result = {"stopReason":"end_turn"}
    print(json.dumps({"jsonrpc":"2.0","id":req["id"],"result":result}), flush=True)
"""#.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private actor ResponseQueue {
        var outputs: [String]
        private(set) var prompts: [String] = []
        init(_ outputs: [String]) { self.outputs = outputs }
        func next(_ prompt: String) -> String {
            prompts.append(prompt)
            return outputs.removeFirst()
        }
    }

    private final class SilentNotifier: CompletionNotifying {
        func prepare(for category: CompletionNotificationCategory) {}
        func deliver(_ notification: CompletionNotification) {}
    }
}
