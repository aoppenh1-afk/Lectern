import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LectureChatView: View {
    @Environment(LectureChatService.self) private var chat

    @Bindable var lecture: Lecture
    let viewSource: () -> Void

    @AppStorage("generation.agentID") private var profileID = AgentProfiles.codexID
    @AppStorage("generation.thinkingLevel") private var thinkingLevelRaw = ThinkingLevel.medium.rawValue
    @State private var draft = ""
    @State private var modelOverride: String?
    @State private var modelCatalogs: [String: AgentModelCatalog] = [:]
    @State private var modelCatalogsLoading = false
    @State private var modelPickerOpen = false
    @State private var thinkingPickerOpen = false
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var attachmentError: String?
    @FocusState private var composerFocused: Bool

    private var source: LectureChatSource? { LectureChatSource.make(for: lecture) }
    private var profiles: [AgentProfile] { AgentProfiles.all() }
    private var selectedProfile: AgentProfile? {
        profiles.first(where: { $0.id == profileID }) ?? profiles.first
    }
    private var thinkingLevel: ThinkingLevel {
        ThinkingLevel(rawValue: thinkingLevelRaw) ?? .medium
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if source == nil {
                noSourceState
            } else {
                conversation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LecternTheme.paper)
        .task {
            if modelOverride == nil {
                modelOverride = selectedProfile?.model
            }
            await loadModelCatalogs()
            normalizeThinkingLevel()
        }
        .onChange(of: effectiveModelID) { _, _ in normalizeThinkingLevel() }
        .onChange(of: profileID) { _, _ in normalizeThinkingLevel() }
        .onChange(of: thinkingLevelRaw) { _, _ in applyThinkingToSelectedModel() }
        .alert("Could not attach file", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            assistantBadge(size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Study Assistant")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LecternTheme.ink)
                Text(groundingLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: viewSource) {
                Label("View Source", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(LecternTheme.cardFill))
                    .overlay(Capsule().strokeBorder(LecternTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                chat.clearConversation(for: lecture)
                draft = ""
                composerFocused = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New chat")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var groundingLabel: String {
        let labels = source?.labels.joined(separator: " + ") ?? "No source"
        return "Grounded in: \(lecture.title) · \(labels)"
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if lecture.chatMessages.isEmpty && !chat.isResponding && chat.lastError == nil {
                            welcomeState
                                .padding(.top, 58)
                        } else {
                            ForEach(lecture.orderedChatMessages) { message in
                                messageRow(message)
                                    .id(message.persistentModelID)
                            }

                            if chat.isResponding && chat.proposingMessageID == nil {
                                streamingRow
                                    .id("streaming-response")
                            }

                            if let error = chat.lastError {
                                errorRow(error)
                                    .id("chat-error")
                            }
                        }
                    }
                    .padding(.horizontal, 42)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: lecture.chatMessages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: chat.partialResponse) { _, _ in
                    proxy.scrollTo("streaming-response", anchor: .bottom)
                }
                .onChange(of: chat.lastError) { _, _ in
                    proxy.scrollTo("chat-error", anchor: .bottom)
                }
            }

            composer
                .padding(.horizontal, 42)
                .padding(.bottom, 16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)

            Text("AI can make mistakes. Check important information against the lecture.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
    }

    private var welcomeState: some View {
        VStack(spacing: 16) {
            assistantBadge(size: 58)

            VStack(spacing: 7) {
                Text("Hi! I'm your AI study assistant")
                    .font(.system(size: 21, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text("Ask me anything about this lecture. I'll help you understand,\nsummarize, and practice what you learned.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            HStack(spacing: 9) {
                suggestion("Summarize this lecture", icon: "text.alignleft")
                suggestion("Turn into a study guide", icon: "book.closed")
                suggestion("Generate flashcards", icon: "rectangle.on.rectangle.angled")
                suggestion("Test me", icon: "target")
            }
            .padding(.top, 14)
        }
    }

    private func suggestion(_ title: String, icon: String) -> some View {
        Button {
            draft = title
            send()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11))
                .foregroundStyle(LecternTheme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(LecternTheme.cardFill))
                .overlay(Capsule().strokeBorder(LecternTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(chat.isResponding)
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 100)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(message.content)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LecternTheme.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LecternTheme.accent.opacity(0.10))
                        )
                    if !message.attachmentNames.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(Array(message.attachmentNames.enumerated()), id: \.offset) { index, name in
                                Label(
                                    name,
                                    systemImage: messageAttachmentIcon(message, index: index)
                                )
                                .lineLimit(1)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.035), in: Capsule())
                            }
                        }
                    }
                    timestamp(message.createdAt)
                }
            }
        } else {
            assistantRow(
                content: message.content,
                sourceLabels: message.sourceLabels,
                date: message.createdAt,
                isStreaming: false,
                message: message
            )
        }
    }

    private var streamingRow: some View {
        assistantRow(
            content: chat.partialResponse,
            sourceLabels: source?.labels ?? [],
            date: nil,
            isStreaming: true,
            message: nil
        )
    }

    private func assistantRow(content: String,
                              sourceLabels: [String],
                              date: Date?,
                              isStreaming: Bool,
                              message: ChatMessage?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            assistantBadge(size: 30)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if content.isEmpty && isStreaming {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Thinking about your lecture…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        markdownText(content)
                            .textSelection(.enabled)
                    }
                }
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LecternTheme.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(LecternTheme.hairline, lineWidth: 1)
                )

                if !content.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(sourceLabels, id: \.self) { label in
                            Button(action: viewSource) {
                                Label(label, systemImage: label.contains("transcript") ? "waveform" : "doc.text")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.035)))
                                    .overlay(Capsule().strokeBorder(LecternTheme.hairline, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        if let date { timestamp(date) }
                    }
                    .padding(.leading, 8)
                }

                if let message {
                    noteChangeControls(for: message)
                }
            }
        }
    }

    @ViewBuilder
    private func noteChangeControls(for message: ChatMessage) -> some View {
        switch message.noteChangeState {
        case nil:
            if lecture.artifact(of: .notes) != nil {
                Button {
                    proposeNoteChange(from: message)
                } label: {
                    if chat.proposingMessageID == message.persistentModelID {
                        Label("Building note proposal…", systemImage: "ellipsis")
                    } else {
                        Label("Propose note change", systemImage: "doc.badge.plus")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(chat.isResponding)
                .padding(.leading, 8)
            }

        case .proposed:
            if let proposed = message.proposedNotes,
               let base = message.proposalBaseNotes {
                NoteChangeProposalView(
                    diff: MarkdownDiff.lines(from: base, to: proposed),
                    isStale: chat.proposalIsStale(message, lecture: lecture),
                    apply: { chat.applyProposal(message, to: lecture) },
                    discard: { chat.discardProposal(message) }
                )
            }

        case .applied:
            HStack(spacing: 8) {
                Label("Applied to Notes", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LecternTheme.successTint)
                if chat.canUndoLastNoteChange(in: lecture) {
                    Button("Undo") { chat.undoLastNoteChange(in: lecture) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.leading, 8)

        case .discarded:
            proposalStatus("Proposal discarded", icon: "xmark.circle", color: .secondary)
        case .stale:
            proposalStatus("Proposal rejected because the note changed", icon: "exclamationmark.triangle", color: LecternTheme.warningTint)
        case .undone:
            proposalStatus("Note change undone", icon: "arrow.uturn.backward.circle", color: .secondary)
        }
    }

    private func proposalStatus(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.leading, 8)
    }

    private func errorRow(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
                .lineLimit(3)
            Spacer()
            Button("Dismiss") { chat.dismissError() }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(LecternTheme.warningTint)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                .fill(LecternTheme.warningTint.opacity(0.08))
        )
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingAttachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: attachmentIcon(for: attachment.kind))
                                Text(attachment.name)
                                    .lineLimit(1)
                                Button {
                                    pendingAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(size: 10))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                        }
                    }
                }
            }

            TextField("Ask a follow-up question…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit { send() }

            HStack(spacing: 10) {
                Button {
                    openAttachmentPanel()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(chat.isResponding)
                .help("Attach files or folders")

                Button {
                    modelPickerOpen.toggle()
                } label: {
                    HStack(spacing: 5) {
                        AgentProviderLogo(profileID: selectedProfile?.id ?? AgentProfiles.codexID)
                            .frame(width: 12, height: 12)
                        Text(modelLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .popover(isPresented: $modelPickerOpen, arrowEdge: .bottom) {
                    LectureModelPicker(
                        profiles: profiles,
                        catalogs: modelCatalogs,
                        isLoading: modelCatalogsLoading,
                        isPresented: $modelPickerOpen,
                        selectedProfileID: $profileID,
                        selectedModelID: $modelOverride
                    )
                }

                if !availableThinkingLevels.isEmpty {
                    Button {
                        thinkingPickerOpen.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "brain")
                                .font(.system(size: 10))
                            Text(thinkingLevel.title)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .popover(isPresented: $thinkingPickerOpen, arrowEdge: .bottom) {
                        ThinkingLevelPicker(
                            levels: availableThinkingLevels,
                            defaultLevel: selectedModel?.defaultThinkingLevel,
                            selection: $thinkingLevelRaw,
                            isPresented: $thinkingPickerOpen
                        )
                    }
                }

                Spacer()

                if chat.isResponding {
                    Button {
                        chat.cancelResponse()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(LecternTheme.warningTint))
                    }
                    .buttonStyle(.plain)
                    .help("Stop response")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(canSend ? LecternTheme.accent : Color.secondary.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(LecternTheme.hairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 10, y: 3)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chat.isResponding
            && selectedProfile != nil
    }

    private var modelLabel: String {
        guard let profile = selectedProfile else { return "Choose agent" }
        guard let modelID = effectiveModelID, !modelID.isEmpty else {
            return "\(profile.title) default"
        }
        return modelCatalogs[profile.id]?.models.first(where: { $0.id == modelID })?.name
            ?? modelID
    }

    private var effectiveModelID: String? {
        modelOverride ?? selectedProfile?.model
    }

    private var selectedModel: AgentModel? {
        guard let profile = selectedProfile,
              let catalog = modelCatalogs[profile.id] else { return nil }
        if let effectiveModelID,
           let exact = catalog.models.first(where: { $0.id == effectiveModelID }) {
            return exact
        }
        if let currentID = catalog.currentID,
           let current = catalog.models.first(where: { $0.id == currentID }) {
            return current
        }
        return catalog.models.first(where: \.isDefault) ?? catalog.models.first
    }

    private var availableThinkingLevels: [ThinkingLevel] {
        ThinkingLevel.chatOptions(
            profileID: selectedProfile?.id,
            advertised: selectedModel?.supportedThinkingLevels ?? []
        )
    }

    private var noSourceState: some View {
        EmptyStateView(
            icon: "text.badge.xmark",
            title: "No lecture source yet",
            message: "Finish transcription or generate notes before starting a grounded chat."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func assistantBadge(size: CGFloat) -> some View {
        Circle()
            .fill(LecternTheme.accent.opacity(0.12))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(LecternTheme.accent)
            )
    }

    private func markdownText(_ content: String) -> Text {
        Text(ChatMarkdownRenderer.attributedString(for: content))
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if chat.isResponding {
            proxy.scrollTo("streaming-response", anchor: .bottom)
        } else if let last = lecture.orderedChatMessages.last {
            proxy.scrollTo(last.persistentModelID, anchor: .bottom)
        }
    }

    private func send() {
        guard let profile = selectedProfile else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        let attachments = pendingAttachments
        pendingAttachments = []
        chat.send(
            question,
            lecture: lecture,
            profile: profile,
            thinkingLevel: thinkingLevel,
            modelOverride: effectiveModelID,
            attachments: attachments
        )
    }

    private func proposeNoteChange(from message: ChatMessage) {
        guard let profile = selectedProfile else { return }
        chat.proposeNoteChange(
            from: message,
            lecture: lecture,
            profile: profile,
            thinkingLevel: thinkingLevel,
            modelOverride: effectiveModelID
        )
    }

    private func openAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.title = "Attach to this chat"
        panel.prompt = "Attach"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.begin { response in
            guard response == .OK else { return }
            handleAttachmentImport(panel.urls)
        }
    }

    private func handleAttachmentImport(_ urls: [URL]) {
        do {
            pendingAttachments.append(contentsOf: try chat.importAttachments(from: urls))
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func attachmentIcon(for kind: ChatAttachmentKind) -> String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.plaintext"
        case .text: return "doc.text"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }

    private func messageAttachmentIcon(_ message: ChatMessage, index: Int) -> String {
        guard message.attachmentKinds.indices.contains(index),
              let kind = ChatAttachmentKind(rawValue: message.attachmentKinds[index]) else {
            return "paperclip"
        }
        return attachmentIcon(for: kind)
    }

    private func normalizeThinkingLevel() {
        if let modelID = effectiveModelID, AntigravityCLI.isThinkingVariant(modelID) {
            let next = AntigravityCLI.thinkingLevel(fromModelID: modelID).rawValue
            if thinkingLevelRaw != next {
                thinkingLevelRaw = next
            }
            return
        }
        let levels = availableThinkingLevels
        guard !levels.isEmpty, !levels.contains(thinkingLevel) else { return }
        thinkingLevelRaw = (selectedModel?.defaultThinkingLevel ?? levels[0]).rawValue
    }

    private func applyThinkingToSelectedModel() {
        guard selectedProfile?.id == AgentProfiles.antigravityID,
              let current = effectiveModelID else { return }
        let catalogIDs = modelCatalogs[AgentProfiles.antigravityID]?.models.map(\.id) ?? []
        let next = AntigravityCLI.applyThinking(thinkingLevel, to: current, availableIDs: catalogIDs)
        guard next != current else { return }
        modelOverride = next
        AgentProfiles.setModel(next, for: AgentProfiles.antigravityID)
    }

    private func loadModelCatalogs() async {
        guard !modelCatalogsLoading, modelCatalogs.isEmpty else { return }
        modelCatalogsLoading = true
        var loaded: [String: AgentModelCatalog] = [:]
        for profile in profiles {
            loaded[profile.id] = await AgentModelCatalogLoader.load(for: profile)
        }
        modelCatalogs = loaded
        modelCatalogsLoading = false
        normalizeThinkingLevel()
    }
}

struct ThinkingLevelPicker: View {
    let levels: [ThinkingLevel]
    let defaultLevel: ThinkingLevel?
    @Binding var selection: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reasoning")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 3)

            ForEach(levels) { level in
                Button {
                    selection = level.rawValue
                    isPresented = false
                } label: {
                    HStack(spacing: 7) {
                        Text(level.title)
                            .font(.system(size: 13))
                        if level == defaultLevel {
                            Text("Default")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.055), in: Capsule())
                        }
                        Spacer(minLength: 16)
                        if selection == level.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(LecternTheme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selection == level.rawValue ? Color.primary.opacity(0.07) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 210)
        .background(LecternTheme.paper)
    }
}

private struct NoteChangeProposalView: View {
    let diff: [MarkdownDiffLine]
    let isStale: Bool
    let apply: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Proposed notes update", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("Review changes")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(10)

            Divider()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(MarkdownDiff.changedSections(diff)) { section in
                        changeSection(section)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 300)
            .background(Color.primary.opacity(0.018))

            Divider()

            HStack(spacing: 8) {
                if isStale {
                    Label("Notes changed since this proposal was created", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LecternTheme.warningTint)
                }
                Spacer()
                Button("Discard", role: .cancel, action: discard)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                .strokeBorder(isStale ? LecternTheme.warningTint.opacity(0.55) : LecternTheme.hairline)
        )
        .padding(.leading, 8)
    }

    private func changeSection(_ section: MarkdownDiffSection) -> some View {
        let added = section.kind == .added
        let tint = added ? LecternTheme.successTint : LecternTheme.warningTint
        return VStack(alignment: .leading, spacing: 7) {
            Label(added ? "After" : "Before", systemImage: added ? "plus.circle.fill" : "minus.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(ChatMarkdownRenderer.attributedString(for: previewText(section.markdown)))
                .font(.system(size: 12.5))
                .foregroundStyle(LecternTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.18))
        )
    }

    private func previewText(_ markdown: String) -> String {
        if markdown.contains("```mermaid") {
            return "A diagram was added or updated."
        }
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            var line = String(rawLine)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line.replaceSubrange(line.startIndex...line.index(after: line.startIndex), with: "• ")
            }
            return line
        }.joined(separator: "\n")
    }
}

struct LectureModelPicker: View {
    let profiles: [AgentProfile]
    let catalogs: [String: AgentModelCatalog]
    let isLoading: Bool

    @Binding var isPresented: Bool
    @Binding var selectedProfileID: String
    @Binding var selectedModelID: String?

    @State private var searchText = ""
    @State private var profileFilter: String?
    @State private var hoveredRow: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            agentRail
            Divider()
            modelList
        }
        .frame(width: 470, height: 430)
        .background(LecternTheme.paper)
        .onAppear {
            if profileFilter == nil {
                profileFilter = selectedProfileID
            }
            searchFocused = true
        }
    }

    private var agentRail: some View {
        VStack(spacing: 10) {
            ForEach(profiles) { profile in
                railButton(
                    title: profile.title,
                    profileID: profile.id
                )
            }

            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 58)
        .background(Color.primary.opacity(0.025))
    }

    private func railButton(title: String, profileID: String) -> some View {
        let selected = (profileFilter ?? selectedProfileID) == profileID
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                profileFilter = profileID
            }
        } label: {
            AgentProviderLogo(profileID: profileID)
                .padding(9)
                .opacity(selected ? 1 : 0.58)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? LecternTheme.accent.opacity(0.13) : Color.clear)
                )
                .overlay(alignment: .trailing) {
                    if selected {
                        Capsule()
                            .fill(LecternTheme.accent)
                            .frame(width: 3, height: 20)
                            .offset(x: 10)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField("Search models…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider()
                .padding(.horizontal, 14)

            if isLoading && catalogs.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading available models…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleProfiles.allSatisfy({ visibleModels(for: $0).isEmpty })
                        && !searchText.isEmpty {
                ContentUnavailableView(
                    "No matching models",
                    systemImage: "magnifyingglass",
                    description: Text("Try a model name, provider, or agent.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleProfiles) { profile in
                            modelSection(profile)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var visibleProfiles: [AgentProfile] {
        let activeProfileID = profileFilter ?? selectedProfileID
        let filtered = profiles.filter { $0.id == activeProfileID }
        return filtered.isEmpty ? profiles : filtered
    }

    private func visibleModels(for profile: AgentProfile) -> [AgentModel] {
        let models = catalogs[profile.id]?.models ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.searchText.contains(query) || profile.title.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private func modelSection(_ profile: AgentProfile) -> some View {
        let models = visibleModels(for: profile)
        if !models.isEmpty || searchText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    AgentProviderLogo(profileID: profile.id)
                        .frame(width: 12, height: 12)
                    Text(profile.title)
                    Spacer()
                    Text("\(models.count) model\(models.count == 1 ? "" : "s")")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

                ForEach(models) { model in
                    let provider = model.provider.map { "\(profile.title) · \($0)" } ?? profile.title
                    modelRow(
                        profile: profile,
                        modelID: model.id,
                        title: model.name,
                        subtitle: provider
                    )
                }
            }
        }
    }

    private func modelRow(profile: AgentProfile,
                          modelID: String?,
                          title: String,
                          subtitle: String) -> some View {
        let rowID = "\(profile.id):\(modelID ?? "default")"
        let activeModel = selectedProfileID == profile.id
            ? (selectedModelID ?? profile.model)
            : nil
        let selected = selectedProfileID == profile.id && activeModel == modelID
        let hovered = hoveredRow == rowID

        return Button {
            selectedProfileID = profile.id
            selectedModelID = modelID
            AgentProfiles.setModel(modelID, for: profile.id)
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LecternTheme.accent.opacity(selected ? 0.16 : 0.08))
                    AgentProviderLogo(profileID: profile.id)
                        .frame(width: 16, height: 16)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LecternTheme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(LecternTheme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? LecternTheme.accent.opacity(0.10)
                          : hovered ? Color.primary.opacity(0.055) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredRow = isHovering ? rowID : nil
        }
    }
}

struct AgentProviderLogo: View {
    let profileID: String

    var body: some View {
        Image(assetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch profileID {
        case AgentProfiles.codexID: return "ProviderOpenAI"
        case AgentProfiles.antigravityID: return "TranscriptionGemini"
        default: return "ProviderOpenCode"
        }
    }
}
