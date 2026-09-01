import AppKit
import Foundation
import SwiftData

enum GoogleNotesSyncState {
    case neverPushed
    case pushed
    case outOfDate
}

/// Pushes a lecture's notes into Google Docs: one Doc per Course, one tab
/// per lecture. Lectern overwrites the tab; it does not pull edits back.
@MainActor
@Observable
final class GoogleDocsSyncService {
    private static let unfiledDocKey = "google.unfiledDocId"

    private let auth: GoogleDocsAuth
    private let modelContainer: ModelContainer
    private let client = GoogleDocsClient()

    private(set) var isSyncing = false
    private(set) var lastMessage: String?
    private(set) var lastSyncSucceeded = true
    private(set) var lastDocURL: URL?

    init(auth: GoogleDocsAuth, modelContainer: ModelContainer) {
        self.auth = auth
        self.modelContainer = modelContainer
    }

    func sync(lecture: Lecture) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            guard let notes = lecture.artifact(of: .notes)?.content else {
                throw GoogleDocsError.noNotes
            }
            if !auth.isSignedIn {
                try await auth.signIn()
            }
            let token = try await auth.accessToken()
            let hash = NotesMarkdownConverter.contentHash(of: notes)
            let title = NotesMarkdownConverter.tabTitle(date: lecture.capturedAt, lectureTitle: lecture.title)

            let documentID = try await resolveDocument(for: lecture, accessToken: token)
            var document = try await client.getDocument(id: documentID, accessToken: token)
            let tab = try await resolveTab(
                lecture: lecture,
                document: document,
                title: title,
                accessToken: token
            )
            document = try await client.getDocument(id: documentID, accessToken: token)
            let tabNow = document.tabs.first(where: { $0.id == tab.id }) ?? tab

            if tabNow.title != title {
                try? await client.renameTab(
                    documentID: documentID,
                    tabID: tabNow.id,
                    title: title,
                    accessToken: token
                )
            }

            lecture.googleTabId = tabNow.id
            if lecture.course != nil {
                lecture.course?.googleDocId = documentID
            } else {
                UserDefaults.standard.set(documentID, forKey: Self.unfiledDocKey)
            }

            if lecture.googleNotesHash == hash {
                lastMessage = "Notes already match the Google Doc tab."
                lastSyncSucceeded = true
                lastDocURL = GoogleDocsClient.editURL(documentID: documentID, tabID: tabNow.id)
                try? modelContainer.mainContext.save()
                return
            }

            let plan = NotesMarkdownConverter.plan(markdown: notes)
            try await client.replaceTabContent(
                documentID: documentID,
                tabID: tabNow.id,
                bodyEndIndex: tabNow.bodyEndIndex,
                plan: plan,
                accessToken: token
            )

            lecture.googleNotesHash = hash
            try? modelContainer.mainContext.save()

            lastDocURL = GoogleDocsClient.editURL(documentID: documentID, tabID: tabNow.id)
            lastMessage = "Pushed notes to \(document.title) · \(title)"
            lastSyncSucceeded = true
        } catch {
            lastMessage = error.localizedDescription
            lastSyncSucceeded = false
        }
    }

    func openInDocs(lecture: Lecture) {
        let documentID: String?
        if let course = lecture.course {
            documentID = course.googleDocId
        } else {
            documentID = UserDefaults.standard.string(forKey: Self.unfiledDocKey)
        }
        guard let documentID,
              let url = GoogleDocsClient.editURL(documentID: documentID, tabID: lecture.googleTabId) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func canOpen(lecture: Lecture) -> Bool {
        if let course = lecture.course { return course.googleDocId != nil }
        return UserDefaults.standard.string(forKey: Self.unfiledDocKey) != nil
    }

    func notesSyncState(for lecture: Lecture) -> GoogleNotesSyncState {
        guard let pushedHash = lecture.googleNotesHash else { return .neverPushed }
        guard let notes = lecture.artifact(of: .notes)?.content else { return .outOfDate }
        return NotesMarkdownConverter.contentHash(of: notes) == pushedHash ? .pushed : .outOfDate
    }

    // MARK: - Resolve

    private func resolveDocument(for lecture: Lecture, accessToken: String) async throws -> String {
        if let existing = storedDocumentID(for: lecture) {
            do {
                _ = try await client.getDocument(id: existing, accessToken: accessToken)
                return existing
            } catch let error as GoogleDocsError where error.isNotFound {
                forgetDocument(for: lecture)
            }
        }

        let created = try await client.createDocument(
            title: lecture.course?.name ?? "Unfiled",
            accessToken: accessToken
        )
        saveDocumentID(created.id, for: lecture)
        return created.id
    }

    private func resolveTab(
        lecture: Lecture,
        document: GoogleDocument,
        title: String,
        accessToken: String
    ) async throws -> GoogleTab {
        if let id = lecture.googleTabId, let match = document.tabs.first(where: { $0.id == id }) {
            return match
        }
        if let match = document.tabs.first(where: { $0.title == title }) {
            return match
        }
        if lecture.googleTabId == nil,
           document.tabs.count == 1,
           let only = document.tabs.first,
           only.isEmpty {
            do {
                try await client.renameTab(
                    documentID: document.id,
                    tabID: only.id,
                    title: title,
                    accessToken: accessToken
                )
                return GoogleTab(id: only.id, title: title, bodyEndIndex: only.bodyEndIndex)
            } catch {
                return only
            }
        }

        let tabID = try await client.addDocumentTab(
            documentID: document.id,
            title: title,
            accessToken: accessToken
        )
        return GoogleTab(id: tabID, title: title, bodyEndIndex: 2)
    }

    private func storedDocumentID(for lecture: Lecture) -> String? {
        if let course = lecture.course { return course.googleDocId }
        return UserDefaults.standard.string(forKey: Self.unfiledDocKey)
    }

    private func saveDocumentID(_ id: String, for lecture: Lecture) {
        if let course = lecture.course {
            course.googleDocId = id
        } else {
            UserDefaults.standard.set(id, forKey: Self.unfiledDocKey)
        }
    }

    private func forgetDocument(for lecture: Lecture) {
        if let course = lecture.course {
            course.googleDocId = nil
            for sibling in course.lectures {
                sibling.googleTabId = nil
                sibling.googleNotesHash = nil
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.unfiledDocKey)
            lecture.googleTabId = nil
            lecture.googleNotesHash = nil
        }
    }
}
