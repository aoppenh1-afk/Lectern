import SwiftUI

struct TranscriptionSettingsPane: View {
    @Environment(TranscriptionPreferences.self) private var preferences

    @State private var editingConnection: TranscriptionConnection?
    @State private var showingNewConnection = false
    @State private var testingID: UUID?
    @State private var testMessages: [UUID: String] = [:]
    @State private var antigravityCatalog = AgentModelCatalog.empty
    @State private var antigravityCatalogLoading = false

    var body: some View {
        @Bindable var preferences = preferences

        VStack(alignment: .leading, spacing: 16) {
            transcriptionSourceCard(preferences: preferences)
            connectionsCard
            fallbackCard(preferences: preferences)
        }
        .sheet(isPresented: $showingNewConnection) {
            TranscriptionConnectionEditor(connection: nil)
                .environment(preferences)
        }
        .sheet(item: $editingConnection) { connection in
            TranscriptionConnectionEditor(connection: connection)
                .environment(preferences)
        }
        .task {
            await loadAntigravityCatalog()
        }
    }

    private func transcriptionSourceCard(preferences: TranscriptionPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(
                eyebrow: "DEFAULT ROUTE",
                title: "Where new recordings are transcribed",
                detail: "This choice affects raw transcription only. Notes, cleanup, quizzes and chat keep their current agent settings."
            )

            Picker("Transcription source", selection: $preferences.source) {
                ForEach(TranscriptionSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if preferences.source == .local {
                HStack(spacing: 12) {
                    Text("Default model")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { builtInFamilyID(preferences.builtInModelID) },
                        set: { selectBuiltInFamily($0, preferences: preferences) }
                    )) {
                        Text("Automatic by lecture language").tag("")
                        ForEach(BuiltInTranscriptionModel.allCases) { model in
                            Text(model.title).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }

                if builtInFamilyID(preferences.builtInModelID) == BuiltInTranscriptionModel.antigravity.id {
                    HStack(spacing: 12) {
                        Text("Gemini model")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if antigravityCatalogLoading && antigravityCatalog.models.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Picker("", selection: Binding(
                                get: {
                                    BuiltInTranscriptionModel.resolvedAntigravityModelID(preferences.builtInModelID)
                                },
                                set: { preferences.builtInModelID = $0 }
                            )) {
                                ForEach(antigravityPickerModels) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 280)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("Thinking")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: {
                                AntigravityCLI.thinkingLevel(
                                    fromModelID: BuiltInTranscriptionModel.resolvedAntigravityModelID(preferences.builtInModelID)
                                ).rawValue
                            },
                            set: { raw in
                                let level = ThinkingLevel(rawValue: raw) ?? .high
                                let current = BuiltInTranscriptionModel.resolvedAntigravityModelID(preferences.builtInModelID)
                                preferences.builtInModelID = AntigravityCLI.applyThinking(
                                    level,
                                    to: current,
                                    availableIDs: antigravityCatalog.models.map(\.id)
                                )
                            }
                        )) {
                            ForEach(AntigravityCLI.thinkingLevels) { level in
                                Text(level.title).tag(level.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }

                if let modelID = preferences.builtInModelID {
                    let model = BuiltInTranscriptionModel.resolve(modelID, language: .english)
                    Text(antigravitySubtitle(for: model, storedID: modelID))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else if preferences.source == .external {
                HStack(spacing: 12) {
                    Text("Default connection")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: $preferences.defaultConnectionID) {
                        Text("Choose a connection").tag(UUID?.none)
                        ForEach(preferences.connections.filter(\.enabled)) { connection in
                            Label {
                                Text(connection.displayName)
                            } icon: {
                                Image(TranscriptionProviderCatalog.provider(connection.provider)?.assetName ?? "")
                            }
                            .tag(Optional(connection.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
            }
        }
        .padding(16)
        .transcriptionSettingsCard()
    }

    private var antigravityPickerModels: [AgentModel] {
        var models = antigravityCatalog.models
        if models.isEmpty {
            models = [
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
        let selected = BuiltInTranscriptionModel.resolvedAntigravityModelID(preferences.builtInModelID)
        if !models.contains(where: { $0.id == selected }) {
            models.insert(
                AgentModel(
                    id: selected,
                    name: selected,
                    provider: "Google",
                    isDefault: false,
                    supportedThinkingLevels: AntigravityCLI.isThinkingVariant(selected) ? AntigravityCLI.thinkingLevels : [],
                    defaultThinkingLevel: AntigravityCLI.isThinkingVariant(selected)
                        ? AntigravityCLI.thinkingLevel(fromModelID: selected)
                        : nil
                ),
                at: 0
            )
        }
        return models
    }

    private func builtInFamilyID(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return "" }
        return BuiltInTranscriptionModel.resolve(stored, language: .english).id
    }

    private func selectBuiltInFamily(_ familyID: String, preferences: TranscriptionPreferences) {
        if familyID.isEmpty {
            preferences.builtInModelID = nil
        } else if familyID == BuiltInTranscriptionModel.antigravity.id {
            preferences.builtInModelID = BuiltInTranscriptionModel.resolvedAntigravityModelID(
                preferences.builtInModelID
            )
        } else {
            preferences.builtInModelID = familyID
        }
    }

    private func antigravitySubtitle(for model: BuiltInTranscriptionModel, storedID: String) -> String {
        if model.usesAntigravity {
            let resolved = BuiltInTranscriptionModel.resolvedAntigravityModelID(storedID)
            if let named = antigravityCatalog.models.first(where: { $0.id == resolved }) {
                return "\(named.name) · \(model.subtitle)"
            }
            return "\(resolved) · \(model.subtitle)"
        }
        return model.subtitle
    }

    private func loadAntigravityCatalog() async {
        guard let profile = AgentProfiles.profile(id: AgentProfiles.antigravityID) else { return }
        antigravityCatalogLoading = true
        let loaded = await AgentModelCatalogLoader.load(for: profile)
        antigravityCatalog = loaded
        antigravityCatalogLoading = false
    }

    private var connectionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SettingsSectionHeader(
                    eyebrow: "CONNECTIONS",
                    title: "Your transcription providers",
                    detail: "Save API connections or use the Antigravity CLI account already signed in on this Mac."
                )
                Spacer()
                Button {
                    showingNewConnection = true
                } label: {
                    Label("Add connection", systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(LecternTheme.accent)
            }

            if preferences.connections.isEmpty {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LecternTheme.accent.opacity(0.10))
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(LecternTheme.accent)
                    }
                    .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("No external connections yet")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Parakeet, Whisper, and Antigravity transcription remain available without an API key.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(preferences.connections) { connection in
                        connectionRow(connection)
                    }
                }
            }
        }
        .padding(16)
        .transcriptionSettingsCard()
    }

    private func connectionRow(_ connection: TranscriptionConnection) -> some View {
        let provider = TranscriptionProviderCatalog.provider(connection.provider)
        let capabilities = connection.capabilities
        return HStack(spacing: 12) {
            ProviderLogo(provider: connection.provider, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(connection.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LecternTheme.ink)
                    if !connection.enabled {
                        Text("Off")
                            .providerBadge(tint: .secondary)
                    }
                }
                Text("\(provider?.name ?? connection.provider.rawValue)  ·  \(connection.modelID)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(connection.costTier.title)
                        .providerBadge(tint: connection.costTier.isPaid ? LecternTheme.warningTint : LecternTheme.successTint)
                    if capabilities.supportsDiarization { Text("Speakers").providerBadge(tint: LecternTheme.accent) }
                    if capabilities.supportsWordTimestamps { Text("Word time").providerBadge(tint: LecternTheme.accent) }
                    if capabilities.supportsCodeSwitching { Text("Mixed language").providerBadge(tint: LecternTheme.accent) }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Button {
                        test(connection)
                    } label: {
                        if testingID == connection.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Test")
                        }
                    }
                    .controlSize(.small)
                    .disabled(testingID != nil)

                    Button("Edit") { editingConnection = connection }
                        .controlSize(.small)
                }
                Text(testMessages[connection.id] ?? connectionStatus(connection))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(
                        testMessages[connection.id]?.hasPrefix("Credentials valid") == true
                            || testMessages[connection.id]?.hasPrefix("Antigravity CLI signed in") == true
                            ? LecternTheme.successTint
                            : Color.secondary.opacity(0.65)
                    )
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func fallbackCard(preferences: TranscriptionPreferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(
                eyebrow: "FALLBACKS",
                title: "A careful backup chain",
                detail: "Lectern tries one connection at a time. It never races paid providers or uploads after a local failure without permission."
            )

            Toggle("Allow fallback providers", isOn: $preferences.allowFallbackProviders)
                .font(.system(size: 12, weight: .medium))

            if preferences.allowFallbackProviders {
                VStack(spacing: 6) {
                    ForEach(Array(preferences.fallbackConnectionIDs.enumerated()), id: \.element) { index, id in
                        if let connection = preferences.connection(id: id) {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .background(Color.primary.opacity(0.06), in: Circle())
                                ProviderLogo(provider: connection.provider, size: 24)
                                Text(connection.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button { moveFallback(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.plain).disabled(index == 0)
                                Button { moveFallback(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.plain).disabled(index == preferences.fallbackConnectionIDs.count - 1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                Divider()
                Toggle("Free connections only", isOn: $preferences.freeConnectionsOnly)
                Toggle("Never fall back from free to paid", isOn: $preferences.neverFallbackFromFreeToPaid)
                Toggle("Ask before a paid fallback", isOn: $preferences.askBeforePaidFallback)
                Toggle("Allow cloud fallback after local failure", isOn: $preferences.allowCloudFallbackAfterLocalFailure)
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .transcriptionSettingsCard()
    }

    private func moveFallback(_ index: Int, by delta: Int) {
        let destination = index + delta
        guard preferences.fallbackConnectionIDs.indices.contains(destination) else { return }
        preferences.fallbackConnectionIDs.swapAt(index, destination)
    }

    private func test(_ connection: TranscriptionConnection) {
        testingID = connection.id
        testMessages[connection.id] = "Checking…"
        Task {
            let result = await ExternalTranscriptionEngine().validate(connection)
            testMessages[connection.id] = result.message
            testingID = nil
        }
    }

    private func connectionStatus(_ connection: TranscriptionConnection) -> String {
        if !connection.provider.requiresAPIKey { return "Uses Antigravity CLI sign-in" }
        return KeychainCredentialStore.maskedSuffix(reference: connection.credentialReference) ?? "No key stored"
    }
}

struct ProviderLogo: View {
    let provider: TranscriptionProviderID
    var size: CGFloat = 32

    var body: some View {
        let descriptor = TranscriptionProviderCatalog.provider(provider)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color(hex: descriptor?.tintHex ?? "777777").opacity(0.12))
            Image(descriptor?.assetName ?? "")
                .resizable()
                .scaledToFit()
                .padding(size * 0.20)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityLabel(descriptor?.name ?? provider.rawValue)
    }
}

private struct SettingsSectionHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(eyebrow)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(LecternTheme.accent)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LecternTheme.ink)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TranscriptionConnectionEditor: View {
    @Environment(TranscriptionPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TranscriptionConnection
    @State private var apiKey = ""
    @State private var customModel = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var antigravityCatalog = AgentModelCatalog.empty

    init(connection: TranscriptionConnection?) {
        let provider = connection?.provider ?? .deepgram
        let model = connection?.modelID ?? TranscriptionProviderCatalog.provider(provider)?.models.first?.id ?? ""
        _draft = State(initialValue: connection ?? .init(displayName: "Deepgram · Personal", provider: provider, modelID: model))
        _customModel = State(initialValue: connection.map { TranscriptionProviderCatalog.model(provider: $0.provider, modelID: $0.modelID) == nil } ?? false)
    }

    private var providerDescriptor: TranscriptionProviderDescriptor? {
        TranscriptionProviderCatalog.provider(draft.provider)
    }

    private var capabilities: TranscriptionCapabilities { draft.capabilities }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProviderLogo(provider: draft.provider, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.createdAt == draft.updatedAt ? "New connection" : "Edit connection")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                    Text(draft.provider.requiresAPIKey
                         ? "Keys stay in your Mac's Keychain and are read only for transcription requests."
                         : "Uses the Antigravity CLI sign-in already available on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionIdentity
                    transcriptOptions
                    consentSection

                    if let warning = capabilities.privacyWarning ?? capabilities.commercialUseWarning {
                        Label(warning, systemImage: "hand.raised.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LecternTheme.warningTint)
                            .padding(12)
                            .background(LecternTheme.warningTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(LecternTheme.warningTint)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if preferences.connection(id: draft.id) != nil {
                    Button("Remove", role: .destructive) { showingDeleteConfirmation = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save connection") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(LecternTheme.accent)
                    .disabled(
                        draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (draft.provider.requiresAPIKey
                                && apiKey.isEmpty
                                && KeychainCredentialStore.maskedSuffix(reference: draft.credentialReference) == nil)
                    )
            }
            .padding(16)
        }
        .frame(width: 560, height: 650)
        .background(LecternTheme.paper)
        .task {
            await loadAntigravityModels()
        }
        .confirmationDialog("Remove this connection?", isPresented: $showingDeleteConfirmation) {
            Button(draft.provider.requiresAPIKey ? "Remove connection and Keychain key" : "Remove connection", role: .destructive) { remove() }
        }
    }

    private var connectionIdentity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection").editorSectionTitle()
            TextField("Name, such as Groq · Free Backup", text: $draft.displayName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Picker("Provider", selection: $draft.provider) {
                    ForEach(TranscriptionProviderCatalog.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .onChange(of: draft.provider) { _, provider in
                    if provider == .antigravityCLI {
                        draft.costTier = .included
                        if let preferred = antigravityCatalog.models.first(where: \.isDefault)
                            ?? antigravityCatalog.models.first {
                            draft.modelID = preferred.id
                            customModel = false
                            return
                        }
                    }
                    if let model = TranscriptionProviderCatalog.provider(provider)?.models.first {
                        draft.modelID = model.id
                        customModel = false
                    }
                }

                if customModel {
                    TextField("Exact model ID", text: $draft.modelID)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Model", selection: $draft.modelID) {
                        ForEach(editorModels) { model in
                            Text(model.title).tag(model.id)
                        }
                    }
                }
            }

            Toggle("Use a custom model ID", isOn: $customModel)
                .font(.system(size: 11))

            if draft.provider == .antigravityCLI, AntigravityCLI.isThinkingVariant(draft.modelID) {
                Picker("Thinking", selection: Binding(
                    get: { AntigravityCLI.thinkingLevel(fromModelID: draft.modelID).rawValue },
                    set: { raw in
                        let level = ThinkingLevel(rawValue: raw) ?? .high
                        draft.modelID = AntigravityCLI.applyThinking(
                            level,
                            to: draft.modelID,
                            availableIDs: antigravityCatalog.models.map(\.id)
                        )
                    }
                )) {
                    ForEach(AntigravityCLI.thinkingLevels) { level in
                        Text(level.title).tag(level.rawValue)
                    }
                }
                .font(.system(size: 12))
            }

            if draft.provider.requiresAPIKey {
                SecureField(KeychainCredentialStore.maskedSuffix(reference: draft.credentialReference) ?? "API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            } else {
                Label("No API key required — authenticate once in the agy CLI.", systemImage: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Raw transcript options").editorSectionTitle()
            HStack {
                Picker("Language", selection: $draft.languageMode) {
                    Text("Detect automatically").tag(TranscriptionLanguageMode.automatic)
                    Text("Fixed language").tag(TranscriptionLanguageMode.fixed)
                }
                if draft.languageMode == .fixed {
                    TextField("ISO code", text: Binding($draft.languageCode, replacingNilWith: "en"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            Toggle("Speaker labels", isOn: $draft.diarizationEnabled)
                .disabled(!capabilities.supportsDiarization)
            Picker("Timestamps", selection: $draft.timestampGranularity) {
                Text("None").tag(TimestampGranularity.none)
                if capabilities.supportsSegmentTimestamps { Text("Segments").tag(TimestampGranularity.segment) }
                if capabilities.supportsWordTimestamps { Text("Words").tag(TimestampGranularity.word) }
            }
            if capabilities.supportsBatchMode {
                Picker("Processing", selection: $draft.processingMode) {
                    ForEach(TranscriptionProcessingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
            }
            Picker("Account cost", selection: $draft.costTier) {
                ForEach(ConnectionCostTier.allCases) { tier in Text(tier.title).tag(tier) }
            }
            Toggle("Connection enabled", isOn: $draft.enabled)
        }
        .font(.system(size: 12))
    }

    private var consentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio upload permission").editorSectionTitle()
            Toggle("Allow Lectern to upload recordings through this connection", isOn: $draft.cloudUploadConsent)
                .font(.system(size: 12, weight: .medium))
            Text("This transcription connection receives lecture audio only. Antigravity can be selected separately as a study-material or chat agent.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var editorModels: [TranscriptionModelDescriptor] {
        if draft.provider == .antigravityCLI, !antigravityCatalog.models.isEmpty {
            return antigravityCatalog.models.map { model in
                .init(
                    id: model.id,
                    title: model.name,
                    subtitle: model.id,
                    capabilities: TranscriptionProviderCatalog.capabilities(
                        provider: .antigravityCLI,
                        modelID: AntigravityCLI.transcriptionModelID
                    )
                )
            }
        }
        return providerDescriptor?.models ?? []
    }

    private func loadAntigravityModels() async {
        guard let profile = AgentProfiles.profile(id: AgentProfiles.antigravityID) else { return }
        antigravityCatalog = await AgentModelCatalogLoader.load(for: profile)
        if draft.provider == .antigravityCLI,
           !antigravityCatalog.models.contains(where: { $0.id == draft.modelID }),
           let preferred = antigravityCatalog.models.first(where: \.isDefault) ?? antigravityCatalog.models.first {
            draft.modelID = preferred.id
        }
    }

    private func save() {
        do {
            if draft.provider.requiresAPIKey, !apiKey.isEmpty {
                try KeychainCredentialStore.save(apiKey, reference: draft.credentialReference)
            }
            draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !capabilities.supportsDiarization { draft.diarizationEnabled = false }
            if !capabilities.supportsWordTimestamps, draft.timestampGranularity == .word { draft.timestampGranularity = .segment }
            if !capabilities.supportsBatchMode { draft.processingMode = .standard }
            preferences.upsert(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try preferences.remove(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    func transcriptionSettingsCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    func providerBadge(tint: Color) -> some View {
        font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.09), in: Capsule())
    }

    func editorSectionTitle() -> some View {
        font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(LecternTheme.ink)
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { source.wrappedValue = $0 }
        )
    }
}
