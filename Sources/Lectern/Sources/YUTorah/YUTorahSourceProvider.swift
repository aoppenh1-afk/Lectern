import Foundation

final class YUTorahSourceProvider: ShiurSourceProvider, @unchecked Sendable {
    let providerKey = "yutorah"
    let displayName = "YU Torah"

    private let searchService: YUTorahSearchService
    private let mediaResolver: YUTorahMediaResolver
    private let searchIndex: YUTorahSearchIndex
    private let session: URLSession

    init(
        searchService: YUTorahSearchService? = nil,
        mediaResolver: YUTorahMediaResolver? = nil,
        searchIndex: YUTorahSearchIndex = .shared,
        session: URLSession = .shared
    ) {
        let index = searchIndex
        self.searchIndex = index
        self.session = session
        self.searchService = searchService ?? YUTorahSearchService(searchIndex: index, session: session)
        self.mediaResolver = mediaResolver ?? YUTorahMediaResolver(session: session)
    }

    func search(query: String) async throws -> [ShiurDiscoveryResult] {
        await searchService.search(query: query)
    }

    func resolveSubscription(for entity: ShiurSubscriptionEntity) async throws -> ResolvedSubscription {
        switch entity {
        case .teacher(let id, let name):
            let feedURL = YUTorahURLResolver.teacherFeedURL(teacherID: id)
            let previews = await searchService.resolvePreviewItems(for: .teacher, numericID: id)
            return ResolvedSubscription(
                targetType: .teacher,
                targetNumericID: id,
                displayName: name,
                originalURL: nil,
                feedURL: feedURL,
                previewItems: previews
            )

        case .series(let id, let title):
            let candidates = YUTorahURLResolver.seriesFeedCandidateURLs(seriesID: id)
            var chosenURL = candidates[0]

            // Validate candidate 1; if not valid RSS, fall back to candidate 2
            if let firstURL = candidates.first {
                if let items = await searchService.fetchFeedItems(url: firstURL), !items.isEmpty {
                    chosenURL = firstURL
                } else if candidates.count > 1 {
                    chosenURL = candidates[1]
                }
            }

            let previews = await searchService.resolvePreviewItems(for: .series, numericID: id)
            return ResolvedSubscription(
                targetType: .series,
                targetNumericID: id,
                displayName: title,
                originalURL: nil,
                feedURL: chosenURL,
                previewItems: previews
            )

        case .collection(let id, let title):
            let candidates = YUTorahURLResolver.collectionFeedCandidateURLs(collectionID: id)
            var chosenURL = candidates[0]

            if let firstURL = candidates.first {
                if let items = await searchService.fetchFeedItems(url: firstURL), !items.isEmpty {
                    chosenURL = firstURL
                } else if candidates.count > 1 {
                    chosenURL = candidates[1]
                }
            }

            let previews = await searchService.resolvePreviewItems(for: .collection, numericID: id)
            return ResolvedSubscription(
                targetType: .collection,
                targetNumericID: id,
                displayName: title,
                originalURL: nil,
                feedURL: chosenURL,
                previewItems: previews
            )

        case .customFeed(let url, let title):
            var previewItems: [RemoteShiurItem] = []
            if let items = await searchService.fetchFeedItems(url: url) {
                previewItems = Array(items.prefix(3))
            }
            return ResolvedSubscription(
                targetType: .rss,
                targetNumericID: nil,
                displayName: title,
                originalURL: url.absoluteString,
                feedURL: url,
                previewItems: previewItems
            )
        }
    }

    func resolveSharedURL(_ url: URL) async throws -> ShiurDiscoveryResult {
        let resolvedType = YUTorahURLResolver.resolve(url: url)

        switch resolvedType {
        case .teacher(let id):
            let name = searchIndex.teacher(forID: id)?.name ?? "Rabbi (YU Torah #\(id))"
            let previews = await searchService.resolvePreviewItems(for: .teacher, numericID: id)
            return .teacher(id: id, name: name, shiurCount: nil, previewItems: previews)

        case .series(let id):
            let title = searchIndex.series(forID: id)?.title ?? "YU Torah Series #\(id)"
            let previews = await searchService.resolvePreviewItems(for: .series, numericID: id)
            return .series(id: id, title: title, teacherName: nil, previewItems: previews)

        case .collection(let id):
            let title = searchIndex.collection(forID: id)?.title ?? "YU Torah Collection #\(id)"
            let description = searchIndex.collection(forID: id)?.collectionDescription
            let previews = await searchService.resolvePreviewItems(for: .collection, numericID: id)
            return .collection(id: id, title: title, description: description, previewItems: previews)

        case .shiur(let id):
            if let fetched = await searchService.fetchShiurByID(id) {
                return .shiur(item: fetched)
            }
            let pageURL = URL(string: "https://www.yutorah.org/lectures/\(id)")
            let item = RemoteShiurItem(
                shiurID: id,
                title: "YU Torah Shiur #\(id)",
                date: Date(),
                pageURL: pageURL
            )
            return .shiur(item: item)

        case .rssFeed(let feedURL):
            if let teacherID = YUTorahURLResolver.extractTeacherID(from: feedURL) {
                let name = searchIndex.teacher(forID: teacherID)?.name ?? "YU Torah Teacher #\(teacherID)"
                let previews = await searchService.resolvePreviewItems(for: .teacher, numericID: teacherID)
                return .teacher(id: teacherID, name: name, shiurCount: nil, previewItems: previews)
            } else if let seriesID = YUTorahURLResolver.extractSeriesID(from: feedURL) {
                let title = searchIndex.series(forID: seriesID)?.title ?? "YU Torah Series #\(seriesID)"
                let previews = await searchService.resolvePreviewItems(for: .series, numericID: seriesID)
                return .series(id: seriesID, title: title, teacherName: nil, previewItems: previews)
            } else if let collectionID = YUTorahURLResolver.extractCollectionID(from: feedURL) {
                let title = searchIndex.collection(forID: collectionID)?.title ?? "YU Torah Collection #\(collectionID)"
                let description = searchIndex.collection(forID: collectionID)?.collectionDescription
                let previews = await searchService.resolvePreviewItems(for: .collection, numericID: collectionID)
                return .collection(id: collectionID, title: title, description: description, previewItems: previews)
            } else {
                let previews = (await searchService.fetchFeedItems(url: feedURL)) ?? []
                let title = previews.first?.teacherName ?? "YU Torah Feed"
                return .series(id: 0, title: title, teacherName: nil, previewItems: Array(previews.prefix(3)))
            }

        case .unknown:
            throw NSError(
                domain: "YUTorahSourceProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unrecognized YU Torah link. Paste a teacher, series, collection, or shiur link."]
            )
        }
    }

    func fetchFeed(url: URL, eTag: String?, lastModified: String?, maxResults: Int) async throws -> FeedFetchResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X) YUTorahSubscriptionEngine", forHTTPHeaderField: "User-Agent")

        if let eTag, !eTag.isEmpty {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Polite HTTP 304 handling: no new content
        if httpResponse.statusCode == 304 {
            return .notModified
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let newETag = httpResponse.value(forHTTPHeaderField: "ETag")
        let newLastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")

        if YUTorahRSSParser.isValidRSS(data: data),
           let parsed = YUTorahRSSParser.parse(data: data) {
            return .newItems(
                items: parsed.items,
                channelTitle: parsed.channelTitle,
                eTag: newETag,
                lastModified: newLastModified
            )
        }

        if let colResponse = try? JSONDecoder().decode(YUTorahSearchService.YUTorahAPICollectionResponse.self, from: data),
           let shiurim = colResponse.collectionShiurim, !shiurim.isEmpty {
            let isoFormatter = ISO8601DateFormatter()
            let items = shiurim.compactMap { s -> RemoteShiurItem? in
                guard let idInt = s.shiurID else { return nil }
                let id = String(idInt)
                return RemoteShiurItem(
                    shiurID: id,
                    title: s.shiurTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "YU Torah Shiur #\(id)",
                    teacherName: s.shiurTeachers?.first?.teacherName,
                    seriesName: colResponse.collectionTitle,
                    date: s.shiurDate.flatMap { isoFormatter.date(from: $0) } ?? Date(),
                    duration: s.shiurDuration.flatMap { YUTorahSearchService.parseDurationString($0) },
                    pageURL: URL(string: "https://www.yutorah.org/lectures/\(id)"),
                    enclosureURL: (s.downloadURL ?? s.shiurFileURL).flatMap { URL(string: $0) }
                )
            }
            let channelTitle = colResponse.collectionTitle ?? "YU Torah Collection"
            return .newItems(
                items: items,
                channelTitle: channelTitle,
                eTag: newETag,
                lastModified: newLastModified
            )
        }

        if let searchResponse = try? JSONDecoder().decode(YUTorahSearchService.YUTorahSearchResponse.self, from: data),
           let docs = searchResponse.response?.docs {
            let items = YUTorahSearchService.parseSearchDocs(docs)
            let channelTitle = items.first?.teacherName.map { "\($0) - Collection" } ?? "YU Torah Collection"
            return .newItems(
                items: items,
                channelTitle: channelTitle,
                eTag: newETag,
                lastModified: newLastModified
            )
        }

        throw NSError(
            domain: "YUTorahSourceProvider",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Feed returned invalid RSS XML or search data."]
        )
    }

    func resolveMediaURL(for item: RemoteShiurItem) async throws -> URL {
        try await mediaResolver.resolveMediaURL(for: item)
    }
}
