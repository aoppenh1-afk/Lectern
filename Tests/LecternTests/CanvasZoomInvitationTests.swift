import XCTest

final class CanvasZoomInvitationTests: XCTestCase {
    private let message = """
    [Create Meeting]
    ---------------------------
    Topic: Microbiology
    Host: Radhashree Maitra
    Time: Sep 16, 2026 6:30 PM, Eastern Time (US and Canada)
    :
      2026-09-16 18:30:00
      2026-09-23 18:30:00
      2026-09-30 18:30:00
    Join URL: https://yeshiva-university.zoom.us/j/99277861371
    """

    func testParsesOnlyMainDateInEasternDaylightTime() throws {
        let invitations = CanvasZoomInvitation.parse(message)
        XCTAssertEqual(invitations.count, 1)
        let invitation = try XCTUnwrap(invitations.first)
        XCTAssertEqual(invitation.topic, "Microbiology")
        XCTAssertEqual(invitation.host, "Radhashree Maitra")
        XCTAssertEqual(invitation.startAt, date("2026-09-16T22:30:00Z"))
    }

    func testWinterUsesEasternStandardTime() throws {
        let winter = message.replacingOccurrences(of: "Sep 16", with: "Dec 16")
        XCTAssertEqual(try XCTUnwrap(CanvasZoomInvitation.parse(winter).first).startAt,
                       date("2026-12-16T23:30:00Z"))
    }

    func testMatchingClassOverridesEarlyZoomTime() throws {
        let invitation = try XCTUnwrap(CanvasZoomInvitation.parse(message).first)
        let actual = date("2026-09-16T22:45:00Z")
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: [
            .init(courseID: 42, title: "Microbiology", startAt: actual, details: "")
        ]), actual)
    }

    func testUnrelatedAndAmbiguousEventsDoNotOverride() throws {
        let invitation = try XCTUnwrap(CanvasZoomInvitation.parse(message).first)
        let actual = date("2026-09-16T22:45:00Z")
        let unrelated: [CanvasZoomInvitation.ClassEvent] = [
            .init(courseID: 99, title: "Microbiology", startAt: actual, details: ""),
            .init(courseID: 42, title: "Office hours", startAt: actual, details: ""),
            .init(courseID: 42, title: "Microbiology", startAt: date("2026-09-23T22:45:00Z"), details: "")
        ]
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: unrelated), invitation.startAt)
        XCTAssertEqual(invitation.resolvedStart(courseID: nil, events: unrelated), invitation.startAt)
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: [
            .init(courseID: 42, title: "Microbiology", startAt: actual, details: ""),
            .init(courseID: 42, title: "Microbiology", startAt: actual.addingTimeInterval(300), details: "")
        ]), invitation.startAt)
    }

    func testExplicitSyllabusClassTimeAndOfficeHours() throws {
        let invitation = try XCTUnwrap(CanvasZoomInvitation.parse(message).first)
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: [],
                        syllabus: "Class meetings: Wednesdays 6:45 PM"), date("2026-09-16T22:45:00Z"))
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: [],
                        syllabus: "Office hours for class: Wednesdays 6:45 PM"), invitation.startAt)
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: [],
                        syllabus: "Class meetings: Thursdays 6:45 PM"), invitation.startAt)
    }

    func testUnknownZoneAndUntrustedLinksAreRejected() {
        XCTAssertTrue(CanvasZoomInvitation.parse(message.replacingOccurrences(
            of: "Eastern Time (US and Canada)", with: "Unknown Time")).isEmpty)
        XCTAssertTrue(CanvasZoomInvitation.parse(message.replacingOccurrences(
            of: "yeshiva-university.zoom.us", with: "zoom.us.evil.example")).isEmpty)
        XCTAssertTrue(CanvasZoomInvitation.parse(message.replacingOccurrences(
            of: "https://", with: "http://")).isEmpty)
        XCTAssertTrue(CanvasZoomInvitation.parse(message.replacingOccurrences(
            of: "[Create Meeting]", with: "Other message")).isEmpty)
    }

    func testMultipleMeetingBlocksAndHTML() {
        XCTAssertEqual(CanvasZoomInvitation.parse(message + "\n" + message).count, 2)
        let html = "<p>" + message.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        XCTAssertEqual(CanvasZoomInvitation.parse(html.canvasPlainText).count, 1)
    }

    func testRenderedLineSeparatorsPreserveInvitationFields() {
        let expected = CanvasZoomInvitation.parse(message)
        XCTAssertEqual(expected.count, 1)
        // HTML rendering can use Unicode line/paragraph separators instead of LF.
        for separator in ["\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let rendered = message.replacingOccurrences(of: "\n", with: separator)
            XCTAssertEqual(CanvasZoomInvitation.parse(rendered), expected,
                           "Line separator: \(separator.debugDescription)")
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
