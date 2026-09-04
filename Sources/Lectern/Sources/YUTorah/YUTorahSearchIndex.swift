import Foundation

struct YUTorahTeacherIndexEntry: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var aliases: [String]
    var shiurCount: Int?

    init(id: Int, name: String, aliases: [String] = [], shiurCount: Int? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.shiurCount = shiurCount
    }
}

struct YUTorahSeriesIndexEntry: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var title: String
    var teacherName: String?
    var aliases: [String]

    init(id: Int, title: String, teacherName: String? = nil, aliases: [String] = []) {
        self.id = id
        self.title = title
        self.teacherName = teacherName
        self.aliases = aliases
    }
}

struct YUTorahCollectionIndexEntry: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var title: String
    var collectionDescription: String?
    var aliases: [String]

    init(id: Int, title: String, collectionDescription: String? = nil, aliases: [String] = []) {
        self.id = id
        self.title = title
        self.collectionDescription = collectionDescription
        self.aliases = aliases
    }
}

final class YUTorahSearchIndex: @unchecked Sendable {
    static let shared = YUTorahSearchIndex()

    private let lock = NSLock()
    private var teachers: [YUTorahTeacherIndexEntry] = []
    private var seriesList: [YUTorahSeriesIndexEntry] = []
    private var collections: [YUTorahCollectionIndexEntry] = []
    private let cacheFileURL: URL

    init(cacheFileURL: URL? = nil) {
        if let cacheFileURL {
            self.cacheFileURL = cacheFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.cacheFileURL = appSupport.appendingPathComponent("Lectern/Data/yutorah_index_cache.json")
        }
        loadSeedCatalog()
        loadCachedCatalog()
    }

    private struct IndexPayload: Codable {
        let teachers: [YUTorahTeacherIndexEntry]
        let series: [YUTorahSeriesIndexEntry]
        var collections: [YUTorahCollectionIndexEntry]? = []
        let savedAt: Date
    }

    private func loadSeedCatalog() {
        teachers = [
            YUTorahTeacherIndexEntry(id: 80146, name: "Rabbi Michael Rosensweig", aliases: ["Michael Rosensweig", "Rosensweig", "R' Rosensweig"]),
            YUTorahTeacherIndexEntry(id: 80044, name: "Rabbi Hershel Schachter", aliases: ["Hershel Schachter", "Schachter", "R' Schachter", "Rav Schachter"]),
            YUTorahTeacherIndexEntry(id: 80182, name: "Rabbi Zvi Sobolofsky", aliases: ["Zvi Sobolofsky", "Sobolofsky", "Sobolovsky", "Soblofsky"]),
            YUTorahTeacherIndexEntry(id: 80218, name: "Rabbi Mordechai Willig", aliases: ["Mordechai Willig", "Willig", "Motti Willig"]),
            YUTorahTeacherIndexEntry(id: 80210, name: "Rabbi Mayer Twersky", aliases: ["Mayer Twersky", "Twersky", "Meir Twersky"]),
            YUTorahTeacherIndexEntry(id: 80130, name: "Rabbi Yaakov B. Neuburger", aliases: ["Yaakov Neuburger", "Neuburger", "Neuberger"]),
            YUTorahTeacherIndexEntry(id: 80572, name: "Rabbi Aryeh Lebowitz", aliases: ["Aryeh Lebowitz", "Lebowitz", "Leibowitz"]),
            YUTorahTeacherIndexEntry(id: 80061, name: "Rabbi Daniel Z. Feldman", aliases: ["Daniel Feldman", "Daniel Z Feldman", "Feldman"]),
            YUTorahTeacherIndexEntry(id: 80140, name: "Rabbi Dr. Aaron Rakeffet-Rothkoff", aliases: ["Aaron Rakeffet", "Rakeffet", "Rakefet", "Rothkoff"]),
            YUTorahTeacherIndexEntry(id: 80256, name: "Rabbi Assaf Bednarsh", aliases: ["Assaf Bednarsh", "Bednarsh"]),
            YUTorahTeacherIndexEntry(id: 80214, name: "Rabbi Jeremy Wieder", aliases: ["Jeremy Wieder", "Wieder"]),
            YUTorahTeacherIndexEntry(id: 80104, name: "Rabbi Eliakim Koenigsberg", aliases: ["Eliakim Koenigsberg", "Koenigsberg", "Konigsberg"]),
            YUTorahTeacherIndexEntry(id: 80173, name: "Rabbi Ezra Schwartz", aliases: ["Ezra Schwartz", "Schwartz"]),
            YUTorahTeacherIndexEntry(id: 80003, name: "Rabbi Elchanan Adler", aliases: ["Elchanan Adler", "Adler"]),
            YUTorahTeacherIndexEntry(id: 80178, name: "Rabbi Eli Baruch Shulman", aliases: ["Eli Baruch Shulman", "Shulman", "Rav Shulman", "R' Shulman"]),
            YUTorahTeacherIndexEntry(id: 80177, name: "Rabbi Eli Baruch Shulman", aliases: ["Eli Baruch Shulman", "Shulman", "Rav Shulman", "R' Shulman"]),
            YUTorahTeacherIndexEntry(id: 80204, name: "Rabbi Michael Taubes", aliases: ["Michael Taubes", "Taubes"]),
            YUTorahTeacherIndexEntry(id: 80179, name: "Rabbi Baruch Simon", aliases: ["Baruch Simon", "Simon"]),
            YUTorahTeacherIndexEntry(id: 80135, name: "Rabbi Menachem Penner", aliases: ["Menachem Penner", "Penner"]),
            YUTorahTeacherIndexEntry(id: 81072, name: "Rabbi Mordechai Torczyner", aliases: ["Mordechai Torczyner", "Torczyner"]),
            YUTorahTeacherIndexEntry(id: 80856, name: "Rabbi Shay Schachter", aliases: ["Shay Schachter"]),
            YUTorahTeacherIndexEntry(id: 80171, name: "Rabbi Dani Schreiber", aliases: ["Dani Schreiber", "Schreiber"]),
            YUTorahTeacherIndexEntry(id: 80857, name: "Rabbi Itamar Rosensweig", aliases: ["Itamar Rosensweig"]),
            YUTorahTeacherIndexEntry(id: 80072, name: "Rabbi Dovid Gottlieb", aliases: ["Dovid Gottlieb", "David Gottlieb"]),
            YUTorahTeacherIndexEntry(id: 80126, name: "Rabbi Jonathan Muskat", aliases: ["Jonathan Muskat", "Muskat"]),
            YUTorahTeacherIndexEntry(id: 80582, name: "Rabbi Eli Wagner", aliases: ["Eli Wagner", "Wagner"]),
            YUTorahTeacherIndexEntry(id: 80018, name: "Rabbi Dr. J. David Bleich", aliases: ["David Bleich", "J. David Bleich", "Bleich"]),
            YUTorahTeacherIndexEntry(id: 80070, name: "Rabbi Meir Goldwicht", aliases: ["Meir Goldwicht", "Goldwicht"]),
            YUTorahTeacherIndexEntry(id: 80087, name: "Rabbi David Horwitz", aliases: ["David Horwitz", "Horwitz"]),
            YUTorahTeacherIndexEntry(id: 80203, name: "Rabbi Moshe Taragin", aliases: ["Moshe Taragin", "Taragin"]),
            YUTorahTeacherIndexEntry(id: 80143, name: "Rabbi Yona Reiss", aliases: ["Yona Reiss", "Reiss"]),
            YUTorahTeacherIndexEntry(id: 80039, name: "Rabbi Shalom Carmy", aliases: ["Shalom Carmy", "Carmy"]),
            YUTorahTeacherIndexEntry(id: 80092, name: "Rabbi Aharon Kahn", aliases: ["Aharon Kahn", "Kahn"]),
            YUTorahTeacherIndexEntry(id: 80064, name: "Rabbi Joshua Flug", aliases: ["Joshua Flug", "Flug"]),
            YUTorahTeacherIndexEntry(id: 80028, name: "Rabbi Yitzchak Breitowitz", aliases: ["Yitzchak Breitowitz", "Breitowitz"]),
            YUTorahTeacherIndexEntry(id: 80165, name: "Rabbi Dr. Jacob J. Schacter", aliases: ["Jacob J. Schacter", "JJ Schacter", "Schacter"])
        ]

        seriesList = [
            YUTorahSeriesIndexEntry(id: 4025, title: "Kollel Yom Rishon", teacherName: "YU Roshei Yeshiva", aliases: ["KYR", "Sunday Kollel"]),
            YUTorahSeriesIndexEntry(id: 4026, title: "Midreshet Yom Rishon", teacherName: "YU Faculty", aliases: ["MYR"]),
            YUTorahSeriesIndexEntry(id: 4000, title: "Hilchot Shabbat", teacherName: "Rabbi Zvi Sobolofsky", aliases: ["Hilchos Shabbos", "Hilchot Shabbos", "Shabbos Halacha"]),
            YUTorahSeriesIndexEntry(id: 4050, title: "Medical Halacha", teacherName: "Rabbi Dr. J. David Bleich", aliases: ["Bioethics", "Medicine and Halacha"]),
            YUTorahSeriesIndexEntry(id: 4060, title: "Business Halacha & Ethics", teacherName: "Rabbi Daniel Z. Feldman", aliases: ["Choshen Mishpat", "Commercial Halacha"]),
            YUTorahSeriesIndexEntry(id: 4100, title: "Kashrus in the Modern Kitchen", teacherName: "Rabbi Ezra Schwartz", aliases: ["Kashrus", "Kosher"]),
            YUTorahSeriesIndexEntry(id: 4010, title: "Contemporary Halakhic Issues", teacherName: "Rabbi Michael Rosensweig", aliases: ["Modern Halacha"]),
            YUTorahSeriesIndexEntry(id: 4020, title: "Parshat Hashavua Series", teacherName: "Rabbi Hershel Schachter", aliases: ["Parsha", "Weekly Parsha"]),
            YUTorahSeriesIndexEntry(id: 4030, title: "Rambam Mishneh Torah", teacherName: "Rabbi David Horwitz", aliases: ["Mishneh Torah", "Yad Hachazakah"]),
            YUTorahSeriesIndexEntry(id: 4040, title: "Gemara B'Iyun", teacherName: "Rabbi Mayer Twersky", aliases: ["Talmud In-Depth", "Iyun"])
        ]

        collections = [
            YUTorahCollectionIndexEntry(id: 5001, title: "Daf Yomi", collectionDescription: "Daily Talmud study across Shas", aliases: ["Talmud Daf Yomi", "Daf", "Gemara Daily"]),
            YUTorahCollectionIndexEntry(id: 5002, title: "Mishna Yomi", collectionDescription: "Daily Mishna study across Seder Moed, Nashim, Nezikin", aliases: ["Mishna", "Mishnah Yomi"]),
            YUTorahCollectionIndexEntry(id: 5003, title: "Five Minute Halacha", collectionDescription: "Short daily halachic insights by Rabbi Aryeh Lebowitz and guests", aliases: ["5 Minute Halacha", "Lebowitz Halacha"]),
            YUTorahCollectionIndexEntry(id: 5004, title: "Ten Minute Torah", collectionDescription: "Concise daily Torah thoughts and insights", aliases: ["10 Minute Torah", "Short Shiurim"]),
            YUTorahCollectionIndexEntry(id: 5005, title: "Pesach & Haggadah Collection", collectionDescription: "Shiurim for Passover, Seder, Hagadah, and Halacha", aliases: ["Passover", "Haggadah", "Seder", "Chometz", "Matzah"]),
            YUTorahCollectionIndexEntry(id: 5006, title: "Yamim Noraim & Tishrei Collection", collectionDescription: "Rosh Hashana, Yom Kippur, and Sukkot collection", aliases: ["High Holidays", "Rosh Hashanah", "Yom Kippur", "Sukkot", "Sukkah"]),
            YUTorahCollectionIndexEntry(id: 5007, title: "Chanukah Collection", collectionDescription: "Halacha, Pirsumei Nisa, and Machshava for Chanukah", aliases: ["Hanukkah", "Menorah", "Chanuka"]),
            YUTorahCollectionIndexEntry(id: 5008, title: "Purim & Megillat Esther", collectionDescription: "Megillat Esther, Purim Halacha and Derashot", aliases: ["Megillah", "Esther", "Purim Shiurim"]),
            YUTorahCollectionIndexEntry(id: 5009, title: "Shavuot & Megillat Ruth", collectionDescription: "Matan Torah, Akdamut, and Megillat Ruth", aliases: ["Shavuos", "Ruth", "Torah Study"]),
            YUTorahCollectionIndexEntry(id: 5010, title: "Tisha B'Av & The Three Weeks", collectionDescription: "Kinot, Eichah, destruction of the Temple, and mourning halachot", aliases: ["Three Weeks", "9 Av", "Nine Days", "Kinot"]),
            YUTorahCollectionIndexEntry(id: 5011, title: "Medical Halacha & Bioethics", collectionDescription: "Bioethics, end of life, organ donation, and modern medicine", aliases: ["Bioethics", "Medicine and Halacha", "Medical Ethics"]),
            YUTorahCollectionIndexEntry(id: 5012, title: "Business Halacha & Choshen Mishpat", collectionDescription: "Commerce, contracts, copyright, and workplace halacha", aliases: ["Commercial Halacha", "Money in Halacha", "Choshen Mishpat"]),
            YUTorahCollectionIndexEntry(id: 5013, title: "Kashrus in the Modern Kitchen", collectionDescription: "Commercial food supervision, meat and milk, appliances", aliases: ["Kosher", "Kitchen Halacha", "Kashrut"]),
            YUTorahCollectionIndexEntry(id: 5014, title: "Contemporary Halakhic Issues", collectionDescription: "Modern halachic questions addressed by leading Poskim", aliases: ["Contemporary Halacha", "Modern Halakhah"]),
            YUTorahCollectionIndexEntry(id: 5015, title: "Kollel Yom Rishon Collection", collectionDescription: "Sunday community lecture series with YU Roshei Yeshiva", aliases: ["KYR", "Sunday Kollel"]),
            YUTorahCollectionIndexEntry(id: 5016, title: "Midreshet Yom Rishon Collection", collectionDescription: "Sunday women's study program with renowned educators", aliases: ["MYR", "Sunday Midrasha"]),
            YUTorahCollectionIndexEntry(id: 5017, title: "Hakotel Community Conferences", collectionDescription: "Annual community shiurim from the Old City of Jerusalem", aliases: ["Hakotel", "Kotel Conference"]),
            YUTorahCollectionIndexEntry(
                id: 15365,
                title: "Rav Shulman Perek Kirah 5786-7",
                collectionDescription: "Rabbi Eli Baruch Shulman · Shabbat Perek Kirah Daily Shiurim",
                aliases: [
                    "Perek Kirah",
                    "Perek Kirah 5786-7",
                    "Perek Kirah 5786",
                    "Rav Shulman Perek Kirah",
                    "Rabbi Shulman Perek Kirah",
                    "Shulman Kirah",
                    "Kirah 5786-7",
                    "Kirah"
                ]
            )
        ]
    }

    private func loadCachedCatalog() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path),
              let data = try? Data(contentsOf: cacheFileURL),
              let payload = try? JSONDecoder().decode(IndexPayload.self, from: data) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        var teacherMap = Dictionary(uniqueKeysWithValues: teachers.map { ($0.id, $0) })
        for item in payload.teachers {
            teacherMap[item.id] = item
        }
        teachers = Array(teacherMap.values)

        var seriesMap = Dictionary(uniqueKeysWithValues: seriesList.map { ($0.id, $0) })
        for item in payload.series {
            seriesMap[item.id] = item
        }
        seriesList = Array(seriesMap.values)

        if let cachedCollections = payload.collections {
            var colMap = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
            for item in cachedCollections {
                colMap[item.id] = item
            }
            collections = Array(colMap.values)
        }
    }

    func persist() {
        lock.lock()
        let payload = IndexPayload(teachers: teachers, series: seriesList, collections: collections, savedAt: Date())
        lock.unlock()

        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: cacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    func registerTeacher(id: Int, name: String, shiurCount: Int? = nil) {
        lock.lock()
        defer {
            lock.unlock()
            persist()
        }
        if let idx = teachers.firstIndex(where: { $0.id == id }) {
            teachers[idx].name = name
            if let shiurCount { teachers[idx].shiurCount = shiurCount }
        } else {
            teachers.append(YUTorahTeacherIndexEntry(id: id, name: name, shiurCount: shiurCount))
        }
    }

    func registerSeries(id: Int, title: String, teacherName: String? = nil) {
        lock.lock()
        defer {
            lock.unlock()
            persist()
        }
        if let idx = seriesList.firstIndex(where: { $0.id == id }) {
            seriesList[idx].title = title
            if let teacherName { seriesList[idx].teacherName = teacherName }
        } else {
            seriesList.append(YUTorahSeriesIndexEntry(id: id, title: title, teacherName: teacherName))
        }
    }

    func registerCollection(id: Int, title: String, description: String? = nil) {
        lock.lock()
        defer {
            lock.unlock()
            persist()
        }
        if let idx = collections.firstIndex(where: { $0.id == id }) {
            collections[idx].title = title
            if let description { collections[idx].collectionDescription = description }
        } else {
            collections.append(YUTorahCollectionIndexEntry(id: id, title: title, collectionDescription: description))
        }
    }

    func teacher(forID id: Int) -> YUTorahTeacherIndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        return teachers.first(where: { $0.id == id })
    }

    func series(forID id: Int) -> YUTorahSeriesIndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        return seriesList.first(where: { $0.id == id })
    }

    func collection(forID id: Int) -> YUTorahCollectionIndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        return collections.first(where: { $0.id == id })
    }

    // MARK: - Fuzzy Search

    func findTeachers(query: String, limit: Int = 10) -> [(entry: YUTorahTeacherIndexEntry, score: Double, isConfident: Bool)] {
        lock.lock()
        let currentTeachers = teachers
        lock.unlock()

        var scored: [(entry: YUTorahTeacherIndexEntry, score: Double, isConfident: Bool)] = []

        for teacher in currentTeachers {
            var bestScore = YUTorahFuzzyMatcher.score(query: query, candidate: teacher.name)
            for alias in teacher.aliases {
                let aliasScore = YUTorahFuzzyMatcher.score(query: query, candidate: alias)
                if aliasScore.score > bestScore.score {
                    bestScore = aliasScore
                }
            }

            if query == String(teacher.id) {
                bestScore = MatchResult(score: 1.0, isConfident: true)
            }

            if bestScore.score > 0.40 {
                scored.append((teacher, bestScore.score, bestScore.isConfident))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }

    func findSeries(query: String, limit: Int = 10) -> [(entry: YUTorahSeriesIndexEntry, score: Double, isConfident: Bool)] {
        lock.lock()
        let currentSeries = seriesList
        lock.unlock()

        var scored: [(entry: YUTorahSeriesIndexEntry, score: Double, isConfident: Bool)] = []

        for series in currentSeries {
            var bestScore = YUTorahFuzzyMatcher.score(query: query, candidate: series.title)
            if let teacher = series.teacherName {
                let combinedScore = YUTorahFuzzyMatcher.score(query: query, candidate: "\(series.title) \(teacher)")
                if combinedScore.score > bestScore.score {
                    bestScore = combinedScore
                }
            }
            for alias in series.aliases {
                let aliasScore = YUTorahFuzzyMatcher.score(query: query, candidate: alias)
                if aliasScore.score > bestScore.score {
                    bestScore = aliasScore
                }
            }

            if query == String(series.id) {
                bestScore = MatchResult(score: 1.0, isConfident: true)
            }

            if bestScore.score > 0.40 {
                scored.append((series, bestScore.score, bestScore.isConfident))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }

    func findCollections(query: String, limit: Int = 10) -> [(entry: YUTorahCollectionIndexEntry, score: Double, isConfident: Bool)] {
        lock.lock()
        let currentCollections = collections
        lock.unlock()

        var scored: [(entry: YUTorahCollectionIndexEntry, score: Double, isConfident: Bool)] = []

        for col in currentCollections {
            var bestScore = YUTorahFuzzyMatcher.score(query: query, candidate: col.title)
            if let desc = col.collectionDescription {
                let combinedScore = YUTorahFuzzyMatcher.score(query: query, candidate: "\(col.title) \(desc)")
                if combinedScore.score > bestScore.score {
                    bestScore = combinedScore
                }
            }
            for alias in col.aliases {
                let aliasScore = YUTorahFuzzyMatcher.score(query: query, candidate: alias)
                if aliasScore.score > bestScore.score {
                    bestScore = aliasScore
                }
            }

            if query == String(col.id) {
                bestScore = MatchResult(score: 1.0, isConfident: true)
            }

            if bestScore.score > 0.40 {
                scored.append((col, bestScore.score, bestScore.isConfident))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }
}
