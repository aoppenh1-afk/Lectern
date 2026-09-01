import SwiftUI

/// Sheet shown when a newer release exists. Installs in place or defers.
struct UpdatePromptView: View {
    @Environment(AppUpdater.self) private var updater
    @Environment(\.dismiss) private var dismiss
    let release: AppRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(LecternTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lectern \(release.version) is available")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                    Text("You have \(updater.currentVersion). The update downloads from GitHub and Lectern relaunches when it is done.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(LecternTheme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                        .fill(LecternTheme.cardFill)
                )
            }

            statusLine

            HStack {
                Button("Skip this version") {
                    updater.skip(release)
                    dismiss()
                }
                .disabled(isBusy)
                Spacer()
                Button("Later") {
                    updater.pendingPrompt = nil
                    dismiss()
                }
                .disabled(isBusy)
                if release.assetAPIURL == nil {
                    Link("Open Releases page", destination: release.htmlURL)
                } else {
                    Button("Install and relaunch") {
                        Task { await updater.downloadAndInstall(release) }
                    }
                    .prominentAction()
                    .disabled(isBusy)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(LecternTheme.paper)
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch updater.phase {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(LecternTheme.warningTint)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}
