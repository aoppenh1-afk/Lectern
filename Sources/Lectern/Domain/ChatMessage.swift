import Foundation
import SwiftData
import UniformTypeIdentifiers

enum ChatAttachmentKind: String, Sendable {
    case image
    case pdf
    case markdown
    case text
    case file
    case folder

    static func classify(_ url: URL) throws -> ChatAttachmentKind {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values.isDirectory == true { return .folder }

        let contentType = values.contentType
        if contentType?.conforms(to: .image) == true { return .image }
        if contentType?.conforms(to: .pdf) == true { return .pdf }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) { return .markdown }
        if contentType?.conforms(to: .text) == true { return .text }
        return .file
    }
}

enum ChatMessageRole: String, Codable {
    case user
    case assistant
}

enum NoteChangeState: String, Codable {
    case proposed
    case applied
    case discarded
    case stale
    case undone
}

struct MarkdownDiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case unchanged
        case removed
        case added
    }

    let id: Int
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let text: String
}

struct MarkdownDiffSection: Identifiable, Equatable {
    let id: Int
    let kind: MarkdownDiffLine.Kind
    let markdown: String
}

enum MarkdownDiff {
    static func lines(from oldMarkdown: String, to newMarkdown: String) -> [MarkdownDiffLine] {
        let oldLines = oldMarkdown.components(separatedBy: "\n")
        let newLines = newMarkdown.components(separatedBy: "\n")
        let changes = newLines.difference(from: oldLines)
        let removed = Set(changes.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let inserted = Set(changes.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var output: [MarkdownDiffLine] = []
        var oldIndex = 0
        var newIndex = 0
        var id = 0

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                output.append(.init(
                    id: id,
                    kind: .removed,
                    oldLine: oldIndex + 1,
                    newLine: nil,
                    text: oldLines[oldIndex]
                ))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                output.append(.init(
                    id: id,
                    kind: .added,
                    oldLine: nil,
                    newLine: newIndex + 1,
                    text: newLines[newIndex]
                ))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                output.append(.init(
                    id: id,
                    kind: .unchanged,
                    oldLine: oldIndex + 1,
                    newLine: newIndex + 1,
                    text: oldLines[oldIndex]
                ))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                output.append(.init(
                    id: id,
                    kind: .removed,
                    oldLine: oldIndex + 1,
                    newLine: nil,
                    text: oldLines[oldIndex]
                ))
                oldIndex += 1
            } else {
                output.append(.init(
                    id: id,
                    kind: .added,
                    oldLine: nil,
                    newLine: newIndex + 1,
                    text: newLines[newIndex]
                ))
                newIndex += 1
            }
            id += 1
        }
        return output
    }

    static func changedSections(_ lines: [MarkdownDiffLine]) -> [MarkdownDiffSection] {
        var sections: [MarkdownDiffSection] = []
        var currentKind: MarkdownDiffLine.Kind?
        var currentLines: [String] = []

        func finishSection() {
            guard let currentKind, !currentLines.isEmpty else { return }
            sections.append(.init(
                id: sections.count,
                kind: currentKind,
                markdown: currentLines.joined(separator: "\n")
            ))
        }

        for line in lines {
            guard line.kind != .unchanged else {
                finishSection()
                currentKind = nil
                currentLines = []
                continue
            }
            if currentKind != line.kind {
                finishSection()
                currentKind = line.kind
                currentLines = []
            }
            currentLines.append(line.text)
        }
        finishSection()
        return sections
    }
}

/// Recognizes ordinary requests to change the Notes artifact without forcing
/// the student to learn a special command or click a follow-up button.
enum ChatNoteEditIntent {
    static let agentSignal = "<<<LECTERN_NOTE_EDIT>>>"

    struct AgentResponse {
        let content: String
        let requestsEdit: Bool
    }

    static func isRequested(_ message: String) -> Bool {
        let words = Set(message.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let actions: Set<String> = [
            "add", "append", "include", "insert", "put", "update", "change", "edit",
            "revise", "rewrite", "reword", "improve", "expand", "replace", "fix",
            "reorganize", "reformat", "format", "remove", "delete", "shorten",
            "simplify", "clarify", "make", "turn", "merge", "move",
        ]
        let targets: Set<String> = [
            "note", "notes", "section", "paragraph", "bullet", "bullets", "outline",
            "study", "guide",
        ]
        return !words.isDisjoint(with: actions) && !words.isDisjoint(with: targets)
    }

    static func parseAgentResponse(_ response: String) -> AgentResponse {
        AgentResponse(
            content: response.replacingOccurrences(of: agentSignal, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            requestsEdit: response.contains(agentSignal)
        )
    }
}

/// One persisted turn in a Lecture's study conversation.
@Model
final class ChatMessage {
    var role: ChatMessageRole
    var content: String
    var createdAt: Date
    var modelInfo: String?
    var sourceLabels: [String]
    var attachmentNames: [String] = []
    var attachmentPaths: [String] = []
    var attachmentKinds: [String] = []

    /// A proposal always contains a complete replacement for the Notes artifact.
    /// The base hash makes applying it an optimistic, conflict-checked update.
    var proposedNotes: String?
    var proposalBaseNotes: String?
    var proposalBaseHash: String?
    var noteChangeStateRaw: String?
    var appliedPreviousNotes: String?
    var appliedNotesHash: String?

    var lecture: Lecture?

    init(role: ChatMessageRole,
         content: String,
         modelInfo: String? = nil,
         sourceLabels: [String] = [],
         attachmentNames: [String] = [],
         attachmentPaths: [String] = [],
         attachmentKinds: [String] = []) {
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.modelInfo = modelInfo
        self.sourceLabels = sourceLabels
        self.attachmentNames = attachmentNames
        self.attachmentPaths = attachmentPaths
        self.attachmentKinds = attachmentKinds
    }

    var noteChangeState: NoteChangeState? {
        get { noteChangeStateRaw.flatMap(NoteChangeState.init(rawValue:)) }
        set { noteChangeStateRaw = newValue?.rawValue }
    }
}
