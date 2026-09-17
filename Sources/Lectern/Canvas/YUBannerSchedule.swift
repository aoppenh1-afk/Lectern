import Foundation

/// One weekly class meeting from YU's public Banner schedule.
///
/// Banner stores times as wall-clock strings in America/New_York, such as
/// beginTime "1000" and endTime "1125". Days are separate booleans. Dates
/// bound the part of term the meeting runs.
struct YUClassMeeting: Codable, Sendable, Equatable {
    /// Calendar weekday numbers, 1 = Sunday through 7 = Saturday.
    var weekdays: [Int]
    /// Minutes after midnight in America/New_York.
    var startMinutes: Int
    var endMinutes: Int?
    var building: String?
    var room: String?
    var startDate: Date?
    var endDate: Date?
    var subjectCourse: String?
    var courseTitle: String?
    var instructors: [String]
    var termCode: String?

    static let yuTimeZone = TimeZone(identifier: "America/New_York") ?? .current

    var weekdaySet: Set<Int> { Set(weekdays) }

    var locationDisplay: String? {
        let parts = [building, room].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    var timeDisplay: String {
        Self.formatMinutes(startMinutes, endMinutes: endMinutes)
    }

    static func formatMinutes(_ start: Int, endMinutes: Int? = nil) -> String {
        func piece(_ minutes: Int) -> String {
            let hour24 = minutes / 60
            let minute = minutes % 60
            let suffix = hour24 >= 12 ? "PM" : "AM"
            var hour12 = hour24 % 12
            if hour12 == 0 { hour12 = 12 }
            return String(format: "%d:%02d %@", hour12, minute, suffix)
        }
        if let endMinutes {
            return "\(piece(start)) - \(piece(endMinutes))"
        }
        return piece(start)
    }

    /// Parse Banner "HHmm" strings such as "0900", "1330", "TBA", or nil.
    static func parseBannerTime(_ value: String?) -> Int? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let upper = raw.uppercased()
        if upper == "TBA" || upper == "TBD" { return nil }
        let digits = upper.filter(\.isNumber)
        guard digits.count == 3 || digits.count == 4, let number = Int(digits) else { return nil }
        let hour = number / 100
        let minute = number % 100
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func parseBannerDate(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = yuTimeZone
        for format in ["MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// Next start after `now`, up to 14 days out. Respects the meeting date range.
    func nextStart(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var nyCalendar = calendar
        nyCalendar.timeZone = Self.yuTimeZone
        let days = weekdaySet
        guard !days.isEmpty else { return nil }
        let hour = startMinutes / 60
        let minute = startMinutes % 60
        let startOfToday = nyCalendar.startOfDay(for: now)
        for offset in 0..<15 {
            guard let day = nyCalendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            let weekday = nyCalendar.component(.weekday, from: day)
            guard days.contains(weekday) else { continue }
            if let rangeStart = startDate, day < nyCalendar.startOfDay(for: rangeStart) { continue }
            if let rangeEnd = endDate, day > nyCalendar.startOfDay(for: rangeEnd) { continue }
            guard let candidate = nyCalendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    /// Start time on a specific day, when that weekday is part of the pattern.
    func start(on day: Date, calendar: Calendar = .current) -> Date? {
        var nyCalendar = calendar
        nyCalendar.timeZone = Self.yuTimeZone
        let weekday = nyCalendar.component(.weekday, from: day)
        guard weekdaySet.contains(weekday) else { return nil }
        if let rangeStart = startDate, day < nyCalendar.startOfDay(for: rangeStart) { return nil }
        if let rangeEnd = endDate, day > nyCalendar.startOfDay(for: rangeEnd) { return nil }
        return nyCalendar.date(
            bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: day)
    }
}

/// Wilf YC versus Syms, for finals slots that split by school.
enum YUSchool: String, Codable, Sendable {
    case yc
    case syms
}

/// A Banner section row. Only the fields Lectern needs are decoded. Every
/// other Banner field is ignored so registrar-side additions never break sync.
struct YUBannerSection: Decodable, Sendable {
    var courseReferenceNumber: String?
    var subject: String?
    var courseNumber: String?
    var subjectCourse: String?
    var courseTitle: String?
    /// Banner sequence number, such as 331. The finals grid keys off this.
    var sequenceNumber: String?
    /// Banner part of term, such as YC1 or UB4. Carries the school for 511.
    var partOfTerm: String?
    /// Section campus, such as Wilf or Beren. Finals cover Wilf only.
    var campusDescription: String?
    /// Section attribute codes, such as SYBC. SY-prefixed codes mark Syms.
    var attributeCodes: [String]
    var faculty: [YUBannerFaculty]
    var meetings: [YUClassMeeting]

    struct YUBannerFaculty: Decodable, Sendable {
        var displayName: String?
    }

    private enum CodingKeys: String, CodingKey {
        case courseReferenceNumber, subject, courseNumber, subjectCourse, courseTitle
        case sequenceNumber, partOfTerm, campusDescription, faculty, meetingsFaculty
        case sectionAttributes
    }

    private struct SectionAttribute: Decodable {
        var code: String?
    }

    private struct MeetingWrapper: Decodable {
        var meetingTime: MeetingTime?
    }

    private struct MeetingTime: Decodable {
        var beginTime: String?
        var endTime: String?
        var monday: Bool?
        var tuesday: Bool?
        var wednesday: Bool?
        var thursday: Bool?
        var friday: Bool?
        var saturday: Bool?
        var sunday: Bool?
        var building: String?
        var room: String?
        var startDate: String?
        var endDate: String?
    }

    init(courseReferenceNumber: String? = nil, subject: String? = nil, courseNumber: String? = nil,
         subjectCourse: String? = nil, courseTitle: String? = nil,
         sequenceNumber: String? = nil, partOfTerm: String? = nil, campusDescription: String? = nil,
         attributeCodes: [String] = [],
         faculty: [YUBannerFaculty] = [], meetings: [YUClassMeeting] = []) {
        self.courseReferenceNumber = courseReferenceNumber
        self.subject = subject
        self.courseNumber = courseNumber
        self.subjectCourse = subjectCourse
        self.courseTitle = courseTitle
        self.sequenceNumber = sequenceNumber
        self.partOfTerm = partOfTerm
        self.campusDescription = campusDescription
        self.attributeCodes = attributeCodes
        self.faculty = faculty
        self.meetings = meetings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseReferenceNumber = (try? container.decodeIfPresent(String.self, forKey: .courseReferenceNumber)) ?? nil
        subject = (try? container.decodeIfPresent(String.self, forKey: .subject)) ?? nil
        courseNumber = (try? container.decodeIfPresent(String.self, forKey: .courseNumber)) ?? nil
        subjectCourse = (try? container.decodeIfPresent(String.self, forKey: .subjectCourse)) ?? nil
        courseTitle = (try? container.decodeIfPresent(String.self, forKey: .courseTitle)) ?? nil
        sequenceNumber = (try? container.decodeIfPresent(String.self, forKey: .sequenceNumber)) ?? nil
        partOfTerm = (try? container.decodeIfPresent(String.self, forKey: .partOfTerm)) ?? nil
        campusDescription = (try? container.decodeIfPresent(String.self, forKey: .campusDescription)) ?? nil
        let attributes = (try? container.decodeIfPresent([SectionAttribute].self, forKey: .sectionAttributes)) ?? []
        attributeCodes = attributes.compactMap(\.code)
        faculty = (try? container.decodeIfPresent([YUBannerFaculty].self, forKey: .faculty)) ?? []
        let wrappers = (try? container.decodeIfPresent([MeetingWrapper].self, forKey: .meetingsFaculty)) ?? []
        let instructorNames = faculty.compactMap(\.displayName)
        var parsed: [YUClassMeeting] = []
        for wrapper in wrappers {
            guard let time = wrapper.meetingTime,
                  let startMinutes = YUClassMeeting.parseBannerTime(time.beginTime) else { continue }
            var weekdays: [Int] = []
            if time.sunday == true { weekdays.append(1) }
            if time.monday == true { weekdays.append(2) }
            if time.tuesday == true { weekdays.append(3) }
            if time.wednesday == true { weekdays.append(4) }
            if time.thursday == true { weekdays.append(5) }
            if time.friday == true { weekdays.append(6) }
            if time.saturday == true { weekdays.append(7) }
            guard !weekdays.isEmpty else { continue }
            parsed.append(YUClassMeeting(
                weekdays: weekdays,
                startMinutes: startMinutes,
                endMinutes: YUClassMeeting.parseBannerTime(time.endTime),
                building: time.building,
                room: time.room,
                startDate: YUClassMeeting.parseBannerDate(time.startDate),
                endDate: YUClassMeeting.parseBannerDate(time.endDate),
                subjectCourse: (try? container.decodeIfPresent(String.self, forKey: .subjectCourse)) ?? nil,
                courseTitle: (try? container.decodeIfPresent(String.self, forKey: .courseTitle)) ?? nil,
                instructors: instructorNames,
                termCode: nil
            ))
        }
        meetings = parsed
    }

    var instructorNames: [String] { faculty.compactMap(\.displayName) }

    /// School for finals slots that split YC and Syms. YC1 marks Yeshiva
    /// College, UB4 and UB1 mark Syms, and SY-prefixed attribute tags corroborate
    /// Syms. Anything else resolves to nil and gets no school-split final.
    var school: YUSchool? {
        let upperPart = (partOfTerm ?? "").uppercased()
        if upperPart == "UB4" || upperPart == "UB1" { return .syms }
        if attributeCodes.contains(where: { $0.uppercased().hasPrefix("SY") }) { return .syms }
        if upperPart == "YC1" { return .yc }
        return nil
    }
}

enum YUBannerSchedule {
    /// Pick the Banner term whose description matches a Canvas term such as
    /// "Fall 2026". Falls back to the newest term containing the year.
    static func pickTerm(matching selectedTerm: String, from terms: [YUBannerTerm]) -> YUBannerTerm? {
        let wanted = selectedTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = terms.first(where: {
            $0.description.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) { return exact }
        let lower = wanted.lowercased()
        let season = ["fall", "spring", "summer", "winter"].first { lower.contains($0) }
        let year = lower.filter(\.isNumber)
        let scored = terms.compactMap { term -> (YUBannerTerm, Int)? in
            let desc = term.description.lowercased()
            var score = 0
            if let season, desc.contains(season) { score += 2 }
            if !year.isEmpty, desc.contains(year) { score += 3 }
            else if year.isEmpty { score += 1 }
            return score > 0 ? (term, score) : nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.code > rhs.0.code
        }.first?.0
    }

    /// Split "BIOL 101" into ("BIOL", "101"). Handles "BIO-101A", "blaw201".
    static func splitCode(_ value: String) -> (subject: String, number: String)? {
        let upper = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upper.isEmpty else { return nil }
        var subject = ""
        var number = ""
        var seenDigit = false
        for char in upper {
            if char.isLetter, !seenDigit {
                subject.append(char)
            } else if char.isNumber {
                seenDigit = true
                number.append(char)
            } else if seenDigit, char.isLetter, !number.isEmpty {
                number.append(char)
                break
            }
        }
        guard !subject.isEmpty, !number.isEmpty else { return nil }
        let digits = number.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return (subject, number)
    }

    static func subjectsMatch(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let common = zip(left, right).prefix(while: { $0 == $1 }).count
        return common >= 3
    }

    /// Score a Banner section against a Canvas course. Negative means no match.
    static func score(canvasCode: String?, canvasName: String, canvasInstructor: String?,
                     section: YUBannerSection) -> Int {
        var points = 0
        var codeMatched = false
        if let canvasCode, let canvas = splitCode(canvasCode) {
            let candidates = [section.subjectCourse, [section.subject, section.courseNumber].compactMap { $0 }.joined(separator: " ")]
                .compactMap { $0 }.compactMap(splitCode)
            for candidate in candidates where candidate.number == canvas.number && subjectsMatch(candidate.subject, canvas.subject) {
                codeMatched = true
                points += candidate.subject == canvas.subject ? 10 : 6
                break
            }
            if !codeMatched { return -1 }
        } else {
            // Without a Canvas code, require a strong title overlap instead.
            let titleWords = Set(canvasName.lowercased().split(separator: " ").map(String.init).filter { $0.count > 3 })
            let bannerWords = Set((section.courseTitle ?? "").lowercased().split(separator: " ").map(String.init))
            let overlap = titleWords.intersection(bannerWords).count
            guard overlap >= 2 || (titleWords.count == 1 && overlap == 1) else { return -1 }
            points += overlap * 2
        }
        if let instructor = canvasInstructor?.lowercased(), !instructor.isEmpty {
            let lastName = instructor.split(separator: " ").last.map(String.init) ?? instructor
            if lastName.count > 2,
               section.instructorNames.joined(separator: " ").lowercased().contains(lastName) {
                points += 5
            }
        }
        if !canvasName.isEmpty, let bannerTitle = section.courseTitle, !bannerTitle.isEmpty {
            let wanted = Set(canvasName.lowercased().split(separator: " ").map(String.init).filter { $0.count > 3 })
            let have = Set(bannerTitle.lowercased().split(separator: " ").map(String.init))
            points += min(wanted.intersection(have).count, 3)
        }
        return points
    }

    /// Best Banner meetings for one Canvas course, ranked by code then instructor.
    static func match(canvasCode: String?, canvasName: String, canvasInstructor: String?,
                     sections: [YUBannerSection], minimumScore: Int = 6) -> [YUClassMeeting] {
        let ranked = sections.compactMap { section -> (Int, YUBannerSection)? in
            let points = score(canvasCode: canvasCode, canvasName: canvasName,
                               canvasInstructor: canvasInstructor, section: section)
            guard points >= minimumScore, !section.meetings.isEmpty else { return nil }
            return (points, section)
        }.sorted { $0.0 > $1.0 }
        guard !ranked.isEmpty else { return [] }
        // Keep every meeting from the top score tier. A course can have a
        // lecture plus a lab at different times, and both matter.
        let top = ranked[0].0
        return ranked.filter { $0.0 == top }.flatMap { $0.1.meetings }
    }

    struct Occurrence: Sendable {
        let courseName: String
        let courseCode: String?
        let meeting: YUClassMeeting
        let start: Date
        let end: Date?
    }

    /// Next Banner class across courses. Used by Overview active session.
    static func nextClass(in courses: [(name: String, code: String?, meetings: [YUClassMeeting])],
                         now: Date = Date()) -> Occurrence? {
        var best: Occurrence?
        for course in courses {
            for meeting in course.meetings {
                guard let start = meeting.nextStart(after: now) else { continue }
                let end: Date? = {
                    guard let endMinutes = meeting.endMinutes else { return nil }
                    var ny = Calendar.current
                    ny.timeZone = YUClassMeeting.yuTimeZone
                    return ny.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: start)
                }()
                if best == nil || start < best!.start {
                    best = Occurrence(courseName: course.name, courseCode: course.code, meeting: meeting, start: start, end: end)
                }
            }
        }
        return best
    }

    /// Banner start times on one calendar day. Used by Zoom resolution.
    static func starts(on day: Date, meetings: [YUClassMeeting]) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        return meetings.compactMap { $0.start(on: day, calendar: calendar) }
    }
}

extension Course {
    var bannerMeetings: [YUClassMeeting] {
        get {
            guard let data = bannerMeetingsData else { return [] }
            return (try? JSONDecoder().decode([YUClassMeeting].self, from: data)) ?? []
        }
        set {
            bannerMeetingsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }
}
