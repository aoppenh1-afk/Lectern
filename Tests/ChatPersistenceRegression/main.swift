import Foundation
import SwiftData

@main
enum ChatPersistenceRegression {
    @MainActor
    static func main() throws {
        let attachmentFixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("lectern-attachment-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentFixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: attachmentFixtures) }

        let html = attachmentFixtures.appendingPathComponent("lesson.html")
        let archive = attachmentFixtures.appendingPathComponent("materials.zip")
        let markdown = attachmentFixtures.appendingPathComponent("outline.md")
        try Data("<h1>Lesson</h1>".utf8).write(to: html)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: archive)
        try Data("# Outline".utf8).write(to: markdown)

        guard try ChatAttachmentKind.classify(attachmentFixtures) == .folder,
              try ChatAttachmentKind.classify(html) == .text,
              try ChatAttachmentKind.classify(archive) == .file,
              try ChatAttachmentKind.classify(markdown) == .markdown else {
            fputs("FAIL: files and folders were not accepted by attachment classification\n", stderr)
            exit(1)
        }

        let notesPrompt = Prompts.notes(cleanedTranscript: "A cell contains organelles.")
        guard notesPrompt.contains("image-generation tool"),
              notesPrompt.contains("textbook-style labeled diagram or illustration"),
              notesPrompt.contains("absolute/local/path.png") else {
            fputs("FAIL: notes prompt does not direct capable agents to generate textbook visuals\n", stderr)
            exit(1)
        }

        let schema = Schema([
            Lecture.self,
            ChatMessage.self,
            Artifact.self,
            Course.self,
            Flashcard.self,
            QuizItem.self,
            Recording.self,
        ])
        let storePath = ProcessInfo.processInfo.environment["LECTERN_STORE_PATH"]
        let configuration = storePath.map {
            ModelConfiguration(url: URL(fileURLWithPath: $0))
        } ?? ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let lecture: Lecture
        if storePath != nil,
           let existing = try context.fetch(FetchDescriptor<Lecture>()).first {
            lecture = existing
        } else {
            lecture = Lecture(
                title: "Relationship regression",
                capturedAt: Date(),
                status: .ready
            )
            context.insert(lecture)
            try context.save()
        }

        // Refetch so the test exercises the same persisted relationship fault that a
        // completed asynchronous agent turn encounters.
        let lectureID = lecture.persistentModelID
        let lectureDescriptor = FetchDescriptor<Lecture>(
            predicate: #Predicate { $0.persistentModelID == lectureID }
        )
        guard let fetched = try context.fetch(lectureDescriptor).first else {
            fputs("FAIL: persisted lecture could not be refetched after the agent turn\n", stderr)
            exit(1)
        }
        let originalMessageCount = try context.fetch(FetchDescriptor<ChatMessage>()).count
        let request = ChatMessage(role: .user, content: "Generate an image for my notes")
        context.insert(request)
        request.lecture = fetched
        try context.save()

        let response = ChatMessage(role: .assistant, content: "Generated response")

        context.insert(response)
        response.lecture = fetched
        try context.save()

        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        guard messages.count == originalMessageCount + 2,
              request.lecture?.persistentModelID == lectureID,
              response.lecture?.persistentModelID == lectureID,
              fetched.chatMessages.contains(where: { $0.persistentModelID == request.persistentModelID }),
              fetched.chatMessages.contains(where: { $0.persistentModelID == response.persistentModelID }) else {
            fputs("FAIL: assistant message relationship was not persisted exactly once\n", stderr)
            exit(1)
        }

        print("PASS: chat persistence, broad attachments, and textbook visual instructions")
    }
}
