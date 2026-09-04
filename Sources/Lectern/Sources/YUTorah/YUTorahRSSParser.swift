import Foundation

final class YUTorahRSSParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var channelTitle: String?
    private var currentElement = ""
    private var currentText = ""

    private var inChannel = false
    private var inItem = false

    private var itemTitle: String = ""
    private var itemLink: String = ""
    private var itemGuid: String = ""
    private var itemPubDate: String = ""
    private var itemAuthor: String = ""
    private var itemDuration: String = ""
    private var itemDescription: String = ""
    private var enclosureURL: String?
    private var enclosureLength: Int64?
    private var enclosureType: String?

    private var parsedItems: [RemoteShiurItem] = []

    static func parse(data: Data) -> (channelTitle: String?, items: [RemoteShiurItem])? {
        let parser = YUTorahRSSParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else {
            return nil
        }
        return (parser.channelTitle, parser.parsedItems)
    }

    static func isValidRSS(data: Data) -> Bool {
        guard let string = String(data: data.prefix(1024), encoding: .utf8)?.lowercased() else {
            return false
        }
        return string.contains("<rss") || string.contains("<channel")
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""

        if currentElement == "channel" {
            inChannel = true
        } else if currentElement == "item" {
            inItem = true
            itemTitle = ""
            itemLink = ""
            itemGuid = ""
            itemPubDate = ""
            itemAuthor = ""
            itemDuration = ""
            itemDescription = ""
            enclosureURL = nil
            enclosureLength = nil
            enclosureType = nil
        } else if inItem && currentElement == "enclosure" {
            if let url = attributeDict["url"] {
                enclosureURL = url
            }
            if let lengthStr = attributeDict["length"], let length = Int64(lengthStr) {
                enclosureLength = length
            }
            if let type = attributeDict["type"] {
                enclosureType = type
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let element = elementName.lowercased()

        if inItem {
            switch element {
            case "title":
                itemTitle = trimmed
            case "link":
                itemLink = trimmed
            case "guid":
                itemGuid = trimmed
            case "pubdate":
                itemPubDate = trimmed
            case "author", "itunes:author":
                if itemAuthor.isEmpty {
                    itemAuthor = trimmed
                }
            case "duration", "itunes:duration":
                itemDuration = trimmed
            case "summary", "itunes:summary", "description":
                if itemDescription.isEmpty {
                    itemDescription = trimmed
                }
            case "item":
                finishItem()
                inItem = false
            default:
                break
            }
        } else if inChannel {
            if element == "title", channelTitle == nil {
                channelTitle = trimmed
            } else if element == "channel" {
                inChannel = false
            }
        }
    }

    private func finishItem() {
        // Extract stable shiur ID
        let candidates = [itemLink, itemGuid, enclosureURL ?? "", itemTitle]
        var resolvedShiurID: String?
        for candidate in candidates {
            if let id = YUTorahURLResolver.extractShiurID(from: candidate) {
                resolvedShiurID = id
                break
            }
        }

        guard let shiurID = resolvedShiurID, !itemTitle.isEmpty else {
            return
        }

        let date = Self.parseDate(itemPubDate) ?? Date()
        let duration = Self.parseDuration(itemDuration)
        let pageURL = URL(string: itemLink)
        let enclosure = enclosureURL.flatMap(URL.init(string:))

        // Normalizing teacher author name if needed (e.g. "Rosensweig, Rabbi Michael" -> "Rabbi Michael Rosensweig")
        let formattedAuthor = Self.formatAuthor(itemAuthor)

        let item = RemoteShiurItem(
            shiurID: shiurID,
            title: itemTitle,
            teacherName: formattedAuthor,
            seriesName: nil,
            date: date,
            duration: duration,
            pageURL: pageURL,
            enclosureURL: enclosure,
            enclosureLength: enclosureLength,
            enclosureType: enclosureType,
            guid: itemGuid.isEmpty ? nil : itemGuid,
            itemDescription: itemDescription.isEmpty ? nil : itemDescription
        )
        parsedItems.append(item)
    }

    private static func formatAuthor(_ author: String) -> String? {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // If author is "LastName, FirstName Title" e.g. "Rosensweig, Rabbi Michael"
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                return "\(parts[1]) \(parts[0])"
            }
        }
        return trimmed
    }

    private static func parseDuration(_ string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // If plain seconds e.g. "4911"
        if let seconds = Double(trimmed) {
            return seconds
        }

        // If HH:MM:SS or MM:SS
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return nil
    }

    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static let rfc822NoSecFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm zzz"
        return formatter
    }()

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = rfc822Formatter.date(from: trimmed) { return date }
        if let date = rfc822NoSecFormatter.date(from: trimmed) { return date }
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        return nil
    }
}
