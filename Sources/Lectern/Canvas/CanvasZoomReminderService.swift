import AppKit
import SwiftData
import SwiftUI
import UserNotifications

@MainActor
final class CanvasZoomReminderService {
    static weak var current: CanvasZoomReminderService?
    static let prefix = "lectern-zoom-"

    struct Reminder: Codable, Identifiable {
        let id: String
        let invitation: CanvasZoomInvitation
        let courseID: Int64?
        let startAt: Date
        var sources: Set<String>
        var prompted: Bool = false
    }

    private let container: ModelContainer
    private let capture: CaptureController
    private let sync: CanvasSyncService
    private let connection: CanvasConnectionSettings
    private var reminders: [Reminder]
    private var loop: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var nextSyncAttempt = Date.distantPast
    private var panel: NSPanel?
    private var accountDomain: String
    private static let storageKey = "canvas.zoomReminders.v1"

    init(container: ModelContainer, capture: CaptureController, sync: CanvasSyncService,
         connection: CanvasConnectionSettings) {
        self.container = container
        self.capture = capture
        self.sync = sync
        self.connection = connection
        accountDomain = UserDefaults.standard.string(forKey: "canvas.zoomAccount") ?? connection.domain
        reminders = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Reminder].self, from: $0) } ?? []
        UserDefaults.standard.set(accountDomain, forKey: "canvas.zoomAccount")
        Self.current = self
        _ = SystemCompletionNotifier.shared
        sync.didSync = { [weak self] snapshot in await self?.update(snapshot) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.accountDomain != self.connection.domain {
                    self.clear()
                    self.accountDomain = self.connection.domain
                    UserDefaults.standard.set(self.accountDomain, forKey: "canvas.zoomAccount")
                }
                if self.connection.isConnected {
                    if Date() >= self.nextSyncAttempt, self.syncTask == nil {
                        self.nextSyncAttempt = Date().addingTimeInterval(300)
                        self.syncTask = Task { [weak self] in
                            guard let self else { return }
                            await self.sync.syncIfNeeded(maxAge: 300)
                            self.syncTask = nil
                        }
                    }
                    await self.checkDue()
                } else {
                    self.clear()
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        syncTask?.cancel(); syncTask = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func clear() {
        let ids = reminders.map { Self.prefix + $0.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        reminders = []
        panel?.close()
        save()
    }

    private func update(_ snapshot: CanvasSnapshot) async {
        guard connection.isConnected else { return }
        let events = snapshot.events.compactMap { event -> CanvasZoomInvitation.ClassEvent? in
            guard let start = event.startAt else { return nil }
            return .init(courseID: Self.courseID(event.contextCode), title: event.title,
                         startAt: start, details: event.description ?? "")
        }
        var messages: [(String, Int64?, String)] = snapshot.announcements.map {
            ($0.message ?? "", Self.courseID($0.contextCode), "announcement:\($0.id)")
        }
        for conversation in snapshot.conversations {
            let courseID = Self.courseID(conversation.contextCode) ?? conversation.resolvedCourseID
            let bodies = conversation.messages?.compactMap(\.body) ?? [conversation.lastMessage ?? ""]
            messages.append(contentsOf: bodies.map { ($0, courseID, "inbox:\(conversation.id)") })
        }
        var seen: [String: Set<String>] = [:]
        let completeSources = Set(snapshot.announcements.map { "announcement:\($0.id)" }
            + snapshot.conversations.filter { $0.messages != nil }.map { "inbox:\($0.id)" })
        for (body, originalCourseID, sourceID) in messages {
            for invitation in CanvasZoomInvitation.parse(body.canvasPlainText) {
                // URL + original date deduplicates announcements and inbox copies.
                let id = invitation.joinURL.absoluteString + "|" + String(invitation.startAt.timeIntervalSince1970)
                seen[sourceID, default: []].insert(id)
                let courseMatches = snapshot.courses.filter {
                    $0.name.compare(invitation.topic, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
                let old = reminders.first { $0.id == id }
                let courseID = originalCourseID ?? old?.courseID
                    ?? (courseMatches.count == 1 ? courseMatches.first?.id : nil)
                let syllabus = snapshot.courses.first { $0.id == courseID }?.syllabusBody?.canvasPlainText
                let start = invitation.resolvedStart(courseID: courseID, events: events, syllabus: syllabus)
                guard start > Date().addingTimeInterval(-15 * 60) else { continue }
                let reminder = Reminder(id: id, invitation: invitation, courseID: courseID ?? old?.courseID,
                                        startAt: start, sources: (old?.sources ?? []).union([sourceID]),
                                        prompted: old?.prompted ?? false)
                reminders.removeAll { $0.id == id }
                reminders.append(reminder)
            }
        }
        for index in reminders.indices {
            let id = reminders[index].id
            reminders[index].sources = reminders[index].sources.filter { source in
                !completeSources.contains(source) || seen[source, default: []].contains(id)
            }
        }
        let expired = reminders.filter { $0.sources.isEmpty || $0.startAt < Date().addingTimeInterval(-15 * 60) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: expired.map { Self.prefix + $0.id })
        reminders.removeAll { $0.sources.isEmpty || $0.startAt < Date().addingTimeInterval(-15 * 60) }
        save()
        let upcoming = reminders.filter { !$0.prompted && $0.startAt > Date() }
        guard UserDefaults.standard.object(forKey: NotificationPreferences.enabledKey) as? Bool != false else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: reminders.map { Self.prefix + $0.id })
            return
        }
        guard !upcoming.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for reminder in upcoming.sorted(by: { $0.startAt < $1.startAt }).prefix(32) {
            let content = UNMutableNotificationContent()
            content.title = "Join \(reminder.invitation.topic) on Zoom?"
            content.body = "Click to join. Lectern will ask when you’re ready to record."
            content.sound = .default
            let interval = reminder.startAt.timeIntervalSinceNow
            guard interval > 0 else { continue }
            try? await center.add(UNNotificationRequest(
                identifier: Self.prefix + reminder.id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)))
        }
    }

    private func checkDue() async {
        if UserDefaults.standard.object(forKey: NotificationPreferences.enabledKey) as? Bool == false {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: reminders.map { Self.prefix + $0.id })
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notificationsOff = UserDefaults.standard.object(forKey: NotificationPreferences.enabledKey) as? Bool == false
            || settings.authorizationStatus == .denied || settings.authorizationStatus == .notDetermined
        guard panel?.isVisible != true, NSApp.isActive || notificationsOff else { return }
        if let reminder = reminders.first(where: {
            !$0.prompted && $0.startAt <= Date() && $0.startAt > Date().addingTimeInterval(-15 * 60)
        }) {
            present(id: reminder.id)
        }
    }

    func present(id: String) {
        guard connection.isConnected, connection.domain == accountDomain,
              let index = reminders.firstIndex(where: { $0.id == id }),
              reminders[index].startAt > Date().addingTimeInterval(-15 * 60) else { return }
        // A timer and the foreground notification delegate can race for the same reminder.
        guard !reminders[index].prompted else { return }
        if panel?.isVisible == true { return }
        let reminder = reminders[index]
        reminders[index].prompted = true
        save()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.prefix + id])
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
        let view = CanvasZoomJoinView(reminder: reminder, capture: capture,
                                     course: course(for: reminder.courseID)) { [weak self] in
            self?.panel?.close()
        }
        panel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Lectern · Zoom"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func course(for id: Int64?) -> Course? {
        guard let id else { return nil }
        return (try? container.mainContext.fetch(FetchDescriptor<Course>()))?.first { $0.canvasID == id }
    }

    private static func courseID(_ code: String?) -> Int64? {
        guard let code, code.hasPrefix("course_") else { return nil }
        return Int64(code.dropFirst(7))
    }
}

private struct CanvasZoomJoinView: View {
    let reminder: CanvasZoomReminderService.Reminder
    let capture: CaptureController
    let course: Course?
    let close: () -> Void
    @State private var opened = false
    @State private var source: CaptureSource = .systemAudio
    @State private var error: String?

    @State private var starting = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top) {
                Image(systemName: opened ? "waveform" : "video.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        LinearGradient(colors: opened
                            ? [LecternTheme.accent, LecternTheme.accent.opacity(0.65)]
                            : [Color(red: 0.36, green: 0.65, blue: 1), Color(red: 0.20, green: 0.38, blue: 0.96)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.2)))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(LecternTheme.subtleFill, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Dismiss Zoom reminder")
            }

            VStack(spacing: 12) {
                if let course {
                    Label(course.name, systemImage: "book")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LecternTheme.accent)
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(LecternTheme.accent.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(LecternTheme.accent.opacity(0.22)))
                }
                Text(opened ? "Record Zoom Meeting?" : "Join Zoom Meeting?")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text(opened
                     ? "Join in Zoom, then start recording when you're ready."
                     : "Your Zoom session is about to start.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                detail("Host", icon: "person.2", value: reminder.invitation.host)
                detail("Date", icon: "calendar", value: reminder.startAt.formatted(date: .abbreviated, time: .omitted))
                detail("Time", icon: "clock", value: reminder.startAt.formatted(date: .omitted, time: .shortened))
                detail("Meeting", icon: "video", value: reminder.invitation.topic)
                if reminder.startAt != reminder.invitation.startAt {
                    Text("Using the Canvas class schedule.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LecternTheme.paper.opacity(0.18), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(LecternTheme.hairline))

            if opened {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AUDIO SOURCE")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(.secondary)
                    Picker("Audio source", selection: $source) {
                        Text("Browser / system audio").tag(CaptureSource.systemAudio)
                        Text("Zoom app only").tag(CaptureSource.zoomApp)
                        Text("System audio + microphone").tag(CaptureSource.mixed)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(starting)
                    Text(source.caption).font(.caption).foregroundStyle(.secondary)
                    if capture.phase.isLive {
                        Text("Another recording is already in progress.")
                            .font(.caption).foregroundStyle(LecternTheme.warningTint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(LecternTheme.recordTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button(action: primaryAction) {
                    ZStack {
                        Text(starting ? "Starting recording…" : opened ? "Start recording" : "Join Zoom")
                        HStack {
                            Spacer()
                            if starting { ProgressView().controlSize(.small) }
                            else { Image(systemName: opened ? "record.circle" : "arrow.right") }
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(ZoomPromptButtonStyle(primary: true, dark: colorScheme == .dark))
                .keyboardShortcut(.defaultAction)
                .disabled(opened && (capture.phase.isLive || starting))

                Button(action: close) {
                    Text(opened ? "Dismiss" : "Not now")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(ZoomPromptButtonStyle(primary: false, dark: colorScheme == .dark))
            }

            Rectangle().fill(LecternTheme.hairline).frame(height: 1)
            Text(opened ? "Lectern will capture audio for your transcript." : "This will open Zoom in a new window.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 460)
        .foregroundStyle(LecternTheme.ink)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(LecternTheme.canvasCard)
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [.white.opacity(0.035), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LecternTheme.ink.opacity(0.18)))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ label: String, icon: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 20)
                .foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }

    private func primaryAction() {
        error = nil
        if opened {
            guard !starting, !capture.phase.isLive else { return }
            starting = true
            Task {
                await capture.start(in: course, source: source)
                starting = false
                if case .recording = capture.phase { close() }
                else { error = capture.errorMessage }
            }
        } else if NSWorkspace.shared.open(reminder.invitation.joinURL) {
            opened = true
        } else {
            error = "Could not open the Zoom link. Try again."
        }
    }
}

private struct ZoomPromptButtonStyle: ButtonStyle {
    let primary: Bool
    let dark: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .foregroundStyle(primary ? Color.white : LecternTheme.ink)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(primary
                          ? LecternTheme.accent.opacity(dark ? 0.58 : 1)
                          : LecternTheme.subtleFill)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(configuration.isPressed ? 0.03 : hovering ? 0.09 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(primary ? LecternTheme.accent.opacity(0.3) : LecternTheme.hairline))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}
