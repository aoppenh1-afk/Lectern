import Carbon.HIToolbox
import SwiftUI

/// Paper-styled settings: sidebar sections on the left, one focused pane on
/// the right, matching the main window's design language.
struct SettingsView: View {
    @State private var section: Section = .general

    enum Section: String, CaseIterable, Identifiable {
        case general, appearance, recording, transcription, retention, canvas, anki, googleDocs, agents

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .recording: return "Recording"
            case .transcription: return "Transcription"
            case .retention: return "Retention"
            case .canvas: return "Canvas"
            case .anki: return "Anki"
            case .googleDocs: return "Google Docs"
            case .agents: return "Agents"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .recording: return "mic"
            case .transcription: return "waveform.and.mic"
            case .retention: return "clock.arrow.circlepath"
            case .canvas: return "building.columns"
            case .anki: return "rectangle.on.rectangle.angled"
            case .googleDocs: return "doc.richtext"
            case .agents: return "cpu"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .background(LecternTheme.paper)
        .frame(width: 820, height: 640)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(LecternTheme.accent)
                    .frame(width: 7, height: 7)
                Text("Settings")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(Section.allCases) { item in
                sectionRow(item)
            }

            Spacer()
        }
        .frame(width: 176)
        .background(LecternTheme.paperDeep)
    }

    private func sectionRow(_ item: Section) -> some View {
        let isSelected = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? LecternTheme.accent : .secondary)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? LecternTheme.accent.opacity(0.10) : Color.clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(section.title)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)

                switch section {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .recording: RecordingPane()
                case .transcription: TranscriptionSettingsPane()
                case .retention: RetentionPane()
                case .canvas: CanvasSettingsPane()
                case .anki: AnkiPane()
                case .googleDocs: GoogleDocsPane()
                case .agents: AgentsPane()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared card + row

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String?
    var showsDivider = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if showsDivider {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
                .padding(.leading, 16)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppUpdater.self) private var updater
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.openWindow) private var openWindow

    @State private var token = ""
    @State private var tokenMessage: String?
    @State private var autoCheck = true

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(title: "Lectern \(updater.currentVersion)",
                            caption: "Build \(build). Updates are published as GitHub releases.") {
                    HStack(spacing: 8) {
                        if updater.phase == .checking {
                            ProgressView().controlSize(.small)
                        }
                        Button("Check for updates") {
                            Task { await updater.checkNow() }
                        }
                        .controlSize(.small)
                        .disabled(updater.phase == .checking || updater.repository == nil)
                    }
                }

                SettingsRow(title: "Check automatically",
                            caption: "Once a day, when Lectern opens. Nothing installs without asking.") {
                    Toggle("", isOn: $autoCheck)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .onChange(of: autoCheck) { _, value in updater.autoCheckEnabled = value }
                }

                SettingsRow(title: "Status", caption: statusCaption, showsDivider: updater.releasesPageURL != nil) {
                    statusIcon
                }

                if let releases = updater.releasesPageURL {
                    SettingsRow(title: "Releases page",
                                caption: "Download any version by hand from GitHub.",
                                showsDivider: false) {
                        Link("Open", destination: releases)
                            .font(.system(size: 12))
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("GitHub token")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LecternTheme.ink)
                        Spacer()
                        if let masked = updater.maskedToken {
                            Text(masked).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text("Only needed while the Lectern repository is private. Create a fine-grained personal access token at github.com › Settings › Developer settings, limited to this repository with Contents: Read-only. It is stored in your Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecureField(updater.hasToken ? "Leave blank to keep current token" : "github_pat_…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                        Button("Save") { saveToken() }
                            .controlSize(.small)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        if updater.hasToken {
                            Button("Remove") { removeToken() }
                                .controlSize(.small)
                        }
                    }
                    if let tokenMessage {
                        Text(tokenMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }

            SettingsCard {
                SettingsRow(title: "Setup assistant",
                            caption: "Walk through Antigravity CLI, Canvas and Google Docs again.",
                            showsDivider: false) {
                    Button("Run again") {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                        onboarding.present()
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { autoCheck = updater.autoCheckEnabled }
    }

    private var statusCaption: String {
        switch updater.phase {
        case .idle: return "Not checked yet this session."
        case .checking: return "Contacting GitHub…"
        case .upToDate: return "You are on the latest release."
        case .available: return "Version \(updater.pendingPrompt?.version ?? updater.availableRelease?.version ?? "") is ready to install."
        case .downloading(let fraction): return "Downloading… \(Int(fraction * 100))%"
        case .installing: return "Installing…"
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch updater.phase {
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(LecternTheme.successTint)
        case .available:
            Button("Install") {
                if let release = updater.pendingPrompt ?? updater.availableRelease {
                    updater.pendingPrompt = release
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LecternTheme.warningTint)
        default:
            EmptyView()
        }
    }

    private func saveToken() {
        do {
            try updater.setToken(token)
            token = ""
            tokenMessage = "Token saved to Keychain."
        } catch {
            tokenMessage = error.localizedDescription
        }
    }

    private func removeToken() {
        do {
            try updater.setToken("")
            token = ""
            tokenMessage = "Token removed."
        } catch {
            tokenMessage = error.localizedDescription
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage("appearance.mode") private var appearanceMode = SurfacePreferences.AppearanceMode.system.rawValue
    @AppStorage("appearance.accent") private var accentID = "moss"

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Theme", caption: "Applies across the app immediately.") {
                Picker("", selection: $appearanceMode) {
                    ForEach(SurfacePreferences.AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }

            SettingsRow(title: "Accent",
                        caption: "Brand color for selections, buttons and highlights.",
                        showsDivider: false) {
                HStack(spacing: 8) {
                    ForEach(LecternTheme.accentChoices, id: \.id) { choice in
                        Button {
                            accentID = choice.id
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(swatchColor(for: choice.id))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if accentID == choice.id {
                                            Circle()
                                                .strokeBorder(LecternTheme.ink, lineWidth: 2)
                                                .frame(width: 28, height: 28)
                                        }
                                    }
                                Text(choice.name)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(accentID == choice.id ? LecternTheme.ink : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func swatchColor(for id: String) -> Color {
        switch id {
        case "blue": return Color(.sRGB, red: 0.184, green: 0.420, blue: 0.929)
        case "plum": return Color(.sRGB, red: 0.486, green: 0.290, blue: 0.451)
        case "graphite": return Color(.sRGB, red: 0.290, green: 0.300, blue: 0.320)
        default: return Color(.sRGB, red: 0.290, green: 0.459, blue: 0.329)
        }
    }
}

// MARK: - Recording

private struct RecordingPane: View {
    @Environment(SurfacePreferences.self) private var surfacePreferences

    @AppStorage("surface.popoverEnabled") private var popoverEnabled = true
    @AppStorage("surface.pillEnabled") private var pillEnabled = false
    @AppStorage(TranscriptionPerformancePolicy.defaultsKey)
    private var transcriptionPolicy = TranscriptionPerformancePolicy.cool.rawValue

    private var selectedTranscriptionPolicy: TranscriptionPerformancePolicy {
        TranscriptionPerformancePolicy(rawValue: transcriptionPolicy) ?? .cool
    }

    var body: some View {
        SettingsCard {
            SettingsRow(
                title: "Record hotkey",
                caption: "Works system-wide. Default ⌥⌘R avoids the browser ⌘R-reload collision; the in-app Capture menu keeps ⌘R."
            ) {
                HotkeyRecorder()
            }

            SettingsRow(title: "Menu-bar popover", caption: "Recording controls from the menu bar icon.") {
                Toggle("", isOn: $popoverEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            SettingsRow(
                title: "Notch pill during recording",
                caption: "Floating pill at the top of the screen while capturing."
            ) {
                Toggle("", isOn: $pillEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            SettingsRow(
                title: "Transcription power",
                caption: selectedTranscriptionPolicy.caption
            ) {
                Picker("", selection: $transcriptionPolicy) {
                    ForEach(TranscriptionPerformancePolicy.allCases) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .labelsHidden()
            }

            SettingsRow(
                title: "Hebrew + English (shiurim)",
                caption: WhisperTranscriptionEngine.isCLIInstalled
                    ? "whisper.cpp is available for automatic on-device shiur transcription. The Transcription settings default still applies, including Gemini through Antigravity."
                    : "Automatic on-device shiur transcription needs whisper.cpp: brew install whisper-cpp",
                showsDivider: false
            ) {
                Image(systemName: WhisperTranscriptionEngine.isCLIInstalled
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(WhisperTranscriptionEngine.isCLIInstalled
                                     ? LecternTheme.successTint
                                     : LecternTheme.warningTint)
            }
        }
        .onChange(of: surfacePreferences.hotKeyCode) { _, _ in
            GlobalRecordHotkey.reinstall()
        }
        .onChange(of: surfacePreferences.hotKeyModifiers) { _, _ in
            GlobalRecordHotkey.reinstall()
        }
    }
}

/// Click-to-capture control for the global record hotkey.
private struct HotkeyRecorder: View {
    @Environment(SurfacePreferences.self) private var surfacePreferences

    @State private var isRecording = false
    @State private var monitor: Any?

    private var currentLabel: String {
        GlobalRecordHotkey.displayLabel(
            keyCode: surfacePreferences.hotKeyCode,
            modifiers: surfacePreferences.hotKeyModifiers)
    }

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            Text(isRecording ? "Press shortcut…  (esc to cancel)" : currentLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? LecternTheme.accent.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? LecternTheme.accent : Color.primary.opacity(0.12), lineWidth: 1)
                )
                .foregroundStyle(isRecording ? LecternTheme.accent : LecternTheme.ink)
                .frame(minWidth: 190)
        }
        .buttonStyle(.plain)
    }

    private func toggleRecording() {
        if isRecording {
            stopCapturing()
        } else {
            startCapturing()
        }
    }

    private func startCapturing() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopCapturing()
                return nil
            }
            let carbon = GlobalRecordHotkey.carbonModifiers(from: event.modifierFlags)
            let isFunctionKey = GlobalRecordHotkey.functionKeyCodes.contains(Int(event.keyCode))
            guard carbon != 0 || isFunctionKey else {
                NSSound.beep()
                return event
            }
            UserDefaults.standard.set(Int(event.keyCode), forKey: "hotkey.keycode")
            UserDefaults.standard.set(carbon, forKey: "hotkey.modifiers")
            stopCapturing()
            return nil
        }
    }

    private func stopCapturing() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}

// MARK: - Retention

private struct RetentionPane: View {
    @AppStorage("retentionDays") private var retentionDays = 3

    var body: some View {
        SettingsCard {
            SettingsRow(
                title: "Keep lecture audio",
                caption: "Transcripts, notes, flashcards and quizzes are always kept.",
                showsDivider: false
            ) {
                Stepper("\(retentionDays) day\(retentionDays == 1 ? "" : "s")", value: $retentionDays, in: 1...365)
                    .controlSize(.small)
                    .frame(width: 160)
            }
        }
    }
}

// MARK: - Anki

private struct AnkiPane: View {
    @AppStorage("ankiPort") private var ankiPort = 8_761

    var body: some View {
        SettingsCard {
            SettingsRow(
                title: "AnkiConnect port",
                caption: "Requires the AnkiConnect add-on (default port 8761). Flashcards sync through Anki's local API.",
                showsDivider: false
            ) {
                Stepper("\(ankiPort)", value: $ankiPort, in: 1024...65_535)
                    .controlSize(.small)
                    .frame(width: 160)
            }
        }
    }
}

// MARK: - Google Docs

struct GoogleDocsPane: View {
    @Environment(GoogleDocsAuth.self) private var auth

    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OAuth client")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LecternTheme.ink)
                    Text("Google Cloud Console → enable Google Docs API → create an OAuth client of type Desktop. Then Google Auth Platform → Audience → add the Gmail you’ll sign in with as a test user. Being the project owner does not count. Keep the app in Testing; do not publish it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    SecureField("Client secret", text: $clientSecret)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                .padding(16)
            }

            SettingsCard {
                SettingsRow(
                    title: auth.isSignedIn ? (auth.email ?? "Signed in") : "Not signed in",
                    caption: "Lectern creates one Google Doc per course and one tab per lecture. Pushing overwrites that tab.",
                    showsDivider: false
                ) {
                    if auth.isSignedIn {
                        Button("Sign out") {
                            auth.signOut()
                        }
                        .controlSize(.small)
                    } else if auth.isSigningIn {
                        Button("Cancel") {
                            auth.cancelSignIn()
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            Task {
                                commitCredentials()
                                try? await auth.signIn()
                            }
                        } label: {
                            Text("Sign in with Google")
                        }
                        .controlSize(.small)
                        .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if let error = auth.lastError, !auth.isSignedIn {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(LecternTheme.warningTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            clientID = auth.clientID
            clientSecret = auth.clientSecret
        }
        .onDisappear {
            commitCredentials()
        }
        .onChange(of: clientID) { _, _ in commitCredentials() }
        .onChange(of: clientSecret) { _, _ in commitCredentials() }
    }

    private func commitCredentials() {
        auth.clientID = clientID
        auth.clientSecret = clientSecret
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @State private var codexCommand = ""
    @State private var opencodeCommand = ""
    @State private var antigravityCommand = ""
    @State private var detections: [AgentDetection] = []
    @State private var detectionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Installed on this Mac")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(LecternTheme.ink)
                            Text("Lectern only needs one agent. Antigravity CLI is the default and ships with Lectern's transcription and notes skills built in.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Detect installed agents") { detectAndApply() }
                            .controlSize(.small)
                    }

                    ForEach(detections) { detection in
                        AgentDetectionRow(detection: detection)
                    }

                    if let detectionMessage {
                        Text(detectionMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }

            SettingsCard {
                agentField(
                    title: "Antigravity CLI",
                    caption: "Uses the signed-in agy CLI with Gemini 3.8 Flash High in private temporary workspaces.",
                    text: $antigravityCommand
                )
                agentField(
                    title: "ChatGPT (Codex)",
                    caption: "Uses your existing Codex CLI ChatGPT sign-in. Image generation is available on this agent.",
                    text: $codexCommand
                )
                agentField(
                    title: "opencode",
                    caption: "Uses whatever providers opencode is signed into. Diagrams render locally; raster images are not available here.",
                    text: $opencodeCommand,
                    showsDivider: false
                )
            }
        }
        .onAppear {
            loadCommands()
            detections = AgentDetector.detectAll()
        }
        .onDisappear {
            saveCommands()
        }
    }

    private func loadCommands() {
        codexCommand = AgentProfiles.profile(id: AgentProfiles.codexID)?.command ?? ""
        opencodeCommand = AgentProfiles.profile(id: AgentProfiles.opencodeID)?.command ?? ""
        antigravityCommand = AgentProfiles.profile(id: AgentProfiles.antigravityID)?.command ?? ""
    }

    private func saveCommands() {
        AgentProfiles.setCommand(codexCommand, for: AgentProfiles.codexID)
        AgentProfiles.setCommand(opencodeCommand, for: AgentProfiles.opencodeID)
        AgentProfiles.setCommand(antigravityCommand, for: AgentProfiles.antigravityID)
    }

    private func detectAndApply() {
        saveCommands()
        detections = AgentDetector.applyDetected(AgentDetector.detectAll())
        loadCommands()
        let found = detections.filter(\.isInstalled).map(\.title)
        detectionMessage = found.isEmpty
            ? "No agents found. Install one with the commands shown above, then detect again."
            : "Found \(found.joined(separator: ", ")). Spawn commands updated."
    }

    private func agentField(title: String, caption: String, text: Binding<String>, showsDivider: Bool = true) -> some View {
        SettingsRow(title: title, caption: caption, showsDivider: showsDivider) {
            TextField("Spawn command", text: text, prompt: Text("/path/to/agent"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 240)
        }
    }
}

/// One line of agent detection output, shared by Settings and onboarding.
struct AgentDetectionRow: View {
    let detection: AgentDetection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(detection.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LecternTheme.ink)
                    Text(detection.status.title)
                        .font(.system(size: 11))
                        .foregroundStyle(tint)
                }
                if let path = detection.executablePath {
                    Text(path)
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(detection.installHint)
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
    }

    private var icon: String {
        switch detection.status {
        case .ready: return "checkmark.circle.fill"
        case .installedNotSignedIn: return "person.crop.circle.badge.exclamationmark"
        case .notInstalled: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch detection.status {
        case .ready: return LecternTheme.successTint
        case .installedNotSignedIn: return LecternTheme.warningTint
        case .notInstalled: return .secondary
        }
    }
}
