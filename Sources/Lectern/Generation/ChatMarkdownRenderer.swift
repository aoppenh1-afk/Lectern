import Foundation

/// Converts inline agent Markdown (bold, italic, code, links) into attributed
/// text. Block structure — headings, lists, tables, fences, mermaid diagrams —
/// is split first by NoteBlockParser and rendered by NotesContentView /
/// ChatMarkdownContent; this helper intentionally stays inline-only so block
/// markers are never collapsed into a single paragraph.
/// Keeping this conversion outside the view gives block-spacing regressions a
/// small, deterministic test seam.
enum ChatMarkdownRenderer {
    static func attributedString(for content: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
    }
}
