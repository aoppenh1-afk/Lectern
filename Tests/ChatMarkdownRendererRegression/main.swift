import Foundation

let markdown = """
**Lecture Summary: Mitochondria & ATP Production**

- Mitochondria produce their own **circular DNA**.
- They are the **powerhouse of the cell**.
- ATP production occurs in **four steps**.
"""

let expected = """
Lecture Summary: Mitochondria & ATP Production

- Mitochondria produce their own circular DNA.
- They are the powerhouse of the cell.
- ATP production occurs in four steps.
"""

let rendered = String(ChatMarkdownRenderer.attributedString(for: markdown).characters)
guard rendered == expected else {
    fputs("FAIL: chat Markdown block spacing was collapsed\n", stderr)
    fputs("Rendered: \(rendered.debugDescription)\n", stderr)
    exit(1)
}

print("PASS: chat Markdown preserves paragraphs and list rows")
