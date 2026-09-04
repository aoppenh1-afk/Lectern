import Foundation

enum YUTorahURLType: Equatable, Sendable {
    case teacher(id: Int)
    case series(id: Int)
    case collection(id: Int)
    case shiur(id: String)
    case rssFeed(url: URL)
    case unknown
}

enum YUTorahURLResolver {
    private static let shiurIDRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"/(?:sidebar/)?lecture(?:s|data)?/(?:lecture(?:_iframe)?\.cfm/)?(\d+)(?:/|$|\?)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"[?&]shiurid=(\d+)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"download\.yutorah\.org/(?:\d+/)+(\d+)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"media\.yutorah\.org/.+/(\d+)\.mp3"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"^(\d{5,8})$"#)
    ]

    static func resolve(url: URL) -> YUTorahURLType {
        let string = url.absoluteString

        // 1. Check for direct RSS URL
        if string.localizedCaseInsensitiveContains("/rss/")
            || string.localizedCaseInsensitiveContains("recentaudioshiurim") {
            return .rssFeed(url: url)
        }

        // 2. Check for Shiur ID in URL
        if let shiurID = extractShiurID(from: string) {
            return .shiur(id: shiurID)
        }

        // 3. Check for Collection query parameter or path (takes precedence over teacher in scoped collection URLs)
        if let collectionID = extractCollectionID(from: url) {
            return .collection(id: collectionID)
        }

        // 4. Check for Series query parameter or path
        if let seriesID = extractSeriesID(from: url) {
            return .series(id: seriesID)
        }

        // 5. Check for Teacher query parameter or path
        if let teacherID = extractTeacherID(from: url) {
            return .teacher(id: teacherID)
        }

        return .unknown
    }

    static func extractShiurID(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let unescaped = trimmed.removingPercentEncoding ?? trimmed
        for input in [trimmed, unescaped] {
            for regex in shiurIDRegexes {
                let range = NSRange(input.startIndex..., in: input)
                if let match = regex.firstMatch(in: input, range: range),
                   match.numberOfRanges >= 2,
                   let targetRange = Range(match.range(at: 1), in: input) {
                    return String(input[targetRange])
                }
            }
        }
        return nil
    }

    static func extractTeacherID(from url: URL) -> Int? {
        let string = url.absoluteString
        // Query param checks
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if (name == "teacher" || name == "teacherid"),
                   let value = item.value,
                   let id = Int(value) {
                    return id
                }
            }
        }

        // Path checks like /rss/RssAudioOnly/teacher/81072
        let pathComponents = url.pathComponents
        for (index, component) in pathComponents.enumerated() {
            if component.lowercased() == "teacher",
               index + 1 < pathComponents.count,
               let id = Int(pathComponents[index + 1]) {
                return id
            }
        }

        // Regex check for ?teacher=12345 in unparsed URLs
        if let match = string.range(of: #"[?&]teacher(?:id)?=(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let sub = String(string[match])
            if let digits = sub.components(separatedBy: CharacterSet.decimalDigits.inverted).last(where: { !$0.isEmpty }),
               let id = Int(digits) {
                return id
            }
        }

        return nil
    }

    static func extractSeriesID(from url: URL) -> Int? {
        let string = url.absoluteString
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if (name == "series" || name == "seriesid"),
                   let value = item.value,
                   let id = Int(value) {
                    return id
                }
            }
        }

        let pathComponents = url.pathComponents
        for (index, component) in pathComponents.enumerated() {
            if component.lowercased() == "series",
               index + 1 < pathComponents.count,
               let id = Int(pathComponents[index + 1]) {
                return id
            }
        }

        if let match = string.range(of: #"[?&]series(?:id)?=(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let sub = String(string[match])
            if let digits = sub.components(separatedBy: CharacterSet.decimalDigits.inverted).last(where: { !$0.isEmpty }),
               let id = Int(digits) {
                return id
            }
        }

        return nil
    }

    static func extractCollectionID(from url: URL) -> Int? {
        let string = url.absoluteString
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = components.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if (name == "collection" || name == "collectionid" || name == "category" || name == "categoryid"),
                   let value = item.value,
                   let id = Int(value.split(separator: ",").last.map(String.init) ?? value) {
                    return id
                }
            }
        }

        let pathComponents = url.pathComponents
        for (index, component) in pathComponents.enumerated() {
            let lower = component.lowercased()
            if (lower == "collection" || lower == "collections" || lower == "category" || lower == "categories"),
               index + 1 < pathComponents.count,
               let id = Int(pathComponents[index + 1]) {
                return id
            }
        }

        if let match = string.range(of: #"[?&](?:collection|category)(?:id)?=(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let sub = String(string[match])
            if let digits = sub.components(separatedBy: CharacterSet.decimalDigits.inverted).last(where: { !$0.isEmpty }),
               let id = Int(digits) {
                return id
            }
        }

        if let match = string.range(of: #"/(?:collection|collections|category|categories)/(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let sub = String(string[match])
            if let digits = sub.components(separatedBy: CharacterSet.decimalDigits.inverted).last(where: { !$0.isEmpty }),
               let id = Int(digits) {
                return id
            }
        }

        return nil
    }

    static func teacherFeedURL(teacherID: Int, maxResults: Int = 100) -> URL {
        URL(string: "https://www.yutorah.org/rss/RecentAudioShiurim?teacherID=\(teacherID)&organizationID=301&numberOfRssResults=\(maxResults)")!
    }

    static func seriesFeedCandidateURLs(seriesID: Int, maxResults: Int = 100) -> [URL] {
        [
            URL(string: "https://www.yutorah.org/rss/RecentAudioShiurim?seriesID=\(seriesID)&organizationID=301&numberOfRssResults=\(maxResults)")!,
            URL(string: "https://www.yutorah.org/rss/recentAudioShiurim.cfm?seriesID=\(seriesID)&organizationID=301&numberOfRssResults=\(maxResults)")!
        ]
    }

    static func collectionFeedURL(collectionID: Int, maxResults: Int = 100) -> URL {
        URL(string: "https://classic.yutorah.org/search/_get_search_results.cfm?facet_query=collectionid:\(collectionID)&rows=\(maxResults)")!
    }

    static func collectionFeedCandidateURLs(collectionID: Int, maxResults: Int = 100) -> [URL] {
        [
            collectionFeedURL(collectionID: collectionID, maxResults: maxResults),
            URL(string: "https://www.yutorah.org/rss/RecentAudioShiurim?collectionID=\(collectionID)&organizationID=301&numberOfRssResults=\(maxResults)")!,
            URL(string: "https://www.yutorah.org/rss/RecentAudioShiurim?seriesID=\(collectionID)&organizationID=301&numberOfRssResults=\(maxResults)")!,
            URL(string: "https://www.yutorah.org/rss/RecentAudioShiurim?categoryID=\(collectionID)&organizationID=301&numberOfRssResults=\(maxResults)")!
        ]
    }
}
