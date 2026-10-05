import Foundation
import CSQLite

/// A finite read selection must stop at partial raw coverage before it rereads
/// returned excerpts or starts query inference. Browser partial-hit delivery
/// has its own explicit contract in LocalReadChecks.
enum ReadCoverageChecks {
    static func run(store: MemoryStore, semantic: SemanticIndex) throws -> [String: Bool] {
        let project = "synthetic-read-coverage-" + UUID().uuidString
        let current = try store.createConversation(projectID: project, title: "Empty selection conversation")
        let archive = try store.createConversation(projectID: project, title: "Bounded partial coverage")
        let large = "needle " + String(repeating: "x ", count: 64_996) + "x"
        let small = "needle " + String(repeating: "a", count: 23)
        let largeSource = try store.append(conversationID: archive.id, role: .human, text: large,
            status: .complete, turnID: "coverage-large-turn", eventID: "coverage-large-" + UUID().uuidString)
        let smallSource = try store.append(conversationID: archive.id, role: .human, text: small,
            status: .complete, turnID: "coverage-small-turn", eventID: "coverage-small-" + UUID().uuidString)
        let clock = SystemEpisodeClock()
        var limits = EpisodeLimits(); limits.resources.rawSourceBytes = 5_000
        var checks: [String: Bool] = [:]
        let sourceCounts = try inventory(store.directory.appendingPathComponent("memory.sqlite3"))
        func episode(_ purpose: EpisodeLocalReadPurpose) throws -> EpisodeLease {
            let id = UUID().uuidString
            let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: purpose,
                requestID: UUID().uuidString, descriptorVersion: "read-coverage-check-v1",
                descriptorSHA256: MeteredRetrieval.digest(Data("Synthetic partial coverage fixture".utf8)))
            _ = try store.beginLocalReadEpisode(episodeID: id, projectID: project, binding: binding,
                limits: limits, clock: clock.now())
            return EpisodeLease(ledger: store, episodeID: id, clock: clock)
        }
        checks["read_coverage_fixture_has_exact_small_and_large_sources"] = smallSource.byteCount == 30
            && largeSource.byteCount == 130_000 && sourceCounts.events >= 2
        let probe = try episode(.retrievalProbe)
        let report = try MeteredRetrieval.lexicalSearch(store: store, query: "needle", projectID: project, lease: probe)
        checks["read_coverage_fixture_returns_small_hit_before_budget_frontier"] = report.hits.count == 1
            && report.hits.first?.eventID == smallSource.id && report.inspectedCandidates == 1
            && report.continuation != nil && report.rawWorkCharged == 180
        _ = try probe.finish(reason: .budgetExceeded)

        func limited(_ name: String, expectedRaw: Int, purpose: EpisodeLocalReadPurpose = .contextSelection,
                     body: (EpisodeLease) throws -> Void) throws {
            let lease = try episode(purpose)
            var refused = false
            do { try body(lease) }
            catch EpisodeBudgetError.exhausted { refused = true }
            // The trusted caller records the terminal reason after the helper
            // refuses incomplete coverage; the helper cannot renew the lease.
            let receipt = try lease.finish(reason: refused ? .budgetExceeded : .failed)
            checks["read_coverage_" + name + "_fails_with_authoritative_budget_receipt"] = refused
                && receipt.state == .budgetExceeded && receipt.origin.isLocalRead && receipt.held == .zero
            checks["read_coverage_" + name + "_does_not_reread_partial_evidence"] = receipt.charged.rawSourceBytes == expectedRaw
                && receipt.charged.memoryOperations == 1
            checks["read_coverage_" + name + "_does_not_start_query_embedding"] = receipt.charged.modelCalls == 0
                && receipt.charged.encoderInputBytes == 0 && receipt.unknownInputOperations == 0
                && receipt.charged.vectorBytes == 0
        }
        try limited("context_lexical", expectedRaw: 180) { lease in
            _ = try ContextAssembler.prepare(store: store, conversationID: current.id, projectID: project,
                prompt: "Synthetic selection", system: "", historicalQuery: "needle", maximumRecentBytes: 0,
                episodeLease: lease)
        }
        try limited("chat_lexical", expectedRaw: 180) { lease in
            _ = try ChatContextPreparation.prepare(store: store, conversationID: current.id, projectID: project,
                prompt: "needle", system: "", excludingEventID: "synthetic-unsaved-current", episodeLease: lease)
        }
        try limited("semantic_lexical", expectedRaw: 180, purpose: .retrievalProbe) { lease in
            _ = try semantic.search(query: "needle", lexicalQuery: "needle", projectID: project,
                includeLiteral: false, episodeLease: lease)
        }
        try limited("semantic_literal", expectedRaw: 0, purpose: .retrievalProbe) { lease in
            // Literal source order reaches the large first source before the
            // small hit. It must stop at that budget frontier before inference.
            _ = try semantic.search(query: "needle", lexicalQuery: "needle", projectID: project,
                includeLiteral: true, episodeLease: lease)
        }
        try limited("chat_hybrid", expectedRaw: 180) { lease in
            _ = try ChatContextPreparation.prepare(store: store, conversationID: current.id, projectID: project,
                prompt: "needle", system: "", excludingEventID: "synthetic-unsaved-current",
                semanticIndex: semantic, episodeLease: lease)
        }
        checks["read_coverage_partial_semantic_selection_publishes_no_manifest"] = try manifestCount(semantic.directory, project: project) == 0

        // A complete candidate scan still validates exactly the 30-byte page.
        // Its two-pass reread costs (30 + 1) * 2 = 62 logical source bytes.
        let complete = try episode(.contextSelection)
        let snapshot = try ContextAssembler.prepare(store: store, conversationID: current.id, projectID: project,
            prompt: "Synthetic selection", system: "", excludingEventID: largeSource.id,
            historicalQuery: "needle", maximumRecentBytes: 0, episodeLease: complete)
        let completeReceipt = try complete.finish(reason: .completed)
        checks["read_coverage_complete_selection_keeps_exact_validation_reread"] = snapshot.evidence.count == 1
            && snapshot.evidence.first?.eventID == smallSource.id && completeReceipt.state == .completed
            && completeReceipt.charged.rawSourceBytes == 242 && completeReceipt.charged.memoryOperations == 1
        checks["read_coverage_operations_create_no_source_capture_or_hidden_chats"] = try inventory(store.directory.appendingPathComponent("memory.sqlite3")) == sourceCounts
        return checks
    }

    private struct Inventory: Equatable { let events: Int; let conversations: Int; let invocations: Int }
    private static func inventory(_ file: URL) throws -> Inventory {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw MemoryError.database("coverage inventory open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, "SELECT (SELECT COUNT(*) FROM events),(SELECT COUNT(*) FROM conversations),(SELECT COUNT(*) FROM invocations)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("coverage inventory query failed") }
        return Inventory(events: Int(sqlite3_column_int64(statement, 0)), conversations: Int(sqlite3_column_int64(statement, 1)),
            invocations: Int(sqlite3_column_int64(statement, 2)))
    }
    private static func manifestCount(_ directory: URL, project: String) throws -> Int {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw MemoryError.database("coverage manifest open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM manifests WHERE project_id=?", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, project, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("coverage manifest query failed") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
