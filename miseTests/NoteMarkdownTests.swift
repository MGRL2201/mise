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

    /// The writer's line-start escaping relies on Apple's inline parser dropping these backslashes.
    @Test func inlineParserUnescapesBlockMarkers() throws {
        for c in ["#", "-", ">", "*", "+", "`"] {
            let a = try AttributedString(markdown: "\\" + c + " x", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            #expect(String(a.characters) == c + " x")
        }
    }
}
