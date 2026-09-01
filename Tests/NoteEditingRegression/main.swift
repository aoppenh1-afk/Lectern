import Foundation
import SwiftData

@Model
final class Lecture {
    init() {}
}

let oldNotes = """
# Respiration

Glycolysis makes ATP.
"""

let newNotes = """
# Respiration

Glycolysis begins glucose breakdown.

## Oxidative phosphorylation
The proton gradient powers ATP synthase.
"""

let diff = MarkdownDiff.lines(from: oldNotes, to: newNotes)
let removed = diff.filter { $0.kind == .removed }.map(\.text)
let added = diff.filter { $0.kind == .added }.map(\.text)

guard removed == ["Glycolysis makes ATP."] else {
    fputs("FAIL: Markdown diff did not preserve the removed line\n", stderr)
    exit(1)
}

guard added == [
    "Glycolysis begins glucose breakdown.",
    "",
    "## Oxidative phosphorylation",
    "The proton gradient powers ATP synthase.",
] else {
    fputs("FAIL: Markdown diff did not preserve every added line\n", stderr)
    exit(1)
}

guard diff.compactMap(\.oldLine).last == 3,
      diff.compactMap(\.newLine).last == 6 else {
    fputs("FAIL: Markdown diff line numbers are incorrect\n", stderr)
    exit(1)
}

let editRequests = [
    "Add this to the notes.",
    "Rewrite the oxidative phosphorylation section so it is clearer.",
    "Make the ATP paragraph easier to study.",
    "Remove the repeated bullet from my notes.",
]

guard editRequests.allSatisfy(ChatNoteEditIntent.isRequested) else {
    fputs("FAIL: ordinary chat note-edit requests were not recognized\n", stderr)
    exit(1)
}

guard !ChatNoteEditIntent.isRequested("What do the notes say about ATP?") else {
    fputs("FAIL: a notes question was mistaken for an edit request\n", stderr)
    exit(1)
}

let signaled = ChatNoteEditIntent.parseAgentResponse("I will rewrite that section.\n\n<<<LECTERN_NOTE_EDIT>>>")
guard signaled.requestsEdit, signaled.content == "I will rewrite that section." else {
    fputs("FAIL: agent-recognized follow-up edits were not routed or cleaned\n", stderr)
    exit(1)
}

let sections = MarkdownDiff.changedSections(diff)
guard sections.map(\.kind) == [.removed, .added],
      sections[0].markdown == "Glycolysis makes ATP.",
      sections[1].markdown.contains("Oxidative phosphorylation") else {
    fputs("FAIL: writing-oriented change sections were not grouped correctly\n", stderr)
    exit(1)
}

print("PASS: note edit intent and writing-oriented proposal sections")
