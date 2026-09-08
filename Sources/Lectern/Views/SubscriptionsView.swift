import SwiftData
import SwiftUI

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ShiurAutomationService.self) private var automationService

    @Query(sort: \ShiurSubscription.createdAt, order: .reverse)
    private var subscriptions: [ShiurSubscription]

    @Query(filter: #Predicate<ShiurAutomationItem> { $0.stateRaw == "failed" },
           sort: \ShiurAutomationItem.updatedAt, order: .reverse)
    private var failedItems: [ShiurAutomationItem]

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
                failedImportsSection
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

    @ViewBuilder
    private var failedImportsSection: some View {
        if !failedItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Imports needing attention")
                        .font(.headline)
                    Spacer()
                    Button("Dismiss All") {
                        automationService.dismissFailedItems(failedItems)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .help("Remove all failed imports from this list")
                }
                ForEach(failedItems) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.stateMessage ?? "Import stopped before completion.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button("Retry") {
                                Task { await automationService.retryItem(item) }
                            }
                            .disabled(automationService.activeItemIDs.contains(item.id))
                            Button("Dismiss") {
                                automationService.dismissItem(item)
                            }
                            .foregroundStyle(.secondary)
                            .disabled(automationService.activeItemIDs.contains(item.id))
                            .help("Remove this failed import from the list")
                        }
                    }
                }
            }
            .padding(14)
            .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10))
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
            HStack(spacing: 16) {
                // Leading type icon
                Image(systemName: leadingIcon(for: sub))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color(red: 0.32, green: 0.6, blue: 1.0))
                    .frame(width: 48, height: 48)
                    .background(
                        Color.blue.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 10) {
                    // Title + pills row
                    HStack(spacing: 10) {
                        Text(sub.displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LecternTheme.ink)
                            .lineLimit(1)

                        pill(icon: pillIcon(for: sub), text: sub.targetType.displayName, accent: true)

                        pillDivider(height: 18)

                        pill(icon: "clock", text: sub.cadence.title, accent: false)

                        pillDivider(height: 18)

                        if let course = sub.course {
                            pill(icon: "tag", text: course.name, accent: false)
                        } else {
                            pill(icon: "tag", text: "Unfiled", accent: false)
                        }
                    }

                    // Meta row
                    HStack(spacing: 12) {
                        if sub.autoTranscribe {
                            metaItem(icon: "waveform", text: "Auto-transcribe")
                        }
                        if sub.autoTranscribe && sub.autoGenerateNotes {
                            metaDivider()
                        }
                        if sub.autoGenerateNotes {
                            metaItem(icon: "sparkles", text: "Clean up transcript & note taking")
                        }
                        if sub.autoTranscribe || sub.autoGenerateNotes {
                            metaDivider()
                        }
                        metaItem(icon: "doc.text", text: "Imported: \(sub.importedCount)")
                        metaDivider()
                        if let lastImport = sub.lastImportedTitle {
                            metaItem(icon: "clock", text: "Latest: \(lastImport)")
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 16)

                // Right actions
                HStack(spacing: 16) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 48)

                    Button {
                        Task {
                            await automationService.checkSubscription(sub, ignoreDue: true)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Check Now")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(
                            Color(red: 0.16, green: 0.38, blue: 0.88),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 28)

                    HStack(spacing: 18) {
                        Button {
                            editingSubscription = sub
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help("Edit subscription")

                        Button {
                            sub.isEnabled.toggle()
                            try? modelContext.save()
                        } label: {
                            Image(systemName: sub.isEnabled ? "pause.circle" : "play.circle")
                                .font(.system(size: 21, weight: .regular))
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help(sub.isEnabled ? "Pause subscription" : "Resume subscription")

                        Button {
                            modelContext.delete(sub)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help("Delete subscription")
                    }
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
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LecternTheme.hairline))
    }

    private func leadingIcon(for sub: ShiurSubscription) -> String {
        switch sub.targetType {
        case .teacher: return "person"
        case .series: return "square.stack"
        case .collection: return "book"
        case .rss: return "antenna.radiowaves.left.and.right"
        }
    }

    private func pillIcon(for sub: ShiurSubscription) -> String {
        switch sub.targetType {
        case .teacher: return "person"
        case .series: return "square.stack"
        case .collection: return "circle.stack"
        case .rss: return "link"
        }
    }

    private func pill(icon: String, text: String, accent: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(accent ? Color(red: 0.36, green: 0.63, blue: 1.0) : Color.primary.opacity(0.72))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            (accent ? Color.blue.opacity(0.14) : Color.primary.opacity(0.05)),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    accent ? Color.blue.opacity(0.28) : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
    }

    private func pillDivider(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: height)
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func metaDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
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
