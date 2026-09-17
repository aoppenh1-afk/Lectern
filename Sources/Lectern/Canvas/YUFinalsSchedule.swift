import Foundation

/// Wilf Campus Fall 2026 final exam schedule, cross-checked per course.
///
/// The registrar keys most slots off the Banner sequence number (the class
/// number suffix, such as 331 in JHI-2430-331). Four Syms core courses instead
/// exam by course code on Sunday Jan 3, and Hebrew sections exam Thursday
/// Dec 31 at 1pm. Morning slots run 9:30-11:45 AM, afternoon slots 1:00-3:15 PM.
/// January dates fall in 2027. Only exact Wilf campus sections qualify.
enum YUFinalsSchedule {
    static let termLabel = "Fall 2026"
    static let morningStart = 9 * 60 + 30
    static let morningEnd = 11 * 60 + 45
    static let afternoonStart = 13 * 60
    static let afternoonEnd = 15 * 60 + 15

    struct Slot: Sendable, Equatable {
        let start: Date
        let end: Date
    }

    /// Split a Canvas code such as JHI-2430-331 into subject, number, section.
    /// Two-part codes such as ACC 1001 yield no section.
    static func parseCanvasCode(_ value: String?) -> (subject: String, number: String, section: String?)? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let upper = raw.uppercased()
        let dashParts = upper.split(separator: "-").map(String.init)
        if dashParts.count >= 3, let last = dashParts.last, !last.isEmpty {
            let subject = dashParts[0].filter(\.isLetter)
            let number = dashParts[1].filter(\.isNumber)
            guard !subject.isEmpty, !number.isEmpty else { return nil }
            return (subject, number, last.filter { $0.isLetter || $0.isNumber })
        }
        guard let split = YUBannerSchedule.splitCode(upper) else { return nil }
        return (split.subject, split.number, nil)
    }

    /// Sections ending in -2 and -3 share the -1 slot (232 sits with 231).
    /// Explicit table entries win first, so 432 keeps its listed slot.
    static func normalizedSection(_ raw: String) -> String {
        let cleaned = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 3, cleaned.allSatisfy(\.isNumber),
              cleaned.hasSuffix("2") || cleaned.hasSuffix("3") else { return cleaned }
        return String(cleaned.dropLast()) + "1"
    }

    /// Finals slot for one course. Campus must be Wilf when known. A nil
    /// campus (Canvas-only fallback with no Banner row) is allowed through.
    /// Section 511 needs a resolved school, otherwise it returns nil.
    static func slot(section: String?, subject: String?, number: String?,
                     school: YUSchool?, campus: String?) -> Slot? {
        if let campus, !campus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           campus.compare("Wilf", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            return nil
        }
        let subjectCode = (subject ?? "").uppercased().filter(\.isLetter)
        let courseNumber = (number ?? "").uppercased().filter(\.isNumber)
        if subjectCode == "HEB" {
            return makeSlot(month: 12, day: 31, year: 2026, start: afternoonStart, end: afternoonEnd)
        }
        if (subjectCode == "ACC" || subjectCode == "FIN") && courseNumber == "1001" {
            return makeSlot(month: 1, day: 3, year: 2027, start: morningStart, end: morningEnd)
        }
        if subjectCode == "IDS" && (courseNumber == "1131" || courseNumber == "1556") {
            return makeSlot(month: 1, day: 3, year: 2027, start: afternoonStart, end: afternoonEnd)
        }
        guard let section, !section.isEmpty else { return nil }
        let key = section.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "511" {
            switch school {
            case .yc: return makeSlot(month: 12, day: 30, year: 2026, start: afternoonStart, end: afternoonEnd)
            case .syms: return makeSlot(month: 12, day: 31, year: 2026, start: morningStart, end: morningEnd)
            case nil: return nil
            }
        }
        if let direct = gridSlot(key) { return direct }
        let folded = normalizedSection(key)
        if folded != key { return gridSlot(folded) }
        return nil
    }

    private static func gridSlot(_ key: String) -> Slot? {
        switch key {
        case "241": return makeSlot(month: 12, day: 28, year: 2026, start: morningStart, end: morningEnd)
        case "451", "461": return makeSlot(month: 12, day: 28, year: 2026, start: afternoonStart, end: afternoonEnd)
        case "341": return makeSlot(month: 12, day: 29, year: 2026, start: morningStart, end: morningEnd)
        case "211": return makeSlot(month: 12, day: 29, year: 2026, start: afternoonStart, end: afternoonEnd)
        case "331": return makeSlot(month: 12, day: 30, year: 2026, start: morningStart, end: morningEnd)
        case "311": return makeSlot(month: 12, day: 30, year: 2026, start: afternoonStart, end: afternoonEnd)
        case "621": return makeSlot(month: 12, day: 31, year: 2026, start: morningStart, end: morningEnd)
        case "351", "361", "551": return makeSlot(month: 1, day: 4, year: 2027, start: morningStart, end: morningEnd)
        case "251", "261": return makeSlot(month: 1, day: 4, year: 2027, start: afternoonStart, end: afternoonEnd)
        case "231", "432": return makeSlot(month: 1, day: 5, year: 2027, start: morningStart, end: morningEnd)
        case "561": return makeSlot(month: 1, day: 5, year: 2027, start: afternoonStart, end: afternoonEnd)
        default: return nil
        }
    }

    private static func makeSlot(month: Int, day: Int, year: Int, start: Int, end: Int) -> Slot? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        guard let date = calendar.date(from: parts),
              let startDate = calendar.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: date),
              let endDate = calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: date) else { return nil }
        return Slot(start: startDate, end: endDate)
    }
}
