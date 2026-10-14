import AppKit
import SwiftUI

@MainActor
struct NotesStyleSettingsPane: View {
    @State private var styles: NotesStyleStore
    @State private var antigravity = AntigravityACPManager.shared
    @State private var samples: [NotesStyleSample] = []
    @State private var adjustments = ""
    @State private var profileID = UserDefaults.standard.string(forKey: "generation.agentID") ?? AgentProfiles.codexID
    @State private var model = ""
    @State private var thinking = ThinkingLevel.medium
    @State private var draft: NotesStyleDraft?
    @State private var draftSamples: [NotesStyleSample] = []
    @State private var creatorAgent = ""
    @State private var creatorModel: String?
    @State private var preview = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var operation: String?
    @State private var task: Task<Void, Never>?
    @State private var removalPresented = false

    init(store: NotesStyleStore? = nil) {
        _styles = State(initialValue: store ?? .shared)
    }

    private var profiles: [AgentProfile] {
        let commands = UserDefaults.standard.dictionary(forKey: AgentProfiles.defaultsKey) as? [String: String] ?? [:]
        let detections = AgentDetector.detectAll(commands: commands)
        return AgentProfiles.all().map { profile in
            var resolved = profile
            if let command = detections.first(where: { $0.profileID == profile.id })?.suggestedCommand {
                resolved.command = command
            }
            return resolved
        }
    }
    private var selectedProfile: AgentProfile? { profiles.first { $0.id == profileID } }
    private var canRun: Bool {
        guard let profile = selectedProfile else { return false }
        return profile.id == AgentProfiles.antigravityID
            ? antigravity.isInstalled && antigravity.isSignedIn
            : AgentProfiles.resolveExecutable(profile.executablePath) != nil
    }
    private var sampleCount: Int { samples.reduce(0) { $0 + $1.text.count } }
    private var samplesValid: Bool { (try? NotesStyleDraft.validatedSamples(samples)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            preferenceCard
            if let message = error ?? styles.loadError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(LecternTheme.warningTint)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.system(size: 12))
            }
            samplesCard
            creationCard
            if draft != nil { draftCard }
            if !preview.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Style preview").font(.headline)
                        Text("Generated from Lectern's short example lecture about study methods.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        DisclosureGroup("Read the example lecture") {
                            Text(NotesStylePrompts.previewTranscript).font(.system(size: 12))
                                .textSelection(.enabled).padding(.top, 8)
                        }
                        NotesContentView(markdown: preview)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { loadEditor() }
        .onChange(of: draft) { _, _ in preview = "" }
        .task { await antigravity.refresh() }
        .onDisappear { task?.cancel() }
        .confirmationDialog("Remove your personal style and its saved samples?", isPresented: $removalPresented) {
            Button("Remove personal style", role: .destructive) {
                perform {
                    try styles.removePersonalStyle()
                    draft = nil
                    preview = ""
                    samples = [NotesStyleSample(name: "Sample notes", text: "")]
                    notice = "Personal style removed. Default Lectern style is selected."
                }
            }
        }
    }

    private var preferenceCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Style for new notes").font(.headline)
                Picker("Saved preference", selection: Binding(
                    get: { styles.preferredSelection },
                    set: { selection in perform { try styles.select(selection) } }
                )) {
                    Text(NotesStyleSelection.lecternDefault.title).tag(NotesStyleSelection.lecternDefault)
                    Text(NotesStyleSelection.personal.title).tag(NotesStyleSelection.personal)
                        .disabled(styles.current == nil)
                }
                .pickerStyle(.segmented)
                Text("Applies to future manual and automatic generations. You can choose a different style for one lecture in Generate.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let current = styles.current {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.draft.name).font(.system(size: 13, weight: .semibold))
                            Text("Saved \(current.createdAt.formatted(date: .abbreviated, time: .shortened)) with \(current.creatorAgent)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Saved versions") {
                            ForEach(styles.revisions.filter { $0.id != current.id }) { revision in
                                Button("\(revision.draft.name) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                                    perform { try styles.restore(revision.id); loadEditor(); notice = "Earlier style restored." }
                                }
                            }
                        }.disabled(styles.revisions.count < 2 || operation != nil)
                        Button("Remove", role: .destructive) { removalPresented = true }
                            .disabled(operation != nil)
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var samplesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Your sample notes").font(.headline)
                    Spacer()
                    Button("Import notes…") { importSamples() }.disabled(operation != nil)
                    Button("Add sample") { samples.append(NotesStyleSample(name: "Sample \(samples.count + 1)", text: "")) }
                        .disabled(samples.count >= 5 || operation != nil)
                }
                Text("Paste notes that show how you write. Markdown, text, Word, RTF, and PDFs with selectable text can be imported. Check the extracted text below; document formatting may be lost.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach($samples) { $sample in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            TextField("Sample name", text: $sample.name).textFieldStyle(.roundedBorder)
                            Button("Remove") { samples.removeAll { $0.id == sample.id } }
                        }
                        TextEditor(text: $sample.text).font(.system(size: 12))
                            .frame(minHeight: 130, maxHeight: 220)
                            .padding(6).background(LecternTheme.paper)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                            .accessibilityLabel("Text for \(sample.name)")
                    }
                }
                .disabled(operation != nil)
                HStack {
                    Text("\(sampleCount.formatted()) of 60,000 characters").font(.system(size: 11))
                        .foregroundStyle(sampleCount > 60_000 ? LecternTheme.warningTint : .secondary)
                    Spacer()
                    Button("Save samples") {
                        perform { try styles.saveSamples(samples); notice = "Samples saved. Your active style changes only when you use a new style." }
                    }.disabled(!samplesValid || operation != nil)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var creationCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Create or update my style").font(.headline)
                Picker("Agent", selection: $profileID) {
                    ForEach(profiles) { profile in Text(profile.title).tag(profile.id) }
                }
                HStack {
                    TextField("Model", text: $model, prompt: Text("Agent default"))
                        .textFieldStyle(.roundedBorder)
                    Picker("Thinking", selection: $thinking) {
                        ForEach(ThinkingLevel.allCases) { level in Text(level.rawValue.capitalized).tag(level) }
                    }.frame(maxWidth: 230)
                }
                TextField("Optional adjustments", text: $adjustments,
                          prompt: Text("For example: keep my question labels, but spell out abbreviations"),
                          axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Text("Creating a style sends these samples to the selected AI provider. After saving, notes generation uses the learned instructions and short excerpts. Samples remain separate from lecture sources.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !canRun {
                    Text("Install and sign in to this agent in Settings › Agents before creating a style.")
                        .font(.system(size: 12)).foregroundStyle(LecternTheme.warningTint)
                }
                HStack {
                    if let operation {
                        ProgressView().controlSize(.small)
                        Text(operation).font(.system(size: 12))
                        Button("Cancel") { task?.cancel() }
                    }
                    Spacer()
                    Button(draft == nil ? "Create my style" : "Relearn from samples") { createStyle() }
                        .buttonStyle(.borderedProminent).tint(LecternTheme.accent)
                        .disabled(operation != nil || !canRun || !samplesValid)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var draftCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review your style").font(.headline)
                TextField("Style name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("Description", text: Binding(get: { draft?.summary ?? "" }, set: { draft?.summary = $0 }),
                          axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                Text("Style instructions").font(.system(size: 12, weight: .semibold))
                TextEditor(text: Binding(get: { draft?.instructions ?? "" }, set: { draft?.instructions = $0 }))
                    .font(.system(size: 12)).frame(minHeight: 160, maxHeight: 260)
                    .padding(6).background(LecternTheme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    .accessibilityLabel("Personal style instructions")
                DisclosureGroup("Selected example excerpts") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array((draft?.examples ?? []).enumerated()), id: \.offset) { _, text in
                            Text(text).font(.system(size: 12)).textSelection(.enabled)
                        }
                    }.padding(.top, 8)
                }
                HStack {
                    Button("Preview style") { previewStyle() }.disabled(operation != nil || !canRun)
                    Spacer()
                    Button("Save without switching") { saveStyle(activate: false) }.disabled(operation != nil)
                    Button("Use my style") { saveStyle(activate: true) }
                        .buttonStyle(.borderedProminent).tint(LecternTheme.accent).disabled(operation != nil)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(operation != nil)
    }

    private func loadEditor() {
        samples = styles.samples.isEmpty ? [NotesStyleSample(name: "Sample notes", text: "")] : styles.samples
        if let current = styles.current {
            draft = current.draft
            draftSamples = current.samples
            creatorAgent = current.creatorAgent
            creatorModel = current.creatorModel
        }
    }

    private func perform(_ action: () throws -> Void) {
        error = nil
        notice = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }

    private func importSamples() {
        let panel = NSOpenPanel()
        panel.title = "Import sample notes"
        panel.message = "Choose examples of your note style. They will not become lecture sources."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ReferenceMaterialService.supportedContentTypes
        guard panel.runModal() == .OK else { return }
        perform {
            let imported = try ReferenceMaterialService.readStyleSamples(panel.urls)
            let combined = samples.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } + imported
            samples = try NotesStyleDraft.validatedSamples(combined)
            try styles.saveSamples(samples)
        }
    }

    private func createStyle() {
        guard let profile = selectedProfile else { return }
        perform { try styles.saveSamples(samples) }
        guard error == nil else { return }
        let source = samples
        let adjustments = adjustments
        let thinking = thinking
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = selectedModel.isEmpty ? nil : selectedModel
        operation = "Learning your note style…"
        task = Task {
            defer { operation = nil; task = nil }
            do {
                let learned = try await NotesStyleLearningService.learn(
                    samples: source, adjustments: adjustments, profile: profile, thinkingLevel: thinking, model: modelID)
                try Task.checkCancellation()
                draft = learned
                draftSamples = source
                creatorAgent = profile.title
                creatorModel = modelID ?? profile.model
                preview = ""
                notice = "Style created. Review it, then choose Use my style."
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func previewStyle() {
        guard let draft, let profile = selectedProfile else { return }
        error = nil
        let source = draftSamples
        let thinking = thinking
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        operation = "Generating a style preview…"
        task = Task {
            defer { operation = nil; task = nil }
            do {
                preview = try await NotesStyleLearningService.preview(draft: draft, samples: source, profile: profile,
                                                                      thinkingLevel: thinking,
                                                                      model: selectedModel.isEmpty ? nil : selectedModel)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func saveStyle(activate: Bool) {
        guard let draft else { return }
        perform {
            try styles.save(draft: draft, samples: draftSamples, creatorAgent: creatorAgent,
                            creatorModel: creatorModel, activate: activate)
            notice = activate ? "Your style is saved and selected for new notes." : "Style saved. Your saved preference is unchanged."
        }
    }
}
