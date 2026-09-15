import AppKit
import Foundation
import Observation
import PDFKit

struct CanvasResourceReference: Sendable {
    let title: String
    let moduleName: String
    let kind: String
    let canvasID: Int64?
    let htmlURL: String?
    let apiURL: String?
}

struct CanvasResourceContent: Sendable {
    let label: String
    let content: String
    let images: [CanvasResourceImage]
}

struct CanvasResourceImage: Sendable {
    let label: String
    let data: Data
    let mimeType: String
}

struct CanvasDownloadedFile: Sendable {
    let filename: String
    let data: Data
    let contentType: String?
}

actor CanvasResourceContentLoader {
    private let credentials: CanvasCredentials
    private let session: URLSession

    init(credentials: CanvasCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    func source(for resource: CanvasResourceReference) async throws -> CanvasResourceContent {
        let extracted: ExtractedContent
        switch resource.kind.lowercased() {
        case "file":
            extracted = try await loadFile(resource)
        case "page":
            extracted = try await loadPage(resource)
        default:
            extracted = try await loadLinkedResource(resource)
        }
        let content = """
        Canvas resource: \(resource.title)
        Module: \(resource.moduleName)
        Type: \(resource.kind)

        \(extracted.text)
        """
        return CanvasResourceContent(label: resource.title, content: content, images: extracted.images)
    }

    private struct ExtractedContent: Sendable {
        let text: String
        let images: [CanvasResourceImage]
    }

    private struct FileMetadata: Decodable, Sendable {
        let url: URL
        let displayName: String?
        let filename: String?
        let contentType: String?

        enum CodingKeys: String, CodingKey {
            case url
            case displayName = "display_name"
            case filename
            case contentType = "content-type"
        }
    }

    private struct PageMetadata: Decodable, Sendable {
        let body: String?
    }

    private func loadFile(_ resource: CanvasResourceReference) async throws -> ExtractedContent {
        let file = try await downloadedFile(for: resource)
        return try Self.extractContent(
            from: file.data,
            filename: file.filename,
            contentType: file.contentType
        )
    }

    func downloadedFile(for resource: CanvasResourceReference) async throws -> CanvasDownloadedFile {
        let metadataURL: URL
        if let apiURL = resource.apiURL.flatMap(URL.init(string:)),
           isCanvasAPIURL(apiURL) {
            metadataURL = apiURL
        } else if let canvasID = resource.canvasID {
            metadataURL = credentials.baseURL.appending(path: "/api/v1/files/\(canvasID)")
        } else {
            throw CanvasResourceContentError.missingLocation(resource.title)
        }
        let (metadataData, _) = try await data(from: metadataURL, authenticated: true, accept: "application/json")
        let metadata: FileMetadata
        do {
            metadata = try JSONDecoder().decode(FileMetadata.self, from: metadataData)
        } catch {
            throw CanvasResourceContentError.invalidMetadata(resource.title)
        }
        let authenticatedDownload = isSameCanvasOrigin(metadata.url)
        let (fileData, response) = try await data(
            from: metadata.url,
            authenticated: authenticatedDownload,
            accept: "*/*"
        )
        return CanvasDownloadedFile(
            filename: metadata.displayName ?? metadata.filename ?? metadata.url.lastPathComponent,
            data: fileData,
            contentType: metadata.contentType ?? response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private func loadPage(_ resource: CanvasResourceReference) async throws -> ExtractedContent {
        guard let url = resource.apiURL.flatMap(URL.init(string:)), isCanvasAPIURL(url) else {
            return try await loadLinkedResource(resource)
        }
        let (data, _) = try await data(from: url, authenticated: true, accept: "application/json")
        guard let page = try? JSONDecoder().decode(PageMetadata.self, from: data),
              let body = page.body else {
            throw CanvasResourceContentError.invalidMetadata(resource.title)
        }
        return try Self.extractContent(from: Data(body.utf8), filename: "page.html", contentType: "text/html")
    }

    private func loadLinkedResource(_ resource: CanvasResourceReference) async throws -> ExtractedContent {
        guard let url = CanvasResourceDestination.url(
            kind: resource.kind,
            canvasID: resource.canvasID,
            htmlURL: resource.htmlURL,
            apiURL: resource.apiURL
        ) else {
            throw CanvasResourceContentError.missingLocation(resource.title)
        }
        let authenticated = isSameCanvasOrigin(url)
        let (data, response) = try await data(from: url, authenticated: authenticated, accept: "text/html, text/plain, application/pdf, */*")
        return try Self.extractContent(
            from: data,
            filename: url.lastPathComponent,
            contentType: response.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private func data(from url: URL, authenticated: Bool, accept: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if authenticated {
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CanvasResourceContentError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CanvasResourceContentError.http(status: http.statusCode)
        }
        guard data.count <= 50 * 1_024 * 1_024 else {
            throw CanvasResourceContentError.tooLarge
        }
        return (data, http)
    }

    private func isCanvasAPIURL(_ url: URL) -> Bool {
        isSameCanvasOrigin(url) && url.path.hasPrefix("/api/")
    }

    private func isSameCanvasOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == credentials.baseURL.host?.lowercased()
            && url.port == credentials.baseURL.port
    }

    private nonisolated static func extractContent(from data: Data, filename: String, contentType: String?) throws -> ExtractedContent {
        let type = contentType?.lowercased() ?? ""
        let ext = (filename as NSString).pathExtension.lowercased()
        if type.contains("pdf") || ext == "pdf" {
            guard let document = PDFDocument(data: data) else {
                throw CanvasResourceContentError.unreadable(filename)
            }
            let embeddedText = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !embeddedText.isEmpty {
                return ExtractedContent(text: embeddedText, images: [])
            }
            let images = try (0..<document.pageCount).map { index in
                guard let page = document.page(at: index) else {
                    throw CanvasResourceContentError.unreadable(filename)
                }
                return CanvasResourceImage(
                    label: "\(filename), page \(index + 1)",
                    data: try renderedPNG(page: page),
                    mimeType: "image/png"
                )
            }
            guard !images.isEmpty else { throw CanvasResourceContentError.unreadable(filename) }
            let pageList = images.map(\.label).joined(separator: "\n- ")
            return ExtractedContent(
                text: "This is a scanned PDF with no text layer. Its page images are attached in this order:\n- \(pageList)",
                images: images
            )
        }

        let text: String?
        if type.contains("html") || ["html", "htm"].contains(ext) {
            text = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            ).string
        } else if type.hasPrefix("text/") || ["txt", "md", "markdown", "csv"].contains(ext) {
            text = String(data: data, encoding: .utf8)
        } else if ["rtf", "rtfd", "doc", "docx"].contains(ext) {
            text = try? NSAttributedString(data: data, options: [:], documentAttributes: nil).string
        } else {
            text = String(data: data, encoding: .utf8)
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw CanvasResourceContentError.unreadable(filename) }
        return ExtractedContent(text: trimmed, images: [])
    }

    private nonisolated static func renderedPNG(page: PDFPage) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw CanvasResourceContentError.invalidResponse
        }
        let maximumDimension: CGFloat = 2_200
        let scale = min(maximumDimension / max(bounds.width, bounds.height), 2.0)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CanvasResourceContentError.invalidResponse
        }
        return png
    }
}

enum CanvasResourceContentError: LocalizedError {
    case notConnected
    case missingLocation(String)
    case invalidMetadata(String)
    case invalidResponse
    case http(status: Int)
    case tooLarge
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Reconnect Canvas before attaching course resources to chat."
        case .missingLocation(let title): return "Canvas did not provide a downloadable location for \(title)."
        case .invalidMetadata(let title): return "Canvas returned incomplete file information for \(title)."
        case .invalidResponse: return "Canvas returned an invalid resource response."
        case .http(let status): return "Canvas resource download failed with HTTP \(status)."
        case .tooLarge: return "The Canvas resource is larger than Lectern's 50 MB chat limit."
        case .unreadable(let name): return "Lectern could not extract text from \(name)."
        }
    }
}

enum CanvasResourceDestination {
    static func url(kind: String,
                    canvasID: Int64?,
                    htmlURL: String?,
                    apiURL: String?) -> URL? {
        // Files need an authenticated request. Canvas browser download routes can
        // reject an API-token user, so file rows are handled by CanvasResourceOpener.
        guard kind.caseInsensitiveCompare("File") != .orderedSame else { return nil }

        let candidates = [htmlURL, apiURL]
            .compactMap { $0.flatMap(URL.init(string:)) }

        if let browserURL = candidates.first(where: { !$0.path.hasPrefix("/api/") }) {
            return browserURL
        }

        return candidates.first
    }
}

@MainActor
@Observable
final class CanvasResourceOpener {
    private let connection: CanvasConnectionSettings
    private let fileManager: FileManager
    private let cacheDirectory: URL

    private(set) var openingKey: String?
    private(set) var errorMessage: String?

    init(connection: CanvasConnectionSettings,
         fileManager: FileManager = .default,
         cacheDirectory: URL? = nil) {
        self.connection = connection
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "Lectern/Canvas Files", directoryHint: .isDirectory)
    }

    func openFile(_ resource: CanvasResourceReference, key: String) async {
        guard openingKey == nil else { return }
        openingKey = key
        errorMessage = nil
        defer { openingKey = nil }

        do {
            let credentials = try connection.credentials()
            let file = try await CanvasResourceContentLoader(credentials: credentials)
                .downloadedFile(for: resource)
            let localURL = try store(file, canvasID: resource.canvasID)
            guard NSWorkspace.shared.open(localURL) else {
                throw CanvasResourceOpenError.couldNotOpen(file.filename)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }

    private func store(_ file: CanvasDownloadedFile, canvasID: Int64?) throws -> URL {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cleanedName = file.filename
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let filename = [canvasID.map(String.init), cleanedName.isEmpty ? "Canvas file" : String(cleanedName.prefix(180))]
            .compactMap { $0 }
            .joined(separator: "-")
        let destination = cacheDirectory.appending(path: filename)
        try file.data.write(to: destination, options: .atomic)
        return destination
    }
}

enum CanvasResourceOpenError: LocalizedError {
    case couldNotOpen(String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let filename):
            return "macOS could not open \(filename)."
        }
    }
}

actor CanvasClient {
    private struct CoursePayload: Sendable {
        let courseID: Int64
        var assignments: [CanvasAssignmentDTO] = []
        var modules: [CanvasModuleDTO] = []
        var files: [CanvasFileDTO] = []
        var folders: [CanvasFolderDTO] = []
        var announcements: [CanvasAnnouncementDTO] = []
        var warnings: [String] = []
    }

    private struct InboxPayload: Sendable {
        var conversations: [CanvasConversationDTO] = []
        var warnings: [String] = []
    }

    /// Wrapper so one malformed thread never fails the whole inbox fetch:
    /// bad items decode as nil and are skipped.
    private struct LossyConversation: Decodable, Sendable {
        let value: CanvasConversationDTO?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(CanvasConversationDTO.self)
        }
    }

    private let credentials: CanvasCredentials
    private let session: URLSession
    private let decoder: JSONDecoder

    init(credentials: CanvasCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseCanvasDate(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Canvas date: \(value)")
        }
    }

    /// Canvas timestamps are ISO-8601 in UTC (…Z) or with a numeric offset
    /// (…-06:00), with or without fractional seconds. Try every variant so a
    /// single unexpected format never fails the whole sync.
    static func parseCanvasDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        // Fallback for offsets without colon (e.g. -0600) or other variants.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"] {
            fallback.dateFormat = format
            if let date = fallback.date(from: value) { return date }
        }
        return nil
    }

    static func normalizedBaseURL(_ input: String) throws -> URL {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CanvasConnectionError.missingDomain }
        if !value.contains("://") { value = "https://\(value)" }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else { throw CanvasConnectionError.invalidDomain }
        guard scheme == "https" else { throw CanvasConnectionError.insecureDomain }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw CanvasConnectionError.invalidDomain }
        return url
    }

    func fetchSnapshot() async throws -> CanvasSnapshot {
        let courses: [CanvasCourseDTO] = try await get(
            path: "/api/v1/courses",
            query: [
                .init(name: "enrollment_state", value: "active"),
                .init(name: "enrollment_type", value: "student"),
                .init(name: "include[]", value: "term"),
                .init(name: "include[]", value: "teachers"),
                .init(name: "include[]", value: "total_scores"),
                .init(name: "include[]", value: "syllabus_body"),
                .init(name: "per_page", value: "100"),
            ]
        )

        let payloads = await fetchCoursePayloads(courses)
        let assignments = payloads.flatMap(\.assignments)
        let modules = payloads.flatMap(\.modules)
        let files = payloads.flatMap(\.files)
        let folders = payloads.flatMap(\.folders)
        let announcements = payloads.flatMap(\.announcements)
        let warnings = payloads.flatMap(\.warnings)

        let dates = CanvasClient.syncWindow()
        let events: [CanvasEventDTO] = try await get(
            path: "/api/v1/calendar_events",
            query: [
                .init(name: "type", value: "event"),
                .init(name: "start_date", value: dates.start),
                .init(name: "end_date", value: dates.end),
                .init(name: "per_page", value: "100"),
            ]
        )

        let inbox = await fetchInboxPayload()

        return CanvasSnapshot(courses: courses, assignments: assignments,
                              events: events, modules: modules, files: files, folders: folders,
                              announcements: announcements,
                              conversations: inbox.conversations,
                              warnings: warnings + inbox.warnings)
    }

    private func fetchInboxPayload() async -> InboxPayload {
        var payload = InboxPayload()
        do {
            // Canvas Inbox == conversations API. No `scope` param means "all
            // non-archived" (read + unread), which is the Inbox view. Note:
            // `scope=inbox` is NOT a valid Canvas scope (valid: unread,
            // starred, archived, sent) and must not be sent.
            // Pagination is followed by get(_:query:).
            // Lossy decode: skip malformed threads instead of dropping inbox.
            let wrapped: [LossyConversation] = try await get(
                path: "/api/v1/conversations",
                query: [
                    .init(name: "per_page", value: "100"),
                ]
            )
            payload.conversations = wrapped.compactMap(\.value)
        } catch {
            payload.warnings.append("Inbox messages: \(error.localizedDescription)")
        }
        return payload
    }

    /// Best-effort mirror of a local read to the Canvas Inbox. Failures are
    /// swallowed by the caller: the local badge is the source of truth.
    func markConversationRead(_ id: Int64) async {
        let url = credentials.baseURL.appending(path: "/api/v1/conversations/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Canvas expects form-encoded params for PUT. Query-string params
        // also work via Rails, but a body is the documented form.
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("conversation%5Bworkflow_state%5D=read".utf8)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return }
    }

    /// Full thread for one conversation. The list endpoint only returns a
    /// <=100 character `last_message` preview; the show endpoint includes the
    /// `messages` array (newest first) with complete bodies. Returns nil on
    /// any failure — the caller keeps the preview.
    /// `auto_mark_as_read=false`: read state is mirrored explicitly via
    /// markConversationRead so a preview fetch never side-effects Canvas.
    func fetchConversation(_ id: Int64) async -> CanvasConversationDTO? {
        guard id > 0 else { return nil }
        var components = URLComponents(
            url: credentials.baseURL.appending(path: "/api/v1/conversations/\(id)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [.init(name: "auto_mark_as_read", value: "false")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return try? decoder.decode(CanvasConversationDTO.self, from: data)
    }

    private func fetchCoursePayloads(_ courses: [CanvasCourseDTO]) async -> [CoursePayload] {
        let maximumConcurrentCourses = 4
        var iterator = courses.makeIterator()
        var payloadsByCourse: [Int64: CoursePayload] = [:]

        await withTaskGroup(of: CoursePayload.self) { group in
            for _ in 0..<min(maximumConcurrentCourses, courses.count) {
                guard let course = iterator.next() else { break }
                group.addTask { await self.fetchCoursePayload(course) }
            }

            while let payload = await group.next() {
                payloadsByCourse[payload.courseID] = payload
                if let course = iterator.next() {
                    group.addTask { await self.fetchCoursePayload(course) }
                }
            }
        }

        return courses.compactMap { payloadsByCourse[$0.id] }
    }

    private func fetchCoursePayload(_ course: CanvasCourseDTO) async -> CoursePayload {
        var payload = CoursePayload(courseID: course.id)
        do {
            let values: [CanvasAssignmentDTO] = try await get(
                path: "/api/v1/courses/\(course.id)/assignments",
                query: [.init(name: "include[]", value: "submission"), .init(name: "order_by", value: "due_at"), .init(name: "per_page", value: "100")]
            )
            payload.assignments = values.map { $0.withCourse(course.id) }
        } catch { payload.warnings.append("Assignments for \(course.name): \(error.localizedDescription)") }

        do {
            let values: [CanvasModuleDTO] = try await get(
                path: "/api/v1/courses/\(course.id)/modules",
                query: [.init(name: "include[]", value: "items"), .init(name: "include[]", value: "content_details"), .init(name: "per_page", value: "100")]
            )
            for module in values {
                var hydrated = module.withCourse(course.id)
                if module.items == nil, (module.itemsCount ?? 0) > 0 {
                    let items: [CanvasModuleDTO.Item] = try await get(
                        path: "/api/v1/courses/\(course.id)/modules/\(module.id)/items",
                        query: [.init(name: "include[]", value: "content_details"), .init(name: "per_page", value: "100")]
                    )
                    hydrated.items = items
                }
                payload.modules.append(hydrated)
            }
        } catch { payload.warnings.append("Modules for \(course.name): \(error.localizedDescription)") }

        do {
            let values: [CanvasFileDTO] = try await get(
                path: "/api/v1/courses/\(course.id)/files",
                query: [.init(name: "per_page", value: "100")]
            )
            payload.files = values.map { $0.withCourse(course.id, baseURL: credentials.baseURL) }
        } catch { payload.warnings.append("Files for \(course.name): \(error.localizedDescription)") }

        do {
            let values: [CanvasFolderDTO] = try await get(
                path: "/api/v1/courses/\(course.id)/folders",
                query: [.init(name: "per_page", value: "100")]
            )
            payload.folders = values.map { $0.withCourse(course.id) }
        } catch { payload.warnings.append("Folders for \(course.name): \(error.localizedDescription)") }

        do {
            payload.announcements = try await get(
                path: "/api/v1/announcements",
                query: [.init(name: "context_codes[]", value: "course_\(course.id)"), .init(name: "active_only", value: "true"), .init(name: "per_page", value: "100")]
            )
        } catch { payload.warnings.append("Announcements for \(course.name): \(error.localizedDescription)") }
        return payload
    }

    private func get<T: Decodable & Sendable>(path: String, query: [URLQueryItem]) async throws -> [T] {
        var components = URLComponents(url: credentials.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let firstURL = components?.url else { throw CanvasAPIError.invalidRequest }
        var nextURL: URL? = firstURL
        var values: [T] = []
        var pageCount = 0

        while let url = nextURL {
            pageCount += 1
            guard pageCount <= 200 else { throw CanvasAPIError.paginationLimit }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CanvasAPIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw CanvasAPIError.http(status: http.statusCode, message: Self.errorMessage(from: data))
            }
            values.append(contentsOf: try decoder.decode([T].self, from: data))
            nextURL = Self.nextLink(from: http.value(forHTTPHeaderField: "Link"))
        }
        return values
    }

    static func nextLink(from header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            guard part.contains("rel=\"next\"") || part.contains("rel=next") else { continue }
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }

    private static func syncWindow() -> (start: String, end: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = Date()
        return (formatter.string(from: now.addingTimeInterval(-60 * 60 * 24 * 30)),
                formatter.string(from: now.addingTimeInterval(60 * 60 * 24 * 180)))
    }

    private static func errorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable { struct Item: Decodable { let message: String? }; let errors: [Item]? }
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { return nil }
        return envelope.errors?.compactMap(\.message).joined(separator: " ").prefix(300).description
    }
}

enum CanvasAPIError: LocalizedError {
    case invalidRequest, invalidResponse, paginationLimit
    case http(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Lectern could not build the Canvas request."
        case .invalidResponse: return "Canvas returned an unreadable response."
        case .paginationLimit: return "Canvas returned too many pages to sync safely."
        case .http(let status, let message):
            if status == 401 { return "Canvas rejected this token. Create a new access token and reconnect." }
            if status == 403 { return message ?? "Canvas did not allow access to one of these courses."
            }
            if status == 429 { return "Canvas is rate limiting Lectern. Wait a minute, then sync again." }
            return message ?? "Canvas sync failed with HTTP \(status)."
        }
    }
}

struct CanvasSnapshot: Sendable {
    let courses: [CanvasCourseDTO]
    let assignments: [CanvasAssignmentDTO]
    let events: [CanvasEventDTO]
    let modules: [CanvasModuleDTO]
    let files: [CanvasFileDTO]
    let folders: [CanvasFolderDTO]
    let announcements: [CanvasAnnouncementDTO]
    let conversations: [CanvasConversationDTO]
    let warnings: [String]
}

struct CanvasFileDTO: Decodable, Sendable {
    let id: Int64
    let folderID: Int64?
    let displayName: String?
    let filename: String?
    let url: String?
    var courseID: Int64? = nil
    var apiURL: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case folderID = "folderId"
        case displayName
        case filename
        case url
    }

    func withCourse(_ id: Int64, baseURL: URL) -> Self {
        var copy = self
        copy.courseID = id
        copy.apiURL = baseURL.appending(path: "/api/v1/files/\(self.id)").absoluteString
        return copy
    }
}

struct CanvasFolderDTO: Decodable, Sendable {
    let id: Int64
    let name: String
    let fullName: String?
    var courseID: Int64?

    func withCourse(_ id: Int64) -> Self {
        var copy = self
        copy.courseID = id
        return copy
    }
}

struct CanvasCourseDTO: Decodable, Sendable {
    struct Term: Decodable, Sendable { let name: String? }
    struct Teacher: Decodable, Sendable { let displayName: String? }
    struct Enrollment: Decodable, Sendable {
        let computedCurrentScore: Double?
        let computedCurrentGrade: String?
    }
    let id: Int64
    let name: String
    let courseCode: String?
    let syllabusBody: String?
    let htmlURL: String?
    let term: Term?
    let teachers: [Teacher]?
    let enrollments: [Enrollment]?
}

struct CanvasAssignmentDTO: Decodable, Sendable {
    struct Submission: Decodable, Sendable {
        let workflowState: String?
        let score: Double?
        let grade: String?
        let missing: Bool?
        let excused: Bool?
    }
    let id: Int64
    let name: String
    let description: String?
    let dueAt: Date?
    let lockAt: Date?
    let pointsPossible: Double?
    let htmlURL: String?
    let submission: Submission?
    var courseID: Int64?

    func withCourse(_ id: Int64) -> Self { var copy = self; copy.courseID = id; return copy }
}

struct CanvasEventDTO: Decodable, Sendable {
    let id: Int64
    let title: String
    let startAt: Date?
    let endAt: Date?
    let description: String?
    let locationName: String?
    let locationAddress: String?
    let contextCode: String?
    let htmlURL: String?
}

struct CanvasModuleDTO: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: Int64
        let title: String
        let type: String
        let contentID: Int64?
        let position: Int?
        let htmlURL: String?
        let url: String?
    }
    let id: Int64
    let name: String
    let position: Int?
    let itemsCount: Int?
    var items: [Item]?
    var courseID: Int64?

    func withCourse(_ id: Int64) -> Self { var copy = self; copy.courseID = id; return copy }
}

struct CanvasAnnouncementDTO: Decodable, Sendable {
    struct Author: Decodable, Sendable { let displayName: String? }
    let id: Int64
    let title: String
    let message: String?
    let postedAt: Date?
    let htmlURL: String?
    let contextCode: String?
    let author: Author?
}

/// One Canvas Inbox thread (GET /api/v1/conversations). Every property is
/// optional except id: Canvas tenants vary, so a missing field must degrade
/// to a fallback, never fail the whole sync.
///
/// Real-world notes (see Canvas Conversations API docs):
/// - `properties` is an array of flags like ["last_author", "attachments"],
///   or null — NOT an object. Older test fixtures used a dict form, which is
///   still accepted for backwards compatibility.
/// - The list endpoint omits `context_code`; the course lives in
///   `audience_contexts.courses` keys (e.g. {"123": [...]}).
/// - `participants` entries carry `name` / `full_name` (no display_name).
struct CanvasConversationDTO: Decodable, Sendable {
    struct Participant: Decodable, Sendable {
        let id: Int64?
        let name: String?
        let displayName: String?
        let fullName: String?

        var resolvedName: String? {
            displayName ?? name ?? fullName
        }
    }
    /// One message in a full-thread (show) response, newest first.
    struct Message: Decodable, Sendable {
        let id: Int64?
        let createdAt: Date?
        let body: String?
        let authorId: Int64?
    }
    struct AudienceContexts: Decodable, Sendable {
        let courses: [String: [String]]?
        let groups: [String: [String]]?

        enum CodingKeys: String, CodingKey { case courses, groups }

        init(from decoder: Decoder) throws {
            // Tolerant: any unexpected shape degrades to nil rather than
            // failing the conversation.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                courses = nil; groups = nil; return
            }
            courses = (try? container.decodeIfPresent([String: [String]].self, forKey: .courses)) ?? nil
            groups = (try? container.decodeIfPresent([String: [String]].self, forKey: .groups)) ?? nil
        }
    }
    let id: Int64
    let subject: String?
    let workflowState: String?
    let lastMessage: String?
    let lastMessageAt: Date?
    let messageCount: Int?
    let contextCode: String?
    let contextName: String?
    let participants: [Participant]?
    let audienceContexts: AudienceContexts?
    /// Full bodies, newest first. Present only in the show (single-thread)
    /// response; the list endpoint omits it and carries just the preview in
    /// `lastMessage`.
    let messages: [Message]?
    /// Raw `properties` flags (e.g. ["last_author"]). Empty when absent/null.
    let propertyFlags: [String]
    /// Author captured only when `properties` arrives in legacy dict form
    /// {"last_author": {...}}. Real API responses use the flags array + participants.
    let legacyLastAuthor: Participant?

    enum CodingKeys: String, CodingKey {
        case id
        case subject
        case workflowState
        case lastMessage
        case lastMessageAt
        case messageCount
        case contextCode
        case contextName
        case participants
        case audienceContexts
        case messages
        case properties
        case lastAuthor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        // Every optional field is decoded tolerantly: a single mistyped field
        // must degrade to nil, never fail the whole conversation (and, via the
        // array decode, never fail the whole inbox fetch).
        subject = (try? container.decodeIfPresent(String.self, forKey: .subject)) ?? nil
        workflowState = (try? container.decodeIfPresent(String.self, forKey: .workflowState)) ?? nil
        lastMessage = (try? container.decodeIfPresent(String.self, forKey: .lastMessage)) ?? nil
        // Tolerant date: try Date (uses the client's ISO-8601 strategy),
        // then fall back to manual string parsing so offset variants never
        // fail the whole conversation.
        if let date = (try? container.decodeIfPresent(Date.self, forKey: .lastMessageAt)) ?? nil {
            lastMessageAt = date
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .lastMessageAt)) ?? nil,
                  let parsed = CanvasClient.parseCanvasDate(raw) {
            lastMessageAt = parsed
        } else {
            lastMessageAt = nil
        }
        messageCount = (try? container.decodeIfPresent(Int.self, forKey: .messageCount)) ?? nil
        contextCode = (try? container.decodeIfPresent(String.self, forKey: .contextCode)) ?? nil
        contextName = (try? container.decodeIfPresent(String.self, forKey: .contextName)) ?? nil
        participants = (try? container.decodeIfPresent([Participant].self, forKey: .participants)) ?? nil
        audienceContexts = (try? container.decodeIfPresent(AudienceContexts.self, forKey: .audienceContexts)) ?? nil
        messages = (try? container.decodeIfPresent([Message].self, forKey: .messages)) ?? nil

        // `properties`: real API sends [String] or null. Accept legacy dict too.
        if let flags = try? container.decodeIfPresent([String].self, forKey: .properties) {
            propertyFlags = flags ?? []
            legacyLastAuthor = nil
        } else if let legacy = try? container.decodeIfPresent([String: Participant].self, forKey: .properties) {
            propertyFlags = []
            // Keys arrive snake_cased ("last_author"); the key strategy maps
            // them, but be permissive about the exact spelling.
            legacyLastAuthor = legacy["lastAuthor"] ?? legacy["last_author"]
        } else if let author = try? container.decodeIfPresent(Participant.self, forKey: .lastAuthor) {
            propertyFlags = []
            legacyLastAuthor = author
        } else {
            propertyFlags = []
            legacyLastAuthor = nil
        }
    }

    var isUnread: Bool { workflowState?.lowercased() == "unread" }

    /// Best-effort course ID: prefer explicit context_code, else the first
    /// course key in audience_contexts (the list endpoint's only course signal).
    var resolvedCourseID: Int64? {
        if let code = contextCode, code.hasPrefix("course_"),
           let id = Int64(code.dropFirst("course_".count)) {
            return id
        }
        if let keys = audienceContexts?.courses?.keys {
            // Keys are numeric strings like "123".
            let ids = keys.compactMap(Int64.init).sorted()
            if let first = ids.first { return first }
        }
        return nil
    }

    var resolvedAuthorName: String? {
        if let name = legacyLastAuthor?.resolvedName, !name.isEmpty { return name }
        let names = (participants ?? []).compactMap(\.resolvedName).filter { !$0.isEmpty }
        if names.isEmpty { return nil }
        return names.count == 1 ? names[0] : names.joined(separator: ", ")
    }

    var resolvedSubject: String {
        if let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines),
           !subject.isEmpty { return subject }
        if let author = resolvedAuthorName { return "Message from \(author)" }
        return "Inbox message"
    }

    /// Complete body for the detail view: newest full message first, falling
    /// back to the <=100 character list preview when the thread was loaded
    /// from the index endpoint.
    var fullBody: String? {
        if let body = messages?.lazy.compactMap({ $0.body }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return body
        }
        return lastMessage
    }
}
