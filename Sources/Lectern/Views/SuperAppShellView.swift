import SwiftData
import SwiftUI

extension Notification.Name {
    static let lecternOpenSettings = Notification.Name("lectern.open-settings")
}

enum SettingsNavigator {
    private static let pendingKey = "lectern.openSettingsPending"

    /// Request the main window's Settings section. Works whether the main
    /// window is already open (live notification) or still opening
    /// (pending flag consumed on appear).
    static func open() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        NotificationCenter.default.post(name: .lecternOpenSettings, object: nil)
    }

    static func consumePending() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return false }
        UserDefaults.standard.set(false, forKey: pendingKey)
        return true
    }

    /// Focus the existing main window (or open one if none exists) and show
    /// Settings in it. Must not call openWindow unconditionally: WindowGroup
    /// spawns a brand-new window on every call. The notch pill is a
    /// borderless panel, so any titled window is a main window.
    @MainActor
    static func openInMainWindow(openWindow: OpenWindowAction) {
        open()
        let app = NSApplication.shared
        if let main = app.windows.first(where: { $0.styleMask.contains(.titled) && $0.isVisible }) {
            main.makeKeyAndOrderFront(nil)
        } else if let hidden = app.windows.first(where: { $0.styleMask.contains(.titled) }) {
            hidden.deminiaturize(nil)
            hidden.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        app.activate(ignoringOtherApps: true)
    }
}

enum CommandStudioSection: String, CaseIterable, Identifiable {
    case overview, calendar, assignments, courses, subscriptions, grades, resources, announcements, aiChat, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .assignments: "Assignments"
        case .courses: "Courses"
        case .subscriptions: "Subscriptions"
        case .grades: "Grades"
        case .resources: "Resources"
        case .announcements: "Announcements"
        case .aiChat: "AI Chat"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .overview: "house"
        case .calendar: "calendar"
        case .assignments: "checklist"
        case .courses: "book.closed"
        case .subscriptions: "antenna.radiowaves.left.and.right"
        case .grades: "chart.bar"
        case .resources: "folder"
        case .announcements: "megaphone"
        case .aiChat: "sparkles"
        case .settings: "gearshape"
        }
    }
}

struct SuperAppShellView: View {
    @Environment(CanvasSyncService.self) private var canvasSync
    @Environment(CanvasConnectionSettings.self) private var canvasConnection
    @Environment(YUBannerSyncService.self) private var bannerSync
    @Environment(CaptureController.self) private var capture
    @Environment(TranscriptionService.self) private var transcription
    @Environment(RetentionService.self) private var retention
    @Environment(AppUpdater.self) private var updater
    @Environment(OnboardingState.self) private var onboarding
    @Query(sort: \Course.name) private var courses: [Course]
    @Query private var assignments: [CanvasAssignment]
    @Query private var announcements: [CanvasAnnouncement]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("commandStudio.selectedTerm") private var selectedTerm = AcademicScopeMatcher.preferredTerm
    // Observed so the app-wide tint follows an accent change immediately.
    @AppStorage("appearance.accent") private var accentID = "moss"
    @State private var selection: CommandStudioSection = .overview

    private var availableTerms: [String] {
        Array(Array(Set(courses.compactMap(\.termName))).sorted().reversed())
    }

    private var scopedCourses: [Course] {
        courses.filter {
            AcademicScopeMatcher.includesInCoursesLibrary(
                canvasID: $0.canvasID,
                term: $0.termName,
                selectedTerm: selectedTerm
            )
        }
    }

    private var scopedCanvasIDs: Set<Int64> { Set(scopedCourses.compactMap(\.canvasID)) }
    private var coursesLibraryPersistentIDs: Set<PersistentIdentifier> {
        Set(courses.lazy.filter {
            AcademicScopeMatcher.includesInCoursesLibrary(
                canvasID: $0.canvasID,
                term: $0.termName,
                selectedTerm: selectedTerm
            )
        }.map(\.persistentModelID))
    }
    private var upcomingCount: Int {
        assignments.lazy.filter {
            ($0.isManual || scopedCanvasIDs.contains($0.courseCanvasID)) && !$0.isComplete && ($0.dueAt ?? .distantFuture) >= Date()
        }.count
    }
    private var announcementCount: Int {
        announcements.lazy.filter {
            ($0.courseCanvasID == 0 || scopedCanvasIDs.contains($0.courseCanvasID)) && !$0.isRead
        }.count
    }

    var body: some View {
        // Match the window. A minimum wider than the window is centered, so
        // leaving fullscreen clips the sidebar and the trailing controls.
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                commandSidebar
                destination
                    .workspaceCard()
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .padding(.trailing, 12)
                    .padding(.leading, 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .appCanvas()
        .ignoresSafeArea()
        // Stock controls (links, prominent buttons, switches, progress bars)
        // otherwise fall back to system blue instead of the brand accent.
        .tint(LecternTheme.accent(for: accentID))
        .background(WindowConfigurationView())
        .task(priority: .utility) {
            // Let SwiftUI commit the cached dashboard before maintenance touches SwiftData.
            try? await Task.sleep(for: .milliseconds(450))
            capture.recoverUnclaimedRecordings()
            await Task.yield()
            transcription.processPending()
            await Task.yield()
            retention.sweepNow()
        }
        .task(priority: .utility) {
            // Cached SwiftData renders immediately while the network refresh runs separately.
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                await canvasSync.syncIfNeeded()
                await bannerSync.syncIfNeeded(selectedTerm: selectedTerm)
                YUAcademicCalendar.seedIfNeeded(modelContext: modelContext,
                                               isYU: canvasConnection.isYUConnected)
                do {
                    try await Task.sleep(for: .seconds(CanvasAutomaticSyncPolicy.maxAge))
                } catch {
                    return
                }
            }
        }
        .task {
            onboarding.presentIfNeeded()
            // Do not stack an update prompt on top of first-run setup.
            while onboarding.isPresented, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            await updater.checkOnLaunch()
        }
        .sheet(isPresented: Binding(
            get: { onboarding.isPresented },
            set: { onboarding.isPresented = $0 }
        )) {
            OnboardingView()
                .interactiveDismissDisabled(onboarding.needsOnboarding)
        }
        .sheet(item: Binding(
            get: { onboarding.isPresented ? nil : updater.pendingPrompt },
            set: { if $0 == nil { updater.pendingPrompt = nil } }
        )) { release in
            UpdatePromptView(release: release)
        }
        .onAppear {
            resolvePreferredTerm()
            if SettingsNavigator.consumePending() {
                selection = .settings
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lecternOpenSettings)) { _ in
            selection = .settings
            _ = SettingsNavigator.consumePending()
        }
        .onChange(of: courses.count) { _, _ in resolvePreferredTerm() }
        .alert("Canvas sync failed", isPresented: .init(
            get: { canvasSync.errorMessage != nil },
            set: { if !$0 { canvasSync.clearError() } }
        )) {
            Button("OK", role: .cancel) { canvasSync.clearError() }
        } message: {
            Text(canvasSync.errorMessage ?? "")
        }
    }

    private var commandSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "building.columns")
                    .font(.system(size: 18, weight: .medium))
                Text("Lectern")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(LecternTheme.ink)
            .padding(.horizontal, 20)
            .padding(.top, 52)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("ACADEMIC TERM")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                StudioDropdown(
                    title: "Academic term",
                    selection: $selectedTerm,
                    options: termOptions,
                    width: 220
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 34)

            VStack(spacing: 4) {
                ForEach(CommandStudioSection.allCases.filter { $0 != .settings }) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            // Same row treatment as the sections above so Settings lines up
            // with them and shows where you are when it is open.
            sidebarButton(.settings)
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
        }
        .frame(width: 260)
        .glassSidebar()
    }

    private func sidebarButton(_ section: CommandStudioSection) -> some View {
        let selected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: selected ? .medium : .regular))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                Spacer()
                if section == .assignments {
                    if upcomingCount > 0 { sidebarCount(upcomingCount) }
                } else if section == .announcements, announcementCount > 0 {
                    sidebarCount(announcementCount)
                }
            }
            .foregroundStyle(selected ? LecternTheme.sidebarSelectedText : LecternTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? LecternTheme.sidebarSelectedFill : .clear)
            )
            .shadow(
                color: selected ? Color.black.opacity(0.04) : .clear,
                radius: 6, y: 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarCount(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var destination: some View {
        destinationView(for: selection)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func destinationView(for section: CommandStudioSection) -> some View {
        switch section {
        case .overview: OverviewDashboardView(allowedCourseIDs: scopedCanvasIDs, navigate: {
            selection = $0
        })
        case .calendar: CanvasCalendarView(allowedCourseIDs: scopedCanvasIDs)
        case .assignments: CanvasAssignmentsView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .courses: MainWindowView(allowedCourseIDs: coursesLibraryPersistentIDs)
        case .subscriptions: SubscriptionsView()
        case .grades: CanvasGradesView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .resources: CanvasResourcesView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .announcements: CanvasAnnouncementsView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .aiChat: CommandStudioAIView(courses: scopedCourses)
        case .settings: SettingsView()
        }
    }

    private func resolvePreferredTerm() {
        selectedTerm = AcademicScopeMatcher.resolvedTerm(
            selectedTerm: selectedTerm,
            availableTerms: availableTerms
        )
    }

    private var termOptions: [StudioDropdownOption<String>] {
        var values = availableTerms
        if !values.contains(selectedTerm) { values.insert(selectedTerm, at: 0) }
        return values.map { StudioDropdownOption(value: $0, title: $0) }
    }
}

struct StudioCard<Content: View>: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LecternTheme.ink.opacity(0.78))
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LecternTheme.accent)
                }
            }
            .padding(.bottom, 14)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: 230, alignment: .topLeading)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LecternTheme.hairline))
    }
}

struct OverviewDashboardView: View {
    @Environment(CaptureController.self) private var capture
    @Environment(SurfacePreferences.self) private var surfacePreferences
    @Environment(CanvasConnectionSettings.self) private var canvasConnection
    @Query(sort: \Course.name) private var courses: [Course]
    @Query(sort: \CanvasAssignment.dueAt) private var assignments: [CanvasAssignment]
    @Query(sort: \CanvasEvent.startAt) private var events: [CanvasEvent]
    @Query(sort: \CanvasAnnouncement.postedAt, order: .reverse) private var announcements: [CanvasAnnouncement]
    let allowedCourseIDs: Set<Int64>
    let navigate: (CommandStudioSection) -> Void

    private var scopedCourses: [Course] { courses.filter { $0.canvasID.map(allowedCourseIDs.contains) ?? false } }
    private var scopedAssignments: [CanvasAssignment] {
        assignments.filter { $0.isManual || allowedCourseIDs.contains($0.courseCanvasID) }
    }
    private var scopedEvents: [CanvasEvent] {
        events.filter { $0.isManual || ($0.courseCanvasID.map(allowedCourseIDs.contains) ?? false) }
            .sorted { $0.startAt < $1.startAt }
    }
    private var scopedAnnouncements: [CanvasAnnouncement] {
        announcements.filter { $0.courseCanvasID == 0 || allowedCourseIDs.contains($0.courseCanvasID) }
    }

    private var upcomingAssignments: [CanvasAssignment] {
        scopedAssignments.filter { !$0.isComplete && ($0.dueAt ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }.prefix(3).map { $0 }
    }
    private var todayEvents: [CanvasEvent] { scopedEvents.filter { Calendar.current.isDateInToday($0.startAt) }.prefix(4).map { $0 } }
    private var gradedCourses: [Course] { scopedCourses.filter { $0.currentScore != nil } }
    private var bannerInputs: [(name: String, code: String?, meetings: [YUClassMeeting])] {
        // Banner times apply to YU Canvas only.
        guard canvasConnection.isYUConnected else { return [] }
        return scopedCourses.map { ($0.name, $0.courseCode, $0.bannerMeetings) }.filter { !$0.meetings.isEmpty }
    }
    private var nextBanner: YUBannerSchedule.Occurrence? {
        YUBannerSchedule.nextClass(in: bannerInputs)
    }
    private var bannerToday: [YUBannerSchedule.Occurrence] {
        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = YUClassMeeting.yuTimeZone
        var rows: [YUBannerSchedule.Occurrence] = []
        for course in scopedCourses where !course.bannerMeetings.isEmpty {
            for meeting in course.bannerMeetings {
                guard let start = meeting.start(on: now, calendar: calendar) else { continue }
                let end: Date? = {
                    guard let endMinutes = meeting.endMinutes else { return nil }
                    return calendar.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: start)
                }()
                rows.append(.init(courseName: course.name, courseCode: course.courseCode, meeting: meeting, start: start, end: end))
            }
        }
        return rows.sorted { $0.start < $1.start }.prefix(4).map { $0 }
    }
    private var suggestedCourse: Course? {
        if let next = nextBanner,
           let bannerCourse = scopedCourses.first(where: { $0.name == next.courseName }) {
            return bannerCourse
        }
        if let courseID = todayEvents.first?.courseCanvasID,
           let scheduledCourse = scopedCourses.first(where: { $0.canvasID == courseID }) {
            return scheduledCourse
        }
        return scopedCourses.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: [.init(.flexible(), spacing: 14), .init(.flexible(), spacing: 14)], spacing: 14) {
                    activeSessionCard
                    scheduleCard
                    deadlineCard
                    announcementCard
                }
                gradeStrip
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
        }
        .background(LecternTheme.paper)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LecternTheme.accent)
                Text("Today's Command Studio")
                    .font(.system(size: 31, weight: .bold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                metric(icon: "book.closed", value: "\(scopedCourses.count)", label: scopedCourses.count == 1 ? "Class" : "Classes")
                metric(icon: "calendar.badge.clock", value: nextDeadlineValue, label: nextDeadlineLabel, width: 190)
                metric(icon: "chart.line.uptrend.xyaxis", value: gpaEstimate, label: "Est. GPA")
            }
        }
    }

    private func metric(icon: String, value: String, label: String, width: CGFloat = 132) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LecternTheme.accent)
                .frame(width: 30, height: 30)
                .background(LecternTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(LecternTheme.ink).lineLimit(1)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 62)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(LecternTheme.hairline))
    }

    private var activeSessionCard: some View {
        StudioCard("Active session") {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Circle().fill(capture.phase.isLive ? LecternTheme.successTint : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                        Text(capture.phase.isLive ? "LIVE SYNCED" : "READY TO RECORD")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(capture.phase.isLive ? LecternTheme.accent : .secondary)
                        Spacer()
                    }
                    Text(activeSessionTitle)
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(LecternTheme.ink)
                    Text(activeSessionSubtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Button {
                        capture.toggle(in: suggestedCourse, source: surfacePreferences.captureSource)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: capture.phase.isLive ? "stop.fill" : "record.circle")
                                .font(.system(size: 12, weight: .semibold))
                            Text(capture.phase.isLive ? "Stop recording" : surfacePreferences.captureSource == .microphone ? "Start recording" : surfacePreferences.captureSource.recordButtonTitle)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(capture.phase.isLive ? LecternTheme.recordTint : LecternTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(suggestedCourse.map { "Record into \($0.name) with its class materials as context" } ?? "Start recording")
                }
            }
        }
    }

    private var activeSessionTitle: String {
        if capture.phase.isLive { return capture.activeCourseName ?? "Unfiled" }
        if let next = nextBanner { return next.courseName }
        return suggestedCourse?.name ?? todayEvents.first?.courseName ?? "Start your first class"
    }

    private var scheduleCard: some View {
        StudioCard("Today's schedule", actionTitle: "View calendar") { navigate(.calendar) } content: {
            VStack(spacing: 0) {
                if bannerToday.isEmpty, todayEvents.isEmpty { emptyLine("Nothing scheduled today", icon: "calendar") }
                ForEach(Array(bannerToday.enumerated()), id: \.offset) { _, occurrence in
                    HStack(alignment: .top, spacing: 12) {
                        Text(occurrence.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11).monospacedDigit()).frame(width: 54, alignment: .leading)
                        Circle().fill(occurrence.start < Date() ? LecternTheme.accent : Color.secondary.opacity(0.45)).frame(width: 8, height: 8).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(occurrence.courseName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text([occurrence.meeting.timeDisplay, occurrence.meeting.locationDisplay].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
                ForEach(todayEvents) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.startAt.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11).monospacedDigit()).frame(width: 54, alignment: .leading)
                        Circle().fill(event.startAt < Date() ? LecternTheme.accent : Color.secondary.opacity(0.45)).frame(width: 8, height: 8).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Text([event.courseName, event.locationName].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    if event.id != todayEvents.last?.id { Divider() }
                }
            }
        }
    }

    private var deadlineCard: some View {
        StudioCard("Upcoming work & deadlines", actionTitle: "View all") { navigate(.assignments) } content: {
            VStack(spacing: 0) {
                if upcomingAssignments.isEmpty { emptyLine("You're all caught up", icon: "checkmark.circle") }
                ForEach(upcomingAssignments) { assignment in
                    HStack(spacing: 12) {
                        DueDateTile(date: assignment.dueAt, tint: dueTint(assignment.dueAt))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(assignment.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(LecternTheme.ink)
                                .lineLimit(1)
                            Text([assignment.courseCode ?? assignment.courseName,
                                  assignment.pointsPossible.map { "\($0.formatted()) pts" },
                                  assignment.isMissing ? "Missing" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(assignment.dueAt == nil ? "No date" : relativeDue(assignment.dueAt))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(dueTint(assignment.dueAt))
                    }
                    .padding(.vertical, 7)
                    if assignment.id != upcomingAssignments.last?.id { Divider().padding(.leading, 48) }
                }
            }
        }
    }

    private var announcementCard: some View {
        StudioCard("Faculty bulletins", actionTitle: "View all") { navigate(.announcements) } content: {
            VStack(spacing: 10) {
                if scopedAnnouncements.isEmpty { emptyLine("No recent announcements", icon: "megaphone") }
                ForEach(scopedAnnouncements.prefix(2)) { announcement in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if !announcement.isRead {
                                Circle().fill(LecternTheme.accent).frame(width: 6, height: 6)
                            }
                            Text(announcement.courseName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LecternTheme.accent)
                                .lineLimit(1)
                            if announcement.isInboxMessage {
                                Text("Inbox").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                            Spacer(minLength: 8)
                            Text(announcement.postedAt.formatted(.relative(presentation: .named)))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        Text(announcement.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(LecternTheme.ink)
                            .lineLimit(1)
                        Text([canvasAuthorSummary(announcement.authorName),
                              announcement.messageHTML?.canvasPreviewText]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": "))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(LecternTheme.hairline))
                }
            }
        }
    }

    private var gradeStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COURSE STANDING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LecternTheme.ink.opacity(0.78))
                Spacer()
                Button("Open grades") { navigate(.grades) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LecternTheme.accent)
            }
            if gradedCourses.isEmpty {
                Text("Grades appear here after Canvas returns a score.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(gradedCourses) { course in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(course.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LecternTheme.ink)
                                    .lineLimit(1)
                                Text([course.courseCode, course.instructorName].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let letter = course.currentGrade, !letter.isEmpty {
                                Text(letter)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(hex: course.colorHex).darkened(by: 0.12))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(hex: course.colorHex).opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                        Text(course.currentScore.map { String(format: "%.1f%%", $0) } ?? "—")
                            .font(.system(size: 24, design: .serif).monospacedDigit())
                            .foregroundStyle(LecternTheme.ink)
                        ScoreBar(fraction: (course.currentScore ?? 0) / 100, tint: Color(hex: course.colorHex))
                    }
                    .padding(14).background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LecternTheme.hairline))
                }
            }
        }
    }

    private func emptyLine(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
    private var greeting: String { Calendar.current.component(.hour, from: Date()) < 12 ? "Good morning" : Calendar.current.component(.hour, from: Date()) < 18 ? "Good afternoon" : "Good evening" }
    private var activeSessionSubtitle: String {
        if capture.phase.isLive {
            return "\(capture.liveStatusTitle) into \(capture.activeCourseName ?? "Unfiled")"
        }
        if let next = nextBanner {
            var parts = [next.start.formatted(date: .omitted, time: .shortened)]
            if let location = next.meeting.locationDisplay { parts.append(location) }
            if next.start <= Date(), let end = next.end {
                parts.append("In progress")
                parts.append("Ends at \(end.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append(countdown(to: next.start))
            }
            return parts.joined(separator: " · ") + " · YU schedule"
        }
        if let event = todayEvents.first {
            return "\(event.startAt.formatted(date: .omitted, time: .shortened)) · \(event.locationName ?? "Canvas schedule")"
        }
        return "Lectern files the recording under this course and uses its materials as context."
    }

    private func countdown(to date: Date) -> String {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "Starting now" }
        if minutes < 60 { return "Starts in \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "Starts in \(hours)h" }
        let days = hours / 24
        return days == 1 ? "Tomorrow" : "In \(days) days"
    }
    private var nextDeadlineValue: String {
        guard let next = upcomingAssignments.first else { return "All clear" }
        return next.dueAt == nil ? "Next up" : dueSummary(next.dueAt)
    }
    private var nextDeadlineLabel: String { upcomingAssignments.first?.title ?? "No upcoming deadlines" }
    private var gpaEstimate: String { let scores = gradedCourses.compactMap(\.currentScore); guard !scores.isEmpty else { return "—" }; let points = scores.map { score in score >= 93 ? 4.0 : score >= 90 ? 3.7 : score >= 87 ? 3.3 : score >= 83 ? 3.0 : score >= 80 ? 2.7 : score >= 77 ? 2.3 : score >= 73 ? 2.0 : score >= 70 ? 1.7 : score >= 67 ? 1.3 : score >= 65 ? 1.0 : 0 }; return String(format: "%.2f", points.reduce(0, +) / Double(points.count)) }
}

func assignmentDetail(_ assignment: CanvasAssignment) -> String {
    var parts: [String] = []
    if let due = assignment.dueAt { parts.append("Due \(due.formatted(date: .abbreviated, time: .shortened))") }
    if let points = assignment.pointsPossible { parts.append("\(points.formatted()) pts") }
    if assignment.isMissing { parts.append("Missing") }
    return parts.joined(separator: " · ")
}

func relativeDue(_ date: Date?) -> String {
    guard let date else { return "No date" }
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0
    return days > 0 && days < 7 ? "\(days) days" : date.formatted(.dateTime.month(.abbreviated).day())
}

/// Sentence-style due phrase for headlines: "Due today", "Due in 3 days".
func dueSummary(_ date: Date?) -> String {
    guard let date else { return "No due date" }
    let calendar = Calendar.current
    if date < Date(), !calendar.isDateInToday(date) { return "Overdue" }
    if calendar.isDateInToday(date) { return "Due today" }
    if calendar.isDateInTomorrow(date) { return "Due tomorrow" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: date).day ?? 0
    return days > 0 && days < 7 ? "Due in \(days) days" : "Due \(date.formatted(.dateTime.month(.abbreviated).day()))"
}

/// Due label tint: overdue and same-day work draws the eye, later work recedes.
func dueTint(_ date: Date?, isComplete: Bool = false) -> Color {
    guard !isComplete, let date else { return .secondary }
    let calendar = Calendar.current
    if date < Date(), !calendar.isDateInToday(date) { return LecternTheme.recordTint }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: date).day ?? 0
    if days <= 1 { return LecternTheme.warningTint }
    return LecternTheme.accent
}
