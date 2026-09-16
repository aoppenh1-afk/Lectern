import AppKit
import CoreText

/// Real notes from the September 15 report, plus the original inline-source case.
let hebrewDirectionExamples = [
    #"In סימן י׳ the רא״ש says חזרה on ערב שבת is אסור אטו שבת ("כולא חדא גזירה היא... ואי שרינן להחזיר מבעוד יום, אתו נמי להחזיר משחשכה")"#,
    "Proximity exists only when returning on שבת itself; returning on ערב שבת is purely an איסור דרבנן of אטו שבת (שמא יחזיר בשבת)",
    "**לפי תוס׳ (ורא״ש פרק ד׳):** איסור חזרה is סמוך לשבת out of fear that returning it 5 minutes before שבת will lead to returning it 5 minutes after שבת",
    "**פני יהושע (דף ל״ז. בשיטת רש״י)**",
    #"**גמ׳:** "אי אמרת בשלמא להחזיר תנן, היינו דשני בין תוכה לעל גבה; אי אמרת לשהות תנן, מאי תוכה ומאי על גבה?""#,
    #"**גמ׳:** "אי אמרת בשלמא: להחזיר תנן, היינו דשני בין תוכה לעל גבה; אלא אי אמרת: לשהות תנן, מה לי תוכה מה לי על גבה?""#,
]

@MainActor
func checkHebrewDirectionExamples() {
    var failures: [String] = []
    for (number, markdown) in hebrewDirectionExamples.enumerated() {
        let plan = NotesMarkdownConverter.inlinePlan(markdown)
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .leftToRight
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: plan.text,
            attributes: [.font: NSFont.systemFont(ofSize: 18), .paragraphStyle: paragraph]))
        // Glyph positions avoid the ambiguous caret position at an RTL/LTR boundary.
        func x(_ token: String) -> CGFloat {
            let location = (plan.text as NSString).range(of: token).location
            precondition(location != NSNotFound, token)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var indices = [CFIndex](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetStringIndices(run, CFRange(), &indices)
                CTRunGetPositions(run, CFRange(), &positions)
                if let index = indices.firstIndex(of: location) { return positions[index].x }
            }
            preconditionFailure("No glyph for \(token)")
        }
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append("Example \(number + 1): \(message)") }
        }
        switch number {
        case 0:
            expect(x("כולא") > x("ואי"), "ellipsis must not restart the Hebrew quotation")
            expect(x("(") > x("כולא") && x(")") < x("משחשכה"), "parentheses must enclose the RTL quotation")
        case 1:
            expect(x("אטו") < x("שמא"), "preserve the English sentence's phrase-then-aside order")
        case 2:
            expect(x("לפי") > x("ורא״ש"), "source parenthetical must be to the left of לפי תוס׳")
            expect(x("לפי") < x("איסור"), "bold source must stay left of its explanation")
        case 3:
            expect(x("פני") > x("דף"), "source citation must be to the left of פני יהושע")
        case 4, 5:
            expect(x("בשלמא") > x("היינו") && x("היינו") > x("לשהות"), "punctuation must not restart the Gemara quotation")
            expect(x("גמ׳") < x("לשהות"), "bold Gemara label must stay to the left of the quotation")
        default: break
        }
        // Exercise actual line wrapping, not just a wide single-line layout.
        if [0, 4, 5].contains(number) {
            for width in [340.0, 520.0] {
                let attributed = NSAttributedString(string: plan.text,
                    attributes: [.font: NSFont.systemFont(ofSize: 18), .paragraphStyle: paragraph])
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),
                    CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 900), transform: nil), nil)
                let lines = CTFrameGetLines(frame) as! [CTLine]
                func position(_ token: String) -> (line: Int, x: CGFloat) {
                    let location = (plan.text as NSString).range(of: token).location
                    for (lineNumber, line) in lines.enumerated() {
                        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                            let count = CTRunGetGlyphCount(run)
                            var indices = [CFIndex](repeating: 0, count: count)
                            var positions = [CGPoint](repeating: .zero, count: count)
                            CTRunGetStringIndices(run, CFRange(), &indices)
                            CTRunGetPositions(run, CFRange(), &positions)
                            if let index = indices.firstIndex(of: location) { return (lineNumber, positions[index].x) }
                        }
                    }
                    preconditionFailure("Missing wrapped glyph: \(token)")
                }
                let words = number == 0 ? ["כולא", "גזירה", "היא", "ואי", "מבעוד", "אתו", "משחשכה"]
                    : ["בשלמא", "להחזיר", "היינו", "לשהות"]
                for (first, second) in zip(words, words.dropFirst()) {
                    let a = position(first), b = position(second)
                    expect(a.line < b.line || (a.line == b.line && a.x > b.x),
                        "RTL reading order across wrapped lines at width \(width): \(first) → \(second)")
                }
                if number == 0 {
                    let opening = position("("), first = position("כולא")
                    let closing = position(")"), last = position("משחשכה")
                    expect(opening.line == first.line && opening.x > first.x,
                        "opening parenthesis must stay at the quote's RTL beginning")
                    expect(closing.line == last.line && closing.x < last.x,
                        "closing parenthesis must stay at the quote's RTL end")
                }
            }
        }
        let native = NotesMarkdownConverter.directionalInline(markdown)
        expect(String(native.characters) == plan.text, "native notes must use the same direction boundaries")
        let document = LectureDocumentRenderer.attributedDocument(from: "- " + markdown)
        expect(document.string.contains(plan.text), "document export must use the same direction boundaries")
    }
    if !failures.isEmpty {
        print(failures.joined(separator: "\n"))
        exit(1)
    }
    print("PASS: Hebrew quotes, source parentheses, and English-led asides retain their intended direction")
}
