import Foundation

struct YUBannerTerm: Sendable, Equatable {
    let code: String
    let description: String
}

enum YUBannerError: LocalizedError {
    case invalidResponse
    case http(status: Int)
    case termNotFound(String)
    case sessionBindFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "YU Banner returned an unreadable response."
        case .http(let status): return "YU Banner request failed with HTTP \(status)."
        case .termNotFound(let term): return "YU Banner has no term matching \(term)."
        case .sessionBindFailed: return "YU Banner would not start a public search session."
        }
    }
}

/// Public YU Banner 9 class-search client.
///
/// Uses the same endpoints the registrar's own search page uses. No login is
/// needed. Banner is stateful, so every refresh runs the bind dance: reset
/// stale criteria, POST the term into the session, then page through the
/// whole term in one wide query. Per-subject loops return duplicate default
/// pages without the bind, so they are deliberately avoided.
actor YUBannerClient {
    static let baseURL = URL(string: "https://banner.oci.yu.edu/StudentRegistrationSsb/ssb")!

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = YUBannerClient.baseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieAcceptPolicy = .always
            config.httpCookieStorage = HTTPCookieStorage()
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Terms

    func fetchTerms() async throws -> [YUBannerTerm] {
        var components = URLComponents(url: baseURL.appending(path: "classSearch/getTerms"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "offset", value: "1"),
            .init(name: "max", value: "100"),
            .init(name: "searchTerm", value: ""),
        ]
        guard let url = components?.url else { throw YUBannerError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YUBannerError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Self.decodeTerms(data)
    }

    static func decodeTerms(_ data: Data) throws -> [YUBannerTerm] {
        struct RawTerm: Decodable {
            let code: LossyString
            let description: String?
        }
        struct LossyString: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { value = text; return }
                if let number = try? container.decode(Int.self) { value = String(number); return }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected term code string")
            }
        }
        let terms = try JSONDecoder().decode([RawTerm].self, from: data)
        return terms.compactMap { raw in
            guard let desc = raw.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty else { return nil }
            return YUBannerTerm(code: raw.code.value, description: desc)
        }
    }

    // MARK: - Sections

    /// Bind `termCode` into the Banner session. Mandatory before searchResults.
    func bindTerm(_ termCode: String) async throws {
        // Best effort: clear criteria left by an earlier run.
        var reset = URLRequest(url: baseURL.appending(path: "classSearch/resetDataForm"))
        reset.httpMethod = "POST"
        _ = try? await session.data(for: reset)

        var components = URLComponents(url: baseURL.appending(path: "term/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "mode", value: "search")]
        guard let url = components?.url else { throw YUBannerError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "term=\(termCode)&studyPath=&studyPathText=&startDatepicker=&endDatepicker="
        request.httpBody = Data(body.utf8)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YUBannerError.sessionBindFailed
        }
    }

    func fetchSectionsPage(termCode: String, offset: Int, maxSize: Int = 500) async throws -> (total: Int, sections: [YUBannerSection]) {
        var components = URLComponents(url: baseURL.appending(path: "searchResults/searchResults"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "txt_term", value: termCode),
            .init(name: "startDatepicker", value: ""),
            .init(name: "endDatepicker", value: ""),
            .init(name: "pageOffset", value: String(offset)),
            .init(name: "pageMaxSize", value: String(maxSize)),
            .init(name: "sortColumn", value: "subjectDescription"),
            .init(name: "sortDirection", value: "asc"),
        ]
        guard let url = components?.url else { throw YUBannerError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YUBannerError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Page: Decodable {
            let totalCount: Int?
            let data: [YUBannerSection]?
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        return (page.totalCount ?? 0, page.data ?? [])
    }

    /// Whole term in one wide query. No subject filter.
    func fetchAllSections(termCode: String, pageSize: Int = 500, politenessNanoseconds: UInt64 = 150_000_000) async throws -> [YUBannerSection] {
        try await bindTerm(termCode)
        var all: [YUBannerSection] = []
        var offset = 0
        var total = Int.max
        while offset < total {
            let page = try await fetchSectionsPage(termCode: termCode, offset: offset, maxSize: pageSize)
            total = page.total
            if page.sections.isEmpty { break }
            all.append(contentsOf: page.sections)
            offset += pageSize
            if page.sections.count < pageSize { break }
            if offset < total {
                try? await Task.sleep(nanoseconds: politenessNanoseconds)
            }
        }
        return all
    }
}
