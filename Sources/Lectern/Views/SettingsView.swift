import Carbon.HIToolbox
import SwiftUI

/// Paper-styled settings: sidebar sections on the left, one focused pane on
/// the right, matching the main window's design language.
/// Embedded in the main window (Command Studio sidebar › Settings), so the
/// layout is flexible and type is sized for the larger workspace card.
struct SettingsView: View {
    @State private var section: Section = .general

    enum Section: String, CaseIterable, Identifiable {
        case general, notifications, appearance, recording, transcription, retention, canvas, anki, googleDocs, mcp, agents

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
            case .mcp: return "ChatGPT & Claude"
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
            case .mcp: return "network"
            case .agents: return "cpu"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "Version, updates, and the setup assistant."
            case .notifications: return "Decide when Lectern may notify you."
            case .appearance: return "Theme and accent across the whole app."
            case .recording: return "Capture source, hotkey, and menu surfaces."
            case .transcription: return "Where new recordings are transcribed."
            case .retention: return "How long lecture audio is kept."
            case .canvas: return "Pull courses, deadlines, and announcements."
            case .anki: return "Sync flashcards through AnkiConnect."
            case .googleDocs: return "Push notes into one doc per course."
            case .mcp: return "Share selected lectures through MCP."
            case .agents: return "Runtimes and accounts that generate study material."
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(LecternTheme.accent)
                    .frame(width: 8, height: 8)
                Text("Settings")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 16)

            ForEach(Section.allCases) { item in
                sectionRow(item)
            }

            Spacer()
        }
        .frame(width: 216)
        .background(LecternTheme.paperDeep)
    }

    private func sectionRow(_ item: Section) -> some View {
        let isSelected = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? LecternTheme.accent : .secondary)
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(LecternTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? LecternTheme.accent.opacity(0.10) : Color.clear)
            )
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if section != .mcp && section != .agents {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(LecternTheme.ink)
                        Text(section.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

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
                case .mcp: MCPSettingsPane()
                case .agents: AgentsPane()
                }
            }
            .padding(.horizontal, section == .mcp ? 24 : 40)
            .padding(.vertical, section == .mcp ? 24 : 32)
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
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LecternTheme.ink)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)

        if showsDivider {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppUpdater.self) private var updater
    @Environment(OnboardingState.self) private var onboarding
    @Environment(\.openWindow) private var openWindow

    @State private var autoCheck = true
    @State private var channel: UpdateChannel = .stable

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                SettingsRow(title: "Lectern \(updater.displayVersion)",
                            caption: "Build \(build). Stable releases are published when ready; dev builds track every commit.") {
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

                SettingsRow(title: "Update channel",
                            caption: channel == .dev
                                ? "Dev builds track every commit on main. Expect breakage."
                                : "Tested releases only. Nothing changes until a new release is published.") {
                    Picker("", selection: $channel) {
                        Text("Stable").tag(UpdateChannel.stable)
                        Text("Dev").tag(UpdateChannel.dev)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                    .disabled(updater.phase == .checking)
                    .onChange(of: channel) { _, value in
                        updater.channel = value
                        Task { await updater.checkNow() }
                    }
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
        .onAppear {
            autoCheck = updater.autoCheckEnabled
            channel = updater.channel
        }
    }

    private var statusCaption: String {
        switch updater.phase {
        case .idle: return "Not checked yet this session."
        case .checking: return "Contacting GitHub…"
        case .upToDate: return updater.channel == .dev ? "You are on the latest dev build." : "You are on the latest release."
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
    @AppStorage(ZoomJoinFollowUp.autoRecordKey) private var autoRecordZoom = false
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
                title: "Capture source",
                caption: surfacePreferences.captureSource.caption
            ) {
                Picker("", selection: Binding(
                    get: { surfacePreferences.captureSource },
                    set: { surfacePreferences.setCaptureSource($0) }
                )) {
                    ForEach(CaptureSource.allCases) { source in
                        Text(source.shortTitle).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .labelsHidden()
            }

            SettingsRow(
                title: "Automatically record Zoom meetings",
                caption: "Start recording the Zoom app 1 minute after you click Join Zoom in Lectern, even if you are still waiting to enter. When off, a small recording prompt appears instead."
            ) {
                Toggle("Automatically record Zoom meetings", isOn: $autoRecordZoom)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

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

            if surfacePreferences.menuBarBlocked, popoverEnabled {
                SettingsRow(
                    title: "Menu bar icon hidden by macOS",
                    caption: "macOS is blocking Lectern's menu bar icon. Allow Lectern in System Settings › Menu Bar, or choose Reset Control Center there.",
                    showsDivider: false
                ) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LecternTheme.warningTint)
                }
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
                    ? "Automatic transcription uses Antigravity ACP. whisper.cpp is available as an on-device fallback."
                    : "Automatic transcription uses Antigravity ACP. For an on-device fallback, install whisper.cpp: brew install whisper-cpp",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        googleDocsIcon("doc.richtext", tint: LecternTheme.accent)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Google Docs")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LecternTheme.ink)
                                statusChip
                            }
                            Text("Lectern creates one Google Doc per course and one tab per lecture. Pushing overwrites that tab.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                    .padding(16)

                    googleDocsDivider

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LecternTheme.accent)
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(title: "Google account")
                            Text(accountMessage)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(LecternTheme.ink)
                            if let detail = accountDetail {
                                Text(detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = auth.lastError, !auth.isSignedIn {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                    Text(error)
                                        .font(.system(size: 11))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .foregroundStyle(LecternTheme.warningTint)
                                .padding(.top, 2)
                            }
                        }

                        Spacer(minLength: 12)

                        accountActions
                    }
                    .padding(16)
                }
            }
        }
    }

    private var statusChip: StatusChip {
        if auth.isSignedIn {
            StatusChip("Signed in", LecternTheme.successTint, icon: "checkmark")
        } else if auth.isSigningIn {
            StatusChip("Signing in", LecternTheme.accent, icon: "arrow.down.circle")
        } else {
            StatusChip("Not connected", .secondary, icon: "circle.dashed")
        }
    }

    private var accountMessage: String {
        if auth.isSignedIn {
            auth.email ?? "Signed in"
        } else if auth.isSigningIn {
            "Waiting for the browser…"
        } else {
            "Not signed in"
        }
    }

    private var accountDetail: String? {
        if auth.isSignedIn {
            return "Lectern pushes notes into your course document."
        } else if auth.isSigningIn {
            return "Finish signing in with Google in your browser."
        } else {
            return auth.isConfigured
                ? "Allow access to files Lectern creates or that you choose to use with it. Your other Drive files stay private."
                : "Google Docs is not configured in this build. Ask the app distributor for a configured build."
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        if auth.isSignedIn {
            Button("Sign out") {
                auth.signOut()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if auth.isSigningIn {
            Button("Cancel") {
                auth.cancelSignIn()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button {
                Task {
                    try? await auth.signIn()
                }
            } label: {
                Text("Connect Google Docs")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!auth.isConfigured)
        }
    }

    private var googleDocsDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func googleDocsIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @Environment(\.openURL) private var openURL
    @State private var codexCommand = ""
    @State private var opencodeCommand = ""
    @State private var detections: [AgentDetection] = []
    @State private var detectionMessage: String?
    @State private var codexSignIn = CodexSignIn()
    @State private var terminalMessages: [String: String] = [:]
    @State private var terminalErrors: [String: String] = [:]
    @State private var openingTerminal: Set<String> = []
    @State private var antigravityACP = AntigravityACPManager.shared
    @State private var callbackURL = ""
    @State private var confirmsRuntimeRemoval = false
    @State private var confirmsActiveSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your agents")
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.1)
                        .foregroundStyle(LecternTheme.ink)
                    Text("Connect an account to turn lectures into study material.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    detectAndApply()
                    if !antigravityACP.isBusy, antigravityACP.updateState != .checking {
                        Task { await antigravityACP.refresh() }
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AgentActionStyle())
                .help("Check for newly installed agents and refresh Antigravity's account.")
                .padding(.top, 6)
            }

            if let detectionMessage {
                Label(detectionMessage, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agents.refreshResult")
            }

            antigravityCard

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Already have an agent?")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LecternTheme.ink)
                    Spacer(minLength: 8)
                    Text("One is all you need.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                    providerCard(
                        id: AgentProfiles.codexID,
                        title: "Codex",
                        caption: "Create notes and images with your ChatGPT account.",
                        text: $codexCommand
                    )
                    providerCard(
                        id: AgentProfiles.opencodeID,
                        title: "OpenCode",
                        caption: "Use the models and providers you've connected to OpenCode.",
                        text: $opencodeCommand
                    )
                }
            }
        }
        .frame(maxWidth: 880, alignment: .leading)
        .onAppear {
            loadCommands()
            detectAndApply(showMessage: false)
        }
        .task {
            await antigravityACP.refresh()
        }
        .onDisappear {
            codexSignIn.cancel()
            saveCommands()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            detectAndApply(showMessage: false)
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

    private var antigravityCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                AgentProviderLogo(profileID: AgentProfiles.antigravityID)
                    .frame(width: 40, height: 40)
                    .frame(width: 56, height: 56)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Antigravity")
                        .font(.system(size: 23, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(LecternTheme.ink)
                    Text("Google account · Set up in Lectern")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                antigravityStatusChip
            }

            Text(antigravityACP.isInstalled
                 ? "Use your Google account for notes, flashcards, quizzes, and transcription."
                 : "Notes, flashcards, quizzes, and transcription. Connect your Google account to get started.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    antigravitySetupActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    antigravitySetupActions
                }
            }

            if case .installing(.downloading, let downloaded, let total) = antigravityACP.runtimeState {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                        .tint(LecternTheme.accent)
                    Text("\(formatBytes(downloaded)) of \(formatBytes(total))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(antigravityACP.isInstalled ? (accountDetail ?? accountMessage) : (runtimeDetail ?? runtimeMessage))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let error = antigravityACP.installationError {
                agentNotice(error, isError: true)
            }
            if case .failed(let message) = antigravityACP.authState {
                agentNotice(message, isError: true)
            }

            if case .waitingForBrowser = antigravityACP.authState {
                DisclosureGroup("Having trouble returning from your browser?") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste the complete http://127.0.0.1:… callback URL from your browser.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        SecureField("Local callback URL", text: $callbackURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Continue") {
                            let value = callbackURL
                            callbackURL = ""
                            Task { await antigravityACP.completeSignIn(callbackURL: value) }
                        }
                        .buttonStyle(AgentActionStyle(primary: true))
                        .disabled(callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let detail = antigravityACP.authDetail {
                            agentNotice(detail, isError: true)
                        }
                    }
                    .padding(.top, 12)
                }
                .font(.system(size: 12, weight: .medium))
            }

            if antigravityACP.isInstalled {
                DisclosureGroup("Manage Antigravity") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(runtimeDetail ?? runtimeMessage)
                            .font(.system(size: 12, weight: .medium))
                        Text(updateMessage)
                            .font(.system(size: 12))
                        if let detail = updateDetail {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Button("Check for updates") {
                                Task { await antigravityACP.checkForUpdates() }
                            }
                            .buttonStyle(AgentActionStyle())
                            .disabled(antigravityACP.isBusy || antigravityACP.updateState == .checking)
                            runtimeActions
                        }
                        if case .signedIn = antigravityACP.authState {
                            Button("Sign out of Google") { signOutAntigravity() }
                                .buttonStyle(AgentActionStyle())
                        }
                    }
                    .padding(.top, 14)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LecternTheme.canvasCard)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(
                            colors: [LecternTheme.accent.opacity(0.09), LecternTheme.accent.opacity(0.015)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LecternTheme.accent.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var antigravitySetupActions: some View {
        if !antigravityACP.isInstalled {
            runtimeActions
        }
        accountActions
        if case .available = antigravityACP.updateState {
            Button("Update Antigravity") { antigravityACP.startInstallation() }
                .buttonStyle(AgentActionStyle())
                .disabled(antigravityACP.isBusy)
        }
    }

    private func signOutAntigravity() {
        if antigravityACP.hasActiveWork {
            confirmsActiveSignOut = true
        } else {
            Task { await antigravityACP.signOut() }
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

    private func detectAndApply(showMessage: Bool = true) {
        saveCommands()
        detections = AgentDetector.applyDetected(otherAgentDetections())
        loadCommands()
        guard showMessage else { return }
        let found = detections.filter(\.isInstalled).map(\.title)
        detectionMessage = found.isEmpty
            ? "Codex and OpenCode were not detected. Use Download or Install in Terminal below, then refresh."
            : "Detected \(found.joined(separator: ", ")). Use Sign in to connect an account."
    }

    private func otherAgentDetections() -> [AgentDetection] {
        AgentDetector.detectAll(commands: [
            AgentProfiles.codexID: codexCommand,
            AgentProfiles.opencodeID: opencodeCommand,
        ])
    }

    private func detection(for id: String) -> AgentDetection? {
        detections.first { $0.profileID == id }
    }

    private var updateMessage: String {
        switch antigravityACP.updateState {
        case .unchecked: return "Updates have not been checked."
        case .checking: return "Checking the installed Antigravity version…"
        case .notInstalled: return "Install Antigravity to get started."
        case .upToDate(let version): return "Antigravity \(version) matches Lectern's verified release."
        case .available: return "An Antigravity update is available."
        case .unsupported: return "No managed runtime is available for this Mac."
        case .failed: return "Could not check for updates."
        }
    }

    private var updateDetail: String? {
        switch antigravityACP.updateState {
        case .available(let installed, let available):
            return "Installed: \(installed) · Available: \(available)"
        case .failed(let message): return message
        default:
            let explanation = "Checks the verified release included with Lectern. Newer releases arrive with Lectern updates."
            if let checked = antigravityACP.lastUpdateCheck {
                return "Checked \(checked.formatted(date: .abbreviated, time: .shortened)). \(explanation)"
            }
            return explanation
        }
    }

    private var runtimeMessage: String {
        switch antigravityACP.runtimeState {
        case .checking: return "Checking the managed runtime…"
        case .notInstalled: return "Download Antigravity, then sign in with Google."
        case .installing(let phase, _, _):
            switch phase {
            case .downloading: return "Downloading Antigravity…"
            case .extracting: return "Extracting the verified runtime…"
            case .verifying: return "Checking the downloaded runtime…"
            }
        case .ready: return "Antigravity is installed on this Mac."
        case .cancelled: return "Antigravity installation was cancelled."
        case .failed: return "Antigravity needs attention."
        }
    }

    private var runtimeDetail: String? {
        switch antigravityACP.runtimeState {
        case .notInstalled, .cancelled:
            return "Downloads about 316 MB directly from Google."
        case .ready(let version):
            return "Version \(version)"
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
            return "Sign in here even if you already use the Antigravity app on this Mac."
        case .waitingForBrowser:
            return antigravityACP.authDetail
                ?? "Return to Lectern after finishing sign-in in your browser."
        case .failed(let message):
            return message
        default: return nil
        }
    }

    @ViewBuilder
    private var runtimeActions: some View {
        switch antigravityACP.runtimeState {
        case .notInstalled:
            Button { antigravityACP.startInstallation() } label: {
                Label("Download Antigravity", systemImage: "arrow.down.circle")
            }
            .buttonStyle(AgentActionStyle(primary: true))
            .accessibilityIdentifier("agents.antigravity.download")
        case .cancelled, .failed:
            Button("Retry installation") { antigravityACP.startInstallation() }
                .buttonStyle(AgentActionStyle(primary: true))
        case .ready:
            HStack(spacing: 6) {
                if case .available = antigravityACP.updateState {
                    EmptyView()
                } else {
                    Button("Reinstall Antigravity") {
                        antigravityACP.startInstallation(reinstall: true)
                    }
                    .disabled(antigravityACP.hasActiveWork)
                }
                Button("Remove runtime", role: .destructive) {
                    confirmsRuntimeRemoval = true
                }
            }
            .buttonStyle(AgentActionStyle())
            .disabled(antigravityACP.isBusy || antigravityACP.updateState == .checking)
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            Button("Cancel") { antigravityACP.cancelInstallation() }
                .buttonStyle(AgentActionStyle())
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        switch antigravityACP.authState {
        case .signedOut, .failed:
            Button("Sign in with Google") {
                Task { await antigravityACP.signIn() }
            }
            .buttonStyle(AgentActionStyle(primary: true))
            .disabled(!antigravityACP.isInstalled)
        case .waitingForBrowser:
            HStack(spacing: 6) {
                Button("Open browser again") { antigravityACP.openAuthorizationURLAgain() }
                Button("Cancel") { antigravityACP.cancelSignIn() }
            }
            .buttonStyle(AgentActionStyle())
        case .signedIn:
            Label("Google connected", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LecternTheme.successTint)
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { antigravityACP.cancelSignIn() }.buttonStyle(AgentActionStyle())
            }
        case .signingOut:
            ProgressView().controlSize(.small)
        case .unavailable:
            Button("Sign in with Google") {}
                .buttonStyle(AgentActionStyle())
                .disabled(true)
                .help("Download Antigravity before signing in.")
        }
    }

    private var antigravityStatusChip: some View {
        switch (antigravityACP.runtimeState, antigravityACP.authState) {
        case (.ready, .signedIn):
            return agentStatus("Connected", tint: LecternTheme.successTint)
        case (.ready, .signingIn), (.ready, .waitingForBrowser):
            return agentStatus("Signing in", tint: LecternTheme.accent)
        case (.ready, .signingOut):
            return agentStatus("Signing out", tint: .secondary)
        case (.ready, .failed):
            return agentStatus("Sign-in failed", tint: LecternTheme.warningTint)
        case (.ready, _):
            return agentStatus("Sign in needed", tint: LecternTheme.warningTint)
        case (.installing, _):
            return agentStatus("Installing", tint: LecternTheme.accent)
        case (.cancelled, _):
            return agentStatus("Cancelled", tint: .secondary)
        case (.failed, _):
            return agentStatus("Needs attention", tint: LecternTheme.warningTint)
        case (.checking, _):
            return agentStatus("Checking", tint: .secondary)
        default:
            return agentStatus("Not installed", tint: .secondary)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func providerCard(
        id: String,
        title: String,
        caption: String,
        text: Binding<String>
    ) -> some View {
        let detection = detection(for: id)
        let isInstalled = detection?.isInstalled == true
        let setup = AgentSetup.forProfile(id)!

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                AgentProviderLogo(profileID: id)
                    .frame(width: 28, height: 28)
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 8)
                if id == AgentProfiles.codexID, isInstalled, codexSignIn.state == .signedIn {
                    agentStatus("Connected", tint: LecternTheme.successTint)
                } else {
                    agentStatus(
                        isInstalled ? "Detected" : "Not installed",
                        tint: isInstalled ? LecternTheme.successTint : .secondary
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(LecternTheme.ink)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 36, alignment: .topLeading)
            }

            if !isInstalled {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        openURL(setup.downloadURL)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .buttonStyle(AgentActionStyle(primary: true, stretches: true))
                    .help("Open the official download and installation instructions.")
                    .accessibilityIdentifier("agents.\(id).download")

                    Button {
                        openSetupTerminal(command: setup.installCommand, for: id, isSignIn: false)
                    } label: {
                        Label("Install in Terminal", systemImage: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LecternTheme.accent)
                    .buttonStyle(.plain)
                    .disabled(openingTerminal.contains(id))
                    .accessibilityIdentifier("agents.\(id).install")
                }
            } else {
                providerAccountActions(id: id)
            }

            if let error = terminalErrors[id] {
                agentNotice(error, isError: true)
            } else if let message = terminalMessages[id] {
                agentNotice(message)
            }

            DisclosureGroup("Advanced setup") {
                VStack(alignment: .leading, spacing: 12) {
                    if !isInstalled {
                        Text(setup.installRequirement)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 10) {
                            Text(setup.installCommand)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(setup.installCommand, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy installation command")
                            .accessibilityLabel("Copy \(title) installation command")
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Agent command")
                        .font(.system(size: 12, weight: .medium))
                    TextField("Agent command", text: text, prompt: Text("/path/to/agent"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12).monospaced())
                        .accessibilityIdentifier("agents.\(id).command")
                    Text("Use a custom location, then click Refresh.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 14)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LecternTheme.canvasCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.025), radius: 16, x: 0, y: 6)
        .onChange(of: text.wrappedValue) { _, _ in
            if id == AgentProfiles.codexID { codexSignIn.reset() }
        }
    }

    @ViewBuilder
    private func providerAccountActions(id: String) -> some View {
        if id == AgentProfiles.codexID {
            switch codexSignIn.state {
            case .signingIn:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish sign-in in your browser.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel sign-in") { codexSignIn.cancel() }
                        .buttonStyle(AgentActionStyle(stretches: true))
                }
            case .signedIn:
                Label("ChatGPT connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LecternTheme.successTint)
                    .frame(height: 44)
            case .idle, .failed:
                Button("Sign in with ChatGPT") {
                    saveCommands()
                    if let profile = AgentProfiles.profile(id: id) {
                        codexSignIn.start(profile: profile)
                    }
                }
                .buttonStyle(AgentActionStyle(primary: true, stretches: true))
                .accessibilityIdentifier("agents.codex.signIn")
                if case .failed(let message) = codexSignIn.state {
                    agentNotice(message, isError: true)
                } else {
                    Text("Continues in your browser.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button("Sign in to a provider") {
                guard let path = detection(for: id)?.executablePath else { return }
                openSetupTerminal(command: "\(AgentSetup.shellQuote(path)) auth login", for: id, isSignIn: true)
            }
            .buttonStyle(AgentActionStyle(primary: true, stretches: true))
            .disabled(openingTerminal.contains(id))
            .accessibilityIdentifier("agents.opencode.signIn")
            Text("Choose your provider in Terminal.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func agentStatus(_ title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.075), in: Capsule())
        .fixedSize()
    }

    private func agentNotice(_ message: String, isError: Bool = false) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(isError ? LecternTheme.warningTint : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openSetupTerminal(command: String, for id: String, isSignIn: Bool) {
        guard !openingTerminal.contains(id) else { return }
        openingTerminal.insert(id)
        terminalErrors[id] = nil
        terminalMessages[id] = nil
        Task {
            defer { openingTerminal.remove(id) }
            do {
                try await AgentSetup.openTerminal(command: command)
                terminalMessages[id] = isSignIn
                    ? "Finish sign-in in Terminal, then return to Lectern."
                    : "Finish installation in Terminal, then return to Lectern and click Refresh."
            } catch {
                terminalErrors[id] = error.localizedDescription
            }
        }
    }

}

private struct AgentActionStyle: ButtonStyle {
    var primary = false
    var stretches = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .fixedSize(horizontal: !stretches, vertical: true)
            .frame(maxWidth: stretches ? .infinity : nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(primary ? (colorScheme == .dark ? Color.black : .white) : (destructive ? LecternTheme.recordTint : LecternTheme.ink))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(primary ? LecternTheme.accent : (destructive ? LecternTheme.recordTint : Color.primary).opacity(hovered ? 0.075 : 0.045))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.14), value: hovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
