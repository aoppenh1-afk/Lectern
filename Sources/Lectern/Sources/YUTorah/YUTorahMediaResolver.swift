import Foundation

enum YUTorahMediaResolverError: LocalizedError, Sendable {
    case invalidShiurID
    case noMediaFound(shiurID: String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidShiurID:
            return "Cannot resolve media: invalid or missing Shiur ID."
        case .noMediaFound(let shiurID):
            return "No playable MP3 audio was found on YU Torah for shiur \(shiurID)."
        case .networkError(let details):
            return "Failed to connect to YU Torah media service: \(details)"
        }
    }
}

final class YUTorahMediaResolver: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let mp3Regex = try! NSRegularExpression(
        pattern: #"https?://[^"'<>\s]+\.mp3(?:\?[^"'<>\s]*)?"#,
        options: .caseInsensitive
    )

    func resolveMediaURL(for item: RemoteShiurItem) async throws -> URL {
        // Fast path: if enclosure URL exists and looks valid
        if let enclosure = item.enclosureURL,
           let normalized = normalizeMediaURL(enclosure) {
            return normalized
        }

        // Fallback path: classic lecture iframe extractor
        return try await resolveMediaFallback(shiurID: item.shiurID)
    }

    func resolveMediaFallback(shiurID: String) async throws -> URL {
        guard !shiurID.isEmpty, Int(shiurID) != nil else {
            throw YUTorahMediaResolverError.invalidShiurID
        }

        let classicURL = URL(string: "https://classic.yutorah.org/lectures/lecture_iframe.cfm/\(shiurID)")!
        var request = URLRequest(url: classicURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw YUTorahMediaResolverError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw YUTorahMediaResolverError.noMediaFound(shiurID: shiurID)
        }

        let range = NSRange(html.startIndex..., in: html)
        if let match = Self.mp3Regex.firstMatch(in: html, range: range),
           let targetRange = Range(match.range(at: 0), in: html) {
            var rawUrl = String(html[targetRange])
            rawUrl = rawUrl.replacingOccurrences(of: "-.mp3", with: ".mp3")
            if let resolved = URL(string: rawUrl), let normalized = normalizeMediaURL(resolved) {
                return normalized
            }
        }

        throw YUTorahMediaResolverError.noMediaFound(shiurID: shiurID)
    }

    private func normalizeMediaURL(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Prefer https for yutorah download domain
        if components?.scheme == "http" {
            components?.scheme = "https"
        }
        return components?.url ?? url
    }
}
