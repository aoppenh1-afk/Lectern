import AppKit
import SwiftUI

/// First-run setup assistant. Antigravity ACP is the one required piece;
/// Canvas and Google Docs can be skipped and configured later in Settings.
struct OnboardingView: View {
    @Environment(OnboardingState.self) private var onboarding
    @Environment(CanvasConnectionSettings.self) private var canvasConnection
    @Environment(GoogleDocsAuth.self) private var googleAuth
    @State private var antigravityACP = AntigravityACPManager.shared

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, antigravity, canvas, googleDocs, finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .antigravity: return "Antigravity"
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
            return "Lectern connects through Google's official Antigravity ACP runtime. This is separate from the agy CLI and uses its own Google sign-in."
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
            .disabled(step == .antigravity && !antigravityACP.isSignedIn)
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
            featureRow("list.bullet.indent", "Notes", "Nested outline notes in your style, plus flashcards and quizzes, generated through Google's official Antigravity ACP connection.")
            featureRow("building.columns", "Canvas", "Optional: deadlines, grades and course resources beside your lectures.")
        }
    }

    private var finishContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryRow("Antigravity", antigravityACP.isSignedIn ? "Ready" : "Setup incomplete")
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

/// Managed Google runtime and isolated ACP sign-in used by onboarding.
struct AntigravitySetupCard: View {
    @State private var antigravityACP = AntigravityACPManager.shared
    @State private var callbackURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    setupRow(
                        icon: "shippingbox",
                        title: "Runtime",
                        detail: runtimeDetail,
                        done: antigravityACP.isInstalled
                    ) {
                        runtimeAction
                    }

                    if case .installing(.downloading, let downloaded, let total) = antigravityACP.runtimeState {
                        ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                        Text("\(ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    setupRow(
                        icon: "person.crop.circle",
                        title: "Google account",
                        detail: accountDetail,
                        done: antigravityACP.isSignedIn
                    ) {
                        accountAction
                    }

                    if case .waitingForBrowser = antigravityACP.authState {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("If the browser could not reach Antigravity, paste the complete http://127.0.0.1:… callback URL.")
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
                            }
                            if let detail = antigravityACP.authDetail {
                                Text(detail).font(.system(size: 10.5)).foregroundStyle(LecternTheme.warningTint)
                            }
                        }
                    }

                    if case .failed(let message) = antigravityACP.authState {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(LecternTheme.warningTint)
                    } else if case .failed(let message) = antigravityACP.runtimeState {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(LecternTheme.warningTint)
                    }

                    HStack {
                        Spacer()
                        Button("Check again") { Task { await antigravityACP.refresh() } }
                            .controlSize(.small)
                    }
                }
                .padding(16)
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What Lectern sends")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LecternTheme.ink)
                    Text("Lectern sends the prompt and supported attachments through ACP. Audio is sent as a native audio block. Google credentials stay in a private Lectern profile and are never copied from the agy CLI.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .task { await antigravityACP.refresh() }
    }

    private func setupRow<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        done: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? LecternTheme.successTint : LecternTheme.accent.opacity(0.12))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(LecternTheme.accent)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LecternTheme.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
    }

    private var runtimeDetail: String {
        switch antigravityACP.runtimeState {
        case .checking: return "Checking this Mac."
        case .notInstalled: return "Downloads 315 MB directly from Google, then verifies the exact SHA-256 and runtime identity."
        case .installing(let phase, _, _):
            switch phase {
            case .downloading: return "Downloading Google's official ACP runtime."
            case .extracting: return "Extracting the verified runtime."
            case .verifying: return "Checking the downloaded runtime."
            }
        case .ready(let version): return "Installed and verified: \(version)"
        case .cancelled: return "Installation was cancelled. You can retry when ready."
        case .failed: return "The managed runtime needs attention."
        }
    }

    private var accountDetail: String {
        switch antigravityACP.authState {
        case .unavailable: return "Install the runtime first."
        case .signedOut: return "Sign in separately for ACP; Lectern intentionally does not reuse the CLI session."
        case .signingIn: return "Starting the isolated OAuth flow."
        case .waitingForBrowser: return "Finish Google's sign-in in your browser."
        case .signedIn: return "ACP access is ready."
        case .signingOut: return "Signing out of the Lectern ACP profile."
        case .failed: return "Sign-in needs attention."
        }
    }

    @ViewBuilder private var runtimeAction: some View {
        switch antigravityACP.runtimeState {
        case .notInstalled:
            Button("Install Antigravity") { antigravityACP.startInstallation() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .cancelled, .failed:
            Button("Retry installation") { antigravityACP.startInstallation() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            Button("Cancel") { antigravityACP.cancelInstallation() }.controlSize(.small)
        case .ready:
            Text("Ready").font(.system(size: 11, weight: .medium)).foregroundStyle(LecternTheme.successTint)
        }
    }

    @ViewBuilder private var accountAction: some View {
        switch antigravityACP.authState {
        case .signedOut, .failed:
            Button("Sign in with Google") { Task { await antigravityACP.signIn() } }
                .controlSize(.small)
                .disabled(!antigravityACP.isInstalled)
        case .waitingForBrowser:
            HStack(spacing: 6) {
                Button("Open browser again") { antigravityACP.openAuthorizationURLAgain() }
                Button("Cancel") { antigravityACP.cancelSignIn() }
            }
            .controlSize(.small)
        case .signedIn:
            Text("Ready").font(.system(size: 11, weight: .medium)).foregroundStyle(LecternTheme.successTint)
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
}
