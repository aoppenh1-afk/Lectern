import AppKit
import Foundation
import PDFKit
import SwiftData
import UniformTypeIdentifiers

enum ReferenceMaterialService {
    static let supportedContentTypes: [UTType] = [
        .pdf,
        .plainText,
        .rtf,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
        UTType(filenameExtension: "doc") ?? .data,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "rtfd") ?? .data,
    ]

    enum ImportError: LocalizedError {
        case unsupported(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "\(name) is not a supported note or slide file."
            case .unreadable(let name): return "Lectern could not read text from \(name)."
            }
        }
    }

    @MainActor
    static func importFiles(_ urls: [URL],
                            course: Course?,
                            lecture: Lecture?,
                            context: ModelContext) throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lectern/Reference Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for source in urls {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

            let kind = try kind(for: source)
            let destination = uniqueDestination(named: source.lastPathComponent, in: base)
            try FileManager.default.copyItem(at: source, to: destination)
            do {
                let text = try extractText(from: destination, kind: kind)
                let attachment = ReferenceAttachment(
                    name: source.lastPathComponent,
                    filePath: destination.path,
                    kind: kind,
                    extractedText: text
                )
                attachment.course = lecture == nil ? course : nil
                attachment.lecture = lecture
                context.insert(attachment)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        try context.save()
    }

    private static func kind(for url: URL) throws -> ReferenceAttachmentKind {
        switch url.pathExtension.lowercased() {
        case "txt", "text": return .text
        case "md", "markdown": return .markdown
        case "doc", "docx", "rtf", "rtfd": return .word
        case "pdf": return .pdf
        default: throw ImportError.unsupported(url.lastPathComponent)
        }
    }

    private static func extractText(from url: URL, kind: ReferenceAttachmentKind) throws -> String {
        let text: String
        switch kind {
        case .text, .markdown:
            text = try String(contentsOf: url, encoding: .utf8)
        case .word:
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        case .pdf:
            guard let document = PDFDocument(url: url) else {
                throw ImportError.unreadable(url.lastPathComponent)
            }
            text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.unreadable(url.lastPathComponent) }
        return trimmed
    }

    private static func uniqueDestination(named name: String, in directory: URL) -> URL {
        let proposed = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let source = name as NSString
        return directory.appendingPathComponent(
            "\(source.deletingPathExtension)-\(UUID().uuidString.prefix(8)).\(source.pathExtension)"
        )
    }
}
