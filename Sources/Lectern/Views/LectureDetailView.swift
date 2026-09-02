import AppKit
import SwiftData
import SwiftUI

struct LectureDetailView: View {
    @Environment(TranscriptionService.self) private var transcription
    @Environment(TranscriptionPreferences.self) private var transcriptionPreferences
    @Environment(GenerationService.self) private var generation
    @Environment(CardSyncService.self) private var cardSync
    @Environment(LectureAudioPlayer.self) private var audioPlayer
    @Environment(\.modelContext) private var modelContext

    @Bindable var lecture: Lecture
    let onAttachFiles: () -> Void

    @State private var selectedTab: Tab = .rawTranscript
    @State private var antigravityCatalog = AgentModelCatalog.empty

    enum Tab: Hashable {
        case rawTranscript, cleanedTranscript, notes, flashcards, quiz, bookmarks, attachments
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                statusArea
                transcriptProvenance
                tabBar
                artifactContent
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: LecternTheme.readingWidth + 56)
            .frame(maxWidth: .infinity)
        }
        .task {
            _ = transcription.recoverCompletedLocalCheckpointIfPossible(lecture)
            if let profile = AgentProfiles.profile(id: AgentProfiles.antigravityID) {
                antigravityCatalog = await AgentModelCatalogLoader.load(for: profile)
            }
        }
    }

    // MARK: - Header

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                TextField("Lecture title", text: $lecture.title, axis: .vertical)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                    .textFieldStyle(.plain)
                    .lineLimit(2)
                    .help("Click to rename this lecture")

                Spacer(minLength: 12)

                Button(action: onAttachFiles) {
                    Label("Add files", systemImage: "paperclip.badge.plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach notes or slides to this lecture")
            }

            HStack(spacing: 12) {
                if let course = lecture.course {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: course.colorHex))
                            .frame(width: 6, height: 6)
                        Text(course.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                MetaText(heroMeta)
            }
        }
        .padding(.bottom, 2)
    }

    private var heroMeta: [String] {
        var parts = [
            lecture.capturedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
            Duration.seconds(lecture.duration).formatted(.time(pattern: .hourMinuteSecond)),
        ]
        if let size = audioSizeLabel { parts.append(size) }
        if !lecture.flashcards.isEmpty { parts.append("\(lecture.flashcards.count) cards") }
        if !lecture.quizItems.isEmpty { parts.append("\(lecture.quizItems.count) questions") }
        if !lecture.attachments.isEmpty { parts.append("\(lecture.attachments.count) files") }
        return parts
    }

    private var audioSizeLabel: String? {
        guard lecture.recording?.isPruned == false, lecture.recordingSizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: lecture.recordingSizeBytes, countStyle: .file)
    }

    // MARK: - Pipeline state

    @ViewBuilder
    private var statusArea: some View {
        switch lecture.status {
        case .recorded:
            SurfaceCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(LecternTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording saved")
                            .font(.system(size: 13, weight: .medium))
                        Text("Transcription will start only when you choose it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Transcribe") {
                        transcription.retranscribe(lecture, as: lecture.language)
                    }
                    .prominentAction()
                    .tint(LecternTheme.accent)
                    transcriptionChoiceMenu(label: "Choose transcriber")
                }
            }
        case .transcribing:
            SurfaceCard(padding: 14) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LecternTheme.processingTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lecture.statusMessage ?? "Transcribing on-device")
                            .font(.system(size: 13, weight: .medium))
                        Text(transcribingSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        case .failed:
            SurfaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(lecture.statusMessage ?? "Transcription failed.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(LecternTheme.warningTint)
                    HStack {
                        Button("Try Again") { retry() }
                            .prominentAction()
                            .tint(LecternTheme.accent)
                        transcriptionChoiceMenu(label: "Choose transcriber")
                    }
                }
            }
        case .recording, .ready:
            EmptyView()
        }
    }

    private var transcribingSubtitle: String {
        TranscriptionJobPlan.resolve(
            preferenceSource: transcriptionPreferences.source,
            preferenceBuiltInModelID: transcriptionPreferences.builtInModelID,
            lectureSource: lecture.transcriptionSourceOverride,
            lectureModelID: lecture.transcriptionSourceOverride == .local
                ? lecture.transcriptModelID
                : nil,
            language: lecture.language
        ).progressSubtitle(connectionName: lecture.transcriptConnectionName)
    }

    @ViewBuilder
    private var transcriptProvenance: some View {
        if lecture.status == .ready,
           let provider = lecture.transcriptConnectionName,
           let model = lecture.transcriptModelID {
            HStack(spacing: 10) {
                if let providerID = lecture.transcriptProviderRaw.flatMap(TranscriptionProviderID.init(rawValue:)),
                   providerID != .local {
                    ProviderLogo(provider: providerID, size: 28)
                } else {
                    Image(systemName: "macbook")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribed with \(provider)")
                        .font(.system(size: 11, weight: .semibold))
                    Text([model, lecture.transcriptCompletedAt?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let fallback = lecture.transcriptFallbackSummary {
                        Text(fallback)
                            .font(.system(size: 10))
                            .foregroundStyle(LecternTheme.warningTint)
                    }
                }
                Spacer()
                transcriptionChoiceMenu(label: "Transcribe again")
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func transcriptionChoiceMenu(label: String) -> some View {
        Menu(label) {
            Section("Models available on this Mac") {
                ForEach(BuiltInTranscriptionModel.allCases.filter { !$0.usesAntigravity }) { model in
                    Button {
                        transcription.retranscribe(
                            lecture,
                            as: lecture.language,
                            source: .local,
                            builtInModelID: model.id
                        )
                    } label: {
                        Label(model.title, systemImage: "macbook")
                    }
                }
                Menu("Antigravity CLI") {
                    ForEach(antigravityMenuModels) { model in
                        Button {
                            transcription.retranscribe(
                                lecture,
                                as: lecture.language,
                                source: .local,
                                builtInModelID: model.id
                            )
                        } label: {
                            Label(model.name, systemImage: "sparkles")
                        }
                    }
                }
            }
            if !transcriptionPreferences.connections.filter(\.enabled).isEmpty {
                Divider()
                Section("API connections") {
                    ForEach(transcriptionPreferences.connections.filter(\.enabled)) { connection in
                        Button {
                            transcription.retranscribe(
                                lecture,
                                as: lecture.language,
                                source: .external,
                                connectionID: connection.id
                            )
                        } label: {
                            Text("\(connection.displayName) · \(connection.modelID)")
                        }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private var antigravityMenuModels: [AgentModel] {
        if antigravityCatalog.models.isEmpty {
            return [
                AgentModel(
                    id: AntigravityCLI.modelID,
                    name: AntigravityCLI.displayName,
                    provider: "Google",
                    isDefault: true,
                    supportedThinkingLevels: AntigravityCLI.thinkingLevels,
                    defaultThinkingLevel: .high
                )
            ]
        }
        return antigravityCatalog.models
    }

    // MARK: - Tab bar (underline style)

    @ViewBuilder
    private var tabBar: some View {
        if hasAnyArtifact {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    tabButton(.rawTranscript, "Raw Transcript")
                    if lecture.artifact(of: .cleanedTranscript) != nil {
                        tabButton(.cleanedTranscript, "Cleaned")
                    }
                    if lecture.artifact(of: .notes) != nil {
                        tabButton(.notes, "Notes")
                    }
                    if !lecture.flashcards.isEmpty {
                        tabButton(.flashcards, "Cards", count: lecture.flashcards.count)
                    }
                    if !lecture.quizItems.isEmpty {
                        tabButton(.quiz, "Quiz", count: lecture.quizItems.count)
                    }
                    if !lecture.bookmarks.isEmpty {
                        tabButton(.bookmarks, "Bookmarks", count: lecture.bookmarks.count)
                    }
                    if !lecture.attachments.isEmpty {
                        tabButton(.attachments, "Files", count: lecture.attachments.count)
                    }
                    Spacer()
                }
                .padding(.bottom, 0)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LecternTheme.hairline)
                    .frame(height: 1)
            }
        }
    }

    private func tabButton(_ tab: Tab, _ title: String, count: Int? = nil) -> some View {
        let isActive = selectedTab == tab
        return Button {
            withAnimation(LecternTheme.standardAnimation) { selectedTab = tab }
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(isActive ? .secondary : .tertiary)
                    }
                }
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

                RoundedRectangle(cornerRadius: 1)
                    .fill(isActive ? LecternTheme.accent : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && !isActive {
                // subtle affordance handled by color; no-op keeps motion budget
            }
        }
    }

    @ViewBuilder
    private var artifactContent: some View {
        switch selectedTab {
        case .rawTranscript:
            if let transcript = lecture.artifact(of: .rawTranscript) {
                TranscriptView(lecture: lecture, content: transcript.content)
                    .padding(.top, 16)
            }
        case .cleanedTranscript:
            if let cleaned = lecture.artifact(of: .cleanedTranscript) {
                NotesContentView(markdown: cleaned.content)
                    .padding(.top, 16)
            }
        case .notes:
            if let notes = lecture.artifact(of: .notes) {
                VStack(alignment: .leading, spacing: 14) {
                    GoogleDocsNotesBar(lecture: lecture)
                    NotesContentView(markdown: notes.content)
                }
                .padding(.top, 16)
            }
        case .flashcards:
            FlashcardsView(lecture: lecture)
                .padding(.top, 16)
        case .quiz:
            QuizReviewView(lecture: lecture)
                .padding(.top, 16)
        case .bookmarks:
            bookmarkList
                .padding(.top, 16)
        case .attachments:
            attachmentList
                .padding(.top, 16)
        }
    }

    private var attachmentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lecture.attachments.sorted(by: { $0.addedAt < $1.addedAt })) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                        .foregroundStyle(LecternTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.name).font(.system(size: 13, weight: .medium))
                        Text("\(attachment.extractedText.count.formatted()) characters available to AI")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !attachment.filePath.isEmpty {
                        Button("Open") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: attachment.filePath))
                        }
                    }
                    Button(role: .destructive) { modelContext.delete(attachment) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lecture.orderedBookmarks) { bookmark in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        if lecture.recording?.isPruned == false {
                            audioPlayer.play(lecture, from: bookmark.offset)
                        }
                    } label: {
                        Text(Self.bookmarkTime(bookmark.offset))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LecternTheme.accent)

                    Image(systemName: bookmark.isExamAlert
                          ? "exclamationmark.triangle.fill"
                          : "bookmark.fill")
                        .foregroundStyle(bookmark.isExamAlert ? .orange : LecternTheme.accent)
                    Text(bookmark.note.isEmpty
                         ? (bookmark.isExamAlert ? "Exam alert" : "Bookmark")
                         : bookmark.note)
                        .font(.system(size: 13))
                    Spacer()
                    Button(role: .destructive) {
                        modelContext.delete(bookmark)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private static func bookmarkTime(_ interval: TimeInterval) -> String {
        let value = max(0, Int(interval))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var hasAnyArtifact: Bool {
        !lecture.flashcards.isEmpty ||
        !lecture.quizItems.isEmpty ||
        !lecture.bookmarks.isEmpty ||
        !lecture.attachments.isEmpty ||
        lecture.artifacts.contains { $0.kind == .rawTranscript || $0.kind == .cleanedTranscript || $0.kind == .notes }
    }

    private func retry() {
        lecture.status = .transcribing
        lecture.statusMessage = nil
        try? modelContext.save()
        transcription.enqueue(lectureID: lecture.persistentModelID)
    }
}

// MARK: - Transcript rendering (document style with timestamp gutter)

struct TranscriptView: View {
    @Environment(LectureAudioPlayer.self) private var audioPlayer

    let lecture: Lecture
    let content: String

    private struct Paragraph {
        let startSeconds: Double?
        let timestampLabel: String?
        let text: String
    }

    private var paragraphs: [Paragraph] {
        content.components(separatedBy: "\n\n").compactMap { raw in
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            if let match = Self.timestampPattern.firstMatch(in: raw, range: raw.fullRange),
               Range(match.range(at: 1), in: raw) != nil,
               Range(match.range(at: 2), in: raw) != nil {
                let label = String(raw[Range(match.range(at: 1), in: raw)!])
                let seconds = Self.parseTimestamp(label)
                let text = String(raw[Range(match.range(at: 2), in: raw)!])
                return Paragraph(startSeconds: seconds, timestampLabel: label, text: text)
            }
            return Paragraph(startSeconds: nil, timestampLabel: nil, text: raw)
        }
    }

    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^\[(\d{2}:\d{2})\]\s*(.*)$"#, options: [.anchorsMatchLines]
    )

    static func parseTimestamp(_ label: String) -> Double? {
        let parts = label.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    var body: some View {
        let playable = lecture.recording?.isPruned == false
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(title: "Raw Transcript")
                Spacer()
                if playable {
                    Text("Tap a timestamp to listen")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    if let label = paragraph.timestampLabel {
                        Button {
                            if playable, let seconds = paragraph.startSeconds {
                                audioPlayer.play(lecture, from: seconds)
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(playable ? LecternTheme.accent : Color.secondary.opacity(0.6))
                                .frame(width: 42, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playable)
                        .help(playable ? "Play from here" : "Audio has been pruned")
                    }

                    Text(paragraph.text)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !playable {
                Label("Recording audio was pruned; timestamps are no longer clickable.",
                      systemImage: "waveform.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

extension String {
    fileprivate var fullRange: NSRange {
        NSRange(startIndex..., in: self)
    }
}
