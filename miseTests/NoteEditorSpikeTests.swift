#if DEBUG
import Testing
import SwiftUI
@testable import mise

@MainActor
struct NoteEditorSpikeTests {
    private func atEnd(_ t: AttributedString) -> AttributedTextSelection {
        AttributedTextSelection(insertionPoint: t.endIndex, typingAttributes: AttributeContainer())
    }

    /// Character offset of the insertion point, nil for a range selection.
    private func cursor(_ s: AttributedTextSelection, in t: AttributedString) -> Int? {
        guard case .insertionPoint(let i) = s.indices(in: t) else { return nil }
        return t.characters.distance(from: t.startIndex, to: i)
    }

    @Test func shortcutsConvertPrefixes() throws {
        var t = AttributedString("# Title\n- item\n- [ ] task\n[x] done")
        var sel = AttributedTextSelection()
        NoteSpike.applyShortcuts(&t, selection: &sel)
        #expect(String(t.characters) == "Title\n• item\n☐ task\n☑ done")
        let (font, range) = try #require(t.runs[\.font].first)
        #expect(font == NoteSpike.headingFont(1))
        #expect(String(t.characters[range]) == "Title")
    }

    @Test func typedShortcutKeepsCursor() {
        var t = AttributedString("- ")
        var sel = atEnd(t)
        NoteSpike.applyShortcuts(&t, selection: &sel)
        #expect(String(t.characters) == "• ")
        #expect(cursor(sel, in: t) == 2)
    }

    @Test func toggleBoldOnRange() throws {
        var t = AttributedString("hello world")
        var sel = AttributedTextSelection(range: try #require(t.range(of: "world")))
        NoteSpike.toggle(.stronglyEmphasized, in: &t, selection: &sel)
        #expect(t[try #require(t.range(of: "world"))].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(t[try #require(t.range(of: "hello "))].runs.allSatisfy { $0.inlinePresentationIntent == nil })
        NoteSpike.toggle(.stronglyEmphasized, in: &t, selection: &sel)
        #expect(t.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test func continueListAddsAndEndsBullet() {
        var old = AttributedString("• a")
        var t = AttributedString("• a\n")
        var sel = atEnd(t)
        NoteSpike.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• a\n• ")
        #expect(cursor(sel, in: t) == 6)

        // Return on an empty bullet drops the prefix and the new newline.
        old = t
        t.append(AttributedString("\n"))
        sel = atEnd(t)
        NoteSpike.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• a\n")
        #expect(cursor(sel, in: t) == 4)
    }

    @Test func continueListSplitsNonEmptyItem() {
        let old = AttributedString("• a")
        var t = AttributedString("• \na")
        var sel = AttributedTextSelection(insertionPoint: t.characters.index(t.startIndex, offsetBy: 3), typingAttributes: AttributeContainer())
        NoteSpike.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• \n• a")
    }

    @Test func headingIgnoresTrailingNewlineOfSelection() throws {
        var t = AttributedString("one\ntwo")
        var sel = AttributedTextSelection(range: try #require(t.range(of: "one\n")))
        NoteSpike.toggleHeading(1, in: &t, selection: &sel)
        #expect(t[try #require(t.range(of: "one"))].runs.allSatisfy { $0.font == NoteSpike.headingFont(1) })
        #expect(t[try #require(t.range(of: "two"))].runs.allSatisfy { $0.font == nil })
    }

    @Test func prefixInHeadingKeepsHeadingFont() {
        var t = AttributedString("# - x")
        var sel = AttributedTextSelection()
        NoteSpike.applyShortcuts(&t, selection: &sel)
        #expect(String(t.characters) == "• x")
        #expect(NoteSpike.markdown(t) == "# - x")
    }

    @Test func markdownRoundTrip() {
        let s = "# Title\nSome **bold** and *it* text\n- item\n- [ ] task\n- [x] done"
        #expect(NoteSpike.markdown(NoteSpike.attributed(markdown: s)) == s)
    }
}
#endif
