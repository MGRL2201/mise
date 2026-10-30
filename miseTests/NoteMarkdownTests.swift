import Testing
import SwiftUI
@testable import mise

@MainActor
struct NoteMarkdownTests {
    /// (input Markdown, expected Markdown after one round trip)
    static let fixtures: [(String, String)] = [
        ("# H1", "# H1"),
        ("## H2", "## H2"),
        ("### H3", "### H3"),
        ("#### x", "#### x"),
        ("# ", ""),
        ("- a\n* b\n+ c", "- a\n- b\n- c"),
        ("- [ ] a", "- [ ] a"),
        ("- [x] a", "- [x] a"),
        ("* [X] a", "- [x] a"),
        ("1. a\n2) b\n10. c", "1. a\n2) b\n10. c"),
        ("> q", "> q"),
        ("> > q", "> > q"),
        ("> - a", "> - a"),
        (">", ">"),
        ("> ", ">"),
        ("  - a\n\t- b\n    1. c", "  - a\n\t- b\n    1. c"),
        ("# - x", "# - x"),
        ("a\n\nb", "a\n\nb"),
        ("\na", "\na"),
        ("a\n", "a\n"),
        ("\n", "\n"),
        ("", ""),
        ("a\r\nb\r\n", "a\nb\n"),
        ("a\rb", "a\nb"),
        ("```swift\n**not bold**\n# not heading\n- not bullet\n\n```\nafter **b**",
         "```swift\n**not bold**\n# not heading\n- not bullet\n\n```\nafter **b**"),
        ("x\n```\n# open\n- y", "x\n```\n# open\n- y"),
        ("\\# x", "\\# x"),
        ("\\- x", "\\- x"),
        ("\\> x", "\\> x"),
        ("**b** *i* `c`", "**b** *i* `c`"),
        ("## **b** x", "## **b** x"),
        ("**bold**", "**bold**"),
        ("*it*", "*it*"),
        ("***both***", "***both***"),
        ("`code`", "`code`"),
        ("`a*b*c`", "`a*b*c`"),
        ("``a`b``", "``a`b``"),
        ("` `` `", "` `` `"),
        ("`  a  `", "`  a  `"),
        ("~~gone~~", "~~gone~~"),
        ("[link](https://example.com)", "[link](https://example.com)"),
        ("[**bold** link](https://example.com)", "[bold link](https://example.com)"),  // Apple drops emphasis in link text
        ("**a [b](https://x.com) c**", "**a [b](https://x.com) c**"),
        ("**[a](https://x.com)**", "**[a](https://x.com)**"),
        ("[a](https://x.com/a\\(b\\)c)", "[a](https://x.com/a\\(b\\)c)"),
        ("<https://example.com>", "<https://example.com>"),
        ("wow\\![a](https://x.com)", "wow\\![a](https://x.com)"),
        ("![alt](https://x.com/i.png)", "![alt](https://x.com/i.png)"),
        ("a \\* b \\_ c \\` d \\[e\\] \\\\ f \\< g", "a \\* b \\_ c \\` d \\[e] \\\\ f \\< g"),
        ("[a\\]b](https://x.com)", "[a\\]b](https://x.com)"),
        ("snake_case_name", "snake_case_name"),
        ("_under_", "*under*"),
        ("x * y", "x \\* y"),
        ("<b>html</b>", "<b>html</b>"),
        ("- \\[ ] a", "- \\[ ] a"),
        ("\\``` x", "\\`\\`\\` x"),
        ("# ```", "# \\`\\`\\`"),
        ("1. **a**", "1. **a**"),
        ("- [ ] **task** with `code`", "- [ ] **task** with `code`"),
        ("> *quote*", "> *quote*"),
        ("# **H**", "# **H**"),
        ("**bold *both* bold**", "**bold *both* bold**"),
        ("&amp;", "\\&"),  // Apple decodes entities, so "&" is escaped
    ]

    @Test func roundTripFixtures() {
        for (input, expected) in Self.fixtures {
            let once = NoteMarkdown.markdown(NoteMarkdown.attributed(input))
            #expect(once == expected, "input: \(input.debugDescription)")
            #expect(NoteMarkdown.markdown(NoteMarkdown.attributed(once)) == once, "second pass of \(input.debugDescription)")
        }
    }

    @Test func blockRepresentation() throws {
        #expect(String(NoteMarkdown.attributed("- a").characters) == "• a")
        #expect(String(NoteMarkdown.attributed("- [ ] a").characters) == "☐ a")
        #expect(String(NoteMarkdown.attributed("> q").characters) == "▍ q")
        #expect(String(NoteMarkdown.attributed("1. a").characters) == "1. a")
        #expect(try #require(NoteMarkdown.attributed("## t").runs.first).font == NoteMarkdown.headingFont(2))
    }

    @Test func fenceLinesAreCode() {
        let t = NoteMarkdown.attributed("```swift\n# x\n```")
        #expect(String(t.characters) == "```swift\n# x\n```")
        for line in t.characters.split(separator: "\n") {
            #expect(t[line.startIndex..<line.endIndex].runs.allSatisfy { $0.inlinePresentationIntent == .code })
        }
    }

    /// Writes `text`, checks the Markdown, and checks it reloads to the same Markdown.
    private func expectWrites(_ text: AttributedString, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let md = NoteMarkdown.markdown(text)
        #expect(md == expected, sourceLocation: sourceLocation)
        #expect(NoteMarkdown.markdown(NoteMarkdown.attributed(md)) == md, "reload of \(md.debugDescription)", sourceLocation: sourceLocation)
    }

    private func run(_ s: String, _ bits: InlinePresentationIntent) -> AttributedString {
        var a = AttributedString(s)
        a.inlinePresentationIntent = bits
        return a
    }

    @Test func emphasisEdgeWhitespaceMovesOutside() {
        expectWrites(run("bold ", .stronglyEmphasized) + AttributedString("x"), "**bold** x")
        expectWrites(AttributedString("a") + run(" lead", .stronglyEmphasized), "a **lead**")
        expectWrites(run("a", .stronglyEmphasized) + run(" ", [.stronglyEmphasized, .emphasized]) + run("b", .stronglyEmphasized), "**a b**")
    }

    @Test func unsupportedAttributesAreDropped() {
        var a = AttributedString("colour ")
        a.swiftUI.foregroundColor = .red
        a.swiftUI.backgroundColor = .yellow
        a.swiftUI.underlineStyle = .single
        var big = AttributedString("big ")
        big.font = .largeTitle
        var bold = AttributedString("bold")
        bold.font = .body.bold()
        expectWrites(a + big + bold, "colour big bold")
    }

    @Test func headingFontKeptColourDropped() {
        var h = AttributedString("H")
        h.font = NoteMarkdown.headingFont(1)
        h.swiftUI.foregroundColor = .red
        expectWrites(h, "# H")
    }

    @Test func carriageReturnsSplitParagraphs() {
        expectWrites(AttributedString("• a\r\nb\rc"), "- a\nb\nc")
    }

    @Test func linkRepresentation() throws {
        let a = NoteMarkdown.attributed("[a](https://example.com)")
        let r = try #require(a.runs.first)
        #expect(String(a.characters[r.range]) == "a")
        #expect(r.link == URL(string: "https://example.com"))
    }

    /// The writer's line-start escaping relies on Apple's inline parser dropping these backslashes.
    @Test func inlineParserUnescapesBlockMarkers() throws {
        for c in ["#", "-", ">", "*", "+", "`"] {
            let a = try AttributedString(markdown: "\\" + c + " x", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            #expect(String(a.characters) == c + " x")
        }
    }
}
