import SwiftUI

struct CanvasSettingsPane: View {
    @Environment(CanvasConnectionSettings.self) private var connection
    @Environment(CanvasSyncService.self) private var sync
    @State private var domain = ""
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 22)).foregroundStyle(LecternTheme.accent).frame(width: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.isConnected ? "Canvas is connected" : "Connect your school Canvas")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Lectern syncs courses, deadlines, calendar events, grades, modules, and announcements. Your token stays in macOS Keychain.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Canvas address").font(.system(size: 11, weight: .semibold))
                        TextField("school.instructure.com", text: $domain).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Personal access token").font(.system(size: 11, weight: .semibold)); Spacer(); if let masked = connection.maskedToken { Text(masked).font(.system(size: 10).monospaced()).foregroundStyle(.secondary) } }
                        SecureField(connection.hasToken ? "Leave blank to keep current token" : "Paste token", text: $token).textFieldStyle(.roundedBorder)
                    }

                    if let message { Text(message).font(.system(size: 11)).foregroundStyle(message.hasPrefix("Connected") ? LecternTheme.successTint : LecternTheme.warningTint) }

                    HStack {
                        Button(connection.isConnected ? "Save and sync" : "Connect and sync") { connect() }
                            .prominentAction()
                        Button("Sync now") { Task { await sync.syncNow() } }
                            .disabled(!connection.isConnected || sync.isSyncing)
                        if sync.isSyncing { ProgressView().controlSize(.small); Text("Syncing Canvas…").font(.system(size: 11)).foregroundStyle(.secondary) }
                        Spacer()
                        if connection.isConnected {
                            Button("Disconnect", role: .destructive) { disconnect() }
                        }
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create a Canvas token").font(.system(size: 13, weight: .semibold))
                    Text("In Canvas, open Account > Settings, find Approved Integrations, and create a new access token. Some schools disable student-created tokens; in that case Lectern will need an OAuth developer key from campus IT.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let date = sync.lastSyncAt { Text("Last successful sync: \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    if !sync.lastWarnings.isEmpty {
                        Divider()
                        Text("Some Canvas sections could not sync").font(.system(size: 11, weight: .semibold)).foregroundStyle(LecternTheme.warningTint)
                        ForEach(sync.lastWarnings.prefix(4), id: \.self) { warning in
                            Text(warning).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear { domain = connection.domain }
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
