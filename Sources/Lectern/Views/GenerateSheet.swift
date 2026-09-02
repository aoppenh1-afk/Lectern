import SwiftData
import SwiftUI

/// Sheet that kicks off study-material generation for a lecture.
struct GenerateSheet: View {
    let lecture: Lecture

    @Environment(GenerationService.self) private var generation
    @Environment(\.dismiss) private var dismiss

    @State private var cleanedTranscriptOn = true
    @State private var notesOn = true
    @State private var flashcardsOn = false
    @State private var quizOn = false
    @State private var quizFormat: QuizOptions.Format = .mixed
    @State private var quizLength: QuizOptions.Length = .standard
    @AppStorage("generation.agentID") private var profileID = AgentProfiles.codexID
    @AppStorage("generation.thinkingLevel") private var thinkingLevelRaw = ThinkingLevel.medium.rawValue
    @State private var modelSelection = ""          // "" = agent default; model id; "__custom"
    @State private var customModelText = ""         // free-form model id
    @State private var catalog = AgentModelCatalog.empty
    @State private var catalogLoading = false
    @State private var modelSearch = ""
    @State private var pickerOpen = false
    @State private var providerFilter: String? = nil
    @State private var hoveredModelID: String? = nil
    @State private var focusText = ""
    @State private var finished = false
    @State private var requestedKinds: [GenerationJobKind] = []

    private let cardBorder = Color.primary.opacity(0.08)

    private var profiles: [AgentProfile] { AgentProfiles.all() }
    private var thinkingLevel: ThinkingLevel {
        ThinkingLevel(rawValue: thinkingLevelRaw) ?? .medium
    }
    private var selectedProfile: AgentProfile? {
        profiles.first(where: { $0.id == profileID })
    }
    private var isAntigravityProfile: Bool {
        profileID == AgentProfiles.antigravityID
    }
    private var catalogIDs: [String] { catalog.models.map(\.id) }
    private var selectedModel: AgentModel? {
        catalog.models.first(where: { $0.id == modelSelection })
            ?? catalog.models.first(where: \.isDefault)
            ?? catalog.models.first
    }
    private var availableThinkingLevels: [ThinkingLevel] {
        ThinkingLevel.chatOptions(
            profileID: profileID,
            advertised: selectedModel?.supportedThinkingLevels ?? []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch viewState {
            case .selection: selectionView
            case .running: runningView
            case .finished: completionView
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(LecternTheme.paper)
        .onAppear {
            loadStoredModel()
            refreshCatalog()
        }
        .onChange(of: profileID) { _, _ in
            loadStoredModel()
            refreshCatalog()
        }
        .onChange(of: modelSelection) { _, _ in
            syncThinkingFromSelectedModel()
        }
        .onChange(of: thinkingLevelRaw) { _, _ in
            applyThinkingToSelectedModel()
        }
        .onChange(of: viewState) { old, new in
            guard old == .running, new != .running else { return }
            if generation.lastError == nil {
                dismiss()
            } else {
                finished = true
            }
        }
    }

    private enum ViewState { case selection, running, finished }

    private var viewState: ViewState {
        if generation.activeJob != nil { return .running }
        return finished ? .finished : .selection
    }

    // MARK: - Selection

    private var selectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Generate study materials")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text(lecture.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            outputsCard
            agentCard

            if quizOn {
                focusCard
            }

            if let profile = selectedProfile,
               AgentProfiles.resolveExecutable(profile.executablePath) == nil {
                Label("\(profile.title) wasn't found — set its spawn command in Settings › Agents.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LecternTheme.warningTint)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Generate") { start() }
                    .keyboardShortcut(.defaultAction)
                    .prominentAction()
                    .tint(LecternTheme.accent)
                    .disabled(!cleanedTranscriptOn && !notesOn && !flashcardsOn && !quizOn)
            }
        }
    }

    private var outputsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Outputs")
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

            toggleRow(title: "Cleaned Transcript",
                      detail: "Repaired prose in paragraphs, without timestamps",
                      isOn: $cleanedTranscriptOn)
            cardDivider
            toggleRow(title: "Notes",
                      detail: "Bullet study notes with a summary",
                      isOn: $notesOn)
            cardDivider
            toggleRow(title: "Flashcards",
                      detail: "Atomic Q&A, exported to Anki",
                      isOn: $flashcardsOn)
            cardDivider
            toggleRow(title: "Quiz",
                      detail: "Practice questions for self-testing",
                      isOn: $quizOn)

            if quizOn {
                cardDivider
                HStack {
                    Picker("Format", selection: $quizFormat) {
                        ForEach(QuizOptions.Format.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    Spacer()
                    Picker("Length", selection: $quizLength) {
                        ForEach(QuizOptions.Length.allCases) { length in
                            Text(length.title).tag(length)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }

    private var agentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Agent")
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(profiles) { profile in
                agentRow(profile)
                if profile.id != profiles.last?.id {
                    cardDivider
                }
            }
            cardDivider

            HStack(alignment: .center, spacing: 12) {
                Text("Model")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LecternTheme.ink)
                Spacer(minLength: 8)
                modelControl
                    .frame(maxWidth: 260)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            cardDivider

            if !availableThinkingLevels.isEmpty {
                cardDivider

                HStack {
                    Text("Thinking")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LecternTheme.ink)
                    Spacer()
                    Picker("", selection: $thinkingLevelRaw) {
                        ForEach(availableThinkingLevels) { level in
                            Text(level.title).tag(level.rawValue)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 130)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
    }

    private func agentRow(_ profile: AgentProfile) -> some View {
        let isSelected = profileID == profile.id
        let installed = AgentProfiles.resolveExecutable(profile.executablePath) != nil
        return Button {
            profileID = profile.id
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(isSelected ? LecternTheme.accent : Color.primary.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .background {
                        if isSelected {
                            Circle().fill(LecternTheme.accent).frame(width: 8, height: 8)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(LecternTheme.ink)
                    Text(installed ? "Ready" : "Not installed")
                        .font(.system(size: 10.5))
                        .foregroundStyle(installed ? Color.secondary : LecternTheme.warningTint)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modelControl: some View {
        if catalogLoading && catalog.models.isEmpty {
            ProgressView()
                .controlSize(.small)
        } else if catalog.models.isEmpty {
            TextField(profileID == AgentProfiles.opencodeID
                      ? "provider/model (empty = default)"
                      : "model id (empty = default)",
                      text: $customModelText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                modelMenuButton
                if modelSelection == "__custom" {
                    TextField(profileID == AgentProfiles.opencodeID ? "provider/model" : "Model id",
                              text: $customModelText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }
        }
    }

    private var modelMenuButton: some View {
        Button {
            pickerOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(modelPickerLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(LecternTheme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            modelSearchPopover
                .onDisappear {
                    modelSearch = ""
                    providerFilter = nil
                    hoveredModelID = nil
                }
        }
    }

    private var modelPickerLabel: String {
        if modelSelection == "__custom" { return customModelText.isEmpty ? "Custom…" : customModelText }
        if modelSelection.isEmpty { return "Agent default" }
        if let model = catalog.models.first(where: { $0.id == modelSelection }) {
            return model.name
        }
        return modelSelection
    }

    private var catalogProviders: [String] {
        let names = catalog.models.compactMap(\.provider).filter { !$0.isEmpty }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.sorted(by: providerSort)
    }

    private var filteredCatalog: [AgentModel] {
        var models = catalog.models
        if let providerFilter {
            models = models.filter { $0.provider == providerFilter }
        }
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter { $0.searchText.contains(query) }
    }

    private var groupedFilteredCatalog: [(provider: String, models: [AgentModel])] {
        let groups = Dictionary(grouping: filteredCatalog, by: { $0.provider ?? "" })
        let keys = groups.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return providerSort(lhs, rhs)
        }
        return keys.map { key in
            (key.isEmpty ? "Models" : key, groups[key] ?? [])
        }
    }

    private var modelSearchPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search models", text: $modelSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if catalogProviders.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        providerChip("All", selected: providerFilter == nil) {
                            providerFilter = nil
                        }
                        ForEach(catalogProviders, id: \.self) { provider in
                            providerChip(provider, selected: providerFilter == provider) {
                                providerFilter = providerFilter == provider ? nil : provider
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    modelPickerRow(
                        id: "",
                        title: "Agent default",
                        subtitle: "Use the agent's configured model",
                        selected: modelSelection.isEmpty
                    ) {
                        modelSelection = ""
                        customModelText = ""
                        pickerOpen = false
                    }

                    if filteredCatalog.isEmpty {
                        Text(modelSearch.isEmpty ? "No models available." : "No models match “\(modelSearch)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(groupedFilteredCatalog, id: \.provider) { group in
                            if groupedFilteredCatalog.count > 1 || group.provider != "Models" {
                                Text(group.provider)
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.4)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 3)
                            }
                            ForEach(group.models) { model in
                                modelPickerRow(
                                    id: model.id,
                                    title: model.name,
                                    subtitle: model.id == model.name ? nil : model.id,
                                    selected: modelSelection == model.id
                                ) {
                                    modelSelection = model.id
                                    customModelText = ""
                                    pickerOpen = false
                                }
                            }
                        }
                    }

                    if !isAntigravityProfile {
                        Divider().padding(.vertical, 4)

                        modelPickerRow(
                            id: "__custom",
                            title: "Custom…",
                            subtitle: "Enter a model id",
                            selected: modelSelection == "__custom"
                        ) {
                            modelSelection = "__custom"
                            pickerOpen = false
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 340, height: catalog.models.count > 10 ? 420 : 280)
    }

    private func providerChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? LecternTheme.accent : LecternTheme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? LecternTheme.accent.opacity(0.14) : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func providerSort(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ value: String) -> Int {
            switch value.lowercased() {
            case "opencode": return 0
            case "openai": return 1
            default: return 2
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private func modelPickerRow(id: String, title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        let hovered = hoveredModelID == id
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LecternTheme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(LecternTheme.ink)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle == nil ? 6 : 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered || selected ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering in
            hoveredModelID = hovering ? id : (hoveredModelID == id ? nil : hoveredModelID)
        }
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Quiz focus · optional")
            TextEditor(text: $focusText)
                .font(.system(size: 12.5))
                .frame(minHeight: 56, maxHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(cardBorder, lineWidth: 1)
                )
            Text("Steer the quiz: topic areas to emphasize, question style, difficulty — e.g. “focus on enzyme kinetics, more application questions”.")
                .font(.system(size: 10.5))
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func loadStoredModel() {
        let stored = selectedProfile?.model ?? ""
        applyStoredModel(stored)
        syncThinkingFromSelectedModel()
    }

    private func applyStoredModel(_ stored: String) {
        if catalogIDs.contains(stored), !stored.isEmpty {
            modelSelection = stored
            customModelText = ""
        } else if stored.isEmpty {
            modelSelection = ""
            customModelText = ""
        } else {
            modelSelection = catalog.models.isEmpty ? stored : "__custom"
            customModelText = stored
        }
    }

    private func syncThinkingFromSelectedModel() {
        let modelID: String
        if !modelSelection.isEmpty, modelSelection != "__custom" {
            modelID = modelSelection
        } else if !customModelText.isEmpty {
            modelID = customModelText
        } else {
            modelID = selectedProfile?.model ?? AntigravityCLI.modelID
        }
        guard AntigravityCLI.isThinkingVariant(modelID) else {
            let levels = availableThinkingLevels
            if !levels.isEmpty, !levels.contains(thinkingLevel) {
                thinkingLevelRaw = (selectedModel?.defaultThinkingLevel ?? levels[0]).rawValue
            }
            return
        }
        let next = AntigravityCLI.thinkingLevel(fromModelID: modelID).rawValue
        if thinkingLevelRaw != next {
            thinkingLevelRaw = next
        }
    }

    private func applyThinkingToSelectedModel() {
        guard isAntigravityProfile else { return }
        let current: String
        if !modelSelection.isEmpty, modelSelection != "__custom" {
            current = modelSelection
        } else if !customModelText.isEmpty {
            current = customModelText
        } else {
            current = selectedProfile?.model ?? AntigravityCLI.modelID
        }
        let next = AntigravityCLI.applyThinking(thinkingLevel, to: current, availableIDs: catalogIDs)
        guard next != current else { return }
        if catalogIDs.contains(next) {
            modelSelection = next
            customModelText = ""
        } else if modelSelection == "__custom" || catalog.models.isEmpty {
            customModelText = next
        }
    }

    private func refreshCatalog() {
        guard let profile = selectedProfile else { return }
        let id = profile.id
        catalogLoading = true
        modelSearch = ""
        providerFilter = nil
        hoveredModelID = nil
        Task {
            let loaded = await AgentModelCatalogLoader.load(for: profile)
            await MainActor.run {
                guard profileID == id else { return }
                catalog = loaded
                catalogLoading = false
                applyStoredModel(selectedProfile?.model ?? customModelText)
                syncThinkingFromSelectedModel()
            }
        }
    }

    private func start() {
        var kinds: [GenerationJobKind] = []
        if cleanedTranscriptOn { kinds.append(.cleanedTranscript) }
        if notesOn { kinds.append(.notes) }
        if flashcardsOn { kinds.append(.flashcards) }
        if quizOn { kinds.append(.quiz) }
        requestedKinds = kinds

        guard let profile = selectedProfile else { return }

        var resolvedModel: String?
        if catalog.models.isEmpty {
            resolvedModel = customModelText.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : customModelText.trimmingCharacters(in: .whitespaces)
        } else if modelSelection == "__custom" {
            resolvedModel = customModelText.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : customModelText.trimmingCharacters(in: .whitespaces)
        } else {
            resolvedModel = modelSelection.isEmpty ? nil : modelSelection
        }
        if isAntigravityProfile {
            let base = resolvedModel ?? profile.model ?? AntigravityCLI.modelID
            resolvedModel = AntigravityCLI.applyThinking(thinkingLevel, to: base, availableIDs: catalogIDs)
        }
        AgentProfiles.setModel(resolvedModel, for: profile.id)

        let focus = focusText.trimmingCharacters(in: .whitespacesAndNewlines)

        finished = false
        generation.generate(lecture: lecture,
                            kinds: kinds,
                            profile: profile,
                            quizOptions: QuizOptions(format: quizFormat, length: quizLength),
                            thinkingLevel: thinkingLevel,
                            modelOverride: resolvedModel,
                            quizFocus: quizOn && !focus.isEmpty ? focus : nil)
    }

    // MARK: - Running (staged pipeline)

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LecternTheme.processingTint)
                    Text("Generating…")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                }
                Text(lecture.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(requestedKinds.enumerated()), id: \.element) { index, kind in
                    pipelineStage(kind,
                                  isFirst: index == 0,
                                  isLast: index == requestedKinds.count - 1)
                }
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

            if let error = generation.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(LecternTheme.warningTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Close keeps generation running in the background.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel generation", role: .destructive) {
                    generation.cancel()
                    dismiss()
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private enum StageState { case queued, active, done }

    private func stageState(_ kind: GenerationJobKind) -> StageState {
        guard let remaining = generation.activeJob?.remaining else { return .queued }
        if remaining.first == kind { return .active }
        if remaining.contains(kind) { return .queued }
        return .done
    }

    private func pipelineStage(_ kind: GenerationJobKind, isFirst: Bool, isLast: Bool) -> some View {
        let state = stageState(kind)
        let connectorUp: Color = isFirst ? .clear : (state == .queued ? LecternTheme.hairline : LecternTheme.successTint.opacity(0.55))
        let connectorDown: Color = isLast ? .clear : (state == .done ? LecternTheme.successTint.opacity(0.55) : LecternTheme.hairline)

        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(connectorUp)
                    .frame(width: 1, height: 8)
                stageMarker(state)
                Rectangle()
                    .fill(connectorDown)
                    .frame(width: 1, height: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 13, weight: state == .queued ? .regular : .medium))
                    .foregroundStyle(state == .queued ? Color.secondary : LecternTheme.ink)
                Text(stageCaption(kind, state: state))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func stageMarker(_ state: StageState) -> some View {
        ZStack {
            switch state {
            case .done:
                Circle()
                    .fill(LecternTheme.successTint)
                    .frame(width: 15, height: 15)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                ProgressView()
                    .controlSize(.mini)
                    .tint(LecternTheme.processingTint)
                    .frame(width: 15, height: 15)
            case .queued:
                Circle()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 13, height: 13)
            }
        }
        .frame(width: 15, height: 16)
    }

    private func stageCaption(_ kind: GenerationJobKind, state: StageState) -> String {
        switch state {
        case .done: return "Done"
        case .queued: return "Queued"
        case .active:
            switch kind {
            case .cleanedTranscript: return "Writing a cleaned prose transcript…"
            case .notes: return "Rewriting into study notes…"
            case .flashcards: return "Distilling atomic Q&A…"
            case .quiz: return "Writing practice questions…"
            }
        }
    }

    // MARK: - Done

    private var completionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: generation.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(generation.lastError == nil ? LecternTheme.successTint : LecternTheme.warningTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(generation.lastError == nil ? "Materials ready" : "Finished with errors")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                    if let error = generation.lastError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .prominentAction()
                    .tint(LecternTheme.accent)
            }
        }
    }
}
