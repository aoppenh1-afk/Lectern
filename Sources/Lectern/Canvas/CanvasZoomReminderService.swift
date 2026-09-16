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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Lectern · Zoom"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(reminder.invitation.topic).font(.title2.bold())
            Text("Host: \(reminder.invitation.host)").foregroundStyle(.secondary)
            Text(reminder.startAt.formatted(date: .abbreviated, time: .shortened))
            if reminder.startAt != reminder.invitation.startAt {
                Text("Using the Canvas class schedule.").font(.caption)
            }
            if opened {
                Text("Join in the Zoom app or your browser, then start recording when you’re ready.")
                Picker("Record", selection: $source) {
                    Text("Browser / system audio").tag(CaptureSource.systemAudio)
                    Text("Zoom app only").tag(CaptureSource.zoomApp)
                    Text("System audio + microphone").tag(CaptureSource.mixed)
                }
                Text(source.caption).font(.caption).foregroundStyle(.secondary)
                if capture.phase.isLive { Text("Another recording is already in progress.") }
                Button("Start Zoom recording when ready") {
                    Task {
                        await capture.start(in: course, source: source)
                        if case .recording = capture.phase { close() }
                        else { error = capture.errorMessage }
                    }
                }
                .disabled(capture.phase.isLive)
            } else {
                Text("Do you want to join this Zoom?")
                Button("Join Zoom") {
                    if NSWorkspace.shared.open(reminder.invitation.joinURL) { opened = true }
                    else { error = "Could not open the Zoom link. Try again." }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Button(opened ? "Dismiss" : "Not now", action: close)
        }
        .padding(22)
        .frame(width: 390, height: 480, alignment: .topLeading)
    }
}
