import Foundation

enum LecternAgentSkill: String, CaseIterable, Hashable, Sendable {
    case transcription = "lectern-transcription"
    case notes = "lectern-notes"

    func bundledURL(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: rawValue
        ) {
            return bundled
        }

        // Keeps command-line regression tools usable from the source tree.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceSkill = sourceRoot
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .appendingPathComponent(rawValue, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: sourceSkill.path) ? sourceSkill : nil
    }

    func instructions(bundle: Bundle = .main) -> String {
        guard let url = bundledURL(bundle: bundle),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallbackInstructions
        }
        return text
    }

    private var fallbackInstructions: String {
        switch self {
        case .transcription:
            return """
            Preserve the complete lecture in source order. Never summarize or add facts. For a mixed English-Hebrew shiur, use English connective prose and standard Hebrew script for recognizable Torah terms, source names, and abbreviations. Preserve uncertainty instead of guessing. Return only the caller's requested transcript format.
            """
        case .notes:
            return """
            Create grounded student notes in source order. Begin with one source-derived # title, use ## topic sections, and choose either a topical bullet outline (**Term:** definition with details nested beneath) or a nested numbered outline for chronological lectures. Put every list item on its own line with a `- ` or `1. ` marker and nest supporting details exactly four spaces under the item they support; outlines normally run two to four levels deep. For a shiur, use English reasoning with standard Hebrew-script Torah terms, source-first items with the pshat nested beneath, explicit Q:/A:/A1:/A2: moves, Case: and נ״מ: labels, separate shitos, and a closing Cash Torah section only when the shiur reaches a bottom line. Do not invent facts, use tables, or force a generic Summary, Overview, Key Takeaways, or Conclusion section. Return only Markdown.
            """
        }
    }
}

/// Prompt templates for study-material generation. The lecture transcript is
/// the baseline artifact for every prompt.
enum Prompts {
    /// Extra rules appended to the transcript-repair prompt for a shiur,
    /// where the speaker code-switches between English and Hebrew and the
    /// speech model misrenders words across the language boundary.
    /// Shared heads-up for notes / flashcards / quiz generation from a shiur
    /// transcript.
    private static func shiurStudySection(_ language: LectureLanguage) -> String {
        guard language == .hebrewEnglish else { return "" }
        return """

        This lecture is a shiur that mixes English with Hebrew and Aramaic. Silently repair clear cross-language recognition errors. Use compact English reasoning with standard Hebrew script for recognizable Torah terms and source abbreviations. Do not add ניקוד or translate every Hebrew term in parentheses.
        """
    }

    static func cleanedTranscript(
        rawTranscript: String,
        language: LectureLanguage = .english,
        skillInstructions: String = LecternAgentSkill.transcription.instructions()
    ) -> String {
        let branch = language == .hebrewEnglish ? "English-Hebrew shiur" : "English lecture"
        return """
        Follow the transcription contract below in transcript cleanup mode.

        <transcription-contract>
        \(skillInstructions)
        </transcription-contract>

        <task>
        Mode: transcript cleanup.
        Language branch: \(branch).
        Return only the complete cleaned Markdown transcript.
        </task>

        <raw-transcript>
        \(rawTranscript)
        </raw-transcript>
        """
    }

    /// Optional extra direction from the student (focus areas, question
    /// style, what to emphasize). Returns an empty string when unset.
    static func focusSection(_ focus: String?) -> String {
        guard let focus else { return "" }
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """

        Additional direction from the student (follow it closely; it wins over any rule it conflicts with):
        \(trimmed)
        """
    }

    static func notes(
        cleanedTranscript: String,
        language: LectureLanguage = .english,
        skillInstructions: String = LecternAgentSkill.notes.instructions()
    ) -> String {
        let branch = language == .hebrewEnglish ? "English-Hebrew shiur" : "English lecture"
        return """
        Follow this notes contract exactly:

        <notes-contract>
        \(skillInstructions)
        </notes-contract>

        <task>
        Language branch: \(branch).
        Create the complete notes now and return only the final Markdown document.
        </task>

        <lecture-source>
        \(cleanedTranscript)
        </lecture-source>
        """
    }

    static func antigravityNotesRequest(language: LectureLanguage) -> String {
        let branch = language == .hebrewEnglish ? "English-Hebrew shiur" : "English lecture"
        return """
        Apply the lectern-notes skill to @lecture-source.md.

        Language branch: \(branch).
        Treat @lecture-source.md together with any explicitly named supplementary reference files as the complete source boundary.
        Return only the final Markdown notes document.
        """
    }

    static func notesRepair(violations: [String]) -> String {
        """
        Revise your previous notes response so it follows the Lectern notes contract already supplied. Preserve all grounded content and its source order while fixing these format failures:

        \(violations.map { "- \($0)" }.joined(separator: "\n"))

        Return only the complete repaired Markdown document.
        """
    }

    static func antigravityNotesRepair(violations: [String], language: LectureLanguage) -> String {
        let branch = language == .hebrewEnglish ? "English-Hebrew shiur" : "English lecture"
        return """
        Apply the lectern-notes skill to repair @draft-notes.md against @lecture-source.md.

        Language branch: \(branch).
        Use any explicitly named supplementary reference files to resolve uncertain terminology without inventing content.
        Preserve every grounded point and its source order while fixing these failures:
        \(violations.map { "- \($0)" }.joined(separator: "\n"))

        Return only the complete repaired Markdown document.
        """
    }

    static func flashcards(cleanedTranscript: String, language: LectureLanguage = .english) -> String {
        """
        You are creating Anki flashcards from a lecture transcript.
        \(shiurStudySection(language))
        Rules:
        - Produce 12-20 cards covering every key concept, definition, mechanism, and example from the lecture.
        - Atomic: one fact per card. Front is a specific question (never yes/no); back is a concise self-sufficient answer.
        - Use the lecture's terminology exactly. Do not invent content that was not covered or implied.
        - Output STRICT JSON only: an array of objects with keys "front" and "back" (both strings). No markdown fences, no commentary.

        Transcript:

        \(cleanedTranscript)
        """
    }

    static func quiz(cleanedTranscript: String, options: QuizOptions, focus: String? = nil, language: LectureLanguage = .english) -> String {
        let shape: String
        switch options.format {
        case .mixed:
            shape = "Roughly half multiple-choice and half short-answer questions."
        case .multipleChoice:
            shape = "All questions must be multiple-choice with exactly 4 options."
        case .shortAnswer:
            shape = "All questions must be short-answer (no options array)."
        }

        return """
        You are writing a practice quiz from a lecture transcript.
        \(focusSection(focus))
        \(shiurStudySection(language))
        Rules:
        - Produce exactly \(options.length.rawValue) questions. \(shape)
        - Spread the questions across the entire lecture so every major topic is tested.
        - Target real understanding — mechanisms, relationships, application, and why — rather than verbatim recall.
        - Multiple-choice items: exactly 4 options, one unambiguously correct; distractors reflect common misconceptions.
        - Short-answer items: the answer is one concise, self-sufficient sentence.
        - Every question includes a one-sentence explanation of why its answer is correct.
        - Use the lecture's terminology exactly and stay within its content.

        Output STRICT JSON only — an array of objects:
        [{"kind": "multipleChoice", "prompt": "...", "options": ["...","...","...","..."], "answer": "<exact option text>", "explanation": "..."},
         {"kind": "shortAnswer", "prompt": "...", "answer": "...", "explanation": "..."}]
        No markdown fences, no commentary.

        Transcript:

        \(cleanedTranscript)
        """
    }

    /// Extracts a JSON array from model output, tolerating markdown fences
    /// and surrounding prose.
    static func extractJSONArray(from output: String) -> Data? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        let firstBracket = text.firstIndex(of: "[")
        let lastBracket = text.lastIndex(of: "]")
        if let start = firstBracket, let end = lastBracket, start < end {
            text = String(text[start...end])
        }

        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        return Data(text.utf8)
    }
}

struct NotesOutputValidator {
    static func violations(
        in markdown: String,
        source: String,
        language: LectureLanguage
    ) -> [String] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["The notes are empty."] }

        let lines = trimmed.components(separatedBy: .newlines)
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var failures: [String] = []

        if nonempty.first?.hasPrefix("# ") != true {
            failures.append("Begin directly with one source-derived # title, with no preamble or wrapper fence.")
        }

        let h1Count = nonempty.filter { $0.hasPrefix("# ") }.count
        if h1Count != 1 {
            failures.append("Use exactly one # title; the draft has \(h1Count).")
        }
        if !nonempty.contains(where: { $0.hasPrefix("## ") }) {
            failures.append("Add ## sections for the lecture's actual topics or sugyos.")
        }

        let outline = listItems(in: lines)
        if outline.isEmpty {
            failures.append("Use a structured bullet or numbered outline beneath the headings.")
        } else if outline.count >= flatOutlineThreshold, !outline.contains(where: { $0.depth > 0 }) {
            failures.append("Nest supporting details, examples, and answers beneath the bullet they support using four-space indentation; every bullet in the draft sits at the top level.")
        }

        let strayFences = nonempty.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("```") && !trimmed.hasPrefix("```mermaid")
        }
        // A mermaid block opens with ```mermaid and closes with a bare ```.
        let mermaidOpeners = nonempty.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```mermaid") }.count
        if strayFences.count > mermaidOpeners {
            failures.append("Do not wrap the notes or any section in a code fence; the only fenced block allowed is a single mermaid diagram.")
        }

        let genericHeadings: Set<String> = [
            "lecture notes", "notes", "overview", "main ideas", "key takeaways",
            "summary", "conclusion",
        ]
        let usedGeneric = nonempty.contains { line in
            guard line.hasPrefix("#") else { return false }
            let title = line.drop(while: { $0 == "#" || $0.isWhitespace })
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return genericHeadings.contains(title)
        }
        if usedGeneric {
            failures.append("Replace generic headings with titles derived from the subject; do not force a Summary or Key Takeaways section.")
        }

        let minimumLength = min(800, max(250, source.count / 20))
        if source.count > 2_000, trimmed.count < minimumLength {
            failures.append("The draft is too sparse for the supplied lecture; restore the developed arguments, examples, and distinctions.")
        }

        if language == .hebrewEnglish,
           sourceSuggestsHebrew(source),
           !containsHebrew(trimmed) {
            failures.append("Use standard Hebrew script for the shiur's recognizable Torah terms and source names.")
        }

        return failures
    }

    /// A real lecture outline of this many bullets with no nesting at all is a
    /// formatting failure rather than a short lecture.
    static let flatOutlineThreshold = 12

    private static func listItems(in lines: [String]) -> [NotesListLine] {
        var scanner = NotesListScanner()
        var inFence = false
        var items: [NotesListLine] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            if let item = scanner.scan(line) { items.append(item) }
        }
        return items
    }

    private static func sourceSuggestsHebrew(_ source: String) -> Bool {
        if containsHebrew(source) { return true }
        let lower = source.lowercased()
        let terms = ["gemara", "rashi", "tosaf", "migo", "shevu", "chazaka", "eidim", "sugya", "halacha", "ramban"]
        return terms.contains(where: lower.contains)
    }

    private static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x05FF).contains(Int($0.value)) }
    }
}
