import Foundation
import SwiftData
import XCTest

final class GoogleDocsSyncTests: XCTestCase {
    func testTabTitlesFitGoogleLimitIncludingUnicode() {
        let date = Date(timeIntervalSince1970: 0)
        for title in [String(repeating: "Shiur ", count: 15),
                      String(repeating: "הלכה ", count: 20),
                      String(repeating: "👨‍👩‍👧‍👦", count: 20)] {
            let tabTitle = NotesMarkdownConverter.tabTitle(date: date, lectureTitle: title)
            XCTAssertLessThanOrEqual(tabTitle.utf16.count, 50)
            XCTAssertTrue(tabTitle.hasSuffix("…"))
        }
        let datePart = NotesMarkdownConverter.tabTitle(date: date, lectureTitle: " ")
        XCTAssertEqual(NotesMarkdownConverter.tabTitle(date: date, lectureTitle: " Short "), "\(datePart) · Short")
        let exact = String(repeating: "a", count: 50 - datePart.utf16.count - 3)
        XCTAssertEqual(NotesMarkdownConverter.tabTitle(date: date, lectureTitle: exact), "\(datePart) · \(exact)")
    }

    @MainActor
    func testCourseDocumentDoesNotEnableOpeningAnUnpushedLecture() throws {
        let container = try ModelContainer(for: Course.self, Lecture.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let course = Course(name: "Shiurim", colorHex: "#ffffff")
        container.mainContext.insert(course)
        course.googleDocId = "existing-document"
        let lecture = Lecture(title: "New shiur", capturedAt: Date())
        container.mainContext.insert(lecture)
        lecture.course = course
        let service = GoogleDocsSyncService(auth: GoogleDocsAuth(), modelContainer: container)

        XCTAssertFalse(service.canOpen(lecture: lecture))
        XCTAssertNil(service.documentURL(for: lecture))
        lecture.googleTabId = ""
        XCTAssertFalse(service.canOpen(lecture: lecture))
        lecture.googleTabId = "new-shiur-tab"
        XCTAssertTrue(service.canOpen(lecture: lecture))
        XCTAssertEqual(service.documentURL(for: lecture)?.absoluteString,
                       "https://docs.google.com/document/d/existing-document/edit?tab=new-shiur-tab")
        course.googleDocId = nil
        XCTAssertFalse(service.canOpen(lecture: lecture))
    }
}

private final class GoogleTabCreationStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"replies":[{"addDocumentTab":{"tabProperties":{"tabId":"new-tab"}}}]}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension GoogleDocsSyncTests {
    @MainActor
    func testSameTitleDoesNotReuseAnotherLecturesTab() async throws {
        let container = try ModelContainer(for: Course.self, Lecture.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleTabCreationStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = GoogleDocsSyncService(auth: GoogleDocsAuth(), modelContainer: container,
                                           client: GoogleDocsClient(session: session))
        let lecture = Lecture(title: String(repeating: "Shiur ", count: 15), capturedAt: Date())
        container.mainContext.insert(lecture)
        let title = NotesMarkdownConverter.tabTitle(date: lecture.capturedAt, lectureTitle: lecture.title)
        let document = GoogleDocument(id: "doc", title: "Shiurim", tabs: [
            GoogleTab(id: "old-tab", title: title, bodyEndIndex: 100)
        ])
        for storedID in [nil, "deleted-tab"] as [String?] {
            lecture.googleTabId = storedID
            lecture.googleNotesHash = "old-hash"
            let tab = try await service.resolveTab(lecture: lecture, document: document,
                                                   title: title, accessToken: "fixture")
            XCTAssertEqual(tab.id, "new-tab")
            XCTAssertNil(lecture.googleNotesHash)
        }
        lecture.googleTabId = "old-tab"
        lecture.googleNotesHash = "existing-hash"
        let tab = try await service.resolveTab(lecture: lecture, document: document,
                                               title: title, accessToken: "fixture")
        XCTAssertEqual(tab.id, "old-tab")
        XCTAssertEqual(lecture.googleNotesHash, "existing-hash")
    }
}
