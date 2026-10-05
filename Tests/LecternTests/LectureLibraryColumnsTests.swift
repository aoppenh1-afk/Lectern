import XCTest

final class LectureLibraryColumnsTests: XCTestCase {
    func testWideLibraryKeepsDesignedColumns() {
        let columns = LectureLibraryColumns.fit(1200)
        XCTAssertEqual(columns.courses, LectureLibraryColumns.coursesMax)
        XCTAssertEqual(columns.lectures, LectureLibraryColumns.lecturesMax)
        XCTAssertEqual(columns.detail, 1200 - 2 - 244 - 316)
    }

    func testWindowedLibraryShrinksListsBeforeTheDetail() {
        let columns = LectureLibraryColumns.fit(900)
        XCTAssertGreaterThanOrEqual(columns.detail, LectureLibraryColumns.detailMin)
        XCTAssertLessThan(columns.lectures, LectureLibraryColumns.lecturesMax)
        XCTAssertEqual(columns.courses + columns.lectures + columns.detail, 898, accuracy: 0.001)
    }

    func testNarrowLibraryStaysNonNegative() {
        let columns = LectureLibraryColumns.fit(120)
        XCTAssertGreaterThanOrEqual(columns.courses, 0)
        XCTAssertGreaterThanOrEqual(columns.lectures, 0)
        XCTAssertGreaterThanOrEqual(columns.detail, 0)
        XCTAssertEqual(columns.courses + columns.lectures + columns.detail, 118, accuracy: 0.001)
    }
}
