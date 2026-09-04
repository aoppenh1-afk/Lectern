import SwiftData
import SwiftUI

struct ShiurImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ShiurAutomationService.self) private var automationService
    @Environment(TranscriptionPreferences.self) private var transcriptionPreferences

    @Query(sort: \Course.name) private var courses: [Course]

    let item: RemoteShiurItem

    @State private var selectedCourseID: PersistentIdentifier? = nil
    @State private var selectedLanguage: LectureLanguage = .hebrewEnglish
    @State private var autoTranscribe: Bool = true
    @State private var autoGenerateNotes: Bool = true
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showingNewCourse: Bool = false

    private enum DestinationChoice: Hashable {
        case unfiled
        case course(PersistentIdentifier)
        case createNew
    }

    private var destinationBinding: Binding<DestinationChoice> {
        Binding(
            get: {
                if let id = selectedCourseID {
                    return .course(id)
                }
                return .unfiled
            },
            set: { choice in
                switch choice {
                case .unfiled:
                    selectedCourseID = nil
                case .course(let id):
                    selectedCourseID = id
                    if let course = courses.first(where: { $0.persistentModelID == id }) {
                        selectedLanguage = course.language
                    }
                case .createNew:
                    showingNewCourse = true
                }
            }
        )
    }

    private func createNewCourse(name: String, language: LectureLanguage) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let color = LecternTheme.coursePalette[courses.count % LecternTheme.coursePalette.count]
        let newCourse = Course(name: trimmed, colorHex: color, language: language)
        modelContext.insert(newCourse)
        try? modelContext.save()
        selectedCourseID = newCourse.persistentModelID
        selectedLanguage = language
    }

    private var selectedCourse: Course? {
        guard let id = selectedCourseID else { return nil }
        return courses.first(where: { $0.persistentModelID == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            previewCard
            configurationCard

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LecternTheme.warningTint)
            }

            footer
        }
        .padding(24)
        .frame(width: 480)
        .background(LecternTheme.paper)
        .sheet(isPresented: $showingNewCourse) {
            NewCourseSheet { name, language in
                createNewCourse(name: name, language: language)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Import Shiur")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(LecternTheme.ink)

            Text("Download and import as an ordinary Lectern lecture.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LecternTheme.ink)

            HStack(spacing: 12) {
                if let teacher = item.teacherName {
                    Label(teacher, systemImage: "person")
                }
                Label(item.date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                if let duration = item.duration, duration > 0 {
                    let minutes = Int(duration) / 60
                    Label("\(minutes) min", systemImage: "clock")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Destination Course
            HStack(spacing: 8) {
                Text("Destination")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: destinationBinding) {
                    Text("Unfiled").tag(DestinationChoice.unfiled)
                    if !courses.isEmpty {
                        Divider()
                        ForEach(courses) { course in
                            Text(course.name).tag(DestinationChoice.course(course.persistentModelID))
                        }
                    }
                    Divider()
                    Label("Create New Course…", systemImage: "plus")
                        .tag(DestinationChoice.createNew)
                }
                .labelsHidden()
                .frame(width: 175)

                Button {
                    showingNewCourse = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LecternTheme.accent)
                        .padding(5)
                        .background(LecternTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Create a new Course")
            }

            Divider()

            HStack {
                Text("Audio language")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: $selectedLanguage) {
                    Text("English").tag(LectureLanguage.english)
                    Text("English + Hebrew").tag(LectureLanguage.hebrewEnglish)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Divider()

            Toggle(isOn: $autoTranscribe) {
                Text("Automatically transcribe")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .toggleStyle(.switch)

            Divider()

            Toggle(isOn: $autoGenerateNotes) {
                Text("Generate Notes after transcription")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .toggleStyle(.switch)
            .onChange(of: autoGenerateNotes) { _, enabled in
                if enabled && !autoTranscribe {
                    autoTranscribe = true
                }
            }
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(isImporting ? "Importing…" : "Import Shiur") {
                startImport()
            }
            .keyboardShortcut(.defaultAction)
            .prominentAction()
            .tint(LecternTheme.accent)
            .disabled(isImporting)
        }
    }

    private func startImport() {
        isImporting = true
        errorMessage = nil

        Task {
            do {
                _ = try await automationService.importShiur(
                    item,
                    into: selectedCourse,
                    language: selectedLanguage,
                    autoTranscribe: autoTranscribe,
                    autoGenerateNotes: autoGenerateNotes
                )
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
