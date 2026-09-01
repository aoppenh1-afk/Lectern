import AppKit
import CoreText
import XCTest

private final class CanvasResourceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task.detached { [request] in
            do {
                guard let handler = Self.handler else { throw URLError(.badServerResponse) }
                let (response, data) = try handler(request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}

private final class CanvasRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var activeRequests = 0
    private var peakRequests = 0

    func begin(_ path: String) {
        lock.lock()
        paths.append(path)
        activeRequests += 1
        peakRequests = max(peakRequests, activeRequests)
        lock.unlock()
    }

    func end() {
        lock.lock()
        activeRequests -= 1
        lock.unlock()
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    var maximumConcurrentRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakRequests
    }
}

private func testPDFData(_ text: String) -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return Data() }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 72, y: 700)
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 12)]
    ))
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

private func testScannedPDFData(_ text: String) -> Data {
    let width = 1_200
    let height = 1_600
    guard let bitmap = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return Data() }
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    bitmap.setFillColor(gray: 0, alpha: 1)
    bitmap.textPosition = CGPoint(x: 80, y: 1_400)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: 42)]
    )), bitmap)
    guard let image = bitmap.makeImage() else { return Data() }

    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return Data() }
    var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
    guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
    pdf.beginPDFPage(nil)
    pdf.draw(image, in: mediaBox)
    pdf.endPDFPage()
    pdf.closePDF()
    return data as Data
}

final class CanvasClientTests: XCTestCase {
    func testCanvasFileResourceLoadsArticleTextForCourseChat() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CanvasResourceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        CanvasResourceURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/api/v1/files/5736708" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                let metadata = #"{"url":"https://files.example.test/abortion.pdf","display_name":"abortion.pdf","content-type":"application/pdf"}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(metadata.utf8))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let article = "The author argues that fetal status changes across stages of pregnancy."
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!, testPDFData(article))
        }
        defer { CanvasResourceURLProtocol.handler = nil }

        let loader = CanvasResourceContentLoader(
            credentials: CanvasCredentials(baseURL: URL(string: "https://school.instructure.com")!, token: "test-token"),
            session: session
        )
        let source = try await loader.source(for: CanvasResourceReference(
            title: "Abortion in Halakhic Literature",
            moduleName: "Abortion",
            kind: "File",
            canvasID: 5_736_708,
            htmlURL: nil,
            apiURL: "https://school.instructure.com/api/v1/files/5736708"
        ))

        XCTAssertTrue(source.content.contains("fetal status changes across stages"), source.content)
        XCTAssertTrue(source.images.isEmpty)
    }

    func testCanvasScannedPDFAttachesRenderedPagesForCourseChat() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CanvasResourceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fixture: Data
        if let path = ProcessInfo.processInfo.environment["LECTERN_SCANNED_PDF_FIXTURE"] {
            fixture = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            fixture = testScannedPDFData("Scanned source page")
        }
        CanvasResourceURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/api/v1/files/5736973" {
                let metadata = #"{"url":"https://files.example.test/abortion-_NA.pdf","display_name":"abortion-_NA.pdf","content-type":"application/pdf"}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(metadata.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!, fixture)
        }
        defer { CanvasResourceURLProtocol.handler = nil }

        let loader = CanvasResourceContentLoader(
            credentials: CanvasCredentials(baseURL: URL(string: "https://school.instructure.com")!, token: "test-token"),
            session: session
        )
        let source = try await loader.source(for: CanvasResourceReference(
            title: "Abraham, Abraham, Abortion",
            moduleName: "Abortion",
            kind: "File",
            canvasID: 5_736_973,
            htmlURL: nil,
            apiURL: "https://school.instructure.com/api/v1/files/5736973"
        ))

        XCTAssertTrue(source.content.contains("scanned PDF with no text layer"), source.content)
        XCTAssertFalse(source.images.isEmpty)
        XCTAssertTrue(source.images.allSatisfy { !$0.data.isEmpty && $0.mimeType == "image/png" })
    }

    func testCanvasFileResourceDoesNotOpenAnUnauthenticatedBrowserDownload() {
        let destination = CanvasResourceDestination.url(
            kind: "File",
            canvasID: 5_736_708,
            htmlURL: nil,
            apiURL: "https://school.instructure.com/api/v1/files/5736708"
        )

        XCTAssertNil(destination)
    }

    func testCanvasResourcePrefersBrowserURLWhenCanvasProvidesOne() {
        let destination = CanvasResourceDestination.url(
            kind: "Page",
            canvasID: 5_736_708,
            htmlURL: "https://school.instructure.com/courses/42/modules/items/99",
            apiURL: "https://school.instructure.com/api/v1/files/5736708"
        )

        XCTAssertEqual(destination?.absoluteString, "https://school.instructure.com/courses/42/modules/items/99")
    }

    func testSnapshotRequestsCourseFilesEvenWhenCourseHasNoModules() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CanvasResourceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let probe = CanvasRequestProbe()
        CanvasResourceURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            probe.begin(url.path)
            defer { probe.end() }
            let body: String
            switch url.path {
            case "/api/v1/courses":
                body = #"[{"id":80281,"name":"Microbiology"}]"#
            case "/api/v1/courses/80281/files":
                body = #"[{"id":5736708,"folder_id":44,"display_name":"MicroBiology laboratory Syllabus.pdf","filename":"microbiology-syllabus.pdf","content-type":"application/pdf","url":"https://school.instructure.com/files/5736708/download?download_frd=1"}]"#
            case "/api/v1/courses/80281/folders":
                body = #"[{"id":44,"name":"Lecture Content 2026","full_name":"course files/Lecture Content 2026"}]"#
            default:
                body = "[]"
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { CanvasResourceURLProtocol.handler = nil }

        let snapshot = try await CanvasClient(
            credentials: CanvasCredentials(baseURL: URL(string: "https://school.instructure.com")!, token: "test-token"),
            session: session
        ).fetchSnapshot()

        XCTAssertTrue(
            probe.requestedPaths.contains("/api/v1/courses/80281/files"),
            "Canvas files that are not module items must still be synced"
        )
        XCTAssertEqual(snapshot.files.map(\.displayName), ["MicroBiology laboratory Syllabus.pdf"])
        XCTAssertEqual(snapshot.files.map(\.folderID), [44])
        XCTAssertEqual(snapshot.files.map(\.apiURL), ["https://school.instructure.com/api/v1/files/5736708"])
        XCTAssertEqual(snapshot.folders.map(\.fullName), ["course files/Lecture Content 2026"])
    }

    func testCourseSyncOverlapsIndependentCanvasRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CanvasResourceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let probe = CanvasRequestProbe()
        CanvasResourceURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            probe.begin(url.path)
            defer { probe.end() }
            let body: String
            if url.path == "/api/v1/courses" {
                body = #"[{"id":11,"name":"Course One"},{"id":22,"name":"Course Two"}]"#
            } else {
                Thread.sleep(forTimeInterval: 0.04)
                body = "[]"
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { CanvasResourceURLProtocol.handler = nil }

        _ = try await CanvasClient(
            credentials: CanvasCredentials(baseURL: URL(string: "https://school.instructure.com")!, token: "test-token"),
            session: session
        ).fetchSnapshot()

        XCTAssertGreaterThanOrEqual(
            probe.maximumConcurrentRequests,
            2,
            "Course endpoints are independent and should not make startup sync wait on each request serially"
        )
    }

    func testAcademicScopeMatchesOnlySelectedTerm() {
        XCTAssertTrue(AcademicScopeMatcher.matches(term: "Fall 2026", selectedTerm: "Fall 2026"))
        XCTAssertTrue(AcademicScopeMatcher.matches(term: "fall 2026", selectedTerm: "Fall 2026"))
        XCTAssertFalse(AcademicScopeMatcher.matches(term: "Spring 2026", selectedTerm: "Fall 2026"))
        XCTAssertFalse(AcademicScopeMatcher.matches(term: nil, selectedTerm: "Fall 2026"))
    }

    func testCoursesLibraryIncludesLocalCoursesAlongsideSelectedCanvasTerm() {
        XCTAssertTrue(AcademicScopeMatcher.includesInCoursesLibrary(
            canvasID: nil,
            term: nil,
            selectedTerm: "Fall 2026"
        ))
        XCTAssertTrue(AcademicScopeMatcher.includesInCoursesLibrary(
            canvasID: 42,
            term: "Fall 2026",
            selectedTerm: "Fall 2026"
        ))
        XCTAssertFalse(AcademicScopeMatcher.includesInCoursesLibrary(
            canvasID: 42,
            term: "Spring 2026",
            selectedTerm: "Fall 2026"
        ))
    }

    func testAcademicTermFallsBackToAnAvailableCanvasTerm() {
        XCTAssertEqual(
            AcademicScopeMatcher.resolvedTerm(
                selectedTerm: "Fall 2026",
                availableTerms: ["Spring 2027", "Fall 2027"]
            ),
            "Spring 2027"
        )
    }

    func testAcademicScopeMembershipPerformance() {
        let allowed = Set((0..<32).map(Int64.init))
        let values = (0..<25_000).map { Int64($0 % 64) }
        measure {
            var count = 0
            for value in values where AcademicScopeMatcher.contains(courseID: value, allowedCourseIDs: allowed) {
                count += 1
            }
            XCTAssertEqual(count, 12_512)
        }
    }

    func testAutomaticCanvasSyncUsesOneHourCacheWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(CanvasAutomaticSyncPolicy.shouldSync(
            lastSyncAt: now.addingTimeInterval(-30 * 60),
            lastSyncedDataVersion: CanvasAutomaticSyncPolicy.dataVersion,
            now: now
        ))
        XCTAssertTrue(CanvasAutomaticSyncPolicy.shouldSync(
            lastSyncAt: now.addingTimeInterval(-61 * 60),
            lastSyncedDataVersion: CanvasAutomaticSyncPolicy.dataVersion,
            now: now
        ))
    }

    func testAutomaticCanvasSyncRefreshesWhenDataVersionChanges() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(CanvasAutomaticSyncPolicy.shouldSync(
            lastSyncAt: now.addingTimeInterval(-5 * 60),
            lastSyncedDataVersion: CanvasAutomaticSyncPolicy.dataVersion - 1,
            now: now
        ))
    }

    func testNormalizesCanvasDomainAndDropsPaths() throws {
        XCTAssertEqual(
            try CanvasClient.normalizedBaseURL("school.instructure.com/courses/42").absoluteString,
            "https://school.instructure.com"
        )
    }

    func testRejectsInsecureCanvasDomain() {
        XCTAssertThrowsError(try CanvasClient.normalizedBaseURL("http://school.instructure.com"))
    }

    func testFindsOpaqueNextPaginationLink() {
        let header = "<https://school.instructure.com/api/v1/courses?page=1>; rel=\"current\", <https://school.instructure.com/api/v1/courses?opaque=abc%2B123>; rel=\"next\""
        XCTAssertEqual(
            CanvasClient.nextLink(from: header)?.absoluteString,
            "https://school.instructure.com/api/v1/courses?opaque=abc%2B123"
        )
    }
}
