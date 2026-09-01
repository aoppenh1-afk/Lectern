import AppKit
import Foundation

let suppliedOutput = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, isDirectory: true)
}
let output = suppliedOutput ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("LecternDocumentExportRegression-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let markdown = """
# Cell Biology Lecture 7

BIO 201 | August 27, 2026 | 01:12:04

## Notes

The professor compared **competitive** and *noncompetitive* inhibition.

- Competitive inhibitors increase apparent Km.
- Noncompetitive inhibitors reduce Vmax.

## Quiz

### Question 1

What happens to Vmax during noncompetitive inhibition?

**Answer:** Vmax decreases.
"""

let markdownURL = output.appendingPathComponent("lecture.md")
let pdfURL = output.appendingPathComponent("lecture.pdf")
let docxURL = output.appendingPathComponent("lecture.docx")

try await MainActor.run {
    try LectureDocumentRenderer.write(markdown: markdown, to: markdownURL, format: .markdown)
    try LectureDocumentRenderer.write(markdown: markdown, to: pdfURL, format: .pdf)
    try LectureDocumentRenderer.write(markdown: markdown, to: docxURL, format: .docx)
}

let markdownData = try Data(contentsOf: markdownURL)
let pdfData = try Data(contentsOf: pdfURL)
let docxData = try Data(contentsOf: docxURL)

precondition(String(data: markdownData, encoding: .utf8)?.contains("Cell Biology Lecture 7") == true)
precondition(pdfData.starts(with: Data("%PDF".utf8)))
precondition(docxData.starts(with: Data([0x50, 0x4B])))

print("PASS: visible document formats produce valid Markdown, PDF, and DOCX files")
print(output.path)
