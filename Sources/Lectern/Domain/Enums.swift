import Foundation

/// Spoken language of a lecture. Automatic on-device transcription uses
/// Parakeet for English and whisper.cpp for mixed Hebrew/English shiurim.
/// An explicit Settings choice such as Gemini through Antigravity overrides that.
enum LectureLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english
    case hebrewEnglish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .hebrewEnglish: return "English + Hebrew"
        }
    }

    var caption: String {
        switch self {
        case .english:
            return "English-only lectures. Automatic on-device transcription uses Parakeet."
        case .hebrewEnglish:
            return "Shiurim that mix English and Hebrew. Automatic on-device transcription uses whisper.cpp."
        }
    }
}

enum LectureStatus: String, Codable {
    case recording
    case recorded
    case transcribing
    case ready
    case failed
}

enum ArtifactKind: String, Codable {
    case rawTranscript
    case cleanedTranscript
    case notes
    case quiz
}

enum AnkiSyncState: String, Codable {
    case pending
    case pushed
    case failed
}

enum QuizQuestionKind: String, Codable {
    case multipleChoice
    case shortAnswer
}

extension ArtifactKind {
    var title: String {
        switch self {
        case .rawTranscript: return "Raw Transcript"
        case .cleanedTranscript: return "Cleaned Transcript"
        case .notes: return "Notes"
        case .quiz: return "Quiz"
        }
    }
}

/// How hard the study agent should think during generation. Maps onto ACP
/// session modes when the agent supports them, and is always echoed in the
/// prompt as a reasoning-effort hint.
enum ThinkingLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }

    static func advertised(_ value: String) -> ThinkingLevel? {
        ThinkingLevel(rawValue: value.lowercased())
    }

    static let generationDefaults: [ThinkingLevel] = [.minimal, .low, .medium, .high]

    static func chatOptions(profileID: String?, advertised: [ThinkingLevel]) -> [ThinkingLevel] {
        if !advertised.isEmpty { return advertised }
        switch profileID {
        case "opencode": return generationDefaults
        case "antigravity": return [.low, .medium, .high]
        default: return []
        }
    }
}

/// What a generation run should produce. Distinct from ArtifactKind because
/// flashcards live in their own table rather than as artifact content.
enum GenerationJobKind: String, Codable, CaseIterable, Sendable {
    case cleanedTranscript
    case notes
    case flashcards
    case quiz

    var title: String {
        switch self {
        case .cleanedTranscript: return "Cleaned Transcript"
        case .notes: return "Notes"
        case .flashcards: return "Flashcards"
        case .quiz: return "Quiz"
        }
    }

    /// Deterministic run order.
    static let ordered: [GenerationJobKind] = [.cleanedTranscript, .notes, .flashcards, .quiz]
}

/// User-chosen quiz shape for generation.
struct QuizOptions: Hashable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case mixed
        case multipleChoice
        case shortAnswer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mixed: return "Mixed"
            case .multipleChoice: return "Multiple choice"
            case .shortAnswer: return "Short answer"
            }
        }
    }

    enum Length: Int, CaseIterable, Identifiable, Sendable {
        case short_ = 5
        case standard = 10
        case long = 15
        case marathon = 20

        var id: Int { rawValue }

        var title: String { "\(rawValue) questions" }
    }

    var format: Format = .mixed
    var length: Length = .standard
}
