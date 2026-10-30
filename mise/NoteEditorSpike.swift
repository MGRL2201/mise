#if DEBUG
import SwiftUI

/// Spike #51 live prototype. Launch with `-miseSpike notes` (sample note) or `-miseSpike probe` (rendering probe).
/// `-miseSpikeType YES` scripts typing + formatting; `-miseSpikeSource YES` then shows the raw Markdown.
struct NoteEditorSpike: View {
    @State private var text = UserDefaults.standard.string(forKey: "miseSpike") == "probe"
        ? NoteEditorSpike.seed
        : NoteSpike.attributed(markdown: "# Groceries\nNeed **milk** and *eggs* before `9am`\n- apples\n- [ ] bread\n- [x] coffee\n## Ideas\nPlain paragraph to format")
    @State private var selection = AttributedTextSelection()
    @State private var source = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Button { NoteSpike.toggle(.stronglyEmphasized, in: &text, selection: &selection) } label: { Image(systemName: "bold") }
                    Button { NoteSpike.toggle(.emphasized, in: &text, selection: &selection) } label: { Image(systemName: "italic") }
                    Button { NoteSpike.toggle(.code, in: &text, selection: &selection) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    Button("H1") { NoteSpike.toggleHeading(1, in: &text, selection: &selection) }
                    Button("H2") { NoteSpike.toggleHeading(2, in: &text, selection: &selection) }
                    Button { NoteSpike.toggleBullet(in: &text, selection: &selection) } label: { Image(systemName: "list.bullet") }
                    Button { NoteSpike.toggleCheckbox(in: &text, selection: &selection) } label: { Image(systemName: "checklist") }
                    Toggle("Source", isOn: $source).toggleStyle(.button)
                }
                if source {
                    ScrollView { Text(NoteSpike.markdown(text)).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    TextEditor(text: $text, selection: $selection)
                }
            }
            .padding(.horizontal)
            .navigationTitle("Notes spike")
            .onChange(of: text) { old, _ in
                NoteSpike.continueList(old: old, text: &text, selection: &selection)
                NoteSpike.applyShortcuts(&text, selection: &selection)
            }
            .task {
                if UserDefaults.standard.bool(forKey: "miseSpikeType") { await typeScript() }
                source = UserDefaults.standard.bool(forKey: "miseSpikeSource")
            }
        }
    }

    /// Fakes keystrokes through the same onChange path, then exercises the formatting functions.
    private func typeScript() async {
        try? await Task.sleep(for: .milliseconds(500))
        selection = AttributedTextSelection(insertionPoint: text.endIndex)
        for ch in "\n# Typed heading\nbody\n- one\ntwo\n\n[ ] typed task\n" {
            text.replaceSelection(&selection, withCharacters: String(ch))
            try? await Task.sleep(for: .milliseconds(40))
        }
        if let r = text.range(of: "Plain") { selection = AttributedTextSelection(range: r) }
        NoteSpike.toggle(.stronglyEmphasized, in: &text, selection: &selection)
        if let r = text.range(of: "paragraph") { selection = AttributedTextSelection(range: r) }
        NoteSpike.toggle(.emphasized, in: &text, selection: &selection)
        if let r = text.range(of: "bread") { selection = AttributedTextSelection(insertionPoint: r.lowerBound) }
        NoteSpike.toggleCheckbox(in: &text, selection: &selection)
        selection = AttributedTextSelection(insertionPoint: text.endIndex)
    }

    static var seed: AttributedString {
        func line(_ s: String, _ style: (inout AttributedString) -> Void = { _ in }) -> AttributedString {
            var a = AttributedString(s)
            style(&a)
            return a + AttributedString("\n")
        }
        var s = try! AttributedString(markdown: "A: Markdown-parsed **bold** *italic* `code`")
        s.append(AttributedString("\n"))
        s += line("B: font bold") { $0.font = .body.bold() }
        s += line("C: font italic") { $0.font = .body.italic() }
        s += line("D: font bold+italic") { $0.font = .body.bold().italic() }
        s += line("E: inlinePresentationIntent stronglyEmphasized") { $0.inlinePresentationIntent = .stronglyEmphasized }
        s += line("F: inlinePresentationIntent emphasized") { $0.inlinePresentationIntent = .emphasized }
        s += line("G: presentationIntent header 1") { $0.presentationIntent = PresentationIntent(.header(level: 1), identity: 1) }
        s += line("H: font .title heading") { $0.font = .title.bold() }
        s += line("I: strikethrough") { $0.strikethroughStyle = .single }
        s += line("J: foregroundColor secondary") { $0.foregroundColor = .secondary }
        s += try! AttributedString(markdown: "# K heading\n\n- K bullet\n- [ ] K task", options: .init(interpretedSyntax: .full))
        s += AttributedString("\n")
        s += line("☐ L: glyph checkbox")
        s += line("☑ L: glyph checked")
        s += line("• M: glyph bullet")
        return s
    }
}

/// Spike #51 editor logic. A paragraph is the text between "\n"s; headings are a fixed font on the
/// paragraph, bold/italic/code are `inlinePresentationIntent`, lists are glyph prefixes.
enum NoteSpike {
    typealias Index = AttributedString.Index
    static let prefixes = ["• ", "☐ ", "☑ "]
    /// Typed Markdown prefix → editor prefix. Order matters: "- [ ] " becomes "• [ ] " then "☐ ".
    static let shortcuts: [(String, String)] = [
        ("- ", "• "), ("* ", "• "), ("• [ ] ", "☐ "), ("• [x] ", "☑ "), ("• [X] ", "☑ "),
        ("[ ] ", "☐ "), ("[] ", "☐ "), ("[x] ", "☑ "), ("[X] ", "☑ "),
    ]

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        default: .title3.bold()
        }
    }

    static func headingLevel(_ font: Font?) -> Int? {
        [1, 2, 3].first { headingFont($0) == font }
    }

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
        let font: Font? = headingLevel(current) == level ? nil : headingFont(level)
        text.transform(updating: &selection) { $0[start..<end].font = font }
        setTypingFont(font, in: text, selection: &selection)
    }

    static func toggleBullet(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let start = paragraphStart(text, bounds(text, selection).lower)
        let old = prefix(text, at: start)
        replace(old ?? "", with: old == "• " ? "" : "• ", at: start, in: &text, selection: &selection)
    }

    static func toggleCheckbox(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        let start = paragraphStart(text, bounds(text, selection).lower)
        let old = prefix(text, at: start)
        replace(old ?? "", with: old == "☐ " ? "☑ " : "☐ ", at: start, in: &text, selection: &selection)
    }

    /// Turns typed Markdown line prefixes ("# ", "- ", "[ ] "...) into the editor representation. Idempotent.
    // ponytail: whole-document scan per edit, scope to the edited paragraph if long notes lag.
    static func applyShortcuts(_ text: inout AttributedString, selection: inout AttributedTextSelection) {
        var offset = 0  // character offset of the paragraph start; indices go stale after each edit
        while true {
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            if let (from, to) = shortcuts.first(where: { text.characters[start...].starts(with: $0.0) }) {
                replace(from, with: to, at: start, in: &text, selection: &selection)
                continue
            }
            if let level = (1...3).first(where: { text.characters[start...].starts(with: String(repeating: "#", count: $0) + " ") }) {
                replace(String(repeating: "#", count: level) + " ", with: "", at: start, in: &text, selection: &selection)
                let start = text.characters.index(text.startIndex, offsetBy: offset), end = paragraphEnd(text, start)
                text.transform(updating: &selection) { $0[start..<end].font = headingFont(level) }
                setTypingFont(headingFont(level), in: text, selection: &selection, onlyIfIn: offset)
                continue
            }
            guard let newline = text.characters[start...].firstIndex(of: "\n") else { return }
            offset = text.characters.distance(from: text.startIndex, to: newline) + 1
        }
    }

    /// Call from onChange(of: text). After a single typed "\n": continue the previous list item's prefix,
    /// or, if that item was only a prefix, drop the prefix and the new "\n" (ends the list, cursor stays on
    /// that line). After a heading, the new line types as body text.
    static func continueList(old: AttributedString, text: inout AttributedString, selection: inout AttributedTextSelection) {
        guard case .insertionPoint(let cursor) = selection.indices(in: text), cursor > text.startIndex else { return }
        let newline = text.characters.index(before: cursor)
        guard text.characters[newline] == "\n",
              String(text.characters[..<newline]) + String(text.characters[cursor...]) == String(old.characters) else { return }
        let start = paragraphStart(text, newline)
        if let pre = prefix(text, at: start) {
            if text.characters.distance(from: start, to: newline) == 2, paragraphEnd(text, cursor) == cursor {
                text.transform(updating: &selection) { $0.removeSubrange(start..<cursor) }
            } else {
                text.transform(updating: &selection) { $0.insert(AttributedString(pre == "• " ? "• " : "☐ "), at: cursor) }
            }
        } else if start < newline, headingLevel(text[start..<newline].runs.first?.font) != nil {
            setTypingFont(nil, in: text, selection: &selection)
        }
    }

    /// Editor text → Markdown, one line per paragraph.
    // ponytail: literal "*", "`", "#" in body text are not escaped; #53 needs escaping for a lossless round trip.
    // Markers also wrap whitespace as-is, so "**bold **x" fails CommonMark flanking and won't parse back;
    // #53 should move leading/trailing whitespace outside the markers.
    static func markdown(_ text: AttributedString) -> String {
        var lines: [String] = []
        var start = text.startIndex
        while true {
            let end = paragraphEnd(text, start)
            var line = ""
            var body = start
            if start < end, let level = headingLevel(text[start..<end].runs.first?.font) {
                line = String(repeating: "#", count: level) + " "
            }
            if let pre = prefix(text, at: start) {
                line += ["• ": "- ", "☐ ": "- [ ] ", "☑ ": "- [x] "][pre]!
                body = text.characters.index(start, offsetBy: 2)
            }
            for (bits, range) in text[body..<end].runs[\.inlinePresentationIntent] {
                var s = String(text.characters[range])
                let bits = bits ?? []
                if bits.contains(.code) { s = "`" + s + "`" }
                let mark = (bits.contains(.stronglyEmphasized) ? "**" : "") + (bits.contains(.emphasized) ? "*" : "")
                line += mark + s + mark
            }
            lines.append(line)
            guard end < text.endIndex else { return lines.joined(separator: "\n") }
            start = text.characters.index(after: end)
        }
    }

    /// Markdown → editor text: inline syntax parsed per line, then line prefixes via applyShortcuts.
    static func attributed(markdown: String) -> AttributedString {
        var text = AttributedString()
        for (n, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if n > 0 { text += AttributedString("\n") }
            text += (try? AttributedString(markdown: String(line), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(String(line))
        }
        var selection = AttributedTextSelection()
        applyShortcuts(&text, selection: &selection)
        return text
    }

    // MARK: helpers

    static func paragraphStart(_ text: AttributedString, _ i: Index) -> Index {
        text.characters[..<i].lastIndex(of: "\n").map { text.characters.index(after: $0) } ?? text.startIndex
    }

    static func paragraphEnd(_ text: AttributedString, _ i: Index) -> Index {
        text.characters[i...].firstIndex(of: "\n") ?? text.endIndex
    }

    static func prefix(_ text: AttributedString, at start: Index) -> String? {
        prefixes.first { text.characters[start...].starts(with: $0) }
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
        // Inherit the paragraph's attributes (heading font) unless the paragraph is empty.
        let attrs = start < text.endIndex && text.characters[start] != "\n" ? text[start...].runs.first!.attributes : AttributeContainer()
        text.transform(updating: &selection) { $0.replaceSubrange(start..<end, with: AttributedString(new, attributes: attrs)) }
    }

    /// Sets the typing font when the cursor is an insertion point (optionally only in the paragraph at `offset`).
    private static func setTypingFont(_ font: Font?, in text: AttributedString, selection: inout AttributedTextSelection, onlyIfIn offset: Int? = nil) {
        guard case .insertionPoint(let i) = selection.indices(in: text) else { return }
        if let offset, text.characters.distance(from: text.startIndex, to: paragraphStart(text, i)) != offset { return }
        var attrs = selection.typingAttributes(in: text)
        attrs.font = font
        selection = AttributedTextSelection(insertionPoint: i, typingAttributes: attrs)
    }
}
#endif
