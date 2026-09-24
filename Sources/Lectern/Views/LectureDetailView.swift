import AppKit
import SwiftData
import SwiftUI

struct LectureDetailView: View {
    @Environment(TranscriptionService.self) private var transcription
    @Environment(TranscriptionPreferences.self) private var transcriptionPreferences
    @Environment(GenerationService.self) private var generation
    @Environment(CardSyncService.self) private var cardSync
    @Environment(LectureAudioPlayer.self) private var audioPlayer
    @Environment(ShiurAutomationService.self) private var automationService
    @Environment(\.modelContext) private var modelContext

    @Bindable var lecture: Lecture
    let onAttachFiles: () -> Void
    let onGenerate: () -> Void

    @State private var selectedTab: Tab = .rawTranscript
    @State private var jumpBookmarkOffset: Double?
    @State private var jumpRequest = UUID()
    @State private var antigravityCatalog = AgentModelCatalog.empty
    @State private var transcriptionPickerOpen = false
    @State private var transcriptionModelSearch = ""
    @State private var hoveredTranscriberID: String?
    @State private var localAvailability = LocalModelAvailability()

    enum Tab: Hashable {
        case rawTranscript, cleanedTranscript, notes, flashcards, quiz, bookmarks, attachments
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    statusArea
                    generationStatusArea
                    transcriptProvenance
                    tabBar
                    artifactContent
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: LecternTheme.readingWidth + 56)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: jumpRequest) { _, _ in
                guard let offset = jumpBookmarkOffset,
                      let raw = lecture.artifact(of: .rawTranscript)?.content,
                      let index = TranscriptParagraph.closestIndex(
                        to: offset, in: TranscriptParagraph.parse(raw)) else { return }
                withAnimation { scrollProxy.scrollTo("transcript-\(index)", anchor: .center) }
            }
        }
        .task {
            _ = transcription.recoverCompletedLocalCheckpointIfPossible(lecture)
            localAvailability.refresh()
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

            if let sourceSummary = lecture.sourceProvenanceSummary {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(LecternTheme.accent)
                    Text(sourceSummary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LecternTheme.ink)

                    Spacer()

                    if let pageURLString = lecture.sourcePageURL,
                       let pageURL = URL(string: pageURLString) {
                        Link(destination: pageURL) {
                            HStack(spacing: 4) {
                                Text("View on YU Torah")
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(LecternTheme.accent)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                        Text(lecture.statusMessage ?? "Recording saved")
                            .font(.system(size: 13, weight: .medium))
                        Text("Transcription will start only when you choose it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    recordingLanguagePicker
                    Button("Transcribe") {
                        transcription.retranscribe(lecture, as: lecture.language)
                    }
                    .prominentAction()
                    .tint(LecternTheme.accent)
                    .disabled(transcription.isQueuedOrRunning(lectureID: lecture.persistentModelID)
                              || transcription.isCancelling(lectureID: lecture.persistentModelID))
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
                        Text(liveStatusMessage)
                            .font(.system(size: 13, weight: .medium))
                        Text(liveTranscribingSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if let fraction = transcription.progressByLecture[lecture.persistentModelID]?.fractionCompleted {
                            ProgressView(value: fraction)
                                .tint(LecternTheme.processingTint)
                                .accessibilityLabel("Transcription progress")
                                .accessibilityValue("\(Int(fraction * 100)) percent")
                        }
                        if let started = transcription.progressByLecture[lecture.persistentModelID]?.startedAt {
                            Text("\(started, style: .relative) elapsed")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    CancelJobButton(isCancelling: transcription.isCancelling(lectureID: lecture.persistentModelID)) {
                        transcription.cancelTranscription(for: lecture)
                    }
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

    @ViewBuilder
    private var generationStatusArea: some View {
        if let job = generation.job(for: lecture.persistentModelID) {
            SurfaceCard(padding: 14) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generating study materials")
                            .font(.system(size: 13, weight: .medium))
                        Text(job.remaining.map(\.title).joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CancelJobButton(isCancelling: generation.isCancelling(lecture.persistentModelID)) {
                        generation.cancel(lectureID: lecture.persistentModelID)
                    }
                }
            }
        } else if let warning = generation.warnings[lecture.persistentModelID] {
            SurfaceCard(padding: 14) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(LecternTheme.warningTint)
            }
        }
    }

    /// Title for the transcribing hero. Prefers the service's live state so a
    /// fallback hop repaints immediately; falls back to the persisted message.
    private var liveStatusMessage: String {
        if let live = transcription.progressByLecture[lecture.persistentModelID]?.message, !live.isEmpty {
            return live
        }
        return lecture.statusMessage ?? "Transcribing on-device"
    }

    /// Subtitle for the transcribing hero. The plan-derived subtitle is static
    /// for local plans, so prefer the service's live subtitle which tracks the
    /// actual running attempt (e.g. Antigravity vs on-device fallback).
    private var liveTranscribingSubtitle: String {
        if let live = transcription.progressByLecture[lecture.persistentModelID]?.subtitle, !live.isEmpty {
            return live
        }
        return transcribingSubtitle
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

    private var recordingLanguagePicker: some View {
        HStack(spacing: 0) {
            recordingLanguageOption(.english, label: "A", help: "English")
            recordingLanguageOption(.hebrewEnglish, label: "A/א", help: "English and Hebrew")
        }
        .padding(2)
        .background(Color.primary.opacity(0.035), in: Capsule())
        .overlay(Capsule().stroke(LecternTheme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio language")
    }

    private func recordingLanguageOption(
        _ language: LectureLanguage,
        label: String,
        help: String
    ) -> some View {
        Button {
            lecture.language = language
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(lecture.language == language ? LecternTheme.accent : LecternTheme.ink)
                .frame(width: 45, height: 30)
                .background(
                    lecture.language == language ? LecternTheme.accent.opacity(0.13) : Color.clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .accessibilityAddTraits(lecture.language == language ? .isSelected : [])
        .help(help)
    }

    @ViewBuilder
    private var transcriptProvenance: some View {
        if lecture.status == .ready,
           let provider = lecture.transcriptConnectionName,
           let model = lecture.transcriptModelID {
            ViewThatFits(in: .horizontal) {
                // Keep the original single-row height when the detail pane is narrow.
                HStack(spacing: 10) {
                    transcriptProvenanceInfo(provider: provider, model: model)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    transcriptProvenanceActions
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: 10) {
                    transcriptProvenanceInfo(provider: provider, model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    compactProvenanceActions
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func transcriptProvenanceInfo(provider: String, model: String) -> some View {
        HStack(spacing: 12) {
            Group {
                if let providerID = lecture.transcriptProviderRaw.flatMap(TranscriptionProviderID.init(rawValue:)),
                   providerID != .local {
                    ProviderLogo(provider: providerID, size: 28)
                } else {
                    Image(systemName: "macbook")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribed with \(provider)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text([model, lecture.transcriptCompletedAt?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fallback = lecture.transcriptFallbackSummary {
                    Text(fallback)
                        .font(.system(size: 10))
                        .foregroundStyle(LecternTheme.warningTint)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var transcriptProvenanceActions: some View {
        HStack(spacing: 8) {
            transcribeAgainButton(compact: false)
            generateCleanTranscriptAndNotesButton(compact: false)
        }
    }

    private var compactProvenanceActions: some View {
        HStack(spacing: 6) {
            transcribeAgainButton(compact: true)
            generateCleanTranscriptAndNotesButton(compact: true)
        }
    }

    private func transcribeAgainButton(compact: Bool) -> some View {
        transcriptionPickerButton {
            Group {
                if compact {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Label("Transcribe again", systemImage: "arrow.clockwise")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(LecternTheme.ink)
            .frame(width: compact ? 28 : nil, height: 28)
            .padding(.horizontal, compact ? 0 : 10)
            .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .disabled(lecture.recording?.isPruned != false
                  || transcription.isQueuedOrRunning(lectureID: lecture.persistentModelID)
                  || transcription.isCancelling(lectureID: lecture.persistentModelID))
        .accessibilityLabel("Transcribe again")
        .help("Choose a transcriber and transcribe this recording again")
    }

    private func generateCleanTranscriptAndNotesButton(compact: Bool) -> some View {
        Button(action: onGenerate) {
            Group {
                if compact {
                    Image(systemName: "doc.text")
                } else {
                    Label("Generate clean transcription & notes", systemImage: "doc.text")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: compact ? 28 : nil, height: 28)
            .padding(.horizontal, compact ? 0 : 10)
            .background(Color(hex: "2168ED"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(generation.job(for: lecture.persistentModelID) != nil)
        .accessibilityLabel("Generate clean transcription and notes")
        .help("Generate clean transcription & notes")
    }

    private func transcriptionChoiceMenu(label: String) -> some View {
        transcriptionPickerButton {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(LecternTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 160)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
    }

    private func transcriptionPickerButton<Content: View>(@ViewBuilder label: () -> Content) -> some View {
        Button {
            localAvailability.refresh()
            transcriptionPickerOpen.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $transcriptionPickerOpen, arrowEdge: .top) {
            transcriptionPicker
                .onDisappear {
                    transcriptionModelSearch = ""
                    hoveredTranscriberID = nil
                }
        }
    }

    private var transcriptionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a transcriber")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text("Run locally on this Mac or use a connected API.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search models", text: $transcriptionModelSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !filteredBuiltInModels.isEmpty {
                        transcriptionPickerSection("On this Mac")
                        ForEach(filteredBuiltInModels) { model in
                            let downloaded = localAvailability.isDownloaded(model)
                            transcriptionPickerRow(
                                id: model.id,
                                title: model.title,
                                subtitle: downloaded
                                    ? "Private, on-device transcription"
                                    : "Not downloaded — get it in Settings › Transcription",
                                enabled: downloaded
                            ) {
                                Image(systemName: downloaded ? "macbook" : "arrow.down.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(downloaded ? LecternTheme.accent : .secondary)
                            } action: {
                                chooseLocalTranscriber(model.id)
                            }
                        }
                    }

                    if !filteredAntigravityModels.isEmpty {
                        transcriptionPickerSection("Antigravity ACP")
                        ForEach(filteredAntigravityModels) { model in
                            transcriptionPickerRow(
                                id: model.id,
                                title: model.name,
                                subtitle: model.id == model.name ? "Runs through Antigravity ACP" : model.id
                            ) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LecternTheme.processingTint)
                            } action: {
                                chooseLocalTranscriber(model.id)
                            }
                        }
                    }

                    if !filteredTranscriptionConnections.isEmpty {
                        transcriptionPickerSection("API connections")
                        ForEach(filteredTranscriptionConnections) { connection in
                            transcriptionPickerRow(
                                id: "connection-\(connection.id)",
                                title: connection.displayName,
                                subtitle: connection.modelID
                            ) {
                                ProviderLogo(provider: connection.provider, size: 26)
                            } action: {
                                chooseAPITranscriber(connection.id)
                            }
                        }
                    }

                    if filteredBuiltInModels.isEmpty,
                       filteredAntigravityModels.isEmpty,
                       filteredTranscriptionConnections.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17))
                                .foregroundStyle(.tertiary)
                            Text("No models match \"\(transcriptionModelSearch)\".")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .frame(width: 380, height: 440)
        .background(LecternTheme.paper)
    }

    private func transcriptionPickerSection(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func transcriptionPickerRow<Icon: View>(
        id: String,
        title: String,
        subtitle: String,
        enabled: Bool = true,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                icon()
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(enabled ? LecternTheme.ink : .secondary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: enabled ? "arrow.right" : "arrow.down.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoveredTranscriberID == id && enabled ? Color.primary.opacity(0.055) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .padding(.horizontal, 5)
        .onHover { hovering in
            hoveredTranscriberID = hovering ? id : nil
        }
    }

    private var filteredBuiltInModels: [BuiltInTranscriptionModel] {
        BuiltInTranscriptionModel.allCases.filter { model in
            !model.usesAntigravity && transcriptionSearchMatches(model.title, model.id)
        }
    }

    private var filteredAntigravityModels: [AgentModel] {
        antigravityMenuModels.filter { model in
            transcriptionSearchMatches(model.name, model.id, model.provider ?? "")
        }
    }

    private var filteredTranscriptionConnections: [TranscriptionConnection] {
        transcriptionPreferences.connections.filter { connection in
            connection.enabled && transcriptionSearchMatches(
                connection.displayName,
                connection.modelID,
                connection.provider.rawValue
            )
        }
    }

    private func transcriptionSearchMatches(_ values: String...) -> Bool {
        let query = transcriptionModelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func chooseLocalTranscriber(_ modelID: String) {
        // Defensive: the picker disables missing models, but the stored
        // default can still point at one that was deleted from disk.
        if let model = BuiltInTranscriptionModel(rawValue: modelID),
           !model.usesAntigravity,
           !localAvailability.isDownloaded(model) {
            return
        }
        transcriptionPickerOpen = false
        transcription.retranscribe(
            lecture,
            as: lecture.language,
            source: .local,
            builtInModelID: modelID
        )
    }

    private func chooseAPITranscriber(_ connectionID: UUID) {
        transcriptionPickerOpen = false
        transcription.retranscribe(
            lecture,
            as: lecture.language,
            source: .external,
            connectionID: connectionID
        )
    }

    private var antigravityMenuModels: [AgentModel] {
        if antigravityCatalog.models.isEmpty {
            return [
                AgentModel(
                    id: AntigravityACPClient.modelID,
                    name: AntigravityACPClient.displayName,
                    provider: "Google",
                    isDefault: true,
                    supportedThinkingLevels: AntigravityACPClient.thinkingLevels,
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
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "lectern", url.host == "bookmark",
                                  let milliseconds = Double(url.lastPathComponent) else {
                                return .systemAction
                            }
                            let offset = milliseconds / 1_000
                            jumpToBookmark(offset)
                            return .handled
                        })
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
                        jumpToBookmark(bookmark.offset)
                    } label: {
                        Text(Self.bookmarkTime(bookmark.offset))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LecternTheme.accent)

                    Image(systemName: bookmark.kind.symbol)
                        .foregroundStyle(bookmark.kind == .quiz ? .orange : LecternTheme.accent)
                    Text(bookmark.note.isEmpty
                         ? bookmark.kind.title
                         : "\(bookmark.kind.title): \(bookmark.note)")
                        .font(.system(size: 13))
                    Spacer()
                    Menu {
                        ForEach(LiveBookmarkKind.allCases) { kind in
                            Button(kind.title) { bookmark.kind = kind }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Change flag type")
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

    private func jumpToBookmark(_ offset: TimeInterval) {
        if lecture.artifact(of: .rawTranscript) != nil {
            selectedTab = .rawTranscript
            jumpBookmarkOffset = offset
            jumpRequest = UUID()
        }
        if lecture.recording?.isPruned == false {
            audioPlayer.play(lecture, from: offset)
        }
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
    @Environment(ShiurAutomationService.self) private var automationService

    let lecture: Lecture
    let content: String

    private var paragraphs: [TranscriptParagraph] { TranscriptParagraph.parse(content) }

    private func bookmarksByParagraph(_ parsed: [TranscriptParagraph]) -> [Int: [LiveBookmark]] {
        return Dictionary(grouping: lecture.orderedBookmarks) { bookmark in
            TranscriptParagraph.closestIndex(to: bookmark.offset, in: parsed) ?? 0
        }
    }

    var body: some View {
        let playable = lecture.recording?.isPruned == false
        let paragraphs = self.paragraphs
        let bookmarksByParagraph = self.bookmarksByParagraph(paragraphs)
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

            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
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

                    if let bookmarks = bookmarksByParagraph[index] {
                        TranscriptBookmarkMarker(bookmarks: bookmarks, lecture: lecture)
                    }
                }
                .id("transcript-\(index)")
            }

            if !playable {
                HStack {
                    Label("Recording audio was pruned; timestamps are no longer clickable.",
                          systemImage: "waveform.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    if lecture.sourceMediaURL != nil || lecture.sourcePageURL != nil {
                        Button("Redownload Audio") {
                            Task {
                                try? await automationService.redownloadAudio(for: lecture)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(LecternTheme.accent)
                    }
                }
            }
        }
    }
}

private struct TranscriptBookmarkMarker: View {
    @Environment(LectureAudioPlayer.self) private var audioPlayer
    let bookmarks: [LiveBookmark]
    let lecture: Lecture
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "bookmark.fill")
                if bookmarks.count > 1 { Text("\(bookmarks.count)") }
            }
            .font(.system(size: 10))
            .foregroundStyle(bookmarks.contains(where: { $0.kind == .quiz }) ? .orange : LecternTheme.accent)
            .opacity(0.65)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(bookmarks.count) transcript flag\(bookmarks.count == 1 ? "" : "s")")
        .help(bookmarks.map { bookmark in
            "\(bookmark.kind.title) · \(TranscriptParagraph.timeLabel(bookmark.offset))"
                + (bookmark.note.isEmpty ? "" : " · \(bookmark.note)")
        }.joined(separator: "\n"))
        .popover(isPresented: $showingDetail) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(bookmarks) { bookmark in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(bookmark.kind.title).fontWeight(.semibold)
                            Spacer()
                            Text(TranscriptParagraph.timeLabel(bookmark.offset))
                                .font(.system(.caption, design: .monospaced))
                        }
                        if !bookmark.note.isEmpty { Text(bookmark.note) }
                        if lecture.recording?.isPruned == false {
                            Button("Play from here") {
                                audioPlayer.play(lecture, from: bookmark.offset)
                                showingDetail = false
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(12)
            .frame(minWidth: 220, alignment: .leading)
        }
    }
}

extension String {
    fileprivate var fullRange: NSRange {
        NSRange(startIndex..., in: self)
    }
}
