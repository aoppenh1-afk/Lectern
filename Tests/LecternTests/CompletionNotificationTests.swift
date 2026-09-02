import Testing

struct CompletionNotificationTests {
    @Test func transcriptionNotificationNamesTheLecture() {
        let notification = CompletionNotification.transcriptionFinished(lectureTitle: "Berakhot 2a")

        #expect(notification.title == "Transcription complete")
        #expect(notification.body == "\"Berakhot 2a\" is ready to review.")
    }

    @Test func generationNotificationListsCompletedItems() {
        let notification = CompletionNotification.generationFinished(
            lectureTitle: "Berakhot 2a",
            items: ["Notes", "Flashcards"]
        )

        #expect(notification.title == "Generation complete")
        #expect(notification.body == "Finished generating Notes and Flashcards for \"Berakhot 2a\".")
    }
}
