import Carbon.HIToolbox
import SwiftUI

/// Paper-styled settings: sidebar sections on the left, one focused pane on
/// the right, matching the main window's design language.
struct SettingsView: View {
    @State private var section: Section = .general

    enum Section: String, CaseIterable, Identifiable {
        case general, notifications, appearance, recording, transcription, retention, canvas, anki, googleDocs, agents

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .notifications: return "Notifications"
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
            case .notifications: return "bell"
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
                case .notifications: NotificationsPane()
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

// MARK: - Notifications

private struct NotificationsPane: View {
    @Environment(NotificationPreferences.self) private var preferences

    var body: some View {
        SettingsCard {
            SettingsRow(
                title: "Allow notifications",
                caption: authorizationCaption
            ) {
                Toggle("", isOn: Binding(
                    get: {
                        preferences.isEnabled && preferences.authorizationState == .authorized
                    },
                    set: { enabled in
                        Task { await preferences.setEnabled(enabled) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            if preferences.isEnabled && preferences.authorizationState == .denied {
                SettingsRow(
                    title: "macOS notifications are off",
                    caption: "Turn on Allow Notifications for Lectern in System Settings."
                ) {
                    Button("Open System Settings") {
                        preferences.openSystemSettings()
                    }
                    .controlSize(.small)
                }
            }

            SettingsRow(
                title: "Transcription completed",
                caption: "Notify when a lecture transcript is ready."
            ) {
                Toggle("", isOn: Binding(
                    get: { preferences.transcriptionEnabled },
                    set: { preferences.transcriptionEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!preferences.isEnabled)
            }

            SettingsRow(
                title: "Study materials completed",
                caption: "Notify when notes, flashcards, or a quiz finish generating.",
                showsDivider: false
            ) {
                Toggle("", isOn: Binding(
                    get: { preferences.generationEnabled },
                    set: { preferences.generationEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!preferences.isEnabled)
            }
        }
        .task { await preferences.refreshAuthorizationState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await preferences.refreshAuthorizationState() }
        }
    }

    private var authorizationCaption: String {
        guard preferences.isEnabled else {
            return "Lectern will not send notifications."
        }
        switch preferences.authorizationState {
        case .unknown:
            return "Checking the macOS notification setting."
        case .notDetermined:
            return "macOS will ask for permission when you turn this on."
        case .denied:
            return "Lectern is on, but macOS is blocking notifications."
        case .authorized:
            return "Lectern and macOS both allow notifications."
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
                            caption: "Every time Lectern opens. Nothing installs without asking.") {
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
                            caption: "Walk through Antigravity ACP, Canvas and Google Docs again.",
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
    @State private var detections: [AgentDetection] = []
    @State private var detectionMessage: String?
    @State private var antigravityACP = AntigravityACPManager.shared
    @State private var callbackURL = ""
    @State private var confirmsRuntimeRemoval = false
    @State private var confirmsActiveSignOut = false

    private var macName: String {
        Host.current().localizedName ?? "this Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        agentIcon("sparkles", tint: LecternTheme.accent)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Antigravity")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LecternTheme.ink)

                                antigravityStatusChip
                            }

                            Text("Antigravity runs locally on \(macName).")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                await antigravityACP.refresh()
                                detectAndApply()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(16)

                    agentsDivider

                    antigravitySection(
                        icon: "shippingbox",
                        title: "Runtime",
                        message: runtimeMessage,
                        detail: runtimeDetail
                    ) {
                        runtimeActions
                    }

                    if case .installing(.downloading, let downloaded, let total) = antigravityACP.runtimeState {
                        VStack(alignment: .leading, spacing: 5) {
                            ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                            Text("\(formatBytes(downloaded)) of \(formatBytes(total))")
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 48)
                        .padding(.bottom, 14)
                    }

                    agentsDivider

                    antigravitySection(
                        icon: "person.crop.circle",
                        title: "Google account",
                        message: accountMessage,
                        detail: accountDetail
                    ) {
                        accountActions
                    }

                    if case .waitingForBrowser = antigravityACP.authState {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("If the browser could not reach the local callback, paste its complete http://127.0.0.1:… URL here.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 8) {
                                SecureField("Local callback URL", text: $callbackURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 10.5).monospaced())
                                Button("Continue") {
                                    let value = callbackURL
                                    callbackURL = ""
                                    Task { await antigravityACP.completeSignIn(callbackURL: value) }
                                }
                                .controlSize(.small)
                                .disabled(callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if let detail = antigravityACP.authDetail {
                                Text(detail).font(.system(size: 10.5)).foregroundStyle(LecternTheme.warningTint)
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.bottom, 14)
                    }
                }
            }

            if let detectionMessage {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(LecternTheme.accent)
                    Text(detectionMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(title: "Other agents")
                    Spacer()
                    Text("Lectern only needs one agent.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                providerCard(
                    id: AgentProfiles.codexID,
                    icon: "bubble.left.and.text.bubble.right",
                    title: "ChatGPT (Codex)",
                    caption: "Uses your existing ChatGPT sign-in and supports image generation.",
                    text: $codexCommand
                )

                providerCard(
                    id: AgentProfiles.opencodeID,
                    icon: "terminal",
                    title: "OpenCode",
                    caption: "Uses the providers already configured in OpenCode.",
                    text: $opencodeCommand
                )
            }
        }
        .onAppear {
            loadCommands()
            detections = otherAgentDetections()
        }
        .task {
            await antigravityACP.refresh()
        }
        .onDisappear {
            saveCommands()
        }
        .confirmationDialog(
            "Remove the downloaded Antigravity runtime?",
            isPresented: $confirmsRuntimeRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove runtime", role: .destructive) {
                Task { await antigravityACP.remove() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active Antigravity work will stop. Lectern courses, recordings, transcripts, and notes are not removed.")
        }
        .confirmationDialog(
            "Sign out and stop active Antigravity work?",
            isPresented: $confirmsActiveSignOut,
            titleVisibility: .visible
        ) {
            Button("Stop work and sign out", role: .destructive) {
                Task { await antigravityACP.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func loadCommands() {
        codexCommand = AgentProfiles.profile(id: AgentProfiles.codexID)?.command ?? ""
        opencodeCommand = AgentProfiles.profile(id: AgentProfiles.opencodeID)?.command ?? ""
    }

    private func saveCommands() {
        AgentProfiles.setCommand(codexCommand, for: AgentProfiles.codexID)
        AgentProfiles.setCommand(opencodeCommand, for: AgentProfiles.opencodeID)
    }

    private func detectAndApply() {
        saveCommands()
        detections = AgentDetector.applyDetected(otherAgentDetections())
        loadCommands()
        let found = detections.filter(\.isInstalled).map(\.title)
        detectionMessage = found.isEmpty
            ? "No agents found. Install one with the commands shown above, then detect again."
            : "Found \(found.joined(separator: ", ")). Spawn commands updated."
    }

    private func otherAgentDetections() -> [AgentDetection] {
        AgentDetector.detectAll().filter { $0.profileID != AgentProfiles.antigravityID }
    }

    private func detection(for id: String) -> AgentDetection? {
        detections.first { $0.profileID == id }
    }

    private var runtimeMessage: String {
        switch antigravityACP.runtimeState {
        case .checking: return "Checking the managed runtime…"
        case .notInstalled: return "Install the official Antigravity runtime before signing in."
        case .installing(let phase, _, _):
            switch phase {
            case .downloading: return "Downloading Antigravity…"
            case .extracting: return "Extracting the verified runtime…"
            case .verifying: return "Checking the downloaded runtime…"
            }
        case .ready: return "Official Antigravity ACP runtime installed."
        case .cancelled: return "Antigravity installation was cancelled."
        case .failed: return "Antigravity needs attention."
        }
    }

    private var runtimeDetail: String? {
        switch antigravityACP.runtimeState {
        case .notInstalled, .cancelled:
            return "Downloads 315 MB directly from Google. Your existing agy CLI is separate and is not used."
        case .ready(let version):
            return "Google release \(version) · SHA-256 verified"
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    private var accountMessage: String {
        switch antigravityACP.authState {
        case .unavailable: return "Install Antigravity before signing in."
        case .signedOut: return "Sign in with your Google account."
        case .signingIn: return "Starting Google sign-in…"
        case .waitingForBrowser: return "Finish signing in with Google in your browser."
        case .signedIn: return "Signed in with Google."
        case .signingOut: return "Signing out…"
        case .failed: return "Google account needs attention."
        }
    }

    private var accountDetail: String? {
        switch antigravityACP.authState {
        case .signedOut:
            return "Lectern uses an isolated ACP profile; your Antigravity CLI sign-in is intentionally not reused."
        case .waitingForBrowser:
            return antigravityACP.authDetail
                ?? "The local ACP process receives Google's redirect and stores its own token in Lectern."
        case .failed(let message):
            return message
        default: return nil
        }
    }

    @ViewBuilder
    private var runtimeActions: some View {
        switch antigravityACP.runtimeState {
        case .notInstalled:
            Button("Install Antigravity") { antigravityACP.startInstallation() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .cancelled, .failed:
            Button("Retry installation") { antigravityACP.startInstallation() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .ready:
            HStack(spacing: 6) {
                Button("Reinstall Antigravity") {
                    antigravityACP.startInstallation(reinstall: true)
                }
                Button("Remove runtime", role: .destructive) {
                    confirmsRuntimeRemoval = true
                }
            }
            .controlSize(.small)
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            Button("Cancel") { antigravityACP.cancelInstallation() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        switch antigravityACP.authState {
        case .signedOut, .failed:
            Button("Sign in with Google") {
                Task { await antigravityACP.signIn() }
            }
            .controlSize(.small)
            .disabled(!antigravityACP.isInstalled)
        case .waitingForBrowser:
            HStack(spacing: 6) {
                Button("Open browser again") { antigravityACP.openAuthorizationURLAgain() }
                Button("Cancel") { antigravityACP.cancelSignIn() }
            }
            .controlSize(.small)
        case .signedIn:
            Button("Sign out") {
                if antigravityACP.hasActiveWork {
                    confirmsActiveSignOut = true
                } else {
                    Task { await antigravityACP.signOut() }
                }
            }
                .controlSize(.small)
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { antigravityACP.cancelSignIn() }.controlSize(.small)
            }
        case .signingOut:
            ProgressView().controlSize(.small)
        case .unavailable:
            EmptyView()
        }
    }

    private var antigravityStatusChip: StatusChip {
        switch (antigravityACP.runtimeState, antigravityACP.authState) {
        case (.ready, .signedIn):
            return StatusChip("Ready", LecternTheme.successTint, icon: "checkmark")
        case (.ready, _):
            return StatusChip("Sign-in needed", LecternTheme.warningTint, icon: "person.crop.circle.badge.exclamationmark")
        case (.installing, _):
            return StatusChip("Installing", LecternTheme.accent, icon: "arrow.down.circle")
        case (.cancelled, _):
            return StatusChip("Cancelled", .secondary, icon: "xmark.circle")
        case (.failed, _):
            return StatusChip("Needs attention", LecternTheme.warningTint, icon: "exclamationmark.triangle")
        default:
            return StatusChip("Not installed", .secondary, icon: "circle.dashed")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var agentsDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    @ViewBuilder
    private func antigravitySection<Actions: View>(
        icon: String,
        title: String,
        message: String,
        detail: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LecternTheme.accent)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(title: title)
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)
            actions()
        }
        .padding(16)
    }

    private func providerCard(
        id: String,
        icon: String,
        title: String,
        caption: String,
        text: Binding<String>
    ) -> some View {
        let detection = detection(for: id)

        return SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                agentIcon(icon, tint: .secondary)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LecternTheme.ink)

                        if let detection {
                            statusChip(for: detection.status)
                        }
                    }

                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)

                    TextField("Spawn command", text: text, prompt: Text("/path/to/agent"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11).monospaced())
                }
            }
            .padding(14)
        }
    }

    private func agentIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func statusChip(for status: AgentDetection.Status) -> StatusChip {
        switch status {
        case .ready:
            return StatusChip("Ready", LecternTheme.successTint, icon: "checkmark")
        case .installedNotSignedIn:
            return StatusChip(
                "Sign-in needed",
                LecternTheme.warningTint,
                icon: "person.crop.circle.badge.exclamationmark"
            )
        case .notInstalled:
            return StatusChip("Not installed", .secondary, icon: "circle.dashed")
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
