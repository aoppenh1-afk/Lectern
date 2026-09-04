import SwiftData
import SwiftUI

struct SubscriptionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(TranscriptionPreferences.self) private var transcriptionPreferences
    @Environment(ShiurAutomationService.self) private var automationService

    @Query(sort: \Course.name) private var courses: [Course]

    let existingSubscription: ShiurSubscription?
    let targetType: ShiurSubscriptionTargetType
    let targetNumericID: Int?
    let displayName: String
    let feedURL: URL
    let originalURL: String?
    let previewItems: [RemoteShiurItem]

    enum CadenceMode: String, CaseIterable {
        case daily = "Daily"
        case custom = "Custom"
    }

    @State private var cadenceMode: CadenceMode = .daily
    @State private var intervalHours: Int = 24
    @State private var customPresetHours: Int = 12
    @State private var selectedCourseID: PersistentIdentifier? = nil
    @State private var selectedLanguage: LectureLanguage = .hebrewEnglish
    @State private var importBaselineFutureOnly: Bool = true
    @State private var autoTranscribe: Bool = true
    @State private var autoGenerateNotes: Bool = true
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.shared.isEnabled
    @State private var showingNewCourse: Bool = false

    init(
        resolved: ResolvedSubscription,
        existing: ShiurSubscription? = nil
    ) {
        self.existingSubscription = existing
        self.targetType = resolved.targetType
        self.targetNumericID = resolved.targetNumericID
        self.displayName = resolved.displayName
        self.feedURL = resolved.feedURL
        self.originalURL = resolved.originalURL
        self.previewItems = resolved.previewItems
    }

    init(subscription: ShiurSubscription) {
        self.existingSubscription = subscription
        self.targetType = subscription.targetType
        self.targetNumericID = subscription.targetNumericID
        self.displayName = subscription.displayName
        self.feedURL = subscription.resolvedFeedURL ?? URL(string: subscription.resolvedFeedURLString)!
        self.originalURL = subscription.originalURL
        self.previewItems = []
    }

    private var selectedCourse: Course? {
        guard let id = selectedCourseID else { return nil }
        return courses.first(where: { $0.persistentModelID == id })
    }

    private var transcriberSummary: String {
        switch transcriptionPreferences.source {
        case .local:
            guard let modelID = transcriptionPreferences.builtInModelID, !modelID.isEmpty else {
                return "On this Mac (Automatic)"
            }
            if BuiltInTranscriptionModel.isAntigravityModelChoice(modelID) {
                let resolved = BuiltInTranscriptionModel.resolvedAntigravityModelID(modelID)
                if resolved == AntigravityACPClient.modelID {
                    return "Google Antigravity (\(AntigravityACPClient.displayName))"
                }
                return "Google Antigravity (\(resolved))"
            } else if let model = BuiltInTranscriptionModel(rawValue: modelID) {
                return "On this Mac (\(model.title))"
            } else {
                return "On this Mac (\(modelID))"
            }
        case .external:
            return transcriptionPreferences.defaultConnection?.displayName ?? "External API"
        case .askEachTime:
            return "Not configured (Ask each time)"
        }
    }

    private var studyAgentSummary: String {
        let profileID = UserDefaults.standard.string(forKey: "generation.agentID") ?? AgentProfiles.codexID
        return AgentProfiles.profile(id: profileID)?.title ?? "Study Agent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            previewCard
            configurationCard
            footer
        }
        .padding(24)
        .frame(width: 500)
        .background(LecternTheme.paper)
        .onAppear {
            if let existing = existingSubscription {
                intervalHours = existing.intervalHours
                if existing.intervalHours == 24 {
                    cadenceMode = .daily
                } else {
                    cadenceMode = .custom
                    customPresetHours = existing.intervalHours
                }
                selectedCourseID = existing.course?.persistentModelID
                selectedLanguage = existing.language
                autoTranscribe = existing.autoTranscribe
                autoGenerateNotes = existing.autoGenerateNotes
            }
        }
        .sheet(isPresented: $showingNewCourse) {
            NewCourseSheet { name, language in
                createNewCourse(name: name, language: language)
            }
        }
    }

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(existingSubscription == nil ? "Subscribe to \(targetType.displayName)" : "Edit Subscription")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(LecternTheme.ink)

            Text("Automatically import new shiurim, transcribe, and generate study materials.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
                Text(targetType.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LecternTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LecternTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }

            if !previewItems.isEmpty {
                Divider()
                Text("RECENT SHIURIM PREVIEW")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(previewItems.prefix(3)) { item in
                        HStack(spacing: 6) {
                            Circle().fill(LecternTheme.accent).frame(width: 4, height: 4)
                            Text(item.title)
                                .font(.system(size: 11.5))
                                .foregroundStyle(LecternTheme.ink)
                                .lineLimit(1)
                            Spacer()
                            Text(item.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Cadence
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Check frequency")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Picker("", selection: $cadenceMode) {
                        Text("Daily").tag(CadenceMode.daily)
                        Text("Custom").tag(CadenceMode.custom)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                    .onChange(of: cadenceMode) { _, newMode in
                        if newMode == .daily {
                            intervalHours = 24
                        } else {
                            intervalHours = customPresetHours
                        }
                    }
                }

                if cadenceMode == .custom {
                    HStack {
                        Text("Custom preset")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { intervalHours },
                            set: {
                                intervalHours = $0
                                customPresetHours = $0
                            }
                        )) {
                            ForEach([1, 2, 4, 6, 12, 48, 168], id: \.self) { hours in
                                Text(cadencePresetLabel(for: hours)).tag(hours)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: cadenceMode)

            Divider()

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

            // Language
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

            if existingSubscription == nil {
                Divider()

                // First-run behavior
                VStack(alignment: .leading, spacing: 6) {
                    Text("First run")
                        .font(.system(size: 12.5, weight: .medium))

                    Picker("", selection: $importBaselineFutureOnly) {
                        Text("Start with new shiurim from now on").tag(true)
                        Text("Import currently visible recent shiurim (\(previewItems.count))").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .font(.system(size: 11.5))
                }
            }

            Divider()

            // Auto-transcribe
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $autoTranscribe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically transcribe")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Transcriber: \(transcriberSummary)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if autoTranscribe && transcriptionPreferences.source == .askEachTime {
                    Label("Unattended transcription requires a default transcriber. Set one in Settings › Transcription.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LecternTheme.warningTint)
                        .padding(.top, 2)
                }
            }

            Divider()

            // Auto-notes
            Toggle(isOn: $autoGenerateNotes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate Notes after transcription")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Study agent: \(studyAgentSummary)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: autoGenerateNotes) { _, enabled in
                if enabled && !autoTranscribe {
                    autoTranscribe = true
                }
            }

            Divider()

            // Launch at login
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch Lectern at login")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Keeps background checks active across restarts")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: launchAtLogin) { _, enabled in
                LaunchAtLoginManager.shared.isEnabled = enabled
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

            Button(existingSubscription == nil ? "Subscribe" : "Save Changes") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .prominentAction()
            .tint(LecternTheme.accent)
        }
    }

    private func cadencePresetLabel(for hours: Int) -> String {
        switch hours {
        case 1: return "Every hour"
        case 2: return "Every 2 hours"
        case 4: return "Every 4 hours"
        case 6: return "Every 6 hours"
        case 12: return "Every 12 hours"
        case 24: return "Daily (24 hours)"
        case 48: return "Every 2 days"
        case 168: return "Weekly"
        default: return "Every \(hours) hours"
        }
    }

    private func save() {
        if let existing = existingSubscription {
            existing.intervalHours = intervalHours
            existing.course = selectedCourse
            existing.language = selectedLanguage
            existing.autoTranscribe = autoTranscribe
            existing.autoGenerateNotes = autoGenerateNotes
        } else {
            let sub = ShiurSubscription(
                providerRaw: "yutorah",
                targetType: targetType,
                targetNumericID: targetNumericID,
                originalURL: originalURL,
                resolvedFeedURLString: feedURL.absoluteString,
                displayName: displayName,
                isEnabled: true,
                intervalHours: intervalHours,
                course: selectedCourse,
                language: selectedLanguage,
                autoTranscribe: autoTranscribe,
                autoGenerateNotes: autoGenerateNotes,
                seenItemIDs: importBaselineFutureOnly ? Set(previewItems.map(\.shiurID)) : []
            )
            modelContext.insert(sub)

            // If user explicitly chose to import currently visible recent shiurim
            if !importBaselineFutureOnly {
                Task {
                    await automationService.checkSubscription(sub, ignoreDue: true)
                }
            }
        }

        try? modelContext.save()
        dismiss()
    }
}
