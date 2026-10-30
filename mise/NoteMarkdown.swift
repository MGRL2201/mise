import SwiftUI

/// Note Markdown ⇄ editor text. A paragraph is the text between "\n"s, laid out as
/// [indent][quote glyph per level][list glyph]?[inline content]; a heading is a font on the whole paragraph.
/// Fenced code lines stay literal text with `.code` on every character.
// ponytail: headings 1–3 only; "#### x" stays literal text.
// ponytail: ``` fences only, ~~~ fences load as plain lines.
// ponytail: literal "•"/"☐"/"☑"/"▍" typed at a Markdown line start load as list/quote structure.
// ponytail: nested lists are just preserved leading indentation, no list tree.
// ponytail: Apple's inline parser drops emphasis/code inside link text and image alt, so "[**a**](u)" saves as "[a](u)".
// ponytail: link titles are dropped; backticks in plain text are always escaped, so "\\``` x" saves as "\\`\\`\\` x".
// ponytail: a closing marker between punctuation and a letter ("**foo.**bar") fails CommonMark flanking and reloads
// as literal asterisks (same for an opener between a letter and punctuation, and for emphasis ending at a link/code span
// before a letter or starting at one after a letter, "**[a](u)**s"); partly overlapping bold/italic may write "****".
// ponytail: bare URLs/emails are found with NSDataDetector and assume its extent matches Apple's autolink extent;
// where it doesn't ("https://a.b/c&amp;" autolinks only up to "c") the reload shifts text. Swap in Apple's rules if that bites.
enum NoteMarkdown {
    static let quote = "▍ "
    static let bullet = "• "
    static let openTask = "☐ "
    static let doneTask = "☑ "
    static let listGlyphs = [bullet, openTask, doneTask]
    private static let listMarkers = [bullet: "- ", openTask: "- [ ] ", doneTask: "- [x] "]
    /// Line starts the parser reads as block markers; written with a leading "\" so they load as text.
    private static let blockStarts = ["# ", "## ", "### ", "- ", "+ ", ">"]
    /// Emphasis markers in opening order (outermost first).
    private static let markers: [(mark: String, bit: InlinePresentationIntent)] =
        [("**", .stronglyEmphasized), ("*", .emphasized), ("~~", .strikethrough)]

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

    /// The list glyph at `start`, if any.
    static func prefix(_ text: AttributedString, at start: AttributedString.Index) -> String? {
        listGlyphs.first { text.characters[start...].starts(with: $0) }
    }

    static func attributed(_ markdown: String) -> AttributedString {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var text = AttributedString()
        var fence = false
        for (n, line) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if n > 0 { text += AttributedString("\n") }
            let afterIndent = line.drop { $0 == " " || $0 == "\t" }
            if fence || opensFence(afterIndent) {
                fence = !fence || !closesFence(afterIndent)  // opening line, or not yet closed
                var code = AttributedString(String(line))
                code.inlinePresentationIntent = .code
                text += code
                continue
            }
            var head = String(line[..<afterIndent.startIndex])
            var rest = afterIndent
            while rest.hasPrefix("> ") || rest == ">" {
                rest = rest.dropFirst(2)
                head += quote
            }
            let level = (1...3).first { rest.hasPrefix(String(repeating: "#", count: $0) + " ") }
            if let level { rest = rest.dropFirst(level + 1) }
            if let c = rest.first, "-*+".contains(c), rest.dropFirst().hasPrefix(" ") {
                rest = rest.dropFirst(2)
                if rest.hasPrefix("[ ] ") {
                    head += openTask
                    rest = rest.dropFirst(4)
                } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
                    head += doneTask
                    rest = rest.dropFirst(4)
                } else {
                    head += bullet
                }
            }
            var paragraph = AttributedString(head)
            paragraph += (try? AttributedString(markdown: String(rest), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(String(rest))
            // ponytail: an empty heading ("# ") has no character to hold the font, so it saves back as an empty line.
            if let level { paragraph.font = headingFont(level) }
            text += paragraph
        }
        return text
    }

    static func markdown(_ text: AttributedString) -> String {
        var lines: [String] = []
        var fence = false
        for p in text.characters.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let raw = String(p)
            let afterIndent = raw.drop { $0 == " " || $0 == "\t" }
            let textStart = text.characters.index(p.endIndex, offsetBy: -afterIndent.count)
            // Only a ``` that is code opens a fence; typed ``` is text and gets escaped.
            if fence || (opensFence(afterIndent) && text[textStart..<p.endIndex].runs.first?.inlinePresentationIntent?.contains(.code) == true) {
                fence = !fence || !closesFence(afterIndent)
                lines.append(raw)
                continue
            }
            // Leading whitespace inside a code span is code, not indent.
            let codeFirst = text[p.startIndex..<p.endIndex].runs.first?.inlinePresentationIntent?.contains(.code) == true
            var line = codeFirst ? "" : String(raw[..<afterIndent.startIndex])
            var rest = codeFirst ? raw[...] : afterIndent
            while rest.hasPrefix(quote) {
                line += "> "
                rest = rest.dropFirst(quote.count)
            }
            // ponytail: leading whitespace in heading text is written before the "#" (lossless here; 4+ spaces/tab reads as indented code elsewhere).
            if !p.isEmpty, let level = headingLevel(text[p.startIndex..<p.endIndex].runs.first?.font) {
                line += String(repeating: "#", count: level) + " "
            }
            if rest.isEmpty, line.hasSuffix("> ") { line.removeLast() }  // empty quote line saves as ">"
            if let glyph = listGlyphs.first(where: { rest.hasPrefix($0) }) {
                line += listMarkers[glyph]!
                rest = rest.dropFirst(glyph.count)
            }
            let inline = inlineMarkdown(text[text.characters.index(p.endIndex, offsetBy: -rest.count)..<p.endIndex])
            if blockStarts.contains(where: { inline.hasPrefix($0) }) { line += "\\" }
            lines.append(line + inline)
        }
        return lines.joined(separator: "\n")
    }

    /// Inline runs → Markdown. Emphasis markers open and close as a stack across runs; links, images,
    /// code spans and inline HTML are written whole inside them (links innermost, as Apple drops emphasis inside link text).
    private static func inlineMarkdown(_ text: AttributedSubstring) -> String {
        let text = unlinkingBareURLs(text)
        let runs = text.runs[\.inlinePresentationIntent, \.link, \.imageURL].map {
            (text: Substring(String(text.characters[$0.3])), bits: $0.0 ?? [], link: $0.1, image: $0.2)
        }
        // Edge whitespace of plain runs keeps only the emphasis shared with that side's neighbour: "**bold** x", not "**bold **x".
        var segments: [(text: Substring, bits: InlinePresentationIntent, link: URL?, image: URL?)] = []
        for (i, r) in runs.enumerated() {
            let s = r.text
            guard r.link == nil, r.image == nil, r.bits.isDisjoint(with: [.code, .inlineHTML]) else {
                segments.append(r)
                continue
            }
            let before = i > 0 ? runs[i - 1].bits : []
            let after = i + 1 < runs.count ? runs[i + 1].bits : []
            let start = s.firstIndex { !$0.isWhitespace } ?? s.endIndex
            let end = s.lastIndex { !$0.isWhitespace }.map(s.index(after:)) ?? s.endIndex
            let pieces = start == s.endIndex
                ? [(s, r.bits.intersection(before).intersection(after))]
                : [(s[..<start], r.bits.intersection(before)), (s[start..<end], r.bits), (s[end...], r.bits.intersection(after))]
            for (t, bits) in pieces where !t.isEmpty { segments.append((t, bits, nil, nil)) }
        }
        var out = ""
        var open: [String] = []
        for seg in segments {
            let want = markers.filter { seg.bits.contains($0.bit) }.map(\.mark)
            if let k = open.firstIndex(where: { !want.contains($0) }) {
                out += open[k...].reversed().joined()
                open.removeSubrange(k...)
            }
            for m in want where !open.contains(m) {
                out += m
                open.append(m)
            }
            let piece = written(seg.text, seg.bits, link: seg.link, image: seg.image)
            if piece.hasPrefix("["), out.hasSuffix("!") { out.insert("\\", at: out.index(before: out.endIndex)) }  // "!" + link is not an image
            out += piece
        }
        return out + open.reversed().joined()
    }

    /// A link that is its own bare URL, as Apple's autolinking makes it, becomes plain text (written raw by `written`).
    private static func unlinkingBareURLs(_ text: AttributedSubstring) -> AttributedString {
        var out = AttributedString()
        for r in text.runs {
            var piece = AttributedString(text[r.range])
            let s = String(piece.characters)
            let before = r.range.lowerBound > text.startIndex ? text.characters[text.characters.index(before: r.range.lowerBound)] : " "
            let after = text.characters[r.range.upperBound...].drop { "?!.,:*_~)".contains($0) }.first ?? " "
            if let link = r.link, r.imageURL == nil, (r.inlinePresentationIntent ?? []).isDisjoint(with: [.code, .inlineHTML]),
               before.isWhitespace || "(*_~".contains(before), after.isWhitespace,
               let m = bareLinks(s).first, m.range == s.startIndex..<s.endIndex, m.url == link {
                piece.link = nil
            }
            out += piece
        }
        return out
    }

    private static func written(_ s: Substring, _ bits: InlinePresentationIntent, link: URL?, image: URL?) -> String {
        if let link, image == nil, !bits.contains(.code), s == link.absoluteString, (link.scheme?.count ?? 0) > 1, !s.contains("&") {
            return "<\(s)>"  // Apple decodes entities inside <...>
        }
        var out = bits.contains(.code) ? codeSpan(s) : bits.contains(.inlineHTML) ? String(s)
            : link == nil && image == nil ? escapedKeepingURLs(s) : escaped(s)
        if link != nil || image != nil { out = out.replacingOccurrences(of: "]", with: "\\]") }  // plain "]" needs no escape: "[" always has one
        if let image { out = "![\(out)](\(destination(image)))" }
        if let link { out = "[\(out)](\(destination(link)))" }
        return out
    }

    /// Shortest backtick fence that no backtick run in the content matches; padded where CommonMark would strip or merge.
    private static func codeSpan(_ s: Substring) -> String {
        let runs = Set(s.split { $0 != "`" }.map(\.count))
        let ticks = String(repeating: "`", count: (1...).first { !runs.contains($0) }!)
        let pad = s.hasPrefix("`") || s.hasSuffix("`") || (s.hasPrefix(" ") && s.hasSuffix(" ") && s.contains { $0 != " " }) ? " " : ""
        return ticks + pad + s + pad + ticks
    }

    /// `escaped`, except bare URLs/emails stay raw: Apple autolinks them on load and keeps a backslash inside as text.
    private static func escapedKeepingURLs(_ s: Substring) -> String {
        let s = String(s)
        var out = ""
        var i = s.startIndex
        for m in bareLinks(s) {
            out += escaped(s[i..<m.range.lowerBound]) + s[m.range]
            i = m.range.upperBound
        }
        return out + escaped(s[i...])
    }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// URLs and emails Apple's parser autolinks in plain text (GFM: scheme://, www., emails).
    private static func bareLinks(_ s: String) -> [(range: Range<String.Index>, url: URL)] {
        detector.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s), let url = m.url else { return nil }
            let t = s[r].lowercased()
            return url.scheme == "mailto" || ["http://", "https://", "ftp://", "www.", "xmpp:"].contains(where: t.hasPrefix) ? (r, url) : nil
        }
    }

    /// Backslash-escapes characters Apple's inline parser would read as syntax ("&" too where it starts an entity).
    private static func escaped(_ s: Substring) -> String {
        let isWord = { (c: Character) in c.isLetter || c.isNumber }
        var out = ""
        for i in s.indices {
            let c = s[i]
            let next = s.index(after: i)
            let intraword = i > s.startIndex && next < s.endIndex && isWord(s[s.index(before: i)]) && isWord(s[next])
            let entity = c == "&" && s[next...].prefixMatch(of: /#?[A-Za-z0-9]+;/) != nil
            if "\\*`[<~".contains(c) || entity || (c == "_" && !intraword) { out += "\\" }
            out.append(c)
        }
        return out
    }

    private static func destination(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
    }

    /// An opening fence: ``` with no backtick in the info string (CommonMark).
    private static func opensFence(_ line: Substring) -> Bool {
        line.hasPrefix("```") && !line.drop { $0 == "`" }.contains("`")
    }

    /// A closing fence: 3+ backticks and nothing else.
    private static func closesFence(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == "`" }
    }
}
