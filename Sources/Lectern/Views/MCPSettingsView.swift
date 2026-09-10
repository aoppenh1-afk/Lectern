import AppKit
import SwiftData
import SwiftUI

struct MCPSettingsPane: View {
    @Environment(LecternCloudSharing.self) private var sharing
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Course.name) private var courses: [Course]
    @State private var confirmsDeletion = false

    var body: some View {
        @Bindable var sharing = sharing
        VStack(alignment: .leading, spacing: 18) {
            Text("Read your lectures from ChatGPT and Claude")
                .font(.title2.bold())
            Text("Sign in, choose courses, and share their notes and transcripts with your hosted Lectern account. Your AI can read the last synced copy even while your Mac is closed.")
                .foregroundStyle(.secondary)
            HStack {
                if sharing.auth.isSigningIn {
                    ProgressView().controlSize(.small)
                    Button("Cancel sign-in") { sharing.auth.cancelSignIn() }
                } else {
                    Button(sharing.auth.isSignedIn ? "Reconnect account" : "Sign in with Google") {
                        Task { await sharing.signIn() }
                    }
                    .disabled(sharing.isBusy)
                }
                if let email = sharing.email { Text(email).foregroundStyle(.secondary) }
            }
            if let warning = sharing.auth.credentialWarning {
                Text(warning).font(.callout).foregroundStyle(.orange)
            }
            GroupBox("Choose courses to share") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(courses) { course in
                        if let id = try? LecternCloudSharing.id(for: course.persistentModelID) {
                            Toggle(course.name, isOn: Binding(
                                get: { sharing.sharedCourseIDs.contains(id) },
                                set: { if $0 { sharing.sharedCourseIDs.insert(id) } else { sharing.sharedCourseIDs.remove(id) } }
                            ))
                        }
                    }
                    Toggle("Unfiled lectures", isOn: $sharing.shareUnfiled)
                }
                .disabled(sharing.isBusy)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Text("Only course names, lecture titles, dates, notes and transcripts are uploaded. Recordings, attachments, chats and service credentials stay out of the shared library. Changes sync while Lectern is open; removing a course takes effect after a successful sync.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(sharing.needsReview ? "Replace hosted selection" : sharing.sharingEnabled ? "Sync now" : "Start sharing") {
                    Task {
                        if sharing.sharingEnabled && !sharing.needsReview { await sharing.syncIfNeeded() }
                        else { await sharing.startSharing() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sharing.auth.isSignedIn || sharing.isBusy)
                if sharing.isBusy { ProgressView().controlSize(.small) }
            }
            Text(sharing.status).font(.callout).textSelection(.enabled)
            if sharing.needsReview {
                Text("Replacing uses this Mac’s selection and replaces the current hosted library. Reconnect first if access was revoked.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let lastSync = sharing.lastSync {
                Text("Last successful sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Connect your AI") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add this server URL in ChatGPT or Claude:")
                    HStack {
                        Text(LecternCloudSharing.connectionURL.absoluteString)
                            .font(.callout.monospaced()).textSelection(.enabled)
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LecternCloudSharing.connectionURL.absoluteString, forType: .string)
                        }
                    }
                    Text("ChatGPT: enable developer mode and add an MCP connection with OAuth authentication. Claude: add a custom connector. Sign in with the same Google account, approve read access, and enable Lectern in the conversation.")
                    Text("Try: “Find my latest biology lecture and explain its notes.”")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Manage connections and shared data", destination: LecternCloudAuth.origin.appendingPathComponent("connect"))
                    HStack {
                        Link("ChatGPT setup", destination: URL(string: "https://developers.openai.com/plugins/deploy/connect-chatgpt")!)
                        Link("Claude setup", destination: URL(string: "https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp")!)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Button("Delete hosted library and disconnect all apps", role: .destructive) { confirmsDeletion = true }
                .disabled(!sharing.auth.isSignedIn || sharing.isBusy)
            Text("Deleting the hosted copy keeps your local library. Copies already read by an AI service may remain with that service.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { try? modelContext.save() }
        .onChange(of: sharing.sharedCourseIDs) { _, _ in Task { await sharing.syncIfNeeded() } }
        .onChange(of: sharing.shareUnfiled) { _, _ in Task { await sharing.syncIfNeeded() } }
        .confirmationDialog("Delete the hosted library and revoke all connections?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete hosted library", role: .destructive) { Task { await sharing.deleteHostedLibrary() } }
        } message: { Text("ChatGPT, Claude and connected Macs will lose access. Lectern’s local notes and transcripts will be kept.") }
    }
}
