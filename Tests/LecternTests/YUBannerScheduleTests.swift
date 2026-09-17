import XCTest

final class YUBannerScheduleTests: XCTestCase {
    private func section(subject: String, number: String, title: String, instructor: String,
                        weekdays: [Int], startMinutes: Int) -> YUBannerSection {
        let meeting = YUClassMeeting(
            weekdays: weekdays, startMinutes: startMinutes, endMinutes: startMinutes + 75,
            building: "Furst", room: "501",
            startDate: nil, endDate: nil,
            subjectCourse: "\(subject) \(number)", courseTitle: title,
            instructors: [instructor], termCode: "202610"
        )
        return YUBannerSection(
            courseReferenceNumber: "12345", subject: subject, courseNumber: number,
            subjectCourse: "\(subject) \(number)", courseTitle: title,
            faculty: [.init(displayName: instructor)], meetings: [meeting]
        )
    }

    func testParsesBannerTimes() {
        XCTAssertEqual(YUClassMeeting.parseBannerTime("0900"), 540)
        XCTAssertEqual(YUClassMeeting.parseBannerTime("1330"), 810)
        XCTAssertEqual(YUClassMeeting.parseBannerTime("645"), 405)
        XCTAssertNil(YUClassMeeting.parseBannerTime("TBA"))
        XCTAssertNil(YUClassMeeting.parseBannerTime(nil))
        XCTAssertNil(YUClassMeeting.parseBannerTime("9999"))
    }

    func testSplitCode() {
        XCTAssertEqual(YUBannerSchedule.splitCode("BIOL 101")?.subject, "BIOL")
        XCTAssertEqual(YUBannerSchedule.splitCode("BIO-101A")?.number, "101A")
        // YU Canvas appends the Banner sequence: the course stays JHI 2430.
        XCTAssertEqual(YUBannerSchedule.splitCode("JHI-2430-331")?.subject, "JHI")
        XCTAssertEqual(YUBannerSchedule.splitCode("JHI-2430-331")?.number, "2430")
        XCTAssertNil(YUBannerSchedule.splitCode("Microbiology"))
    }

    func testMatchesRealYUCanvasCode() {
        let sections = [
            section(subject: "JHI", number: "2430", title: "Drashot as a Source of Eastern European Jewry",
                    instructor: "Joshua Karlip", weekdays: [3, 5], startMinutes: 15 * 60)
        ]
        let meetings = YUBannerSchedule.match(canvasCode: "JHI-2430-331", canvasName: "Drashot-Eastern European Jewry",
                                              canvasInstructor: nil, sections: sections)
        XCTAssertEqual(meetings.count, 1)
    }

    func testMatchesByCodeWithSubjectPrefix() {
        let sections = [
            section(subject: "BIOL", number: "101", title: "Microbiology", instructor: "Radhashree Maitra",
                    weekdays: [4], startMinutes: 18 * 60 + 45)
        ]
        // Canvas shortens BIOL to BIO in some exports. Prefix still matches.
        let meetings = YUBannerSchedule.match(canvasCode: "BIO 101", canvasName: "Microbiology",
                                              canvasInstructor: "Radhashree Maitra", sections: sections)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.startMinutes, 18 * 60 + 45)
    }

    func testWrongNumberDoesNotMatch() {
        let sections = [
            section(subject: "BIOL", number: "102", title: "Microbiology", instructor: "Maitra",
                    weekdays: [4], startMinutes: 1125)
        ]
        XCTAssertTrue(YUBannerSchedule.match(canvasCode: "BIO 101", canvasName: "Microbiology",
                                             canvasInstructor: nil, sections: sections).isEmpty)
    }

    func testPickTermMatchesFall2026() {
        let terms = [
            YUBannerTerm(code: "202610", description: "Fall 2026 Semester"),
            YUBannerTerm(code: "202620", description: "Spring 2027 Semester"),
        ]
        XCTAssertEqual(YUBannerSchedule.pickTerm(matching: "Fall 2026", from: terms)?.code, "202610")
    }

    func testNextStartSkipsToMeetingWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        // Sunday Sep 13 2026 noon Eastern. Next Mon/Wed 10:00 is Sep 14.
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 13; parts.hour = 12
        let sunday = calendar.date(from: parts)!
        let meeting = YUClassMeeting(weekdays: [2, 4], startMinutes: 600, endMinutes: 675,
                                     building: nil, room: nil, startDate: nil, endDate: nil,
                                     subjectCourse: nil, courseTitle: nil, instructors: [], termCode: nil)
        let next = meeting.nextStart(after: sunday, calendar: calendar)!
        XCTAssertEqual(calendar.component(.weekday, from: next), 2)
        XCTAssertEqual(calendar.component(.hour, from: next), 10)
    }

    func testNextClassPicksEarliest() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = YUClassMeeting.yuTimeZone
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 13; parts.hour = 12
        let now = calendar.date(from: parts)!
        let early = YUClassMeeting(weekdays: [2], startMinutes: 600, endMinutes: nil,
                                   building: nil, room: nil, startDate: nil, endDate: nil,
                                   subjectCourse: nil, courseTitle: nil, instructors: [], termCode: nil)
        let late = YUClassMeeting(weekdays: [2], startMinutes: 840, endMinutes: nil,
                                  building: nil, room: nil, startDate: nil, endDate: nil,
                                  subjectCourse: nil, courseTitle: nil, instructors: [], termCode: nil)
        let next = YUBannerSchedule.nextClass(in: [
            (name: "Late", code: nil, meetings: [late]),
            (name: "Early", code: nil, meetings: [early]),
        ], now: now)
        XCTAssertEqual(next?.courseName, "Early")
    }

    func testBannerTimeFixesEarlyZoomInvite() throws {
        let message = """
        [Create Meeting]
        Topic: Microbiology
        Host: Radhashree Maitra
        Time: Sep 16, 2026 6:30 PM, Eastern Time (US and Canada)
        Join URL: https://yeshiva-university.zoom.us/j/99277861371
        """
        let invitation = try XCTUnwrap(CanvasZoomInvitation.parse(message).first)
        // Sep 16 2026 is a Wednesday. Banner says class meets Wed 6:45 PM.
        let banner = YUClassMeeting(weekdays: [4], startMinutes: 18 * 60 + 45, endMinutes: 20 * 60,
                                    building: "Furst", room: "501", startDate: nil, endDate: nil,
                                    subjectCourse: "BIOL 101", courseTitle: "Microbiology",
                                    instructors: ["Radhashree Maitra"], termCode: "202610")
        let fixed = invitation.resolvedStart(courseID: 42, events: [], syllabus: nil, bannerMeetings: [banner])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(calendar.component(.hour, from: fixed), 18)
        XCTAssertEqual(calendar.component(.minute, from: fixed), 45)
    }

    func testAmbiguousBannerTimesKeepInvite() throws {
        let message = """
        [Create Meeting]
        Topic: Microbiology
        Host: Radhashree Maitra
        Time: Sep 16, 2026 6:30 PM, Eastern Time (US and Canada)
        Join URL: https://yeshiva-university.zoom.us/j/99277861371
        """
        let invitation = try XCTUnwrap(CanvasZoomInvitation.parse(message).first)
        let first = YUClassMeeting(weekdays: [4], startMinutes: 18 * 60 + 45, endMinutes: nil,
                                   building: nil, room: nil, startDate: nil, endDate: nil,
                                   subjectCourse: nil, courseTitle: nil, instructors: [], termCode: nil)
        let second = YUClassMeeting(weekdays: [4], startMinutes: 18 * 60 + 50, endMinutes: nil,
                                    building: nil, room: nil, startDate: nil, endDate: nil,
                                    subjectCourse: nil, courseTitle: nil, instructors: [], termCode: nil)
        XCTAssertEqual(invitation.resolvedStart(courseID: 42, events: [], bannerMeetings: [first, second]),
                       invitation.startAt)
    }

    func testDecodeTermsAcceptsNumericCodes() throws {
        let data = Data("""
        [{"code": 202610, "description": "Fall 2026 Semester"}]
        """.utf8)
        let terms = try YUBannerClient.decodeTerms(data)
        XCTAssertEqual(terms.first?.code, "202610")
    }

    func testDecodeSectionMeetings() throws {
        let data = Data("""
        {"subject": "BIOL", "courseNumber": "101", "subjectCourse": "BIOL 101",
         "courseTitle": "Microbiology",
         "faculty": [{"displayName": "Radhashree Maitra"}],
         "meetingsFaculty": [{"meetingTime": {
           "beginTime": "1830", "endTime": "2015",
           "monday": false, "tuesday": false, "wednesday": true, "thursday": false,
           "friday": false, "saturday": false, "sunday": false,
           "building": "Furst", "room": "501",
           "startDate": "08/27/2026", "endDate": "12/18/2026"}}]}
        """.utf8)
        let section = try JSONDecoder().decode(YUBannerSection.self, from: data)
        XCTAssertEqual(section.meetings.count, 1)
        XCTAssertEqual(section.meetings.first?.weekdays, [4])
        XCTAssertEqual(section.meetings.first?.startMinutes, 18 * 60 + 30)
        XCTAssertEqual(section.meetings.first?.locationDisplay, "Furst 501")
    }
}
