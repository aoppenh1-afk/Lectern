import AppKit
import SwiftUI

/// Chrome-less always-on-top pill docked at the top center of the screen
/// (over the notch region). Shows a pulsing red dot and elapsed time while a
/// capture is live; expands on hover to reveal the stop button.
@MainActor
final class PillWindowController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<PillContentView>?
    private let capture: CaptureController
    private let surfacePreferences: SurfacePreferences

    private static let collapsedWidth: CGFloat = 132
    private static let expandedWidth: CGFloat = 260
    private static let height: CGFloat = 34

    init(capture: CaptureController, surfacePreferences: SurfacePreferences) {
        self.capture = capture
        self.surfacePreferences = surfacePreferences
    }

    /// Re-evaluates visibility from capture phase + user preference.
    func refresh() {
        let shouldBeVisible = surfacePreferences.pillEnabled && capture.phase.isLive

        if shouldBeVisible {
            if panel == nil { buildPanel() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.collapsedWidth, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let content = PillContentView(
            capture: capture,
            onWidthChange: { [weak self] expanded in
                self?.resize(expanded: expanded)
            }
        )
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
        positionPanel()
    }

    private func positionPanel() {
        guard let panel,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let width = panel.frame.width
        let x = screen.frame.midX - width / 2
        // Hug the very top edge of the built-in display (notch region).
        let y = screen.frame.maxY - panel.frame.height - 1
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func resize(expanded: Bool) {
        guard let panel else { return }
        let targetWidth = expanded ? Self.expandedWidth : Self.collapsedWidth
        var frame = panel.frame
        let delta = targetWidth - frame.width
        frame.size.width = targetWidth
        frame.origin.x -= delta / 2   // keep centered while expanding
        panel.setFrame(frame, display: true)
    }
}

// MARK: - Pill content

struct PillContentView: View {
    @Bindable var capture: CaptureController
    let onWidthChange: (Bool) -> Void

    @State private var hovered = false

    var body: some View {
        Group {
            if case .recording(let startedAt) = capture.phase {
                pill(startedAt: startedAt)
            } else {
                // Transient phases (permission/saving): keep the pill quiet.
                Color.clear.frame(width: 10, height: 10)
            }
        }
        .onHover { hovering in
            hovered = hovering
            onWidthChange(hovering)
        }
    }

    @ViewBuilder
    private func pill(startedAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse)

                Text(Self.elapsed(since: startedAt))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)

                if hovered {
                    Button {
                        capture.addBookmark()
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Drop bookmark (Option-Command-B)")

                    Button {
                        capture.addBookmark(isExamAlert: true)
                    } label: {
                        Image(systemName: "exclamationmark.bookmark.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Exam alert (Option-Command-B)")

                    Button {
                        capture.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop recording")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, hovered ? 12 : 14)
            .frame(height: 26)
            .glassEffect(.regular, in: Capsule())
            .animation(.spring(response: 0.3), value: hovered)
        }
    }

    static func elapsed(since date: Date) -> String {
        let interval = max(0, Int(Date().timeIntervalSince(date)))
        return String(format: "%02d:%02d:%02d",
                      interval / 3600,
                      (interval % 3600) / 60,
                      interval % 60)
    }
}
