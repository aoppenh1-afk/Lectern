import AppKit
import XCTest
import SwiftUI

@MainActor
final class ZoomJoinFollowUpTests: XCTestCase {
    func testJoinHidesImmediatelyAndWaitsBeforeFollowUp() async throws {
        let followUp = ZoomJoinFollowUp()
        var hidden = false
        var fired = false
        let completed = expectation(description: "Delayed follow-up ran")
        followUp.schedule(delay: .milliseconds(60), hide: { hidden = true }) {
            fired = true
            completed.fulfill()
        }
        defer { followUp.cancel() }
        XCTAssertTrue(hidden)
        XCTAssertTrue(followUp.isPending)
        XCTAssertFalse(fired)
        // Wait for the event, not a guess at how quickly the CI runner schedules it.
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(fired)
        XCTAssertFalse(followUp.isPending)
    }

    func testCancellationPreventsRecordingOrPrompt() async throws {
        let followUp = ZoomJoinFollowUp()
        var fired = false
        followUp.schedule(delay: .milliseconds(30), hide: {}) { fired = true }
        followUp.cancel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(fired)
        XCTAssertFalse(followUp.isPending)
    }

    func testNewJoinReplacesPreviousFollowUp() async throws {
        let followUp = ZoomJoinFollowUp()
        var events: [String] = []
        let completed = expectation(description: "Replacement follow-up ran")
        followUp.schedule(delay: .milliseconds(30), hide: {}) { events.append("old") }
        followUp.schedule(delay: .milliseconds(30), hide: {}) {
            events.append("new")
            completed.fulfill()
        }
        defer { followUp.cancel() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(events, ["new"])
    }

    func testRecordingPanelDoesNotActivateAndUsesScreenCorner() {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: Text("Record Zoom meeting?").frame(width: 340, height: 200))
        let panel = ZoomJoinFollowUp.makePanel(content: view, screen: NSScreen.main)
        defer { panel.close() }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.frame.width, 340, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 200, accuracy: 1)
        if let bounds = NSScreen.main?.visibleFrame {
            XCTAssertEqual(panel.frame.maxX, bounds.maxX - 20, accuracy: 1)
            XCTAssertEqual(panel.frame.minY, bounds.minY + 20, accuracy: 1)
        }
    }
}
