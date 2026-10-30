import SwiftUI

/// Note Markdown ⇄ editor text. A paragraph is the text between "\n"s, laid out as
/// [indent][quote glyph per level][list glyph]?[inline content]; a heading is a font on the whole paragraph.
/// Fenced code lines stay literal text with `.code` on every character.
// ponytail: headings 1–3 only; "#### x" stays literal text.
// ponytail: ``` fences only, ~~~ fences load as plain lines.
// ponytail: literal "•"/"☐"/"☑"/"▍" typed at a Markdown line start load as list/quote structure.
// ponytail: nested lists are just preserved leading indentation, no list tree.
enum NoteMarkdown {
    static let quote = "▍ "
    static let bullet = "• "
    static let openTask = "☐ "
    static let doneTask = "☑ "
    static let listGlyphs = [bullet, openTask, doneTask]
    private static let listMarkers = [bullet: "- ", openTask: "- [ ] ", doneTask: "- [x] "]
    /// Line starts the parser reads as block markers; written with a leading "\" so they load as text.
    private static let blockStarts = ["# ", "## ", "### ", "- ", "* ", "+ ", ">", "```"]

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
            if fence || afterIndent.hasPrefix("```") {
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
        for p in text.characters.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(p)
            let afterIndent = raw.drop { $0 == " " || $0 == "\t" }
            if fence || afterIndent.hasPrefix("```") {
                fence = !fence || !closesFence(afterIndent)
                lines.append(raw)
                continue
            }
            var line = String(raw[..<afterIndent.startIndex])
            var rest = afterIndent
            while rest.hasPrefix(quote) {
                line += "> "
                rest = rest.dropFirst(quote.count)
            }
            if !p.isEmpty, let level = headingLevel(text[p.startIndex..<p.endIndex].runs.first?.font) {
                line += String(repeating: "#", count: level) + " "
            }
            if rest.isEmpty, line.hasSuffix("> ") { line.removeLast() }  // empty quote line saves as ">"
            if let glyph = listGlyphs.first(where: { rest.hasPrefix($0) }) {
                line += listMarkers[glyph]!
                rest = rest.dropFirst(glyph.count)
            }
            // ponytail: spike's inline writer; no inline escaping, markers wrap edge whitespace, links/strikethrough dropped.
            var inline = ""
            let body = text.characters.index(p.endIndex, offsetBy: -rest.count)
            for (bits, range) in text[body..<p.endIndex].runs[\.inlinePresentationIntent] {
                var s = String(text.characters[range])
                let bits = bits ?? []
                if bits.contains(.code) { s = "`" + s + "`" }
                let mark = (bits.contains(.stronglyEmphasized) ? "**" : "") + (bits.contains(.emphasized) ? "*" : "")
                inline += mark + s + mark
            }
            if blockStarts.contains(where: { inline.hasPrefix($0) }) { line += "\\" }
            lines.append(line + inline)
        }
        return lines.joined(separator: "\n")
    }

    /// A closing fence: 3+ backticks and nothing else.
    private static func closesFence(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == "`" }
    }
}
