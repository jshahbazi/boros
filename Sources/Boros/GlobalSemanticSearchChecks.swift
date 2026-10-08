import Foundation
import CSQLite
import Darwin

/// Public synthetic fixtures for the P2 step 4 global semantic search option.
/// Injected three-dimensional vectors test population, fusion and integrity
/// mechanics only; they are not retrieval-quality evidence.
enum GlobalSemanticSearchChecks {
    static func run() throws -> [String: Bool] {
        guard let real = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw SemanticError.invalid }
        let base = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        let directory = base.appendingPathComponent("boros-global-semantic-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks: [String: Bool] = [:]
        let rrf = GlobalSemanticSearchParameters.declared(.globalReciprocalRank)
        let fill = GlobalSemanticSearchParameters.declared(.globalLexicalFill)
        checks["global_semantic_parameters_declared_and_shipped_unchanged"] = GlobalSemanticSearchParameters.declared(.shipped) == nil
            && rrf?.reciprocalRankConstant == 60 && rrf?.lexicalWindow == "100" && rrf?.fusion == "reciprocal-rank-equal-weight"
            && fill?.reciprocalRankConstant == nil && fill?.lexicalWindow == "result-limit" && fill?.fusion == "lexical-first-semantic-fill"
            && SemanticIndexConfiguration().maximumCandidateChunks == 4096 && SemanticIndexConfiguration().reciprocalRankConstant == 60
            && SemanticSearchSelection.shipped.mode == .shipped && SemanticSearchSelection.shipped.encoder == nil

        let store = try MemoryStore(directory: directory)
        let project = "synthetic-global-semantic", foreign = "synthetic-global-foreign"
        let archive = try store.createConversation(projectID: project, title: "Synthetic global archive")
        let other = try store.createConversation(projectID: foreign, title: "Synthetic foreign archive")
        // The semantic target is chronologically last, beyond a two-row cap.
        let early = try (0..<4).map { index in
            try store.append(conversationID: archive.id, role: index % 2 == 0 ? .human : .assistant,
                text: "Synthetic filler note \(index) about pebble \(index).", status: .complete,
                turnID: "global-early-turn-\(index)", eventID: "global-early-\(index)")
        }
        let target = try store.append(conversationID: archive.id, role: .assistant,
            text: "The orchard ladder leans on the barn.", status: .complete, turnID: "global-target-turn", eventID: "global-target")
        _ = try store.append(conversationID: other.id, role: .human, text: "The orchard ladder leans on the barn.",
            status: .complete, turnID: "global-foreign-turn", eventID: "global-foreign")
        let encoder = Encoder()
        var configuration = SemanticIndexConfiguration(); configuration.maximumCandidateChunks = 2
        var index: SemanticIndex? = try SemanticIndex(store: store, encoder: encoder, configuration: configuration)
        try build(index!, projects: [project, foreign])
        let selection = SemanticSearchSelection(.globalReciprocalRank, encoder: encoder)
        let capped = try index!.search(query: "ladder", lexicalQuery: "absentterm", projectID: project, limit: 4, includeLiteral: false)
        let global = try GlobalSemanticSearch.search(index: index!, selection: selection, query: "ladder", lexicalQuery: "absentterm",
            projectID: project, limit: 4, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
        checks["global_semantic_reaches_rows_beyond_shipped_chronological_cap"] = !capped.hits.contains { $0.eventID == target.id }
            && capped.manifest.vectorCandidatesInspected == 2 && capped.manifest.vectorContinuation != nil
            && global.report.hits.first?.eventID == target.id
            && global.report.manifest.results.first?.retrievalPaths == ["semantic"]
            && global.audit["eligible_vector_rows"] as? Int == 5 && global.report.manifest.vectorContinuation == nil
        checks["global_semantic_scope_frontier_and_exclusions_before_rank"] = try {
            let excluded = try GlobalSemanticSearch.search(index: index!, selection: selection, query: "ladder", lexicalQuery: "pebble",
                projectID: project, limit: 8, excludingSourceIDs: ExactSourceIDs([target.id, early[0].id]), episodeLease: nil)
            return excluded.report.hits.allSatisfy { $0.projectID == project && $0.eventID != target.id && $0.eventID != early[0].id }
                && excluded.audit["eligible_vector_rows"] as? Int == 3
        }()
        checks["global_semantic_returns_original_bytes_and_source_metadata"] = global.report.hits.allSatisfy { hit in
            guard let original = try? store.read(eventID: hit.eventID, offset: hit.excerptOffset, length: hit.excerpt.utf8.count) else { return false }
            return original.text == hit.excerpt && original.digest == hit.digest
        } && global.report.hits.first?.status == target.status && global.report.hits.first?.role == .assistant

        // With the population inside the shipped cap, the reciprocal-rank arm
        // must reproduce SemanticIndex.search exactly.
        index = nil
        index = try SemanticIndex(store: store, encoder: encoder)
        var identical = true
        for (query, lexical) in [("ladder", "pebble"), ("pebble barn", "barn pebble"), ("unrelated", "note"), ("ladder", "absentterm")] {
            let shipped = try index!.search(query: query, lexicalQuery: lexical, projectID: project, limit: 4, includeLiteral: false)
            let candidate = try GlobalSemanticSearch.search(index: index!, selection: selection, query: query, lexicalQuery: lexical,
                projectID: project, limit: 4, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
            identical = identical && shipped.manifest.results.count == candidate.report.manifest.results.count
                && zip(shipped.manifest.results, candidate.report.manifest.results).allSatisfy { lhs, rhs in
                    lhs.source == rhs.source && lhs.offset == rhs.offset && lhs.byteCount == rhs.byteCount
                        && lhs.excerptDigest == rhs.excerptDigest && lhs.retrievalPaths == rhs.retrievalPaths
                        && lhs.fusedScore == rhs.fusedScore && lhs.cosineScore == rhs.cosineScore
                }
                && shipped.hits.map(\.excerpt) == candidate.report.hits.map(\.excerpt)
        }
        checks["global_rrf_reproduces_shipped_fusion_when_population_fits"] = identical

        let fillSelection = SemanticSearchSelection(.globalLexicalFill, encoder: encoder)
        let lexicalOnly = try store.search(query: "pebble", projectID: project, limit: 3, matching: .anyTerm)
        let full = try GlobalSemanticSearch.search(index: index!, selection: fillSelection, query: "ladder", lexicalQuery: "pebble",
            projectID: project, limit: 3, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
        checks["global_fill_keeps_lexical_primaries_and_order_when_lexical_fills_limit"] = lexicalOnly.count == 3
            && full.report.hits.map(\.eventID) == lexicalOnly.map(\.eventID)
            && full.report.hits.map(\.excerptOffset) == lexicalOnly.map(\.excerptOffset)
            && !full.report.manifest.results.contains { $0.retrievalPaths == ["semantic"] }
        let sparse = try GlobalSemanticSearch.search(index: index!, selection: fillSelection, query: "ladder", lexicalQuery: "barn",
            projectID: project, limit: 3, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
        let sparseLexical = try store.search(query: "barn", projectID: project, limit: 3, matching: .anyTerm)
        checks["global_fill_appends_semantic_only_after_lexical_prefix"] = try {
            let paths = sparse.report.manifest.results.map(\.retrievalPaths)
            let lexicalCount = paths.prefix { $0.contains("lexical") }.count
            let sparseLexicalSmaller = try store.search(query: "orchardx", projectID: project, limit: 3, matching: .anyTerm).isEmpty
            let emptyLexical = try GlobalSemanticSearch.search(index: index!, selection: fillSelection, query: "ladder", lexicalQuery: "orchardx",
                projectID: project, limit: 3, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
            return lexicalCount == 1 && sparseLexical.count == 1 && sparse.report.hits.count == 3
                && sparse.report.hits.first?.eventID == sparseLexical.first?.eventID
                && sparse.report.hits.first?.excerptOffset == sparseLexical.first?.excerptOffset
                && paths.dropFirst(lexicalCount).allSatisfy { $0 == ["semantic"] }
                && sparse.report.hits.dropFirst().map(\.eventID) == [early[1].id, early[3].id]
                && sparseLexicalSmaller && emptyLexical.report.hits.first?.eventID == target.id && emptyLexical.report.hits.count == 3
                && emptyLexical.report.manifest.results.allSatisfy { $0.retrievalPaths == ["semantic"] }
        }()

        encoder.unsupported = true
        let unsupported = try GlobalSemanticSearch.search(index: index!, selection: selection, query: "ladder", lexicalQuery: "pebble",
            projectID: project, limit: 4, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
        encoder.unsupported = false
        checks["global_semantic_unsupported_query_scans_no_vectors"] = unsupported.report.manifest.queryDisposition == "codeLike"
            && unsupported.audit["eligible_vector_rows"] as? Int == 0
            && unsupported.report.manifest.results.allSatisfy { $0.retrievalPaths == ["lexical"] }
        checks["global_semantic_rejects_a_different_encoder_identity"] = rejects {
            _ = try GlobalSemanticSearch.search(index: index!, selection: SemanticSearchSelection(.globalReciprocalRank, encoder: Encoder(revision: "2")),
                query: "ladder", lexicalQuery: "pebble", projectID: project, limit: 4, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
        }
        checks["global_semantic_rejects_shipped_mode_as_global_call"] = rejects {
            _ = try GlobalSemanticSearch.search(index: index!, selection: .shipped, query: "ladder", lexicalQuery: "pebble",
                projectID: project, limit: 4, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
        }
        checks.merge(try preparationChecks(store: store, index: index!, encoder: encoder, project: project, target: target)) { _, new in new }
        // A stored vector that is not unit length fails closed.
        try corruptVector(index!.directory.appendingPathComponent("index.sqlite3"), eventID: early[1].id)
        do {
            _ = try GlobalSemanticSearch.search(index: index!, selection: selection, query: "ladder", lexicalQuery: "pebble",
                projectID: project, limit: 4, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
            checks["global_semantic_corrupt_vector_fails_closed"] = false
        } catch { checks["global_semantic_corrupt_vector_fails_closed"] = (error as? SemanticError) == .sourceMismatch }
        index = nil
        return checks
    }

    /// The selection reaches ordinary preparation only when passed explicitly;
    /// the default call keeps the shipped audit and charges vector work.
    private static func preparationChecks(store: MemoryStore, index: SemanticIndex, encoder: Encoder, project: String,
                                          target: MemoryEvent) throws -> [String: Bool] {
        let chat = try store.createConversation(projectID: project, title: "Synthetic global request")
        let clock = Clock(), episodeID = UUID().uuidString, currentID = "global-current"
        let prompt = "Where does the ladder lean?"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "global-current-turn",
            humanEventID: currentID, episodeID: episodeID, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, episodeLease: lease)
        let shipped = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: currentID, semanticIndex: index, episodeLease: lease)
        let before = try lease.checkActive(), callsBefore = encoder.calls
        let selected = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: currentID, semanticIndex: index, episodeLease: lease,
            semanticSearch: SemanticSearchSelection(.globalReciprocalRank, encoder: encoder))
        let after = try lease.checkActive()
        let shippedAudit = try JSONSerialization.jsonObject(with: shipped.retrievalAuditJSON!) as? [String: Any] ?? [:]
        let audit = try JSONSerialization.jsonObject(with: selected.retrievalAuditJSON!) as? [String: Any] ?? [:]
        let global = audit["global_semantic"] as? [String: Any] ?? [:]
        let rows = global["eligible_vector_rows"] as? Int ?? -1
        _ = try lease.finish(reason: .cancelled)
        return [
            "global_semantic_default_preparation_is_shipped": shippedAudit["mode"] as? String == "hybrid"
                && shippedAudit["global_semantic"] == nil && shippedAudit["semantic_search"] == nil,
            "global_semantic_explicit_preparation_records_mode_and_delivers_original": audit["mode"] as? String == "hybrid"
                && audit["semantic_search"] as? String == "global_rrf" && global["parameters_sha256"] is String
                && selected.evidence.contains { episodeIdentifierEqual($0.eventID, target.id) },
            "global_semantic_charges_vectors_and_one_query_embedding": rows > 0 && encoder.calls == callsBefore + 1
                && after.charged.vectorBytes - before.charged.vectorBytes == rows * (encoder.dimension * 4 + 1)
                && after.charged.encoderInputBytes - before.charged.encoderInputBytes == "Where does the ladder lean?".utf8.count
                && after.charged.modelCalls == before.charged.modelCalls + 1,
            "global_semantic_audit_is_content_free": !(String(data: try JSONSerialization.data(withJSONObject: global), encoding: .utf8) ?? "ladder")
                .contains("ladder")
        ]
    }

    private static func build(_ index: SemanticIndex, projects: [String]) throws {
        for project in projects {
            while true {
                let receipt = try index.process(projectID: project)
                if receipt.scheduledSources == 0 && receipt.publishedChunks == 0 && receipt.failedChunks == 0 { break }
            }
        }
    }

    private static func corruptVector(_ url: URL, eventID: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else { throw SemanticError.database }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE chunks SET vector=? WHERE event_id=?", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SemanticError.database
        }
        defer { sqlite3_finalize(statement) }
        let bad = SemanticIndex.vectorData([2, 0, 0])
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = bad.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(bad.count), transient) }
        sqlite3_bind_text(statement, 2, eventID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw SemanticError.database }
    }

    private static func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }

    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-global-semantic-clock", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }

    private final class Encoder: SemanticEmbeddingAdapter {
        let dimension = 3
        let metadata: [String: String]
        var unsupported = false
        private(set) var calls = 0
        init(revision: String = "1") { metadata = ["provider": "synthetic-global-semantic", "revision": revision] }
        func encode(_ text: String) throws -> SemanticEncoding {
            calls += 1
            if unsupported { return .unsupported(.codeLike) }
            if text.contains("ladder") { return .vector([1, 0, 0]) }
            if text.contains("pebble 1") || text.contains("pebble 3") { return .vector([0.6, 0.8, 0]) }
            if text.contains("pebble") { return .vector([0, 1, 0]) }
            return .vector([0, 0, 1])
        }
    }
}
