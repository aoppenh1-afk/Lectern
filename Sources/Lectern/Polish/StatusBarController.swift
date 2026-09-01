import AppKit
import SwiftUI

/// Owns the menu-bar status item and its popover. Hidden entirely when the
/// user disables the menu-bar surface in Settings.
@MainActor
final class StatusBarController {
    private let capture: CaptureController
    private let surfacePreferences: SurfacePreferences

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var observing = false

    init(capture: CaptureController, surfacePreferences: SurfacePreferences) {
        self.capture = capture
        self.surfacePreferences = surfacePreferences
        // NOTE: intentionally NOT observing UserDefaults here. During app
        // launch, NSApplication's own registerDefaults: posts
        // .didChangeNotification, and touching AppKit (status items) at that
        // moment re-enters NSApplication init and crashes the process.
        // Observation begins in installIfNeeded(), called after the UI is up.
    }

    func installIfNeeded() {
        guard !observing else {
            rebuild()
            return
        }
        observing = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        rebuild()
    }

    @objc private func preferencesChanged() {
        MainActor.assumeIsolated {
            rebuild()
        }
    }

    private func rebuild() {
        guard NSApp != nil else { return }
        let wanted = surfacePreferences.popoverEnabled

        if wanted {
            let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let symbolName = capture.phase.isLive ? "record.circle.fill" : "waveform.circle"
            item.button?.image = NSImage(systemSymbolName: symbolName,
                                         accessibilityDescription: "Lectern")?
                .withSymbolConfiguration(.init(paletteColors: [.labelColor]))

            if popover == nil {
                let pop = NSPopover()
                pop.behavior = .transient
                pop.contentSize = NSSize(width: 240, height: 260)
                pop.contentViewController = NSHostingController(
                    rootView: MenuBarPopoverView()
                        .environment(capture)
                )
                popover = pop
            }
            item.button?.action = #selector(togglePopover(_:))
            item.button?.target = self

            statusItem = item
        } else {
            popover?.performClose(nil)
            popover = nil
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
            }
            statusItem = nil
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Called whenever capture phase changes so a finished recording closes
    /// an open popover promptly.
    func refresh() {
        guard surfacePreferences.popoverEnabled else { return }
        if !capture.phase.isLive, popover?.isShown == true {
            // Give the user a beat to see the saved state before closing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard self?.capture.phase.isLive == false else { return }
                self?.popover?.performClose(nil)
            }
        }
    }
}
