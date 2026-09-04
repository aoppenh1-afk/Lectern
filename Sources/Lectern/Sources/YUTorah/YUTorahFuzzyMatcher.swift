import Foundation

struct MatchResult: Comparable, Sendable {
    let score: Double
    let isConfident: Bool

    static func < (lhs: MatchResult, rhs: MatchResult) -> Bool {
        lhs.score < rhs.score
    }
}

enum YUTorahFuzzyMatcher {
    static let confidenceThreshold = 0.68
    static let highConfidenceThreshold = 0.80

    private static let honorificPrefixes: Set<String> = [
        "rabbi", "rav", "r", "dr", "reb", "harav", "dayan", "rosh", "yeshiva",
        "ztl", "shlita", "prof", "professor"
    ]

    private static let transliterationAliases: [String: String] = [
        "shabbat": "shabbos", "shabat": "shabbos", "shabbath": "shabbos",
        "sukkot": "sukkos", "succot": "sukkos", "succos": "sukkos",
        "parashah": "parsha", "parashat": "parsha", "parshas": "parsha",
        "hanukkah": "chanukah", "chanuka": "chanukah", "hanuka": "chanukah",
        "passover": "pesach", "pesakh": "pesach",
        "shavuot": "shavuos", "shevuot": "shavuos", "shevuos": "shavuos",
        "hilchot": "hilchos", "halakha": "halacha", "halakhot": "halachos", "halachot": "halachos",
        "tefilah": "tefillah", "tefilot": "tefillos", "tefillot": "tefillos",
        "humash": "chumash",
        "berakhot": "brachos", "berachot": "brachos", "brakhot": "brachos", "brachot": "brachos",
        "kashrut": "kashrus",
        "shema": "shma",
        "bava": "baba",
        "metzia": "metziah",
        "kidushin": "kiddushin",
        "kesuvos": "ketubot", "ketubos": "ketubot", "kesubot": "ketubot",
        "nidah": "niddah",
        "mikveh": "mikvah",
        "rakeffet": "rakefet", "rothkoff": "rotkoff"
    ]

    // MARK: - Normalization

    static func normalize(_ string: String, removeHonorifics: Bool = true) -> String {
        var text = string
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()

        // Replace hyphens, apostrophes, underscores, quotes with spaces or strip them
        text = text.replacingOccurrences(of: "'", with: "")
        text = text.replacingOccurrences(of: "’", with: "")
        text = text.replacingOccurrences(of: "\"", with: "")
        text = text.replacingOccurrences(of: "-", with: " ")
        text = text.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: ".", with: " ")
        text = text.replacingOccurrences(of: ",", with: " ")

        // Split tokens
        let rawTokens = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        var filteredTokens: [String] = []

        for token in rawTokens {
            let aliasResolved = transliterationAliases[token] ?? token
            if removeHonorifics && honorificPrefixes.contains(aliasResolved) {
                continue
            }
            filteredTokens.append(aliasResolved)
        }

        return filteredTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func tokenize(_ string: String, removeHonorifics: Bool = true) -> [String] {
        let normalized = normalize(string, removeHonorifics: removeHonorifics)
        return normalized.split(separator: " ").map(String.init)
    }

    // MARK: - Scoring

    static func score(query: String, candidate: String) -> MatchResult {
        let normQuery = normalize(query)
        let normCandidate = normalize(candidate)

        if normQuery.isEmpty || normCandidate.isEmpty {
            return MatchResult(score: 0.0, isConfident: false)
        }

        // Exact match
        if normQuery == normCandidate {
            return MatchResult(score: 1.0, isConfident: true)
        }

        // Prefix match
        if normCandidate.hasPrefix(normQuery) || normQuery.hasPrefix(normCandidate) {
            let ratio = Double(min(normQuery.count, normCandidate.count)) / Double(max(normQuery.count, normCandidate.count))
            let score = 0.90 + (0.10 * ratio)
            return MatchResult(score: score, isConfident: true)
        }

        let queryTokens = tokenize(query)
        let candidateTokens = tokenize(candidate)

        // Token match: for each token in query, find best token match in candidate
        var tokenScores: [Double] = []
        for qToken in queryTokens {
            var bestTokenScore = 0.0
            for cToken in candidateTokens {
                let s = singleTokenScore(qToken, cToken)
                if s > bestTokenScore {
                    bestTokenScore = s
                }
            }
            tokenScores.append(bestTokenScore)
        }

        let avgTokenScore = tokenScores.isEmpty ? 0.0 : tokenScores.reduce(0, +) / Double(tokenScores.count)

        // Substring / n-gram trigram score
        let triScore = trigramSimilarity(normQuery, normCandidate)
        let dlScore = damerauLevenshteinSimilarity(normQuery, normCandidate)

        let overallScore = (avgTokenScore * 0.50) + (triScore * 0.30) + (dlScore * 0.20)
        let isConfident = overallScore >= confidenceThreshold && avgTokenScore >= 0.60

        return MatchResult(score: min(1.0, max(0.0, overallScore)), isConfident: isConfident)
    }

    private static func singleTokenScore(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if b.hasPrefix(a) || a.hasPrefix(b) {
            let minLen = Double(min(a.count, b.count))
            let maxLen = Double(max(a.count, b.count))
            return 0.85 + (0.15 * (minLen / maxLen))
        }
        let dl = damerauLevenshteinSimilarity(a, b)
        let tri = trigramSimilarity(a, b)
        return max(dl, tri)
    }

    // MARK: - Damerau-Levenshtein Edit Distance

    static func damerauLevenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let aCount = aChars.count
        let bCount = bChars.count

        if aCount == 0 { return bCount }
        if bCount == 0 { return aCount }

        var d = Array(repeating: Array(repeating: 0, count: bCount + 1), count: aCount + 1)

        for i in 0...aCount { d[i][0] = i }
        for j in 0...bCount { d[0][j] = j }

        for i in 1...aCount {
            for j in 1...bCount {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                d[i][j] = min(
                    d[i - 1][j] + 1,       // deletion
                    d[i][j - 1] + 1,       // insertion
                    d[i - 1][j - 1] + cost // substitution
                )
                if i > 1 && j > 1 && aChars[i - 1] == bChars[j - 2] && aChars[i - 2] == bChars[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) // transposition
                }
            }
        }

        return d[aCount][bCount]
    }

    static func damerauLevenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1.0 }
        let dist = damerauLevenshteinDistance(a, b)
        return max(0.0, 1.0 - (Double(dist) / Double(maxLen)))
    }

    // MARK: - Trigram Similarity

    static func trigramSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let triA = trigrams(of: a)
        let triB = trigrams(of: b)

        if triA.isEmpty || triB.isEmpty {
            return damerauLevenshteinSimilarity(a, b)
        }

        var intersection = 0
        var countsB = [String: Int]()
        for t in triB { countsB[t, default: 0] += 1 }

        for t in triA {
            if let count = countsB[t], count > 0 {
                intersection += 1
                countsB[t] = count - 1
            }
        }

        return (2.0 * Double(intersection)) / Double(triA.count + triB.count)
    }

    private static func trigrams(of string: String) -> [String] {
        let padded = "  " + string + " "
        let chars = Array(padded)
        guard chars.count >= 3 else { return [string] }
        var result: [String] = []
        for i in 0...(chars.count - 3) {
            result.append(String(chars[i..<(i + 3)]))
        }
        return result
    }
}
