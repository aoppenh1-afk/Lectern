import SwiftUI

struct CanvasSettingsPane: View {
    @Environment(CanvasConnectionSettings.self) private var connection
    @Environment(CanvasSyncService.self) private var sync
    @State private var domain = ""
    @State private var token = ""
    @State private var message: String?
    @State private var showsWalkthrough = true

    private var isConnected: Bool { connection.isConnected }
    private var canConnect: Bool {
        !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.hasToken)
    }
    private var isSuccessMessage: Bool { (message ?? "").hasPrefix("Connected") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        settingsIcon("building.columns", tint: LecternTheme.accent)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Canvas")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(LecternTheme.ink)
                                statusChip
                            }
                            Text("Lectern syncs courses, deadlines, calendar events, grades, modules, and announcements. Your token stays in macOS Keychain.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button {
                            Task { await sync.syncNow() }
                        } label: {
                            Label("Sync", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!isConnected || sync.isSyncing)
                    }
                    .padding(16)

                    settingsDivider

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(title: "Canvas address")
                            SettingsTextField(placeholder: "your-school.instructure.com", text: $domain)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SettingsFieldLabel(title: "Personal access token")
                                Spacer()
                                if let masked = connection.maskedToken {
                                    Text(masked)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            SettingsSecureField(
                                placeholder: connection.hasToken ? "Leave blank to keep current token" : "Paste your Canvas token",
                                text: $token
                            )
                        }

                        if let message {
                            HStack(spacing: 6) {
                                Image(systemName: isSuccessMessage ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSuccessMessage ? LecternTheme.successTint : LecternTheme.warningTint)
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSuccessMessage ? LecternTheme.successTint : LecternTheme.warningTint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(16)

                    settingsDivider

                    HStack(spacing: 6) {
                        Button(isConnected ? "Save and sync" : "Connect and sync") { connect() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canConnect || sync.isSyncing)

                        if isConnected {
                            Button("Disconnect", role: .destructive) { disconnect() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }

                        Spacer()

                        if sync.isSyncing {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        settingsIcon("key", tint: .secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Create a Canvas token")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                            Text("Four steps in Canvas. It takes about a minute.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(showsWalkthrough ? "Hide steps" : "Show steps") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showsWalkthrough.toggle()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                    }

                    if showsWalkthrough {
                        VStack(alignment: .leading, spacing: 14) {
                            walkthroughStep(
                                number: 1,
                                text: "In Canvas, click Account in the left sidebar, then Settings.",
                                imageName: "CanvasTokenStep1"
                            )
                            walkthroughStep(
                                number: 2,
                                text: "Scroll to Approved Integrations, then click + New Access Token.",
                                imageName: "CanvasTokenStep2"
                            )
                            walkthroughStep(
                                number: 3,
                                text: "Purpose: Lectern. Pick an expiry date, then Generate Token. Many schools cap expiry at 30 days.",
                                imageName: "CanvasTokenStep3"
                            )
                            walkthroughStep(
                                number: 4,
                                text: "Copy the token now. Canvas shows it once. Paste it above, then Connect and sync.",
                                imageName: "CanvasTokenStep4"
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text("When the token lapses, repeat these steps and paste the new token above. If your school blocks student tokens, ask campus IT for an OAuth developer key.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let guideURL = URL(string: "https://community.instructure.com/en/kb/articles/662901-how-do-i-manage-api-access-tokens-in-my-user-account") {
                                    Link("Open full Canvas guide", destination: guideURL)
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            if sync.lastSyncAt != nil || !sync.lastWarnings.isEmpty {
                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        settingsIcon("arrow.clockwise", tint: .secondary)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Sync status")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                            if let date = sync.lastSyncAt {
                                MetaText(["Last sync \(date.formatted(date: .abbreviated, time: .shortened))"])
                            }
                            if !sync.lastWarnings.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Some Canvas sections could not sync")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(LecternTheme.warningTint)
                                    ForEach(sync.lastWarnings.prefix(4), id: \.self) { warning in
                                        Text(warning)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear { domain = connection.domain }
    }

    private var statusChip: StatusChip {
        if isConnected {
            StatusChip("Connected", LecternTheme.successTint, icon: "checkmark")
        } else {
            StatusChip("Not connected", .secondary, icon: "circle.dashed")
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func walkthroughStep(number: Int, text: String, imageName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(LecternTheme.accent, in: Circle())
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LecternTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .accessibilityLabel("Canvas screenshot for step \(number)")
        }
    }

    private func settingsIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func connect() {
        do {
            if token.isEmpty && connection.hasToken {
                let existing = try connection.credentials().token
                try connection.save(domain: domain, token: existing)
            } else {
                try connection.save(domain: domain, token: token)
            }
            token = ""
            message = "Connected. Syncing your Canvas data now."
            Task { await sync.syncNow() }
        } catch {
            message = error.localizedDescription
        }
    }

    private func disconnect() {
        do {
            try connection.disconnect()
            domain = ""
            token = ""
            message = "Canvas disconnected. Synced data remains available offline."
        } catch {
            message = error.localizedDescription
        }
    }
}
