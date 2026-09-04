#!/usr/bin/env swift

import AppKit
import ApplicationServices

private let lecternBundleID = ProcessInfo.processInfo.environment["LECTERN_BUNDLE_ID"]
    ?? "com.lectern.Lectern"
private let controlCenterBundleID = "com.apple.controlcenter"

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return ""
    }
    return value as? String ?? ""
}

private func rect(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    var position = CGPoint.zero
    var size = CGSize.zero

    guard AXUIElementCopyAttributeValue(
        element,
        kAXPositionAttribute as CFString,
        &positionValue
    ) == .success,
    let positionValue,
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
    AXUIElementCopyAttributeValue(
        element,
        kAXSizeAttribute as CFString,
        &sizeValue
    ) == .success,
    let sizeValue,
    CFGetTypeID(sizeValue) == AXValueGetTypeID(),
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
        return nil
    }

    return CGRect(origin: position, size: size)
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

private func menuBarItems(for application: NSRunningApplication) -> [(AXUIElement, CGRect)] {
    let root = AXUIElementCreateApplication(application.processIdentifier)
    return children(of: root).flatMap { menuBar -> [(AXUIElement, CGRect)] in
        guard stringAttribute(menuBar, kAXRoleAttribute) == kAXMenuBarRole as String else {
            return []
        }
        return children(of: menuBar).compactMap { item in
            guard let frame = rect(of: item) else { return nil }
            return (item, frame)
        }
    }
}

guard let screen = NSScreen.main else {
    fputs("RED: no main screen is available\n", stderr)
    exit(1)
}

let lecternApps = NSRunningApplication.runningApplications(withBundleIdentifier: lecternBundleID)
guard lecternApps.count == 1, let lectern = lecternApps.first else {
    fputs("RED: expected one running Lectern app, found \(lecternApps.count)\n", stderr)
    exit(1)
}

let lecternItems = menuBarItems(for: lectern)
let matchingItems = lecternItems.filter { item, _ in
    let description = stringAttribute(item, kAXDescriptionAttribute)
    let title = stringAttribute(item, kAXTitleAttribute)
    return description == "Lectern menu bar controls" || title == "Lectern menu bar controls"
}

guard matchingItems.count == 1, let (_, itemFrame) = matchingItems.first else {
    fputs("RED: expected one Lectern menu-bar item, found \(matchingItems.count)\n", stderr)
    exit(1)
}

let topBand = CGRect(x: -10, y: -10, width: screen.frame.width + 20, height: 52)
guard topBand.contains(itemFrame) else {
    fputs("RED: Lectern item is not in the top menu bar; frame=\(itemFrame)\n", stderr)
    exit(1)
}

let controlCenterItems = NSRunningApplication
    .runningApplications(withBundleIdentifier: controlCenterBundleID)
    .flatMap(menuBarItems)
    .map(\.1)
    .filter { !$0.isEmpty }

if let overlap = controlCenterItems.first(where: { $0.intersects(itemFrame) }) {
    fputs(
        "RED: Lectern item overlaps a system menu-bar item; lectern=\(itemFrame) system=\(overlap)\n",
        stderr
    )
    exit(1)
}

print("GREEN: Lectern item is visible in the top menu bar at \(itemFrame)")
