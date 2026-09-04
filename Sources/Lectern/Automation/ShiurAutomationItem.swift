import Foundation
import SwiftData

enum ShiurAutomationState: String, Codable, CaseIterable, Identifiable, Sendable {
    case discovered
    case downloading
    case imported
    case waitingForTranscription
    case transcribing
    case waitingForNotes
    case generatingNotes
    case complete
    case paused
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .discovered: return "Discovered"
        case .downloading: return "Downloading audio"
        case .imported: return "Audio imported"
        case .waitingForTranscription: return "Queued for transcription"
        case .transcribing: return "Transcribing"
        case .waitingForNotes: return "Queued for Notes"
        case .generatingNotes: return "Generating Notes"
        case .complete: return "Complete"
        case .paused: return "Paused"
        case .failed: return "Needs attention"
        }
    }

    var isTerminal: Bool {
        self == .complete
    }

    var isRunning: Bool {
        self == .downloading || self == .transcribing || self == .generatingNotes
    }
}

@Model
final class ShiurAutomationItem {
    var id: UUID
    var sourceKey: String
    var shiurID: String
    var subscriptionID: UUID?
    var title: String
    var teacherName: String?
    var seriesName: String?
    var publicationDate: Date
    var pageURLString: String?
    var mediaURLString: String?
    var duration: TimeInterval?
    var stateRaw: String
    var stateMessage: String?
    var lecturePersistentIDData: Data?
    var targetCourseIDData: Data?
    private var languageRaw: String
    var autoTranscribe: Bool
    var autoGenerateNotes: Bool
    var downloadAttempts: Int
    var lastAttemptAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceKey: String,
        shiurID: String,
        subscriptionID: UUID? = nil,
        title: String,
        teacherName: String? = nil,
        seriesName: String? = nil,
        publicationDate: Date = Date(),
        pageURLString: String? = nil,
        mediaURLString: String? = nil,
        duration: TimeInterval? = nil,
        state: ShiurAutomationState = .discovered,
        stateMessage: String? = nil,
        lecturePersistentIDData: Data? = nil,
        targetCourseIDData: Data? = nil,
        language: LectureLanguage = .hebrewEnglish,
        autoTranscribe: Bool = true,
        autoGenerateNotes: Bool = true,
        downloadAttempts: Int = 0,
        lastAttemptAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.shiurID = shiurID
        self.subscriptionID = subscriptionID
        self.title = title
        self.teacherName = teacherName
        self.seriesName = seriesName
        self.publicationDate = publicationDate
        self.pageURLString = pageURLString
        self.mediaURLString = mediaURLString
        self.duration = duration
        self.stateRaw = state.rawValue
        self.stateMessage = stateMessage
        self.lecturePersistentIDData = lecturePersistentIDData
        self.targetCourseIDData = targetCourseIDData
        self.languageRaw = language.rawValue
        self.autoTranscribe = autoTranscribe
        self.autoGenerateNotes = autoGenerateNotes
        self.downloadAttempts = downloadAttempts
        self.lastAttemptAt = lastAttemptAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var state: ShiurAutomationState {
        get { ShiurAutomationState(rawValue: stateRaw) ?? .discovered }
        set {
            stateRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var language: LectureLanguage {
        get { LectureLanguage(rawValue: languageRaw) ?? .hebrewEnglish }
        set { languageRaw = newValue.rawValue }
    }

    var pageURL: URL? {
        pageURLString.flatMap(URL.init(string:))
    }

    var mediaURL: URL? {
        mediaURLString.flatMap(URL.init(string:))
    }
}

extension ShiurAutomationItem: Identifiable, Hashable {
    static func == (lhs: ShiurAutomationItem, rhs: ShiurAutomationItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
