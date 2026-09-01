import SwiftData
import SwiftUI

enum CommandStudioSection: String, CaseIterable, Identifiable {
    case overview, calendar, assignments, courses, grades, resources, announcements, aiChat

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .assignments: "Assignments"
        case .courses: "Courses"
        case .grades: "Grades"
        case .resources: "Resources"
        case .announcements: "Announcements"
        case .aiChat: "AI Chat"
        }
    }
    var icon: String {
        switch self {
        case .overview: "house"
        case .calendar: "calendar"
        case .assignments: "checklist"
        case .courses: "book.closed"
        case .grades: "chart.bar"
        case .resources: "folder"
        case .announcements: "megaphone"
        case .aiChat: "sparkles"
        }
    }
}

struct SuperAppShellView: View {
    @Environment(CanvasSyncService.self) private var canvasSync
    @Environment(CanvasConnectionSettings.self) private var canvasConnection
    @Environment(CaptureController.self) private var capture
    @Environment(TranscriptionService.self) private var transcription
    @Environment(RetentionService.self) private var retention
    @Environment(AppUpdater.self) private var updater
    @Environment(OnboardingState.self) private var onboarding
    @Query(sort: \Course.name) private var courses: [Course]
    @Query private var assignments: [CanvasAssignment]
    @Query private var announcements: [CanvasAnnouncement]
    @AppStorage("commandStudio.selectedTerm") private var selectedTerm = AcademicScopeMatcher.preferredTerm
    @State private var selection: CommandStudioSection = .overview

    private var availableTerms: [String] {
        Array(Array(Set(courses.compactMap(\.termName))).sorted().reversed())
    }

    private var scopedCourses: [Course] {
        courses.filter { AcademicScopeMatcher.matches(term: $0.termName, selectedTerm: selectedTerm) }
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
            scopedCanvasIDs.contains($0.courseCanvasID) && !$0.isComplete && ($0.dueAt ?? .distantFuture) >= Date()
        }.count
    }
    private var announcementCount: Int {
        announcements.lazy.filter { scopedCanvasIDs.contains($0.courseCanvasID) }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            commandSidebar
            Divider()
            destination
        }
        .background(LecternTheme.paper)
        .frame(minWidth: 1180, minHeight: 760)
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
            await updater.checkAutomaticallyIfDue()
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
        .onAppear(perform: resolvePreferredTerm)
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
            .padding(.top, 26)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("ACADEMIC TERM")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                StudioDropdown(
                    title: "Academic term",
                    selection: $selectedTerm,
                    options: termOptions,
                    width: 196
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            VStack(spacing: 5) {
                ForEach(CommandStudioSection.allCases) { section in
                    sidebarButton(section)
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            Divider().padding(.horizontal, 20)

            HStack(spacing: 8) {
                Circle()
                    .fill(canvasConnection.isConnected ? LecternTheme.successTint : Color.secondary.opacity(0.25))
                    .frame(width: 7, height: 7)
                Text(canvasConnection.isConnected ? "Canvas connected" : "Canvas not connected")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if canvasSync.isSyncing { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    Task { await canvasSync.syncNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(!canvasConnection.isConnected || canvasSync.isSyncing)
                .help("Sync Canvas now")
            }
            .foregroundStyle(LecternTheme.ink)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 236)
        .background(LecternTheme.paperDeep)
    }

    private func sidebarButton(_ section: CommandStudioSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13.5, weight: selection == section ? .medium : .regular))
                Spacer()
                if section == .assignments {
                    if upcomingCount > 0 { sidebarCount(upcomingCount) }
                } else if section == .announcements, announcementCount > 0 {
                    sidebarCount(announcementCount)
                }
            }
            .foregroundStyle(selection == section ? LecternTheme.accent : LecternTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == section ? LecternTheme.accent.opacity(0.10) : .clear)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .grades: CanvasGradesView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .resources: CanvasResourcesView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .announcements: CanvasAnnouncementsView(courses: scopedCourses, allowedCourseIDs: scopedCanvasIDs)
        case .aiChat: CommandStudioAIView(courses: scopedCourses)
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
    @Query(sort: \Course.name) private var courses: [Course]
    @Query(sort: \CanvasAssignment.dueAt) private var assignments: [CanvasAssignment]
    @Query(sort: \CanvasEvent.startAt) private var events: [CanvasEvent]
    @Query(sort: \CanvasAnnouncement.postedAt, order: .reverse) private var announcements: [CanvasAnnouncement]
    let allowedCourseIDs: Set<Int64>
    let navigate: (CommandStudioSection) -> Void

    private var scopedCourses: [Course] { courses.filter { $0.canvasID.map(allowedCourseIDs.contains) ?? false } }
    private var scopedAssignments: [CanvasAssignment] { assignments.filter { allowedCourseIDs.contains($0.courseCanvasID) } }
    private var scopedEvents: [CanvasEvent] { events.filter { $0.courseCanvasID.map(allowedCourseIDs.contains) ?? false } }
    private var scopedAnnouncements: [CanvasAnnouncement] { announcements.filter { allowedCourseIDs.contains($0.courseCanvasID) } }

    private var upcomingAssignments: [CanvasAssignment] {
        scopedAssignments.filter { !$0.isComplete && ($0.dueAt ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }.prefix(3).map { $0 }
    }
    private var todayEvents: [CanvasEvent] { scopedEvents.filter { Calendar.current.isDateInToday($0.startAt) }.prefix(4).map { $0 } }
    private var gradedCourses: [Course] { scopedCourses.filter { $0.currentScore != nil } }
    private var suggestedCourse: Course? {
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
                metric(icon: "book.closed", value: "\(scopedCourses.count)", label: "Classes")
                metric(icon: "circle.fill", value: nextDeadlineTitle, label: nextDeadlineLabel)
                metric(icon: "chart.line.uptrend.xyaxis", value: gpaEstimate, label: "Est. GPA")
            }
        }
    }

    private func metric(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(LecternTheme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 130, height: 62)
        .background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(LecternTheme.hairline))
    }

    private var activeSessionCard: some View {
        StudioCard("Active session") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(capture.phase.isLive ? LecternTheme.successTint : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                    Text(capture.phase.isLive ? "LIVE SYNCED" : "READY TO RECORD")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(capture.phase.isLive ? LecternTheme.accent : .secondary)
                    Spacer()
                }
                Text(capture.activeCourseName ?? suggestedCourse?.name ?? todayEvents.first?.courseName ?? "Start your first class")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(LecternTheme.ink)
                Text(activeSessionSubtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Button {
                    capture.toggle(in: suggestedCourse)
                } label: {
                    Text(capture.phase.isLive ? "Stop recording" : "Start grounded recording")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(LecternTheme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var scheduleCard: some View {
        StudioCard("Today's schedule", actionTitle: "View calendar") { navigate(.calendar) } content: {
            VStack(spacing: 0) {
                if todayEvents.isEmpty { emptyLine("No Canvas events scheduled today") }
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
                if upcomingAssignments.isEmpty { emptyLine("No upcoming Canvas assignments") }
                ForEach(upcomingAssignments) { assignment in
                    HStack(spacing: 11) {
                        RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.55)).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(assignment.courseCode ?? assignment.courseName): \(assignment.title)")
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(assignmentDetail(assignment)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(relativeDue(assignment.dueAt))
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(LecternTheme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(LecternTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.vertical, 8)
                    if assignment.id != upcomingAssignments.last?.id { Divider() }
                }
            }
        }
    }

    private var announcementCard: some View {
        StudioCard("Faculty bulletins", actionTitle: "View all") { navigate(.announcements) } content: {
            VStack(spacing: 10) {
                if scopedAnnouncements.isEmpty { emptyLine("No recent Canvas announcements") }
                ForEach(scopedAnnouncements.prefix(2)) { announcement in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Circle().fill(LecternTheme.accent).frame(width: 7, height: 7)
                            Text(announcement.courseName).font(.system(size: 11.5, weight: .medium)).foregroundStyle(LecternTheme.accent)
                            if let author = announcement.authorName { Text("·  \(author)").font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            Text(announcement.postedAt.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(announcement.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if let message = announcement.messageHTML?.canvasPlainText {
                            Text(message).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
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
            HStack { Text("COURSE STANDING").font(.system(size: 11, weight: .semibold)); Spacer(); Button("Open grades") { navigate(.grades) }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(LecternTheme.accent) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(gradedCourses) { course in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(course.courseCode ?? course.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1); Spacer(); Text(course.currentGrade ?? "").font(.system(size: 12, weight: .medium, design: .serif)) }
                        Text(course.currentScore.map { String(format: "%.1f%%", $0) } ?? "—").font(.system(size: 23, design: .serif))
                        ProgressView(value: min(max(course.currentScore ?? 0, 0), 100), total: 100).tint(LecternTheme.accent)
                        Text(course.instructorName ?? course.termName ?? "Synced from Canvas").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(14).background(LecternTheme.cardFill, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(LecternTheme.hairline))
                }
            }
        }
    }

    private func emptyLine(_ title: String) -> some View { Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 76, alignment: .center) }
    private var greeting: String { Calendar.current.component(.hour, from: Date()) < 12 ? "Good morning" : Calendar.current.component(.hour, from: Date()) < 18 ? "Good afternoon" : "Good evening" }
    private var activeSessionSubtitle: String { if capture.phase.isLive { return "Recording into \(capture.activeCourseName ?? "Unfiled")" }; if let event = todayEvents.first { return "\(event.startAt.formatted(date: .omitted, time: .shortened)) · \(event.locationName ?? "Canvas schedule")" }; return "Choose a course and Lectern will ground the recording in its class context." }
    private var nextDeadlineTitle: String { upcomingAssignments.first.map { String($0.title.prefix(16)) } ?? "All clear" }
    private var nextDeadlineLabel: String { upcomingAssignments.first.map { relativeDue($0.dueAt) } ?? "No deadline" }
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
