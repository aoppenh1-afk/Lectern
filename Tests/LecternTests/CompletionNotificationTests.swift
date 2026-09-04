import Foundation
import Testing

struct CompletionNotificationTests {
    @Test func transcriptionNotificationNamesTheLecture() {
        let notification = CompletionNotification.transcriptionFinished(lectureTitle: "Berakhot 2a")

        #expect(notification.category == .transcription)
        #expect(notification.title == "Transcription complete")
        #expect(notification.body == "\"Berakhot 2a\" is ready to review.")
    }

    @Test func generationNotificationListsCompletedItems() {
        let notification = CompletionNotification.generationFinished(
            lectureTitle: "Berakhot 2a",
            items: ["Notes", "Flashcards"]
        )

        #expect(notification.category == .generation)
        #expect(notification.title == "Generation complete")
        #expect(notification.body == "Finished generating Notes and Flashcards for \"Berakhot 2a\".")
    }

    @Test func deliveryPreferencesDefaultToEnabledAndPersist() {
        let suiteName = "CompletionNotificationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NotificationPreferences.isDeliveryEnabled(for: .transcription, userDefaults: defaults))
        #expect(NotificationPreferences.isDeliveryEnabled(for: .generation, userDefaults: defaults))

        defaults.set(false, forKey: NotificationPreferences.generationKey)

        #expect(NotificationPreferences.isDeliveryEnabled(for: .transcription, userDefaults: defaults))
        #expect(!NotificationPreferences.isDeliveryEnabled(for: .generation, userDefaults: defaults))

        defaults.set(false, forKey: NotificationPreferences.enabledKey)

        #expect(!NotificationPreferences.isDeliveryEnabled(for: .transcription, userDefaults: defaults))
        #expect(!NotificationPreferences.isDeliveryEnabled(for: .generation, userDefaults: defaults))
    }
}
