import Foundation
import Observation
import SwiftData

/// Pulls YU's public Banner schedule and cross-checks it against Canvas courses.
///
/// YU-only: every entry point requires a Canvas connection to
/// yu.instructure.com. Other schools never fetch Banner and never see Banner
/// times or finals.
///
/// Banner needs no login. The registrar publishes courses, faculty, times, and
/// locations for browsing. Lectern fetches the whole term once a day, matches
/// each Fall 2026 Canvas course by subject and number, then instructor, and
/// stores the weekly meetings on the local Course. The same pass resolves one
/// final exam per course from the Wilf finals grid and refreshes YUFinalExam
/// rows for the Calendar tab. Overview and Zoom reminders read those meetings.
/// A Banner miss never clears Canvas data. It only leaves the old meetings in place.
@MainActor
@Observable
final class YUBannerSyncService {
    struct Result: Sendable {
        let term: YUBannerTerm
        let sectionCount: Int
        let matchedCourses: Int
        let finalsCount: Int
    }

    private static let lastSyncKey = "yuBanner.lastSuccessfulSync"
    private static let lastTermCodeKey = "yuBanner.lastTermCode"
    private static let maxAge: TimeInterval = 24 * 60 * 60

    private let modelContainer: ModelContainer
    private let client: YUBannerClient
    private let defaults: UserDefaults
    private let connection: CanvasConnectionSettings?

    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    init(modelContainer: ModelContainer, client: YUBannerClient = YUBannerClient(),
         defaults: UserDefaults = .standard, connection: CanvasConnectionSettings? = nil) {
        self.modelContainer = modelContainer
        self.client = client
        self.defaults = defaults
        self.connection = connection
        lastSyncAt = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    private var isYU: Bool { connection?.isYUConnected ?? true }

    func syncIfNeeded(selectedTerm: String, maxAge: TimeInterval = YUBannerSyncService.maxAge) async {
        guard isYU, !isSyncing else { return }
        if let last = lastSyncAt, Date().timeIntervalSince(last) < maxAge { return }
        await syncNow(selectedTerm: selectedTerm)
    }

    @discardableResult
    func syncNow(selectedTerm: String) async -> Result? {
        guard isYU, !isSyncing else { return nil }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let terms = try await client.fetchTerms()
            guard let term = YUBannerSchedule.pickTerm(matching: selectedTerm, from: terms) else {
                throw YUBannerError.termNotFound(selectedTerm)
            }
            let sections = try await client.fetchAllSections(termCode: term.code)
            let (matched, finals) = try apply(sections: sections, term: term, selectedTerm: selectedTerm)
            let now = Date()
            lastSyncAt = now
            lastError = nil
            defaults.set(now, forKey: Self.lastSyncKey)
            defaults.set(term.code, forKey: Self.lastTermCodeKey)
            return Result(term: term, sectionCount: sections.count, matchedCourses: matched, finalsCount: finals)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func apply(sections: [YUBannerSection], term: YUBannerTerm, selectedTerm: String) throws -> (Int, Int) {
        let context = modelContainer.mainContext
        let all = try context.fetch(FetchDescriptor<Course>())
        // Full refresh for this Banner term: stale finals must never linger.
        let oldFinals = try context.fetch(FetchDescriptor<YUFinalExam>()).filter { $0.termCode == term.code }
        for stale in oldFinals { context.delete(stale) }
        var matched = 0
        var finals = 0
        for course in all {
            // Local-only courses have no Canvas term. Leave them alone.
            guard course.canvasID != nil else { continue }
            guard let termName = course.termName,
                  AcademicScopeMatcher.matches(term: termName, selectedTerm: selectedTerm) else { continue }
            let ranked = sections.compactMap { section -> (Int, YUBannerSection)? in
                let points = YUBannerSchedule.score(canvasCode: course.courseCode, canvasName: course.name,
                                                    canvasInstructor: course.instructorName, section: section)
                guard points >= 6, !section.meetings.isEmpty else { return nil }
                return (points, section)
            }.sorted { $0.0 > $1.0 }
            let topSections: [YUBannerSection] = {
                guard let top = ranked.first?.0 else { return [] }
                return ranked.filter { $0.0 == top }.map { $0.1 }
            }()
            let meetings = topSections.flatMap(\.meetings)
            if !meetings.isEmpty {
                var stamped = meetings
                for index in stamped.indices { stamped[index].termCode = term.code }
                course.bannerMeetings = stamped
                course.bannerTermCode = term.code
                course.bannerSubjectCourse = stamped.first?.subjectCourse
                course.bannerUpdatedAt = Date()
                matched += 1
            }
            if let exam = Self.finalExam(for: course, matchedSections: topSections, term: term) {
                context.insert(exam)
                finals += 1
            }
        }
        try context.save()
        return (matched, finals)
    }

    /// One final per course. Multiple distinct Banner sequences means a bad
    /// match, so the course gets no final rather than a guessed one.
    static func finalExam(for course: Course, matchedSections: [YUBannerSection], term: YUBannerTerm) -> YUFinalExam? {
        let distinctSequences = Set(matchedSections.compactMap(\.sequenceNumber))
        if distinctSequences.count > 1 { return nil }
        if let sequence = distinctSequences.first {
            let section = matchedSections.first { $0.sequenceNumber == sequence }
            let subject = section?.subject ?? YUFinalsSchedule.parseCanvasCode(course.courseCode)?.subject
            let number = section?.courseNumber ?? YUFinalsSchedule.parseCanvasCode(course.courseCode)?.number
            guard let slot = YUFinalsSchedule.slot(section: sequence, subject: subject, number: number,
                                                   school: section?.school,
                                                   campus: section?.campusDescription) else { return nil }
            return makeExam(course: course, section: sequence, slot: slot, term: term, source: "registrar")
        }
        // No Banner row. Fall back to the Canvas code suffix, such as the 331
        // in JHI-2430-331. Campus and school are unknown on this path, so
        // school-split sections stay unresolved.
        guard let parsed = YUFinalsSchedule.parseCanvasCode(course.courseCode),
              let section = parsed.section,
              let slot = YUFinalsSchedule.slot(section: section, subject: parsed.subject, number: parsed.number,
                                               school: nil, campus: nil) else { return nil }
        return makeExam(course: course, section: section, slot: slot, term: term, source: "canvas-code")
    }

    private static func makeExam(course: Course, section: String, slot: YUFinalsSchedule.Slot,
                                 term: YUBannerTerm, source: String) -> YUFinalExam {
        let exam = YUFinalExam(courseCanvasID: course.canvasID, courseName: course.name,
                               title: "\(course.name) final", startAt: slot.start)
        exam.endAt = slot.end
        exam.sectionCode = section
        exam.sourceRaw = source
        exam.termCode = term.code
        exam.termLabel = YUFinalsSchedule.termLabel
        return exam
    }
}
