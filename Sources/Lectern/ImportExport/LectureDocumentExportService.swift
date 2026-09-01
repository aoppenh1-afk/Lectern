import Foundation

enum LectureDocumentExportService {
    @MainActor
    static func export(_ lecture: Lecture,
                       to destination: URL,
                       format: LectureShareFormat,
                       options: LecternBundleOptions) throws {
        let availableOptions = LectureExportAvailability(lecture: lecture).normalized(options)
        let markdown = documentMarkdown(for: lecture, options: availableOptions)
        try LectureDocumentRenderer.write(markdown: markdown, to: destination, format: format)
    }

    @MainActor
    static func documentMarkdown(for lecture: Lecture, options: LecternBundleOptions) -> String {
        var sections: [String] = [
            "# \(lecture.title)",
            metadata(for: lecture),
        ]

        if options.includeTranscript {
            if let cleaned = lecture.artifact(of: .cleanedTranscript)?.content,
               !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("## Cleaned transcript\n\n\(cleaned)")
            } else if let raw = lecture.artifact(of: .rawTranscript)?.content,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("## Transcript\n\n\(raw)")
            }
        }

        if options.includeNotes,
           let notes = lecture.artifact(of: .notes)?.content,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## Notes\n\n\(notes)")
        }

        if options.includeFlashcards, !lecture.flashcards.isEmpty {
            let cards = lecture.flashcards.enumerated().map { index, card in
                "### Card \(index + 1)\n\n**Front:** \(card.front)\n\n**Back:** \(card.back)"
            }.joined(separator: "\n\n")
            sections.append("## Flashcards\n\n\(cards)")
        }

        if options.includeQuiz, !lecture.quizSets.isEmpty {
            let quiz = lecture.quizSets.flatMap(\.items).enumerated().map { index, item in
                var block = "### Question \(index + 1)\n\n\(item.prompt)"
                if let choices = item.options, !choices.isEmpty {
                    block += "\n\n" + choices.map { "- \($0)" }.joined(separator: "\n")
                }
                block += "\n\n**Answer:** \(item.answer)"
                if !item.explanation.isEmpty { block += "\n\n**Explanation:** \(item.explanation)" }
                return block
            }.joined(separator: "\n\n")
            sections.append("## Quiz\n\n\(quiz)")
        }

        if options.includeBookmarks, !lecture.orderedBookmarks.isEmpty {
            let bookmarks = lecture.orderedBookmarks.map { bookmark in
                let label = bookmark.isExamAlert ? "Exam alert" : "Bookmark"
                let note = bookmark.note.isEmpty ? label : "\(label): \(bookmark.note)"
                return "- [\(timeLabel(bookmark.offset))] \(note)"
            }.joined(separator: "\n")
            sections.append("## Bookmarks\n\n\(bookmarks)")
        }

        if options.includeReferenceFiles, !lecture.attachments.isEmpty {
            let references = lecture.attachments.map { "- \($0.name)" }.joined(separator: "\n")
            sections.append("## Attached reference files\n\n\(references)")
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    @MainActor
    private static func metadata(for lecture: Lecture) -> String {
        var values = [lecture.capturedAt.formatted(date: .long, time: .shortened)]
        if let course = lecture.course?.name { values.insert(course, at: 0) }
        if lecture.duration > 0 {
            values.append(Duration.seconds(lecture.duration).formatted(.time(pattern: .hourMinuteSecond)))
        }
        return values.joined(separator: " | ")
    }

    private static func timeLabel(_ interval: TimeInterval) -> String {
        let value = max(0, Int(interval))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
