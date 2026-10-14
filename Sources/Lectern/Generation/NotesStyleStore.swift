import Foundation
import Observation
import Darwin

/// Personal style revisions live outside both the app bundle and global agent configuration.
@MainActor
@Observable
final class NotesStyleStore {
    static let shared = NotesStyleStore()

    private struct Library: Codable {
        var version = 1
        var preference: NotesStyleSelection = .lecternDefault
        var activeRevision: UUID?
        var revisions: [PersonalNotesStyle] = []
        var samples: [NotesStyleSample] = []
    }

    private var library = Library()
    let directory: URL
    private(set) var loadError: String?

    var samples: [NotesStyleSample] { library.samples }
    var preferredSelection: NotesStyleSelection { library.preference }
    var current: PersonalNotesStyle? {
        library.revisions.first { $0.id == library.activeRevision }
    }
    var revisions: [PersonalNotesStyle] { library.revisions.reversed() }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Note Styles", isDirectory: true)
        let file = self.directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 8_000_000 else { throw NotesStyleError.invalid("The saved style library is too large.") }
            let decoded = try JSONDecoder().decode(Library.self, from: data)
            guard decoded.version == 1, decoded.preference != .savedPreference else {
                throw NotesStyleError.invalid("The saved style library has an unsupported format.")
            }
            library = decoded
        } catch {
            loadError = "Lectern could not load your saved style. Default Lectern style will be used. \(error.localizedDescription)"
        }
    }

    func skillURL(for id: UUID) -> URL {
        directory.appendingPathComponent("Revisions", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    func resolve(_ selection: NotesStyleSelection = .savedPreference) -> (snapshot: NotesStyleSnapshot, warning: String?) {
        let selected = selection == .savedPreference ? library.preference : selection
        guard selected == .personal else {
            return (.lecternDefault, selection == .savedPreference ? loadError : nil)
        }
        do {
            guard let current else { throw NotesStyleError.invalid("No personal style is saved.") }
            _ = try current.draft.validated(samples: current.samples)
            let savedSkill = try String(contentsOf: skillURL(for: current.id), encoding: .utf8)
            guard savedSkill == current.skillMarkdown else {
                throw NotesStyleError.invalid("The saved style file has changed. Save the style again in Settings.")
            }
            return (NotesStyleSnapshot(personal: current), nil)
        } catch {
            return (.lecternDefault, "Default Lectern style was used because your personal style is unavailable. \(error.localizedDescription)")
        }
    }

    func saveSamples(_ samples: [NotesStyleSample]) throws {
        var next = library
        next.samples = try NotesStyleDraft.validatedSamples(samples)
        try persist(next)
    }

    func select(_ selection: NotesStyleSelection) throws {
        guard selection != .savedPreference else { return }
        if selection == .personal, let warning = resolve(.personal).warning {
            throw NotesStyleError.invalid(warning)
        }
        var next = library
        next.preference = selection
        try persist(next)
    }

    @discardableResult
    func save(draft: NotesStyleDraft, samples: [NotesStyleSample], creatorAgent: String,
              creatorModel: String?, activate: Bool = true) throws -> PersonalNotesStyle {
        let revision = try PersonalNotesStyle(draft: draft, samples: samples,
                                             creatorAgent: creatorAgent, creatorModel: creatorModel)
        let folder = skillURL(for: revision.id).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try writePrivate(Data(revision.skillMarkdown.utf8), to: skillURL(for: revision.id))
            var next = library
            next.samples = revision.samples
            next.revisions.append(revision)
            if activate || next.activeRevision == nil { next.activeRevision = revision.id }
            if activate { next.preference = .personal }
            try persist(next)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return revision
    }

    func restore(_ id: UUID) throws {
        guard let revision = library.revisions.first(where: { $0.id == id }) else {
            throw NotesStyleError.invalid("That style revision is no longer available.")
        }
        _ = try revision.draft.validated(samples: revision.samples)
        let file = try String(contentsOf: skillURL(for: id), encoding: .utf8)
        guard file == revision.skillMarkdown else { throw NotesStyleError.invalid("That style revision is unreadable.") }
        var next = library
        next.activeRevision = id
        next.samples = revision.samples
        next.preference = .personal
        try persist(next)
    }

    func removePersonalStyle() throws {
        let revisions = directory.appendingPathComponent("Revisions", isDirectory: true)
        if FileManager.default.fileExists(atPath: revisions.path) {
            try FileManager.default.removeItem(at: revisions)
        }
        try persist(Library())
    }

    private func persist(_ next: Library) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 8_000_000 else {
            throw NotesStyleError.invalid("The style library is full. Remove your personal style before creating a new one.")
        }
        try writePrivate(data, to: directory.appendingPathComponent("library.json"))
        library = next
        loadError = nil
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        guard rename(staging.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
