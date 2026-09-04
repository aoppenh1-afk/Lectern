import SwiftData
import SwiftUI

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ShiurAutomationService.self) private var automationService

    @Query(sort: \ShiurSubscription.createdAt, order: .reverse)
    private var subscriptions: [ShiurSubscription]

    @State private var pendingTeacher: (id: Int, name: String, previews: [RemoteShiurItem])?
    @State private var pendingSeries: (id: Int, title: String, previews: [RemoteShiurItem])?
    @State private var pendingCollection: (id: Int, title: String, previews: [RemoteShiurItem])?
    @State private var pendingShiur: RemoteShiurItem?
    @State private var editingSubscription: ShiurSubscription?

    @State private var pasteLinkOpen = false
    @State private var pastedURLString = ""
    @State private var pasteError: String?
    @State private var isResolvingPaste = false

    private let provider = YUTorahSourceProvider()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                // Native Search Area
                YUTorahSearchView(
                    onSelectTeacher: { id, name, previews in
                        resolveAndOpenTeacher(id: id, name: name, previews: previews)
                    },
                    onSelectSeries: { id, title, previews in
                        resolveAndOpenSeries(id: id, title: title, previews: previews)
                    },
                    onSelectCollection: { id, title, previews in
                        resolveAndOpenCollection(id: id, title: title, previews: previews)
                    },
                    onSelectShiur: { item in
                        pendingShiur = item
                    }
                )

                subscriptionsSection
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
        }
        .background(LecternTheme.paper)
        .sheet(item: Binding(
            get: { pendingTeacher.map { IdentifiedTeacher(id: $0.id, name: $0.name, previews: $0.previews) } },
            set: { pendingTeacher = $0.map { ($0.id, $0.name, $0.previews) } }
        )) { teacher in
            SubscriptionEditorView(resolved: ResolvedSubscription(
                targetType: .teacher,
                targetNumericID: teacher.id,
                displayName: teacher.name,
                originalURL: nil,
                feedURL: YUTorahURLResolver.teacherFeedURL(teacherID: teacher.id),
                previewItems: teacher.previews
            ))
        }
        .sheet(item: Binding(
            get: { pendingSeries.map { IdentifiedSeries(id: $0.id, title: $0.title, previews: $0.previews) } },
            set: { pendingSeries = $0.map { ($0.id, $0.title, $0.previews) } }
        )) { series in
            SubscriptionEditorView(resolved: ResolvedSubscription(
                targetType: .series,
                targetNumericID: series.id,
                displayName: series.title,
                originalURL: nil,
                feedURL: YUTorahURLResolver.seriesFeedCandidateURLs(seriesID: series.id)[0],
                previewItems: series.previews
            ))
        }
        .sheet(item: Binding(
            get: { pendingCollection.map { IdentifiedCollection(id: $0.id, title: $0.title, previews: $0.previews) } },
            set: { pendingCollection = $0.map { ($0.id, $0.title, $0.previews) } }
        )) { collection in
            SubscriptionEditorView(resolved: ResolvedSubscription(
                targetType: .collection,
                targetNumericID: collection.id,
                displayName: collection.title,
                originalURL: nil,
                feedURL: YUTorahURLResolver.collectionFeedURL(collectionID: collection.id),
                previewItems: collection.previews
            ))
        }
        .sheet(item: $pendingShiur) { item in
            ShiurImportSheet(item: item)
        }
        .sheet(item: $editingSubscription) { sub in
            SubscriptionEditorView(subscription: sub)
        }
        .popover(isPresented: $pasteLinkOpen) {
            pasteLinkPopover
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Subscriptions")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)

                Text("Automatically discover, download, and turn new shiurim into notes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    pasteLinkOpen = true
                } label: {
                    Label("Paste YU Torah Link…", systemImage: "link")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if !subscriptions.isEmpty {
                    Button {
                        Task {
                            await automationService.checkSubscriptions(dueOnly: false)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if automationService.isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Check All")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(automationService.isChecking)
                }
            }
        }
    }

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ACTIVE SUBSCRIPTIONS (\(subscriptions.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LecternTheme.ink.opacity(0.75))
                Spacer()
            }

            if subscriptions.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(subscriptions) { sub in
                        subscriptionCard(sub)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 32))
                .foregroundStyle(LecternTheme.accent.opacity(0.8))
                .padding(.top, 24)

            Text("No shiur subscriptions yet")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(LecternTheme.ink)

            Text("Search for a teacher like “Rabbi Rosensweig” or “Rabbi Sobolofsky”, a series like “Kollel Yom Rishon”, or an individual shiur above. Lectern will automatically pull new shiurim, transcribe them, and generate study notes.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LecternTheme.hairline))
    }

    private func subscriptionCard(_ sub: ShiurSubscription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(sub.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LecternTheme.ink)

                        let targetColor: Color = {
                            switch sub.targetType {
                            case .teacher: return .blue
                            case .series: return .orange
                            case .collection: return .teal
                            case .rss: return .purple
                            }
                        }()
                        badge(sub.targetType.displayName, color: targetColor)
                        badge(sub.cadence.title, color: .blue)
                        if let course = sub.course {
                            badge(course.name, color: .green)
                        } else {
                            badge("Unfiled", color: .gray)
                        }
                    }

                    HStack(spacing: 12) {
                        if sub.autoTranscribe {
                            Label("Auto-transcribe", systemImage: "waveform")
                        }
                        if sub.autoGenerateNotes {
                            Label("Auto-Notes", systemImage: "sparkles")
                        }
                        Text("Imported: \(sub.importedCount)")
                        if let lastImport = sub.lastImportedTitle {
                            Text("Latest: \(lastImport)")
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Check Now") {
                        Task {
                            await automationService.checkSubscription(sub, ignoreDue: true)
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                    Button {
                        editingSubscription = sub
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)

                    Button {
                        sub.isEnabled.toggle()
                        try? modelContext.save()
                    } label: {
                        Image(systemName: sub.isEnabled ? "pause.circle" : "play.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(sub.isEnabled ? Color.secondary : LecternTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .help(sub.isEnabled ? "Pause subscription" : "Resume subscription")

                    Button {
                        modelContext.delete(sub)
                        try? modelContext.save()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = sub.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LecternTheme.warningTint)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(LecternTheme.warningTint)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LecternTheme.warningTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(16)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LecternTheme.hairline))
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var pasteLinkPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste YU Torah Link")
                .font(.system(size: 14, weight: .semibold))

            TextField("https://www.yutorah.org/...", text: $pastedURLString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            if let pasteError {
                Text(pasteError)
                    .font(.system(size: 11))
                    .foregroundStyle(LecternTheme.warningTint)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    pasteLinkOpen = false
                    pasteError = nil
                }
                Button("Resolve") {
                    resolvePastedLink()
                }
                .prominentAction()
                .tint(LecternTheme.accent)
                .disabled(pastedURLString.trimmingCharacters(in: .whitespaces).isEmpty || isResolvingPaste)
            }
        }
        .padding(16)
    }

    private func resolvePastedLink() {
        guard let url = URL(string: pastedURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            pasteError = "Invalid URL."
            return
        }

        isResolvingPaste = true
        pasteError = nil

        Task {
            do {
                let result = try await provider.resolveSharedURL(url)
                await MainActor.run {
                    self.isResolvingPaste = false
                    self.pasteLinkOpen = false
                    switch result {
                    case .teacher(let id, let name, _, let previews):
                        self.pendingTeacher = (id, name, previews)
                    case .series(let id, let title, _, let previews):
                        self.pendingSeries = (id, title, previews)
                    case .collection(let id, let title, _, let previews):
                        self.pendingCollection = (id, title, previews)
                    case .shiur(let item):
                        self.pendingShiur = item
                    }
                }
            } catch {
                await MainActor.run {
                    self.isResolvingPaste = false
                    self.pasteError = error.localizedDescription
                }
            }
        }
    }

    private func resolveAndOpenTeacher(id: Int, name: String, previews: [RemoteShiurItem]) {
        pendingTeacher = (id, name, previews)
    }

    private func resolveAndOpenSeries(id: Int, title: String, previews: [RemoteShiurItem]) {
        pendingSeries = (id, title, previews)
    }

    private func resolveAndOpenCollection(id: Int, title: String, previews: [RemoteShiurItem]) {
        pendingCollection = (id, title, previews)
    }
}

private struct IdentifiedTeacher: Identifiable {
    let id: Int
    let name: String
    let previews: [RemoteShiurItem]
}

private struct IdentifiedSeries: Identifiable {
    let id: Int
    let title: String
    let previews: [RemoteShiurItem]
}

private struct IdentifiedCollection: Identifiable {
    let id: Int
    let title: String
    let previews: [RemoteShiurItem]
}
