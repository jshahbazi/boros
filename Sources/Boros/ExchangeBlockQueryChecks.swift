import Foundation
import Darwin

/// Synthetic contracts for the explicit P2 exchange policies. Only fixed
/// synthetic sources enter these fixtures; results are named booleans.
enum ExchangeBlockQueryChecks {
    static func run() -> [String: Bool] {
        do { return try checks() }
        catch { return ["exchange_query_fixture_setup_and_execution": false] }
    }

    private static func checks() throws -> [String: Bool] {
        var result: [String: Bool] = [:]

        // Policies: the shipped default is unchanged and the new ones are explicit.
        let v1 = try ContextComponentPolicy.currentSelectedQwen.validated()
        let exchange = try ContextComponentPolicy.selectedQwenExchange.validated()
        let adjacent = try ContextComponentPolicy.selectedQwenExchangeAdjacent.validated()
        result["exchange_query_default_policy_remains_exact_v1_sixteen_spans"] = v1 == .selectedQwen
            && v1.version == "selected-model-context-components-v1" && v1.evidenceSpans == 16
            && v1.reductionVersion == "whole-source-geometric-v1" && !v1.usesExchangeQuery
            && !v1.packsAdjacentExchanges && v1.selectionAuditVersion == "context-geometric-v1"
        result["exchange_query_policies_are_explicit_versioned_and_distinct"] = exchange.usesExchangeQuery && adjacent.usesExchangeQuery
            && !exchange.packsAdjacentExchanges && adjacent.packsAdjacentExchanges
            && exchange != adjacent && exchange != v1 && adjacent != v1
            && !exchange.usesBoundedNeighborhood && !adjacent.usesBoundedNeighborhood
            && exchange.selectionAuditVersion == "context-exchange-v1" && adjacent.selectionAuditVersion == "context-exchange-v1"
            && exchange.version == "selected-model-context-components-v3-exchange"
            && adjacent.version == "selected-model-context-components-v3-exchange-adjacent"
        let decodedExchange = try JSONDecoder().decode(ContextComponentPolicy.self, from: exchange.canonicalData())
        let decodedAdjacent = try JSONDecoder().decode(ContextComponentPolicy.self, from: adjacent.canonicalData())
        var forged = exchange; forged.evidenceSpans = 64
        result["exchange_query_policies_round_trip_and_unknown_variants_refused"] = decodedExchange == exchange
            && decodedAdjacent == adjacent && (try? forged.validated()) == nil

        // Query: every content term, folded; quoted spans are anchor term sets.
        let query = ExchangeBlockQuery.query("What did the \u{201C}Blue Heron\u{201D} café say about `alpha-beta` and Zebra?")
        result["exchange_query_uses_every_folded_content_term_without_stopwords"] = query.terms
            == ["blue", "heron", "cafe", "alpha", "beta", "zebra"]
        result["exchange_query_keeps_quoted_anchor_term_sets"] = query.anchors == [["blue", "heron"], ["alpha", "beta"]]
        result["exchange_query_without_content_terms_is_empty"] = ExchangeBlockQuery.query("what is it?").terms.isEmpty

        // Index and ranking over synthetic in-memory sources.
        func source(_ id: String, _ conversation: String, _ role: MemoryRole, _ text: String, _ sequence: Int) -> ExchangeBlockQuery.Source {
            ExchangeBlockQuery.Source(reference: MemorySourceReference(sequence: sequence, eventID: id, conversationID: conversation,
                projectID: "synthetic-exchange-project", role: role, status: .complete, createdAt: "2026-10-08T00:00:00Z",
                digest: MeteredRetrieval.digest(Data(text.utf8)), byteCount: text.utf8.count), text: text)
        }
        let index = ExchangeBlockQuery.Index(sources: [
            source("lead", "c1", .assistant, "Synthetic greeting common", 1),
            source("h1", "c1", .human, "Synthetic common words here", 2),
            source("x1", "c2", .human, "Synthetic interleaved common", 3),
            source("a1", "c1", .assistant, "Synthetic reply common", 4),
            source("h2", "c1", .human, "Synthetic rare zebra common", 5),
            source("a2", "c1", .assistant, "Synthetic answer common", 6),
            source("h3", "c1", .human, "Synthetic blue heron common", 7),
        ])
        let ids = index.blocks.map { $0.sources.map { index.sources[$0].reference.eventID } }
        result["exchange_query_blocks_start_at_each_human_within_one_conversation"] = ids
            == [["lead"], ["h1", "a1"], ["h2", "a2"], ["h3"], ["x1"]]
        result["exchange_query_adjacency_is_same_conversation_only"] = index.previous[4] == 3 && index.next[3] == 4
            && index.previous[2] == nil && index.next[2] == nil
        let rare = index.rank(ExchangeBlockQuery.query("zebra common"))
        result["exchange_query_rare_term_outranks_common_term_by_idf"] = rare.first.map { index.blocks[$0.block].sources.first } == 4
            && rare.count == index.blocks.count
        let anchored = index.rank(ExchangeBlockQuery.query("zebra zebra \"blue heron\""))
        result["exchange_query_quoted_anchor_blocks_rank_first"] = anchored.first.map { index.blocks[$0.block].sources.first } == 6
            && anchored.first?.anchorMatches == 1 && anchored.dropFirst().allSatisfy { $0.anchorMatches == 0 }
        let tied = index.rank(ExchangeBlockQuery.query("synthetic"))
        result["exchange_query_equal_scores_prefer_later_block"] = zip(tied, tied.dropFirst()).allSatisfy {
            $0.score > $1.score || ($0.score == $1.score && $0.block > $1.block)
        }

        // Exact store-page boundaries.
        let long = source("long", "c3", .assistant, String(repeating: "x", count: 4095) + "é" + "tail", 8)
        let pages = ExchangeBlockQuery.pages(long)
        result["exchange_query_pages_end_on_scalar_boundaries_within_page_limit"] = pages.count == 2
            && pages[0].excerpt.utf8.count == 4095 && pages[1].excerptOffset == 4095
            && pages.map(\.excerpt).joined() == long.text && pages.allSatisfy { $0.excerpt.utf8.count <= MemoryStore.maximumPageBytes }

        // End to end through the ordinary preparation entry point.
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let archive = try fixture.conversation("archive")
        let before1 = try fixture.append("before-assistant", "Synthetic earlier assistant note", .assistant, archive)
        let target = try fixture.append("target-human", "Synthetic question about the quokka habitat", .human, archive)
        let reply = try fixture.append("target-assistant", "Synthetic reply on habitat details", .assistant, archive)
        let after1 = try fixture.append("after-human", "Synthetic follow-up request", .human, archive)
        let afterReply = try fixture.append("after-assistant", "Synthetic follow-up reply", .assistant, archive)
        let other = try fixture.conversation("other")
        let weak = try fixture.append("weak-human", "Synthetic habitat mention only", .human, other)
        let oversized = try fixture.conversation("oversized")
        let huge = try fixture.append("huge-human", "Synthetic quokka " + String(repeating: "padding ", count: 9000), .human, oversized)
        let prompt = "Where is the quokka habitat?"
        func prepare(_ policy: ContextComponentPolicy, prompt: String = prompt) throws
            -> (snapshot: ContextSnapshot, before: EpisodeReceipt, after: EpisodeReceipt) {
            var limits = EpisodeLimits(); limits.componentPolicy = policy
            let lease = try fixture.lease(limits, text: prompt), accepted = try lease.checkActive()
            let recent = try ContextAssembler.prepareRecent(store: fixture.store, conversationID: fixture.requests.id,
                projectID: fixture.project, prompt: prompt, system: "Synthetic exchange host",
                excludingEventID: accepted.humanEventID!, episodeLease: lease, componentPolicy: policy)
            let before = try lease.checkActive()
            let snapshot = try ExchangeBlockQuery.prepareEvidence(recent: recent, store: fixture.store,
                conversationID: fixture.requests.id, projectID: fixture.project, prompt: prompt,
                excludingEventID: accepted.humanEventID!, episodeLease: lease, lexicalQueryUTF8Range: nil, componentPolicy: policy)
            return (snapshot, before, try lease.checkActive())
        }
        let step1 = try prepare(.selectedQwenExchange)
        // The v1 ranked entry refuses exchange policies; v1 refuses the exchange entry.
        var refusalLimits = EpisodeLimits(); refusalLimits.componentPolicy = .selectedQwenExchange
        let refusalLease = try fixture.lease(refusalLimits, text: prompt), refusalID = try refusalLease.checkActive().humanEventID!
        let refusalRecent = try ContextAssembler.prepareRecent(store: fixture.store, conversationID: fixture.requests.id,
            projectID: fixture.project, prompt: prompt, system: "Synthetic exchange host", excludingEventID: refusalID,
            episodeLease: refusalLease, componentPolicy: .selectedQwenExchange)
        let v1Refused = (try? ChatContextPreparation.prepareEvidence(recent: refusalRecent, store: fixture.store,
            conversationID: fixture.requests.id, projectID: fixture.project, prompt: prompt, excludingEventID: refusalID,
            episodeLease: refusalLease, componentPolicy: .selectedQwenExchange)) == nil
        let mismatchRefused = (try? ExchangeBlockQuery.prepareEvidence(recent: refusalRecent, store: fixture.store,
            conversationID: fixture.requests.id, projectID: fixture.project, prompt: prompt, excludingEventID: refusalID,
            episodeLease: refusalLease, lexicalQueryUTF8Range: nil, componentPolicy: .selectedQwenExchangeAdjacent)) == nil
        let defaultRefused = (try? ExchangeBlockQuery.prepareEvidence(recent: refusalRecent, store: fixture.store,
            conversationID: fixture.requests.id, projectID: fixture.project, prompt: prompt, excludingEventID: refusalID,
            episodeLease: refusalLease, lexicalQueryUTF8Range: nil, componentPolicy: .selectedQwen)) == nil
        result["exchange_query_entry_points_refuse_mismatched_policies"] = v1Refused && mismatchRefused && defaultRefused
        let delivered = step1.snapshot.evidence.map(\.eventID)
        let retrieval = try JSONSerialization.jsonObject(with: step1.snapshot.retrievalAuditJSON ?? Data()) as? [String: Any] ?? [:]
        let exchangeAudit = retrieval["exchange_query"] as? [String: Any] ?? [:]
        let auditBytes = try JSONSerialization.data(withJSONObject: retrieval)
        result["exchange_query_step1_delivers_best_block_whole_first"] = Array(delivered.prefix(2)) == [target.id, reply.id]
            && step1.snapshot.evidence.prefix(2).allSatisfy { $0.excerptOffset == 0 && $0.excerpt.utf8.count == $0.totalBytes }
        result["exchange_query_step1_includes_lower_ranked_block_and_no_neighbors"] = delivered.contains(weak.id)
            && !delivered.contains(before1.id) && !delivered.contains(after1.id) && !delivered.contains(afterReply.id)
        result["exchange_query_step1_skips_block_over_estimated_budget_atomically"] = !delivered.contains(huge.id)
            && (exchangeAudit["budget_skipped_block_count"] as? Int ?? 0) >= 1
        result["exchange_query_never_delivers_recent_or_accepted_request"] = !step1.snapshot.evidence.contains { hit in
            step1.snapshot.recentSourceIDs.contains(hit.eventID) || hit.conversationID == fixture.requests.id }
        result["exchange_query_snapshot_is_valid_and_versioned"] = (try? step1.snapshot.componentAssignments()) != nil
            && step1.snapshot.selectionAudit?.version == "context-exchange-v1" && step1.snapshot.evidenceProvenance == nil
            && retrieval["mode"] as? String == "exchange_lexical" && retrieval["semantic_available"] as? Bool == false
            && exchangeAudit["version"] as? String == ExchangeBlockQuery.version
            && exchangeAudit["index"] as? String == "in_memory_per_turn"
        result["exchange_query_audit_contains_no_source_payload_or_question"] = ![prompt, target.text, reply.text, weak.text]
            .contains { auditBytes.range(of: Data($0.utf8)) != nil }
        result["exchange_query_uses_no_model_encoder_or_vector_work"] = step1.after.charged.modelCalls == step1.before.charged.modelCalls
            && step1.after.charged.encoderInputBytes == step1.before.charged.encoderInputBytes
            && step1.after.charged.vectorBytes == step1.before.charged.vectorBytes
            && step1.after.charged.rawSourceBytes > step1.before.charged.rawSourceBytes
            && step1.after.limits == step1.before.limits

        let step2 = try prepare(.selectedQwenExchangeAdjacent)
        let adjacentIDs = step2.snapshot.evidence.map(\.eventID)
        result["exchange_query_adjacent_packs_opposite_role_neighbors_beside_block"] = Array(adjacentIDs.prefix(4))
            == [before1.id, target.id, reply.id, after1.id]
        result["exchange_query_adjacent_never_adds_same_role_or_second_neighbor"] = !adjacentIDs.contains(afterReply.id)
            && (try? JSONSerialization.jsonObject(with: step2.snapshot.retrievalAuditJSON ?? Data()) as? [String: Any])?["mode"] as? String == "exchange_adjacent"

        // A component-cap overflow removes exactly one lowest-ranked span.
        let reduced = try step2.snapshot.reducedEvidenceForComponentCap()
        result["exchange_query_component_overflow_removes_one_span"] = reduced?.evidence.count == step2.snapshot.evidence.count - 1
            && reduced?.evidence.map(\.eventID) == Array(adjacentIDs.dropLast())
            && reduced?.selectionAudit?.evidenceTokenExcludedCount == 1

        let empty = try prepare(.selectedQwenExchange, prompt: "What is it?")
        let emptyAudit = (try? JSONSerialization.jsonObject(with: empty.snapshot.retrievalAuditJSON ?? Data()) as? [String: Any])?["exchange_query"] as? [String: Any]
        result["exchange_query_no_content_terms_delivers_no_evidence"] = empty.snapshot.evidence.isEmpty
            && emptyAudit?["skipped"] as? String == "no_query_terms"
        return result
    }

    private final class Fixture {
        let directory: URL
        let store: MemoryStore
        let project = "synthetic-exchange-project"
        let clock = Clock()
        let requests: StoredConversation
        private var requestOrdinal = 0
        init() throws {
            guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw MeteredRetrievalError.invalid }
            defer { free(path) }
            directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("boros-exchange-checks-" + UUID().uuidString)
            store = try MemoryStore(directory: directory)
            requests = try store.createConversation(projectID: project, title: "Synthetic exchange requests")
        }
        func conversation(_ label: String) throws -> StoredConversation {
            try store.createConversation(projectID: project, title: "Synthetic exchange " + label)
        }
        func append(_ id: String, _ text: String, _ role: MemoryRole, _ conversation: StoredConversation) throws -> MemoryEvent {
            try store.append(conversationID: conversation.id, role: role, text: text, status: .complete,
                turnID: "synthetic-exchange-turn-" + id, eventID: id)
        }
        func lease(_ limits: EpisodeLimits, text: String) throws -> EpisodeLease {
            requestOrdinal += 1
            let id = UUID().uuidString, suffix = String(requestOrdinal)
            _ = try store.acceptRequestAndBeginEpisode(conversationID: requests.id, turnID: "synthetic-exchange-request-turn-" + suffix,
                humanEventID: "synthetic-exchange-request-" + suffix, episodeID: id,
                text: text, limits: limits, clock: clock.now())
            return EpisodeLease(ledger: store, episodeID: id, clock: clock)
        }
    }

    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-exchange-clock", continuousNanoseconds: 1_000_000,
                utc: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
}
