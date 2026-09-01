import AppKit
import SwiftUI

/// First-run setup assistant. Antigravity CLI is the one required piece;
/// Canvas and Google Docs can be skipped and configured later in Settings.
struct OnboardingView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(CanvasConnectionSettings.self) private var canvasConnection
    @Environment(GoogleDocsAuth.self) private var googleAuth

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, antigravity, canvas, googleDocs, finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .antigravity: return "Antigravity CLI"
            case .canvas: return "Canvas"
            case .googleDocs: return "Google Docs"
            case .finish: return "Ready"
            }
        }

        var icon: String {
            switch self {
            case .welcome: return "hand.wave"
            case .antigravity: return "cpu"
            case .canvas: return "building.columns"
            case .googleDocs: return "doc.richtext"
            case .finish: return "checkmark.seal"
            }
        }

        var isOptional: Bool {
            self == .canvas || self == .googleDocs
        }
    }

    @State private var step: Step = .welcome

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        content
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .background(LecternTheme.paper)
        .frame(width: 780, height: 600)
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(LecternTheme.accent)
                Text("Lectern setup")
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ForEach(Step.allCases) { item in
                let done = item.rawValue < step.rawValue
                let current = item == step
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : item.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(done ? LecternTheme.successTint : (current ? LecternTheme.accent : .secondary))
                        .frame(width: 18)
                    Text(item.title)
                        .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                        .foregroundStyle(LecternTheme.ink)
                    if item.isOptional {
                        Text("optional")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(current ? LecternTheme.accent.opacity(0.10) : Color.clear)
                )
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .frame(width: 190)
        .background(LecternTheme.paperDeep)
    }

    // MARK: Header + footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.title)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(LecternTheme.ink)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome:
            return "Lectern records lectures and shiurim, transcribes them, and writes notes, flashcards and quizzes in your own style. Setup takes about two minutes."
        case .antigravity:
            return "Lectern does its AI work through Google's Antigravity CLI on your Mac. Lectern's transcription and notes skills ship inside the app, so all you need is the CLI signed in."
        case .canvas:
            return "Connect Canvas to pull courses, deadlines, grades and announcements into Lectern. You can skip this and add it later in Settings › Canvas."
        case .googleDocs:
            return "Push notes to Google Docs, one document per course. This needs your own Google OAuth client, so most people skip it for now. Settings › Google Docs has the same form."
        case .finish:
            return "That is everything Lectern needs. You can rerun this assistant any time from Settings › General."
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            if step.isOptional {
                Button("Skip") { move(1) }
            }
            Button(primaryLabel) {
                if step == .finish {
                    onboarding.complete()
                } else {
                    move(1)
                }
            }
            .prominentAction()
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .finish: return "Start using Lectern"
        case .canvas: return canvasConnection.isConnected ? "Continue" : "Continue without Canvas"
        case .googleDocs: return googleAuth.isSignedIn ? "Continue" : "Continue without Google Docs"
        case .antigravity: return "Continue"
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { step = next }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeContent
        case .antigravity: AntigravitySetupCard()
        case .canvas: CanvasSettingsPane()
        case .googleDocs: GoogleDocsPane()
        case .finish: finishContent
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow("mic", "Record", "Press ⌥⌘R anywhere, or use the menu bar icon. Audio stays on this Mac.")
            featureRow("waveform.and.mic", "Transcribe", "English lectures and mixed English‑Hebrew shiurim, with Hebrew sources written in Hebrew script.")
            featureRow("list.bullet.indent", "Notes", "Nested outline notes in your style, plus flashcards and quizzes, generated by an agent running locally through Antigravity CLI.")
            featureRow("building.columns", "Canvas", "Optional: deadlines, grades and course resources beside your lectures.")
        }
    }

    private var finishContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryRow("Antigravity CLI", AgentDetector.detectAll().first { $0.profileID == AgentProfiles.antigravityID }?.status.title ?? "Unknown")
            summaryRow("Canvas", canvasConnection.isConnected ? "Connected" : "Skipped")
            summaryRow("Google Docs", googleAuth.isSignedIn ? (googleAuth.email ?? "Signed in") : "Skipped")
            Text("Tip: Settings › Agents can detect other installed agents (ChatGPT via Codex, opencode) if you prefer them for generation.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(LecternTheme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LecternTheme.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(LecternTheme.ink)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(LecternTheme.cardFill)
        )
    }
}

/// Install + sign-in checklist for `agy`, shared by onboarding.
struct AntigravitySetupCard: View {
    @State private var detections: [AgentDetection] = []
    @State private var isVerifying = false
    @State private var verificationMessage: String?

    private var antigravity: AgentDetection? {
        detections.first { $0.profileID == AgentProfiles.antigravityID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    if let antigravity {
                        AgentDetectionRow(detection: antigravity)
                    }

                    Divider()

                    stepBlock(
                        number: 1,
                        title: "Install the CLI",
                        detail: "Paste this in Terminal. It puts `agy` in ~/.local/bin.",
                        command: AgentDetector.candidates.first { $0.profileID == AgentProfiles.antigravityID }?.installHint ?? "",
                        done: antigravity?.isInstalled ?? false
                    )

                    stepBlock(
                        number: 2,
                        title: "Sign in with Google",
                        detail: "Run `agy` once in Terminal. It opens a browser to sign in and remembers you in the Keychain. Lectern reuses that session; it never sees your password.",
                        command: "agy",
                        done: antigravity?.status == .ready
                    )

                    HStack(spacing: 10) {
                        Button("Open Terminal") { openTerminal() }
                            .controlSize(.small)
                        Button {
                            Task { await verify() }
                        } label: {
                            HStack(spacing: 6) {
                                if isVerifying { ProgressView().controlSize(.mini) }
                                Text("Check again")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isVerifying)
                        Spacer()
                    }

                    if let verificationMessage {
                        Text(verificationMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(antigravity?.status == .ready ? LecternTheme.successTint : LecternTheme.warningTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What Lectern sends")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LecternTheme.ink)
                    Text("Each job runs in a fresh private folder containing only the recording or transcript and Lectern's skill file. The agent runs sandboxed, returns structured output, and the folder is deleted afterwards.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .onAppear { refresh() }
    }

    private func stepBlock(number: Int, title: String, detail: String, command: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? LecternTheme.successTint : LecternTheme.accent.opacity(0.12))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(LecternTheme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LecternTheme.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(LecternTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy")
                }
            }
        }
    }

    private func refresh() {
        detections = AgentDetector.applyDetected(AgentDetector.detectAll())
    }

    private func verify() async {
        isVerifying = true
        defer { isVerifying = false }
        refresh()
        guard let antigravity, antigravity.isInstalled else {
            verificationMessage = "agy is not on this Mac yet. Run the install command, then check again."
            return
        }
        if antigravity.status == .ready {
            verificationMessage = "Antigravity CLI is installed and signed in."
            return
        }
        // The token file can lag the first sign-in; a live probe settles it.
        if await AgentDetector.verifyAntigravitySignIn() {
            verificationMessage = "Antigravity CLI is installed and signed in."
            detections = detections.map { detection in
                guard detection.profileID == AgentProfiles.antigravityID else { return detection }
                return AgentDetection(
                    profileID: detection.profileID, title: detection.title,
                    executablePath: detection.executablePath, suggestedCommand: detection.suggestedCommand,
                    status: .ready, installHint: detection.installHint)
            }
        } else {
            verificationMessage = "agy is installed but not signed in. Run `agy` in Terminal, finish the Google sign-in, then check again."
        }
    }

    private func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
