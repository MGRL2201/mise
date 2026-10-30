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
        var (lower, upper) = bounds(text, selection)
        // A triple-click selection ends after the "\n"; don't spill into the next paragraph.
        if lower < upper, text.characters[text.characters.index(before: upper)] == "\n" { upper = text.characters.index(before: upper) }
        let start = paragraphStart(text, lower), end = paragraphEnd(text, upper)
        let current = start < end ? text[start..<end].runs.first?.font : selection.typingAttributes(in: text).font
        let font: Font? = NoteMarkdown.headingLevel(current) == level ? nil : NoteMarkdown.headingFont(level)
        text.transform(updating: &selection) { $0[start..<end].font = font }
        setTyping(in: text, selection: &selection) { $0.font = font }
    }

    static func toggleBullet(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let start = paragraphStart(text, bounds(text, selection).lower)
        let old = NoteMarkdown.prefix(text, at: start)
        replace(old ?? "", with: old == NoteMarkdown.bullet ? "" : NoteMarkdown.bullet, at: start, in: &text, selection: &selection)
    }

    static func toggleCheckbox(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let start = paragraphStart(text, bounds(text, selection).lower)
        let old = NoteMarkdown.prefix(text, at: start)
        replace(old ?? "", with: old == NoteMarkdown.openTask ? NoteMarkdown.doneTask : NoteMarkdown.openTask, at: start, in: &text, selection: &selection)
    }

    /// Turns typed Markdown line prefixes ("# ", "- ", "> ", "[ ] "...) into the editor representation, and a typed
    /// ``` into a code line, in the paragraphs the edit from `old` touched. Idempotent.
    static func applyShortcuts(old: AttributedString, text: inout AttributedString, selection: inout AttributedTextSelection) {
        let common = zip(old.characters, text.characters).prefix { $0 == $1 }.count
        let tail = min(zip(old.characters.reversed(), text.characters.reversed()).prefix { $0 == $1 }.count,
                       min(old.characters.count, text.characters.count) - common)
        // Characters after the last touched paragraph; edits never reach them, so this stays valid.
        let after = text.characters.distance(from: paragraphEnd(text, text.characters.index(text.endIndex, offsetBy: -tail)), to: text.endIndex)
        var offset = text.characters.distance(from: text.startIndex, to: paragraphStart(text, text.characters.index(text.startIndex, offsetBy: common)))
        while true {  // offset = character offset of the paragraph start; indices go stale after each edit
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            let body = text.characters[start...].drop { $0 == " " || $0 == "\t" }.startIndex
            if isCode(text, body) {
                // Code line: no shortcuts.
            } else if text.characters[body...].starts(with: "```") {
                let end = paragraphEnd(text, start)
                text.transform(updating: &selection) { $0[start..<end].inlinePresentationIntent = .code }
                setTyping(in: text, selection: &selection, onlyIfIn: offset) { $0.inlinePresentationIntent = flipped($0.inlinePresentationIntent, .code, on: true) }
            } else {
                let at = text.characters.index(start, offsetBy: lead(text, at: start).quotes.count)
                if let (from, to) = shortcuts.first(where: { text.characters[at...].starts(with: $0.0) }) {
                    replace(from, with: to, at: at, in: &text, selection: &selection)
                    continue
                }
                if let level = (1...3).first(where: { text.characters[start...].starts(with: String(repeating: "#", count: $0) + " ") }) {
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
        if start < newline, text[start..<newline].runs.allSatisfy({ $0.inlinePresentationIntent?.contains(.code) == true }) {
            let fences = text.characters[..<newline].split(separator: "\n", omittingEmptySubsequences: false).filter {
                let body = $0.drop { $0 == " " || $0 == "\t" }
                return body.starts(with: "```") && isCode(text, body.startIndex)
            }
            let closes = fences.last?.endIndex == newline && fences.count.isMultiple(of: 2)
            setTyping(in: text, selection: &selection) { $0.inlinePresentationIntent = flipped($0.inlinePresentationIntent, .code, on: !closes) }
        } else if quotes.contains(NoteMarkdown.quote) || !glyph.isEmpty {
            if text.characters.distance(from: start, to: newline) == quotes.count + glyph.count, paragraphEnd(text, cursor) == cursor {
                text.transform(updating: &selection) { $0.removeSubrange(start..<cursor) }
            } else {
                let next = glyph == NoteMarkdown.doneTask ? NoteMarkdown.openTask : Int(glyph.dropLast(2)).map { "\($0 + 1). " } ?? glyph
                text.transform(updating: &selection) { $0.insert(AttributedString(quotes + next), at: cursor) }
            }
        } else if start < newline, NoteMarkdown.headingLevel(text[start..<newline].runs.first?.font) != nil {
            setTyping(in: text, selection: &selection) { $0.font = nil }
        }
    }

    // MARK: helpers

    static func paragraphStart(_ text: AttributedString, _ i: Index) -> Index {
        text.characters[..<i].lastIndex(of: "\n").map { text.characters.index(after: $0) } ?? text.startIndex
    }

    static func paragraphEnd(_ text: AttributedString, _ i: Index) -> Index {
        text.characters[i...].firstIndex(of: "\n") ?? text.endIndex
    }

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
        let digits = rest.prefix { ("0"..."9").contains($0) }
        return (quotes, !digits.isEmpty && rest.dropFirst(digits.count).starts(with: ". ") ? String(digits) + ". " : "")
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
