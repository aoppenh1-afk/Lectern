import SwiftUI
import SwiftData

struct ChatStudyMaterialSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CourseSynthesisService.self) private var synthesis
    @Query(sort: \Lecture.capturedAt, order: .reverse) private var lectures: [Lecture]
    let course: Course
    let turnID: UUID
    @State var material: ChatStudyMaterial
    @State private var destinationID: PersistentIdentifier?
    @State private var newLectureTitle = ""
    @State private var editing = false
    @State private var saveError: String?

    private var destinations: [Lecture] {
        lectures.filter { $0.course == course && $0.status == .ready }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Review \(material.kind.title.lowercased())").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Material title", text: $material.title).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Save to", selection: $destinationID) {
                    Text("New lecture in \(course.name)").tag(Optional<PersistentIdentifier>.none)
                    ForEach(destinations) { lecture in
                        Text(lecture.title).tag(Optional(lecture.persistentModelID))
                    }
                }
                .frame(maxWidth: .infinity)
                Toggle("Edit draft", isOn: $editing).toggleStyle(.switch)
            }
            if destinationID == nil {
                TextField("New lecture title", text: $newLectureTitle).textFieldStyle(.roundedBorder)
            }
            Text(saveExplanation).font(.callout).foregroundStyle(.secondary)
            Divider()
            if editing {
                draftEditor
            } else {
                ScrollView { NotesContentView(markdown: material.preview).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if !material.sourceLabels.isEmpty {
                Text("Sources: " + material.sourceLabels.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
            HStack {
                Text("Generated with \(material.modelInfo)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save to lecture") {
                    do {
                        try synthesis.saveMaterial(material, turnID: turnID, course: course,
                                                   lectureID: destinationID, newLectureTitle: newLectureTitle)
                        dismiss()
                    } catch { saveError = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(material.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (destinationID == nil && newLectureTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(minWidth: 660, idealWidth: 780, minHeight: 600, idealHeight: 760)
        .onAppear { newLectureTitle = material.title }
    }

    @ViewBuilder
    private var draftEditor: some View {
        switch material.kind {
        case .notes, .studyGuide:
            TextEditor(text: $material.markdown).font(.system(.body, design: .monospaced))
        case .flashcards:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(material.cards.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Card \(index + 1)").font(.headline)
                            TextField("Question", text: $material.cards[index].front, axis: .vertical)
                            TextField("Answer", text: $material.cards[index].back, axis: .vertical)
                        }.textFieldStyle(.roundedBorder)
                    }
                }.padding(8)
            }
        case .quiz:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(material.questions.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Question \(index + 1)").font(.headline)
                            TextField("Question", text: $material.questions[index].prompt, axis: .vertical)
                            if let options = material.questions[index].options, !options.isEmpty {
                                ForEach(options.indices, id: \.self) { optionIndex in
                                    TextField("Choice \(optionIndex + 1)", text: Binding(
                                        get: { material.questions[index].options?[optionIndex] ?? "" },
                                        set: { value in
                                            let previous = material.questions[index].options?[optionIndex]
                                            material.questions[index].options?[optionIndex] = value
                                            if material.questions[index].answer == previous { material.questions[index].answer = value }
                                        }
                                    ))
                                }
                                Picker("Correct answer", selection: $material.questions[index].answer) {
                                    ForEach(options, id: \.self) { Text($0).tag($0) }
                                }
                            } else {
                                TextField("Answer", text: $material.questions[index].answer, axis: .vertical)
                            }
                            TextField("Explanation", text: $material.questions[index].explanation, axis: .vertical)
                        }.textFieldStyle(.roundedBorder)
                    }
                }.padding(8)
            }
        }
    }

    private var saveExplanation: String {
        switch material.kind {
        case .notes, .studyGuide:
            return destinationID == nil ? "Creates a lecture with these notes. No recording is required." : "Adds a new section to this lecture's notes. Existing notes stay intact."
        case .quiz:
            return "Saves \(material.questions.count) \(material.questions.count == 1 ? "question" : "questions") as a separate quiz set. Existing quizzes stay intact."
        case .flashcards:
            return "Adds up to \(material.cards.count) \(material.cards.count == 1 ? "card" : "cards") to the lecture's deck. Identical question-and-answer pairs are skipped."
        }
    }
}
