import XCTest

final class CanvasHTMLTextCacheTests: XCTestCase {
    func testRepeatedHTMLUsesParsedValueOnce() {
        let cache = CanvasHTMLTextCache(countLimit: 4, totalCostLimit: 1_024)
        var parseCount = 0

        let first = cache.text(for: "<p>Canvas announcement</p>") { source in
            parseCount += 1
            return "parsed: \(source)"
        }
        let second = cache.text(for: "<p>Canvas announcement</p>") { _ in
            parseCount += 1
            return "unexpected"
        }

        XCTAssertEqual(first, "parsed: <p>Canvas announcement</p>")
        XCTAssertEqual(second, first)
        XCTAssertEqual(parseCount, 1)
    }

    func testPlainTextBypassesHTMLParser() {
        let cache = CanvasHTMLTextCache(countLimit: 4, totalCostLimit: 1_024)
        var parseCount = 0

        let result = cache.text(for: "Already plain text") { _ in
            parseCount += 1
            return "unexpected"
        }

        XCTAssertEqual(result, "Already plain text")
        XCTAssertEqual(parseCount, 0)
    }
}
