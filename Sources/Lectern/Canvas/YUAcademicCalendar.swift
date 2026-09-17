import Foundation
import SwiftData

enum YUAcademicKind: String, Codable, Sendable {
    case holiday
    case deadline
    case remote
    case swap
    case exams
    case noSchool
    case boundary
    case admin
    case observance
}

/// One official academic calendar day. Seeded from the bundled UG calendar,
/// never fetched. Display is gated on YU Canvas, like Banner and finals.
@Model
final class YUAcademicEvent {
    var title: String
    var startAt: Date
    var endAt: Date?
    var kindRaw: String?
    var sourceRaw: String?
    var syncedAt: Date

    init(title: String, startAt: Date, kind: YUAcademicKind) {
        self.title = title
        self.startAt = startAt
        self.kindRaw = kind.rawValue
        self.sourceRaw = YUAcademicCalendar.sourceKey
        self.syncedAt = Date()
    }

    var kind: YUAcademicKind {
        get { YUAcademicKind(rawValue: kindRaw ?? "") ?? .observance }
        set { kindRaw = newValue.rawValue }
    }
}

/// Wilf entries from the UG Academic Calendar 2026-27 (Fall plus Spring).
/// Refund lines are dropped everywhere. Calendar-level final exam rows are
/// skipped because per-course finals already cover them. Stern women's
/// entries are skipped; UTS and MYP programs meet on Wilf so they stay.
enum YUAcademicCalendar {
    static let sourceKey = "ug-calendar-2026-27"
    static let seededVersionKey = "yuAcademicCalendar.seededVersion"
    static let seededVersion = 2

    struct Entry: Sendable {
        let title: String
        let year: Int
        let month: Int
        let day: Int
        let kind: YUAcademicKind
    }

    static let entries: [Entry] = [
        // MARK: - Fall 2026, August
        .init(title: "Move in", year: 2026, month: 8, day: 25, kind: .boundary),
        .init(title: "Orientation", year: 2026, month: 8, day: 26, kind: .boundary),
        .init(title: "Orientation and registration", year: 2026, month: 8, day: 27, kind: .boundary),
        .init(title: "Orientation", year: 2026, month: 8, day: 28, kind: .boundary),
        .init(title: "First day of classes", year: 2026, month: 8, day: 31, kind: .boundary),
        // MARK: - Fall 2026, September
        .init(title: "Make-up finals for Spring 2026", year: 2026, month: 9, day: 4, kind: .exams),
        .init(title: "Last day to complete Spring and summer incomplete work", year: 2026, month: 9, day: 4, kind: .deadline),
        .init(title: "Labor Day, no classes, MYP classes meet", year: 2026, month: 9, day: 7, kind: .holiday),
        .init(title: "Last day to add a class", year: 2026, month: 9, day: 8, kind: .deadline),
        .init(title: "Last day to drop", year: 2026, month: 9, day: 9, kind: .deadline),
        .init(title: "Erev Rosh Hashana, no classes", year: 2026, month: 9, day: 11, kind: .holiday),
        .init(title: "Rosh Hashana, no classes", year: 2026, month: 9, day: 13, kind: .holiday),
        .init(title: "Fast of Gedaliah, no classes, MYP and SMBP meet", year: 2026, month: 9, day: 14, kind: .holiday),
        .init(title: "Remote instruction, MYP and SMBP in person", year: 2026, month: 9, day: 15, kind: .remote),
        .init(title: "Monday classes meet, remote instruction", year: 2026, month: 9, day: 16, kind: .swap),
        .init(title: "Last day to drop", year: 2026, month: 9, day: 16, kind: .deadline),
        .init(title: "Last day to add a Monday class", year: 2026, month: 9, day: 16, kind: .deadline),
        .init(title: "Remote instruction, MYP and SMBP in person", year: 2026, month: 9, day: 17, kind: .remote),
        .init(title: "Remote instruction", year: 2026, month: 9, day: 18, kind: .remote),
        .init(title: "Erev Yom Kippur, no classes", year: 2026, month: 9, day: 20, kind: .holiday),
        .init(title: "Yom Kippur, no classes", year: 2026, month: 9, day: 21, kind: .holiday),
        .init(title: "Remote instruction, Friday classes meet", year: 2026, month: 9, day: 22, kind: .swap),
        .init(title: "Remote instruction", year: 2026, month: 9, day: 23, kind: .remote),
        .init(title: "Last day to drop", year: 2026, month: 9, day: 23, kind: .deadline),
        .init(title: "Remote instruction", year: 2026, month: 9, day: 24, kind: .remote),
        .init(title: "Erev Sukkot, no classes", year: 2026, month: 9, day: 25, kind: .holiday),
        .init(title: "Sukkot, no classes", year: 2026, month: 9, day: 27, kind: .holiday),
        .init(title: "Sukkot, no classes", year: 2026, month: 9, day: 28, kind: .holiday),
        .init(title: "Sukkot, no classes", year: 2026, month: 9, day: 29, kind: .holiday),
        .init(title: "Sukkot, no classes", year: 2026, month: 9, day: 30, kind: .holiday),
        // MARK: - Fall 2026, October
        .init(title: "Sukkot, no classes", year: 2026, month: 10, day: 1, kind: .holiday),
        .init(title: "September conferral date", year: 2026, month: 10, day: 1, kind: .admin),
        .init(title: "Sukkot, no classes", year: 2026, month: 10, day: 2, kind: .holiday),
        .init(title: "Simchas Torah, no classes", year: 2026, month: 10, day: 4, kind: .holiday),
        .init(title: "Travel day, no classes", year: 2026, month: 10, day: 5, kind: .noSchool),
        .init(title: "Monday classes meet", year: 2026, month: 10, day: 7, kind: .swap),
        .init(title: "Last day to drop", year: 2026, month: 10, day: 7, kind: .deadline),
        .init(title: "Last day to drop without a W", year: 2026, month: 10, day: 21, kind: .deadline),
        .init(title: "First day to drop with a W", year: 2026, month: 10, day: 22, kind: .deadline),
        .init(title: "Last day to apply for January 2027 degree", year: 2026, month: 10, day: 26, kind: .deadline),
        .init(title: "UTS midterms", year: 2026, month: 10, day: 27, kind: .exams),
        .init(title: "UTS midterms", year: 2026, month: 10, day: 28, kind: .exams),
        .init(title: "UTS midterms", year: 2026, month: 10, day: 29, kind: .exams),
        // MARK: - Fall 2026, November
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 5, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 6, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 9, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 10, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 11, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 12, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 13, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2026, month: 11, day: 16, kind: .exams),
        .init(title: "Last day to drop with a W", year: 2026, month: 11, day: 18, kind: .deadline),
        .init(title: "P/N filing period", year: 2026, month: 11, day: 23, kind: .deadline),
        .init(title: "P/N filing period", year: 2026, month: 11, day: 24, kind: .deadline),
        .init(title: "P/N filing period", year: 2026, month: 11, day: 25, kind: .deadline),
        .init(title: "Thanksgiving, no classes", year: 2026, month: 11, day: 26, kind: .holiday),
        .init(title: "Thanksgiving, no classes", year: 2026, month: 11, day: 27, kind: .holiday),
        // MARK: - Fall 2026, December
        .init(title: "Chanukah, no classes", year: 2026, month: 12, day: 4, kind: .holiday),
        .init(title: "Chanukah, no classes", year: 2026, month: 12, day: 6, kind: .holiday),
        .init(title: "Chanukah, no classes", year: 2026, month: 12, day: 7, kind: .holiday),
        .init(title: "Chanukah, Friday classes meet after 3pm", year: 2026, month: 12, day: 8, kind: .holiday),
        .init(title: "Chanukah, no classes", year: 2026, month: 12, day: 9, kind: .holiday),
        .init(title: "Chanukah, no classes", year: 2026, month: 12, day: 10, kind: .holiday),
        .init(title: "Chanukah, no classes", year: 2026, month: 12, day: 11, kind: .holiday),
        .init(title: "Asara B'Tevet, no classes, MYP classes meet", year: 2026, month: 12, day: 20, kind: .holiday),
        .init(title: "UTS finals", year: 2026, month: 12, day: 21, kind: .exams),
        .init(title: "UTS finals", year: 2026, month: 12, day: 22, kind: .exams),
        .init(title: "UTS finals", year: 2026, month: 12, day: 23, kind: .exams),
        .init(title: "MYP and SMBP bechinos", year: 2026, month: 12, day: 23, kind: .exams),
        .init(title: "Study day", year: 2026, month: 12, day: 24, kind: .noSchool),
        .init(title: "Study day", year: 2026, month: 12, day: 25, kind: .noSchool),
        .init(title: "Study day", year: 2026, month: 12, day: 27, kind: .noSchool),
        // MARK: - Fall 2026, January
        .init(title: "New Year's Day, no classes", year: 2027, month: 1, day: 1, kind: .holiday),
        .init(title: "Last day of the semester", year: 2027, month: 1, day: 5, kind: .boundary),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 6, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 7, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 8, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 10, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 11, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 12, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 13, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 14, kind: .noSchool),
        .init(title: "Intersession, no classes", year: 2027, month: 1, day: 15, kind: .noSchool),
        // MARK: - Spring 2027, January
        .init(title: "Martin Luther King Jr. Day, no classes, orientation and move in", year: 2027, month: 1, day: 18, kind: .holiday),
        .init(title: "Orientation", year: 2027, month: 1, day: 19, kind: .boundary),
        .init(title: "First day of classes", year: 2027, month: 1, day: 20, kind: .boundary),
        .init(title: "Last day to add a class", year: 2027, month: 1, day: 27, kind: .deadline),
        .init(title: "Last day to drop", year: 2027, month: 1, day: 27, kind: .deadline),
        .init(title: "Last day to complete Fall 2025 incomplete work", year: 2027, month: 1, day: 29, kind: .deadline),
        .init(title: "Make-up finals for Spring 2026", year: 2027, month: 1, day: 29, kind: .exams),
        .init(title: "January 2027 degree award date", year: 2027, month: 1, day: 29, kind: .admin),
        // MARK: - Spring 2027, February
        .init(title: "Last day to drop", year: 2027, month: 2, day: 3, kind: .deadline),
        .init(title: "Last day to drop", year: 2027, month: 2, day: 10, kind: .deadline),
        .init(title: "Last day to apply for May 2027 conferral", year: 2027, month: 2, day: 15, kind: .deadline),
        .init(title: "Last day to drop", year: 2027, month: 2, day: 17, kind: .deadline),
        .init(title: "Last day to drop without a W", year: 2027, month: 2, day: 24, kind: .deadline),
        .init(title: "First day to drop with a W", year: 2027, month: 2, day: 25, kind: .deadline),
        // MARK: - Spring 2027, March
        .init(title: "UTS midterms", year: 2027, month: 3, day: 2, kind: .exams),
        .init(title: "UTS midterms", year: 2027, month: 3, day: 3, kind: .exams),
        .init(title: "UTS midterms", year: 2027, month: 3, day: 4, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 10, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 11, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 15, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 16, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 17, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 18, kind: .exams),
        .init(title: "YC and SSSB men's midterms", year: 2027, month: 3, day: 19, kind: .exams),
        .init(title: "Fast of Esther, no classes, MYP and SMBP meet", year: 2027, month: 3, day: 22, kind: .holiday),
        .init(title: "Purim, no classes", year: 2027, month: 3, day: 23, kind: .holiday),
        .init(title: "Tuesday classes meet", year: 2027, month: 3, day: 25, kind: .swap),
        .init(title: "P/N filing period", year: 2027, month: 3, day: 26, kind: .deadline),
        .init(title: "Last day to drop with a W", year: 2027, month: 3, day: 26, kind: .deadline),
        .init(title: "P/N filing period", year: 2027, month: 3, day: 29, kind: .deadline),
        .init(title: "P/N filing period", year: 2027, month: 3, day: 30, kind: .deadline),
        .init(title: "P/N filing period", year: 2027, month: 3, day: 31, kind: .deadline),
        // MARK: - Spring 2027, April
        .init(title: "Travel day, no classes", year: 2027, month: 4, day: 19, kind: .noSchool),
        .init(title: "Bedikat Chametz", year: 2027, month: 4, day: 20, kind: .observance),
        .init(title: "Erev Pesach, no classes", year: 2027, month: 4, day: 21, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 22, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 23, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 25, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 26, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 27, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 28, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 29, kind: .holiday),
        .init(title: "Pesach, no classes", year: 2027, month: 4, day: 30, kind: .holiday),
        // MARK: - Spring 2027, May and June
        .init(title: "UTS finals", year: 2027, month: 5, day: 10, kind: .exams),
        .init(title: "UTS finals", year: 2027, month: 5, day: 11, kind: .exams),
        .init(title: "Yom HaAtzmaut, no classes, UTS classes meet", year: 2027, month: 5, day: 12, kind: .holiday),
        .init(title: "UTS finals", year: 2027, month: 5, day: 13, kind: .exams),
        .init(title: "MYP and SMBP bechinos", year: 2027, month: 5, day: 13, kind: .exams),
        .init(title: "Study day", year: 2027, month: 5, day: 14, kind: .noSchool),
        .init(title: "Study day", year: 2027, month: 5, day: 16, kind: .noSchool),
        .init(title: "Monday classes meet", year: 2027, month: 5, day: 17, kind: .swap),
        .init(title: "Last day of the semester", year: 2027, month: 5, day: 25, kind: .boundary),
        .init(title: "Commencement, tentative", year: 2027, month: 5, day: 26, kind: .boundary),
        .init(title: "June conferral date", year: 2027, month: 6, day: 15, kind: .admin),
    ]

    static func date(for entry: Entry) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        var parts = DateComponents()
        parts.year = entry.year; parts.month = entry.month; parts.day = entry.day
        return calendar.date(from: parts)
    }

    /// Insert every entry once. Safe to call on every launch.
    ///
    /// Self-healing: an empty store reseeds even when the version flag says
    /// done, so a failed first save can never leave the calendar blank
    /// forever. The flag stamps only after a successful save, so a failed
    /// save retries on the next launch.
    static func seedIfNeeded(modelContext: ModelContext, isYU: Bool,
                             defaults: UserDefaults = .standard) {
        guard isYU else { return }
        let existing = (try? modelContext.fetch(FetchDescriptor<YUAcademicEvent>())) ?? []
        let hasSeededRows = existing.contains { $0.sourceRaw == sourceKey }
        guard defaults.integer(forKey: seededVersionKey) != seededVersion || !hasSeededRows else { return }
        for stale in existing where stale.sourceRaw == sourceKey { modelContext.delete(stale) }
        for entry in entries {
            guard let date = date(for: entry) else { continue }
            modelContext.insert(YUAcademicEvent(title: entry.title, startAt: date, kind: entry.kind))
        }
        do {
            try modelContext.save()
            defaults.set(seededVersion, forKey: seededVersionKey)
        } catch {
            // Leave the flag unset so the next launch retries the seed.
        }
    }
}
