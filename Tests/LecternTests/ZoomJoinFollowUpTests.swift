import AppKit
import XCTest
import SwiftUI

@MainActor
final class ZoomJoinFollowUpTests: XCTestCase {
    func testJoinHidesImmediatelyAndWaitsBeforeFollowUp() async throws {
        let followUp = ZoomJoinFollowUp()
        var hidden = false
        var fired = false
        followUp.schedule(delay: .milliseconds(60), hide: { hidden = true }) { fired = true }
        XCTAssertTrue(hidden)
        XCTAssertTrue(followUp.isPending)
        XCTAssertFalse(fired)
        try await Task.sleep(for: .milliseconds(150))
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
        followUp.schedule(delay: .milliseconds(30), hide: {}) { events.append("old") }
        followUp.schedule(delay: .milliseconds(30), hide: {}) { events.append("new") }
        try await Task.sleep(for: .milliseconds(100))
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
