import Foundation

/// Converts agent Markdown into the attributed text shown by lecture chat.
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
