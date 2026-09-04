import Foundation

enum YUTorahSearchParser {
    static func parseHTMLSearch(html: String) -> [ShiurDiscoveryResult] {
        var results: [ShiurDiscoveryResult] = []

        // Extract teachers: href="/search/?teacher=80182" or href=".../teacherID=80182" or <span class="teacherTitle">
        let teacherRegex = try? NSRegularExpression(
            pattern: #"href=["'][^"']*?[?&]teacher(?:id)?=(\d+)[^"']*["'][^>]*>([^<]+)</a>"#,
            options: .caseInsensitive
        )
        if let teacherRegex {
            let matches = teacherRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var seenTeachers = Set<Int>()
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let idRange = Range(match.range(at: 1), in: html),
                      let nameRange = Range(match.range(at: 2), in: html),
                      let id = Int(html[idRange]) else { continue }
                let name = html[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !seenTeachers.contains(id) {
                    seenTeachers.insert(id)
                    results.append(.teacher(id: id, name: name, shiurCount: nil, previewItems: []))
                }
            }
        }

        // Extract series: href="...[?&]series(?:id)?=(\d+)...">...</a>
        let seriesRegex = try? NSRegularExpression(
            pattern: #"href=["'][^"']*?[?&]series(?:id)?=(\d+)[^"']*["'][^>]*>([^<]+)</a>"#,
            options: .caseInsensitive
        )
        if let seriesRegex {
            let matches = seriesRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var seenSeries = Set<Int>()
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let idRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 2), in: html),
                      let id = Int(html[idRange]) else { continue }
                let title = html[titleRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, !seenSeries.contains(id) {
                    seenSeries.insert(id)
                    results.append(.series(id: id, title: title, teacherName: nil, previewItems: []))
                }
            }
        }

        // Extract shiurim: /lectures/(\d+)/([^"']+) or /lectures/lecture.cfm/(\d+)/([^"']+)
        let shiurRegex = try? NSRegularExpression(
            pattern: #"href=["'](?:https?://(?:www\.)?yutorah\.org)?/lectures/(?:lecture\.cfm/)?(\d+)/?([^"']*)["'][^>]*>([^<]+)</a>"#,
            options: .caseInsensitive
        )
        if let shiurRegex {
            let matches = shiurRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var seenShiurim = Set<String>()
            for match in matches {
                guard match.numberOfRanges >= 4,
                      let idRange = Range(match.range(at: 1), in: html),
                      let titleRange = Range(match.range(at: 3), in: html) else { continue }
                let shiurID = String(html[idRange])
                let rawTitle = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawTitle.isEmpty, !seenShiurim.contains(shiurID) {
                    seenShiurim.insert(shiurID)
                    let pageURL = URL(string: "https://www.yutorah.org/lectures/\(shiurID)")
                    let item = RemoteShiurItem(
                        shiurID: shiurID,
                        title: rawTitle,
                        teacherName: nil,
                        date: Date(),
                        pageURL: pageURL
                    )
                    results.append(.shiur(item: item))
                }
            }
        }

        return results
    }
}
