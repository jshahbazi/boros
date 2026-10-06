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
        semanticIndex: SemanticIndex? = nil,
        retrievalStrategy: ContextRetrievalStrategy = .hybrid,
        episodeLease: EpisodeLease? = nil
    ) throws -> ContextSnapshot {
        _ = try episodeLease?.checkActive(projectID: projectID)
        return try MeteredRetrieval.operation(lease: episodeLease) {
            if retrievalStrategy == .recentOnly {
                let recent = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                    prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                    maximumEvidenceBytes: 0, episodeLease: episodeLease, operationIsNested: true)
                return try recentOnlySnapshot(recent)
            }
            let lexical = historicalQuery(prompt)
            guard let semanticIndex else {
                var snapshot = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                    prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                    historicalQuery: lexical, historicalMatching: .anyTerm, expandFollowingAssistant: true, episodeLease: episodeLease, operationIsNested: true)
                try appendAudit(to: &snapshot, fields: ["mode": "lexical", "semantic_available": false])
                if snapshot.retrievalNotice == nil { snapshot.retrievalNotice = "Archive recall used lexical search; semantic recall is unavailable." }
                return snapshot
            }
            let recent = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                maximumEvidenceBytes: 0, episodeLease: episodeLease, operationIsNested: true)
            let report: SemanticSearchReport
            do {
                report = try semanticIndex.search(query: prompt, lexicalQuery: lexical ?? "", projectID: projectID,
                    limit: 16, excludingSourceIDs: ExactSourceIDs(recent.recentSourceIDs + [excludingEventID]), includeLiteral: false,
                    episodeLease: episodeLease, operationIsNested: true)
            } catch {
                if error is EpisodeBudgetError || error is MeteredRetrievalError || error is MemoryError || error is ContextError { throw error }
                if let semanticError = error as? SemanticError {
                    switch semanticError {
                    case .sourceMismatch, .publicationConflict: throw error
                    default: break
                    }
                }
                // A sidecar failure cannot erase original sources or invent a hit.
                // Raw lexical fallback is revalidated by the same assembler.
                var snapshot = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                    prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                    historicalQuery: lexical, historicalMatching: .anyTerm, expandFollowingAssistant: true, episodeLease: episodeLease, operationIsNested: true)
                try appendAudit(to: &snapshot, fields: ["mode": "lexical_fallback",
                    "semantic_available": false, "failure": "semantic_search_failed"])
                if snapshot.retrievalNotice == nil { snapshot.retrievalNotice = "Semantic recall failed; archive recall used lexical search." }
                return snapshot
            }
            try MeteredRetrieval.requireCompleteReadCoverage(lease: episodeLease,
                resourceLimited: report.manifest.meteredLexicalCoverage?.continuation != nil
                    || report.manifest.meteredLiteralCoverage?.incompleteReason == "raw_source_budget")
            let expanded = try MeteredExchangeExpansion.expand(store: store, projectID: projectID,
                primaryHits: report.hits, sourceFrontier: report.manifest.sourceFrontier,
                excludingSourceIDs: ExactSourceIDs(recent.recentSourceIDs + [excludingEventID]),
                episodeLease: episodeLease, operationIsNested: true)
            var snapshot = try ContextAssembler.prepare(store: store, conversationID: conversationID, projectID: projectID,
                prompt: prompt, system: system, budgetBytes: 65_536, excludingEventID: excludingEventID,
                historicalHits: expanded.hits, episodeLease: episodeLease, operationIsNested: true)
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
            if let lexicalCoverage = report.manifest.meteredLexicalCoverage {
                audit["raw_work_version"] = "raw_work_v1"
                audit["raw_work_charged"] = lexicalCoverage.rawWorkCharged
                audit["inspected_candidates"] = lexicalCoverage.inspectedCandidates
                audit["candidate_window_full"] = lexicalCoverage.candidateWindowFull
                audit["candidate_window_complete"] = lexicalCoverage.candidateWindowComplete
                audit["raw_continuation_available"] = lexicalCoverage.continuation != nil
            }
            audit["exchange_expansion"] = expanded.audit
            try appendAudit(to: &snapshot, fields: audit)
            if report.manifest.queryDisposition != "supported" {
                snapshot.retrievalNotice = "This request used lexical archive recall; semantic recall does not support its text."
            } else if !coverage.complete || report.manifest.vectorContinuation != nil || report.manifest.meteredLexicalCoverage?.candidateWindowComplete == false || report.manifest.meteredLexicalCoverage?.candidateWindowFull == true {
                snapshot.retrievalNotice = "Archive recall used a partial semantic index. Missing evidence may still be in the archive."
            }
            return snapshot
        }
    }

    /// Retrieve only after exact recent-component reduction. The caller owns
    /// adapter counts and keeps the same original lease across every stage.
    static func prepareEvidence(recent: ContextSnapshot, store: MemoryStore, conversationID: String,
        projectID: String, prompt: String, excludingEventID: String,
        semanticIndex: SemanticIndex? = nil, retrievalStrategy: ContextRetrievalStrategy = .hybrid,
        episodeLease: EpisodeLease? = nil, lexicalQueryUTF8Range: Range<Int>? = nil) throws -> ContextSnapshot {
        _ = try episodeLease?.checkActive(projectID: projectID)
        return try MeteredRetrieval.operation(lease: episodeLease) {
            _ = try recent.componentAssignments()
            guard let binding = recent.selectionBinding,
                  episodeIdentifierEqual(binding.projectID, projectID), episodeIdentifierEqual(binding.conversationID, conversationID),
                  episodeIdentifierEqual(binding.acceptedHumanEventID, excludingEventID),
                  episodeIdentifierEqual(recent.messages.last?.content, prompt), recent.evidence.isEmpty else { throw ContextError.sourceMismatch }
            let lexicalInput = try HistoricalQueryFormulation.input(prompt, utf8Range: lexicalQueryUTF8Range)
            if retrievalStrategy == .recentOnly {
                return try recentOnlySnapshot(recent)
            }
            let formulation = HistoricalQueryFormulation.formulate(lexicalInput)
            let lexical = formulation.query
            let excluded = ExactSourceIDs(recent.recentSourceIDs + [excludingEventID])
            func lexicalSnapshot(fallback: Bool) throws -> ContextSnapshot {
                let hits: [MemoryHit]
                var raw: MeteredLexicalReport?
                var frontier = 0
                if let lexical {
                    if let episodeLease {
                        let report = try MeteredRetrieval.lexicalSearch(store: store, query: lexical, projectID: projectID,
                            limit: ContextAssembler.componentMaximumEvidenceSpans, matching: .anyTerm,
                            excludingSourceIDs: excluded, lease: episodeLease, nested: true)
                        try MeteredRetrieval.requireCompleteReadCoverage(lease: episodeLease, resourceLimited: report.continuation != nil)
                        raw = report; hits = report.hits; frontier = report.sourceFrontier
                    } else {
                        frontier = try store.sourceFrontier(projectID: projectID)
                        hits = try store.search(query: lexical, projectID: projectID, limit: ContextAssembler.componentMaximumEvidenceSpans,
                            matching: .anyTerm, throughSequence: frontier, excludingSourceIDs: excluded)
                    }
                } else { hits = [] }
                let completed = try MeteredExchangeExpansion.completeShortPrimaries(store: store, projectID: projectID,
                    primaryHits: hits, sourceFrontier: frontier, excludingSourceIDs: excluded,
                    episodeLease: episodeLease, operationIsNested: true)
                let expanded = try MeteredExchangeExpansion.expand(store: store, projectID: projectID,
                    primaryHits: completed.hits, sourceFrontier: frontier, excludingSourceIDs: excluded,
                    episodeLease: episodeLease, operationIsNested: true)
                var result = try ContextAssembler.addEvidence(to: recent, store: store, conversationID: conversationID,
                    projectID: projectID, excludingEventID: excludingEventID, historicalHits: expanded.hits,
                    episodeLease: episodeLease, operationIsNested: true)
                var fields: [String: Any] = ["mode": fallback ? "lexical_fallback" : "lexical", "semantic_available": false]
                fields["primary_completion"] = completed.audit
                fields["exchange_expansion"] = expanded.audit
                if fallback { fields["failure"] = "semantic_search_failed" }
                if let raw {
                    fields["raw_work_version"] = "raw_work_v1"; fields["source_frontier"] = raw.sourceFrontier
                    fields["raw_work_charged"] = raw.rawWorkCharged; fields["inspected_candidates"] = raw.inspectedCandidates
                    fields["candidate_window_full"] = raw.candidateWindowFull; fields["candidate_window_complete"] = raw.candidateWindowComplete
                    fields["continuation_available"] = raw.continuation != nil
                }
                try appendAudit(to: &result, fields: fields)
                try appendQueryTrace(to: &result, formulation: formulation, prompt: prompt, input: lexicalInput, range: lexicalQueryUTF8Range)
                result.retrievalNotice = fallback ? "Semantic recall failed; archive recall used lexical search."
                    : "Archive recall used lexical search; semantic recall is unavailable."
                if let raw, !raw.candidateWindowComplete || raw.candidateWindowFull {
                    result.retrievalNotice = "Archive recall inspected a bounded lexical candidate window; additional evidence may remain."
                }
                return result
            }
            guard let semanticIndex else { return try lexicalSnapshot(fallback: false) }
            let report: SemanticSearchReport
            do {
                report = try semanticIndex.search(query: prompt, lexicalQuery: lexical ?? "", projectID: projectID,
                    limit: ContextAssembler.componentMaximumEvidenceSpans, excludingSourceIDs: excluded, includeLiteral: false,
                    episodeLease: episodeLease, operationIsNested: true)
            } catch {
                if error is EpisodeBudgetError || error is MeteredRetrievalError || error is MemoryError || error is ContextError { throw error }
                if let semanticError = error as? SemanticError {
                    switch semanticError { case .sourceMismatch, .publicationConflict: throw error; default: break }
                }
                return try lexicalSnapshot(fallback: true)
            }
            try MeteredRetrieval.requireCompleteReadCoverage(lease: episodeLease,
                resourceLimited: report.manifest.meteredLexicalCoverage?.continuation != nil
                    || report.manifest.meteredLiteralCoverage?.incompleteReason == "raw_source_budget")
            let completed = try MeteredExchangeExpansion.completeShortPrimaries(store: store, projectID: projectID,
                primaryHits: report.hits, sourceFrontier: report.manifest.sourceFrontier, excludingSourceIDs: excluded,
                episodeLease: episodeLease, operationIsNested: true)
            let expanded = try MeteredExchangeExpansion.expand(store: store, projectID: projectID,
                primaryHits: completed.hits, sourceFrontier: report.manifest.sourceFrontier, excludingSourceIDs: excluded,
                episodeLease: episodeLease, operationIsNested: true)
            var result = try ContextAssembler.addEvidence(to: recent, store: store, conversationID: conversationID,
                projectID: projectID, excludingEventID: excludingEventID, historicalHits: expanded.hits,
                episodeLease: episodeLease, operationIsNested: true)
            result.retrievalManifestID = report.manifestID
            result.retrievalManifestJSON = try report.serializedManifest()
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
            if let raw = report.manifest.meteredLexicalCoverage {
                audit["raw_work_version"] = "raw_work_v1"; audit["raw_work_charged"] = raw.rawWorkCharged
                audit["inspected_candidates"] = raw.inspectedCandidates; audit["candidate_window_full"] = raw.candidateWindowFull
                audit["candidate_window_complete"] = raw.candidateWindowComplete; audit["raw_continuation_available"] = raw.continuation != nil
            }
            audit["primary_completion"] = completed.audit
            audit["exchange_expansion"] = expanded.audit
            try appendAudit(to: &result, fields: audit)
            try appendQueryTrace(to: &result, formulation: formulation, prompt: prompt, input: lexicalInput, range: lexicalQueryUTF8Range)
            if report.manifest.queryDisposition != "supported" {
                result.retrievalNotice = "This request used lexical archive recall; semantic recall does not support its text."
            } else if !coverage.complete || report.manifest.vectorContinuation != nil || report.manifest.meteredLexicalCoverage?.candidateWindowComplete == false || report.manifest.meteredLexicalCoverage?.candidateWindowFull == true {
                result.retrievalNotice = "Archive recall used a partial semantic index. Missing evidence may still be in the archive."
            }
            return result
        }
    }

    private static func recentOnlySnapshot(_ recent: ContextSnapshot) throws -> ContextSnapshot {
        var result = recent
        result.retrievalManifestID = nil
        result.retrievalManifestJSON = nil
        result.retrievalNotice = nil
        result.retrievalAuditJSON = try JSONSerialization.data(
            withJSONObject: ["mode": ContextRetrievalStrategy.recentOnly.rawValue], options: [.sortedKeys])
        return result
    }

    private static func appendAudit(to snapshot: inout ContextSnapshot, fields: [String: Any]) throws {
        var audit = try snapshot.retrievalAuditJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        audit.merge(fields) { _, new in new }
        snapshot.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
    }

    private static func appendQueryTrace(to snapshot: inout ContextSnapshot, formulation: HistoricalQueryFormulation.Result,
        prompt: String, input: String, range: Range<Int>?) throws {
        var audit = try snapshot.retrievalAuditJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var trace = audit["selection_trace"] as? [String: Any] ?? [:]
        trace["version"] = "historical-selection-trace-v1"
        trace["lexical_query_version"] = HistoricalQueryFormulation.version
        trace["quoted_anchor_count"] = formulation.quotedAnchorCount
        trace["lexical_query_sha256"] = ContextSnapshot.digest(Data((formulation.query ?? "").utf8))
        trace["lexical_term_count"] = formulation.selectedTokenIndices.count
        trace["lexical_selected_token_indices"] = formulation.selectedTokenIndices
        if let range {
            trace["lexical_input_version"] = "accepted-prompt-utf8-range-v1"
            trace["accepted_prompt_sha256"] = ContextSnapshot.digest(Data(prompt.utf8))
            trace["lexical_input_sha256"] = ContextSnapshot.digest(Data(input.utf8))
            trace["lexical_input_offset"] = range.lowerBound
            trace["lexical_input_bytes"] = range.count
        }
        audit["selection_trace"] = trace
        snapshot.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
    }

    /// Keep at most eight unique non-filler terms, within the store's query
    /// limits. Operators and punctuation remain data; no raw FTS is accepted.
    /// Oversized terms are skipped so a valid long draft remains sendable.
    private static func historicalQuery(_ prompt: String) -> String? { HistoricalQueryFormulation.formulate(prompt).query }

}
