import Foundation

/// Bounded literal terms for ordinary source retrieval. Complete quoted spans
/// receive priority, distributed across anchors before prompt prose fills gaps.
/// Quotes remain data: this never emits user-controlled FTS operators.
enum HistoricalQueryFormulation {
    static let version = "quoted-anchor-round-robin-v1"
    struct Result {
        let query: String?
        let selectedTokenIndices: [Int]
        let quotedAnchorCount: Int
    }
    private struct Token {
        let term: String
        let index: Int
        let start: Int
        let end: Int
    }

    enum InputError: Error { case invalidRange }
    /// A host-selected span must remain exact accepted text. Invalid byte or
    /// scalar boundaries fail rather than replacing the accepted query.
    static func input(_ prompt: String, utf8Range: Range<Int>?) throws -> String {
        guard let range = utf8Range else { return prompt }
        let bytes = Data(prompt.utf8)
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty,
              String(data: bytes.prefix(range.lowerBound), encoding: .utf8) != nil,
              let text = String(data: bytes.subdata(in: range), encoding: .utf8),
              String(data: bytes.suffix(from: range.upperBound), encoding: .utf8) != nil else {
            throw InputError.invalidRange
        }
        return text
    }

    static func formulate(_ prompt: String) -> Result {
        // Offsets are Unicode-scalar ordinals, independent of grapheme or UTF-16
        // normalization. CharacterSet matches the previous component tokenizer.
        var tokens: [Token] = [], spans: [Range<Int>] = []
        var token = "", tokenStart = 0, position = 0
        var opening: (start: Int, close: Unicode.Scalar, bytes: Int)?
        var escaped = false
        func finishToken(at end: Int) {
            guard !token.isEmpty else { return }
            tokens.append(Token(term: token.lowercased(), index: tokens.count, start: tokenStart, end: end))
            token = ""
        }
        for scalar in prompt.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if token.isEmpty { tokenStart = position }
                token.unicodeScalars.append(scalar)
            } else { finishToken(at: position) }
            if var active = opening {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == active.close {
                    if active.bytes <= 16_384, spans.count < 8 { spans.append((active.start + 1)..<position) }
                    opening = nil
                }
                if opening != nil {
                    active.bytes += scalar.utf8.count
                    opening = active
                }
            } else if spans.count < 8 {
                let closing: Unicode.Scalar?
                switch scalar {
                case "\"": closing = "\""
                case "“": closing = "”"
                case "`": closing = "`"
                default: closing = nil
                }
                if let closing { opening = (position, closing, 0); escaped = false }
            }
            position += 1
        }
        finishToken(at: position)
        var selected: [String] = [], indices: [Int] = [], seen: Set<String> = [], bytes = 0
        func append(_ candidate: Token) -> Bool {
            let term = candidate.term
            guard selected.count < 8, !stopwords.contains(term), !seen.contains(term), term.utf8.count <= 128 else { return false }
            let nextBytes = bytes + term.utf8.count + (selected.isEmpty ? 0 : 1)
            guard nextBytes <= 1024 else { return false }
            selected.append(term); indices.append(candidate.index); seen.insert(term); bytes = nextBytes
            return true
        }
        let anchors = spans.map { span in tokens.filter { $0.start >= span.lowerBound && $0.end <= span.upperBound } }
        var cursors = Array(repeating: 0, count: anchors.count)
        while selected.count < 8 {
            var advanced = false
            for i in anchors.indices {
                while cursors[i] < anchors[i].count {
                    let candidate = anchors[i][cursors[i]]; cursors[i] += 1; advanced = true
                    if append(candidate) { break }
                }
                if selected.count == 8 { break }
            }
            if !advanced { break }
        }
        for candidate in tokens {
            if selected.count == 8 { break }
            _ = append(candidate)
        }
        return Result(query: selected.isEmpty ? nil : selected.joined(separator: " "),
            selectedTokenIndices: indices, quotedAnchorCount: anchors.filter { !$0.isEmpty }.count)
    }

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by", "can", "could",
        "did", "do", "does", "doing", "for", "from", "had", "has", "have", "having", "he", "her",
        "here", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just",
        "me", "more", "most", "my", "no", "not", "of", "on", "or", "our", "ours", "please",
        "s", "say", "she", "should", "so", "some", "t", "tell", "than", "that", "the", "their",
        "theirs", "them", "then", "there", "these", "they", "this", "those", "through", "to",
        "too", "us", "was", "we", "were", "what", "when", "where", "which", "who", "why",
        "will", "with", "would", "you", "your", "yours", "about"
    ]
}
