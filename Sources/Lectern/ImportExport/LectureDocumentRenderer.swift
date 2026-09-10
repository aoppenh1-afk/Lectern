import AppKit
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
        case wordFailed
        case pdfFailed
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .wordFailed: return "Lectern could not render the Word document."
            case .pdfFailed: return "Lectern could not render the PDF."
            case .unsupportedFormat: return "This document format is not supported."
            }
        }
    }

    static func write(markdown: String, to destination: URL, format: LectureShareFormat) throws {
        switch format {
        case .markdown:
            try Data(NotesDafCitation.normalize(markdown).utf8).write(to: destination, options: .atomic)
        case .pdf:
            try writePDF(attributedDocument(from: markdown), to: destination)
        case .docx:
            try writeWord(attributedDocument(from: markdown), to: destination)
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
                       background: NSColor(calibratedWhite: 0.95, alpha: 1), literal: true)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Scanning every line keeps list depth in sync; headings and
            // flush-left paragraphs end the current outline.
            let listItem = lists.scan(line)
            if trimmed.isEmpty {
                continue
            } else if let item = listItem {
                let marker: String
                switch item.marker {
                case .bullet: marker = bulletGlyph(depth: item.depth)
                case .ordered: marker = item.orderedLabel
                }
                let indent = CGFloat(min(item.depth, 7)) * 36 + 18
                append(item.content + "\n", to: output,
                       font: documentFont(size: 12), color: .black,
                       before: 0, after: 0, lineHeight: 1.15, prefix: marker + "\t", firstLineIndent: indent,
                       headIndent: indent + 18)
            } else if trimmed.hasPrefix("# ") {
                append(String(trimmed.dropFirst(2)) + "\n", to: output,
                       font: documentFont(size: 20, bold: true),
                       color: .black,
                       before: 20, after: 6, lineHeight: 1.15, underline: true)
            } else if trimmed.hasPrefix("## ") {
                append(String(trimmed.dropFirst(3)) + "\n", to: output,
                       font: documentFont(size: 16, bold: true),
                       color: .black,
                       before: 18, after: 6, lineHeight: 1.15)
            } else if trimmed.hasPrefix("### ") {
                append(String(trimmed.dropFirst(4)) + "\n", to: output,
                       font: documentFont(size: 16, bold: true),
                       color: .black,
                       before: 12, after: 6, lineHeight: 1.15)
            } else if trimmed.hasPrefix("> ") {
                append(String(trimmed.dropFirst(2)) + "\n", to: output,
                       font: documentFont(size: 12),
                       color: .black,
                       before: 2, after: 6, lineHeight: 1.25, firstLineIndent: 14,
                       headIndent: 14)
            } else {
                append(trimmed + "\n", to: output,
                       font: documentFont(size: 12), color: .black,
                       before: 0, after: 0, lineHeight: 1.15)
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
                               prefix: String = "",
                               underline: Bool = false,
                               literal: Bool = false,
                               firstLineIndent: CGFloat = 0,
                               headIndent: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        paragraph.lineHeightMultiple = lineHeight
        paragraph.firstLineHeadIndent = firstLineIndent
        paragraph.headIndent = headIndent
        if headIndent > firstLineIndent {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)]
        }
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
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        // Consume the tested Hebrew boundary and bold ranges without changing
        // the Google Docs converter or its requests.
        // A disposable plain prefix prevents list-like inline content such as
        // "1. example" from being interpreted as another structural list.
        let plan = NotesMarkdownConverter.plan(markdown: "x " + text)
        let rendered = literal ? text : prefix + String(plan.text.dropFirst(2)) + "\n"
        let paragraphText = NSMutableAttributedString(string: rendered, attributes: attributes)
        if !literal {
            for bold in plan.boldRanges where bold.end > bold.start {
                paragraphText.addAttribute(.font, value: documentFont(size: font.pointSize, bold: true),
                    range: NSRange(location: prefix.utf16.count + bold.start - 3, length: bold.end - bold.start))
            }
        }
        output.append(paragraphText)
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

    private static func documentFont(size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// AppKit's DOCX writer emits legacy names (first-line, sz-cs) and omits
    /// paragraph direction/tab stops. Normalize the package for Word readers.
    private static func writeWord(_ document: NSAttributedString, to destination: URL) throws {
        let data = try document.data(from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("original.docx")
        let package = temporary.appendingPathComponent("package")
        try data.write(to: archive)
        try runArchiveTool(["-x", "-k", archive.path, package.path])
        let xmlURL = package.appendingPathComponent("word/document.xml")
        let xml = try XMLDocument(contentsOf: xmlURL)
        func element(_ name: String, _ attributes: [String: String] = [:]) -> XMLElement {
            let node = XMLElement(name: "w:" + name)
            for (key, value) in attributes {
                node.addAttribute(XMLNode.attribute(withName: "w:" + key, stringValue: value) as! XMLNode)
            }
            return node
        }
        for case let node as XMLElement in try xml.nodes(forXPath: "//w:sz-cs") {
            node.name = "w:szCs"
        }
        for case let props as XMLElement in try xml.nodes(forXPath: "//w:rPr") {
            if props.elements(forName: "w:b").first != nil { props.addChild(element("bCs")) }
        }
        for case let paragraph as XMLElement in try xml.nodes(forXPath: "//w:p") {
            let props = paragraph.elements(forName: "w:pPr").first ?? element("pPr")
            if props.parent == nil { paragraph.insertChild(props, at: 0) }
            for name in ["w:bidi", "w:jc"] {
                props.elements(forName: name).forEach { $0.detach() }
            }
            // Explicit LTR plus Unicode LRM boundaries preserves mixed text.
            props.addChild(element("bidi", ["val": "0"]))
            props.addChild(element("jc", ["val": "left"]))
            let spacing = props.elements(forName: "w:spacing").first ?? element("spacing")
            if spacing.parent == nil { props.addChild(spacing) }
            spacing.addAttribute(XMLNode.attribute(withName: "w:line", stringValue: "276") as! XMLNode)
            spacing.addAttribute(XMLNode.attribute(withName: "w:lineRule", stringValue: "auto") as! XMLNode)
            if let indent = props.elements(forName: "w:ind").first {
                if let old = indent.attribute(forName: "w:first-line"), let value = Int(old.stringValue ?? "") {
                    indent.removeAttribute(forName: "w:first-line")
                    indent.addAttribute(XMLNode.attribute(withName: value < 0 ? "w:hanging" : "w:firstLine",
                        stringValue: String(abs(value))) as! XMLNode)
                }
                if let left = indent.attribute(forName: "w:left")?.stringValue {
                    let tabs = element("tabs")
                    tabs.addChild(element("tab", ["val": "left", "pos": left]))
                    props.addChild(tabs)
                }
            }
            if let size = (try paragraph.nodes(forXPath: "w:r/w:rPr/w:sz/@w:val").first)?.stringValue,
               (Int(size) ?? 0) >= 32 {
                props.addChild(element("keepNext"))
                props.addChild(element("keepLines"))
            }
            // CT_PPr uses schema order, even though some readers tolerate more.
            let order = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "numPr", "tabs",
                         "bidi", "spacing", "ind", "jc", "rPr", "sectPr"]
            let children = props.children ?? []
            let sorted = children.enumerated().sorted {
                let lhs = order.firstIndex(of: $0.element.localName ?? "") ?? 10
                let rhs = order.firstIndex(of: $1.element.localName ?? "") ?? 10
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            children.forEach { $0.detach() }
            sorted.forEach { props.addChild($0.element) }
        }
        try xml.xmlData.write(to: xmlURL)
        let result = temporary.appendingPathComponent("result.docx")
        try runArchiveTool(["-c", "-k", package.path, result.path])
        try Data(contentsOf: result).write(to: destination, options: .atomic)
    }

    private static func runArchiveTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RenderError.wordFailed }
    }

    private static func writePDF(_ document: NSAttributedString, to destination: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let contentBox = CGRect(x: 72, y: 72, width: 468, height: 648)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw RenderError.pdfFailed
        }

        // TextKit applies Cocoa's bidi layout and draws attachments. Drawing
        // this NSAttributedString directly with CTFrameDraw reverses Hebrew runs.
        let storage = NSTextStorage(attributedString: document)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var location = 0
        repeat {
            let container = NSTextContainer(containerSize: contentBox.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0 || document.length == 0 else { throw RenderError.pdfFailed }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: glyphs, at: contentBox.origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: contentBox.origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            location = NSMaxRange(glyphs)
        } while location < layout.numberOfGlyphs

        context.closePDF()
        let resourceValues = try? destination.resourceValues(forKeys: [.fileSizeKey])
        guard (resourceValues?.fileSize ?? 0) > 0 else {
            throw RenderError.pdfFailed
        }
    }
}
