import SwiftData
import SwiftUI

enum SidebarSelection: Hashable {
    case unfiled
    case course(Course)
}

struct MainWindowView: View {
    @Environment(CaptureController.self) private var capture
    @Environment(TranscriptionService.self) private var transcription
    @Environment(TranscriptionPreferences.self) private var transcriptionPreferences
    @Environment(GenerationService.self) private var generation
    @Environment(RetentionService.self) private var retention
    @Environment(SurfacePreferences.self) private var surfacePreferences
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Course.name) private var courses: [Course]
    @Query(sort: \Lecture.capturedAt, order: .reverse) private var lectures: [Lecture]

    /// When embedded in Command Studio, only courses in the active academic term
    /// are visible. A nil value keeps the standalone lecture-library behavior.
    let allowedCourseIDs: Set<PersistentIdentifier>?

    init(allowedCourseIDs: Set<PersistentIdentifier>? = nil) {
        self.allowedCourseIDs = allowedCourseIDs
    }

    @State private var selection: SidebarSelection?
    @State private var selectedLecture: Lecture?
    @State private var showingNewCourse = false
    @State private var searchText = ""
    @State private var transcriptMatches: Set<PersistentIdentifier> = []
    @State private var transcriptIDsByKey: [String: PersistentIdentifier] = [:]
    private let transcriptSearchIndex = TranscriptSearchIndex.shared
    @State private var searchIndexReady = false
    @State private var searchRevision = 0
    @State private var isIndexingTranscripts = false
    @State private var transcriptSearchError: String?
    @State private var importError: String?
    @State private var generateTarget: Lecture?
    @State private var exportTarget: Lecture?
    @State private var renamingLecture: Lecture?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    private let cardBorder = Color.primary.opacity(0.08)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                listColumn
                Divider()
                detailPane
            }
        }
        .background(LecternTheme.panelFill)
        .task {
            if selection == nil {
                selection = visibleCourses.first.map { SidebarSelection.course($0) } ?? .unfiled
            }
        }
        .onChange(of: selection) { _, _ in
            selectedLecture = nil
            searchText = ""
        }
        .onChange(of: lectures.map(\.status)) { _, _ in
            searchIndexReady = false
            searchRevision += 1
        }
        .onChange(of: lectures.count) { _, _ in
            searchIndexReady = false
            searchRevision += 1
        }
        .task(id: "\(searchText)|\(searchRevision)") {
            await updateTranscriptMatches()
        }
        .sheet(item: $generateTarget) { lecture in
            GenerateSheet(lecture: lecture)
        }
        .sheet(item: $exportTarget) { lecture in
            LectureBundleExportSheet(lecture: lecture)
        }
        .alert("Import Failed", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showingNewCourse) {
            NewCourseSheet { name, language in
                addCourse(name: name, language: language)
            }
        }
    }

    private var selectedCourse: Course? {
        if case .course(let course) = selection { return course }
        return nil
    }

    private var visibleCourses: [Course] {
        guard let allowedCourseIDs else { return courses }
        return courses.filter { allowedCourseIDs.contains($0.persistentModelID) }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            recordButton

            Button {
                generateTarget = selectedLecture
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("Generate")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(LecternTheme.cardFill))
                .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 1))
                .foregroundStyle(LecternTheme.ink)
            }
            .buttonStyle(.plain)
            .disabled(selectedLecture == nil || selectedLecture.map { generation.job(for: $0.persistentModelID) != nil } == true)
            .opacity(selectedLecture == nil ? 0.45 : 1)
            .help("Generate cleaned transcript, notes, flashcards, quiz")

            Button {
                importAudioLecture(autoTranscribe: true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Upload Audio")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(LecternTheme.cardFill))
                .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 1))
                .foregroundStyle(LecternTheme.ink)
            }
            .buttonStyle(.plain)
            .disabled(selectedCourse == nil)
            .opacity(selectedCourse == nil ? 0.45 : 1)
            .help(selectedCourse.map { "Upload audio to \($0.name) for transcription" }
                  ?? "Select a course to upload audio")

            Spacer()

            if capture.phase.isLive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(LecternTheme.recordTint)
                        .frame(width: 6, height: 6)
                        .symbolEffect(.pulse)
                    Text("\(capture.liveStatusTitle)…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LecternTheme.recordTint)
                }
            } else if generation.activeJob != nil {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Generating study materials for \(generation.activeJobs.count) lecture(s)…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Button {
                exportTarget = selectedLecture
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LecternTheme.cardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(cardBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedLecture == nil)
            .opacity(selectedLecture == nil ? 0.45 : 1)
            .help("Export this lecture as Lectern, Markdown, PDF, or Word")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var recordButton: some View {
        let isLive = capture.phase.isLive
        let source = surfacePreferences.captureSource
        return HStack(spacing: 0) {
            Button {
                capture.toggle(in: selectedCourse, source: source)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(LecternTheme.recordTint)
                        .frame(width: 12, height: 12)
                        .symbolEffect(.pulse, isActive: isLive)
                    Text(isLive ? "Stop Recording" : source.recordButtonTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .frame(minWidth: isLive ? nil : 101)
            .help(isLive
                  ? "Stop recording"
                  : "Record into \(selectedCourse?.name ?? "Unfiled") using \(source.title.lowercased())")

            if !isLive {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: 19)

                Menu {
                    ForEach(CaptureSource.allCases) { item in
                        Button {
                            surfacePreferences.setCaptureSource(item)
                            capture.toggle(in: selectedCourse, source: item)
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LecternTheme.ink)
                        .frame(width: 38, height: 29)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose microphone, Zoom / system audio, or both")
            }
        }
        .background(
            Capsule().fill(isLive ? LecternTheme.recordTint.opacity(0.10) : LecternTheme.canvasCard)
        )
        .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 1))
        .foregroundStyle(LecternTheme.ink)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            unfiledRow

            HStack {
                Text("Courses")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingNewCourse = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add Course")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 5)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleCourses) { course in
                        courseRow(course)
                    }
                }
            }

            Spacer()
        }
        .frame(width: 244)
        .background(LecternTheme.panelFill)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .help("Search lecture titles, courses, and transcripts")
            if isIndexingTranscripts && !searchText.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LecternTheme.canvasCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LecternTheme.hairline, lineWidth: 1)
        )
    }

    private var unfiledRow: some View {
        Button {
            selection = .unfiled
            selectedLecture = nil
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LecternTheme.warningTint.opacity(0.14))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "tray")
                            .font(.system(size: 11))
                            .foregroundStyle(LecternTheme.warningTint.darkened(by: 0.1))
                    )
                Text("Unfiled")
                    .font(.system(size: 12.5, weight: selection == .unfiled ? .semibold : .regular))
                    .foregroundStyle(selection == .unfiled ? LecternTheme.sidebarSelectedText : LecternTheme.ink)
                Spacer()
                Text("\(lectures.filter(\.isUnfiled).count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == .unfiled ? LecternTheme.sidebarSelectedFill : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func courseRow(_ course: Course) -> some View {
        let isSelected = selection == .course(course)
        return Button {
            selection = .course(course)
            selectedLecture = nil
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(hex: course.colorHex).opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: course.subjectSymbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: course.colorHex).darkened(by: 0.12))
                    )
                Text(course.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LecternTheme.sidebarSelectedText : LecternTheme.ink)
                    .lineLimit(1)
                Spacer()
                Text("\(course.lectures.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? LecternTheme.sidebarSelectedFill : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Picker("Transcription Language", selection: Binding(
                get: { course.language },
                set: { course.language = $0 }
            )) {
                ForEach(LectureLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            Divider()
            Button("Delete Course", role: .destructive) {
                deleteCourse(course)
            }
        }
    }

    // MARK: - Lecture list

    @MainActor
    private func updateTranscriptMatches() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            transcriptMatches = []
            transcriptSearchError = nil
            isIndexingTranscripts = false
            return
        }
        // A one-character query is useful for title search, but would produce
        // a very broad transcript lookup and unnecessary disk work.
        guard TranscriptSearchIndex.ftsQuery(query) != nil else {
            transcriptMatches = []
            isIndexingTranscripts = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            if !searchIndexReady {
                isIndexingTranscripts = true
                try await synchronizeTranscriptIndex()
                try Task.checkCancellation()
                searchIndexReady = true
                isIndexingTranscripts = false
            }
            let matchedKeys = try await transcriptSearchIndex.search(query)
            try Task.checkCancellation()
            transcriptMatches = Set(matchedKeys.compactMap { transcriptIDsByKey[$0] })
            transcriptSearchError = nil
        } catch is CancellationError {
            isIndexingTranscripts = false
        } catch {
            isIndexingTranscripts = false
            transcriptSearchError = error.localizedDescription
            transcriptMatches = []
        }
    }

    @MainActor
    private func synchronizeTranscriptIndex() async throws {
        let indexedRevisions = try await transcriptSearchIndex.revisions()
        var currentKeys: Set<String> = []
        var idsByKey: [String: PersistentIdentifier] = [:]
        var batch: [TranscriptSearchIndex.Document] = []

        for lecture in lectures where lecture.status == .ready {
            try Task.checkCancellation()
            guard let key = TranscriptSearchIndex.key(for: lecture.persistentModelID) else { continue }
            let revision = (lecture.transcriptCompletedAt ?? lecture.capturedAt).timeIntervalSince1970
            if indexedRevisions[key] == revision {
                currentKeys.insert(key)
                idsByKey[key] = lecture.persistentModelID
                continue
            }
            // A short-lived context keeps the first search's backfill from
            // retaining every transcript in the window's long-lived context.
            guard let text = try rawTranscript(for: lecture.persistentModelID),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            currentKeys.insert(key)
            idsByKey[key] = lecture.persistentModelID
            batch.append(.init(key: key, revision: revision, text: text))
            if batch.count == 4 {
                try await transcriptSearchIndex.upsert(batch)
                batch.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        if !batch.isEmpty { try await transcriptSearchIndex.upsert(batch) }
        try await transcriptSearchIndex.removeMissing(keeping: currentKeys)
        try Task.checkCancellation()
        transcriptIDsByKey = idsByKey
    }

    @MainActor
    private func rawTranscript(for id: PersistentIdentifier) throws -> String? {
        let context = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<Lecture>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        guard let lecture = try context.fetch(descriptor).first,
              !lecture.isDeleted else { return nil }
        return lecture.artifact(of: .rawTranscript)?.content
    }

    private var visibleLectures: [Lecture] {
        if !searchText.isEmpty {
            return lectures.filter {
                (allowedCourseIDs == nil || $0.course.map {
                    allowedCourseIDs?.contains($0.persistentModelID) ?? false
                } == true) && (
                    $0.title.localizedCaseInsensitiveContains(searchText) ||
                    ($0.course?.name.localizedCaseInsensitiveContains(searchText) ?? false) ||
                    transcriptMatches.contains($0.persistentModelID)
                )
            }
        }
        switch selection {
        case .unfiled: return lectures.filter(\.isUnfiled)
        case .course(let course): return course.lectures.sorted { $0.capturedAt > $1.capturedAt }
        case nil: return lectures
        }
    }

    private var selectionTitle: String {
        if !searchText.isEmpty { return "Results" }
        switch selection {
        case .course(let course): return course.name
        case .unfiled: return "Unfiled"
        case nil: return "All lectures"
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectionTitle)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text("\(visibleLectures.count) lecture\(visibleLectures.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if !searchText.isEmpty, transcriptSearchError != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(LecternTheme.warningTint)
                        .help(transcriptSearchError ?? "Transcript search unavailable")
                }
                Spacer()
                if selectedCourse != nil, searchText.isEmpty {
                    Button {
                        attachReferenceMaterials(to: nil)
                    } label: {
                        Image(systemName: "paperclip.badge.plus")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach notes or slides to this course")
                }
                if searchText.isEmpty {
                    addLectureMenu
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if visibleLectures.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(dayGroups, id: \.key) { group in
                            Text(group.key)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                            ForEach(group.items) { lecture in
                                listRow(lecture)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 316)
    }

    /// Add-lecture entry point: record now or import an existing audio file.
    private var addLectureMenu: some View {
        Menu {
            if capture.phase.isLive {
                Button {
                    capture.stop()
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
            } else {
                ForEach(CaptureSource.allCases) { source in
                    Button {
                        surfacePreferences.setCaptureSource(source)
                        capture.toggle(in: selectedCourse, source: source)
                    } label: {
                        Label(source == .microphone ? "Record Lecture" : source.title,
                              systemImage: source.systemImage)
                    }
                }
            }
            Button {
                // Menu dismissal and panel presentation share a turn. Hop to the next
                // run-loop pass so NSOpenPanel is not attached to the disappearing menu.
                DispatchQueue.main.async {
                    importAudioLecture()
                }
            } label: {
                Label("Import Audio File…", systemImage: "square.and.arrow.down")
            }
            Button {
                DispatchQueue.main.async {
                    importLecternBundle()
                }
            } label: {
                Label("Import Lectern Bundle…", systemImage: "shippingbox.and.arrow.backward")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a lecture")
    }

    @ViewBuilder
    private var emptyList: some View {
        if !searchText.isEmpty {
            EmptyStateView(icon: "magnifyingglass",
                           title: "No matches",
                           message: "Nothing in view matches “\(searchText)”.")
        } else {
            switch selection {
            case .course(let course):
                EmptyStateView(icon: "waveform.badge.plus",
                               title: "No lectures in \(course.name)",
                               message: "Record your next class or import an audio file. It will land here automatically.",
                               actionTitle: "Start Recording") {
                    capture.toggle(in: course, source: surfacePreferences.captureSource)
                }
            case .unfiled:
                EmptyStateView(icon: "tray",
                               title: "Nothing unfiled",
                               message: "Lectures recorded before picking a course wait here until you file them.")
            case nil:
                EmptyStateView(icon: "book.closed",
                               title: "Pick a collection",
                               message: "Choose a course on the left to see its lectures.")
            }
        }
    }

    private var dayGroups: [(key: String, items: [Lecture])] {
        let calendar = Calendar.current
        var result: [(String, [Lecture])] = []
        var remaining = visibleLectures
        for (label, test) in [("Today", calendar.isDateInToday), ("Yesterday", calendar.isDateInYesterday)] {
            let matches = remaining.filter { test($0.capturedAt) }
            if !matches.isEmpty {
                result.append((label, matches))
                remaining.removeAll { test($0.capturedAt) }
            }
        }
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let thisWeek = remaining.filter { $0.capturedAt >= weekAgo }
        if !thisWeek.isEmpty {
            result.append(("This week", thisWeek))
            remaining.removeAll { thisWeek.contains($0) }
        }
        if !remaining.isEmpty {
            result.append(("Earlier", remaining.sorted { $0.capturedAt > $1.capturedAt }))
        }
        return result.map { (key: $0.0, items: $0.1) }
    }

    private func listRow(_ lecture: Lecture) -> some View {
        let isSelected = selectedLecture == lecture
        let isRenaming = renamingLecture == lecture
        return Button {
            selectedLecture = lecture
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    if isRenaming {
                        TextField("Lecture title", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, weight: .semibold))
                            .focused($renameFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renamingLecture = nil }
                    } else {
                        Text(lecture.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LecternTheme.ink)
                            .lineLimit(1)
                    }
                    Text("\(lecture.course?.name ?? "Unfiled") · \(shortDate(lecture)) · \(durationLabel(lecture))\(lecture.language == .hebrewEnglish ? " · En+עב" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if !searchText.isEmpty, transcriptMatches.contains(lecture.persistentModelID) {
                        Text("Transcript match")
                            .font(.system(size: 10))
                            .foregroundStyle(LecternTheme.accent)
                    }
                }
                Spacer(minLength: 8)
                if !isRenaming {
                    statusChip(lecture)
                    if isSelected {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LecternTheme.accent)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? LecternTheme.sidebarSelectedFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) {
            selectedLecture = lecture
            beginRename(lecture)
        }
        .contextMenu {
            Button("Rename…") {
                selectedLecture = lecture
                beginRename(lecture)
            }
            if lecture.isUnfiled, !visibleCourses.isEmpty {
                Menu("File into") {
                    ForEach(visibleCourses) { course in
                        Button(course.name) { lecture.course = course }
                    }
                }
            } else if let course = lecture.course {
                Button("Remove from \(course.name)") { lecture.course = nil }
            }
            if lecture.recording != nil,
               lecture.status == .recorded ||
               lecture.status == .ready ||
               lecture.status == .failed {
                Menu(lecture.status == .recorded ? "Transcribe" : "Transcribe Again") {
                    ForEach(LectureLanguage.allCases) { language in
                        Button(language == lecture.language
                               ? "\(language.title) (current)"
                               : language.title) {
                            transcription.retranscribe(lecture, as: language)
                        }
                    }
                }
            }
            Button("Attach notes or slides…") {
                attachReferenceMaterials(to: lecture)
            }
            Button("Share…") {
                exportTarget = lecture
            }
            Divider()
            Button("Delete Lecture", role: .destructive) {
                if selectedLecture == lecture { selectedLecture = nil }
                transcription.cancel(lectureID: lecture.persistentModelID,
                                     discardingCheckpointsFor: lecture.recording?.filePath)
                generation.cancel(lectureID: lecture.persistentModelID)
                capture.discardLectureRecording(lecture)
                modelContext.delete(lecture)
                try? modelContext.save()
            }
        }
    }

    private func beginRename(_ lecture: Lecture) {
        renamingLecture = lecture
        renameText = lecture.title
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lecture = renamingLecture, !trimmed.isEmpty {
            lecture.title = trimmed
        }
        renamingLecture = nil
    }

    private func statusChip(_ lecture: Lecture) -> some View {
        let tint = chipTint(lecture.status)
        return HStack(spacing: 4) {
            if lecture.status == .recording {
                Circle().fill(tint).frame(width: 5, height: 5)
                    .symbolEffect(.pulse)
            } else {
                Image(systemName: chipIcon(lecture.status))
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(statusLabel(lecture.status))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
    }

    private func chipTint(_ status: LectureStatus) -> Color {
        switch status {
        case .recording: return LecternTheme.recordTint
        case .recorded: return LecternTheme.accent
        case .transcribing: return LecternTheme.processingTint
        case .ready: return LecternTheme.successTint
        case .failed: return LecternTheme.warningTint
        }
    }

    private func chipIcon(_ status: LectureStatus) -> String {
        switch status {
        case .recording: return "mic"
        case .recorded: return "waveform.badge.plus"
        case .transcribing: return "waveform"
        case .ready: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private func statusLabel(_ status: LectureStatus) -> String {
        switch status {
        case .recording: return "Recording"
        case .recorded: return "Recorded"
        case .transcribing: return "Transcribing"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let selectedLecture {
            LectureDetailView(
                lecture: selectedLecture,
                onAttachFiles: { attachReferenceMaterials(to: selectedLecture) },
                onGenerate: { generateTarget = selectedLecture }
            )
            .id(selectedLecture.persistentModelID)
        } else {
            dashboardHome
        }
    }

    private func importAudioLecture(autoTranscribe: Bool = false) {
        guard let url = LectureImportPicker.chooseAudioFile() else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let lecture = try capture.importAudio(at: url, into: selectedCourse)
            if autoTranscribe {
                selectedLecture = lecture
                if transcriptionPreferences.source != .askEachTime {
                    transcription.retranscribe(lecture, as: lecture.language)
                }
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importLecternBundle() {
        guard let url = LectureImportPicker.chooseBundle() else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            selectedLecture = try LecternBundleService.importBundle(
                from: url, into: selectedCourse, context: modelContext
            )
        } catch {
            importError = error.localizedDescription
        }
    }

    private func attachReferenceMaterials(to lecture: Lecture?) {
        guard let urls = ReferenceMaterialPicker.chooseFiles(), !urls.isEmpty else { return }
        do {
            try ReferenceMaterialService.importFiles(
                urls,
                course: lecture?.course ?? selectedCourse,
                lecture: lecture,
                context: modelContext
            )
        } catch {
            importError = error.localizedDescription
        }
    }

    private var dashboardHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Home")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)

                HStack(spacing: 12) {
                    statCard(value: "\(lectures.count)",
                             label: "Lectures",
                             icon: "waveform",
                             tint: LecternTheme.processingTint)
                    statCard(value: "\((try? modelContext.fetchCount(FetchDescriptor<Artifact>())) ?? 0)",
                             label: "Materials",
                             icon: "doc.text",
                             tint: .purple)
                    statCard(value: "\((try? modelContext.fetchCount(FetchDescriptor<Flashcard>())) ?? 0)",
                             label: "Flashcards",
                             icon: "rectangle.on.rectangle.angled",
                             tint: .teal)
                    statCard(value: "\(lectures.filter { $0.status == .ready }.count)",
                             label: "Ready",
                             icon: "checkmark.circle",
                             tint: LecternTheme.successTint)
                }

                if !lectures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent lectures")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LecternTheme.ink)
                            .padding(.bottom, 4)
                        ForEach(lectures.prefix(5)) { lecture in
                            listRow(lecture)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func statCard(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.12)))
                Spacer()
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .serif).monospacedDigit())
                .foregroundStyle(LecternTheme.ink)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func addCourse(name: String, language: LectureLanguage) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let color = LecternTheme.coursePalette[visibleCourses.count % LecternTheme.coursePalette.count]
        modelContext.insert(Course(name: trimmed, colorHex: color, language: language))
    }

    private func deleteCourse(_ course: Course) {
        course.lectures.forEach { $0.course = nil }
        if case .course(let selected) = selection, selected == course {
            selection = nil
        }
        modelContext.delete(course)
    }

    // MARK: - Date helpers

    private func shortDate(_ lecture: Lecture) -> String {
        lecture.capturedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private func durationLabel(_ lecture: Lecture) -> String {
        Duration.seconds(lecture.duration).formatted(.time(pattern: .hourMinuteSecond))
    }
}

/// Course creation: name plus the transcription language its lectures default
/// to. English + Hebrew tells automatic on-device transcription to use whisper.cpp;
/// an explicit Gemini/Antigravity default in Settings still applies to those lectures.
struct NewCourseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var language: LectureLanguage = .english
    @FocusState private var nameFocused: Bool

    let onCreate: (String, LectureLanguage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Course")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(LecternTheme.ink)

            TextField("Course name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)

            VStack(alignment: .leading, spacing: 6) {
                Text("Lecture language")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("Lecture language", selection: $language) {
                    ForEach(LectureLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(language.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Courses group your lectures and name your Anki decks.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, language)
        dismiss()
    }
}
