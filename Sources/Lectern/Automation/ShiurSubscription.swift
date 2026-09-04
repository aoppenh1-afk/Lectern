import Foundation
import SwiftData

enum ShiurSubscriptionTargetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case teacher
    case series
    case collection
    case rss

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .teacher: return "Teacher"
        case .series: return "Series"
        case .collection: return "Collection"
        case .rss: return "Custom Feed"
        }
    }
}

enum ShiurSubscriptionCadence: Int, Codable, CaseIterable, Identifiable, Sendable {
    case everyHour = 1
    case every2Hours = 2
    case every4Hours = 4
    case every6Hours = 6
    case every12Hours = 12
    case daily = 24
    case every2Days = 48
    case weekly = 168

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .everyHour: return "Every hour"
        case .every2Hours: return "Every 2 hours"
        case .every4Hours: return "Every 4 hours"
        case .every6Hours: return "Every 6 hours"
        case .every12Hours: return "Every 12 hours"
        case .daily: return "Daily (24 hours)"
        case .every2Days: return "Every 2 days (48 hours)"
        case .weekly: return "Weekly (7 days)"
        }
    }
}

@Model
final class ShiurSubscription {
    var id: UUID
    var providerRaw: String
    var targetTypeRaw: String
    var targetNumericID: Int?
    var originalURL: String?
    var resolvedFeedURLString: String
    var displayName: String
    var isEnabled: Bool
    var intervalHours: Int
    var course: Course?
    private var languageRaw: String
    var autoTranscribe: Bool
    var autoGenerateNotes: Bool
    var createdAt: Date
    var lastCheckedAt: Date?
    var lastSuccessfulCheckAt: Date?
    var lastImportedAt: Date?
    var lastImportedTitle: String?
    var importedCount: Int
    var eTag: String?
    var lastModified: String?
    var lastError: String?
    var seenItemIDsData: Data

    init(
        id: UUID = UUID(),
        providerRaw: String = "yutorah",
        targetType: ShiurSubscriptionTargetType = .teacher,
        targetNumericID: Int? = nil,
        originalURL: String? = nil,
        resolvedFeedURLString: String,
        displayName: String,
        isEnabled: Bool = true,
        intervalHours: Int = 24,
        course: Course? = nil,
        language: LectureLanguage = .hebrewEnglish,
        autoTranscribe: Bool = true,
        autoGenerateNotes: Bool = true,
        createdAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        lastSuccessfulCheckAt: Date? = nil,
        lastImportedAt: Date? = nil,
        lastImportedTitle: String? = nil,
        importedCount: Int = 0,
        eTag: String? = nil,
        lastModified: String? = nil,
        lastError: String? = nil,
        seenItemIDs: Set<String> = []
    ) {
        self.id = id
        self.providerRaw = providerRaw
        self.targetTypeRaw = targetType.rawValue
        self.targetNumericID = targetNumericID
        self.originalURL = originalURL
        self.resolvedFeedURLString = resolvedFeedURLString
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.intervalHours = intervalHours
        self.course = course
        self.languageRaw = language.rawValue
        self.autoTranscribe = autoTranscribe
        self.autoGenerateNotes = autoGenerateNotes
        self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.lastImportedAt = lastImportedAt
        self.lastImportedTitle = lastImportedTitle
        self.importedCount = importedCount
        self.eTag = eTag
        self.lastModified = lastModified
        self.lastError = lastError
        self.seenItemIDsData = (try? JSONEncoder().encode(Array(seenItemIDs))) ?? Data()
    }

    var targetType: ShiurSubscriptionTargetType {
        get { ShiurSubscriptionTargetType(rawValue: targetTypeRaw) ?? .teacher }
        set { targetTypeRaw = newValue.rawValue }
    }

    var cadence: ShiurSubscriptionCadence {
        get { ShiurSubscriptionCadence(rawValue: intervalHours) ?? .daily }
        set { intervalHours = newValue.rawValue }
    }

    var language: LectureLanguage {
        get { LectureLanguage(rawValue: languageRaw) ?? .hebrewEnglish }
        set { languageRaw = newValue.rawValue }
    }

    var resolvedFeedURL: URL? {
        URL(string: resolvedFeedURLString)
    }

    var nextCheckDate: Date {
        guard let lastCheckedAt else { return Date.distantPast }
        return lastCheckedAt.addingTimeInterval(Double(intervalHours) * 3600.0)
    }

    func isDue(at referenceDate: Date = Date()) -> Bool {
        guard isEnabled else { return false }
        guard let lastCheckedAt else { return true }
        return referenceDate >= lastCheckedAt.addingTimeInterval(Double(intervalHours) * 3600.0)
    }

    var needsAttention: Bool {
        lastError != nil
    }

    private var seenIDsList: [String] {
        get {
            guard !seenItemIDsData.isEmpty,
                  let decoded = try? JSONDecoder().decode([String].self, from: seenItemIDsData) else {
                return []
            }
            return decoded
        }
        set {
            let bounded: [String]
            if newValue.count > 1000 {
                bounded = Array(newValue.suffix(1000))
            } else {
                bounded = newValue
            }
            seenItemIDsData = (try? JSONEncoder().encode(bounded)) ?? Data()
        }
    }

    var seenItemIDs: Set<String> {
        get {
            Set(seenIDsList)
        }
        set {
            var list = seenIDsList
            var set = Set(list)
            for item in newValue where !set.contains(item) {
                list.append(item)
                set.insert(item)
            }
            seenIDsList = list
        }
    }

    func markSeen(itemIDs: [String]) {
        var list = seenIDsList
        var set = Set(list)
        for id in itemIDs where !set.contains(id) {
            list.append(id)
            set.insert(id)
        }
        seenIDsList = list
    }

    func hasSeen(itemID: String) -> Bool {
        seenItemIDs.contains(itemID)
    }
}

extension ShiurSubscription: Identifiable, Hashable {
    static func == (lhs: ShiurSubscription, rhs: ShiurSubscription) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
