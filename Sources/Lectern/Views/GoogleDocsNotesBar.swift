import SwiftUI

struct GoogleDocsNotesBar: View {
    @Environment(GoogleDocsSyncService.self) private var googleDocs
    @Environment(GoogleDocsAuth.self) private var auth

    let lecture: Lecture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Docs")
                        .font(.system(size: 15, weight: .semibold))
                    Text(destinationLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if googleDocs.notesSyncState(for: lecture) == .pushed {
                    StatusChip("Pushed", LecternTheme.successTint, icon: "checkmark")
                } else if googleDocs.notesSyncState(for: lecture) == .outOfDate {
                    StatusChip("Out of date", LecternTheme.warningTint, icon: "arrow.triangle.2.circlepath")
                }

                if googleDocs.canOpen(lecture: lecture) {
                    Button {
                        googleDocs.openInDocs(lecture: lecture)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right")
                    }
                }

                if auth.isSigningIn || googleDocs.isSyncing {
                    Button("Cancel") {
                        auth.cancelSignIn()
                    }
                } else {
                    Button {
                        Task { await googleDocs.sync(lecture: lecture) }
                    } label: {
                        Text(auth.isSignedIn ? "Push to Docs" : "Sign in & push")
                    }
                    .prominentAction()
                    .tint(LecternTheme.accent)
                }
            }

            if let message = googleDocs.lastMessage {
                HStack(spacing: 6) {
                    Image(systemName: googleDocs.lastSyncSucceeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 12))
                    Spacer()
                    if googleDocs.lastSyncSucceeded, googleDocs.lastDocURL != nil {
                        Button("Open Doc") {
                            googleDocs.openInDocs(lecture: lecture)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(googleDocs.lastSyncSucceeded ? LecternTheme.successTint : LecternTheme.warningTint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (googleDocs.lastSyncSucceeded ? LecternTheme.successTint : LecternTheme.warningTint).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                )
            }
        }
    }

    private var destinationLabel: String {
        if let course = lecture.course {
            return "\(course.name).doc · tab per lecture"
        }
        return "Unfiled.doc · tab per lecture"
    }
}
