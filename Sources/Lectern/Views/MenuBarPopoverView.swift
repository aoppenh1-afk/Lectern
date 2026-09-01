import SwiftData
import SwiftUI

struct MenuBarPopoverView: View {
    @Environment(CaptureController.self) private var capture
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Course.name) private var courses: [Course]

    @State private var selectedCourse: Course?
    @State private var selectedLanguage: LectureLanguage = .english
    @State private var bookmarkNote = ""

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            Group {
                if capture.phase.isLive {
                    liveContent
                        .transition(.opacity)
                } else {
                    idleContent
                        .transition(.opacity)
                }
            }
            .padding(14)
        }
        .frame(width: 252)
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LecternTheme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Lectern")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Ready to record")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider().opacity(0.5)

            if !courses.isEmpty {
                Picker("Course", selection: $selectedCourse) {
                    Text("None (Unfiled)").tag(Optional<Course>.none)
                    ForEach(courses) { course in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: course.colorHex))
                                .frame(width: 7, height: 7)
                            Text(course.name)
                        }
                        .tag(Optional(course))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: selectedCourse) { _, course in
                    selectedLanguage = course?.language ?? .english
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(LectureLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Text(selectedLanguage.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = capture.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(LecternTheme.warningTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await capture.start(in: selectedCourse, language: selectedLanguage) }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .prominentAction()
            .tint(LecternTheme.recordTint)

            Divider().opacity(0.5)

            popoverLink("Open Lectern", systemImage: "book.closed") {
                openWindow(id: "main")
            }
            popoverLink("Settings…", systemImage: "gearshape") {
                openSettings()
            }
            popoverLink("Quit Lectern", systemImage: "power", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func popoverLink(_ title: String, systemImage: String,
                             role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(role == .destructive ? AnyShapeStyle(LecternTheme.recordTint) : AnyShapeStyle(Color.secondary))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(LecternTheme.recordTint) : AnyShapeStyle(Color.primary))
    }

    // MARK: - Live

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 7) {
                    Circle()
                        .fill(LecternTheme.recordTint)
                        .frame(width: 7, height: 7)
                        .symbolEffect(.pulse)

                    Text("Recording")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text(elapsedString)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(LecternTheme.recordTint)
                }
            }

            if let course = capture.activeCourseName {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 5, height: 5)
                    Text(course)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                capture.stop()
            } label: {
                Label("Stop & Save Lecture", systemImage: "stop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .prominentAction()

            HStack(spacing: 6) {
                TextField("Quick thought…", text: $bookmarkNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveThought)
                Button(action: saveThought) {
                    Image(systemName: "bookmark.fill")
                }
                .help(bookmarkNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "Drop bookmark (Option-Command-B)"
                      : "Save timestamped thought")
                Button {
                    capture.addBookmark(isExamAlert: true)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .help("Exam alert (Option-Command-B)")
            }

            if !capture.liveBookmarks.isEmpty {
                Text("\(capture.liveBookmarks.count) bookmark\(capture.liveBookmarks.count == 1 ? "" : "s") saved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("The transcript appears after you stop — nothing is shown during class.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var elapsedString: String {
        let interval = Int(capture.elapsedInterval)
        return String(format: "%02d:%02d:%02d",
                      interval / 3600,
                      (interval % 3600) / 60,
                      interval % 60)
    }

    private func saveThought() {
        guard capture.addBookmark(note: bookmarkNote) else { return }
        bookmarkNote = ""
    }
}
