import Foundation
import SwiftData
import XCTest

@MainActor
final class LecternCloudSharingTests: XCTestCase {
    func testSnapshotIncludesOnlySelectedCoursesAndSupportedDocuments() throws {
        let container = try ModelContainer(for: Course.self, Lecture.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let selected = Course(name: "Selected", colorHex: "#123456")
        selected.currentGrade = "private grade"
        let hidden = Course(name: "Unshared", colorHex: "#123456")
        let lecture = Lecture(title: "Visible", capturedAt: Date())
        lecture.course = selected
        lecture.sourceMediaURL = "https://example.com/private-audio"
        lecture.artifacts = [Artifact(kind: .notes, content: "בחירה חופשית", modelInfo: "private provider info")]
        let privateLecture = Lecture(title: "Hidden lecture", capturedAt: Date())
        privateLecture.course = hidden
        let unfiled = Lecture(title: "Unfiled", capturedAt: Date())
        for course in [selected, hidden] { container.mainContext.insert(course) }
        for item in [lecture, privateLecture, unfiled] { container.mainContext.insert(item) }
        try container.mainContext.save()
        let suite = "LecternCloudSharingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharing = LecternCloudSharing(container: container, defaults: defaults)
        defer { sharing.shutdown() }
        let selectedID = try LecternCloudSharing.id(for: selected.persistentModelID)
        sharing.sharedCourseIDs = [selectedID]
        let snapshot = try sharing.snapshot()
        XCTAssertEqual(snapshot.courses.map(\.name), ["Selected"])
        XCTAssertEqual(snapshot.lectures.map(\.title), ["Visible"])
        XCTAssertEqual(snapshot.lectures.first?.documents["notes"], "בחירה חופשית")
        let json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for forbidden in ["private grade", "private-audio", "private provider info", "Hidden lecture"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        for _ in 0..<10 { XCTAssertEqual(try LecternCloudSharing.id(for: selected.persistentModelID), selectedID) }
        sharing.shareUnfiled = true
        XCTAssertEqual(try sharing.snapshot().lectures.count, 2)
        sharing.sharedCourseIDs = []
        XCTAssertEqual(try sharing.snapshot().lectures.map(\.title), ["Unfiled"])
    }
}
