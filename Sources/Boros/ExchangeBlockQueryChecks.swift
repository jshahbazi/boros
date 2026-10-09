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

        // P2 step 3: value-density packing over a declared candidate window.
        result.merge(try packedChecks(source: source)) { _, latest in latest }
        let step3 = try prepare(.selectedQwenExchangePacked)
        let packedRetrieval = try JSONSerialization.jsonObject(with: step3.snapshot.retrievalAuditJSON ?? Data()) as? [String: Any] ?? [:]
        let packedAudit = packedRetrieval["exchange_query"] as? [String: Any] ?? [:]
        let packedCandidates = packedAudit["candidates"] as? [[Any]] ?? []
        let packedUnits = packedCandidates.flatMap { ($0.last as? [[String]]) ?? [] }
        let packedCodes = packedUnits.map { $0[2] }
        let packedIDs = step3.snapshot.evidence.map(\.eventID)
        let candidateIDs = Set(packedUnits.map { $0[0] })
        result["exchange_packed_entry_delivers_best_block_first_from_declared_candidates"] = Array(packedIDs.prefix(4)) == [before1.id, target.id, reply.id, after1.id]
            && packedRetrieval["mode"] as? String == "exchange_packed" && packedRetrieval["selection_trace"] == nil
            && packedAudit["packing_version"] as? String == ExchangeBlockQuery.ValuePacking.version
            && packedAudit["candidate_block_depth"] as? Int == ExchangeBlockQuery.ValuePacking.candidateBlockDepth
            && packedIDs.allSatisfy { candidateIDs.contains(ExchangeBlockQuery.ValuePacking.candidateID($0)) }
        result["exchange_packed_every_candidate_unit_has_an_explicit_receipt"] = !packedCodes.isEmpty
            && packedCodes.allSatisfy { $0 != "?" && ExchangeBlockQuery.ValuePacking.dispositionCodes[$0] != nil }
            && packedCodes.filter { $0 == "D" }.count == Set(packedIDs).count
            && (packedAudit["disposition_counts"] as? [String: Int])?.values.reduce(0, +) == packedCodes.count
        let packedDelivery = try JSONSerialization.jsonObject(with: step3.snapshot.deliveryAudit()) as? [String: Any] ?? [:]
        let deliveredSources = packedDelivery["historical_sources"] as? [[String: Any]] ?? []
        let replicaBytes = try step3.snapshot.evidence.map {
            try ExchangeBlockQuery.ValuePacking.auditEntryBytes($0, selectionVersion: step3.snapshot.selectionBinding!.version)
        }
        let actualBytes = try deliveredSources.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).count + 1 }
        result["exchange_packed_audit_entry_replica_matches_delivery_audit_bytes"] = !replicaBytes.isEmpty && replicaBytes == actualBytes
        let measuredAudit = packedAudit["delivery_audit_bytes_before_admission"] as? Int ?? Int.max
        result["exchange_packed_delivery_audit_keeps_admission_headroom_and_candidates"] = measuredAudit
            <= ExchangeBlockQuery.ValuePacking.deliveryAuditLimitBytes - ExchangeBlockQuery.ValuePacking.admissionHeadroomBytes
            && (packedDelivery["retrieval"] as? [String: Any])?["exchange_query"] != nil
        let packedAuditBytes = try JSONSerialization.data(withJSONObject: packedRetrieval)
        result["exchange_packed_audit_contains_no_source_payload_or_question"] = ![prompt, target.text, reply.text, weak.text]
            .contains { packedAuditBytes.range(of: Data($0.utf8)) != nil }
            && !step3.snapshot.evidence.contains { step3.snapshot.recentSourceIDs.contains($0.eventID) || $0.conversationID == fixture.requests.id }
            && step3.after.charged.modelCalls == step3.before.charged.modelCalls
            && step3.after.charged.vectorBytes == step3.before.charged.vectorBytes
        let packedReduced = try step3.snapshot.reducedEvidenceForComponentCap()
        let reducedRetrieval = try JSONSerialization.jsonObject(with: packedReduced?.retrievalAuditJSON ?? Data()) as? [String: Any]
        let reducedAudit = reducedRetrieval?["exchange_query"] as? [String: Any]
        let receipt = (reducedAudit?["reduction_receipts"] as? [[Any]])?.first
        result["exchange_packed_counted_removal_is_an_explicit_receipt"] = packedReduced?.evidence.count == step3.snapshot.evidence.count - 1
            && receipt?.count == 3 && receipt?[0] as? String == packedIDs.last.map(ExchangeBlockQuery.ValuePacking.candidateID)
            && receipt?[2] as? String == "token" && packedReduced?.selectionAudit?.evidenceTokenExcludedCount == 1
        let anchoredStep3 = try prepare(.selectedQwenExchangePacked, prompt: "Where is the \"quokka padding\" habitat?")
        let anchoredRetrieval = try JSONSerialization.jsonObject(with: anchoredStep3.snapshot.retrievalAuditJSON ?? Data()) as? [String: Any]
        let anchoredAudit = anchoredRetrieval?["exchange_query"] as? [String: Any]
        let anchoredFirst = (anchoredAudit?["candidates"] as? [[Any]])?.first
        result["exchange_packed_mandatory_anchor_over_budget_is_receipted"] = anchoredFirst?.first as? Int == 1
            && ((anchoredFirst?.last as? [[String]])?.contains { $0[1] == "l" && $0[2] == "M" } ?? false)
            && !anchoredStep3.snapshot.evidence.contains { $0.eventID == huge.id }

        let empty = try prepare(.selectedQwenExchange, prompt: "What is it?")
        let emptyAudit = (try? JSONSerialization.jsonObject(with: empty.snapshot.retrievalAuditJSON ?? Data()) as? [String: Any])?["exchange_query"] as? [String: Any]
        result["exchange_query_no_content_terms_delivers_no_evidence"] = empty.snapshot.evidence.isEmpty
            && emptyAudit?["skipped"] as? String == "no_query_terms"
        return result
    }

    /// Planner contracts on a synthetic in-memory index.
    private static func packedChecks(source: (String, String, MemoryRole, String, Int) -> ExchangeBlockQuery.Source) throws -> [String: Bool] {
        typealias Packing = ExchangeBlockQuery.ValuePacking
        var result: [String: Bool] = [:]
        let packed = try ContextComponentPolicy.selectedQwenExchangePacked.validated()
        let decoded = try JSONDecoder().decode(ContextComponentPolicy.self, from: packed.canonicalData())
        result["exchange_packed_policy_is_explicit_versioned_and_not_default"] = packed.usesExchangeQuery
            && packed.packsAdjacentExchanges && packed.packsExchangeValueDensity && decoded == packed
            && packed.version == "selected-model-context-components-v3-exchange-packed" && packed.evidenceSpans == 48
            && packed.evidenceTokens == 12_000 && packed.selectionAuditVersion == "context-exchange-v1"
            && packed != .selectedQwenExchangeAdjacent && ContextComponentPolicy.currentSelectedQwen == .selectedQwen
            && !ContextComponentPolicy.selectedQwenExchangeAdjacent.packsExchangeValueDensity
        result["exchange_packed_parameters_are_declared"] = Packing.candidateBlockDepth == 32 && Packing.memberWeight == 1.0
            && Packing.neighborWeight == 0.5 && Packing.admissionHeadroomBytes == 5_120
            && Packing.deliveryAuditLimitBytes == 32_768 && Packing.version == "exchange-value-density-v1"

        // c1: [p0] [h1 a1-long] [h2 a2]; c2: [k1 k1a]
        let longReply = "Synthetic long reply " + String(repeating: "filler ", count: 700) + " zebra"
        let index = ExchangeBlockQuery.Index(sources: [
            source("p0", "c1", .assistant, "Synthetic opening note", 1),
            source("h1", "c1", .human, "Synthetic zebra zebra habitat question", 2),
            source("a1", "c1", .assistant, longReply, 3),
            source("h2", "c1", .human, "Synthetic habitat follow-up", 4),
            source("a2", "c1", .assistant, "Synthetic short answer", 5),
            source("k1", "c2", .human, "Synthetic quoted anchor habitat", 6),
            source("k1a", "c2", .assistant, "Synthetic anchor reply", 7),
        ])
        func id(_ unit: Packing.Unit) -> String { index.sources[unit.source].reference.eventID }
        let version = ContextSourceFraming.currentSelectionVersion
        let ranked = index.rank(ExchangeBlockQuery.query("zebra habitat"))
        let units = Packing.candidates(index: index, ranked: ranked)
        let top = units.first?.units.map { $0.kind + ":" + id($0) }
        result["exchange_packed_candidate_units_are_chronological_with_neighbors"] = top == ["p:p0", "l:h1", "r:a1", "n:h2"]
            && units.count == min(ranked.count, Packing.candidateBlockDepth)
        // A tight token budget: short leads beat the long reply of the best block.
        let tight = try Packing.plan(index: index, ranked: ranked, maximumSpans: 48, tokenBudget: 900,
            auditBudget: 100_000, selectionVersion: version)
        let delivered = Set(tight.hits.map(\.eventID))
        let topCodes = Dictionary(uniqueKeysWithValues: zip(units[0].units.map(id), tight.codes[0]))
        result["exchange_packed_value_density_prefers_short_leads_over_long_replies"] = delivered.contains("h1")
            && delivered.contains("h2") && !delivered.contains("a1") && topCodes["a1"] == "T" && tight.estimatedTokens <= 900
        var codedDelivered = Set<String>()
        for (rank, row) in tight.codes.enumerated() {
            for (position, code) in row.enumerated() where code == "D" { codedDelivered.insert(id(units[rank].units[position])) }
        }
        result["exchange_packed_every_unit_is_receipted_and_delivery_is_rank_grouped"] = tight.codes.allSatisfy { $0.allSatisfy { $0 != "?" } }
            && tight.hits.first?.eventID == "h1" && zip(tight.owners, tight.owners.dropFirst()).allSatisfy { $0.rank <= $1.rank }
            && codedDelivered == delivered
        var dependentOK = true
        for (rank, block) in tight.blocks.enumerated() {
            let leadDelivered = block.units.contains { $0.kind == "l" && delivered.contains(id($0)) }
            for (position, unit) in block.units.enumerated() where unit.kind != "l" && tight.codes[rank][position] == "D" && !leadDelivered {
                dependentOK = false
            }
        }
        result["exchange_packed_dependent_units_need_their_lead"] = dependentOK
        // The audit-byte budget binds independently of tokens.
        let narrow = try Packing.plan(index: index, ranked: ranked, maximumSpans: 48, tokenBudget: 100_000,
            auditBudget: 900, selectionVersion: version)
        let narrowAudit = try narrow.hits.reduce(0) { $0 + (try Packing.auditEntryBytes($1, selectionVersion: version)) }
        result["exchange_packed_audit_byte_budget_binds_with_receipts"] = narrowAudit <= 900 && narrow.estimatedAuditBytes == narrowAudit
            && narrow.codes.joined().contains("A") && !narrow.hits.isEmpty
        let spanLimited = try Packing.plan(index: index, ranked: ranked, maximumSpans: 2, tokenBudget: 100_000,
            auditBudget: 100_000, selectionVersion: version)
        result["exchange_packed_span_cap_binds_with_receipts"] = spanLimited.hits.count == 2 && spanLimited.codes.joined().contains("S")
        // Quoted-anchor blocks are mandatory and placed first.
        let anchoredRank = index.rank(ExchangeBlockQuery.query("zebra \"quoted anchor\""))
        let anchored = try Packing.plan(index: index, ranked: anchoredRank, maximumSpans: 48, tokenBudget: 600,
            auditBudget: 100_000, selectionVersion: version)
        result["exchange_packed_quoted_anchor_members_are_mandatory_and_first"] = anchored.blocks.first?.anchors == 1
            && anchored.hits.prefix(2).map(\.eventID) == ["k1", "k1a"] && anchored.codes[0].contains("D")
        let audit = Packing.audit(plan: tight, index: index, matchedBlocks: ranked.count, tokenBudget: 900,
            auditBudget: 100_000, maximumSpans: 48)
        let auditBytes = try JSONSerialization.data(withJSONObject: audit)
        result["exchange_packed_candidate_audit_is_compact_and_content_free"] = auditBytes.range(of: Data("zebra".utf8)) == nil
            && auditBytes.range(of: Data("\"h1\"".utf8)) == nil
            && (audit["candidates"] as? [[Any]])?.count == units.count && Packing.candidateID("h1").count == 12
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
