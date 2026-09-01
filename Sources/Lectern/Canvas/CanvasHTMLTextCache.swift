import Foundation

final class CanvasHTMLTextCache: @unchecked Sendable {
    static let shared = CanvasHTMLTextCache()

    private let cache = NSCache<NSString, NSString>()

    init(countLimit: Int = 128, totalCostLimit: Int = 16 * 1_024 * 1_024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func text(for source: String, parser: (String) -> String = CanvasHTMLTextCache.parse) -> String {
        guard source.contains("<") else { return source }

        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached as String
        }

        let parsed = parser(source)
        cache.setObject(parsed as NSString, forKey: key, cost: source.utf8.count + parsed.utf8.count)
        return parsed
    }

    private static func parse(_ source: String) -> String {
        let data = Data(source.utf8)
        if let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return source.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
