import Foundation
import SwiftData
import Testing
import SwiftUI
import AppKit

@MainActor
struct ChatStudyMaterialTests {
    private func fixture(_ material: ChatStudyMaterial) throws -> (ModelContainer, Course, CourseSynthesisService, UUID) {
        let container = try ModelContainer(for: Course.self, Lecture.self, ShiurSubscription.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let course = Course(name: "Biology", colorHex: "#123456", language: .hebrewEnglish)
        container.mainContext.insert(course)
        let turn = CourseSynthesisService.Turn(question: "Create material", answer: material.preview, material: material)
        course.studyChatHistory = try JSONEncoder().encode([turn])
        try container.mainContext.save()
        let service = CourseSynthesisService()
        service.activate(course)
        return (container, course, service, turn.id)
    }

    @Test func parsesFencedQuizAndRejectsUnusableAnswer() throws {
        let valid = """
        ```json
        {"title":"Review","questions":[{"prompt":"Which?","options":["A","B"],"answer":"A","explanation":"Source says A."}]}
        ```
        """
        let parsed = try ChatStudyMaterial.parse(valid, request: .init(kind: .quiz), sourceLabels: ["Lecture 1"], modelInfo: "Test")
        #expect(parsed.questions.count == 1)
        #expect(parsed.sourceLabels == ["Lecture 1"])
        #expect(throws: (any Error).self) {
            try ChatStudyMaterial.parse(valid.replacingOccurrences(of: "\"answer\":\"A\"", with: "\"answer\":\"C\""),
                                        request: .init(kind: .quiz), sourceLabels: [], modelInfo: "Test")
        }
        #expect(throws: (any Error).self) {
            try ChatStudyMaterial.parse("{\"title\":\"Empty\",\"cards\":[]}", request: .init(kind: .flashcards), sourceLabels: [], modelInfo: "Test")
        }
    }

    @Test func createsNativeQuizLectureAndPersistsSaveReceipt() throws {
        let material = ChatStudyMaterial(kind: .quiz, title: "Practice", markdown: "", questions: [
            .init(prompt: "Why?", options: nil, answer: "Because", explanation: "Explanation"),
            .init(prompt: "Which?", options: ["A", "B"], answer: "A", explanation: "Explanation")
        ], modelInfo: "Test")
        let (container, course, service, turnID) = try fixture(material)
        let lecture = try service.saveMaterial(material, turnID: turnID, course: course, lectureID: nil, newLectureTitle: "Exam review")
        #expect(lecture.course == course)
        #expect(lecture.status == .ready)
        #expect(lecture.recording == nil)
        #expect(lecture.language == .hebrewEnglish)
        #expect(lecture.quizItems.count == 2)
        #expect(lecture.quizSets.count == 1)
        #expect(Set(lecture.quizItems.map(\.kind)) == [.shortAnswer, .multipleChoice])
        #expect(try container.mainContext.fetch(FetchDescriptor<Lecture>()).count == 1)
        let reloaded = CourseSynthesisService()
        reloaded.activate(course)
        #expect(reloaded.turns.first?.material?.savedLectureTitle == "Exam review")
        #expect(throws: (any Error).self) {
            try reloaded.saveMaterial(material, turnID: turnID, course: course, lectureID: nil, newLectureTitle: "Duplicate")
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<Lecture>()).count == 1)
    }

    @Test func appendsStudyGuideToLatestNotes() throws {
        let material = ChatStudyMaterial(kind: .studyGuide, title: "Review", markdown: "New guide", modelInfo: "Test")
        let (container, course, service, turnID) = try fixture(material)
        let lecture = Lecture(title: "Existing", capturedAt: Date(), status: .ready)
        container.mainContext.insert(lecture)
        lecture.course = course
        let notes = Artifact(kind: .notes, content: "Student's edited notes", modelInfo: "Original")
        container.mainContext.insert(notes)
        notes.lecture = lecture
        lecture.artifacts.append(notes)
        try container.mainContext.save()
        try service.saveMaterial(material, turnID: turnID, course: course, lectureID: lecture.persistentModelID, newLectureTitle: "")
        #expect(notes.content.hasPrefix("Student's edited notes"))
        #expect(notes.content.contains("New guide"))
        #expect(lecture.artifacts.count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<Lecture>()).count == 1)
    }

    @Test func cardsAppendWithoutDuplicatesAndKeepSyncState() throws {
        let material = ChatStudyMaterial(kind: .flashcards, title: "Cards", markdown: "", cards: [
            .init(front: "Old", back: "Answer"), .init(front: "New", back: "New answer"),
            .init(front: "New", back: "New answer")
        ], modelInfo: "Test")
        let (container, course, service, turnID) = try fixture(material)
        let lecture = Lecture(title: "Existing", capturedAt: Date(), status: .ready)
        container.mainContext.insert(lecture)
        lecture.course = course
        let old = Flashcard(front: "Old", back: "Answer", syncState: .pushed)
        container.mainContext.insert(old)
        old.lecture = lecture
        lecture.flashcards.append(old)
        try container.mainContext.save()
        try service.saveMaterial(material, turnID: turnID, course: course, lectureID: lecture.persistentModelID, newLectureTitle: "")
        #expect(lecture.flashcards.count == 2)
        #expect(old.syncState == .pushed)
        #expect(lecture.flashcards.first(where: { $0.front == "New" })?.syncState == .pending)
    }

    @Test func rejectsWrongCourseAndInvalidDraftWithoutCreatingLecture() throws {
        var material = ChatStudyMaterial(kind: .notes, title: "Notes", markdown: "Text", modelInfo: "Test")
        let (container, course, service, turnID) = try fixture(material)
        let other = Course(name: "Other", colorHex: "#000000")
        let lecture = Lecture(title: "Other course", capturedAt: Date(), status: .ready)
        container.mainContext.insert(other)
        container.mainContext.insert(lecture)
        lecture.course = other
        try container.mainContext.save()
        #expect(throws: (any Error).self) {
            try service.saveMaterial(material, turnID: turnID, course: course, lectureID: lecture.persistentModelID, newLectureTitle: "")
        }
        material.markdown = " "
        #expect(throws: (any Error).self) {
            try service.saveMaterial(material, turnID: turnID, course: course, lectureID: nil, newLectureTitle: "Invalid")
        }
        #expect(course.lectures.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<Lecture>()).count == 1)
    }

    @Test func switchingCoursesRestoresTheirOwnDraftsAndClearKeepsMaterials() throws {
        let material = ChatStudyMaterial(kind: .notes, title: "Notes", markdown: "Text", modelInfo: "Test")
        let (container, course, service, turnID) = try fixture(material)
        let lecture = try service.saveMaterial(material, turnID: turnID, course: course, lectureID: nil, newLectureTitle: "Saved")
        let other = Course(name: "Other", colorHex: "#000000")
        container.mainContext.insert(other)
        try container.mainContext.save()
        service.activate(other)
        #expect(service.turns.isEmpty)
        service.activate(course)
        #expect(service.turns.count == 1)
        service.clear()
        let reloaded = CourseSynthesisService()
        reloaded.activate(course)
        #expect(reloaded.turns.isEmpty)
        #expect(lecture.artifact(of: .notes)?.content.contains("Text") == true)
    }
    @Test func generatedOnlyLecturesRemainAvailableAsChatSources() throws {
        let material = ChatStudyMaterial(kind: .flashcards, title: "Cards", markdown: "", cards: [
            .init(front: "What is mitosis?", back: "Cell division")
        ], modelInfo: "Test")
        let (container, course, service, turnID) = try fixture(material)
        let lecture = try service.saveMaterial(material, turnID: turnID, course: course, lectureID: nil, newLectureTitle: "Cards only")
        #expect(LectureChatSource.make(for: lecture)?.content.contains("Cell division") == true)
        #expect(CourseChatSource.make(course: course, lectures: [lecture])?.chunks.joined().contains("Cell division") == true)
        let freshContext = ModelContext(container)
        let fetchedCourse = try #require(freshContext.fetch(FetchDescriptor<Course>()).first)
        let history = try JSONDecoder().decode([CourseSynthesisService.Turn].self, from: #require(fetchedCourse.studyChatHistory))
        #expect(history.first?.material?.savedLectureTitle == "Cards only")
    }

    @Test func sourceFreeGenerationIsExplicitInPrompt() {
        let request = ChatStudyRequest(kind: .studyGuide, usesTopicOnly: true)
        #expect(request.instruction.contains("No course sources were selected"))
        #expect(request.instruction.contains("not a summary of the course"))
    }

    @Test func reviewSheetRenders() throws {
        let material = ChatStudyMaterial(kind: .quiz, title: "Cell biology review", markdown: "", questions: [
            .init(prompt: "Which organelle produces most cellular ATP?", options: ["Mitochondrion", "Nucleus"],
                  answer: "Mitochondrion", explanation: "Mitochondria produce ATP through oxidative phosphorylation.")
        ], sourceLabels: ["Lecture 2 notes"], modelInfo: "Test provider")
        let (container, course, service, turnID) = try fixture(material)
        let view = ChatStudyMaterialSheet(course: course, turnID: turnID, material: material)
            .environment(service).modelContainer(container)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("lectern-chat-review.png"))
    }

}
