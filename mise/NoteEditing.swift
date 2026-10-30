import SwiftUI

/// #54 note editor logic. A paragraph is the text between "\n"s; headings are a fixed font on the
/// paragraph, bold/italic/code are `inlinePresentationIntent`, lists are glyph prefixes.
enum NoteEditing {
    typealias Index = AttributedString.Index
    /// Typed Markdown prefix → editor prefix. Order matters: "- [ ] " becomes "• [ ] " then "☐ ".
    static let shortcuts: [(String, String)] = [
        ("> ", NoteMarkdown.quote), ("- ", NoteMarkdown.bullet), ("* ", NoteMarkdown.bullet),
        ("• [ ] ", NoteMarkdown.openTask), ("• [x] ", NoteMarkdown.doneTask), ("• [X] ", NoteMarkdown.doneTask),
        ("[ ] ", NoteMarkdown.openTask), ("[] ", NoteMarkdown.openTask), ("[x] ", NoteMarkdown.doneTask), ("[X] ", NoteMarkdown.doneTask),
    ]

    /// Flips one intent bit on the selected runs (removed only if every run has it), or in the typing attributes.
    static func toggle(_ intent: InlinePresentationIntent, in text: inout AttributedString, selection: inout AttributedTextSelection) {
        switch selection.indices(in: text) {
        case .insertionPoint(let i):
            var attrs = selection.typingAttributes(in: text)
            attrs.inlinePresentationIntent = flipped(attrs.inlinePresentationIntent, intent, on: attrs.inlinePresentationIntent?.contains(intent) != true)
            selection = AttributedTextSelection(insertionPoint: i, typingAttributes: attrs)
        case .ranges(let ranges):
            let on = !text[ranges].runs.allSatisfy { $0.inlinePresentationIntent?.contains(intent) == true }
            text.transformAttributes(in: &selection) { $0.inlinePresentationIntent = flipped($0.inlinePresentationIntent, intent, on: on) }
        }
    }

    private static func flipped(_ bits: InlinePresentationIntent?, _ intent: InlinePresentationIntent, on: Bool) -> InlinePresentationIntent? {
        var bits = bits ?? []
        if on { bits.insert(intent) } else { bits.remove(intent) }
        return bits.isEmpty ? nil : bits
    }

    /// Heading `level` on the paragraph(s) at the selection, or body text if they already are that level.
    static func toggleHeading(_ level: Int, in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let starts = paragraphStarts(text, selection)
        let start = starts.first!, end = paragraphEnd(text, starts.last!)
        let current = start < end ? text[start..<end].runs.first?.font : selection.typingAttributes(in: text).font
        let font: Font? = NoteMarkdown.headingLevel(current) == level ? nil : NoteMarkdown.headingFont(level)
        text.transform(updating: &selection) { $0[start..<end].font = font }
        setTyping(in: text, selection: &selection) { $0.font = font }
    }

    static func toggleBullet(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        relead(&text, &selection) { _, l, first in l.quotes + (first.glyph != NoteMarkdown.bullet ? NoteMarkdown.bullet : l.glyph == NoteMarkdown.bullet ? "" : l.glyph) }
    }

    static func toggleCheckbox(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        relead(&text, &selection) { _, l, first in l.quotes + (first.glyph == NoteMarkdown.openTask ? NoteMarkdown.doneTask : NoteMarkdown.openTask) }
    }

    /// "N. " on/off; numbering continues a numbered previous paragraph with the same quotes/indent.
    static func toggleNumbered(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let start = paragraphStarts(text, selection)[0]
        var base = 1
        if start > text.startIndex {
            let prev = lead(text, at: paragraphStart(text, text.characters.index(before: start)))
            if prev.quotes == lead(text, at: start).quotes, let n = number(prev.glyph) { base = n + 1 }
        }
        relead(&text, &selection) { k, l, first in
            l.quotes + (number(first.glyph) == nil ? "\(base + k). " : number(l.glyph) == nil ? l.glyph : "")
        }
    }

    /// Adds a quote level after the indent, or removes one.
    static func toggleQuote(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        relead(&text, &selection) { _, l, first in
            let indent = String(l.quotes.prefix { $0 == " " || $0 == "\t" }), quotes = l.quotes.dropFirst(indent.count)
            return indent + (first.quotes.contains(NoteMarkdown.quote) ? String(quotes.dropFirst(NoteMarkdown.quote.count)) : NoteMarkdown.quote + quotes) + l.glyph
        }
    }

    /// Saves `text` as the note's body unless its Markdown equals `baseline` (the canonical form of what was loaded).
    static func commit(_ text: AttributedString, to note: Note, baseline: inout String, now: Date = .now) {
        let md = NoteMarkdown.markdown(text)
        guard md != baseline else { return }
        baseline = md
        note.body = md
        note.modified = now
    }

    /// Turns typed Markdown line prefixes ("# ", "- ", "> ", "[ ] "...) into the editor representation, and a typed
    /// ``` or a line inside a fence into a code line, in the paragraphs the edit from `old` touched. Idempotent.
    static func applyShortcuts(old: AttributedString, text: inout AttributedString, selection: inout AttributedTextSelection) {
        guard !old.characters.elementsEqual(text.characters) else { return }  // attribute-only change
        let common = zip(old.characters, text.characters).prefix { $0 == $1 }.count
        let tail = min(zip(old.characters.reversed(), text.characters.reversed()).prefix { $0 == $1 }.count,
                       min(old.characters.count, text.characters.count) - common)
        // Characters after the last touched paragraph; edits never reach them, so this stays valid.
        let after = text.characters.distance(from: paragraphEnd(text, text.characters.index(text.endIndex, offsetBy: -tail)), to: text.endIndex)
        var offset = text.characters.distance(from: text.startIndex, to: paragraphStart(text, text.characters.index(text.startIndex, offsetBy: common)))
        // Only a marker the edit touched converts: typing after a literal "# x" leaves it literal.
        func edited(_ lower: Index, _ count: Int) -> Bool {
            let a = text.characters.distance(from: text.startIndex, to: lower)
            return a < text.characters.count - tail && a + count > common
        }
        while true {  // offset = character offset of the paragraph start; indices go stale after each edit
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            let body = text.characters[start...].drop { $0 == " " || $0 == "\t" }.startIndex
            if isCode(text, body) {
                // Code line: no shortcuts.
            } else if inFence(text, before: start) || (text.characters[body...].starts(with: "```") && edited(body, 3)) {
                let end = paragraphEnd(text, start)
                text.transform(updating: &selection) { $0[start..<end].inlinePresentationIntent = .code }
                setTyping(in: text, selection: &selection, onlyIfIn: offset) { $0.inlinePresentationIntent = flipped($0.inlinePresentationIntent, .code, on: true) }
            } else {
                let at = text.characters.index(start, offsetBy: lead(text, at: start).quotes.count)
                if let (from, to) = shortcuts.first(where: { text.characters[at...].starts(with: $0.0) }), edited(at, from.count) {
                    replace(from, with: to, at: at, in: &text, selection: &selection)
                    continue
                }
                if let level = (1...3).first(where: { text.characters[start...].starts(with: String(repeating: "#", count: $0) + " ") }),
                   edited(start, level + 1) {
                    replace(String(repeating: "#", count: level) + " ", with: "", at: start, in: &text, selection: &selection)
                    let start = text.characters.index(text.startIndex, offsetBy: offset), end = paragraphEnd(text, start)
                    text.transform(updating: &selection) { $0[start..<end].font = NoteMarkdown.headingFont(level) }
                    setTyping(in: text, selection: &selection, onlyIfIn: offset) { $0.font = NoteMarkdown.headingFont(level) }
                    continue
                }
            }
            let end = paragraphEnd(text, start)
            if text.characters.distance(from: end, to: text.endIndex) <= after { return }
            offset = text.characters.distance(from: text.startIndex, to: end) + 1
        }
    }

    /// Call from onChange(of: text). After a single typed "\n": continue the previous paragraph's quotes and list
    /// item ("N. " counts up, tasks restart open), or, if that paragraph was only its lead, drop the lead and the new
    /// "\n" (ends the list, cursor stays on that line). After a heading, the new line types as body text; after a
    /// code line, as code unless that line closed a fence.
    static func continueList(old: AttributedString, text: inout AttributedString, selection: inout AttributedTextSelection) {
        guard case .insertionPoint(let cursor) = selection.indices(in: text), cursor > text.startIndex else { return }
        let newline = text.characters.index(before: cursor)
        guard text.characters[newline] == "\n",
              String(text.characters[..<newline]) + String(text.characters[cursor...]) == String(old.characters) else { return }
        let start = paragraphStart(text, newline)
        let (quotes, glyph) = lead(text, at: start)
        // Return in the middle of a heading keeps the heading on both halves.
        let afterHeading = start < newline && NoteMarkdown.headingLevel(text[start..<newline].runs.first?.font) != nil && paragraphEnd(text, cursor) == cursor
        if start < newline, text[start..<newline].runs.allSatisfy({ $0.inlinePresentationIntent?.contains(.code) == true }) {
            let closes = inFence(text, before: start) && NoteMarkdown.closesFence(String(text.characters[start..<newline])[...])
            setTyping(in: text, selection: &selection) { $0.inlinePresentationIntent = flipped($0.inlinePresentationIntent, .code, on: !closes) }
        } else if quotes.contains(NoteMarkdown.quote) || !glyph.isEmpty {
            if text.characters.distance(from: start, to: newline) == quotes.count + glyph.count, paragraphEnd(text, cursor) == cursor {
                text.transform(updating: &selection) { $0.removeSubrange(start..<cursor) }
            } else {
                let next = glyph == NoteMarkdown.doneTask ? NoteMarkdown.openTask : number(glyph).map { "\($0 + 1). " } ?? glyph
                // Mid-heading split: the new lead takes the tail's heading font.
                var attrs = AttributeContainer()
                if cursor < paragraphEnd(text, cursor) { attrs.font = text[cursor...].runs.first?.font }
                text.transform(updating: &selection) { $0.insert(AttributedString(quotes + next, attributes: attrs), at: cursor) }
            }
        }
        if afterHeading { setTyping(in: text, selection: &selection) { $0.font = nil } }
    }

    // MARK: helpers

    static func paragraphStart(_ text: AttributedString, _ i: Index) -> Index {
        text.characters[..<i].lastIndex(of: "\n").map { text.characters.index(after: $0) } ?? text.startIndex
    }

    static func paragraphEnd(_ text: AttributedString, _ i: Index) -> Index {
        text.characters[i...].firstIndex(of: "\n") ?? text.endIndex
    }

    /// Starts of the paragraphs the selection touches. A triple-click selection ends after the "\n"; it doesn't
    /// spill into the next paragraph.
    private static func paragraphStarts(_ text: AttributedString, _ selection: AttributedTextSelection) -> [Index] {
        var (lower, upper) = bounds(text, selection)
        if lower < upper, text.characters[text.characters.index(before: upper)] == "\n" { upper = text.characters.index(before: upper) }
        var starts = [paragraphStart(text, lower)]
        while let newline = text.characters[starts.last!..<upper].firstIndex(of: "\n") { starts.append(text.characters.index(after: newline)) }
        return starts
    }

    /// Replaces the lead of every paragraph the selection touches with `change(k, lead, firstLead)`; the first
    /// paragraph decides on/off. Works last to first so earlier offsets stay valid.
    private static func relead(_ text: inout AttributedString, _ selection: inout AttributedTextSelection,
                               _ change: (Int, (quotes: String, glyph: String), (quotes: String, glyph: String)) -> String) {
        let offsets = paragraphStarts(text, selection).map { text.characters.distance(from: text.startIndex, to: $0) }
        let first = lead(text, at: text.characters.index(text.startIndex, offsetBy: offsets[0]))
        for (k, offset) in offsets.enumerated().reversed() {
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            let l = lead(text, at: start), new = change(k, l, first)
            if new != l.quotes + l.glyph { replace(l.quotes + l.glyph, with: new, at: start, in: &text, selection: &selection) }
        }
    }

    private static func number(_ glyph: String) -> Int? { Int(glyph.dropLast(2)) }

    /// A paragraph's lead: indent plus quote glyphs (`quotes`), then a list glyph or "N. " (`glyph`, else "").
    static func lead(_ text: AttributedString, at start: Index) -> (quotes: String, glyph: String) {
        var rest = text.characters[start..<paragraphEnd(text, start)]
        var quotes = String(rest.prefix { $0 == " " || $0 == "\t" })
        rest = rest.dropFirst(quotes.count)
        while rest.starts(with: NoteMarkdown.quote) {
            quotes += NoteMarkdown.quote
            rest = rest.dropFirst(NoteMarkdown.quote.count)
        }
        if let glyph = NoteMarkdown.prefix(text, at: rest.startIndex) { return (quotes, glyph) }
        let digits = rest.prefix { ("0"..."9").contains($0) }  // CommonMark: 1–9 digits, so `n + 1` can't overflow
        return (quotes, (1...9).contains(digits.count) && rest.dropFirst(digits.count).starts(with: ". ") ? String(digits) + ". " : "")
    }

    /// Whether the paragraph at `start` sits inside a code fence, by the serializer's rules.
    // ponytail: rescans from the document start per paragraph, O(lines²) for a big paste; carry the state if that lags.
    static func inFence(_ text: AttributedString, before start: Index) -> Bool {
        var fence = false
        for p in text.characters[..<start].split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let body = p.drop { $0 == " " || $0 == "\t" }
            let line = String(body)[...]
            if fence || (NoteMarkdown.opensFence(line) && isCode(text, body.startIndex)) { fence = !fence || !NoteMarkdown.closesFence(line) }
        }
        return fence
    }

    private static func isCode(_ text: AttributedString, _ i: Index) -> Bool {
        text[i...].runs.first?.inlinePresentationIntent?.contains(.code) == true
    }

    private static func bounds(_ text: AttributedString, _ selection: AttributedTextSelection) -> (lower: Index, upper: Index) {
        switch selection.indices(in: text) {
        case .insertionPoint(let i): (i, i)
        case .ranges(let r): (r.ranges.first?.lowerBound ?? text.startIndex, r.ranges.last?.upperBound ?? text.startIndex)
        }
    }

    /// Replaces `old` (already known to sit at `start`) with `new`, keeping the selection valid.
    private static func replace(_ old: String, with new: String, at start: Index, in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let end = text.characters.index(start, offsetBy: old.count)
        // Inherit the paragraph's heading font (not its inline intents) unless the paragraph is empty.
        var attrs = AttributeContainer()
        if start < text.endIndex, text.characters[start] != "\n" { attrs.font = text[start...].runs.first!.font }
        text.transform(updating: &selection) { $0.replaceSubrange(start..<end, with: AttributedString(new, attributes: attrs)) }
    }

    /// Changes the typing attributes when the cursor is an insertion point (optionally only in the paragraph at `offset`).
    private static func setTyping(in text: AttributedString, selection: inout AttributedTextSelection, onlyIfIn offset: Int? = nil,
                                  _ change: (inout AttributeContainer) -> Void) {
        guard case .insertionPoint(let i) = selection.indices(in: text) else { return }
        if let offset, text.characters.distance(from: text.startIndex, to: paragraphStart(text, i)) != offset { return }
        var attrs = selection.typingAttributes(in: text)
        change(&attrs)
        selection = AttributedTextSelection(insertionPoint: i, typingAttributes: attrs)
    }
}
