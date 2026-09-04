import AppKit
import Foundation
import UserNotifications

enum CompletionNotificationCategory: String, Sendable {
    case transcription
    case generation
}

struct CompletionNotification: Equatable, Sendable {
    let category: CompletionNotificationCategory
    let title: String
    let body: String

    static func transcriptionFinished(lectureTitle: String) -> Self {
        Self(
            category: .transcription,
            title: "Transcription complete",
            body: "\"\(lectureTitle)\" is ready to review."
        )
    }

    static func generationFinished(lectureTitle: String, items: [String]) -> Self {
        let itemList = items.formatted(.list(type: .and))
        return Self(
            category: .generation,
            title: "Generation complete",
            body: "Finished generating \(itemList) for \"\(lectureTitle)\"."
        )
    }
}

@MainActor
@Observable
final class NotificationPreferences {
    enum AuthorizationState: Equatable {
        case unknown
        case notDetermined
        case denied
        case authorized
    }

    nonisolated static let enabledKey = "notifications.enabled"
    nonisolated static let transcriptionKey = "notifications.transcriptionEnabled"
    nonisolated static let generationKey = "notifications.generationEnabled"

    private let center: UNUserNotificationCenter
    private let userDefaults: UserDefaults

    private(set) var authorizationState: AuthorizationState = .unknown
    var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    var transcriptionEnabled: Bool {
        didSet { userDefaults.set(transcriptionEnabled, forKey: Self.transcriptionKey) }
    }
    var generationEnabled: Bool {
        didSet { userDefaults.set(generationEnabled, forKey: Self.generationKey) }
    }

    init(
        center: UNUserNotificationCenter = .current(),
        userDefaults: UserDefaults = .standard
    ) {
        self.center = center
        self.userDefaults = userDefaults
        isEnabled = Self.bool(forKey: Self.enabledKey, userDefaults: userDefaults)
        transcriptionEnabled = Self.bool(forKey: Self.transcriptionKey, userDefaults: userDefaults)
        generationEnabled = Self.bool(forKey: Self.generationKey, userDefaults: userDefaults)
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        guard enabled else { return }

        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshAuthorizationState()
        if authorizationState == .denied {
            openSystemSettings()
        }
    }

    func refreshAuthorizationState() async {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            authorizationState = .notDetermined
        case .denied:
            authorizationState = .denied
        case .authorized, .provisional, .ephemeral:
            authorizationState = .authorized
        @unknown default:
            authorizationState = .unknown
        }
    }

    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lectern.Lectern"
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func isDeliveryEnabled(
        for category: CompletionNotificationCategory,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard bool(forKey: enabledKey, userDefaults: userDefaults) else { return false }
        switch category {
        case .transcription:
            return bool(forKey: transcriptionKey, userDefaults: userDefaults)
        case .generation:
            return bool(forKey: generationKey, userDefaults: userDefaults)
        }
    }

    private nonisolated static func bool(forKey key: String, userDefaults: UserDefaults) -> Bool {
        userDefaults.object(forKey: key) as? Bool ?? true
    }
}

protocol CompletionNotifying: AnyObject {
    func prepare(for category: CompletionNotificationCategory)
    func deliver(_ notification: CompletionNotification)
}

final class SystemCompletionNotifier: NSObject, CompletionNotifying, UNUserNotificationCenterDelegate,
                                      @unchecked Sendable {
    static let shared = SystemCompletionNotifier()

    private let center: UNUserNotificationCenter
    private let authorizationLock = NSLock()
    private var requestedAuthorization = false

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func prepare(for category: CompletionNotificationCategory) {
        guard NotificationPreferences.isDeliveryEnabled(for: category) else { return }
        authorizationLock.lock()
        let shouldRequest = !requestedAuthorization
        requestedAuthorization = true
        authorizationLock.unlock()

        guard shouldRequest else { return }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func deliver(_ notification: CompletionNotification) {
        guard NotificationPreferences.isDeliveryEnabled(for: notification.category) else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "lectern-completion-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        Task {
            try? await center.add(request)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
