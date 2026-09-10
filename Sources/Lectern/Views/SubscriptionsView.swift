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
            VStack(alignment: .leading, spacing: 28) {
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
                    },
                    subscriptionsContent: { AnyView(subscriptionsSection) }
                )

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
                    .font(.system(size: 38, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)

                Text("Automate your learning from YU Torah.")
                    .font(.system(size: 20, design: .serif))
                    .foregroundStyle(LecternTheme.ink.opacity(0.8))
                    .padding(.top, 3)

                Text("Subscribe to teachers, series, or collections. Lectern watches for new shiurim and turns them into transcripts and study notes in your library.")
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .frame(maxWidth: 650, alignment: .leading)
                    .padding(.top, 6)
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
            Divider().overlay(LecternTheme.hairline).padding(.bottom, 4)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your subscriptions")
                        .font(.system(size: 23, weight: .semibold, design: .serif))
                    Text("\(subscriptions.filter(\.isEnabled).count) active · Watching for new shiurim")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(subscriptions.count == 1 ? "1 source" : "\(subscriptions.count) sources")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LecternTheme.accent)
            }

            if subscriptions.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 14)], spacing: 14) {
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

            Text("Choose a recommended teacher below or search YU Torah to find your next shiur. New shiurim will appear here automatically once you subscribe.")
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                YUTorahSourcePortrait(teacherID: sub.targetType == .teacher ? sub.targetNumericID : nil,
                                     symbol: leadingIcon(for: sub), size: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Text(sub.displayName)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        Text(sub.targetType.displayName)
                            .foregroundStyle(LecternTheme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(LecternTheme.accent.opacity(0.09), in: Capsule())
                        Text(sub.isEnabled ? "Active" : "Paused")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                Menu {
                    Button("Check now", systemImage: "arrow.clockwise") {
                        Task { await automationService.checkSubscription(sub, ignoreDue: true) }
                    }
                    .disabled(automationService.isChecking)
                    Button(sub.isEnabled ? "Pause subscription" : "Resume subscription",
                           systemImage: sub.isEnabled ? "pause.circle" : "play.circle") {
                        sub.isEnabled.toggle()
                        try? modelContext.save()
                    }
                    Divider()
                    Button("Delete subscription", systemImage: "trash", role: .destructive) {
                        modelContext.delete(sub)
                        try? modelContext.save()
                    }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                        .frame(width: 18, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Subscription options")
            }
            VStack(alignment: .leading, spacing: 9) {
                Label(sub.cadence == .daily ? "Daily" : sub.cadence.title, systemImage: "calendar")
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                    if let date = sub.lastCheckedAt {
                        Text("Checked \(date.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Not checked yet")
                    }
                }
                Label("\(sub.importedCount) imported", systemImage: "doc.text")
                Label(sub.course?.name ?? "Unfiled", systemImage: "folder")
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let error = sub.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(LecternTheme.warningTint)
                    .lineLimit(2).help(error)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    Task { await automationService.checkSubscription(sub, ignoreDue: true) }
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
                .disabled(automationService.isChecking)
                Button { editingSubscription = sub } label: {
                    Label("Manage", systemImage: "gearshape")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(LecternTheme.accent)
                        .background(LecternTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 255, alignment: .topLeading)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(LecternTheme.hairline))
        .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
    }

    private func leadingIcon(for sub: ShiurSubscription) -> String {
        switch sub.targetType {
        case .teacher: return "person.fill"
        case .series: return "books.vertical"
        case .collection: return "book"
        case .rss: return "antenna.radiowaves.left.and.right"
        }
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
