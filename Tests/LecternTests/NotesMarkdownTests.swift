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
        XCTAssertNil(scanner.scan("#UPDATES"), "A heading without space also ends the list.")
        XCTAssertEqual(scanner.scan("    - c2")?.depth, 0, "A heading resets nesting.")
        XCTAssertNil(scanner.scan("Plain paragraph"))
        XCTAssertEqual(scanner.scan("        - d")?.depth, 0, "A flush-left paragraph resets nesting.")
    }

    func testHeadingWithoutSpaceMatchesHeading() {
        let plan = NotesMarkdownConverter.plan(markdown: "#UPDATES\n- item 1\n##FIXES\n- item 2")
        XCTAssertEqual(plan.headingRanges.count, 2)
        XCTAssertEqual(plan.headingRanges[0].level, 1)
        XCTAssertEqual(plan.headingRanges[1].level, 2)
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
        XCTAssertFalse(
            kinds[firstBulletIndex...].contains("updateParagraphStyle"),
            "Paragraph direction applies before Docs removes the depth tabs."
        )
        let starts = requests.compactMap { request -> Int? in
            guard let bullets = request["createParagraphBullets"] as? [String: Any],
                  let range = bullets["range"] as? [String: Any] else { return nil }
            return range["startIndex"] as? Int
        }
        XCTAssertEqual(starts, starts.sorted(by: >), "Bullets apply from the end of the document backwards.")
    }

    func testGoogleDocsPlanKeepsHebrewListBulletsLTRAndIsolatesTheirText() {
        let markdown = """
        # דין בישול אחר בישול בדבר לח (שבת לד.-לד:)

        - **משנה:** בפרק במה טומנין (דף מז:): Distinguishes between two classes.
            - גזירה שמא ירתיח (שבת)
        - Q (רש״י, ד״ה וטומנין): Derived from the משנה.
        - English with דבר לח (liquids, broth).
        2026 — דבר לח שנצטנן
        """
        let plan = NotesMarkdownConverter.plan(markdown: markdown)
        let lines = plan.text.components(separatedBy: "\n")

        XCTAssertEqual(
            lines[1],
            "\u{2067}משנה\u{2069}: \u{2067}בפרק במה טומנין\u{2069} (\u{2067}דף מז\u{2069}:): Distinguishes between two classes."
        )
        XCTAssertEqual(lines[2], "\t\u{2067}גזירה שמא ירתיח\u{2069} (\u{2067}שבת\u{2069})")
        XCTAssertEqual(
            Self.visible((plan.text as NSString).substring(
                with: NSRange(
                    location: plan.boldRanges[0].start - 1,
                    length: plan.boldRanges[0].end - plan.boldRanges[0].start
                )
            )),
            "משנה:"
        )

        let requests = plan.requests(tabId: "t", existingBodyEndIndex: 1)

        let directions = requests.compactMap { request -> String? in
            guard let update = request["updateParagraphStyle"] as? [String: Any],
                  let style = update["paragraphStyle"] as? [String: Any] else { return nil }
            return style["direction"] as? String
        }
        let alignments = requests.compactMap { request -> String? in
            guard let update = request["updateParagraphStyle"] as? [String: Any],
                  let style = update["paragraphStyle"] as? [String: Any],
                  style["direction"] != nil else { return nil }
            return style["alignment"] as? String
        }

        XCTAssertEqual(
            directions,
            [
                "LEFT_TO_RIGHT",
                "LEFT_TO_RIGHT",
                "LEFT_TO_RIGHT",
                "LEFT_TO_RIGHT",
                "LEFT_TO_RIGHT",
                "LEFT_TO_RIGHT",
            ]
        )
        XCTAssertEqual(alignments, Array(repeating: "START", count: 6))
    }

    func testGoogleDocsPlanKeepsLeadingHebrewBoldLabelBeforeEnglishContinuation() {
        let markdown = """
        - **שיטת שאר ראשונים (תוס׳, ריטב״א):** שהייה and הטמנה are two entirely separate realms with distinct mechanisms
        """
        let plan = NotesMarkdownConverter.plan(markdown: markdown)

        XCTAssertEqual(
            plan.text,
            "\u{2067}שיטת שאר ראשונים\u{2069} (\u{2067}תוס׳\u{2069}, \u{2067}ריטב״א\u{2069}): "
                + "\u{2067}שהייה\u{2069} and \u{2067}הטמנה\u{2069} "
                + "are two entirely separate realms with distinct mechanisms"
        )
        XCTAssertEqual(
            Self.visible((plan.text as NSString).substring(
                with: NSRange(
                    location: plan.boldRanges[0].start - 1,
                    length: plan.boldRanges[0].end - plan.boldRanges[0].start
                )
            )),
            "שיטת שאר ראשונים (תוס׳, ריטב״א):"
        )
    }

    func testGoogleDocsIsolatesEnglishLedHebrewWithoutSwallowingParentheses() {
        let plan = NotesMarkdownConverter.plan(
            markdown: "- On שבת (שלא יוסיף הבל בשבת)"
        )
        XCTAssertEqual(plan.text, "On \u{2067}שבת\u{2069} (\u{2067}שלא יוסיף הבל בשבת\u{2069})")
    }

    func testGoogleDocsKeepsCommasSemicolonsAndFractionsInLTRContext() {
        let plan = NotesMarkdownConverter.plan(
            markdown: "- שבת (רש״י: 1/3 cooked; רמב״ם: 1/2 cooked), הטמנה, שהייה"
        )
        XCTAssertEqual(
            plan.text,
            "\u{2067}שבת\u{2069} (\u{2067}רש״י\u{2069}: 1/3 cooked; "
                + "\u{2067}רמב״ם\u{2069}: 1/2 cooked), \u{2067}הטמנה\u{2069}, \u{2067}שהייה\u{2069}"
        )
    }

    func testGoogleDocsKeepsNestedBracketsQuotesAndNumericLabelsOutsideHebrewRuns() {
        let examples = [
            "נ״מ 1 on שבת (בלעך):",
            "רבא (מימרא 1): הטמנה on שבת itself",
            "Q: why did חז״ל say אין טומנין on ערב שבת?",
            "On שבת (\"ולא חיישינן אם מתבשל והולך בשבת\")",
            "ברייתא (חנניה [דף כ:])",
            "רש\"י, תוס' (ד\"ה במה): 1/3",
        ]
        for example in examples {
            let plan = NotesMarkdownConverter.plan(markdown: "- " + example)
            XCTAssertEqual(Self.visible(plan.text), example)
            var inside = false
            for scalar in plan.text.unicodeScalars {
                if scalar.value == 0x2067 {
                    XCTAssertFalse(inside, example)
                    inside = true
                } else if scalar.value == 0x2069 {
                    XCTAssertTrue(inside, example)
                    inside = false
                } else if "()[]{}:,;?/0123456789".unicodeScalars.contains(scalar) {
                    XCTAssertFalse(inside, "Punctuation or number inside Hebrew isolate: \(example)")
                }
            }
            XCTAssertFalse(inside, example)
        }
    }

    func testGoogleDocsPreservesBoldAndParagraphUTF16OffsetsAfterIsolation() {
        let plan = NotesMarkdownConverter.plan(markdown: """
        # שבת (בישול)
        - 🧪 **רש״י:** 1/3 cooked; **רמב״ם:** 1/2 cooked
            - **נ״מ 1:** on שבת (בלעך)
        - **English:** unchanged
        """)
        let text = plan.text as NSString
        let labels = plan.boldRanges.map {
            Self.visible(text.substring(with: NSRange(location: $0.start - 1, length: $0.end - $0.start)))
        }
        XCTAssertEqual(labels, ["רש״י:", "רמב״ם:", "נ״מ 1:", "English:"])
        let lines = plan.text.components(separatedBy: "\n")
        var start = 1
        for (line, range) in zip(lines, plan.directionRanges) {
            XCTAssertEqual(range.start, start)
            XCTAssertEqual(range.end, start + line.utf16.count + 1)
            XCTAssertEqual(range.direction, "LEFT_TO_RIGHT")
            start = range.end
        }
        XCTAssertTrue(lines[2].hasPrefix("\t"), "Depth tabs must precede direction controls")
    }

    func testGoogleDocsRebuildsPastedDirectionControlsBeforeParsingMarkdown() {
        let clean = "# שבת\n- **רש״י:** on שבת (בלעך)"
        let pasted = "\u{200F}# \u{202B}שבת\u{202C}\n\u{200E}- **\u{2067}רש״י\u{2069}:** on שבת (בלעך)\u{2069}"
        let expected = NotesMarkdownConverter.plan(markdown: clean)
        let actual = NotesMarkdownConverter.plan(markdown: pasted)
        XCTAssertEqual(actual.text, expected.text)
        XCTAssertEqual(actual.headingRanges.count, 1)
        XCTAssertEqual(actual.bulletRanges.count, 1)
        XCTAssertEqual(actual.boldRanges.first?.start, expected.boldRanges.first?.start)
        XCTAssertEqual(actual.boldRanges.first?.end, expected.boldRanges.first?.end)
        XCTAssertEqual(NotesMarkdownConverter.plan(markdown: actual.text).text, actual.text)
    }

    func testGoogleDocsLeavesEnglishPunctuationUnchanged() {
        let plan = NotesMarkdownConverter.plan(markdown: "- **Molarity:** moles/L (1/3); atoms, ions [2]")
        XCTAssertEqual(plan.text, "Molarity: moles/L (1/3); atoms, ions [2]")
        XCTAssertEqual(plan.boldRanges.first?.start, 1)
        XCTAssertEqual(plan.boldRanges.first?.end, 10)
    }

    func testGoogleDocsBoldInsideHebrewDoesNotSplitThePhrase() {
        let plan = NotesMarkdownConverter.plan(markdown: "- **אין** טומנין on שבת")
        XCTAssertEqual(plan.text, "\u{2067}אין טומנין\u{2069} on \u{2067}שבת\u{2069}")
        let bold = plan.boldRanges[0]
        XCTAssertEqual(
            (plan.text as NSString).substring(with: NSRange(location: bold.start - 1, length: bold.end - bold.start)),
            "אין"
        )
    }

    func testBuiltAppContainsCompleteNotesSkillForBothLanguageBranches() throws {
        let appURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Lectern.app")
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        let skillURL = try XCTUnwrap(LecternAgentSkill.notes.bundledURL(bundle: bundle))
        XCTAssertTrue(skillURL.path.hasPrefix(appURL.path + "/"), "Must load the shipped resource, not source-tree fallback")
        let instructions = try String(contentsOf: skillURL, encoding: .utf8)
        XCTAssertEqual(LecternAgentSkill.notes.instructions(bundle: bundle), instructions)
        XCTAssertEqual(instructions, LecternAgentSkill.notes.instructions())
        // Codex and OpenCode receive this contract inline through Prompts.notes.
        for language in [LectureLanguage.english, .hebrewEnglish] {
            let prompt = Prompts.notes(cleanedTranscript: "Lecture fixture", language: language, skillInstructions: instructions)
            XCTAssertTrue(prompt.contains("<notes-contract>\n" + instructions + "\n</notes-contract>"))
            XCTAssertTrue(prompt.contains("<lecture-source>\nLecture fixture\n</lecture-source>"))
            XCTAssertTrue(prompt.contains(language == .english ? "Language branch: English lecture" : "Language branch: English-Hebrew shiur"))
        }
    }

    func testGoogleDocsRepeatedSyncDoesNotGiveHeadingsAndBodyInheritedBullets() {
        let plan = NotesMarkdownConverter.plan(markdown: """
        # שבת

        Plain introduction 🧪

        - Parent
            - Child

        ## Next topic

        Plain explanation

        1. Final step
        """)
        var replay = DocsListReplay()
        for sync in 1...3 {
            replay.apply(plan.requests(tabId: "notes-tab", existingBodyEndIndex: replay.bodyEndIndex))
            XCTAssertEqual(
                replay.bullets,
                [false, false, true, true, false, false, true],
                "Sync \(sync) must leave headings and ordinary paragraphs outside lists"
            )
        }
    }

    func testGoogleDocsSyncClearsInheritedIndentationBeforeApplyingLists() throws {
        let plan = NotesMarkdownConverter.plan(markdown: "# שבת\n- 🧪 Parent\n    - Child")
        for existingEnd in [2, 150] {
            let requests = plan.requests(tabId: "notes-tab", existingBodyEndIndex: existingEnd)
            let insert = try XCTUnwrap(requests.firstIndex { $0["insertText"] != nil })
            let clear = try XCTUnwrap(requests.firstIndex { $0["deleteParagraphBullets"] != nil })
            let reset = try XCTUnwrap(requests.firstIndex {
                ($0["updateParagraphStyle"] as? [String: Any])?["fields"] as? String == "indentStart,indentEnd,indentFirstLine"
            })
            let firstList = try XCTUnwrap(requests.firstIndex { $0["createParagraphBullets"] != nil })
            XCTAssertLessThan(insert, clear)
            XCTAssertLessThan(clear, reset)
            XCTAssertLessThan(reset, firstList)
            for (index, key) in [(clear, "deleteParagraphBullets"), (reset, "updateParagraphStyle")] {
                let request = try XCTUnwrap(requests[index][key] as? [String: Any])
                let range = try XCTUnwrap(request["range"] as? [String: Any])
                XCTAssertEqual(range["tabId"] as? String, "notes-tab")
                XCTAssertEqual(range["startIndex"] as? Int, 1)
                XCTAssertEqual(range["endIndex"] as? Int, plan.text.utf16.count + 1)
            }
            let update = try XCTUnwrap(requests[reset]["updateParagraphStyle"] as? [String: Any])
            let style = try XCTUnwrap(update["paragraphStyle"] as? [String: Any])
            for field in ["indentStart", "indentEnd", "indentFirstLine"] {
                let dimension = try XCTUnwrap(style[field] as? [String: Any])
                XCTAssertEqual(dimension["magnitude"] as? Int, 0)
                XCTAssertEqual(dimension["unit"] as? String, "PT")
            }
        }
    }

    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2067}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
    }

    private static func depths(of markdown: String) -> [Int] {
        var scanner = NotesListScanner()
        return markdown.components(separatedBy: "\n").compactMap { scanner.scan($0)?.depth }
    }
}

/// A bounded replay of Docs list inheritance, not a substitute for a live Docs
/// test. The final newline survives replacement and can retain its list state;
/// insertText copies that state into every new paragraph. List creation removes
/// leading depth tabs, so later requests must use the shifted UTF-16 indices.
private struct DocsListReplay {
    var lines = [""]
    var bullets = [false]

    var bodyEndIndex: Int { lines.joined(separator: "\n").utf16.count + 2 }

    mutating func apply(_ requests: [[String: Any]]) {
        for request in requests {
            if request["deleteContentRange"] != nil {
                bullets = [bullets.last ?? false]
                lines = [""]
            } else if let insert = request["insertText"] as? [String: Any],
                      let text = insert["text"] as? String {
                let inherited = bullets[0]
                lines = text.components(separatedBy: "\n")
                bullets = Array(repeating: inherited, count: lines.count)
            } else {
                let creating = request["createParagraphBullets"] != nil
                guard let update = (request["createParagraphBullets"] ?? request["deleteParagraphBullets"]) as? [String: Any],
                      let range = update["range"] as? [String: Any],
                      let start = range["startIndex"] as? Int,
                      let end = range["endIndex"] as? Int else { continue }
                var offset = 1
                var selected: [Int] = []
                for (index, line) in lines.enumerated() {
                    let next = offset + line.utf16.count + 1
                    if offset < end && next > start { selected.append(index) }
                    offset = next
                }
                for index in selected {
                    bullets[index] = creating
                    if creating { lines[index] = String(lines[index].drop(while: { $0 == "\t" })) }
                }
            }
        }
    }
}
