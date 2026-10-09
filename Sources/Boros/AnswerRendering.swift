import AppKit

// Display-only rendering of transcript messages (fix E in
// docs/ANSWER-PRESENTATION-DEFECTS.md). The renderer never changes stored
// text. Every rendered character carries the original UTF-16 span that
// produced it, and every message carries its complete original text, so copy
// and "Show Original Text" return the exact stored bytes.
//
// Answers are untrusted. The parser is a bounded, line-based Markdown subset
// written for this display: no HTML, no images, no reference definitions, no
// automatic links and no remote loads. Unrecognized syntax stays literal.

extension NSAttributedString.Key {
    /// The complete original text of one transcript message.
    static let borosMessageSource = NSAttributedString.Key("dev.boros.transcript.messageSource")
    /// The original UTF-16 span of the message text that produced these characters.
    static let borosSourceSpan = NSAttributedString.Key("dev.boros.transcript.sourceSpan")
    /// A validated http or https URL, opened only by an explicit click.
    static let borosLink = NSAttributedString.Key("dev.boros.transcript.link")
}

/// The exact stored text of one displayed message. Identity equality keeps
/// adjacent messages in separate attribute runs.
final class TranscriptMessageSource: NSObject {
    let text: String
    let isAssistant: Bool
    let length: Int
    init(text: String, isAssistant: Bool) {
        self.text = text
        self.isAssistant = isAssistant
        self.length = (text as NSString).length
    }
}

/// A verbatim span maps each rendered UTF-16 unit to one source unit, in order.
/// A synthetic span (bullet, math, rule) maps all its characters to the whole source span.
final class RenderedSourceSpan: NSObject {
    let location: Int
    let length: Int
    let verbatim: Bool
    init(location: Int, length: Int, verbatim: Bool) {
        self.location = location
        self.length = length
        self.verbatim = verbatim
    }
}

enum AnswerRendering {
    /// Larger answers are shown as plain text; see the performance checks.
    static let maximumMarkdownUnits = 400_000
    static let maximumNestingDepth = 8
    static let maximumTableColumns = 24
    static let maximumInlineMathUnits = 400
    static let maximumDisplayMathUnits = 4_000
    static let maximumLinkLabelUnits = 1_000
    static let maximumLinkDestinationUnits = 2_048
    static let bodySize: CGFloat = 13

    static var proseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.textColor]
    }

    /// One transcript message body. Only assistant text is parsed as Markdown;
    /// human text is shown as typed. `rendered == false` reproduces the
    /// original plain display with `rawAttributes`.
    static func message(_ text: String, assistant: Bool, rendered: Bool,
                        rawAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let body: NSMutableAttributedString
        if rendered && assistant { body = NSMutableAttributedString(attributedString: markdown(text)) }
        else { body = plain(text, attributes: rendered ? proseAttributes : rawAttributes) }
        body.addAttribute(.borosMessageSource, value: TranscriptMessageSource(text: text, isAssistant: assistant),
                          range: NSRange(location: 0, length: body.length))
        return body
    }

    static func plain(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if result.length > 0 {
            result.addAttribute(.borosSourceSpan, value: RenderedSourceSpan(location: 0, length: result.length, verbatim: true),
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// Renders Markdown and inline math for display. Falls back to plain text
    /// for empty, whitespace-only or oversized input.
    static func markdown(_ text: String) -> NSAttributedString {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= maximumMarkdownUnits,
              units.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }) else {
            return plain(text, attributes: proseAttributes)
        }
        let parser = MarkdownBlockParser(units)
        let blocks = parser.parse(MarkdownBlockParser.lines(units), depth: 0)
        let renderer = MarkdownAttributedRenderer(units, parser: parser)
        renderer.render(blocks, MarkdownAttributedRenderer.Context())
        let out = renderer.out
        if out.length > 0, (out.string as NSString).character(at: out.length - 1) == 0x0A {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out.length == 0 ? plain(text, attributes: proseAttributes) : out
    }

    /// Accepts only absolute http or https URLs with a host and no embedded
    /// credentials, whitespace or control characters.
    static func safeLinkURL(_ destination: String) -> URL? {
        guard !destination.isEmpty, destination.utf16.count <= maximumLinkDestinationUnits,
              destination.unicodeScalars.allSatisfy({ scalar in
                  scalar.value > 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
                      && !scalar.properties.isWhitespace
              }),
              let components = URLComponents(string: destination),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// True for host citation labels such as `E1` or `E1, E2` (the text inside brackets).
    static func isCitationLabel(_ units: ArraySlice<UInt16>) -> Bool {
        var index = units.startIndex
        var sawLabel = false
        while index < units.endIndex {
            while index < units.endIndex && (units[index] == 0x20 || units[index] == 0x2C) { index += 1 }
            guard index < units.endIndex else { break }
            guard units[index] == 0x45, index + 1 < units.endIndex, (0x31...0x39).contains(units[index + 1]) else { return false }
            index += 2
            while index < units.endIndex && (0x30...0x39).contains(units[index]) { index += 1 }
            sawLabel = true
            if index < units.endIndex && units[index] != 0x20 && units[index] != 0x2C { return false }
        }
        return sawLabel
    }

    static func messageSource(at index: Int, in text: NSAttributedString) -> TranscriptMessageSource? {
        guard index >= 0, index < text.length else { return nil }
        return text.attribute(.borosMessageSource, at: index, effectiveRange: nil) as? TranscriptMessageSource
    }

    /// The original text for a displayed range. Message characters map back to
    /// the stored text: a range that reaches a message's first or last rendered
    /// character extends to that message's start or end, so selecting a whole
    /// message yields its exact stored bytes. Other characters (speaker lines,
    /// separators, status notes) are copied as displayed.
    static func originalText(in range: NSRange, of text: NSAttributedString) -> String {
        let whole = NSRange(location: 0, length: text.length)
        let bounded = NSIntersectionRange(range, whole)
        guard bounded.length > 0 else { return "" }
        var result = ""
        text.enumerateAttribute(.borosMessageSource, in: bounded, options: []) { value, sub, _ in
            guard let source = value as? TranscriptMessageSource else {
                result += text.attributedSubstring(from: sub).string
                return
            }
            var full = NSRange()
            _ = text.attribute(.borosMessageSource, at: sub.location, longestEffectiveRange: &full, in: whole)
            var first: (Int, Int)?
            var last: (Int, Int)?
            text.enumerateAttribute(.borosSourceSpan, in: sub, options: []) { spanValue, spanRange, _ in
                guard let span = spanValue as? RenderedSourceSpan else { return }
                var run = NSRange()
                _ = text.attribute(.borosSourceSpan, at: spanRange.location, longestEffectiveRange: &run, in: full)
                func map(_ index: Int) -> (Int, Int) {
                    if span.verbatim {
                        let start = span.location + (index - run.location)
                        return (start, start + 1)
                    }
                    return (span.location, span.location + span.length)
                }
                if first == nil { first = map(spanRange.location) }
                last = map(NSMaxRange(spanRange) - 1)
            }
            let reachesStart = sub.location == full.location
            let reachesEnd = NSMaxRange(sub) == NSMaxRange(full)
            guard first != nil || (reachesStart && reachesEnd) else { return }
            var start = reachesStart ? 0 : (first?.0 ?? 0)
            var end = reachesEnd ? source.length : (last?.1 ?? source.length)
            start = max(0, min(start, source.length))
            end = max(start, min(end, source.length))
            guard end > start else { return }
            let original = source.text as NSString
            let composed = original.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            result += original.substring(with: composed)
        }
        return result
    }
}

// MARK: - Block parsing

private enum MD {
    static let space: UInt16 = 0x20, tab: UInt16 = 0x09, newline: UInt16 = 0x0A, carriageReturn: UInt16 = 0x0D
    static let backslash: UInt16 = 0x5C, backtick: UInt16 = 0x60, tilde: UInt16 = 0x7E, dollar: UInt16 = 0x24
    static let star: UInt16 = 0x2A, underscore: UInt16 = 0x5F, hash: UInt16 = 0x23, greater: UInt16 = 0x3E
    static let less: UInt16 = 0x3C, pipe: UInt16 = 0x7C, dash: UInt16 = 0x2D, plus: UInt16 = 0x2B
    static let colon: UInt16 = 0x3A, period: UInt16 = 0x2E, closeParen: UInt16 = 0x29, openParen: UInt16 = 0x28
    static let openBracket: UInt16 = 0x5B, closeBracket: UInt16 = 0x5D, bang: UInt16 = 0x21
    static let lineSeparator: UInt16 = 0x2028

    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    static func isLetter(_ u: UInt16) -> Bool { (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) }
    static func isSpaceOrTab(_ u: UInt16) -> Bool { u == space || u == tab }
    static func isASCIIPunctuation(_ u: UInt16) -> Bool {
        (u >= 0x21 && u <= 0x2F) || (u >= 0x3A && u <= 0x40) || (u >= 0x5B && u <= 0x60) || (u >= 0x7B && u <= 0x7E)
    }
    static func isWhitespace(_ u: UInt16?) -> Bool {
        guard let u else { return true }
        if u < 0x80 { return u == space || u == tab || u == newline || u == carriageReturn || u == 0x0B || u == 0x0C }
        if u >= 0xD800 && u <= 0xDFFF { return false }
        return Unicode.Scalar(u).map { $0.properties.isWhitespace } ?? false
    }
    static func isPunctuation(_ u: UInt16?) -> Bool {
        guard let u else { return false }
        if u < 0x80 { return isASCIIPunctuation(u) }
        if u >= 0xD800 && u <= 0xDFFF { return false }
        guard let scalar = Unicode.Scalar(u) else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
        default: return false
        }
    }
    static func string(_ units: ArraySlice<UInt16>) -> String {
        guard !units.isEmpty else { return "" }
        return units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
    }
}

struct MDLine {
    var start: Int
    var end: Int
}

struct MDListItem {
    let marker: Range<Int>
    let ordered: Bool
    let blocks: [MDBlock]
}

indirect enum MDBlock {
    case paragraph([MDLine])
    case heading(Int, Range<Int>)
    case code([MDLine])
    case rule(MDLine)
    case quote([MDBlock])
    case list([MDListItem])
    case table([[Range<Int>]], [NSTextAlignment])
    case plain([MDLine])
}

private struct ListMarker {
    let indent: Int
    let marker: Range<Int>
    let contentColumn: Int
    let contentStart: Int
    let ordered: Bool
    let kind: UInt16
    let empty: Bool
    let startsWithOne: Bool
}

final class MarkdownBlockParser {
    let u: [UInt16]
    init(_ units: [UInt16]) { u = units }

    static func lines(_ u: [UInt16]) -> [MDLine] {
        var result: [MDLine] = []
        var start = 0, index = 0
        while index < u.count {
            if u[index] == MD.newline {
                result.append(MDLine(start: start, end: index)); index += 1; start = index
            } else if u[index] == MD.carriageReturn {
                result.append(MDLine(start: start, end: index))
                index += (index + 1 < u.count && u[index + 1] == MD.newline) ? 2 : 1
                start = index
            } else { index += 1 }
        }
        if start < u.count { result.append(MDLine(start: start, end: u.count)) }
        return result
    }

    func isBlank(_ line: MDLine) -> Bool {
        var index = line.start
        while index < line.end { if !MD.isSpaceOrTab(u[index]) { return false }; index += 1 }
        return true
    }

    func indent(_ line: MDLine) -> (columns: Int, first: Int) {
        var columns = 0, index = line.start
        while index < line.end {
            if u[index] == MD.space { columns += 1 } else if u[index] == MD.tab { columns += 4 - columns % 4 } else { break }
            index += 1
        }
        return (columns, index)
    }

    func strip(_ line: MDLine, columns limit: Int) -> MDLine {
        var columns = 0, index = line.start
        while index < line.end && columns < limit {
            if u[index] == MD.space { columns += 1 } else if u[index] == MD.tab { columns += 4 - columns % 4 } else { break }
            index += 1
        }
        return MDLine(start: index, end: line.end)
    }

    private func fenceOpen(_ line: MDLine) -> (char: UInt16, count: Int, indent: Int)? {
        let (columns, first) = indent(line)
        guard columns <= 3, first < line.end, u[first] == MD.backtick || u[first] == MD.tilde else { return nil }
        let char = u[first]
        var index = first
        while index < line.end && u[index] == char { index += 1 }
        guard index - first >= 3 else { return nil }
        if char == MD.backtick { for position in index..<line.end where u[position] == MD.backtick { return nil } }
        return (char, index - first, columns)
    }

    private func isFenceClose(_ line: MDLine, char: UInt16, count: Int) -> Bool {
        let (columns, first) = indent(line)
        guard columns <= 3 else { return false }
        var index = first
        while index < line.end && u[index] == char { index += 1 }
        guard index - first >= count else { return false }
        while index < line.end { if !MD.isSpaceOrTab(u[index]) { return false }; index += 1 }
        return true
    }

    private func heading(_ line: MDLine) -> (level: Int, content: Range<Int>)? {
        let (columns, first) = indent(line)
        guard columns <= 3, first < line.end, u[first] == MD.hash else { return nil }
        var index = first
        while index < line.end && u[index] == MD.hash { index += 1 }
        let level = index - first
        guard level <= 6, index == line.end || MD.isSpaceOrTab(u[index]) else { return nil }
        var start = index
        while start < line.end && MD.isSpaceOrTab(u[start]) { start += 1 }
        var end = line.end
        while end > start && MD.isSpaceOrTab(u[end - 1]) { end -= 1 }
        var closing = end
        while closing > start && u[closing - 1] == MD.hash { closing -= 1 }
        if closing == start { end = start }
        else if closing < end && MD.isSpaceOrTab(u[closing - 1]) {
            end = closing
            while end > start && MD.isSpaceOrTab(u[end - 1]) { end -= 1 }
        }
        return (level, start..<end)
    }

    private func isThematicBreak(_ line: MDLine) -> Bool {
        let (columns, first) = indent(line)
        guard columns <= 3, first < line.end else { return false }
        let char = u[first]
        guard char == MD.dash || char == MD.star || char == MD.underscore else { return false }
        var count = 0
        for index in first..<line.end {
            if u[index] == char { count += 1 } else if !MD.isSpaceOrTab(u[index]) { return false }
        }
        return count >= 3
    }

    private func listMarker(_ line: MDLine) -> ListMarker? {
        let (columns, first) = indent(line)
        guard columns <= 3, first < line.end else { return nil }
        var index = first
        let ordered: Bool, kind: UInt16
        var startsWithOne = false
        if u[first] == MD.dash || u[first] == MD.plus || u[first] == MD.star {
            index = first + 1; ordered = false; kind = u[first]
        } else if MD.isDigit(u[first]) {
            while index < line.end && MD.isDigit(u[index]) && index - first < 9 { index += 1 }
            guard index < line.end, u[index] == MD.period || u[index] == MD.closeParen else { return nil }
            startsWithOne = index - first == 1 && u[first] == 0x31
            kind = u[index]; index += 1; ordered = true
        } else { return nil }
        let markerEnd = index
        guard index == line.end || MD.isSpaceOrTab(u[index]) else { return nil }
        let markerColumns = columns + (markerEnd - first)
        var contentColumns = markerColumns, position = index
        while position < line.end && MD.isSpaceOrTab(u[position]) {
            contentColumns += u[position] == MD.tab ? 4 - contentColumns % 4 : 1
            position += 1
        }
        let empty = position == line.end
        let width = contentColumns - markerColumns
        let contentColumn = (empty || width > 4) ? markerColumns + 1 : contentColumns
        let contentStart = empty ? line.end : (width > 4 ? markerEnd + 1 : position)
        return ListMarker(indent: columns, marker: first..<markerEnd, contentColumn: contentColumn,
                          contentStart: contentStart, ordered: ordered, kind: kind, empty: empty, startsWithOne: startsWithOne)
    }

    private func quoteContent(_ line: MDLine) -> MDLine? {
        let (columns, first) = indent(line)
        guard columns <= 3, first < line.end, u[first] == MD.greater else { return nil }
        var start = first + 1
        if start < line.end && MD.isSpaceOrTab(u[start]) { start += 1 }
        return MDLine(start: start, end: line.end)
    }

    private func startsBlock(_ line: MDLine) -> Bool {
        let (columns, first) = indent(line)
        guard columns <= 3, first < line.end else { return false }
        return fenceOpen(line) != nil || heading(line) != nil || isThematicBreak(line)
            || u[first] == MD.greater || listMarker(line) != nil
    }

    /// Cells split on unescaped pipes, with outer pipes and whitespace removed.
    func cells(_ line: MDLine) -> [Range<Int>] {
        var start = line.start, end = line.end
        while start < end && MD.isSpaceOrTab(u[start]) { start += 1 }
        while end > start && MD.isSpaceOrTab(u[end - 1]) { end -= 1 }
        if start < end && u[start] == MD.pipe { start += 1 }
        if end > start && u[end - 1] == MD.pipe && !(end - 2 >= start && u[end - 2] == MD.backslash) { end -= 1 }
        var result: [Range<Int>] = []
        var cellStart = start, index = start
        func close(_ cellEnd: Int) {
            var low = cellStart, high = cellEnd
            while low < high && MD.isSpaceOrTab(u[low]) { low += 1 }
            while high > low && MD.isSpaceOrTab(u[high - 1]) { high -= 1 }
            result.append(low..<high)
        }
        while index < end {
            if u[index] == MD.backslash { index += 2; continue }
            if u[index] == MD.pipe { close(index); cellStart = index + 1 }
            index += 1
        }
        close(max(cellStart, end))
        return result
    }

    private func hasUnescapedPipe(_ line: MDLine) -> Bool {
        var index = line.start
        while index < line.end {
            if u[index] == MD.backslash { index += 2; continue }
            if u[index] == MD.pipe { return true }
            index += 1
        }
        return false
    }

    private func delimiterRow(_ line: MDLine) -> [NSTextAlignment]? {
        var sawPipeOrDash = false
        for index in line.start..<line.end {
            let unit = u[index]
            if unit == MD.pipe || unit == MD.dash { sawPipeOrDash = true }
            else if unit != MD.colon && !MD.isSpaceOrTab(unit) { return nil }
        }
        guard sawPipeOrDash, hasUnescapedPipe(line) else { return nil }
        var alignments: [NSTextAlignment] = []
        for cell in cells(line) {
            guard !cell.isEmpty else { return nil }
            var low = cell.lowerBound, high = cell.upperBound
            let left = u[low] == MD.colon, right = u[high - 1] == MD.colon
            if left { low += 1 }
            if right && high > low { high -= 1 }
            guard low < high else { return nil }
            for index in low..<high where u[index] != MD.dash { return nil }
            alignments.append(left && right ? .center : right ? .right : left ? .left : .natural)
        }
        return alignments.isEmpty ? nil : alignments
    }

    private func table(_ lines: [MDLine], from index: Int) -> (MDBlock, Int)? {
        guard index + 1 < lines.count, hasUnescapedPipe(lines[index]),
              let alignments = delimiterRow(lines[index + 1]),
              alignments.count <= AnswerRendering.maximumTableColumns else { return nil }
        let header = cells(lines[index])
        guard header.count == alignments.count else { return nil }
        var rows = [header]
        var next = index + 2
        while next < lines.count && !isBlank(lines[next]) && !startsBlock(lines[next]) {
            var row = cells(lines[next])
            if row.count > alignments.count { row.removeLast(row.count - alignments.count) }
            while row.count < alignments.count { row.append(lines[next].end..<lines[next].end) }
            rows.append(row)
            next += 1
        }
        return (.table(rows, alignments), next)
    }

    func parse(_ lines: [MDLine], depth: Int) -> [MDBlock] {
        if depth > AnswerRendering.maximumNestingDepth { return [.plain(lines)] }
        var blocks: [MDBlock] = []
        var paragraph: [MDLine] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)); paragraph = [] } }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) { flush(); index += 1; continue }
            let (columns, first) = indent(line)
            if columns >= 4 {
                if paragraph.isEmpty {
                    var code: [MDLine] = []
                    var next = index
                    while next < lines.count && (isBlank(lines[next]) || indent(lines[next]).columns >= 4) {
                        code.append(strip(lines[next], columns: 4)); next += 1
                    }
                    while let last = code.last, isBlank(last) { code.removeLast() }
                    blocks.append(.code(code)); index = next; continue
                }
                paragraph.append(line); index += 1; continue
            }
            if let fence = fenceOpen(line) {
                flush()
                var content: [MDLine] = []
                var next = index + 1
                while next < lines.count && !isFenceClose(lines[next], char: fence.char, count: fence.count) {
                    content.append(strip(lines[next], columns: fence.indent)); next += 1
                }
                blocks.append(.code(content)); index = min(next + 1, lines.count); continue
            }
            if let heading = heading(line) { flush(); blocks.append(.heading(heading.level, heading.content)); index += 1; continue }
            if isThematicBreak(line) { flush(); blocks.append(.rule(line)); index += 1; continue }
            if u[first] == MD.greater {
                flush()
                var inner: [MDLine] = []
                var next = index
                while next < lines.count, let content = quoteContent(lines[next]) { inner.append(content); next += 1 }
                blocks.append(.quote(parse(inner, depth: depth + 1))); index = next; continue
            }
            if let marker = listMarker(line),
               paragraph.isEmpty || (!marker.empty && (!marker.ordered || marker.startsWithOne)) {
                flush()
                let (list, next) = parseList(lines, from: index, first: marker, depth: depth)
                blocks.append(list); index = next; continue
            }
            if let (table, next) = table(lines, from: index) { flush(); blocks.append(table); index = next; continue }
            paragraph.append(line); index += 1
        }
        flush()
        return blocks
    }

    private func parseList(_ lines: [MDLine], from start: Int, first: ListMarker, depth: Int) -> (MDBlock, Int) {
        func compatible(_ marker: ListMarker) -> Bool { marker.ordered == first.ordered && marker.kind == first.kind }
        var items: [MDListItem] = []
        var index = start
        while index < lines.count, let marker = listMarker(lines[index]), compatible(marker) {
            var itemLines = [MDLine(start: marker.contentStart, end: lines[index].end)]
            index += 1
            while index < lines.count {
                let line = lines[index]
                if isBlank(line) {
                    var next = index
                    while next < lines.count && isBlank(lines[next]) { next += 1 }
                    if next < lines.count && indent(lines[next]).columns >= marker.contentColumn {
                        for blank in index..<next { itemLines.append(MDLine(start: lines[blank].end, end: lines[blank].end)) }
                        index = next; continue
                    }
                    break
                }
                let columns = indent(line).columns
                if columns >= marker.contentColumn {
                    itemLines.append(strip(line, columns: marker.contentColumn)); index += 1; continue
                }
                if columns > marker.indent, listMarker(line) != nil {
                    // Lenient nesting: a deeper marker short of the content column is still a child.
                    itemLines.append(strip(line, columns: columns)); index += 1; continue
                }
                if let last = itemLines.last, !isBlank(last), !startsBlock(line), table(lines, from: index) == nil {
                    itemLines.append(strip(line, columns: columns)); index += 1; continue
                }
                break
            }
            items.append(MDListItem(marker: marker.marker, ordered: marker.ordered, blocks: parse(itemLines, depth: depth + 1)))
            if index < lines.count && isBlank(lines[index]) {
                var next = index
                while next < lines.count && isBlank(lines[next]) { next += 1 }
                if next < lines.count, let following = listMarker(lines[next]), compatible(following) { index = next } else { break }
            }
        }
        return (.list(items), index)
    }
}

// MARK: - Inline parsing

struct InlineFormat {
    var bold = false
    var italic = false
    var strike = false
    func merged(_ other: InlineFormat) -> InlineFormat {
        InlineFormat(bold: bold || other.bold, italic: italic || other.italic, strike: strike || other.strike)
    }
}

enum InlinePiece {
    case text(Range<Int>, InlineFormat, URL?)
    case code(Range<Int>, InlineFormat, URL?)
    case math(whole: Range<Int>, content: Range<Int>, display: Bool, InlineFormat, URL?)

    func with(_ format: InlineFormat, url: URL?) -> InlinePiece {
        switch self {
        case let .text(range, own, link): return .text(range, own.merged(format), link ?? url)
        case let .code(range, own, link): return .code(range, own.merged(format), link ?? url)
        case let .math(whole, content, display, own, link): return .math(whole: whole, content: content, display: display, own.merged(format), link ?? url)
        }
    }
}

final class InlineParser {
    private let c: [UInt16]
    private let low: Int, high: Int
    private let allowLinks: Bool
    private var nodes: [Node] = []
    private var tickRuns: [Int: [Int]] = [:]
    private var tickCursor: [Int: Int] = [:]

    private enum Kind { case text, delimiter, code, math, link }
    private struct Node {
        var kind: Kind
        var start: Int
        var end: Int
        var content: Range<Int> = 0..<0
        var display = false
        var char: UInt16 = 0
        var canOpen = false
        var canClose = false
        var count = 0
        var front = 0
        var back = 0
        var url: URL?
        var children: [InlinePiece] = []
        var remaining: Int { count - front - back }
    }

    init(_ chars: [UInt16], range: Range<Int>, allowLinks: Bool = true) {
        c = chars; low = range.lowerBound; high = range.upperBound; self.allowLinks = allowLinks
    }

    func parse() -> [InlinePiece] {
        indexBacktickRuns()
        scan()
        let count = nodes.count
        var bold = [Int](repeating: 0, count: count + 1)
        var italic = bold, strike = bold
        processEmphasis(bold: &bold, italic: &italic, strike: &strike)
        var pieces: [InlinePiece] = []
        var b = 0, i = 0, s = 0
        for index in 0..<count {
            b += bold[index]; i += italic[index]; s += strike[index]
            let format = InlineFormat(bold: b > 0, italic: i > 0, strike: s > 0)
            let node = nodes[index]
            switch node.kind {
            case .text: if node.start < node.end { pieces.append(.text(node.start..<node.end, format, nil)) }
            case .delimiter:
                let range = (node.start + node.front)..<(node.end - node.back)
                if !range.isEmpty { pieces.append(.text(range, format, nil)) }
            case .code: pieces.append(.code(node.content, format, nil))
            case .math: pieces.append(.math(whole: node.start..<node.end, content: node.content, display: node.display, format, nil))
            case .link: pieces += node.children.map { $0.with(format, url: node.url) }
            }
        }
        return pieces
    }

    private func at(_ index: Int) -> UInt16? { index >= low && index < high ? c[index] : nil }

    private func indexBacktickRuns() {
        var index = low
        while index < high {
            if c[index] == MD.backtick {
                let start = index
                while index < high && c[index] == MD.backtick { index += 1 }
                tickRuns[index - start, default: []].append(start)
            } else { index += 1 }
        }
    }

    private func backtickCloser(from position: Int, length: Int) -> Int? {
        guard let runs = tickRuns[length] else { return nil }
        var cursor = tickCursor[length] ?? 0
        while cursor < runs.count && runs[cursor] < position { cursor += 1 }
        tickCursor[length] = cursor
        return cursor < runs.count ? runs[cursor] : nil
    }

    private func scan() {
        var index = low, textStart = low
        func flush(_ end: Int) {
            if textStart < end { nodes.append(Node(kind: .text, start: textStart, end: end)) }
        }
        while index < high {
            let char = c[index]
            switch char {
            case MD.backslash:
                if let next = at(index + 1) {
                    if next == MD.openParen || next == MD.openBracket,
                       let close = mathCloser(from: index + 2, closer: next == MD.openParen ? MD.closeParen : MD.closeBracket) {
                        flush(index)
                        nodes.append(Node(kind: .math, start: index, end: close + 2, content: (index + 2)..<close,
                                          display: next == MD.openBracket))
                        index = close + 2; textStart = index; continue
                    }
                    if MD.isASCIIPunctuation(next) {
                        flush(index)
                        nodes.append(Node(kind: .text, start: index + 1, end: index + 2))
                        index += 2; textStart = index; continue
                    }
                    if next == MD.newline { flush(index); index += 1; textStart = index; continue }
                }
                index += 1
            case MD.backtick:
                var end = index
                while end < high && c[end] == MD.backtick { end += 1 }
                let length = end - index
                if let closer = backtickCloser(from: end, length: length) {
                    flush(index)
                    var contentStart = end, contentEnd = closer
                    let allSpace = (contentStart..<contentEnd).allSatisfy { c[$0] == MD.space || c[$0] == MD.newline }
                    if contentEnd - contentStart >= 2, !allSpace,
                       c[contentStart] == MD.space || c[contentStart] == MD.newline,
                       c[contentEnd - 1] == MD.space || c[contentEnd - 1] == MD.newline {
                        contentStart += 1; contentEnd -= 1
                    }
                    nodes.append(Node(kind: .code, start: index, end: closer + length, content: contentStart..<contentEnd))
                    index = closer + length; textStart = index
                } else { index = end }
            case MD.dollar:
                if let math = matchDollar(index) {
                    flush(index)
                    nodes.append(Node(kind: .math, start: index, end: math.end, content: math.content, display: math.display))
                    index = math.end; textStart = index
                } else {
                    index += at(index + 1) == MD.dollar ? 2 : 1
                }
            case MD.star, MD.underscore, MD.tilde:
                var end = index
                while end < high && c[end] == char { end += 1 }
                if char == MD.tilde && end - index != 2 { index = end; continue }
                flush(index)
                let previous = at(index - 1), next = at(end)
                let left = !MD.isWhitespace(next) && (!MD.isPunctuation(next) || MD.isWhitespace(previous) || MD.isPunctuation(previous))
                let right = !MD.isWhitespace(previous) && (!MD.isPunctuation(previous) || MD.isWhitespace(next) || MD.isPunctuation(next))
                var node = Node(kind: .delimiter, start: index, end: end)
                node.char = char; node.count = end - index
                if char == MD.underscore {
                    node.canOpen = left && (!right || MD.isPunctuation(previous))
                    node.canClose = right && (!left || MD.isPunctuation(next))
                } else { node.canOpen = left; node.canClose = right }
                nodes.append(node)
                index = end; textStart = index
            case MD.bang where allowLinks && at(index + 1) == MD.openBracket:
                // Images are never loaded; the whole construct stays literal text.
                if let link = matchInlineLink(index + 1) {
                    flush(index)
                    nodes.append(Node(kind: .text, start: index, end: link.end))
                    index = link.end; textStart = index
                } else { index += 1 }
            case MD.openBracket where allowLinks:
                if let link = matchInlineLink(index) {
                    flush(index)
                    let label = c[link.label]
                    if !AnswerRendering.isCitationLabel(label),
                       let url = AnswerRendering.safeLinkURL(link.destination),
                       label.contains(where: { !MD.isWhitespace($0) }) {
                        var node = Node(kind: .link, start: index, end: link.end)
                        node.url = url
                        node.children = InlineParser(c, range: link.label, allowLinks: false).parse()
                        nodes.append(node)
                    } else {
                        nodes.append(Node(kind: .text, start: index, end: link.end))
                    }
                    index = link.end; textStart = index
                } else { index += 1 }
            case MD.less where allowLinks:
                if let link = matchAutolink(index) {
                    flush(index)
                    var node = Node(kind: .link, start: index, end: link.end)
                    node.url = link.url
                    node.children = [.text((index + 1)..<(link.end - 1), InlineFormat(), nil)]
                    nodes.append(node)
                    index = link.end; textStart = index
                } else { index += 1 }
            default:
                index += 1
            }
        }
        flush(high)
    }

    private func processEmphasis(bold: inout [Int], italic: inout [Int], strike: inout [Int]) {
        var stack: [Int] = []
        var bottoms: [Int: Int] = [:]
        for closer in nodes.indices where nodes[closer].kind == .delimiter {
            if nodes[closer].canClose {
                let key = Int(nodes[closer].char) * 16 + (nodes[closer].canOpen ? 8 : 0) + nodes[closer].count % 3
                while nodes[closer].remaining > 0 {
                    let floor = min(bottoms[key] ?? 0, stack.count)
                    var found = -1
                    var position = stack.count - 1
                    while position >= floor {
                        let opener = nodes[stack[position]]
                        if opener.char == nodes[closer].char && opener.remaining > 0 {
                            if opener.char == MD.tilde {
                                if opener.remaining == 2 && nodes[closer].remaining == 2 { found = position; break }
                            } else {
                                let odd = (opener.canClose || nodes[closer].canOpen)
                                    && (opener.count + nodes[closer].count) % 3 == 0
                                    && !(opener.count % 3 == 0 && nodes[closer].count % 3 == 0)
                                if !odd { found = position; break }
                            }
                        }
                        position -= 1
                    }
                    if found < 0 { bottoms[key] = stack.count; break }
                    let opener = stack[found]
                    let used = nodes[opener].char == MD.tilde ? 2
                        : (nodes[opener].remaining >= 2 && nodes[closer].remaining >= 2 ? 2 : 1)
                    nodes[opener].back += used
                    nodes[closer].front += used
                    if nodes[opener].char == MD.tilde { strike[opener + 1] += 1; strike[closer] -= 1 }
                    else if used == 2 { bold[opener + 1] += 1; bold[closer] -= 1 }
                    else { italic[opener + 1] += 1; italic[closer] -= 1 }
                    stack.removeSubrange((found + 1)..<stack.count)
                    if nodes[opener].remaining == 0 { stack.remove(at: found) }
                    for (key, value) in bottoms where value > stack.count { bottoms[key] = stack.count }
                }
            }
            if nodes[closer].canOpen && nodes[closer].remaining > 0 { stack.append(closer) }
        }
    }

    /// Finds `\)` or `\]` closing a LaTeX-delimited math span.
    private func mathCloser(from start: Int, closer: UInt16) -> Int? {
        var index = start
        let limit = min(high, start + AnswerRendering.maximumDisplayMathUnits)
        while index + 1 < limit {
            if c[index] == MD.backslash {
                if c[index + 1] == closer { return index > start ? index : nil }
                index += 2; continue
            }
            index += 1
        }
        return nil
    }

    /// The dollar-math heuristic. See docs/ANSWER-PRESENTATION-DEFECTS.md (fix E).
    private func matchDollar(_ index: Int) -> (end: Int, content: Range<Int>, display: Bool)? {
        if at(index + 1) == MD.dollar {
            var position = index + 2
            let limit = min(high, index + 2 + AnswerRendering.maximumDisplayMathUnits)
            while position + 1 < limit {
                if c[position] == MD.backslash { position += 2; continue }
                if c[position] == MD.dollar {
                    guard c[position + 1] == MD.dollar else { return nil }
                    let content = (index + 2)..<position
                    guard content.contains(where: { !MD.isWhitespace(c[$0]) }) else { return nil }
                    return (position + 2, content, true)
                }
                position += 1
            }
            return nil
        }
        guard let next = at(index + 1), !MD.isWhitespace(next) else { return nil }
        if let previous = at(index - 1), MD.isLetter(previous) || MD.isDigit(previous) { return nil }
        var position = index + 1
        let limit = min(high, index + 1 + AnswerRendering.maximumInlineMathUnits)
        while position < limit {
            let char = c[position]
            if char == MD.newline { return nil }
            if char == MD.backslash { position += 2; continue }
            if char == MD.dollar {
                guard !MD.isWhitespace(c[position - 1]), !(at(position + 1).map(MD.isDigit) ?? false),
                      at(position + 1) != MD.dollar else { return nil }
                let content = (index + 1)..<position
                guard !looksLikeProse(content), !looksLikeCurrency(content) else { return nil }
                return (position + 1, content, false)
            }
            position += 1
        }
        return nil
    }

    private static let textCommands: Set<String> = ["text", "textrm", "textbf", "textit", "mathrm", "mathbf", "mathit",
                                                     "operatorname", "mbox", "textsf", "texttt", "mathsf", "mathtt"]

    /// Two or more words of three or more ASCII letters, outside TeX command
    /// names and `\text{...}`-style arguments, indicate prose between two dollar amounts.
    private func looksLikeProse(_ range: Range<Int>) -> Bool {
        var words = 0
        var index = range.lowerBound
        while index < range.upperBound {
            if c[index] == MD.backslash {
                index += 1
                let nameStart = index
                while index < range.upperBound && MD.isLetter(c[index]) { index += 1 }
                if Self.textCommands.contains(MD.string(c[nameStart..<index])), index < range.upperBound, c[index] == 0x7B {
                    var depth = 0
                    while index < range.upperBound {
                        if c[index] == 0x7B { depth += 1 } else if c[index] == 0x7D { depth -= 1; if depth == 0 { index += 1; break } }
                        index += 1
                    }
                }
                continue
            }
            if MD.isLetter(c[index]) {
                let start = index
                while index < range.upperBound && MD.isLetter(c[index]) { index += 1 }
                if index - start >= 3 { words += 1; if words >= 2 { return true } }
                continue
            }
            index += 1
        }
        return false
    }

    /// Content that starts with a digit and contains whitespace must also
    /// contain an operator or TeX command; otherwise it reads as money.
    private func looksLikeCurrency(_ range: Range<Int>) -> Bool {
        guard MD.isDigit(c[range.lowerBound]), range.contains(where: { MD.isWhitespace(c[$0]) }) else { return false }
        let operators: Set<UInt16> = [MD.backslash, 0x5E, MD.underscore, 0x3D, MD.plus, MD.dash, MD.star, 0x2F,
                                      MD.less, MD.greater, MD.openParen, MD.closeParen, 0x00D7, 0x00B7, 0x2212]
        return !range.contains(where: { operators.contains(c[$0]) })
    }

    private func matchInlineLink(_ index: Int) -> (end: Int, label: Range<Int>, destination: String)? {
        var position = index + 1, depth = 1
        let limit = min(high, index + 1 + AnswerRendering.maximumLinkLabelUnits)
        while position < limit {
            let char = c[position]
            if char == MD.backslash { position += 2; continue }
            if char == MD.openBracket { depth += 1 }
            else if char == MD.closeBracket { depth -= 1; if depth == 0 { break } }
            position += 1
        }
        guard position < limit, depth == 0, at(position + 1) == MD.openParen else { return nil }
        let label = (index + 1)..<position
        var cursor = position + 2
        while let char = at(cursor), MD.isSpaceOrTab(char) || char == MD.newline { cursor += 1 }
        let destination: Range<Int>
        if at(cursor) == MD.less {
            let start = cursor + 1
            var end = start
            while let char = at(end), char != MD.greater, char != MD.newline, char != MD.less { end += 1 }
            guard at(end) == MD.greater else { return nil }
            destination = start..<end; cursor = end + 1
        } else {
            let start = cursor
            var parens = 0
            while let char = at(cursor), cursor - start < AnswerRendering.maximumLinkDestinationUnits {
                if MD.isWhitespace(char) || char < 0x20 { break }
                if char == MD.backslash, at(cursor + 1) != nil { cursor += 2; continue }
                if char == MD.openParen { parens += 1 }
                if char == MD.closeParen { if parens == 0 { break }; parens -= 1 }
                cursor += 1
            }
            destination = start..<cursor
        }
        while let char = at(cursor), MD.isSpaceOrTab(char) || char == MD.newline { cursor += 1 }
        if let quote = at(cursor), quote == 0x22 || quote == 0x27 || quote == MD.openParen {
            let close = quote == MD.openParen ? MD.closeParen : quote
            cursor += 1
            while let char = at(cursor), char != close {
                if char == MD.backslash { cursor += 1 }
                cursor += 1
            }
            guard at(cursor) == close else { return nil }
            cursor += 1
            while let char = at(cursor), MD.isSpaceOrTab(char) || char == MD.newline { cursor += 1 }
        }
        guard at(cursor) == MD.closeParen else { return nil }
        return (cursor + 1, label, MD.string(c[destination]))
    }

    private func matchAutolink(_ index: Int) -> (end: Int, url: URL)? {
        var position = index + 1
        let limit = min(high, index + 1 + AnswerRendering.maximumLinkDestinationUnits)
        while position < limit, c[position] != MD.greater {
            if MD.isWhitespace(c[position]) || c[position] == MD.less { return nil }
            position += 1
        }
        guard position < limit, position > index + 1,
              let url = AnswerRendering.safeLinkURL(MD.string(c[(index + 1)..<position])) else { return nil }
        return (position + 1, url)
    }
}

// MARK: - Attributed output

/// AppKit text blocks without a width shrink to their content. These fill the
/// width available at layout time, so window resizing reflows them.
private func fillAvailableWidth(_ block: NSTextBlock, _ rect: NSRect) {
    let extras = [NSTextBlock.Layer.margin, .border, .padding].reduce(CGFloat(0)) {
        $0 + block.width(for: $1, edge: .minX) + block.width(for: $1, edge: .maxX)
    }
    let content = max(24, rect.width - extras)
    if abs(block.value(for: .width) - content) > 0.5 || block.valueType(for: .width) != .absoluteValueType {
        block.setValue(content, type: .absoluteValueType, for: .width)
    }
}

final class FullWidthTextBlock: NSTextBlock {
    override func rectForLayout(at startingPoint: NSPoint, in rect: NSRect, textContainer: NSTextContainer,
                                characterRange: NSRange) -> NSRect {
        fillAvailableWidth(self, rect)
        return super.rectForLayout(at: startingPoint, in: rect, textContainer: textContainer, characterRange: characterRange)
    }
}

final class FullWidthTextTable: NSTextTable {
    override func rect(for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
                       textContainer: NSTextContainer, characterRange: NSRange) -> NSRect {
        fillAvailableWidth(self, rect)
        return super.rect(for: block, layoutAt: startingPoint, in: rect, textContainer: textContainer, characterRange: characterRange)
    }

    override func rectForLayout(at startingPoint: NSPoint, in rect: NSRect, textContainer: NSTextContainer,
                                characterRange: NSRange) -> NSRect {
        fillAvailableWidth(self, rect)
        return super.rectForLayout(at: startingPoint, in: rect, textContainer: textContainer, characterRange: characterRange)
    }
}

final class MarkdownAttributedRenderer {
    struct Context {
        var indent: CGFloat = 0
        var blocks: [NSTextBlock] = []
        var color: NSColor = .textColor
        var listDepth = 0
    }

    private let u: [UInt16]
    private let parser: MarkdownBlockParser
    let out = NSMutableAttributedString()
    private var prefix: (text: NSAttributedString, indent: CGFloat)?
    private var fonts: [String: NSFont] = [:]
    private let size = AnswerRendering.bodySize
    static let codeBackground = NSColor.quaternaryLabelColor

    init(_ units: [UInt16], parser: MarkdownBlockParser) { u = units; self.parser = parser }

    func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        let key = "\(size)|\(bold)|\(italic)|\(mono)"
        if let cached = fonts[key] { return cached }
        var font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
            : (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        fonts[key] = font
        return font
    }

    func render(_ blocks: [MDBlock], _ context: Context) {
        for block in blocks {
            switch block {
            case let .paragraph(lines): paragraph(lines, context)
            case let .heading(level, content): heading(level, content, context)
            case let .code(lines): code(lines, context)
            case let .rule(line): rule(line, context)
            case let .quote(inner): quote(inner, context)
            case let .list(items): list(items, context)
            case let .table(rows, alignments): table(rows, alignments, context)
            case let .plain(lines): plain(lines, context)
            }
        }
    }

    private func style(_ context: Context, first: CGFloat? = nil, before: CGFloat = 0, after: CGFloat,
                       alignment: NSTextAlignment = .natural, blocks: [NSTextBlock]? = nil,
                       lineBreak: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = first ?? context.indent
        style.headIndent = context.indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: context.indent)]
        style.defaultTabInterval = 28
        style.paragraphSpacing = after
        style.paragraphSpacingBefore = before
        style.alignment = alignment
        style.textBlocks = blocks ?? context.blocks
        style.lineBreakMode = lineBreak
        return style
    }

    private func emit(_ content: NSAttributedString, style: NSParagraphStyle, terminatorFont: NSFont) {
        let start = out.length
        out.append(content)
        out.append(NSAttributedString(string: "\n", attributes: [.font: terminatorFont]))
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    private func spacing(_ context: Context) -> CGFloat { context.listDepth > 0 ? 3 : 8 }

    /// Emits content as one paragraph, consuming a pending list marker.
    private func emitParagraph(_ content: NSAttributedString, _ context: Context, before: CGFloat = 0,
                               alignment: NSTextAlignment = .natural, font: NSFont) {
        let paragraph = NSMutableAttributedString()
        var first: CGFloat?
        if let pending = prefix { paragraph.append(pending.text); first = pending.indent; prefix = nil }
        paragraph.append(content)
        emit(paragraph, style: style(context, first: first, before: before, after: spacing(context), alignment: alignment), terminatorFont: font)
    }

    private func emitPendingMarker(_ context: Context) {
        guard prefix != nil else { return }
        emitParagraph(NSAttributedString(), context, font: font(size: size, bold: false, italic: false, mono: false))
    }

    private func addVerbatimSpans(_ target: NSMutableAttributedString, at offset: Int, sources: ArraySlice<Int>) {
        var runStart = sources.startIndex
        var index = sources.startIndex
        while index < sources.endIndex {
            let next = index + 1
            if next == sources.endIndex || sources[next] != sources[index] + 1 {
                let length = next - runStart
                target.addAttribute(.borosSourceSpan,
                                    value: RenderedSourceSpan(location: sources[runStart], length: length, verbatim: true),
                                    range: NSRange(location: offset + (runStart - sources.startIndex), length: length))
                runStart = next
            }
            index = next
        }
    }

    private func verbatim(_ range: Range<Int>, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: MD.string(u[range]), attributes: attributes)
        if result.length > 0 {
            result.addAttribute(.borosSourceSpan, value: RenderedSourceSpan(location: range.lowerBound, length: range.count, verbatim: true),
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private func synthetic(_ text: String, source: Range<Int>, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if result.length > 0 {
            result.addAttribute(.borosSourceSpan, value: RenderedSourceSpan(location: source.lowerBound, length: source.count, verbatim: false),
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    /// Paragraph content with joined lines; line breaks are kept as line separators.
    private func inlineInput(_ lines: [MDLine]) -> (chars: [UInt16], sources: [Int]) {
        var chars: [UInt16] = [], sources: [Int] = []
        for (index, line) in lines.enumerated() {
            let start = parser.indent(line).first
            var end = line.end
            if index == lines.count - 1 { while end > start && MD.isSpaceOrTab(u[end - 1]) { end -= 1 } }
            if start < end {
                chars.append(contentsOf: u[start..<end])
                sources.append(contentsOf: start..<end)
            }
            if index < lines.count - 1 { chars.append(MD.newline); sources.append(line.end) }
        }
        return (chars, sources)
    }

    private func inline(_ chars: [UInt16], _ sources: [Int], size: CGFloat, bold: Bool,
                        _ context: Context) -> (NSAttributedString, Bool) {
        let pieces = InlineParser(chars, range: 0..<chars.count).parse()
        let result = NSMutableAttributedString()
        var onlyDisplayMath = !pieces.isEmpty
        for piece in pieces {
            switch piece {
            case let .text(range, format, url), let .code(range, format, url):
                var isCode = false
                if case .code = piece { isCode = true }
                if case .text = piece { onlyDisplayMath = onlyDisplayMath && chars[range].allSatisfy { MD.isWhitespace($0) } }
                else { onlyDisplayMath = false }
                guard !range.isEmpty else { continue }
                var units = Array(chars[range])
                for index in units.indices where units[index] == MD.newline { units[index] = isCode ? MD.space : MD.lineSeparator }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font(size: isCode ? size - 1 : size, bold: bold || format.bold, italic: format.italic, mono: isCode),
                    .foregroundColor: url != nil ? NSColor.linkColor : context.color
                ]
                if isCode { attributes[.backgroundColor] = Self.codeBackground }
                if format.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let url {
                    attributes[.borosLink] = url
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.toolTip] = url.absoluteString
                    attributes[.cursor] = NSCursor.pointingHand
                }
                let start = result.length
                result.append(NSAttributedString(string: MD.string(units[...]), attributes: attributes))
                addVerbatimSpans(result, at: start, sources: sources[range])
            case let .math(whole, content, display, format, url):
                if !display { onlyDisplayMath = false }
                let math = NSMutableAttributedString(attributedString: MathText.render(MD.string(chars[content]), size: size,
                                                                                       color: url != nil ? .linkColor : context.color,
                                                                                       bold: bold || format.bold))
                if let url { math.addAttribute(.borosLink, value: url, range: NSRange(location: 0, length: math.length)) }
                let start = result.length
                result.append(math)
                let first = sources[whole.lowerBound], last = sources[whole.upperBound - 1]
                if math.length > 0 {
                    result.addAttribute(.borosSourceSpan, value: RenderedSourceSpan(location: first, length: last + 1 - first, verbatim: false),
                                        range: NSRange(location: start, length: math.length))
                }
            }
        }
        return (result, onlyDisplayMath)
    }

    private func paragraph(_ lines: [MDLine], _ context: Context) {
        let input = inlineInput(lines)
        let bodyFont = font(size: size, bold: false, italic: false, mono: false)
        let (content, displayMath) = inline(input.chars, input.sources, size: size, bold: false, context)
        emitParagraph(content, context, alignment: displayMath && prefix == nil ? .center : .natural, font: bodyFont)
    }

    private func heading(_ level: Int, _ range: Range<Int>, _ context: Context) {
        let headingSize: CGFloat = level == 1 ? 20 : level == 2 ? 17 : level == 3 ? 15 : size
        let (content, _) = inline(Array(u[range]), Array(range), size: headingSize, bold: true, context)
        emitParagraph(content, context, before: out.length > 0 ? 6 : 0, font: font(size: headingSize, bold: true, italic: false, mono: false))
    }

    private func code(_ lines: [MDLine], _ context: Context) {
        emitPendingMarker(context)
        let block = FullWidthTextBlock()
        block.backgroundColor = Self.codeBackground
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        var inner = context
        inner.indent = 0
        inner.blocks = context.blocks + [block]
        let mono = font(size: size - 1, bold: false, italic: false, mono: true)
        let attributes: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.textColor]
        let paragraphStyle = style(inner, after: 0, lineBreak: .byCharWrapping)
        if lines.isEmpty { emit(NSAttributedString(), style: paragraphStyle, terminatorFont: mono) }
        for line in lines { emit(verbatim(line.start..<line.end, attributes: attributes), style: paragraphStyle, terminatorFont: mono) }
    }

    private func rule(_ line: MDLine, _ context: Context) {
        emitPendingMarker(context)
        let block = FullWidthTextBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(.separatorColor, for: .maxY)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
        var inner = context
        inner.indent = 0
        inner.blocks = context.blocks + [block]
        let small = NSFont.systemFont(ofSize: 2)
        emit(synthetic(" ", source: line.start..<line.end, attributes: [.font: small]), style: style(inner, after: 0), terminatorFont: small)
    }

    private func quote(_ inner: [MDBlock], _ context: Context) {
        emitPendingMarker(context)
        let block = FullWidthTextBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(.tertiaryLabelColor, for: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        var quoted = context
        quoted.indent = 0
        quoted.blocks = context.blocks + [block]
        quoted.color = .secondaryLabelColor
        if inner.isEmpty {
            emit(NSAttributedString(), style: style(quoted, after: 0), terminatorFont: font(size: size, bold: false, italic: false, mono: false))
        }
        render(inner, quoted)
    }

    private func list(_ items: [MDListItem], _ context: Context) {
        emitPendingMarker(context)
        let bodyFont = font(size: size, bold: false, italic: false, mono: false)
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let markers = items.map { item in item.ordered ? MD.string(u[item.marker]) : bullets[context.listDepth % bullets.count] }
        let widest = markers.map { ($0 as NSString).size(withAttributes: [.font: bodyFont]).width }.max() ?? 0
        let width = max(18, ceil(widest) + 8)
        var itemContext = context
        itemContext.indent = context.indent + width
        itemContext.listDepth += 1
        for (item, marker) in zip(items, markers) {
            let attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: item.ordered ? context.color : NSColor.secondaryLabelColor]
            let text = NSMutableAttributedString(attributedString: item.ordered ? verbatim(item.marker, attributes: attributes)
                                                 : synthetic(marker, source: item.marker, attributes: attributes))
            text.append(NSAttributedString(string: "\t", attributes: attributes))
            prefix = (text, context.indent)
            render(item.blocks, itemContext)
            emitPendingMarker(itemContext)
        }
    }

    private func table(_ rows: [[Range<Int>]], _ alignments: [NSTextAlignment], _ context: Context) {
        emitPendingMarker(context)
        let table = FullWidthTextTable()
        table.numberOfColumns = alignments.count
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX)
        table.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        let bodyFont = font(size: size, bold: false, italic: false, mono: false)
        for (rowIndex, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
                if rowIndex == 0 { block.backgroundColor = Self.codeBackground }
                var cellContext = context
                cellContext.indent = 0
                cellContext.blocks = context.blocks + [block]
                let (content, _) = inline(Array(u[cell]), Array(cell), size: size, bold: rowIndex == 0, cellContext)
                emit(content, style: style(cellContext, after: 0, alignment: alignments[column]), terminatorFont: bodyFont)
            }
        }
    }

    private func plain(_ lines: [MDLine], _ context: Context) {
        let bodyFont = font(size: size, bold: false, italic: false, mono: false)
        let content = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            content.append(verbatim(line.start..<line.end, attributes: [.font: bodyFont, .foregroundColor: context.color]))
            if index < lines.count - 1 { content.append(NSAttributedString(string: "\u{2028}", attributes: [.font: bodyFont])) }
        }
        emitParagraph(content, context, font: bodyFont)
    }
}

// MARK: - Math

/// Readable plain-text rendering of common TeX math. This is not TeX layout:
/// commands map to Unicode symbols, fractions become `a/b`, and scripts use a
/// smaller font with a baseline offset. Unknown commands stay literal.
enum MathText {
    private static let symbols: [String: String] = [
        "times": "\u{00D7}", "cdot": "\u{00B7}", "div": "\u{00F7}", "pm": "\u{00B1}", "mp": "\u{2213}",
        "le": "\u{2264}", "leq": "\u{2264}", "ge": "\u{2265}", "geq": "\u{2265}", "ne": "\u{2260}", "neq": "\u{2260}",
        "approx": "\u{2248}", "equiv": "\u{2261}", "sim": "\u{223C}", "simeq": "\u{2243}", "cong": "\u{2245}",
        "propto": "\u{221D}", "infty": "\u{221E}", "to": "\u{2192}", "rightarrow": "\u{2192}", "leftarrow": "\u{2190}",
        "gets": "\u{2190}", "Rightarrow": "\u{21D2}", "Leftarrow": "\u{21D0}", "implies": "\u{21D2}", "iff": "\u{21D4}",
        "Leftrightarrow": "\u{21D4}", "leftrightarrow": "\u{2194}", "mapsto": "\u{21A6}", "sum": "\u{2211}",
        "prod": "\u{220F}", "int": "\u{222B}", "oint": "\u{222E}", "partial": "\u{2202}", "nabla": "\u{2207}",
        "in": "\u{2208}", "notin": "\u{2209}", "ni": "\u{220B}", "subset": "\u{2282}", "subseteq": "\u{2286}",
        "supset": "\u{2283}", "supseteq": "\u{2287}", "cup": "\u{222A}", "cap": "\u{2229}", "emptyset": "\u{2205}",
        "varnothing": "\u{2205}", "forall": "\u{2200}", "exists": "\u{2203}", "neg": "\u{00AC}", "lnot": "\u{00AC}",
        "land": "\u{2227}", "wedge": "\u{2227}", "lor": "\u{2228}", "vee": "\u{2228}", "oplus": "\u{2295}",
        "otimes": "\u{2297}", "circ": "\u{2218}", "bullet": "\u{2022}", "star": "\u{22C6}", "ast": "\u{2217}",
        "ldots": "\u{2026}", "dots": "\u{2026}", "cdots": "\u{22EF}", "vdots": "\u{22EE}", "ddots": "\u{22F1}",
        "prime": "\u{2032}", "angle": "\u{2220}", "degree": "\u{00B0}", "perp": "\u{22A5}", "parallel": "\u{2225}",
        "mid": "\u{2223}", "langle": "\u{27E8}", "rangle": "\u{27E9}", "lceil": "\u{2308}", "rceil": "\u{2309}",
        "lfloor": "\u{230A}", "rfloor": "\u{230B}", "lvert": "|", "rvert": "|", "vert": "|", "Vert": "\u{2016}",
        "ll": "\u{226A}", "gg": "\u{226B}", "hbar": "\u{210F}", "ell": "\u{2113}", "Re": "\u{211C}", "Im": "\u{2111}",
        "aleph": "\u{2135}", "therefore": "\u{2234}", "because": "\u{2235}", "checkmark": "\u{2713}",
        "alpha": "\u{03B1}", "beta": "\u{03B2}", "gamma": "\u{03B3}", "delta": "\u{03B4}", "epsilon": "\u{03F5}",
        "varepsilon": "\u{03B5}", "zeta": "\u{03B6}", "eta": "\u{03B7}", "theta": "\u{03B8}", "vartheta": "\u{03D1}",
        "iota": "\u{03B9}", "kappa": "\u{03BA}", "lambda": "\u{03BB}", "mu": "\u{03BC}", "nu": "\u{03BD}",
        "xi": "\u{03BE}", "pi": "\u{03C0}", "varpi": "\u{03D6}", "rho": "\u{03C1}", "varrho": "\u{03F1}",
        "sigma": "\u{03C3}", "varsigma": "\u{03C2}", "tau": "\u{03C4}", "upsilon": "\u{03C5}", "phi": "\u{03D5}",
        "varphi": "\u{03C6}", "chi": "\u{03C7}", "psi": "\u{03C8}", "omega": "\u{03C9}", "Gamma": "\u{0393}",
        "Delta": "\u{0394}", "Theta": "\u{0398}", "Lambda": "\u{039B}", "Xi": "\u{039E}", "Pi": "\u{03A0}",
        "Sigma": "\u{03A3}", "Upsilon": "\u{03A5}", "Phi": "\u{03A6}", "Psi": "\u{03A8}", "Omega": "\u{03A9}",
        "log": "log", "ln": "ln", "exp": "exp", "sin": "sin", "cos": "cos", "tan": "tan", "lim": "lim",
        "max": "max", "min": "min", "det": "det", "gcd": "gcd", "mod": "mod", "bmod": "mod", "deg": "deg",
        "sup": "sup", "inf": "inf", "arg": "arg"
    ]
    private static let spacing: [String: String] = [",": " ", ":": " ", ";": " ", " ": " ", "!": "", "quad": "\u{2003}",
                                                     "qquad": "\u{2003}\u{2003}", "\\": " "]
    private static let ignored: Set<String> = ["left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl",
                                               "Bigr", "biggl", "biggr", "middle", "displaystyle", "textstyle", "limits", "nolimits"]
    private static let roman: Set<String> = ["text", "textrm", "textbf", "textit", "mathrm", "operatorname", "mbox",
                                             "textsf", "texttt", "mathsf", "mathtt"]
    private static let styled: Set<String> = ["mathbf", "mathit", "boldsymbol", "bm", "mathcal", "mathscr", "mathfrak"]
    private static let accents: [String: String] = ["bar": "\u{0304}", "overline": "\u{0305}", "hat": "\u{0302}",
                                                    "widehat": "\u{0302}", "vec": "\u{20D7}", "dot": "\u{0307}",
                                                    "ddot": "\u{0308}", "tilde": "\u{0303}", "widetilde": "\u{0303}"]
    private static let blackboard: [Character: String] = ["R": "\u{211D}", "N": "\u{2115}", "Z": "\u{2124}", "Q": "\u{211A}",
                                                           "C": "\u{2102}", "P": "\u{2119}", "E": "\u{1D53C}"]

    struct Segment {
        var text: String
        var italic: Bool
        var scale: CGFloat = 1
        var baseline: CGFloat = 0
    }

    static func render(_ source: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSAttributedString {
        var parser = Parser(Array(source))
        let segments = parser.sequence(stopAtBrace: false, depth: 0)
        let result = NSMutableAttributedString()
        let manager = NSFontManager.shared
        let base = NSFont(name: "Times New Roman", size: size + 1) ?? NSFont.systemFont(ofSize: size + 1)
        for segment in segments where !segment.text.isEmpty {
            var font = NSFont(descriptor: base.fontDescriptor, size: (size + 1) * segment.scale) ?? base
            if segment.italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if segment.baseline != 0 { attributes[.baselineOffset] = segment.baseline * size }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    static func plainText(_ source: String) -> String {
        var parser = Parser(Array(source))
        return parser.sequence(stopAtBrace: false, depth: 0).map(\.text).joined()
    }

    private struct Parser {
        let t: [Character]
        var i = 0
        init(_ characters: [Character]) { t = characters }

        mutating func sequence(stopAtBrace: Bool, depth: Int) -> [Segment] {
            var out: [Segment] = []
            while i < t.count {
                let char = t[i]
                if char == "}" && stopAtBrace { break }
                if char == "^" || char == "_" {
                    i += 1
                    let argument = self.argument(depth: depth + 1)
                    out += argument.map { segment in
                        var shifted = segment
                        shifted.scale *= 0.75
                        shifted.baseline = segment.baseline * 0.75 + (char == "^" ? 0.38 : -0.18)
                        return shifted
                    }
                    continue
                }
                if char.isWhitespace {
                    while i < t.count && t[i].isWhitespace { i += 1 }
                    if let last = out.last, !last.text.hasSuffix(" ") { out.append(Segment(text: " ", italic: false)) }
                    continue
                }
                out += atom(depth: depth)
            }
            return out
        }

        mutating func argument(depth: Int) -> [Segment] {
            while i < t.count && t[i].isWhitespace { i += 1 }
            guard i < t.count else { return [] }
            if t[i] == "}" { return [] }
            return atom(depth: depth)
        }

        mutating func atom(depth: Int) -> [Segment] {
            guard i < t.count else { return [] }
            if depth > 12 {
                let rest = String(t[i...]); i = t.count
                return [Segment(text: rest, italic: false)]
            }
            let char = t[i]
            if char == "{" {
                i += 1
                let inner = sequence(stopAtBrace: true, depth: depth + 1)
                if i < t.count && t[i] == "}" { i += 1 }
                return inner
            }
            if char == "\\" { return command(depth: depth) }
            i += 1
            if char.isASCII && char.isLetter { return [Segment(text: String(char), italic: true)] }
            if char == "'" { return [Segment(text: "\u{2032}", italic: false)] }
            if char == "*" { return [Segment(text: "\u{2217}", italic: false)] }
            if char == "-" { return [Segment(text: "\u{2212}", italic: false)] }
            return [Segment(text: String(char), italic: false)]
        }

        static func text(_ segments: [Segment]) -> String { segments.map(\.text).joined() }

        func wrapped(_ segments: [Segment]) -> [Segment] {
            let text = Self.text(segments).trimmingCharacters(in: .whitespaces)
            if text.count <= 1 || text.allSatisfy({ $0.isNumber || $0 == "." }) || text.allSatisfy({ $0.isLetter }) { return segments }
            return [Segment(text: "(", italic: false)] + segments + [Segment(text: ")", italic: false)]
        }

        mutating func command(depth: Int) -> [Segment] {
            i += 1
            guard i < t.count else { return [Segment(text: "\\", italic: false)] }
            var name: String
            if t[i].isASCII && t[i].isLetter {
                let start = i
                while i < t.count && t[i].isASCII && t[i].isLetter { i += 1 }
                name = String(t[start..<i])
            } else { name = String(t[i]); i += 1 }
            if let space = MathText.spacing[name] { return space.isEmpty ? [] : [Segment(text: space, italic: false)] }
            if ["{", "}", "$", "%", "&", "#", "_", "|"].contains(name) {
                return [Segment(text: name == "|" ? "\u{2016}" : name, italic: false)]
            }
            if MathText.ignored.contains(name) {
                while i < t.count && t[i].isWhitespace { i += 1 }
                if i < t.count && t[i] == "." { i += 1 }
                return []
            }
            if let symbol = MathText.symbols[name] { return [Segment(text: symbol, italic: false)] }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = argument(depth: depth + 1), denominator = argument(depth: depth + 1)
                return wrapped(numerator) + [Segment(text: "/", italic: false)] + wrapped(denominator)
            case "sqrt":
                var index: [Segment] = []
                while i < t.count && t[i].isWhitespace { i += 1 }
                if i < t.count && t[i] == "[" {
                    i += 1
                    let start = i
                    while i < t.count && t[i] != "]" { i += 1 }
                    var inner = Parser(Array(t[start..<i]))
                    index = inner.sequence(stopAtBrace: false, depth: depth + 1).map { var s = $0; s.scale *= 0.75; s.baseline += 0.38; return s }
                    if i < t.count { i += 1 }
                }
                let radicand = argument(depth: depth + 1)
                return index + [Segment(text: "\u{221A}", italic: false)] + wrapped(radicand)
            case "binom", "dbinom", "tbinom":
                let n = argument(depth: depth + 1), k = argument(depth: depth + 1)
                return [Segment(text: "C(", italic: false)] + n + [Segment(text: ", ", italic: false)] + k + [Segment(text: ")", italic: false)]
            case "mathbb":
                return argument(depth: depth + 1).map { segment in
                    var mapped = segment
                    mapped.text = String(segment.text.flatMap { MathText.blackboard[$0] ?? String($0) })
                    mapped.italic = false
                    return mapped
                }
            default: break
            }
            if MathText.roman.contains(name) {
                return argument(depth: depth + 1).map { var s = $0; s.italic = false; return s }
            }
            if MathText.styled.contains(name) { return argument(depth: depth + 1) }
            if let accent = MathText.accents[name] {
                let base = argument(depth: depth + 1)
                guard Self.text(base).count == 1, var first = base.first else { return base }
                first.text += accent
                return [first]
            }
            return [Segment(text: "\\" + name, italic: false)]
        }
    }
}

// MARK: - Transcript view

/// The read-only conversation view. Copy and drag write the original stored
/// text, links open only on an explicit click, and the context menu offers
/// "Copy Original Message" and "Show Original Text".
final class TranscriptTextView: NSTextView {
    var originalTextShown: () -> Bool = { false }
    var toggleOriginalText: () -> Void = {}
    var openLink: (URL) -> Void = { url in
        if AnswerRendering.safeLinkURL(url.absoluteString) != nil { NSWorkspace.shared.open(url) }
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    func originalSelectionText() -> String {
        guard let storage = textStorage else { return "" }
        return selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            .map { AnswerRendering.originalText(in: $0, of: storage) }.joined(separator: "\n")
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        return pboard.setString(originalSelectionText(), forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        pboard.declareTypes([.string], owner: nil)
        return writeSelection(to: pboard, type: .string)
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        _ = writeSelection(to: NSPasteboard.general, types: [.string])
    }

    func characterIndex(atViewPoint point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(containerPoint) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    private func link(at point: NSPoint) -> URL? {
        guard let index = characterIndex(atViewPoint: point) else { return nil }
        return textStorage?.attribute(.borosLink, at: index, effectiveRange: nil) as? URL
    }

    override func mouseDown(with event: NSEvent) {
        let target = event.clickCount == 1 && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            ? link(at: convert(event.locationInWindow, from: nil)) : nil
        super.mouseDown(with: event)
        guard let target, selectedRange().length == 0 else { return }
        if let release = window?.currentEvent, release.type == .leftMouseUp,
           link(at: convert(release.locationInWindow, from: nil)) != target { return }
        if let safe = AnswerRendering.safeLinkURL(target.absoluteString) { openLink(safe) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        if let index = characterIndex(atViewPoint: convert(event.locationInWindow, from: nil)),
           let storage = textStorage, let source = AnswerRendering.messageSource(at: index, in: storage) {
            let copy = NSMenuItem(title: "Copy Original Message", action: #selector(copyOriginalMessage(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = source
            menu.addItem(copy)
        }
        let toggle = NSMenuItem(title: "Show Original Text", action: #selector(toggleOriginalFromMenu(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = originalTextShown() ? .on : .off
        menu.addItem(toggle)
        return menu
    }

    @objc func copyOriginalMessage(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? TranscriptMessageSource else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(source.text, forType: .string)
    }

    @objc private func toggleOriginalFromMenu(_ sender: Any?) { toggleOriginalText() }
}
