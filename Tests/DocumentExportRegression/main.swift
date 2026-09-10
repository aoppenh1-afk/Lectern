import AppKit
import Foundation
import PDFKit

let suppliedOutput = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, isDirectory: true)
}
let output = suppliedOutput ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("LecternDocumentExportRegression-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let markdown = """
# גדרי איסור חזרה

- **חנניה:** נותנים means חזרה; **חכמים:** נותנים means שהייה
  - **משנה (דף ל״ו:):** a nested explanation with enough text to wrap onto another line and retain its hanging indent.


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
    let document = LectureDocumentRenderer.attributedDocument(from: markdown)
    let full = NSRange(location: 0, length: document.length)
    var failures: [String] = []
    document.enumerateAttributes(in: full) { attributes, _, _ in
        if let color = attributes[.foregroundColor] as? NSColor,
           let rgb = color.usingColorSpace(.deviceRGB),
           max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) > 0.01 {
            failures.append("Export text must be fixed black")
        }
    }
    precondition(document.string.contains("(:\u{200E}דף ל״ו\u{200E})"), "Daf amud mark must precede the reference")
    let label = (document.string as NSString).range(of: "חנניה")
    let font = document.attribute(.font, at: label.location, effectiveRange: nil) as! NSFont
    if !NSFontManager.shared.traits(of: font).contains(.boldFontMask) { failures.append("Inline Hebrew bold was lost") }
    if font.familyName != "Times New Roman" { failures.append("Font differs from the Google Docs notes") }
    if !document.string.contains("\u{200E}חנניה\u{200E}:") { failures.append("Hebrew punctuation has no LTR boundaries") }
    if !failures.isEmpty {
        print("FAIL: " + failures.joined(separator: "; "))
        exit(1)
    }
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

// Validate serialized Word settings, not just the ZIP signature.
let unpacked = output.appendingPathComponent("word-package")
try? FileManager.default.removeItem(at: unpacked)
let unzip = Process()
unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
unzip.arguments = ["-x", "-k", docxURL.path, unpacked.path]
try unzip.run()
unzip.waitUntilExit()
precondition(unzip.terminationStatus == 0)
let wordXML = try XMLDocument(contentsOf: unpacked.appendingPathComponent("word/document.xml"))
func nodes(_ xpath: String) -> [XMLNode] { try! wordXML.nodes(forXPath: xpath) }
precondition(nodes( "//w:sz-cs | //w:ind/@w:first-line").isEmpty)
precondition(!nodes( "//w:szCs").isEmpty)
precondition(!nodes( "//w:bCs").isEmpty)
precondition(!nodes( "//w:ind[@w:hanging='360']").isEmpty)
precondition(!nodes( "//w:tabs/w:tab[@w:pos='1440']").isEmpty)
let paragraphs = nodes( "//w:p").count
precondition(nodes( "//w:p/w:pPr/w:bidi[@w:val='0']").count == paragraphs)

// Exercise pagination and ensure the final paragraph is not dropped.
let longPDF = output.appendingPathComponent("multipage.pdf")
try await MainActor.run {
    try LectureDocumentRenderer.write(
        markdown: String(repeating: "- A long lecture outline item with **bold** text.\n", count: 180) + "\nLast exported paragraph.",
        to: longPDF, format: .pdf)
}
let pdf = PDFDocument(url: longPDF)!
precondition(pdf.pageCount > 1)
precondition(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Last exported paragraph.") == true)
print("PASS: DOCX hanging indents, Hebrew bold/size and LTR paragraphs; PDF pagination")
