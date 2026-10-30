import Testing
import SwiftUI
@testable import mise

@MainActor
struct NoteEditingTests {
    private func atEnd(_ t: AttributedString) -> AttributedTextSelection {
        AttributedTextSelection(insertionPoint: t.endIndex, typingAttributes: AttributeContainer())
    }

    /// Character offset of the insertion point, nil for a range selection.
    private func cursor(_ s: AttributedTextSelection, in t: AttributedString) -> Int? {
        guard case .insertionPoint(let i) = s.indices(in: t) else { return nil }
        return t.characters.distance(from: t.startIndex, to: i)
    }

    /// `s` with every character carrying `intent`.
    private func styled(_ s: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var t = AttributedString(s)
        t.inlinePresentationIntent = intent
        return t
    }

    /// Types `typed` at the end of `old` and runs the shortcuts on it.
    private func shortcuts(_ old: AttributedString, typing typed: AttributedString) -> (AttributedString, AttributedTextSelection) {
        var t = old + typed
        var sel = atEnd(t)
        NoteEditing.applyShortcuts(old: old, text: &t, selection: &sel)
        return (t, sel)
    }

    /// Types Return at the end of `old` and runs continueList on it.
    private func typeReturn(_ old: AttributedString, typing: AttributeContainer = AttributeContainer()) -> (AttributedString, AttributedTextSelection) {
        var t = old + AttributedString("\n")
        var sel = AttributedTextSelection(insertionPoint: t.endIndex, typingAttributes: typing)
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        return (t, sel)
    }

    @Test func shortcutsConvertPrefixes() throws {
        var t = AttributedString("# Title\n- item\n- [ ] task\n[x] done")
        var sel = AttributedTextSelection()
        NoteEditing.applyShortcuts(old: AttributedString(), text: &t, selection: &sel)
        #expect(String(t.characters) == "Title\n• item\n☐ task\n☑ done")
        let (font, range) = try #require(t.runs[\.font].first)
        #expect(font == NoteMarkdown.headingFont(1))
        #expect(String(t.characters[range]) == "Title")
    }

    @Test func typedShortcutKeepsCursor() {
        var t = AttributedString("- ")
        var sel = atEnd(t)
        NoteEditing.applyShortcuts(old: AttributedString(), text: &t, selection: &sel)
        #expect(String(t.characters) == "• ")
        #expect(cursor(sel, in: t) == 2)
    }

    @Test func toggleBoldOnRange() throws {
        var t = AttributedString("hello world")
        var sel = AttributedTextSelection(range: try #require(t.range(of: "world")))
        NoteEditing.toggle(.stronglyEmphasized, in: &t, selection: &sel)
        #expect(t[try #require(t.range(of: "world"))].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(t[try #require(t.range(of: "hello "))].runs.allSatisfy { $0.inlinePresentationIntent == nil })
        NoteEditing.toggle(.stronglyEmphasized, in: &t, selection: &sel)
        #expect(t.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test func continueListAddsAndEndsBullet() {
        var old = AttributedString("• a")
        var t = AttributedString("• a\n")
        var sel = atEnd(t)
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• a\n• ")
        #expect(cursor(sel, in: t) == 6)

        // Return on an empty bullet drops the prefix and the new newline.
        old = t
        t.append(AttributedString("\n"))
        sel = atEnd(t)
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• a\n")
        #expect(cursor(sel, in: t) == 4)
    }

    @Test func continueListSplitsNonEmptyItem() {
        let old = AttributedString("• a")
        var t = AttributedString("• \na")
        var sel = AttributedTextSelection(insertionPoint: t.characters.index(t.startIndex, offsetBy: 3), typingAttributes: AttributeContainer())
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• \n• a")
    }

    @Test func headingIgnoresTrailingNewlineOfSelection() throws {
        var t = AttributedString("one\ntwo")
        var sel = AttributedTextSelection(range: try #require(t.range(of: "one\n")))
        NoteEditing.toggleHeading(1, in: &t, selection: &sel)
        #expect(t[try #require(t.range(of: "one"))].runs.allSatisfy { $0.font == NoteMarkdown.headingFont(1) })
        #expect(t[try #require(t.range(of: "two"))].runs.allSatisfy { $0.font == nil })
    }

    @Test func prefixInHeadingKeepsHeadingFont() {
        var t = AttributedString("# - x")
        var sel = AttributedTextSelection()
        NoteEditing.applyShortcuts(old: AttributedString(), text: &t, selection: &sel)
        #expect(String(t.characters) == "• x")
        #expect(NoteMarkdown.markdown(t) == "# - x")
    }

    @Test func markdownRoundTrip() {
        let s = "# Title\nSome **bold** and *it* text\n- item\n- [ ] task\n- [x] done"
        #expect(NoteMarkdown.markdown(NoteMarkdown.attributed(s)) == s)
    }

    @Test func onlyEditedParagraph() {
        let (t, sel) = shortcuts(AttributedString("- x\n-"), typing: AttributedString(" "))
        #expect(String(t.characters) == "- x\n• ")
        #expect(cursor(sel, in: t) == 6)
    }

    @Test func skipsCodeLines() {
        let (t, _) = shortcuts(styled("```\n-", .code), typing: styled(" ", .code))
        #expect(String(t.characters) == "```\n- ")
    }

    @Test func backticksBecomeCode() {
        let (t, sel) = shortcuts(AttributedString("``"), typing: AttributedString("`"))
        #expect(t.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(sel.typingAttributes(in: t).inlinePresentationIntent?.contains(.code) == true)
        #expect(NoteMarkdown.markdown(t) == "```")
    }

    @Test func quoteShortcuts() {
        #expect(String(shortcuts(AttributedString(), typing: AttributedString("> ")).0.characters) == "▍ ")
        #expect(String(shortcuts(AttributedString("▍ -"), typing: AttributedString(" ")).0.characters) == "▍ • ")
        #expect(String(shortcuts(AttributedString("▍ >"), typing: AttributedString(" ")).0.characters) == "▍ ▍ ")
        #expect(NoteMarkdown.markdown(AttributedString("▍ • x")) == "> - x")
    }

    @Test func boldParagraphBulletNotBold() throws {
        var t = styled("- x", .stronglyEmphasized)
        var sel = AttributedTextSelection()
        NoteEditing.applyShortcuts(old: AttributedString(), text: &t, selection: &sel)
        #expect(String(t.characters) == "• x")
        #expect(t[try #require(t.range(of: "• "))].runs.allSatisfy { $0.inlinePresentationIntent == nil })
        #expect(t[try #require(t.range(of: "x"))].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func headingReturnResetsTypingFont() {
        var title = AttributedString("Title")
        title.font = NoteMarkdown.headingFont(1)
        let (t, sel) = typeReturn(title, typing: AttributeContainer().font(NoteMarkdown.headingFont(1)))
        #expect(String(t.characters) == "Title\n")
        #expect(sel.typingAttributes(in: t).font == nil)
    }

    @Test func pasteDoesNotContinue() {
        let old = AttributedString("• x")
        var t = AttributedString("• x\na\nb")
        var sel = atEnd(t)
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "• x\na\nb")
    }

    @Test func numberedContinues() {
        let (t, sel) = typeReturn(AttributedString("1. a"))
        #expect(String(t.characters) == "1. a\n2. ")
        #expect(cursor(sel, in: t) == 8)
        let (ended, endSel) = typeReturn(t)
        #expect(String(ended.characters) == "1. a\n")
        #expect(cursor(endSel, in: ended) == 5)
    }

    @Test func quotedBulletContinues() {
        #expect(String(typeReturn(AttributedString("▍ • a")).0.characters) == "▍ • a\n▍ • ")
        #expect(String(typeReturn(AttributedString("  ☑ a")).0.characters) == "  ☑ a\n  ☐ ")
        #expect(String(typeReturn(AttributedString("▍ ▍ ")).0.characters) == "")
    }

    @Test func codeReturn() {
        let (inside, insideSel) = typeReturn(styled("```\nx", .code))
        #expect(String(inside.characters) == "```\nx\n")
        #expect(insideSel.typingAttributes(in: inside).inlinePresentationIntent?.contains(.code) == true)
        let (closed, closedSel) = typeReturn(styled("```\nx\n```", .code), typing: AttributeContainer().inlinePresentationIntent(.code))
        #expect(String(closed.characters) == "```\nx\n```\n")
        #expect(closedSel.typingAttributes(in: closed).inlinePresentationIntent?.contains(.code) != true)
        // "```swift" inside a fence doesn't close it.
        let (info, infoSel) = typeReturn(styled("```\nx\n```swift", .code), typing: AttributeContainer().inlinePresentationIntent(.code))
        #expect(infoSel.typingAttributes(in: info).inlinePresentationIntent?.contains(.code) == true)
    }

    /// Inserts plain `typed` at character `offset` of `old` and runs applyShortcuts.
    private func insert(_ typed: String, at offset: Int, in old: AttributedString) -> AttributedString {
        var t = old
        let i = t.characters.index(t.startIndex, offsetBy: offset)
        t.insert(AttributedString(typed), at: i)
        var sel = AttributedTextSelection(insertionPoint: t.characters.index(t.startIndex, offsetBy: offset + typed.count), typingAttributes: AttributeContainer())
        NoteEditing.applyShortcuts(old: old, text: &t, selection: &sel)
        return t
    }

    @Test func noShortcutsInsideFence() {
        let loaded = NoteMarkdown.attributed("```\n\n```")
        #expect(loaded[loaded.characters.index(loaded.startIndex, offsetBy: 3)...].runs.first?.inlinePresentationIntent?.contains(.code) == true)
        #expect(NoteMarkdown.markdown(insert("- ", at: 4, in: loaded)) == "```\n- \n```")
        var pasted = AttributedString("```\n- a\n```")
        var sel = atEnd(pasted)
        NoteEditing.applyShortcuts(old: AttributedString(), text: &pasted, selection: &sel)
        #expect(NoteMarkdown.markdown(pasted) == "```\n- a\n```")
    }

    @Test func quotedHeadingReturnResetsTypingFont() {
        var title = AttributedString("▍ Title")
        title.font = NoteMarkdown.headingFont(1)
        let (t, sel) = typeReturn(title, typing: AttributeContainer().font(NoteMarkdown.headingFont(1)))
        #expect(String(t.characters) == "▍ Title\n▍ ")
        #expect(sel.typingAttributes(in: t).font == nil)
    }

    @Test func midHeadingReturnKeepsTypingFont() {
        var old = AttributedString("Title")
        old.font = NoteMarkdown.headingFont(1)
        var t = old
        t.insert(AttributedString("\n", attributes: AttributeContainer().font(NoteMarkdown.headingFont(1))), at: t.characters.index(t.startIndex, offsetBy: 2))
        var sel = AttributedTextSelection(insertionPoint: t.characters.index(t.startIndex, offsetBy: 3),
                                          typingAttributes: AttributeContainer().font(NoteMarkdown.headingFont(1)))
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        #expect(sel.typingAttributes(in: t).font == NoteMarkdown.headingFont(1))
    }

    @Test func attributeOnlyChangeIsIgnored() {
        var t = AttributedString("```")
        var sel = atEnd(t)
        NoteEditing.applyShortcuts(old: styled("```", .code), text: &t, selection: &sel)
        #expect(t.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test func editAwayFromMarkerKeepsLiteral() {
        #expect(String(insert("x", at: 5, in: AttributedString("# not")).characters) == "# notx")
        #expect(String(insert("x", at: 3, in: AttributedString("```")).characters) == "```x")
        #expect(insert("x", at: 3, in: AttributedString("```")).runs.allSatisfy { $0.inlinePresentationIntent == nil })
        #expect(String(insert("x", at: 3, in: AttributedString("- y")).characters) == "- yx")
        #expect(String(insert("b", at: 1, in: AttributedString("a\n- y")).characters) == "ab\n- y")
    }

    @Test func secondPassIsNoOp() {
        for (first, _) in [shortcuts(AttributedString("-"), typing: AttributedString(" ")), typeReturn(AttributedString("• a")),
                           shortcuts(AttributedString("``"), typing: AttributedString("`"))] {
            var t = first
            var sel = atEnd(t)
            NoteEditing.continueList(old: first, text: &t, selection: &sel)
            NoteEditing.applyShortcuts(old: first, text: &t, selection: &sel)
            #expect(t == first)
        }
    }

    typealias Edit = (inout AttributedString, inout AttributedTextSelection) -> Void

    /// Markdown of `s` after `edits`, with everything selected or (`cursor`) an insertion point at the end.
    private func apply(_ edits: [Edit], to s: String = "x", cursor: Bool = false) -> String {
        var t = AttributedString(s)
        var sel = cursor ? atEnd(t) : AttributedTextSelection(range: t.startIndex..<t.endIndex)
        for edit in edits { edit(&t, &sel) }
        return NoteMarkdown.markdown(t)
    }

    @Test func toggleRoundTrips() {
        let bold: Edit = { NoteEditing.toggle(.stronglyEmphasized, in: &$0, selection: &$1) }
        let italic: Edit = { NoteEditing.toggle(.emphasized, in: &$0, selection: &$1) }
        let strike: Edit = { NoteEditing.toggle(.strikethrough, in: &$0, selection: &$1) }
        let code: Edit = { NoteEditing.toggle(.code, in: &$0, selection: &$1) }
        let heading: Edit = { NoteEditing.toggleHeading(1, in: &$0, selection: &$1) }
        let bullet: Edit = { NoteEditing.toggleBullet(in: &$0, selection: &$1) }
        let numbered: Edit = { NoteEditing.toggleNumbered(in: &$0, selection: &$1) }
        let checkbox: Edit = { NoteEditing.toggleCheckbox(in: &$0, selection: &$1) }
        let quote: Edit = { NoteEditing.toggleQuote(in: &$0, selection: &$1) }
        for (edit, md) in [(bold, "**x**"), (italic, "*x*"), (strike, "~~x~~"), (code, "`x`")] {
            #expect(apply([edit]) == md)
            #expect(apply([edit, edit]) == "x")
        }
        for (edit, md) in [(heading, "# x"), (bullet, "- x"), (numbered, "1. x"), (quote, "> x")] {
            for cursor in [false, true] {
                #expect(apply([edit], cursor: cursor) == md)
                #expect(apply([edit, edit], cursor: cursor) == "x")
            }
        }
        for cursor in [false, true] {
            #expect(apply([checkbox], cursor: cursor) == "- [ ] x")
            #expect(apply([checkbox, checkbox], cursor: cursor) == "- [x] x")
            #expect(apply([quote, bullet], cursor: cursor) == "> - x")
        }
        #expect(apply([bullet, numbered]) == "1. x")
        #expect(apply([numbered, checkbox]) == "- [ ] x")
    }

    @Test func multiParagraph() {
        #expect(apply([{ NoteEditing.toggleNumbered(in: &$0, selection: &$1) }], to: "a\nb\nc") == "1. a\n2. b\n3. c")
        #expect(apply([{ NoteEditing.toggleBullet(in: &$0, selection: &$1) }], to: "a\nb") == "- a\n- b")
        #expect(apply([{ NoteEditing.toggleQuote(in: &$0, selection: &$1) }], to: "a\nb") == "> a\n> b")
        #expect(apply([{ NoteEditing.toggleCheckbox(in: &$0, selection: &$1) }], to: "a\nb") == "- [ ] a\n- [ ] b")
        #expect(apply([{ NoteEditing.toggleNumbered(in: &$0, selection: &$1) }], to: "1. a\nb", cursor: true) == "1. a\n2. b")
        // A selection ending right after a "\n" leaves the next paragraph alone.
        var t = AttributedString("a\nb")
        var sel = AttributedTextSelection(range: t.startIndex..<t.characters.index(t.startIndex, offsetBy: 2))
        NoteEditing.toggleBullet(in: &t, selection: &sel)
        #expect(NoteMarkdown.markdown(t) == "- a\nb")
        // Off across several paragraphs.
        #expect(apply([{ NoteEditing.toggleBullet(in: &$0, selection: &$1) }], to: "• a\nb") == "a\nb")
        #expect(apply([{ NoteEditing.toggleQuote(in: &$0, selection: &$1) }], to: "▍ a\n▍ b") == "a\nb")
        #expect(apply([{ NoteEditing.toggleNumbered(in: &$0, selection: &$1) }], to: "1. a\n2. b") == "a\nb")
        // Numbering doesn't continue into a paragraph with different quotes.
        #expect(apply([{ NoteEditing.toggleNumbered(in: &$0, selection: &$1) }], to: "▍ 1. a\nb", cursor: true) == "> 1. a\n1. b")
    }

    /// CommonMark caps list numbers at 9 digits; longer is text, and must not overflow `n + 1`.
    @Test func longNumberIsText() {
        let long = "9223372036854775807. x"
        #expect(String(typeReturn(AttributedString(long)).0.characters) == long + "\n")
        var t = AttributedString(long + "\nb")
        var sel = atEnd(t)
        NoteEditing.toggleNumbered(in: &t, selection: &sel)
        #expect(String(t.characters) == long + "\n1. b")
    }

    @Test func listGlyphKeepsHeadingFontOnly() {
        var t = styled("x", .stronglyEmphasized)
        t.font = NoteMarkdown.headingFont(2)
        var sel = atEnd(t)
        NoteEditing.toggleQuote(in: &t, selection: &sel)
        NoteEditing.toggleBullet(in: &t, selection: &sel)
        #expect(NoteMarkdown.markdown(t) == "> ## - **x**")
    }

    @Test func openingDoesNotChangeNote() {
        let note = Note(body: "* item\n__b__\n\\# lit")
        let past = Date(timeIntervalSince1970: 1_000_000)
        note.modified = past
        var baseline = NoteMarkdown.markdown(NoteMarkdown.attributed(note.body))
        var text = NoteMarkdown.attributed(note.body)
        NoteEditing.commit(text, to: note, baseline: &baseline)
        #expect(note.body == "* item\n__b__\n\\# lit")
        #expect(note.modified == past)
        text.append(AttributedString("!"))
        let now = Date(timeIntervalSince1970: 2_000_000)
        NoteEditing.commit(text, to: note, baseline: &baseline, now: now)
        #expect(note.body == NoteMarkdown.markdown(text))
        #expect(baseline == note.body)
        #expect(note.modified == now)
    }

    @Test func pastedFenceIsCode() {
        var pasted = AttributedString("```\n1. a\n```")
        var sel = atEnd(pasted)
        NoteEditing.applyShortcuts(old: AttributedString(), text: &pasted, selection: &sel)
        #expect(pasted.runs.filter { $0.inlinePresentationIntent?.contains(.code) != true }.allSatisfy { String(pasted.characters[$0.range]) == "\n" })
        let line = AttributedString(pasted[..<pasted.characters.index(pasted.startIndex, offsetBy: 8)])
        let (t, sel2) = typeReturn(line)
        #expect(String(t.characters) == "```\n1. a\n")
        #expect(sel2.typingAttributes(in: t).inlinePresentationIntent?.contains(.code) == true)
    }

    @Test func midQuotedHeadingReturnKeepsHeading() {
        var old = AttributedString("▍ Title")
        old.font = NoteMarkdown.headingFont(1)
        var t = old
        t.insert(AttributedString("\n", attributes: AttributeContainer().font(NoteMarkdown.headingFont(1))), at: t.characters.index(t.startIndex, offsetBy: 4))
        var sel = AttributedTextSelection(insertionPoint: t.characters.index(t.startIndex, offsetBy: 5),
                                          typingAttributes: AttributeContainer().font(NoteMarkdown.headingFont(1)))
        NoteEditing.continueList(old: old, text: &t, selection: &sel)
        #expect(String(t.characters) == "▍ Ti\n▍ tle")
        #expect(NoteMarkdown.markdown(t) == "> # Ti\n> # tle")
    }
}
