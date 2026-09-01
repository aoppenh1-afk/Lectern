import XCTest

final class NotesMarkdownTests: XCTestCase {
    // MARK: - Depth resolution

    func testScannerResolvesFourSpaceNesting() {
        let depths = Self.depths(of: """
        - **Isotopes:** same protons, different neutrons
            - Sometimes radioactive
                - Main ex: Carbon-14
            - Used for carbon dating
        - **Molarity:** moles per liter
        """)
        XCTAssertEqual(depths, [0, 1, 2, 1, 0])
    }

    func testScannerResolvesTwoSpaceAndTabNestingTheSameWay() {
        let twoSpace = Self.depths(of: "- a\n  - b\n    - c\n  - d")
        let tabs = Self.depths(of: "- a\n\t- b\n\t\t- c\n\t- d")
        XCTAssertEqual(twoSpace, [0, 1, 2, 1])
        XCTAssertEqual(tabs, [0, 1, 2, 1])
    }

    func testHeadingsAndParagraphsEndTheCurrentList() {
        var scanner = NotesListScanner()
        XCTAssertEqual(scanner.scan("- a")?.depth, 0)
        XCTAssertEqual(scanner.scan("    - b")?.depth, 1)
        XCTAssertNil(scanner.scan("## Next topic"))
        XCTAssertEqual(scanner.scan("    - c")?.depth, 0, "A heading resets nesting.")
        XCTAssertNil(scanner.scan("Plain paragraph"))
        XCTAssertEqual(scanner.scan("        - d")?.depth, 0, "A flush-left paragraph resets nesting.")
    }

    func testOrderedItemsGetDecimalAlphaRomanLabelsByDepth() {
        var scanner = NotesListScanner()
        let lines = [
            "1. Death was everywhere",
            "    1. Cemeteries in churchyards",
            "        1. Upper class buried inside",
            "        1. Everyone else outside",
            "    1. High death rate",
            "1. Death rates were high",
        ]
        let labels = lines.compactMap { scanner.scan($0)?.orderedLabel }
        XCTAssertEqual(labels, ["1.", "a.", "i.", "ii.", "b.", "2."])
    }

    func testAlphaAndRomanLabelsExtend() {
        XCTAssertEqual(NotesListLine.alphaLabel(26), "z")
        XCTAssertEqual(NotesListLine.alphaLabel(27), "aa")
        XCTAssertEqual(NotesListLine.romanLabel(4), "iv")
        XCTAssertEqual(NotesListLine.romanLabel(14), "xiv")
    }

    // MARK: - Normalizer

    func testNormalizerRewritesToCanonicalFourSpaceDashOutline() {
        let raw = """
        ```markdown
        # Cells

        ## Organelles

        * **Nucleus:** stores DNA
          * Surrounded by a double membrane
            + Has pores
          • Contains the nucleolus
        1) Step one
           1) Sub step
        ```
        """
        let expected = """
        # Cells

        ## Organelles

        - **Nucleus:** stores DNA
            - Surrounded by a double membrane
                - Has pores
            - Contains the nucleolus
        1. Step one
            1. Sub step
        """
        XCTAssertEqual(NotesMarkdownNormalizer.normalize(raw), expected)
    }

    func testNormalizerSplitsInlineDotBulletsAndLeavesHyphensAlone() {
        let raw = "- Types • monosaccharides • disaccharides\n• Ribose • Glucose\n- Range 5 - 10 - 15"
        let expected = "- Types • monosaccharides • disaccharides\n- Ribose\n- Glucose\n- Range 5 - 10 - 15"
        XCTAssertEqual(NotesMarkdownNormalizer.normalize(raw), expected)
    }

    func testNormalizerLeavesMermaidFenceUntouched() {
        let raw = """
        # Flow

        ```mermaid
        graph TD
          A --> B
        ```
        """
        XCTAssertEqual(NotesMarkdownNormalizer.normalize(raw), raw)
    }

    // MARK: - Validator

    func testValidatorRejectsFlatOutlineForDevelopedLecture() {
        let source = String(repeating: "The lecture develops a detailed causal argument. ", count: 80)
        let flat = "# Enzymes\n\n## Catalysts\n\n"
            + (1...NotesOutputValidator.flatOutlineThreshold).map { "- Point \($0)" }.joined(separator: "\n")
        let violations = NotesOutputValidator.violations(in: flat, source: source, language: .english)
        XCTAssertTrue(violations.contains(where: { $0.contains("four-space indentation") }), "\(violations)")
    }

    func testValidatorAcceptsNestedOutlineAndRejectsStrayFences() {
        let nested = "# Enzymes\n\n## Catalysts\n\n"
            + (1...NotesOutputValidator.flatOutlineThreshold).map { "- Point \($0)\n    - Detail \($0)" }.joined(separator: "\n")
        XCTAssertEqual(NotesOutputValidator.violations(in: nested, source: "short", language: .english), [])

        let fenced = nested + "\n\n```\n- stray\n```"
        let violations = NotesOutputValidator.violations(in: fenced, source: "short", language: .english)
        XCTAssertTrue(violations.contains(where: { $0.contains("code fence") }), "\(violations)")

        let mermaid = nested + "\n\n```mermaid\ngraph TD\n  A --> B\n```"
        XCTAssertEqual(NotesOutputValidator.violations(in: mermaid, source: "short", language: .english), [])
    }

    // MARK: - Google Docs plan

    func testGoogleDocsPlanCarriesDepthAsLeadingTabsAndBulletsFromTheEnd() {
        let markdown = """
        # Title

        - **Term:** definition
            - detail
        1. first
            1. nested
        """
        let plan = NotesMarkdownConverter.plan(markdown: markdown)
        XCTAssertEqual(plan.text, "Title\nTerm: definition\n\tdetail\nfirst\n\tnested")

        XCTAssertEqual(plan.bulletRanges.count, 2)
        XCTAssertEqual(plan.bulletRanges[0].preset, NotesMarkdownConverter.bulletPreset)
        XCTAssertEqual(plan.bulletRanges[1].preset, NotesMarkdownConverter.numberedPreset)

        // "Title\n" occupies indices 1..<7; the bullet run starts right after.
        XCTAssertEqual(plan.bulletRanges[0].start, 7)
        XCTAssertEqual(plan.bulletRanges[0].end, plan.bulletRanges[1].start)

        // Bold offsets account for the depth tabs that precede the text.
        XCTAssertEqual(plan.boldRanges.first?.start, 7)
        XCTAssertEqual(plan.boldRanges.first?.end, 7 + "Term:".utf16.count)

        let requests = plan.requests(tabId: "t", existingBodyEndIndex: 1)
        let kinds = requests.compactMap { $0.keys.first }
        let firstBulletIndex = kinds.firstIndex(of: "createParagraphBullets")!
        XCTAssertTrue(kinds[..<firstBulletIndex].allSatisfy { $0 != "createParagraphBullets" })
        XCTAssertFalse(kinds[firstBulletIndex...].contains("updateTextStyle"), "Bullets apply after every style.")
        let starts = requests.compactMap { request -> Int? in
            guard let bullets = request["createParagraphBullets"] as? [String: Any],
                  let range = bullets["range"] as? [String: Any] else { return nil }
            return range["startIndex"] as? Int
        }
        XCTAssertEqual(starts, starts.sorted(by: >), "Bullets apply from the end of the document backwards.")
    }

    private static func depths(of markdown: String) -> [Int] {
        var scanner = NotesListScanner()
        return markdown.components(separatedBy: "\n").compactMap { scanner.scan($0)?.depth }
    }
}
