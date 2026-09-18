import SwiftData
import XCTest

final class YUAcademicCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        return calendar
    }

    private func day(_ entry: YUAcademicCalendar.Entry) -> (month: Int, day: Int, year: Int) {
        (entry.month, entry.day, entry.year)
    }

    func testCoversBothTerms() {
        XCTAssertGreaterThan(YUAcademicCalendar.entries.count, 130)
        XCTAssertTrue(YUAcademicCalendar.entries.contains { $0.year == 2026 })
        XCTAssertTrue(YUAcademicCalendar.entries.contains { $0.year == 2027 && $0.month <= 6 })
    }

    func testNoRefundTextAnywhere() {
        for entry in YUAcademicCalendar.entries {
            XCTAssertFalse(entry.title.lowercased().contains("refund"), entry.title)
        }
    }

    func testNoCalendarFinalsRows() {
        // Per-course finals cover Dec 28-Jan 5 and May 18-25. Only makeup,
        // UTS, midterm, and bechinos exam blocks remain.
        for entry in YUAcademicCalendar.entries where entry.kind == .exams {
            let lower = entry.title.lowercased()
            XCTAssertTrue(lower.contains("midterm") || lower.contains("uts")
                          || lower.contains("bechinos") || lower.contains("make-up"),
                          entry.title)
        }
    }

    func testSpotDates() {
        func has(_ title: String, month: Int, day: Int, year: Int) -> Bool {
            YUAcademicCalendar.entries.contains {
                $0.title == title && $0.month == month && $0.day == day && $0.year == year
            }
        }
        XCTAssertTrue(has("Rosh Hashana, no classes", month: 9, day: 13, year: 2026))
        XCTAssertTrue(has("Monday classes meet, remote instruction", month: 9, day: 16, year: 2026))
        XCTAssertTrue(has("Yom Kippur, no classes", month: 9, day: 21, year: 2026))
        XCTAssertTrue(has("Thanksgiving, no classes", month: 11, day: 26, year: 2026))
        XCTAssertTrue(has("YC and SSSB men's midterms", month: 11, day: 9, year: 2026))
        XCTAssertTrue(has("Study day", month: 12, day: 24, year: 2026))
        XCTAssertTrue(has("First day of classes", month: 8, day: 31, year: 2026))
        XCTAssertTrue(has("Last day of the semester", month: 1, day: 5, year: 2027))
        XCTAssertTrue(has("Martin Luther King Jr. Day, no classes, orientation and move in", month: 1, day: 18, year: 2027))
        XCTAssertTrue(has("Purim, no classes", month: 3, day: 23, year: 2027))
        XCTAssertTrue(has("Pesach, no classes", month: 4, day: 22, year: 2027))
        XCTAssertTrue(has("Tuesday classes meet", month: 3, day: 25, year: 2027))
        XCTAssertTrue(has("Commencement, tentative", month: 5, day: 26, year: 2027))
        XCTAssertTrue(has("Last day of the semester", month: 5, day: 25, year: 2027))
    }

    func testNoWomensMidterms() {
        for entry in YUAcademicCalendar.entries {
            XCTAssertFalse(entry.title.contains("Women"), entry.title)
        }
    }

    func testDatesResolveInNewYork() throws {
        let entry = try XCTUnwrap(YUAcademicCalendar.entries.first {
            $0.title == "Rosh Hashana, no classes"
        })
        let date = try XCTUnwrap(YUAcademicCalendar.date(for: entry))
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 13)
    }

    @MainActor
    func testSeedIsIdempotent() throws {
        let container = try ModelContainer(for: YUAcademicEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        // Fresh defaults per run: the seeded flag must not leak between tests.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "yuAcademicCalendarTests"))
        defaults.removeObject(forKey: YUAcademicCalendar.seededVersionKey)
        YUAcademicCalendar.seedIfNeeded(modelContext: context, isYU: false, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YUAcademicEvent>()), 0)
        YUAcademicCalendar.seedIfNeeded(modelContext: context, isYU: true, defaults: defaults)
        let first = try context.fetchCount(FetchDescriptor<YUAcademicEvent>())
        XCTAssertEqual(first, YUAcademicCalendar.entries.count)
        YUAcademicCalendar.seedIfNeeded(modelContext: context, isYU: true, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YUAcademicEvent>()), first)
    }

    @MainActor
    func testReseedsWhenStoreEmptyDespiteFlag() throws {
        let container = try ModelContainer(for: YUAcademicEvent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "yuAcademicCalendarReseedTests"))
        // A failed first save can stamp the flag with no rows. The next
        // launch must heal the store instead of trusting the flag.
        defaults.set(YUAcademicCalendar.seededVersion, forKey: YUAcademicCalendar.seededVersionKey)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YUAcademicEvent>()), 0)
        YUAcademicCalendar.seedIfNeeded(modelContext: context, isYU: true, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YUAcademicEvent>()), YUAcademicCalendar.entries.count)
    }
}
