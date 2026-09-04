import Foundation

actor YUTorahSearchService {
    private let searchIndex: YUTorahSearchIndex
    private let session: URLSession

    init(searchIndex: YUTorahSearchIndex = .shared, session: URLSession = .shared) {
        self.searchIndex = searchIndex
        self.session = session
    }

    struct QueryAnalysis {
        let originalQuery: String
        let matchedTeacher: YUTorahTeacherIndexEntry?
        let teacherConfidence: Double
        let topicTokens: [String]
        let matchedSeries: YUTorahSeriesIndexEntry?
        let seriesConfidence: Double
        let matchedCollection: YUTorahCollectionIndexEntry?
        let collectionConfidence: Double
    }

    func analyzeQuery(_ query: String) -> QueryAnalysis {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return QueryAnalysis(
                originalQuery: "",
                matchedTeacher: nil,
                teacherConfidence: 0,
                topicTokens: [],
                matchedSeries: nil,
                seriesConfidence: 0,
                matchedCollection: nil,
                collectionConfidence: 0
            )
        }

        let teacherMatches = searchIndex.findTeachers(query: trimmed, limit: 1)
        let topTeacher = teacherMatches.first
        let seriesMatches = searchIndex.findSeries(query: trimmed, limit: 1)
        let topSeries = seriesMatches.first
        let collectionMatches = searchIndex.findCollections(query: trimmed, limit: 1)
        let topCollection = collectionMatches.first

        let tokens = trimmed.split(separator: " ").map(String.init)
        var bestSubTeacher: (entry: YUTorahTeacherIndexEntry, score: Double, matchedTokenCount: Int)?

        if tokens.count > 1 {
            for len in (1..<tokens.count).reversed() {
                let candidateName = tokens.prefix(len).joined(separator: " ")
                let subMatches = searchIndex.findTeachers(query: candidateName, limit: 1)
                if let match = subMatches.first, match.score >= YUTorahFuzzyMatcher.confidenceThreshold {
                    bestSubTeacher = (match.entry, match.score, len)
                    break
                }
            }
        }

        let resolvedTeacher: YUTorahTeacherIndexEntry?
        let resolvedTeacherConfidence: Double
        let topicTokens: [String]

        if let sub = bestSubTeacher, sub.score >= (topTeacher?.score ?? 0) {
            resolvedTeacher = sub.entry
            resolvedTeacherConfidence = sub.score
            topicTokens = Array(tokens.dropFirst(sub.matchedTokenCount))
        } else if let top = topTeacher, top.isConfident {
            resolvedTeacher = top.entry
            resolvedTeacherConfidence = top.score
            topicTokens = []
        } else {
            resolvedTeacher = nil
            resolvedTeacherConfidence = topTeacher?.score ?? 0
            topicTokens = tokens
        }

        return QueryAnalysis(
            originalQuery: trimmed,
            matchedTeacher: resolvedTeacher,
            teacherConfidence: resolvedTeacherConfidence,
            topicTokens: topicTokens,
            matchedSeries: (topSeries?.isConfident == true) ? topSeries?.entry : nil,
            seriesConfidence: topSeries?.score ?? 0,
            matchedCollection: (topCollection?.isConfident == true) ? topCollection?.entry : nil,
            collectionConfidence: topCollection?.score ?? 0
        )
    }

    // MARK: - Full Structured Search (YU Torah Core API)

    func searchStructured(
        query: String,
        teacherID: Int? = nil,
        seriesID: Int? = nil,
        collectionID: Int? = nil,
        subcategoryID: Int? = nil,
        page: Int = 1
    ) async -> YUTorahSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://api.yutorah.org/search")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start", value: "\(max(1, page))")
        ]

        if !trimmed.isEmpty {
            queryItems.append(URLQueryItem(name: "searchTerm", value: trimmed))
        }
        if let teacherID {
            queryItems.append(URLQueryItem(name: "teacherID", value: "\(teacherID)"))
        }
        if let seriesID {
            queryItems.append(URLQueryItem(name: "seriesID", value: "\(seriesID)"))
        }
        if let collectionID {
            queryItems.append(URLQueryItem(name: "collectionID", value: "\(collectionID)"))
        }
        if let subcategoryID {
            queryItems.append(URLQueryItem(name: "subcategoryID", value: "\(subcategoryID)"))
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            return .empty
        }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let apiResponse = try? JSONDecoder().decode(YUTorahAPISearchResponse.self, from: data) {

            let totalShiurim = apiResponse.response?.numFound ?? 0
            let docs = apiResponse.response?.docs ?? []
            let parsedShiurim = Self.parseAPIDocs(docs)

            let teachers = (apiResponse.facetCounts?.facetFields?.teachers ?? []).compactMap { t -> YUTorahFacetTeacher? in
                guard let id = t.teacherId, let rawName = t.teacherName else { return nil }
                return YUTorahFacetTeacher(
                    id: id,
                    rawName: rawName,
                    lastName: t.teacherLastName,
                    shiurCount: t.match ?? 0
                )
            }

            let collections = (apiResponse.facetCounts?.facetFields?.collections ?? []).compactMap { c -> YUTorahFacetCollection? in
                guard let id = c.collectionId, let name = c.collectionName else { return nil }
                return YUTorahFacetCollection(
                    id: id,
                    title: name,
                    shiurCount: c.match ?? 0
                )
            }

            let seriesList = (apiResponse.facetCounts?.facetFields?.series ?? []).compactMap { s -> YUTorahFacetSeries? in
                guard let id = s.seriesId, let name = s.seriesName else { return nil }
                return YUTorahFacetSeries(
                    id: id,
                    title: name,
                    shiurCount: s.match ?? 0
                )
            }

            let subcategories = (apiResponse.facetCounts?.facetFields?.subcategories ?? []).compactMap { sc -> YUTorahFacetSubcategory? in
                guard let id = sc.subcategoryId else { return nil }
                return YUTorahFacetSubcategory(
                    id: id,
                    categoryName: sc.categoryName ?? "",
                    subcategoryName: sc.subcategoryName ?? "",
                    shiurCount: sc.match ?? 0
                )
            }

            let totalPages = max(1, Int(ceil(Double(totalShiurim) / 30.0)))

            var activeTeacher: YUTorahFacetTeacher? = nil
            if let teacherID {
                activeTeacher = teachers.first(where: { $0.id == teacherID })
                    ?? searchIndex.teacher(forID: teacherID).map {
                        YUTorahFacetTeacher(id: $0.id, rawName: $0.name, lastName: nil, shiurCount: totalShiurim)
                    }
            } else if let topTeacher = teachers.first, !trimmed.isEmpty {
                let score = YUTorahFuzzyMatcher.score(query: trimmed, candidate: topTeacher.displayName).score
                let altScore = YUTorahFuzzyMatcher.score(query: trimmed, candidate: topTeacher.rawName).score
                if max(score, altScore) >= 0.70 {
                    activeTeacher = topTeacher
                }
            }

            let activeSubcat = subcategoryID.flatMap { scID in
                subcategories.first(where: { $0.id == scID })
            }

            return YUTorahSearchResults(
                query: trimmed,
                totalShiurim: totalShiurim,
                currentPage: max(1, page),
                totalPages: totalPages,
                shiurim: parsedShiurim,
                teachers: teachers,
                collections: collections,
                series: seriesList,
                subcategories: subcategories,
                activeTeacher: activeTeacher,
                activeSubcategory: activeSubcat
            )
        }

        // Fallback: Classic search endpoint
        let fallbackShiurim = await fetchSearchResults(query: trimmed, maxResults: 30)
        let localTeachers = searchIndex.findTeachers(query: trimmed, limit: 10).map {
            YUTorahFacetTeacher(id: $0.entry.id, rawName: $0.entry.name, lastName: nil, shiurCount: $0.entry.shiurCount ?? fallbackShiurim.count)
        }
        let localSeries = searchIndex.findSeries(query: trimmed, limit: 10).map {
            YUTorahFacetSeries(id: $0.entry.id, title: $0.entry.title, shiurCount: 0)
        }
        let localCollections = searchIndex.findCollections(query: trimmed, limit: 10).map {
            YUTorahFacetCollection(id: $0.entry.id, title: $0.entry.title, shiurCount: 0)
        }

        return YUTorahSearchResults(
            query: trimmed,
            totalShiurim: fallbackShiurim.count,
            currentPage: 1,
            totalPages: 1,
            shiurim: fallbackShiurim,
            teachers: localTeachers,
            collections: localCollections,
            series: localSeries,
            subcategories: [],
            activeTeacher: localTeachers.first,
            activeSubcategory: nil
        )
    }

    // MARK: - Legacy / Standard Discovery Search

    func search(query: String) async -> [ShiurDiscoveryResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [ShiurDiscoveryResult] = []
        var seenShiurIDs = Set<String>()

        // 0. Direct URL or Query Parameter Interception
        if trimmed.contains("yutorah.org") || trimmed.contains("collection=") || trimmed.contains("teacher=") || trimmed.contains("series=") || (URL(string: trimmed)?.scheme != nil) {
            let candidateString = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) ? trimmed : "https://www.yutorah.org/\(trimmed)"
            if let url = URL(string: candidateString) {
                let resolvedType = YUTorahURLResolver.resolve(url: url)
                switch resolvedType {
                case .collection(let id):
                    let colTitle = searchIndex.collection(forID: id)?.title ?? "YU Torah Collection #\(id)"
                    let colDesc = searchIndex.collection(forID: id)?.collectionDescription
                    let previews = await resolvePreviewItems(for: .collection, numericID: id)
                    return [.collection(id: id, title: colTitle, description: colDesc, previewItems: previews)]
                case .series(let id):
                    let serTitle = searchIndex.series(forID: id)?.title ?? "YU Torah Series #\(id)"
                    let previews = await resolvePreviewItems(for: .series, numericID: id)
                    return [.series(id: id, title: serTitle, teacherName: nil, previewItems: previews)]
                case .teacher(let id):
                    let teachName = searchIndex.teacher(forID: id)?.name ?? "YU Torah Teacher #\(id)"
                    let previews = await resolvePreviewItems(for: .teacher, numericID: id)
                    return [.teacher(id: id, name: teachName, shiurCount: nil, previewItems: previews)]
                case .shiur(let id):
                    if let item = await fetchShiurByID(id) {
                        return [.shiur(item: item)]
                    }
                case .rssFeed(let feedURL):
                    if let items = await fetchFeedItems(url: feedURL) {
                        return items.map { .shiur(item: $0) }
                    }
                case .unknown:
                    break
                }
            }
        }

        // 1. Direct Shiur ID lookup
        if let directID = YUTorahURLResolver.extractShiurID(from: trimmed) {
            if let directItem = await fetchShiurByID(directID) {
                seenShiurIDs.insert(directItem.shiurID)
                results.append(.shiur(item: directItem))
            }
        }

        // 2. Perform Full Structured Search on Core API
        let structured = await searchStructured(query: trimmed)

        // Add matching teachers
        for teacher in structured.teachers.prefix(5) {
            let previews = structured.shiurim.filter { $0.teacherName?.contains(teacher.displayName) == true || $0.teacherName?.contains(teacher.rawName) == true }
            results.append(.teacher(
                id: teacher.id,
                name: teacher.displayName,
                shiurCount: teacher.shiurCount,
                previewItems: previews
            ))
        }

        // Add matching collections
        for collection in structured.collections.prefix(6) {
            let previews = await resolvePreviewItems(for: .collection, numericID: collection.id)
            results.append(.collection(
                id: collection.id,
                title: collection.title,
                description: "\(collection.shiurCount) Shiurim",
                previewItems: previews
            ))
        }

        // Add matching series
        for series in structured.series.prefix(5) {
            let previews = await resolvePreviewItems(for: .series, numericID: series.id)
            results.append(.series(
                id: series.id,
                title: series.title,
                teacherName: "\(series.shiurCount) Shiurim",
                previewItems: previews
            ))
        }

        // Add discovered shiurim
        for item in structured.shiurim where !seenShiurIDs.contains(item.shiurID) {
            seenShiurIDs.insert(item.shiurID)
            results.append(.shiur(item: item))
        }

        // 3. Fallback to Local Search Index if API returned nothing
        if results.isEmpty {
            let teacherMatches = searchIndex.findTeachers(query: trimmed, limit: 3)
            for match in teacherMatches where match.score >= 0.45 {
                let previews = await resolvePreviewItems(for: .teacher, numericID: match.entry.id)
                results.append(.teacher(
                    id: match.entry.id,
                    name: match.entry.name,
                    shiurCount: match.entry.shiurCount,
                    previewItems: previews
                ))
            }

            let collectionMatches = searchIndex.findCollections(query: trimmed, limit: 3)
            for match in collectionMatches where match.score >= 0.45 {
                let previews = await resolvePreviewItems(for: .collection, numericID: match.entry.id)
                results.append(.collection(
                    id: match.entry.id,
                    title: match.entry.title,
                    description: match.entry.collectionDescription,
                    previewItems: previews
                ))
            }

            let seriesMatches = searchIndex.findSeries(query: trimmed, limit: 3)
            for match in seriesMatches where match.score >= 0.45 {
                let previews = await resolvePreviewItems(for: .series, numericID: match.entry.id)
                results.append(.series(
                    id: match.entry.id,
                    title: match.entry.title,
                    teacherName: match.entry.teacherName,
                    previewItems: previews
                ))
            }
        }

        return results
    }

    // MARK: - Collection Shiurim Retrieval (Core API /collections/get)

    func fetchCollectionShiurim(collectionID: Int) async -> [RemoteShiurItem] {
        let urlString = "https://api.yutorah.org/collections/get?collectionID=\(collectionID)"
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let colResponse = try? JSONDecoder().decode(YUTorahAPICollectionResponse.self, from: data),
           let shiurim = colResponse.collectionShiurim, !shiurim.isEmpty {

            let isoFormatter = ISO8601DateFormatter()

            return shiurim.compactMap { s -> RemoteShiurItem? in
                guard let idInt = s.shiurID else { return nil }
                let id = String(idInt)
                let title = s.shiurTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "YU Torah Shiur #\(id)"
                let teacher = s.shiurTeachers?.first?.teacherName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let date = s.shiurDate.flatMap { isoFormatter.date(from: $0) } ?? Date()
                let duration = s.shiurDuration.flatMap { Self.parseDurationString($0) }
                let enclosure = (s.downloadURL ?? s.shiurFileURL).flatMap { URL(string: $0) }
                let pageURL = URL(string: "https://www.yutorah.org/lectures/\(id)")

                return RemoteShiurItem(
                    shiurID: id,
                    title: title,
                    teacherName: teacher,
                    seriesName: colResponse.collectionTitle,
                    date: date,
                    duration: duration,
                    pageURL: pageURL,
                    enclosureURL: enclosure,
                    itemDescription: s.shiurDescription
                )
            }
        }

        // Fallback: Classic Solr search
        let classicFeedURL = YUTorahURLResolver.collectionFeedURL(collectionID: collectionID, maxResults: 50)
        return (await fetchFeedItems(url: classicFeedURL)) ?? []
    }

    // MARK: - Core API Codable Responses

    struct YUTorahAPISearchResponse: Codable, Sendable {
        struct ResponseBody: Codable, Sendable {
            let start: Int?
            let maxScore: Double?
            let numFound: Int?
            let docs: [Doc]?
        }

        struct Doc: Codable, Sendable {
            let shiurid: Int?
            let shiurtitle: String?
            let teacherfullname: String?
            let teacherid: Int?
            let teachertype: String?
            let duration: Double?
            let durationformatted: String?
            let shiurdate: String?
            let shiurdateformatted: String?
            let shiurdownloadurl: String?
            let shiururl: String?
            let seriesname: [String]?
            let seriesid: [Int]?
            let collectionname: [String]?
            let collectionid: [Int]?
            let categoryname: [String]?
            let subcategoryname: [String]?
            let subcategoryid: [Int]?
            let photo: String?

            enum CodingKeys: String, CodingKey {
                case shiurid, shiurtitle, teacherfullname, teacherid, teachertype, duration, durationformatted
                case shiurdate, shiurdateformatted, shiurdownloadurl, shiururl, seriesname, seriesid
                case collectionname, collectionid, categoryname, subcategoryname, subcategoryid
                case photo = "PHOTO"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.shiurid = try? c.decodeIfPresent(Int.self, forKey: .shiurid)
                self.shiurtitle = try? c.decodeIfPresent(String.self, forKey: .shiurtitle)
                self.teacherfullname = try? c.decodeIfPresent(String.self, forKey: .teacherfullname)
                self.teacherid = try? c.decodeIfPresent(Int.self, forKey: .teacherid)
                self.teachertype = try? c.decodeIfPresent(String.self, forKey: .teachertype)
                self.durationformatted = try? c.decodeIfPresent(String.self, forKey: .durationformatted)
                self.shiurdate = try? c.decodeIfPresent(String.self, forKey: .shiurdate)
                self.shiurdateformatted = try? c.decodeIfPresent(String.self, forKey: .shiurdateformatted)
                self.shiurdownloadurl = try? c.decodeIfPresent(String.self, forKey: .shiurdownloadurl)
                self.shiururl = try? c.decodeIfPresent(String.self, forKey: .shiururl)
                self.seriesname = try? c.decodeIfPresent([String].self, forKey: .seriesname)
                self.seriesid = try? c.decodeIfPresent([Int].self, forKey: .seriesid)
                self.collectionname = try? c.decodeIfPresent([String].self, forKey: .collectionname)
                self.collectionid = try? c.decodeIfPresent([Int].self, forKey: .collectionid)
                self.categoryname = try? c.decodeIfPresent([String].self, forKey: .categoryname)
                self.subcategoryname = try? c.decodeIfPresent([String].self, forKey: .subcategoryname)
                self.subcategoryid = try? c.decodeIfPresent([Int].self, forKey: .subcategoryid)
                self.photo = try? c.decodeIfPresent(String.self, forKey: .photo)

                if let d = try? c.decodeIfPresent(Double.self, forKey: .duration) {
                    self.duration = d
                } else if let s = try? c.decodeIfPresent(String.self, forKey: .duration), let d = Double(s) {
                    self.duration = d
                } else {
                    self.duration = nil
                }
            }
        }

        struct FacetCounts: Codable, Sendable {
            let facetFields: FacetFields?

            enum CodingKeys: String, CodingKey {
                case facetFields = "facet_fields"
            }
        }

        struct FacetFields: Codable, Sendable {
            let teachers: [FacetTeacherItem]?
            let collections: [FacetCollectionItem]?
            let series: [FacetSeriesItem]?
            let subcategories: [FacetSubcategoryItem]?
        }

        struct FacetTeacherItem: Codable, Sendable {
            let teacherName: String?
            let teacherId: Int?
            let teacherLastName: String?
            let match: Int?

            enum CodingKeys: String, CodingKey {
                case teacherName = "TeacherName"
                case teacherId = "TeacherId"
                case teacherLastName = "TeacherLastName"
                case match = "Match"
            }
        }

        struct FacetCollectionItem: Codable, Sendable {
            let collectionName: String?
            let collectionId: Int?
            let match: Int?

            enum CodingKeys: String, CodingKey {
                case collectionName = "CollectionName"
                case collectionId = "CollectionId"
                case match = "Match"
            }
        }

        struct FacetSeriesItem: Codable, Sendable {
            let seriesName: String?
            let seriesId: Int?
            let match: Int?

            enum CodingKeys: String, CodingKey {
                case seriesName = "SeriesName"
                case seriesId = "SeriesId"
                case match = "Match"
            }
        }

        struct FacetSubcategoryItem: Codable, Sendable {
            let categoryName: String?
            let subcategoryName: String?
            let subcategoryId: Int?
            let match: Int?

            enum CodingKeys: String, CodingKey {
                case categoryName = "categoryName"
                case subcategoryName = "Subcategoryname"
                case subcategoryId = "SubcategoryId"
                case match = "Match"
            }
        }

        let response: ResponseBody?
        let facetCounts: FacetCounts?

        enum CodingKeys: String, CodingKey {
            case response
            case facetCounts = "facet_counts"
        }
    }

    struct YUTorahAPICollectionResponse: Codable, Sendable {
        struct CollectionShiur: Codable, Sendable {
            let shiurID: Int?
            let shiurTitle: String?
            let shiurDescription: String?
            let shiurDate: String?
            let shiurDuration: String?
            let downloadURL: String?
            let shiurFileURL: String?
            let shiurTeachers: [CollectionTeacher]?

            struct CollectionTeacher: Codable, Sendable {
                let teacherID: Int?
                let teacherName: String?
            }
        }

        let collectionTitle: String?
        let collectionSubtitle: String?
        let collectionShiurim: [CollectionShiur]?
    }

    static func parseAPIDocs(_ docs: [YUTorahAPISearchResponse.Doc]) -> [RemoteShiurItem] {
        let isoFormatter = ISO8601DateFormatter()

        return docs.compactMap { doc -> RemoteShiurItem? in
            guard let idInt = doc.shiurid else { return nil }
            let id = String(idInt)
            let title = doc.shiurtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "YU Torah Shiur #\(id)"
            let durationSec: TimeInterval? = {
                if let d = doc.duration, d > 0 {
                    return d * 60
                }
                if let formatted = doc.durationformatted {
                    return parseDurationString(formatted)
                }
                return nil
            }()
            let date = doc.shiurdate.flatMap { isoFormatter.date(from: $0) } ?? Date()
            let pageURL = URL(string: "https://www.yutorah.org/lectures/\(id)")

            var enclosureURL: URL? = nil
            if let downloadStr = doc.shiurdownloadurl, !downloadStr.isEmpty, let u = URL(string: downloadStr) {
                enclosureURL = u
            } else if let path = doc.shiururl, !path.isEmpty {
                let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
                enclosureURL = URL(string: "https://download.yutorah.org" + cleanPath)
            }

            return RemoteShiurItem(
                shiurID: id,
                title: title,
                teacherName: doc.teacherfullname?.trimmingCharacters(in: .whitespacesAndNewlines),
                seriesName: doc.seriesname?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                date: date,
                duration: durationSec,
                pageURL: pageURL,
                enclosureURL: enclosureURL
            )
        }
    }

    static func parseDurationString(_ string: String) -> TimeInterval? {
        var totalSeconds: TimeInterval = 0
        let lower = string.lowercased()

        if let hrRange = lower.range(of: "hr") {
            let prefix = lower[..<hrRange.lowerBound]
            let digits = prefix.components(separatedBy: CharacterSet.decimalDigits.inverted).last ?? ""
            if let hrs = Double(digits) {
                totalSeconds += hrs * 3600
            }
        }
        if let minRange = lower.range(of: "min") {
            let prefix = lower[..<minRange.lowerBound]
            let digits = prefix.components(separatedBy: CharacterSet.decimalDigits.inverted).last ?? ""
            if let mins = Double(digits) {
                totalSeconds += mins * 60
            }
        }
        if let secRange = lower.range(of: "sec") {
            let prefix = lower[..<secRange.lowerBound]
            let digits = prefix.components(separatedBy: CharacterSet.decimalDigits.inverted).last ?? ""
            if let secs = Double(digits) {
                totalSeconds += secs
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }

    // MARK: - Legacy Solr Search (classic.yutorah.org)

    struct YUTorahSearchResponse: Codable, Sendable {
        struct ResponseBody: Codable, Sendable {
            let numFound: Int?
            let docs: [Doc]?
        }
        struct Doc: Codable, Sendable {
            let shiurid: Int?
            let shiurtitle: String?
            let teacherfullname: String?
            let teacherid: Int?
            let seriesname: [String]?
            let seriesid: [Int]?
            let duration: Double?
            let shiurdate: String?
            let shiururl: String?

            enum CodingKeys: String, CodingKey {
                case shiurid, shiurtitle, teacherfullname, teacherid, seriesname, seriesid, duration, shiurdate, shiururl
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.shiurid = try? container.decodeIfPresent(Int.self, forKey: .shiurid)
                self.shiurtitle = try? container.decodeIfPresent(String.self, forKey: .shiurtitle)
                self.teacherfullname = try? container.decodeIfPresent(String.self, forKey: .teacherfullname)
                self.teacherid = try? container.decodeIfPresent(Int.self, forKey: .teacherid)
                self.seriesname = try? container.decodeIfPresent([String].self, forKey: .seriesname)
                self.seriesid = try? container.decodeIfPresent([Int].self, forKey: .seriesid)
                self.shiurdate = try? container.decodeIfPresent(String.self, forKey: .shiurdate)
                self.shiururl = try? container.decodeIfPresent(String.self, forKey: .shiururl)

                if let d = try? container.decodeIfPresent(Double.self, forKey: .duration) {
                    self.duration = d
                } else if let s = try? container.decodeIfPresent(String.self, forKey: .duration), let d = Double(s) {
                    self.duration = d
                } else {
                    self.duration = nil
                }
            }
        }
        let response: ResponseBody?
    }

    func fetchSearchResults(query: String, maxResults: Int = 30) async -> [RemoteShiurItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://classic.yutorah.org/search/_get_search_results.cfm")
        components?.queryItems = [
            URLQueryItem(name: "search_query", value: trimmed),
            URLQueryItem(name: "rows", value: "\(maxResults)")
        ]

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return []
        }

        let decoder = JSONDecoder()
        guard let searchResponse = try? decoder.decode(YUTorahSearchResponse.self, from: data),
              let docs = searchResponse.response?.docs else {
            return []
        }

        return Self.parseSearchDocs(docs)
    }

    static func parseSearchDocs(_ docs: [YUTorahSearchResponse.Doc]) -> [RemoteShiurItem] {
        let isoFormatter = ISO8601DateFormatter()

        return docs.compactMap { doc -> RemoteShiurItem? in
            guard let idInt = doc.shiurid else { return nil }
            let id = String(idInt)
            let title = doc.shiurtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "YU Torah Shiur #\(id)"
            let durationSec: TimeInterval? = doc.duration.map { $0 * 60 }
            let date = doc.shiurdate.flatMap { isoFormatter.date(from: $0) } ?? Date()
            let pageURL = URL(string: "https://www.yutorah.org/lectures/\(id)")

            var enclosureURL: URL? = nil
            if let path = doc.shiururl, !path.isEmpty {
                let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
                enclosureURL = URL(string: "https://download.yutorah.org" + cleanPath)
            }

            return RemoteShiurItem(
                shiurID: id,
                title: title,
                teacherName: doc.teacherfullname?.trimmingCharacters(in: .whitespacesAndNewlines),
                seriesName: doc.seriesname?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                date: date,
                duration: durationSec,
                pageURL: pageURL,
                enclosureURL: enclosureURL
            )
        }
    }

    func fetchShiurByID(_ id: String) async -> RemoteShiurItem? {
        let structured = await searchStructured(query: id)
        if let match = structured.shiurim.first(where: { $0.shiurID == id }) {
            return match
        }
        let results = await fetchSearchResults(query: id, maxResults: 5)
        return results.first(where: { $0.shiurID == id }) ?? results.first
    }

    func fetchFeedItems(url: URL) async -> [RemoteShiurItem]? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 12)
        request.setValue("Lectern/1.3.3 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        if YUTorahRSSParser.isValidRSS(data: data),
           let parsed = YUTorahRSSParser.parse(data: data) {
            return parsed.items
        }

        if let apiResponse = try? JSONDecoder().decode(YUTorahAPISearchResponse.self, from: data),
           let docs = apiResponse.response?.docs, !docs.isEmpty {
            return Self.parseAPIDocs(docs)
        }

        if let colResponse = try? JSONDecoder().decode(YUTorahAPICollectionResponse.self, from: data),
           let shiurim = colResponse.collectionShiurim, !shiurim.isEmpty {
            let isoFormatter = ISO8601DateFormatter()
            return shiurim.compactMap { s -> RemoteShiurItem? in
                guard let idInt = s.shiurID else { return nil }
                let id = String(idInt)
                return RemoteShiurItem(
                    shiurID: id,
                    title: s.shiurTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "YU Torah Shiur #\(id)",
                    teacherName: s.shiurTeachers?.first?.teacherName,
                    seriesName: colResponse.collectionTitle,
                    date: s.shiurDate.flatMap { isoFormatter.date(from: $0) } ?? Date(),
                    duration: s.shiurDuration.flatMap { Self.parseDurationString($0) },
                    pageURL: URL(string: "https://www.yutorah.org/lectures/\(id)"),
                    enclosureURL: (s.downloadURL ?? s.shiurFileURL).flatMap { URL(string: $0) }
                )
            }
        }

        if let searchResponse = try? JSONDecoder().decode(YUTorahSearchResponse.self, from: data),
           let docs = searchResponse.response?.docs {
            return Self.parseSearchDocs(docs)
        }

        return nil
    }

    func resolvePreviewItems(for target: ShiurSubscriptionTargetType, numericID: Int) async -> [RemoteShiurItem] {
        switch target {
        case .teacher:
            let results = await searchStructured(query: "", teacherID: numericID, page: 1)
            if !results.shiurim.isEmpty {
                return Array(results.shiurim.prefix(3))
            }
            let url = YUTorahURLResolver.teacherFeedURL(teacherID: numericID, maxResults: 5)
            return (await fetchFeedItems(url: url))?.prefix(3).map { $0 } ?? []

        case .series:
            let results = await searchStructured(query: "", seriesID: numericID, page: 1)
            if !results.shiurim.isEmpty {
                return Array(results.shiurim.prefix(3))
            }
            let candidateURLs = YUTorahURLResolver.seriesFeedCandidateURLs(seriesID: numericID, maxResults: 5)
            for url in candidateURLs {
                if let items = await fetchFeedItems(url: url), !items.isEmpty {
                    return Array(items.prefix(3))
                }
            }
            return []

        case .collection:
            let collectionShiurim = await fetchCollectionShiurim(collectionID: numericID)
            if !collectionShiurim.isEmpty {
                return Array(collectionShiurim.prefix(3))
            }
            let candidateURLs = YUTorahURLResolver.collectionFeedCandidateURLs(collectionID: numericID, maxResults: 5)
            for url in candidateURLs {
                if let items = await fetchFeedItems(url: url), !items.isEmpty {
                    return Array(items.prefix(3))
                }
            }
            return []

        case .rss:
            return []
        }
    }
}
