import AppKit
import SwiftData
import SwiftUI

struct MenuBarPopoverView: View {
    /// One fixed popover geometry for every idle selection state.
    /// 340 points leaves enough room for four equal source segments plus
    /// the standard 14-point content margins without clipping.
    static let popoverWidth: CGFloat = 340
    private static let contentWidth = popoverWidth - 28

    @Environment(CaptureController.self) private var capture
    @Environment(SurfacePreferences.self) private var surfacePreferences
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Course.name) private var courses: [Course]

    @State private var selectedCourse: Course?
    @State private var selectedLanguage: LectureLanguage = .english
    @State private var bookmarkNote = ""

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            Group {
                if capture.phase.isLive {
                    liveContent
                        .transition(.opacity)
                } else {
                    idleContent
                        .transition(.opacity)
                }
            }
            .frame(width: Self.contentWidth, alignment: .leading)
            .padding(14)
        }
        .frame(width: Self.popoverWidth, alignment: .center)
    }

    // MARK: - Idle

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LecternTheme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Lectern")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Ready to record")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider().opacity(0.5)

            if !courses.isEmpty {
                Picker("Course", selection: $selectedCourse) {
                    Text("None (Unfiled)").tag(Optional<Course>.none)
                    ForEach(courses) { course in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: course.colorHex))
                                .frame(width: 7, height: 7)
                            Text(course.name)
                        }
                        .tag(Optional(course))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: Self.contentWidth)
                .onChange(of: selectedCourse) { _, course in
                    selectedLanguage = course?.language ?? .english
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                EqualWidthSegmentedControl(
                    titles: CaptureSource.allCases.map(\.shortTitle),
                    selectedIndex: Binding(
                        get: {
                            CaptureSource.allCases.firstIndex(of: surfacePreferences.captureSource) ?? 0
                        },
                        set: { index in
                            guard CaptureSource.allCases.indices.contains(index) else { return }
                            surfacePreferences.setCaptureSource(CaptureSource.allCases[index])
                        }
                    ),
                    accessibilityLabel: "Recording source"
                )
                .frame(width: Self.contentWidth, height: 24)

                Text(sourceCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3, reservesSpace: true)
                    .frame(width: Self.contentWidth, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 4) {
                EqualWidthSegmentedControl(
                    titles: LectureLanguage.allCases.map(\.title),
                    selectedIndex: Binding(
                        get: { LectureLanguage.allCases.firstIndex(of: selectedLanguage) ?? 0 },
                        set: { index in
                            guard LectureLanguage.allCases.indices.contains(index) else { return }
                            selectedLanguage = LectureLanguage.allCases[index]
                        }
                    ),
                    accessibilityLabel: "Lecture language"
                )
                .frame(width: Self.contentWidth, height: 24)

                Text(selectedLanguage.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(width: Self.contentWidth, alignment: .topLeading)
            }

            if let errorMessage = capture.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(LecternTheme.warningTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    await capture.start(
                        in: selectedCourse,
                        language: selectedLanguage,
                        source: surfacePreferences.captureSource
                    )
                }
            } label: {
                Label(surfacePreferences.captureSource.recordButtonTitle, systemImage: "record.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .prominentAction()
            .tint(LecternTheme.recordTint)
            .frame(width: Self.contentWidth)

            Divider().opacity(0.5)

            popoverLink("Open Lectern", systemImage: "book.closed") {
                openWindow(id: "main")
            }
            popoverLink("Settings…", systemImage: "gearshape") {
                SettingsNavigator.openInMainWindow(openWindow: openWindow)
            }
            popoverLink("Quit Lectern", systemImage: "power", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private func popoverLink(_ title: String, systemImage: String,
                             role: ButtonRole? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(role == .destructive ? AnyShapeStyle(LecternTheme.recordTint) : AnyShapeStyle(Color.secondary))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(LecternTheme.recordTint) : AnyShapeStyle(Color.primary))
        .frame(width: Self.contentWidth)
    }

    // MARK: - Live

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 7) {
                    Circle()
                        .fill(LecternTheme.recordTint)
                        .frame(width: 7, height: 7)
                        .symbolEffect(.pulse)

                    Text(capture.liveStatusTitle)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text(elapsedString)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(LecternTheme.recordTint)
                }
            }

            if let course = capture.activeCourseName {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 5, height: 5)
                    Text(course)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                capture.stop()
            } label: {
                Label("Stop & Save Lecture", systemImage: "stop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .prominentAction()
            .frame(width: Self.contentWidth)

            HStack(spacing: 6) {
                TextField("Quick thought…", text: $bookmarkNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveThought)
                Button(action: saveThought) {
                    Image(systemName: "bookmark.fill")
                }
                .help(bookmarkNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "Drop bookmark (Option-Command-B)"
                      : "Save timestamped thought")
                Button {
                    capture.addBookmark(isExamAlert: true)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .help("Exam alert (Option-Command-B)")
            }
            .frame(width: Self.contentWidth)

            if !capture.liveBookmarks.isEmpty {
                Text("\(capture.liveBookmarks.count) bookmark\(capture.liveBookmarks.count == 1 ? "" : "s") saved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("The transcript appears after you stop — nothing is shown during class.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var sourceCaption: String {
        if surfacePreferences.captureSource.zoomAppOnly {
            return MeetingAudioTarget.isZoomRunning
                ? "Zoom is open. Lectern will capture only the Zoom app."
                : "Open the Zoom desktop app, then press Record."
        }
        if surfacePreferences.captureSource.includesSystemAudio, MeetingAudioTarget.isZoomRunning {
            return "Zoom is open. Lectern will capture what this Mac is playing."
        }
        return surfacePreferences.captureSource.caption
    }

    private var elapsedString: String {
        let interval = Int(capture.elapsedInterval)
        return String(format: "%02d:%02d:%02d",
                      interval / 3600,
                      (interval % 3600) / 60,
                      interval % 60)
    }

    private func saveThought() {
        guard capture.addBookmark(note: bookmarkNote) else { return }
        bookmarkNote = ""
    }
}

/// A native AppKit segmented control whose geometry is independent of selection.
/// SwiftUI's segmented Picker can publish a changing intrinsic width on newer
/// macOS releases; this control instead fills one explicit frame with equal
/// segments so changing the selected item only moves the highlight.
private struct EqualWidthSegmentedControl: NSViewRepresentable {
    let titles: [String]
    @Binding var selectedIndex: Int
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedIndex: $selectedIndex)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: titles,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(accessibilityLabel)
        control.selectedSegment = selectedIndex
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selectedIndex = $selectedIndex
        if control.segmentCount != titles.count {
            control.segmentCount = titles.count
        }
        for (index, title) in titles.enumerated() {
            control.setLabel(title, forSegment: index)
        }
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(accessibilityLabel)
        control.selectedSegment = selectedIndex
    }

    final class Coordinator: NSObject {
        var selectedIndex: Binding<Int>

        init(selectedIndex: Binding<Int>) {
            self.selectedIndex = selectedIndex
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0 else { return }
            selectedIndex.wrappedValue = sender.selectedSegment
        }
    }
}
