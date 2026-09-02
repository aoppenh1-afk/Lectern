import Foundation
import UserNotifications

struct CompletionNotification: Equatable, Sendable {
    let title: String
    let body: String

    static func transcriptionFinished(lectureTitle: String) -> Self {
        Self(
            title: "Transcription complete",
            body: "\"\(lectureTitle)\" is ready to review."
        )
    }

    static func generationFinished(lectureTitle: String, items: [String]) -> Self {
        let itemList = items.formatted(.list(type: .and))
        return Self(
            title: "Generation complete",
            body: "Finished generating \(itemList) for \"\(lectureTitle)\"."
        )
    }
}

protocol CompletionNotifying: AnyObject {
    func prepare()
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

    func prepare() {
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
