import Foundation

struct RemoteShiurItem: Identifiable, Hashable, Codable, Sendable {
    var id: String { shiurID }
    let shiurID: String
    let title: String
    let teacherName: String?
    let seriesName: String?
    let date: Date
    let duration: TimeInterval?
    let pageURL: URL?
    let enclosureURL: URL?
    let enclosureLength: Int64?
    let enclosureType: String?
    let guid: String?
    let itemDescription: String?

    init(
        shiurID: String,
        title: String,
        teacherName: String? = nil,
        seriesName: String? = nil,
        date: Date = Date(),
        duration: TimeInterval? = nil,
        pageURL: URL? = nil,
        enclosureURL: URL? = nil,
        enclosureLength: Int64? = nil,
        enclosureType: String? = nil,
        guid: String? = nil,
        itemDescription: String? = nil
    ) {
        self.shiurID = shiurID
        self.title = title
        self.teacherName = teacherName
        self.seriesName = seriesName
        self.date = date
        self.duration = duration
        self.pageURL = pageURL
        self.enclosureURL = enclosureURL
        self.enclosureLength = enclosureLength
        self.enclosureType = enclosureType
        self.guid = guid
        self.itemDescription = itemDescription
    }

    var sourceKey: String {
        "yutorah:\(shiurID)"
    }
}

enum ShiurDiscoveryResult: Identifiable, Hashable, Sendable {
    case teacher(id: Int, name: String, shiurCount: Int?, previewItems: [RemoteShiurItem])
    case series(id: Int, title: String, teacherName: String?, previewItems: [RemoteShiurItem])
    case collection(id: Int, title: String, description: String?, previewItems: [RemoteShiurItem])
    case shiur(item: RemoteShiurItem)

    var id: String {
        switch self {
        case .teacher(let id, _, _, _):
            return "teacher-\(id)"
        case .series(let id, _, _, _):
            return "series-\(id)"
        case .collection(let id, _, _, _):
            return "collection-\(id)"
        case .shiur(let item):
            return "shiur-\(item.shiurID)"
        }
    }

    var title: String {
        switch self {
        case .teacher(_, let name, _, _): return name
        case .series(_, let title, _, _): return title
        case .collection(_, let title, _, _): return title
        case .shiur(let item): return item.title
        }
    }

    var subtitle: String? {
        switch self {
        case .teacher(_, _, let count, _):
            return count.map { "\($0) shiurim" } ?? "Teacher"
        case .series(_, _, let teacher, _):
            return teacher ?? "Series"
        case .collection(_, _, let desc, _):
            return desc ?? "Collection"
        case .shiur(let item):
            var parts: [String] = []
            if let teacher = item.teacherName { parts.append(teacher) }
            parts.append(item.date.formatted(date: .abbreviated, time: .omitted))
            if let duration = item.duration, duration > 0 {
                let minutes = Int(duration) / 60
                parts.append("\(minutes) min")
            }
            return parts.joined(separator: " · ")
        }
    }

    var previewItems: [RemoteShiurItem] {
        switch self {
        case .teacher(_, _, _, let items): return items
        case .series(_, _, _, let items): return items
        case .collection(_, _, _, let items): return items
        case .shiur(let item): return [item]
        }
    }
}

enum ShiurSubscriptionEntity: Sendable {
    case teacher(id: Int, name: String)
    case series(id: Int, title: String)
    case collection(id: Int, title: String)
    case customFeed(url: URL, title: String)
}

struct ResolvedSubscription: Sendable {
    let targetType: ShiurSubscriptionTargetType
    let targetNumericID: Int?
    let displayName: String
    let originalURL: String?
    let feedURL: URL
    let previewItems: [RemoteShiurItem]
}

enum FeedFetchResult: Sendable {
    case notModified
    case newItems(items: [RemoteShiurItem], channelTitle: String?, eTag: String?, lastModified: String?)
}

enum YUTorahNameFormatter {
    static func format(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.contains(", R' ") {
            let parts = trimmed.components(separatedBy: ", R' ")
            if parts.count == 2 {
                let last = parts[0].trimmingCharacters(in: .whitespaces)
                let first = parts[1].trimmingCharacters(in: .whitespaces)
                return "Rabbi \(first) \(last)"
            }
        }

        if trimmed.contains(", ") {
            let parts = trimmed.components(separatedBy: ", ")
            if parts.count == 2 {
                let last = parts[0].trimmingCharacters(in: .whitespaces)
                let first = parts[1].trimmingCharacters(in: .whitespaces)
                return "\(first) \(last)"
            }
        }

        return trimmed
    }
}

struct YUTorahFacetTeacher: Identifiable, Hashable, Sendable {
    let id: Int
    let rawName: String
    let lastName: String?
    let shiurCount: Int

    var displayName: String {
        YUTorahNameFormatter.format(rawName)
    }
}

struct YUTorahFacetCollection: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let shiurCount: Int
}

struct YUTorahFacetSeries: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let shiurCount: Int
}

struct YUTorahFacetSubcategory: Identifiable, Hashable, Sendable {
    let id: Int
    let categoryName: String
    let subcategoryName: String
    let shiurCount: Int

    var title: String {
        if categoryName.isEmpty || categoryName == subcategoryName {
            return subcategoryName
        }
        return "\(categoryName) · \(subcategoryName)"
    }
}

struct YUTorahSearchResults: Sendable {
    let query: String
    let totalShiurim: Int
    let currentPage: Int
    let totalPages: Int
    let shiurim: [RemoteShiurItem]
    let teachers: [YUTorahFacetTeacher]
    let collections: [YUTorahFacetCollection]
    let series: [YUTorahFacetSeries]
    let subcategories: [YUTorahFacetSubcategory]
    let activeTeacher: YUTorahFacetTeacher?
    let activeSubcategory: YUTorahFacetSubcategory?

    static let empty = YUTorahSearchResults(
        query: "",
        totalShiurim: 0,
        currentPage: 1,
        totalPages: 1,
        shiurim: [],
        teachers: [],
        collections: [],
        series: [],
        subcategories: [],
        activeTeacher: nil,
        activeSubcategory: nil
    )

    var isEmpty: Bool {
        shiurim.isEmpty && teachers.isEmpty && collections.isEmpty && series.isEmpty
    }
}
