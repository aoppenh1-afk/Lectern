import AppKit
import CoreText
import Foundation
import UniformTypeIdentifiers

enum LectureShareFormat: String, CaseIterable, Identifiable, Sendable {
    case lectern
    case markdown
    case pdf
    case docx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lectern: return "Lectern"
        case .markdown: return "Markdown"
        case .pdf: return "PDF"
        case .docx: return "Word"
        }
    }

    var fileExtension: String {
        switch self {
        case .lectern: return "lectern"
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .docx: return "docx"
        }
    }

    var contentType: UTType {
        switch self {
        case .lectern:
            return UTType(exportedAs: "com.lectern.bundle", conformingTo: .package)
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        }
    }
}

@MainActor
enum LectureDocumentRenderer {
    enum RenderError: LocalizedError {
        case pdfFailed
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .pdfFailed: return "Lectern could not render the PDF."
            case .unsupportedFormat: return "This document format is not supported."
            }
        }
    }

    static func write(markdown: String, to destination: URL, format: LectureShareFormat) throws {
        switch format {
        case .markdown:
            try Data(markdown.utf8).write(to: destination, options: .atomic)
        case .pdf:
            try writePDF(attributedDocument(from: markdown), to: destination)
        case .docx:
            let document = attributedDocument(from: markdown)
            let data = try document.data(
                from: NSRange(location: 0, length: document.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
            try data.write(to: destination, options: .atomic)
        case .lectern:
            throw RenderError.unsupportedFormat
        }
    }

    static func attributedDocument(from markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)
        var inCodeBlock = false
        var lists = NotesListScanner()

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "```" ||
                line.trimmingCharacters(in: .whitespaces).hasPrefix("```mermaid") {
                inCodeBlock.toggle()
                lists.reset()
                continue
            }

            if let image = imageAttachment(from: line) {
                output.append(image)
                output.append(NSAttributedString(string: "\n"))
                continue
            }

            if inCodeBlock {
                append(line + "\n", to: output,
                       font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                       color: NSColor(calibratedWhite: 0.22, alpha: 1),
                       before: 0, after: 0, lineHeight: 1.15,
                       background: NSColor(calibratedWhite: 0.95, alpha: 1))
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Scanning every line keeps list depth in sync; headings and
            // flush-left paragraphs end the current outline.
            let listItem = lists.scan(line)
            if trimmed.isEmpty {
                output.append(NSAttributedString(string: "\n"))
            } else if let item = listItem {
                let marker: String
                switch item.marker {
                case .bullet: marker = bulletGlyph(depth: item.depth)
                case .ordered: marker = item.orderedLabel
                }
                let indent = CGFloat(min(item.depth, 7)) * 18
                append(marker + " " + stripInlineMarkdown(item.content) + "\n", to: output,
                       font: NSFont.systemFont(ofSize: 11), color: .textColor,
                       before: 0, after: 4, lineHeight: 1.25, firstLineIndent: indent,
                       headIndent: indent + 18)
            } else if trimmed.hasPrefix("# ") {
                append(String(trimmed.dropFirst(2)) + "\n", to: output,
                       font: NSFont.systemFont(ofSize: 26, weight: .bold),
                       color: NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.22, alpha: 1),
                       before: 0, after: 8, lineHeight: 1.05)
            } else if trimmed.hasPrefix("## ") {
                append(String(trimmed.dropFirst(3)) + "\n", to: output,
                       font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                       color: NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.71, alpha: 1),
                       before: 18, after: 10, lineHeight: 1.1)
            } else if trimmed.hasPrefix("### ") {
                append(String(trimmed.dropFirst(4)) + "\n", to: output,
                       font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                       color: NSColor(calibratedRed: 0.12, green: 0.30, blue: 0.47, alpha: 1),
                       before: 12, after: 6, lineHeight: 1.15)
            } else if trimmed.hasPrefix("> ") {
                append(stripInlineMarkdown(String(trimmed.dropFirst(2))) + "\n", to: output,
                       font: NSFont.systemFont(ofSize: 11),
                       color: NSColor(calibratedWhite: 0.35, alpha: 1),
                       before: 2, after: 6, lineHeight: 1.25, firstLineIndent: 14,
                       headIndent: 14)
            } else {
                append(stripInlineMarkdown(trimmed) + "\n", to: output,
                       font: NSFont.systemFont(ofSize: 11), color: .textColor,
                       before: 0, after: 6, lineHeight: 1.25)
            }
        }
        return output
    }

    private static func append(_ text: String,
                               to output: NSMutableAttributedString,
                               font: NSFont,
                               color: NSColor,
                               before: CGFloat,
                               after: CGFloat,
                               lineHeight: CGFloat,
                               background: NSColor? = nil,
                               firstLineIndent: CGFloat = 0,
                               headIndent: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        paragraph.lineHeightMultiple = lineHeight
        paragraph.firstLineHeadIndent = firstLineIndent
        paragraph.headIndent = headIndent
        // Mixed English-Hebrew lines must keep English reading order even
        // when the first word is Hebrew.
        paragraph.baseWritingDirection = .leftToRight
        paragraph.alignment = .left
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let background { attributes[.backgroundColor] = background }
        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    private static func imageAttachment(from line: String) -> NSAttributedString? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^)]+)\)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let pathRange = Range(match.range(at: 2), in: line) else { return nil }
        var path = String(line[pathRange])
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        guard let image = NSImage(contentsOfFile: path) else { return nil }

        let maxWidth: CGFloat = 468
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0,
                                   width: image.size.width * scale,
                                   height: image.size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    private static func bulletGlyph(depth: Int) -> String {
        switch depth % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private static func stripInlineMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
    }

    private static func writePDF(_ document: NSAttributedString, to destination: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let contentBox = CGRect(x: 54, y: 54, width: 504, height: 684)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RenderError.pdfFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(document)
        let pagePath = CGPath(rect: contentBox, transform: nil)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                pagePath,
                nil
            )
            CTFrameDraw(frame, context)
            context.restoreGState()
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 || document.length == 0 else {
                throw RenderError.pdfFailed
            }
            location += visible.length
        } while location < document.length

        context.closePDF()
        let resourceValues = try? destination.resourceValues(forKeys: [.fileSizeKey])
        guard (resourceValues?.fileSize ?? 0) > 0 else {
            throw RenderError.pdfFailed
        }
    }
}
