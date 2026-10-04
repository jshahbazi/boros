import Foundation

/// The ordinary Send path uses bounded lexical recall from the current request.
/// This is deterministic local query selection, not semantic query planning.
enum ChatContextPreparation {
    static func prepare(
        store: MemoryStore,
        conversationID: String,
        projectID: String,
        prompt: String,
        system: String,
        excludingEventID: String
    ) throws -> ContextSnapshot {
        try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
            prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
            historicalQuery: historicalQuery(prompt), historicalMatching: .anyTerm)
    }

    /// Keep at most eight unique non-filler terms, within the store's query
    /// limits. Operators and punctuation remain data; no raw FTS is accepted.
    /// Oversized terms are skipped so a valid long draft remains sendable.
    private static func historicalQuery(_ prompt: String) -> String? {
        var selected: [String] = []
        var seen: Set<String> = []
        var bytes = 0
        for raw in prompt.components(separatedBy: CharacterSet.alphanumerics.inverted) where !raw.isEmpty {
            let term = raw.lowercased()
            guard !stopwords.contains(term), !seen.contains(term), term.utf8.count <= 128 else { continue }
            let nextBytes = bytes + term.utf8.count + (selected.isEmpty ? 0 : 1)
            guard nextBytes <= 1024 else { continue }
            selected.append(term)
            seen.insert(term)
            bytes = nextBytes
            if selected.count == 8 { break }
        }
        return selected.isEmpty ? nil : selected.joined(separator: " ")
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
