import SwiftData
import SwiftUI

struct FlashcardsView: View {
    @Environment(CardSyncService.self) private var cardSync
    @Environment(\.modelContext) private var modelContext

    let lecture: Lecture

    private var dueCount: Int {
        lecture.flashcards.filter { $0.syncState != .pushed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let message = cardSync.lastMessage {
                HStack(spacing: 6) {
                    Image(systemName: cardSync.lastSyncSucceeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 12))
                }
                .foregroundStyle(cardSync.lastSyncSucceeded ? LecternTheme.successTint : LecternTheme.warningTint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (cardSync.lastSyncSucceeded ? LecternTheme.successTint : LecternTheme.warningTint).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                )
            }

            if lecture.flashcards.isEmpty {
                Text("No flashcards yet — generate them from the lecture.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(Array(lecture.flashcards.sorted { $0.createdAt < $1.createdAt }.enumerated()),
                            id: \.element.persistentModelID) { index, card in
                        CardRow(index: index + 1, card: card) {
                            modelContext.delete(card)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(lecture.flashcards.count) flashcards")
                    .font(.system(size: 15, weight: .semibold))
                Text("Deck · \(CardSyncService.deck(for: lecture))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if dueCount > 0 {
                StatusChip("\(dueCount) pending", LecternTheme.warningTint,
                           icon: "clock.arrow.circlepath")
            } else if !lecture.flashcards.isEmpty {
                StatusChip("All synced", LecternTheme.successTint, icon: "checkmark")
            }

            Button {
                cardSync.exportToDesktop(lecture: lecture)
            } label: {
                Label("CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(lecture.flashcards.isEmpty)

            Button {
                Task { await cardSync.sync(lecture: lecture) }
            } label: {
                if cardSync.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 52)
                } else {
                    Text("Sync to Anki")
                }
            }
            .prominentAction()
            .tint(LecternTheme.accent)
            .disabled(cardSync.isSyncing || dueCount == 0)
        }
    }
}

private struct CardRow: View {
    let index: Int
    let card: Flashcard
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var isEditing = false
    @State private var frontDraft = ""
    @State private var backDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.05), in: Circle())

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Front (question)", text: $frontDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .medium))
                    TextField("Back (answer)", text: $backDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))

                    HStack {
                        Spacer()
                        Button("Cancel") { isEditing = false }
                            .controlSize(.small)
                        Button("Save") { save() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(LecternTheme.accent)
                            .disabled(frontDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                      || backDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.front)
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                    Text(card.back)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    hoverButton("pencil") { beginEditing() }
                    hoverButton("trash") { onDelete() }
                }
                .opacity(hovering ? 1 : 0)

                syncChip
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.055) : LecternTheme.surfaceFill)
        }
        .overlay(
            RoundedRectangle(cornerRadius: LecternTheme.cardRadius, style: .continuous)
                .strokeBorder(LecternTheme.hairline, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(LecternTheme.standardAnimation, value: hovering)
        .onTapGesture(count: 2) { beginEditing() }
        .contextMenu {
            Button("Edit Card…") { beginEditing() }
            Button("Delete Card", role: .destructive) { onDelete() }
        }
    }

    private func hoverButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon == "pencil" ? "Edit card" : "Delete card")
    }

    private func beginEditing() {
        frontDraft = card.front
        backDraft = card.back
        isEditing = true
    }

    private func save() {
        card.front = frontDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        card.back = backDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Edits after a push mean the Anki copy is now stale.
        if card.syncState == .pushed {
            card.syncState = .pending
        }
        isEditing = false
    }

    private var syncChip: some View {
        let (label, tint, icon): (String, Color, String?) = switch card.syncState {
        case .pending: ("Pending", LecternTheme.warningTint, nil)
        case .pushed: ("In Anki", LecternTheme.successTint, "checkmark")
        case .failed: ("Failed", LecternTheme.recordTint, "exclamationmark")
        }
        return StatusChip(label, tint, icon: icon)
    }
}
