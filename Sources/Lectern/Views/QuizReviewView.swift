import Observation
import SwiftUI

/// Interactive self-test over a lecture's generated quizzes.
struct QuizReviewView: View {
    let lecture: Lecture

    @Environment(\.modelContext) private var modelContext
    @State private var session: QuizSession?
    @State private var exportTarget: QuizSet?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let activeSession = session {
                QuizSessionView(session: activeSession) {
                    self.session = QuizSession(questions: activeSession.questions)
                }
            } else {
                quizList
            }
        }
        .alert("Export quiz to Desktop?",
               isPresented: Binding(get: { exportTarget != nil },
                                    set: { if !$0 { exportTarget = nil } }),
               presenting: exportTarget) { set in
            Button("Export") {
                QuizExport.exportToDesktop(title: lecture.title, items: set.items)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var quizList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Quiz")

            let sets = lecture.quizSets
            if sets.isEmpty {
                Text("No quizzes yet — generate one from the sparkles toolbar button.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            ForEach(sets) { set in
                quizRow(set)
            }
        }
    }

    private func quizRow(_ set: QuizSet) -> some View {
        SurfaceCard(padding: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LecternTheme.ink)
                    Text("\(set.items.count) questions · \(Self.formatBreakdown(set.items))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button("Review") {
                    session = QuizSession(questions: set.items)
                }
                .controlSize(.small)

                Button {
                    exportTarget = set
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    deleteQuiz(set)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    private func deleteQuiz(_ set: QuizSet) {
        for item in set.items {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    static func formatBreakdown(_ items: [QuizItem]) -> String {
        let mcq = items.filter { $0.kind == .multipleChoice }.count
        let short = items.count - mcq
        var parts: [String] = []
        if mcq > 0 { parts.append("\(mcq) MCQ") }
        if short > 0 { parts.append("\(short) short answer") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Session state

@Observable
final class QuizSession {
    let questions: [QuizItem]
    private(set) var index = 0
    private(set) var score = 0
    private(set) var isFinished = false

    private(set) var selectedOption: String?
    var typedAnswer = ""
    private(set) var revealedCurrent = false
    private(set) var correctCurrent: Bool?

    init(questions: [QuizItem]) {
        self.questions = questions
    }

    var current: QuizItem? {
        guard !isFinished, index < questions.count else { return nil }
        return questions[index]
    }

    func select(option: String) {
        guard !revealedCurrent else { return }
        selectedOption = option
    }

    func reveal() {
        guard !revealedCurrent, let question = current else { return }

        switch question.kind {
        case .multipleChoice:
            guard let selectedOption else { return }
            correctCurrent = selectedOption == question.answer
        case .shortAnswer:
            correctCurrent = Self.matchesKeywords(answer: question.answer, user: typedAnswer)
        }

        revealedCurrent = true
        if correctCurrent == true { score += 1 }
    }

    /// Override for either direction; adjusts the score accordingly.
    func gradeManually(correct: Bool) {
        guard revealedCurrent else { return }
        if correctCurrent == true && !correct { score -= 1 }
        if correctCurrent != true && correct { score += 1 }
        correctCurrent = correct
    }

    // MARK: Keyword grading

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "by",
        "for", "with", "from", "as", "is", "are", "was", "were", "be", "been",
        "being", "it", "its", "this", "that", "these", "those", "they", "them",
        "their", "there", "which", "who", "what", "when", "how", "why", "can",
        "could", "will", "would", "should", "do", "does", "did", "not", "into",
        "than", "then", "also", "because", "so", "such", "has", "have", "had",
    ]

    private static func keywords(in text: String) -> [String] {
        normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }

    /// True when the words share a stem — catches plurals and tense variants.
    private static func shareStem(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let commonPrefix = zip(lhs, rhs).prefix { $0.0 == $0.1 }.count
        if commonPrefix >= 4 { return true }
        return min(lhs.count, rhs.count) <= 3 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    /// Auto-grading for written answers: enough of the model answer's keywords
    /// appear in the user's answer (half or more), word forms may differ.
    static func matchesKeywords(answer: String, user: String) -> Bool {
        let expected = keywords(in: answer)
        guard !expected.isEmpty else {
            return normalized(user) == normalized(answer)
        }
        let given = Set(keywords(in: user))
        let matched = expected.filter { word in
            given.contains { shareStem(word, $0) }
        }
        return Double(matched.count) / Double(expected.count) >= 0.5
    }

    func next() {
        guard index + 1 < questions.count else {
            isFinished = true
            return
        }
        index += 1
        selectedOption = nil
        typedAnswer = ""
        revealedCurrent = false
        correctCurrent = nil
    }

    static func normalized(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
    }
}

// MARK: - Session view

private struct QuizSessionView: View {
    @Bindable var session: QuizSession
    let onRestart: () -> Void

    var body: some View {
        Group {
            if session.isFinished {
                finishedCard
            } else if let question = session.current {
                questionCard(question)
            }
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Question \(session.index + 1) of \(session.questions.count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Spacer()
                Text("Score \(session.score)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(LecternTheme.accent)
                        .frame(width: max(2, geo.size.width * Double(session.index) / Double(max(session.questions.count, 1))))
                }
            }
            .frame(height: 3)
        }
    }

    private func questionCard(_ question: QuizItem) -> some View {
        SurfaceCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                progressHeader

                Text(question.prompt)
                    .font(.system(size: 16, weight: .medium))
                    .lineSpacing(3)
                    .textSelection(.enabled)

                switch question.kind {
                case .multipleChoice:
                    optionList(question)
                case .shortAnswer:
                    shortAnswerField(question)
                }

                if session.revealedCurrent {
                    verdict(question)
                        .transition(.opacity)
                }

                HStack {
                    Spacer()
                    if !session.revealedCurrent {
                        Button(question.kind == .multipleChoice ? "Check Answer" : "Reveal Answer") {
                            withAnimation(LecternTheme.standardAnimation) { session.reveal() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .prominentAction()
                        .tint(LecternTheme.accent)
                        .disabled(revealDisabled(for: question))
                    } else {
                        Button(session.index + 1 == session.questions.count ? "Finish" : "Next Question") {
                            withAnimation(LecternTheme.standardAnimation) { session.next() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .prominentAction()
                        .tint(LecternTheme.accent)
                    }
                }
            }
        }
    }

    private func optionList(_ question: QuizItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.options ?? [], id: \.self) { option in
                let isSelected = session.selectedOption == option
                let isAnswer = session.revealedCurrent && option == question.answer
                let isWrongPick = session.revealedCurrent && isSelected && option != question.answer

                Button {
                    session.select(option: option)
                } label: {
                    HStack(spacing: 10) {
                        Text(option)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        if isAnswer {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LecternTheme.successTint)
                        } else if isWrongPick {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(LecternTheme.recordTint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        highlight(isAnswer: isAnswer, isWrongPick: isWrongPick, isSelected: isSelected),
                        in: RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous)
                            .strokeBorder(optionBorder(isAnswer: isAnswer, isWrongPick: isWrongPick, isSelected: isSelected),
                                          lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: LecternTheme.controlRadius))
                }
                .buttonStyle(.plain)
                .disabled(session.revealedCurrent && !isAnswer)
            }
        }
    }

    private func highlight(isAnswer: Bool, isWrongPick: Bool, isSelected: Bool) -> Color {
        if isAnswer { return LecternTheme.successTint.opacity(0.12) }
        if isWrongPick { return LecternTheme.recordTint.opacity(0.10) }
        if isSelected { return LecternTheme.accent.opacity(0.09) }
        return Color.primary.opacity(0.04)
    }

    private func optionBorder(isAnswer: Bool, isWrongPick: Bool, isSelected: Bool) -> Color {
        if isAnswer { return LecternTheme.successTint.opacity(0.45) }
        if isWrongPick { return LecternTheme.recordTint.opacity(0.40) }
        if isSelected { return LecternTheme.accent.opacity(0.45) }
        return LecternTheme.hairline
    }

    private func shortAnswerField(_ question: QuizItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Type your answer…", text: $session.typedAnswer)
                .textFieldStyle(.roundedBorder)
                .disabled(session.revealedCurrent)

            if session.revealedCurrent {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "Model answer")
                    Text(question.answer)
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Text(session.correctCurrent == true
                             ? "Auto-checked by keyword match — override if needed:"
                             : "Not a keyword match — override if needed:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("I got it") { session.gradeManually(correct: true) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(session.correctCurrent == true)
                        Button("Missed it") { session.gradeManually(correct: false) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(session.correctCurrent == false)
                    }
                    .padding(.top, 2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LecternTheme.accent.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: LecternTheme.controlRadius, style: .continuous))
            }
        }
    }

    private func verdict(_ question: QuizItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.correctCurrent == true {
                Label("Correct", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LecternTheme.successTint)
            } else if question.kind == .multipleChoice {
                Label("Incorrect", systemImage: "xmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LecternTheme.recordTint)
            }

            if !question.explanation.isEmpty {
                Text(question.explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func revealDisabled(for question: QuizItem) -> Bool {
        question.kind == .multipleChoice && session.selectedOption == nil
    }

    private var finishedCard: some View {
        SurfaceCard(padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "Review complete")

                Text("\(session.score) / \(session.questions.count)")
                    .font(.system(size: 30, weight: .bold).monospacedDigit())

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(ratio >= 0.7 ? LecternTheme.successTint : LecternTheme.warningTint)
                            .frame(width: max(2, geo.size.width * ratio))
                    }
                }
                .frame(height: 4)

                Text(Self.gradeComment(score: session.score, total: session.questions.count))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Button("Restart Review") { onRestart() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var ratio: Double {
        guard session.questions.count > 0 else { return 0 }
        return Double(session.score) / Double(session.questions.count)
    }

    private static func gradeComment(score: Int, total: Int) -> String {
        guard total > 0 else { return "" }
        let ratio = Double(score) / Double(total)
        if ratio >= 0.9 { return "Exam-ready." }
        if ratio >= 0.7 { return "Solid — review the misses and run it again." }
        if ratio >= 0.5 { return "Halfway there. Reread the notes on what you missed." }
        return "Worth another pass through the notes before retrying."
    }
}

// MARK: - Export

enum QuizExport {
    static func markdown(title: String, items: [QuizItem]) -> String {
        let items = items.sorted { $0.createdAt < $1.createdAt }
        var lines = ["# \(title) — Quiz", ""]

        for (index, item) in items.enumerated() {
            lines.append("**\(index + 1). \(item.prompt)**")
            if let options = item.options {
                for (optionIndex, option) in options.enumerated() {
                    lines.append("- \(letter(optionIndex)). \(option)")
                }
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("")
        lines.append("## Answers")
        lines.append("")
        for (index, item) in items.enumerated() {
            var prefix = ""
            if let options = item.options,
               let optionIndex = options.firstIndex(of: item.answer) {
                prefix = "\(letter(optionIndex))) "
            }
            lines.append("**\(index + 1).** \(prefix)\(item.answer)")
            if !item.explanation.isEmpty {
                lines.append("   *\(item.explanation)*")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func exportToDesktop(title: String, items: [QuizItem]) {
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = desktop.appendingPathComponent("\(safeTitle) — Quiz.md")
        do {
            try markdown(title: title, items: items).write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Lectern quiz export failed: \(error)")
        }
    }

    private static func letter(_ index: Int) -> Character {
        Character(UnicodeScalar(65 + index) ?? "?")
    }
}
