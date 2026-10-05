import Foundation

/// Ordinary Send uses bounded lexical formulation plus an optional local
/// semantic index. Every delivered excerpt is checked against original bytes.
enum ChatContextPreparation {
    static func prepare(
        store: MemoryStore,
        conversationID: String,
        projectID: String,
        prompt: String,
        system: String,
        excludingEventID: String,
        semanticIndex: SemanticIndex? = nil
    ) throws -> ContextSnapshot {
        let lexical = historicalQuery(prompt)
        guard let semanticIndex else {
            var snapshot = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                historicalQuery: lexical, historicalMatching: .anyTerm)
            snapshot.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: ["mode": "lexical", "semantic_available": false], options: [.sortedKeys])
            snapshot.retrievalNotice = "Archive recall used lexical search; semantic recall is unavailable."
            return snapshot
        }
        let recent = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
            prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
            maximumEvidenceBytes: 0)
        let report: SemanticSearchReport
        do {
            report = try semanticIndex.search(query: prompt, lexicalQuery: lexical ?? "", projectID: projectID,
                limit: 16, excludingEventIDs: Set(recent.recentSourceIDs + [excludingEventID]), includeLiteral: false)
        } catch {
            // A sidecar failure cannot erase original sources or invent a hit.
            // Raw lexical fallback is revalidated by the same assembler.
            var snapshot = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                historicalQuery: lexical, historicalMatching: .anyTerm)
            snapshot.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: ["mode": "lexical_fallback",
                "semantic_available": false, "failure": "semantic_search_failed"], options: [.sortedKeys])
            snapshot.retrievalNotice = "Semantic recall failed; archive recall used lexical search."
            return snapshot
        }
        var snapshot = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
            prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
            historicalHits: report.hits)
        snapshot.retrievalManifestID = report.manifestID
        snapshot.retrievalManifestJSON = try report.serializedManifest()
        let coverage = report.manifest.coverage
        var audit: [String: Any] = ["mode": "hybrid", "manifest_id": report.manifestID,
            "index_fingerprint": report.manifest.indexFingerprint, "encoder_fingerprint": report.manifest.encoderFingerprint,
            "ranking_fingerprint": report.manifest.rankingFingerprint, "configuration_fingerprint": report.manifest.configurationFingerprint,
            "query_configuration_fingerprint": report.manifest.queryConfigurationFingerprint,
            "query_sha256": report.manifest.queryDigest, "lexical_query_sha256": report.manifest.lexicalQueryDigest,
            "raw_snapshot_id": report.manifest.rawSnapshotID,
            "source_frontier": report.manifest.sourceFrontier, "published_chunk_frontier": report.manifest.publishedChunkFrontier,
            "query_disposition": report.manifest.queryDisposition, "literal_search": false,
            "coverage_complete": coverage.complete, "inspected_sources": coverage.inspectedSources,
            "complete_sources": coverage.completeSources, "pending_sources": coverage.pendingSources,
            "unsupported_sources": coverage.unsupportedSources, "failed_sources": coverage.failedSources,
            "holes_truncated": coverage.holesTruncated, "vector_candidates_inspected": report.manifest.vectorCandidatesInspected,
            "vector_continuation_available": report.manifest.vectorContinuation != nil]
        if let sequence = coverage.metadataContinuationSequence { audit["metadata_continuation_sequence"] = sequence }
        snapshot.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
        if report.manifest.queryDisposition != "supported" {
            snapshot.retrievalNotice = "This request used lexical archive recall; semantic recall does not support its text."
        } else if !coverage.complete || report.manifest.vectorContinuation != nil {
            snapshot.retrievalNotice = "Archive recall used a partial semantic index. Missing evidence may still be in the archive."
        }
        return snapshot
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
