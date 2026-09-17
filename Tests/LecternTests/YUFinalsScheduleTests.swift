import XCTest

final class YUFinalsScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        return calendar
    }

    private func parts(_ date: Date) -> (month: Int, day: Int, year: Int, hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.month, .day, .year, .hour, .minute], from: date)
        return (parts.month!, parts.day!, parts.year!, parts.hour!, parts.minute!)
    }

    // MARK: - Parsing

    func testParseCanvasCode() {
        let parsed = YUFinalsSchedule.parseCanvasCode("JHI-2430-331")
        XCTAssertEqual(parsed?.subject, "JHI")
        XCTAssertEqual(parsed?.number, "2430")
        XCTAssertEqual(parsed?.section, "331")
        XCTAssertNil(YUFinalsSchedule.parseCanvasCode("ACC 1001")?.section)
        XCTAssertEqual(YUFinalsSchedule.parseCanvasCode("ACC 1001")?.number, "1001")
        XCTAssertNil(YUFinalsSchedule.parseCanvasCode(nil))
    }

    func testNormalizedSection() {
        XCTAssertEqual(YUFinalsSchedule.normalizedSection("232"), "231")
        XCTAssertEqual(YUFinalsSchedule.normalizedSection("243"), "241")
        XCTAssertEqual(YUFinalsSchedule.normalizedSection("B"), "B")
        XCTAssertEqual(YUFinalsSchedule.normalizedSection("331"), "331")
    }

    // MARK: - Grid

    func testTestClassSection331() {
        // JHI-2430-331 from the screenshot: Wednesday Dec 30 morning.
        let slot = YUFinalsSchedule.slot(section: "331", subject: "JHI", number: "2430", school: .yc, campus: "Wilf")
        let start = try! XCTUnwrap(slot?.start)
        XCTAssertEqual(parts(start).month, 12)
        XCTAssertEqual(parts(start).day, 30)
        XCTAssertEqual(parts(start).year, 2026)
        XCTAssertEqual(parts(start).hour, 9)
        XCTAssertEqual(parts(start).minute, 30)
        XCTAssertEqual(parts(try! XCTUnwrap(slot?.end)).hour, 11)
    }

    func testDashTwoFoldsToDashOne() {
        let folded = YUFinalsSchedule.slot(section: "232", subject: "ACC", number: "1002", school: .syms, campus: "Wilf")
        let direct = YUFinalsSchedule.slot(section: "231", subject: "ACC", number: "1002", school: .syms, campus: "Wilf")
        XCTAssertEqual(folded, direct)
        XCTAssertEqual(parts(try! XCTUnwrap(folded?.start)).day, 5)
        XCTAssertEqual(parts(try! XCTUnwrap(folded?.start)).year, 2027)
    }

    func testExplicit432KeepsListedSlot() {
        let slot = YUFinalsSchedule.slot(section: "432", subject: "X", number: "1", school: nil, campus: "Wilf")
        XCTAssertEqual(parts(try! XCTUnwrap(slot?.start)).day, 5)
        XCTAssertEqual(parts(try! XCTUnwrap(slot?.start)).month, 1)
    }

    // MARK: - Overrides and Hebrew

    func testCourseOverrideBeatsSectionGrid() {
        // ACC 1001 section 241 would sit Monday Dec 28 by grid, but the Syms
        // row moves the whole course to Sunday Jan 3 morning.
        let slot = YUFinalsSchedule.slot(section: "241", subject: "ACC", number: "1001", school: .syms, campus: "Wilf")
        let start = try! XCTUnwrap(slot?.start)
        XCTAssertEqual(parts(start).month, 1)
        XCTAssertEqual(parts(start).day, 3)
        XCTAssertEqual(parts(start).year, 2027)
        XCTAssertEqual(parts(start).hour, 9)
    }

    func testIDSCourseExamsSundayAfternoon() {
        let slot = YUFinalsSchedule.slot(section: "341", subject: "IDS", number: "1131", school: .syms, campus: "Wilf")
        let start = try! XCTUnwrap(slot?.start)
        XCTAssertEqual(parts(start).day, 3)
        XCTAssertEqual(parts(start).hour, 13)
    }

    func testHebrewSectionExamsThursdayAfternoon() {
        let slot = YUFinalsSchedule.slot(section: "341", subject: "HEB", number: "1040", school: .yc, campus: "Wilf")
        let start = try! XCTUnwrap(slot?.start)
        XCTAssertEqual(parts(start).month, 12)
        XCTAssertEqual(parts(start).day, 31)
        XCTAssertEqual(parts(start).hour, 13)
    }

    // MARK: - School split and campus gate

    func testSection511SplitsBySchool() {
        let yc = YUFinalsSchedule.slot(section: "511", subject: "BIB", number: "2110", school: .yc, campus: "Wilf")
        XCTAssertEqual(parts(try! XCTUnwrap(yc?.start)).day, 30)
        let syms = YUFinalsSchedule.slot(section: "511", subject: "JUD", number: "2613", school: .syms, campus: "Wilf")
        XCTAssertEqual(parts(try! XCTUnwrap(syms?.start)).day, 31)
        XCTAssertNil(YUFinalsSchedule.slot(section: "511", subject: "X", number: "1", school: nil, campus: "Wilf"))
    }

    func testNonWilfCampusIsSkipped() {
        XCTAssertNil(YUFinalsSchedule.slot(section: "331", subject: "JHI", number: "2430", school: .yc, campus: "Beren"))
        XCTAssertNil(YUFinalsSchedule.slot(section: "331", subject: "JHI", number: "2430", school: .yc, campus: "Wilf (Online)"))
        XCTAssertNil(YUFinalsSchedule.slot(section: "241", subject: "ACC", number: "1001", school: .syms, campus: "Beren"))
        // Unknown campus (Canvas-only fallback) still resolves.
        XCTAssertNotNil(YUFinalsSchedule.slot(section: "331", subject: "JHI", number: "2430", school: nil, campus: nil))
    }

    // MARK: - School inference

    func testSchoolFromPartOfTermAndAttributes() {
        XCTAssertEqual(YUBannerSection(partOfTerm: "YC1").school, .yc)
        XCTAssertEqual(YUBannerSection(partOfTerm: "UB4").school, .syms)
        XCTAssertEqual(YUBannerSection(partOfTerm: "UB1").school, .syms)
        XCTAssertEqual(YUBannerSection(attributeCodes: ["SYBC"]).school, .syms)
        XCTAssertNil(YUBannerSection(partOfTerm: "AM1").school)
        XCTAssertNil(YUBannerSection().school)
    }

    func testDecodeSectionMetadata() throws {
        let data = Data("""
        {"subject": "ACC", "courseNumber": "1001", "subjectCourse": "ACC1001",
         "sequenceNumber": "241", "partOfTerm": "UB4", "campusDescription": "Wilf",
         "sectionAttributes": [{"code": "SYBC", "description": "Sy Syms-UG Business Core"}],
         "faculty": [], "meetingsFaculty": []}
        """.utf8)
        let section = try JSONDecoder().decode(YUBannerSection.self, from: data)
        XCTAssertEqual(section.sequenceNumber, "241")
        XCTAssertEqual(section.partOfTerm, "UB4")
        XCTAssertEqual(section.campusDescription, "Wilf")
        XCTAssertEqual(section.attributeCodes, ["SYBC"])
        XCTAssertEqual(section.school, .syms)
    }

    // MARK: - One final per course

    @MainActor
    func testCanvasCodeFallbackNeedsNoBannerRow() {
        // Microbiology never matched Banner, but its code suffix still resolves.
        let course = Course(name: "Microbiology", colorHex: "#fff")
        course.canvasID = 9
        course.courseCode = "BIO-4023-261"
        let exam = YUBannerSyncService.finalExam(for: course, matchedSections: [],
                                                term: YUBannerTerm(code: "202609", description: "Fall 2026"))
        let start = try! XCTUnwrap(exam?.startAt)
        XCTAssertEqual(parts(start).month, 1)
        XCTAssertEqual(parts(start).day, 4)
        XCTAssertEqual(parts(start).hour, 13)
    }

    @MainActor
    func testFinalExamForTestClass() {
        let course = Course(name: "Drashot-Eastern European Jewry", colorHex: "#fff")
        course.canvasID = 7
        course.courseCode = "JHI-2430-331"
        let sections = [YUBannerSection(subject: "JHI", courseNumber: "2430", subjectCourse: "JHI2430",
                                        sequenceNumber: "331", partOfTerm: "YC1", campusDescription: "Wilf")]
        let exam = YUBannerSyncService.finalExam(for: course, matchedSections: sections,
                                                term: YUBannerTerm(code: "202609", description: "Fall 2026"))
        XCTAssertEqual(parts(try! XCTUnwrap(exam?.startAt)).day, 30)
        XCTAssertEqual(exam?.sectionCode, "331")
        XCTAssertEqual(exam?.termCode, "202609")
    }

    @MainActor
    func testDashTwoVariantSharesDashOneFinal() {
        // Microbiology matched both 261 and 262. Same slot, one final.
        let course = Course(name: "Microbiology", colorHex: "#fff")
        course.canvasID = 9
        course.courseCode = "BIO-4023-261"
        let sections = [
            YUBannerSection(subject: "BIO", courseNumber: "4023", sequenceNumber: "261",
                            partOfTerm: "YC1", campusDescription: "Wilf"),
            YUBannerSection(subject: "BIO", courseNumber: "4023", sequenceNumber: "262",
                            partOfTerm: "YC1", campusDescription: "Wilf"),
        ]
        let exam = YUBannerSyncService.finalExam(for: course, matchedSections: sections,
                                                term: YUBannerTerm(code: "202609", description: "Fall 2026"))
        let start = try! XCTUnwrap(exam?.startAt)
        XCTAssertEqual(parts(start).month, 1)
        XCTAssertEqual(parts(start).day, 4)
        XCTAssertEqual(parts(start).hour, 13)
    }

    @MainActor
    func testConflictingSequencesYieldNoFinal() {
        let course = Course(name: "Accounting Principles I", colorHex: "#fff")
        course.courseCode = "ACC-1001-241"
        let sections = [
            YUBannerSection(subject: "ACC", courseNumber: "1001", sequenceNumber: "241",
                            partOfTerm: "UB4", campusDescription: "Wilf"),
            YUBannerSection(subject: "ACC", courseNumber: "1001", sequenceNumber: "311",
                            partOfTerm: "UB4", campusDescription: "Wilf"),
        ]
        XCTAssertNil(YUBannerSyncService.finalExam(for: course, matchedSections: sections,
                                                   term: YUBannerTerm(code: "202609", description: "Fall 2026")))
    }

    // MARK: - YU host gate

    func testYUHostGate() {
        XCTAssertTrue(CanvasConnectionSettings.isYUHost("yu.instructure.com"))
        XCTAssertTrue(CanvasConnectionSettings.isYUHost("https://yu.instructure.com/"))
        XCTAssertTrue(CanvasConnectionSettings.isYUHost("YU.INSTRUCTURE.COM"))
        XCTAssertFalse(CanvasConnectionSettings.isYUHost("canvas.yu.edu"))
        XCTAssertFalse(CanvasConnectionSettings.isYUHost("other.instructure.com"))
        XCTAssertFalse(CanvasConnectionSettings.isYUHost(""))
    }
}
