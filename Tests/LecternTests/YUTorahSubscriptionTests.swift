import Foundation
import SwiftData
import Testing

struct YUTorahSubscriptionTests {

    // MARK: - 1. URL Resolver Tests

    @Test func testResolveTeacherURL() {
        let directURL = URL(string: "https://www.yutorah.org/lectures/?teacher=80056")!
        let target = YUTorahURLResolver.resolve(url: directURL)
        #expect(target != nil)
        if case .teacher(let id) = target {
            #expect(id == 80056)
        } else {
            Issue.record("Expected .teacher target for teacher URL")
        }

        let queryURL = URL(string: "https://www.yutorah.org/lectures/?teacherID=80056")!
        let queryTarget = YUTorahURLResolver.resolve(url: queryURL)
        if case .teacher(let id) = queryTarget {
            #expect(id == 80056)
        } else {
            Issue.record("Expected .teacher target for query URL")
        }
    }

    @Test func testResolveSeriesURL() {
        let directSeriesURL = URL(string: "https://www.yutorah.org/series/1234/")!
        let target = YUTorahURLResolver.resolve(url: directSeriesURL)
        #expect(target != nil)
        if case .series(let id) = target {
            #expect(id == 1234)
        } else {
            Issue.record("Expected .series target for series URL")
        }

        let querySeriesURL = URL(string: "https://www.yutorah.org/lectures/?seriesID=5678")!
        let queryTarget = YUTorahURLResolver.resolve(url: querySeriesURL)
        if case .series(let id) = queryTarget {
            #expect(id == 5678)
        } else {
            Issue.record("Expected .series target for series query URL")
        }
    }

    @Test func testResolveShiurURL() {
        let shiurURL = URL(string: "https://www.yutorah.org/lectures/1083921/")!
        let target = YUTorahURLResolver.resolve(url: shiurURL)
        #expect(target != nil)
        if case .shiur(let id) = target {
            #expect(id == "1083921")
        } else {
            Issue.record("Expected .shiur target for lecture URL")
        }

        let legacyShiurURL = URL(string: "https://classic.yutorah.org/lectures/lecture.cfm/1083921")!
        let legacyTarget = YUTorahURLResolver.resolve(url: legacyShiurURL)
        if case .shiur(let id) = legacyTarget {
            #expect(id == "1083921")
        } else {
            Issue.record("Expected .shiur target for legacy lecture URL")
        }

        let queryShiurURL = URL(string: "https://www.yutorah.org/showShiur.cfm?shiurid=1083921")!
        let queryTarget = YUTorahURLResolver.resolve(url: queryShiurURL)
        if case .shiur(let id) = queryTarget {
            #expect(id == "1083921")
        } else {
            Issue.record("Expected .shiur target for showShiur query URL")
        }
    }

    @Test func testResolveRSSFeedURL() {
        let rssURL = URL(string: "https://www.yutorah.org/rss/RecentAudioShiurim")!
        let target = YUTorahURLResolver.resolve(url: rssURL)
        #expect(target != nil)
        if case .rssFeed(let url) = target {
            #expect(url == rssURL)
        } else {
            Issue.record("Expected .rssFeed target for RSS URL")
        }
    }

    @Test func testSeriesCandidateFeeds() {
        let candidates = YUTorahURLResolver.seriesFeedCandidateURLs(seriesID: 456)
        #expect(candidates.count >= 2)
        #expect(candidates.contains(where: { $0.absoluteString.contains("seriesID=456") }))
    }

    @Test func testResolveCollectionURL() {
        let directURL = URL(string: "https://www.yutorah.org/collection/5001/")!
        let target = YUTorahURLResolver.resolve(url: directURL)
        if case .collection(let id) = target {
            #expect(id == 5001)
        } else {
            Issue.record("Expected .collection target for direct collection URL")
        }

        let queryURL = URL(string: "https://www.yutorah.org/lectures/?collectionID=5001")!
        let queryTarget = YUTorahURLResolver.resolve(url: queryURL)
        if case .collection(let id) = queryTarget {
            #expect(id == 5001)
        } else {
            Issue.record("Expected .collection target for collection query URL")
        }

        let categoryURL = URL(string: "https://www.yutorah.org/categories/5005/")!
        let categoryTarget = YUTorahURLResolver.resolve(url: categoryURL)
        if case .collection(let id) = categoryTarget {
            #expect(id == 5005)
        } else {
            Issue.record("Expected .collection target for category URL")
        }
    }

    @Test func testCollectionCandidateFeeds() {
        let candidates = YUTorahURLResolver.collectionFeedCandidateURLs(collectionID: 5001)
        #expect(candidates.count >= 3)
        #expect(candidates.contains(where: { $0.absoluteString.contains("collectionID=5001") }))
        #expect(candidates.contains(where: { $0.absoluteString.contains("seriesID=5001") }))
        #expect(candidates.contains(where: { $0.absoluteString.contains("categoryID=5001") }))
    }

    @Test func testShiurIDExtraction() {
        #expect(YUTorahURLResolver.extractShiurID(from: "https://www.yutorah.org/lectures/1054321/") == "1054321")
        #expect(YUTorahURLResolver.extractShiurID(from: "https://classic.yutorah.org/lectures/lecture.cfm/1054321") == "1054321")
        #expect(YUTorahURLResolver.extractShiurID(from: "https://www.yutorah.org/showShiur.cfm?shiurid=1054321") == "1054321")
        #expect(YUTorahURLResolver.extractShiurID(from: "https://download.yutorah.org/2026/10/1054321/audio.mp3") == "1054321")
        #expect(YUTorahURLResolver.extractShiurID(from: "1054321") == "1054321")
        #expect(YUTorahURLResolver.extractShiurID(from: "invalid-url") == nil)
    }

    @Test func testSidebarLectureDataShiurResolution() {
        let rawURLString = "https://www.yutorah.org/sidebar/lecturedata/1187085/Shiur-#1%D7%91%D7%99%D7%A9%D7%95%D7%9C-%D7%90%D7%97%D7%A8-%D7%91%D7%99%D7%A9%D7%95%D7%9C"
        #expect(YUTorahURLResolver.extractShiurID(from: rawURLString) == "1187085")

        let resolved = YUTorahURLResolver.resolve(url: URL(string: rawURLString)!)
        if case .shiur(let id) = resolved {
            #expect(id == "1187085")
        } else {
            Issue.record("Expected .shiur target for sidebar lecturedata URL")
        }
    }

    @Test func testHebrewAndIDSearch() async {
        let service = YUTorahSearchService()
        let resultsByHebrew = await service.search(query: "בישול אחר בישול")
        let foundHebrewShiur = resultsByHebrew.contains {
            if case .shiur(let item) = $0 {
                return item.shiurID == "1187085" || item.title.contains("בישול אחר בישול")
            }
            return false
        }
        #expect(foundHebrewShiur, "Expected to find Shiur #1 - בישול אחר בישול when searching in Hebrew")

        let resultsByID = await service.search(query: "1187085")
        let foundIDShiur = resultsByID.contains {
            if case .shiur(let item) = $0 {
                return item.shiurID == "1187085"
            }
            return false
        }
        #expect(foundIDShiur, "Expected to find Shiur 1187085 when searching by ID")
    }

    @Test func testResolveTeacherAndCollectionURL() {
        let url = URL(string: "https://www.yutorah.org/search/?teacher=80177&collection=15365")!
        let resolved = YUTorahURLResolver.resolve(url: url)
        if case .collection(let id) = resolved {
            #expect(id == 15365, "Expected collection ID 15365 even when teacher= parameter is also present")
        } else {
            Issue.record("Expected .collection(15365) from search URL with collection=15365")
        }
    }

    @Test func testSearchCollectionRavShulmanPerekKirah() async {
        let service = YUTorahSearchService()
        let results = await service.search(query: "Rav Shulman Perek Kirah 5786-7")
        let foundCollection = results.contains {
            if case .collection(let id, let title, _, _) = $0 {
                return id == 15365 && title.contains("Perek Kirah")
            }
            return false
        }
        #expect(foundCollection, "Expected to discover collection 15365 when searching for 'Rav Shulman Perek Kirah 5786-7'")
    }

    @Test func testCadenceDefaultAndPresets() {
        let defaultCadence = ShiurSubscriptionCadence.daily
        #expect(defaultCadence.rawValue == 24)
        #expect(ShiurSubscriptionCadence(rawValue: 1) == .everyHour)
        #expect(ShiurSubscriptionCadence(rawValue: 12) == .every12Hours)
        #expect(ShiurSubscriptionCadence(rawValue: 24) == .daily)
        #expect(ShiurSubscriptionCadence(rawValue: 48) == .every2Days)
        #expect(ShiurSubscriptionCadence(rawValue: 168) == .weekly)
    }

    // MARK: - 2. RSS Parser Tests

    @Test func testParseRSSFeedWithHebrewAndEnclosures() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
            <channel>
                <title>Shiurim of Rabbi Hershel Schachter</title>
                <link>https://www.yutorah.org/rabbi-hershel-schachter/</link>
                <description>Recent Torah lectures</description>
                <item>
                    <title>הלכות שבת: אמירה לנכרי</title>
                    <link>https://www.yutorah.org/lectures/1099881/</link>
                    <guid isPermaLink="false">yutorah-1099881</guid>
                    <pubDate>Mon, 02 Mar 2026 14:30:00 GMT</pubDate>
                    <itunes:author>Rabbi Hershel Schachter</itunes:author>
                    <itunes:duration>45:12</itunes:duration>
                    <enclosure url="https://download.yutorah.org/2026/1099881/shabbos.mp3" length="32654321" type="audio/mpeg"/>
                </item>
                <item>
                    <title>Pesachim 10a: Chometz and Bedikah</title>
                    <link>https://classic.yutorah.org/lectures/lecture.cfm?shiurid=1099882</link>
                    <guid>https://www.yutorah.org/lectures/1099882/</guid>
                    <pubDate>Sun, 01 Mar 2026 10:00:00 GMT</pubDate>
                    <author>Schachter, Rabbi Hershel</author>
                    <itunes:duration>2712</itunes:duration>
                    <enclosure url="https://download.yutorah.org/2026/1099882/pesachim.mp3" length="21000000" type="audio/mp3"/>
                </item>
            </channel>
        </rss>
        """

        let result = YUTorahRSSParser.parse(data: Data(xml.utf8))

        #expect(result != nil)
        #expect(result?.channelTitle == "Shiurim of Rabbi Hershel Schachter")
        #expect(result?.items.count == 2)

        let first = result!.items[0]
        #expect(first.shiurID == "1099881")
        #expect(first.title == "הלכות שבת: אמירה לנכרי")
        #expect(first.enclosureURL?.absoluteString == "https://download.yutorah.org/2026/1099881/shabbos.mp3")
        #expect(first.enclosureLength == 32654321)
        #expect(first.teacherName == "Rabbi Hershel Schachter")
        #expect(first.duration == 2712.0)

        let second = result!.items[1]
        #expect(second.shiurID == "1099882")
        #expect(second.title == "Pesachim 10a: Chometz and Bedikah")
        #expect(second.duration == 2712.0)
    }

    // MARK: - 3. Fuzzy Matcher Tests

    @Test func testNormalizationAndHonorificStripping() {
        let name1 = "Rabbi Hershel Schachter"
        let name2 = "Rav Hershel Schachter"
        let name3 = "Harav Hershel Schachter"
        let name4 = "Dr. Rabbi Hershel Schachter"

        let norm1 = YUTorahFuzzyMatcher.normalize(name1)
        let norm2 = YUTorahFuzzyMatcher.normalize(name2)
        let norm3 = YUTorahFuzzyMatcher.normalize(name3)
        let norm4 = YUTorahFuzzyMatcher.normalize(name4)

        #expect(norm1 == "hershel schachter")
        #expect(norm2 == "hershel schachter")
        #expect(norm3 == "hershel schachter")
        #expect(norm4 == "hershel schachter")
    }

    @Test func testDamerauLevenshteinDistance() {
        // Transposition: distance 1
        #expect(YUTorahFuzzyMatcher.damerauLevenshteinDistance("schacter", "schatcer") == 1)
        // Single typo
        #expect(YUTorahFuzzyMatcher.damerauLevenshteinDistance("schachter", "schacter") == 1)
        // Identical
        #expect(YUTorahFuzzyMatcher.damerauLevenshteinDistance("rosensweig", "rosensweig") == 0)
    }

    @Test func testTeacherFuzzyTypoMatch() {
        let index = YUTorahSearchIndex.shared

        // Typo: "Hershel Schacter"
        let schachterMatches = index.findTeachers(query: "Hershel Schacter")
        #expect(!schachterMatches.isEmpty)
        #expect(schachterMatches.first?.entry.name.contains("Schachter") == true)
        #expect(schachterMatches.first!.score > 0.8)

        // Transposition: "Mordechei Willig"
        let willigMatches = index.findTeachers(query: "Mordechei Willig")
        #expect(!willigMatches.isEmpty)
        #expect(willigMatches.first?.entry.name.contains("Willig") == true)

        // Single name: "Rosensweig"
        let rosensweigMatches = index.findTeachers(query: "Rosensweig")
        #expect(!rosensweigMatches.isEmpty)
        #expect(rosensweigMatches.first?.entry.name.contains("Rosensweig") == true)
    }

    @Test func testTransliterationAliases() {
        let norm1 = YUTorahFuzzyMatcher.normalize("Hilchos Shabbos")
        let norm2 = YUTorahFuzzyMatcher.normalize("Hilchot Shabbat")

        // Both normalize to the canonical transliteration "shabbos"
        #expect(norm1 == "hilchos shabbos")
        #expect(norm2 == "hilchos shabbos")
        #expect(norm1 == norm2)
    }

    @Test func testWeakSimilarityDoesNotTriggerMatch() {
        let index = YUTorahSearchIndex.shared

        // Totally unrelated query should return low score or empty
        let matches = index.findTeachers(query: "Quantum Mechanics and Calculus")
        let confidentMatch = matches.first(where: { $0.isConfident })
        #expect(confidentMatch == nil)
    }

    @Test func testSeriesSearch() {
        let index = YUTorahSearchIndex.shared

        let matches = index.findSeries(query: "Hilchos Shabbos")
        #expect(!matches.isEmpty)
        #expect(matches.first?.entry.id == 4000)
    }

    @Test func testCollectionFuzzySearchAndSeeding() {
        let index = YUTorahSearchIndex.shared

        let dafYomiMatches = index.findCollections(query: "Daf Yomi")
        #expect(!dafYomiMatches.isEmpty)
        #expect(dafYomiMatches.first?.entry.id == 5001)

        let pesachMatches = index.findCollections(query: "Passover Haggadah")
        #expect(!pesachMatches.isEmpty)
        #expect(pesachMatches.first?.entry.id == 5005)

        let halachaMatches = index.findCollections(query: "Five Minute Halacha")
        #expect(!halachaMatches.isEmpty)
        #expect(halachaMatches.first?.entry.id == 5003)
    }

    // MARK: - 4. Search Parser Tests

    @Test func testSearchHTMLParserExtractsResults() {
        let html = """
        <html>
        <body>
            <div class="teacher-result">
                <a href="/search/?teacherID=80056">Rabbi Hershel Schachter</a>
            </div>
            <div class="series-result">
                <a href="/search/?seriesID=1002">Hilchos Berachos</a>
            </div>
            <div class="lecture-result">
                <a href="/lectures/1083921/">Pesachim 15a: Chametz After Midnight</a>
            </div>
        </body>
        </html>
        """

        let results = YUTorahSearchParser.parseHTMLSearch(html: html)
        #expect(results.count >= 2)

        let hasTeacher = results.contains {
            if case .teacher(let id, let name, _, _) = $0 {
                return id == 80056 && name.contains("Schachter")
            }
            return false
        }
        #expect(hasTeacher)

        let hasSeries = results.contains {
            if case .series(let id, let title, _, _) = $0 {
                return id == 1002 && title.contains("Berachos")
            }
            return false
        }
        #expect(hasSeries)

        let hasShiur = results.contains {
            if case .shiur(let item) = $0 {
                return item.shiurID == "1083921"
            }
            return false
        }
        #expect(hasShiur)
    }

    // MARK: - 5. Media Resolver Tests

    @Test func testMediaResolverDirectEnclosure() async {
        let resolver = YUTorahMediaResolver()
        let item = RemoteShiurItem(
            shiurID: "1083921",
            title: "Pesachim 15a",
            teacherName: "Rabbi Hershel Schachter",
            seriesName: nil,
            date: Date(),
            duration: 1800,
            pageURL: URL(string: "https://www.yutorah.org/lectures/1083921/"),
            enclosureURL: URL(string: "https://download.yutorah.org/2026/1083921/audio.mp3")
        )

        let resolved = try? await resolver.resolveMediaURL(for: item)
        #expect(resolved?.absoluteString == "https://download.yutorah.org/2026/1083921/audio.mp3")
    }

    // MARK: - 6. Subscription Model Tests

    @Test func testSubscriptionDueIntervalCalculations() {
        let subHourly = ShiurSubscription(
            targetType: .teacher,
            targetNumericID: 80056,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?teacher=80056",
            displayName: "Hourly Shiur",
            intervalHours: 1
        )

        // Brand new subscription with nil lastCheckedAt is due
        #expect(subHourly.isDue())

        // Just checked -> not due
        subHourly.lastCheckedAt = Date()
        #expect(!subHourly.isDue())

        // 2 hours ago -> due
        subHourly.lastCheckedAt = Date().addingTimeInterval(-7200)
        #expect(subHourly.isDue())

        // 12-hour cadence
        let subTwiceDaily = ShiurSubscription(
            targetType: .series,
            targetNumericID: 1002,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?seriesID=1002",
            displayName: "Twice Daily Shiur",
            intervalHours: 12
        )
        // 6 hours ago -> not due
        subTwiceDaily.lastCheckedAt = Date().addingTimeInterval(-21600)
        #expect(!subTwiceDaily.isDue())

        // 13 hours ago -> due
        subTwiceDaily.lastCheckedAt = Date().addingTimeInterval(-46800)
        #expect(subTwiceDaily.isDue())
    }

    @Test func testSubscriptionSeenIDsBoundedStorage() {
        let sub = ShiurSubscription(
            targetType: .teacher,
            targetNumericID: 80056,
            resolvedFeedURLString: "https://www.yutorah.org/rss/test",
            displayName: "Test Subscription"
        )

        #expect(!sub.hasSeen(itemID: "1001"))

        sub.markSeen(itemIDs: ["1001", "1002", "1003"])
        #expect(sub.hasSeen(itemID: "1001"))
        #expect(sub.hasSeen(itemID: "1002"))
        #expect(sub.hasSeen(itemID: "1003"))
        #expect(!sub.hasSeen(itemID: "1004"))

        // Bounded capacity: test adding 1200 items trims to 1000
        let manyIDs = (2000..<3200).map { String($0) }
        sub.markSeen(itemIDs: manyIDs)

        // Most recent should exist
        #expect(sub.hasSeen(itemID: "3199"))
        // Oldest ("1001") should have been pruned to stay under 1000 items
        #expect(!sub.hasSeen(itemID: "1001"))
    }

    // MARK: - 7. ShiurAutomationItem State Machine Tests

    @Test func testAutomationItemInitialStateAndTransitions() {
        let item = ShiurAutomationItem(
            sourceKey: "yutorah:1083921",
            shiurID: "1083921",
            title: "Pesachim 15a",
            teacherName: "Rabbi Hershel Schachter",
            seriesName: "Daf Yomi",
            publicationDate: Date(),
            mediaURLString: "https://download.yutorah.org/audio.mp3",
            state: .discovered,
            autoTranscribe: true,
            autoGenerateNotes: true
        )

        #expect(item.state == .discovered)
        #expect(item.shiurID == "1083921")
        #expect(item.sourceKey == "yutorah:1083921")

        item.state = .downloading
        #expect(item.state == .downloading)

        item.state = .imported
        #expect(item.state == .imported)

        item.state = .waitingForTranscription
        #expect(item.state == .waitingForTranscription)

        item.state = .transcribing
        #expect(item.state == .transcribing)

        item.state = .waitingForNotes
        #expect(item.state == .waitingForNotes)

        item.state = .generatingNotes
        #expect(item.state == .generatingNotes)

        item.state = .complete
        #expect(item.state == .complete)
    }

    // MARK: - 8. Deduplication & Retention Date Logic Tests

    @Test func testGlobalDeduplicationKey() {
        let key1 = RemoteShiurItem(
            shiurID: "999123",
            title: "Shiur A",
            date: Date()
        ).sourceKey

        let key2 = RemoteShiurItem(
            shiurID: "999123",
            title: "Shiur A - Reposted in Series",
            date: Date()
        ).sourceKey

        #expect(key1 == "yutorah:999123")
        #expect(key1 == key2)
    }

    @Test func testRetentionDateSemantics() {
        // Lecture date is historic shiur recording date (e.g. from 2018)
        let historicDate = Date(timeIntervalSince1970: 1514764800) // Jan 1, 2018
        let lecture = Lecture(
            title: "Historic Shiur",
            capturedAt: historicDate,
            language: .english
        )
        lecture.sourceProviderRaw = "yutorah"
        lecture.sourceKey = "yutorah:776655"
        lecture.sourceMediaURL = "https://download.yutorah.org/776655.mp3"

        #expect(lecture.capturedAt == historicDate)
        #expect(lecture.isRemoteImport)

        // Local recording retention date is set to local import date (NOW)
        let localImportDate = Date()
        let recording = Recording(
            filePath: "/dummy/path.mp3",
            sampleRate: 44100,
            sizeBytes: 1024,
            recordedAt: localImportDate
        )
        lecture.recording = recording

        // The recording must NOT be considered 8 years old for retention pruning
        #expect(recording.recordedAt >= localImportDate.addingTimeInterval(-1))
        #expect(!recording.isPruned)
    }

    @MainActor
    @Test func testLaunchAtLoginManagerStatus() {
        // Test that checking isEnabled doesn't crash
        _ = LaunchAtLoginManager.shared.isEnabled
    }

    // MARK: - 9. Baseline, Model Relationships & Error Handling Tests

    @Test func testFirstRunFutureOnlyBaselineMarksCurrentItemsAsSeen() {
        let sub = ShiurSubscription(
            targetType: .teacher,
            targetNumericID: 80056,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?teacher=80056",
            displayName: "Rabbi Schachter"
        )

        // Baseline: mark existing items in feed as seen
        let existingFeedShiurIDs = ["101", "102", "103", "104"]
        sub.markSeen(itemIDs: existingFeedShiurIDs)

        // Future check: only new shiur 105 is not seen
        let incomingFeedShiurIDs = ["105", "104", "103", "102"]
        let newItems = incomingFeedShiurIDs.filter { !sub.hasSeen(itemID: $0) }

        #expect(newItems == ["105"])
    }

    @Test func testBacklogBaselineImportsExistingItems() {
        let sub = ShiurSubscription(
            targetType: .teacher,
            targetNumericID: 80056,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?teacher=80056",
            displayName: "Rabbi Schachter"
        )

        // Opting into backlog: seenItemIDs remains empty on creation
        #expect(sub.seenItemIDs.isEmpty)

        let incomingFeedShiurIDs = ["101", "102", "103"]
        let newItems = incomingFeedShiurIDs.filter { !sub.hasSeen(itemID: $0) }

        #expect(newItems.count == 3)
    }

    @Test func testDeduplicationAcrossTwoSubscriptions() {
        let teacherSub = ShiurSubscription(
            targetType: .teacher,
            targetNumericID: 80056,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?teacher=80056",
            displayName: "Rabbi Schachter"
        )
        let seriesSub = ShiurSubscription(
            targetType: .series,
            targetNumericID: 4000,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?seriesID=4000",
            displayName: "Hilchot Shabbat"
        )

        let shiurFromTeacher = RemoteShiurItem(
            shiurID: "205511",
            title: "Amira L'Nochri in Halacha",
            teacherName: "Rabbi Hershel Schachter",
            date: Date()
        )
        let shiurFromSeries = RemoteShiurItem(
            shiurID: "205511",
            title: "Hilchos Shabbos Shiur #14: Amira L'Nochri",
            seriesName: "Hilchot Shabbat",
            date: Date()
        )

        // Verify identical deduplication sourceKey
        #expect(shiurFromTeacher.sourceKey == "yutorah:205511")
        #expect(shiurFromSeries.sourceKey == "yutorah:205511")
        #expect(shiurFromTeacher.sourceKey == shiurFromSeries.sourceKey)

        // When teacher sub marks seen, series sub can still check its own seen list
        teacherSub.markSeen(itemIDs: [shiurFromTeacher.shiurID])
        #expect(teacherSub.hasSeen(itemID: "205511"))
        #expect(!seriesSub.hasSeen(itemID: "205511"))
    }

    @Test func testPrunedRecordingRedownloadEligibility() {
        let lecture = Lecture(
            title: "Pruned Lecture",
            capturedAt: Date(),
            language: .english
        )
        lecture.sourceProviderRaw = "yutorah"
        lecture.sourceKey = "yutorah:123456"
        lecture.sourceMediaURL = "https://download.yutorah.org/123456.mp3"
        lecture.sourcePageURL = "https://www.yutorah.org/lectures/123456/"

        let recording = Recording(
            filePath: "/pruned/file.mp3",
            sampleRate: 44100,
            sizeBytes: 0,
            recordedAt: Date()
        )
        recording.prunedAt = Date()
        lecture.recording = recording

        #expect(recording.isPruned)
        #expect(lecture.sourceMediaURL != nil)
        #expect(lecture.isRemoteImport)
    }

    @MainActor
    @Test func testCourseRelationshipNullifyOnCourseDeletion() throws {
        let schema = Schema([Course.self, ShiurSubscription.self, Lecture.self, Recording.self, Artifact.self, Flashcard.self, QuizItem.self, ChatMessage.self, LiveBookmark.self, ReferenceAttachment.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let course = Course(name: "Halacha 101", colorHex: "#3B82F6")
        context.insert(course)

        let sub = ShiurSubscription(
            targetType: .teacher,
            targetNumericID: 80056,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?teacher=80056",
            displayName: "Rabbi Schachter",
            course: course
        )
        context.insert(sub)
        try context.save()

        #expect(sub.course?.name == "Halacha 101")

        // Delete course: subscription must stay intact with course = nil
        context.delete(course)
        try context.save()

        #expect(sub.course == nil)
        #expect(sub.displayName == "Rabbi Schachter")
    }

    @Test func testDownloaderErrorDescriptions() {
        let err404 = RemoteAudioDownloaderError.invalidHTTPStatus(404)
        #expect(err404.errorDescription?.contains("404") == true)

        let errEmpty = RemoteAudioDownloaderError.emptyDownload
        #expect(errEmpty.errorDescription?.contains("0 bytes") == true)

        let errCorrupt = RemoteAudioDownloaderError.unreadableAudio("Corrupt header")
        #expect(errCorrupt.errorDescription?.contains("Corrupt header") == true)
    }

    @Test func testCollectionSubscriptionPersistence() {
        let collectionSub = ShiurSubscription(
            targetType: .collection,
            targetNumericID: 5001,
            resolvedFeedURLString: "https://www.yutorah.org/rss/RecentAudioShiurim?collectionID=5001",
            displayName: "Daf Yomi"
        )
        #expect(collectionSub.targetType == .collection)
        #expect(collectionSub.targetTypeRaw == "collection")
        #expect(collectionSub.targetType.displayName == "Collection")
    }

    @Test func testCollectionSubscriptionEntityResolution() async throws {
        let provider = YUTorahSourceProvider()
        let resolved = try await provider.resolveSubscription(for: .collection(id: 5001, title: "Daf Yomi"))
        #expect(resolved.targetType == .collection)
        #expect(resolved.targetNumericID == 5001)
        #expect(resolved.displayName == "Daf Yomi")
        #expect(resolved.feedURL.absoluteString.contains("5001"))
    }

    // MARK: - 10. Core API Faceted Search Tests

    @Test func testNameFormatterRabbiAndFirstLast() {
        #expect(YUTorahNameFormatter.format("Schachter, R' Hershel") == "Rabbi Hershel Schachter")
        #expect(YUTorahNameFormatter.format("Shulman, R' Eli Baruch") == "Rabbi Eli Baruch Shulman")
        #expect(YUTorahNameFormatter.format("Becker,  Asher") == "Asher Becker")
        #expect(YUTorahNameFormatter.format("Rabbi Hershel Schachter") == "Rabbi Hershel Schachter")
    }

    @Test func testFacetedSearchForRabbiSchachter() async {
        let service = YUTorahSearchService()
        let results = await service.searchStructured(query: "Rabbi Schachter", page: 1)

        #expect(results.totalShiurim > 1000, "Expected thousands of shiurim for Rabbi Schachter")
        #expect(!results.shiurim.isEmpty, "Expected page 1 shiurim to be populated")
        #expect(!results.teachers.isEmpty, "Expected matching teachers to be returned")
        #expect(!results.collections.isEmpty, "Expected matching collections to be returned")
        #expect(!results.series.isEmpty, "Expected matching series to be returned")

        let hasHershelSchachter = results.teachers.contains {
            $0.displayName.contains("Hershel Schachter") || $0.rawName.contains("Schachter")
        }
        #expect(hasHershelSchachter, "Expected Rabbi Hershel Schachter among teachers")
    }

    @Test func testTeacherDrilldownSearch() async {
        let service = YUTorahSearchService()
        // Drill down directly into Rabbi Hershel Schachter (ID 80153)
        let results = await service.searchStructured(query: "", teacherID: 80153, page: 1)

        #expect(results.totalShiurim >= 7000, "Expected >= 7000 shiurim for Rav Hershel Schachter")
        #expect(!results.collections.isEmpty, "Expected Rav Schachter's collections to be returned")
        #expect(!results.series.isEmpty, "Expected Rav Schachter's series to be returned")
        #expect(results.activeTeacher?.id == 80153)
    }

    @Test func testFetchCollectionShiurimDirect() async {
        let service = YUTorahSearchService()
        let items = await service.fetchCollectionShiurim(collectionID: 15365)

        #expect(items.count == 3, "Expected 3 shiurim in collection 15365 (Rav Shulman Perek Kirah)")
        let hasBishul = items.contains { $0.title.contains("בישול") }
        #expect(hasBishul, "Expected to find בישול אחר בישול shiur")
        #expect(items.first?.enclosureURL != nil, "Expected direct audio download URL")
    }
}

