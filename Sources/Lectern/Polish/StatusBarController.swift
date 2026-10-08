import AppKit
import SwiftUI

/// Owns the menu-bar status item and its popover. Hidden entirely when the
/// user disables the menu-bar surface in Settings.
@MainActor
final class StatusBarController {
    private static let autosaveName = "LecternMenuBarItem"
    private static let idlePopoverSize = NSSize(width: MenuBarPopoverView.popoverWidth, height: 360)

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
        // Observation begins in installIfNeeded(), after app launch completes.
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
        assertVisibleSoon()
    }

    @objc private func preferencesChanged() {
        MainActor.assumeIsolated {
            rebuild()
            if let popover {
                updatePopoverSize(popover)
            }
        }
    }

    private func rebuild() {
        guard NSApp != nil else { return }
        let wanted = surfacePreferences.popoverEnabled

        if wanted {
            let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = Self.autosaveName
            let symbolName = capture.phase.isLive ? "record.circle.fill" : "waveform.circle"
            item.button?.image = NSImage(systemSymbolName: symbolName,
                                         accessibilityDescription: "Lectern menu bar controls")?
                .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
            item.button?.setAccessibilityLabel("Lectern menu bar controls")
            item.button?.setAccessibilityTitle("Lectern menu bar controls")
            item.button?.action = #selector(togglePopover(_:))
            item.button?.target = self

            // Settings is the source of truth for visibility. AppKit can restore
            // a persisted hidden state for this autosave name, so assert
            // visible on every rebuild, not just once per install.
            item.isVisible = true
            statusItem = item
        } else {
            popover?.performClose(nil)
            popover = nil
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
            }
            statusItem = nil
            surfacePreferences.menuBarBlocked = false
        }
    }

    /// Re-asserts visibility shortly after install. The persisted hidden state
    /// for the autosave name can be restored asynchronously after the item is
    /// created, re-hiding it after the synchronous assert in rebuild().
    /// Also detects when macOS Control Center refuses to host the item at all
    /// (per-bundle blocklist in Tahoe's menu-bar ledger): the button's window
    /// then has no screen. Surfaces as SurfacePreferences.menuBarBlocked so
    /// Settings can tell the user how to re-allow Lectern.
    private func assertVisibleSoon() {
        guard let item = statusItem,
              surfacePreferences.popoverEnabled else { return }
        for delay in [2.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak item] in
                guard let self, let item,
                      self.statusItem === item,
                      self.surfacePreferences.popoverEnabled else { return }
                item.isVisible = true
                // A hosted item's button window belongs to a screen. When
                // Control Center blocks the bundle, the window is never
                // hosted (screen stays nil) even though isVisible is true.
                self.surfacePreferences.menuBarBlocked = item.button?.window?.screen == nil
            }
        }
    }

    private func popoverRootView() -> AnyView {
        AnyView(
            MenuBarPopoverView()
                .environment(capture)
                .environment(surfacePreferences)
                .preferredColorScheme(surfacePreferences.appearance.colorScheme)
        )
    }

    private func updatePopoverSize(_ pop: NSPopover) {
        guard let hosting = pop.contentViewController as? NSHostingController<AnyView> else { return }
        // Keep idle selections from changing the shell's geometry. During a
        // recording, retain the width but fit the shorter live controls,
        // including the course and bookmark count when present.
        var size = Self.idlePopoverSize
        if capture.phase.isLive {
            hosting.view.layoutSubtreeIfNeeded()
            size.height = ceil(hosting.sizeThatFits(in: NSSize(
                width: size.width,
                height: .greatestFiniteMagnitude
            )).height)
        }
        hosting.preferredContentSize = size
        pop.contentSize = size
    }

    private func buildPopover() -> NSPopover {
        let pop = NSPopover()
        pop.behavior = .transient

        let hosting = NSHostingController(rootView: popoverRootView())
        // Manage geometry here instead of reflecting SwiftUI's changing
        // intrinsic sizes into AppKit after every source/language selection.
        hosting.sizingOptions = []

        pop.contentViewController = hosting
        updatePopoverSize(pop)
        return pop
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
        } else {
            let pop = popover ?? buildPopover()
            self.popover = pop
            updatePopoverSize(pop)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            updatePopoverSize(pop)
            // AppKit's popover window is a nonactivating panel. Give only it
            // key focus so controls respond immediately without activating
            // Lectern and bringing the main window forward.
            pop.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Called whenever capture phase changes so a finished recording closes
    /// an open popover promptly.
    func refresh() {
        guard surfacePreferences.popoverEnabled else { return }
        rebuild()
        if let hosting = popover?.contentViewController as? NSHostingController<AnyView> {
            hosting.rootView = popoverRootView()
        }
        if let popover {
            updatePopoverSize(popover)
        }
        if !capture.phase.isLive, popover?.isShown == true {
            // Give the user a beat to see the saved state before closing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard self?.capture.phase.isLive == false else { return }
                self?.popover?.performClose(nil)
            }
        }
    }
}
