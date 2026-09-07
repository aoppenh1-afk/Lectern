import AppKit
import Foundation
import ScreenCaptureKit

/// Bundle identifiers and running-app checks for Zoom and related meeting
/// clients. Used for UI copy ("Zoom is open") — capture itself always takes
/// the full system mix so browser Zoom and helper processes are included.
enum MeetingAudioTarget {
    static let zoomBundleIDs: Set<String> = [
        "us.zoom.xos",
        "us.zoom.ringcentral",
        "us.zoom.ZoomClips",
        "us.zoom.ZoomPresence",
    ]

    static func isZoomBundleID(_ identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        if zoomBundleIDs.contains(identifier) { return true }
        return identifier.hasPrefix("us.zoom.")
    }

    static var isZoomRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            isZoomBundleID($0.bundleIdentifier)
        }
    }

    static func matchingApplications(_ apps: [SCRunningApplication]) -> [SCRunningApplication] {
        apps.filter { isZoomBundleID($0.bundleIdentifier) }
    }
}
