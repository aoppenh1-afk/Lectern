import Foundation

/// Only the named Time field is authoritative; the exported recurrence list is ignored.
struct CanvasZoomInvitation: Codable, Equatable, Sendable {
    let topic: String
    let host: String
    let startAt: Date
    let timeZoneID: String
    let joinURL: URL

    static func parse(_ text: String) -> [Self] {
        // HTML-to-text conversion can emit Unicode line/paragraph separators.
        // Normalize them so field values stop at the same boundaries as plain text.
        let normalizedText = text.components(separatedBy: .newlines).joined(separator: "\n")
        return normalizedText.components(separatedBy: "[Create Meeting]").dropFirst().compactMap { block in
            func field(_ name: String) -> String? {
                let pattern = "(?m)^\\s*" + name + ":\\s*([^\\r\\n]+)"
                guard let range = block.range(of: pattern, options: .regularExpression) else { return nil }
                return block[range].split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let topic = field("Topic"), let host = field("Host"),
                  let time = field("Time"), let rawURL = field("Join URL"),
                  let url = URL(string: rawURL), isZoomURL(url) else { return nil }
            let zones = [
                "Eastern Time (US and Canada)": "America/New_York",
                "Central Time (US and Canada)": "America/Chicago",
                "Mountain Time (US and Canada)": "America/Denver",
                "Pacific Time (US and Canada)": "America/Los_Angeles",
                "UTC": "UTC", "GMT": "GMT"
            ]
            guard let comma = time.lastIndex(of: ",") else { return nil }
            let zoneName = time[time.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            guard let zone = TimeZone(identifier: zones[zoneName] ?? zoneName) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = "MMM d, yyyy h:mm a"
            formatter.isLenient = false
            guard let date = formatter.date(from: String(time[..<comma])) else { return nil }
            return Self(topic: topic, host: host, startAt: date, timeZoneID: zone.identifier, joinURL: url)
        }
    }

    static func isZoomURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return false }
        return host == "zoom.us" || host.hasSuffix(".zoom.us")
    }

    struct ClassEvent: Sendable {
        let courseID: Int64?
        let title: String
        let startAt: Date
        let details: String
    }

    /// Require the same course, date and a nearby, identifiable class event.
    /// Ambiguous evidence leaves the invitation unchanged.
    /// Banner meetings come first. They hold the registrar time, so an early
    /// Zoom invite moves to the real class start when Banner names one time.
    func resolvedStart(courseID: Int64?, events: [ClassEvent], syllabus: String? = nil,
                       bannerMeetings: [YUClassMeeting] = []) -> Date {
        if !bannerMeetings.isEmpty {
            let bannerTimes = Set(YUBannerSchedule.starts(on: startAt, meetings: bannerMeetings).filter {
                abs($0.timeIntervalSince(startAt)) <= 60 * 60
            })
            if bannerTimes.count == 1, let time = bannerTimes.first { return time }
            if bannerTimes.count > 1 { return startAt }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        let matches = events.filter { event in
            guard let courseID, courseID != 0, event.courseID == courseID,
                  calendar.isDate(event.startAt, inSameDayAs: startAt),
                  abs(event.startAt.timeIntervalSince(startAt)) <= 60 * 60 else { return false }
            return event.title.compare(topic, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || event.details.contains(joinURL.absoluteString)
        }
        let times = Set(matches.map(\.startAt))
        if times.count == 1, let time = times.first { return time }
        guard times.isEmpty, courseID != nil, courseID != 0, let syllabus else { return startAt }
        // Only explicit class/lecture meeting lines on this weekday qualify.
        // Free-form references (exams, deadlines, office hours) are not schedules.
        let weekday = calendar.component(.weekday, from: startAt)
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let day = names[weekday - 1]
        var syllabusTimes = Set<Date>()
        for line in syllabus.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard lower.range(of: #"\b(class|classes|lecture|lectures)\b"#, options: .regularExpression) != nil,
                  !lower.contains("office"), !lower.contains("exam"),
                  lower.range(of: "\\b" + day + "s?\\b", options: .regularExpression) != nil,
                  let range = line.range(of: #"(?i)\b(1[0-2]|[1-9]):[0-5][0-9]\s*[AP]M\b"#,
                                         options: .regularExpression) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "h:mm a"
            guard let clock = formatter.date(from: String(line[range])) else { continue }
            let components = calendar.dateComponents([.hour, .minute], from: clock)
            guard let hour = components.hour, let minute = components.minute,
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startAt),
                  abs(candidate.timeIntervalSince(startAt)) <= 3600 else { continue }
            syllabusTimes.insert(candidate)
        }
        return syllabusTimes.count == 1 ? syllabusTimes.first! : startAt
    }
}
