import Foundation
import Darwin

/// Fixed public synthetic adjacency fixtures; reports contain booleans only.
enum ExchangeExpansionChecks {
    static func run() throws -> [String: Bool] {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-exchange-project"
        let archive = try store.createConversation(projectID: project, title: "Synthetic exchange sources")
        let unrelated = try store.createConversation(projectID: project, title: "Synthetic interleaved conversation")
        let chat = try store.createConversation(projectID: project, title: "Synthetic exchange request")
        func append(_ id: String, _ text: String, _ role: MemoryRole = .human, _ status: CaptureStatus = .complete,
            conversationID: String? = nil) throws -> MemoryEvent {
            try store.append(conversationID: conversationID ?? archive.id, role: role, text: text, status: status,
                turnID: "synthetic-independent-turn-" + id, eventID: id)
        }
        let anchor = try append("exchange-anchor-é", "Synthetic anchor")
        _ = try append("exchange-other-conversation", "Synthetic unrelated publication", .assistant, conversationID: unrelated.id)
        let neighbor = try append("exchange-neighbor-é", "Synthetic original assistant café e\u{301}", .assistant, .partial)
        let distinctAnchor = try append("exchange-anchor-e\u{301}", "Synthetic distinct anchor")
        let distinctNeighbor = try append("exchange-neighbor-e\u{301}", "Synthetic distinct original assistant", .assistant, .cancelled)
        let boundary = try append("exchange-boundary-anchor", "Synthetic boundary anchor")
        let nextHuman = try append("exchange-next-human", "Synthetic next request")
        let afterHuman = try append("exchange-after-human", "Synthetic subsequent response", .assistant)
        let excludedAnchor = try append("exchange-excluded-anchor", "Synthetic excluded boundary")
        let excludedNeighbor = try append("exchange-excluded-neighbor", "Synthetic excluded assistant", .assistant)
        let afterExcluded = try append("exchange-after-excluded", "Synthetic later assistant", .assistant)
        let longAnchor = try append("exchange-long-anchor", "Synthetic long prefix anchor")
        let longNeighbor = try append("exchange-long-neighbor", String(repeating: "x", count: 4095) + "é" + "tail", .assistant, .failed)
        let emptyAnchor = try append("exchange-empty-anchor", "Synthetic empty neighbor anchor")
        _ = try append("exchange-empty-neighbor", "", .assistant, .failed)
        let lineAnchor = try append("exchange-line-anchor", "Synthetic long single-line anchor")
        let lineNeighbor = try append("exchange-line-neighbor", String(repeating: "L", count: 1894), .assistant)
        var cappedAnchors: [MemoryEvent] = [], cappedNeighbors: [MemoryEvent] = []
        for ordinal in 0..<9 {
            cappedAnchors.append(try append("exchange-cap-anchor-\(ordinal)", "Synthetic ranked anchor"))
            cappedNeighbors.append(try append("exchange-cap-neighbor-\(ordinal)", "Synthetic ranked assistant", .assistant))
        }
        let tailAnchor = try append("exchange-tail-anchor", "Synthetic frozen frontier anchor")
        let frontier = try store.sourceFrontier(projectID: project)
        let future = try append("exchange-future", "Synthetic post-frontier assistant", .assistant)
        let foreignChat = try store.createConversation(projectID: "synthetic-foreign-project", title: "Synthetic foreign scope")
        let foreign = try append("exchange-foreign", "Synthetic foreign source", conversationID: foreignChat.id)
        let clock = Clock(), episodeID = UUID().uuidString, currentID = "exchange-current-request"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "synthetic-exchange-request-turn",
            humanEventID: currentID, episodeID: episodeID, text: "Synthetic exchange request", limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        func expand(_ primary: [MemoryHit], exclusions: [String] = [], upper: Int? = nil,
            nested: Bool = false) throws -> ExchangeExpansionReport {
            try MeteredExchangeExpansion.expand(store: store, projectID: project, primaryHits: primary,
                sourceFrontier: upper ?? frontier, excludingSourceIDs: ExactSourceIDs(exclusions + [currentID]),
                episodeLease: lease, operationIsNested: nested)
        }
        let before = try lease.checkActive(), first = try expand([hit(anchor)]), after = try lease.checkActive()
        let auditBytes = try JSONSerialization.data(withJSONObject: first.audit)
        var checks: [String: Bool] = [
            "exchange_immediate_same_conversation_assistant_preserves_original_bytes_status_and_scope": first.hits.count == 2
                && first.hits.map { Data($0.eventID.utf8) } == [Data(anchor.id.utf8), Data(neighbor.id.utf8)]
                && first.hits[1].excerpt.utf8.elementsEqual(neighbor.text.utf8) && first.hits[1].excerptOffset == 0
                && first.hits[1].digest == neighbor.digest && first.hits[1].totalBytes == neighbor.byteCount
                && first.hits[1].status == .partial && first.hits[1].projectID == project && first.hits[1].conversationID == archive.id,
            "exchange_original_lease_prefunds_exact_metadata_page_and_operation_recipe": after.id == before.id
                && after.limits == before.limits && after.charged.memoryOperations - before.charged.memoryOperations == 1
                && after.charged.metadataRows - before.charged.metadataRows == 4
                && after.charged.rawSourceBytes - before.charged.rawSourceBytes == 2 * (neighbor.byteCount + 1)
                && after.charged.modelCalls == before.charged.modelCalls && after.charged.encoderInputBytes == before.charged.encoderInputBytes,
            "exchange_audit_reports_prefix_adjacency_without_source_text": first.audit["version"] as? String == "following-assistant-prefix-v2"
                && first.audit["added_neighbor_count"] as? Int == 1 && first.audit["prefix_truncated_count"] as? Int == 0
                && auditBytes.range(of: Data(neighbor.text.utf8)) == nil
        ]
        let repeatedBefore = try lease.checkActive()
        _ = try expand([hit(anchor)])
        let repeatedAfter = try lease.checkActive()
        checks["exchange_repeated_prefix_reads_retain_new_debits_without_refund"] = repeatedAfter.charged.rawSourceBytes - repeatedBefore.charged.rawSourceBytes
            == 2 * (neighbor.byteCount + 1) && repeatedAfter.charged.metadataRows - repeatedBefore.charged.metadataRows == 4
        let ordered = try expand([hit(anchor), hit(distinctAnchor)])
        checks["exchange_rank_interleaving_and_utf8_distinct_ids_are_exact"] = ordered.hits.map { Data($0.eventID.utf8) }
            == [anchor, neighbor, distinctAnchor, distinctNeighbor].map { Data($0.id.utf8) }
            && ordered.hits[3].status == .cancelled
        let stopped = try expand([hit(boundary)])
        checks["exchange_next_human_is_boundary_without_skipping_to_later_assistant"] = stopped.hits.map(\.eventID) == [boundary.id]
            && disposition(stopped) == "human_boundary" && !stopped.hits.contains { $0.eventID == afterHuman.id }
            && decisionNeighbor(stopped) == nextHuman.id
        let excludedBefore = try lease.checkActive(), excluded = try expand([hit(excludedAnchor)], exclusions: [excludedNeighbor.id])
        checks["exchange_excluded_recent_neighbor_has_no_payload_read_or_forward_skip"] = try excluded.hits.map(\.eventID) == [excludedAnchor.id]
            && disposition(excluded) == "excluded_neighbor" && !excluded.hits.contains { $0.eventID == afterExcluded.id }
            && lease.checkActive().charged.rawSourceBytes == excludedBefore.charged.rawSourceBytes
        let assistantBefore = try lease.checkActive(), assistantOnly = try expand([hit(neighbor)])
        checks["exchange_assistant_primary_does_not_expand_forward"] = try assistantOnly.hits.map(\.eventID) == [neighbor.id]
            && lease.checkActive().charged.metadataRows - assistantBefore.charged.metadataRows == 1
            && lease.checkActive().charged.rawSourceBytes == assistantBefore.charged.rawSourceBytes
        let prefixBefore = try lease.checkActive(), prefixed = try expand([hit(longAnchor)]), prefixAfter = try lease.checkActive()
        checks["exchange_oversized_assistant_uses_scalar_safe_prefix_with_original_total_and_digest"] = prefixed.hits.count == 2
            && prefixed.hits[1].excerpt.utf8.count == 4095 && prefixed.hits[1].excerpt == String(repeating: "x", count: 4095)
            && prefixed.hits[1].totalBytes == longNeighbor.byteCount && prefixed.hits[1].digest == longNeighbor.digest
            && prefixed.hits[1].status == .failed && prefixed.audit["prefix_truncated_count"] as? Int == 1
            && prefixAfter.charged.rawSourceBytes - prefixBefore.charged.rawSourceBytes == 2 * 4097
        let emptyBefore = try lease.checkActive(), empty = try expand([hit(emptyAnchor)])
        checks["exchange_empty_assistant_is_explicit_and_never_reads_payload"] = try empty.hits.map(\.eventID) == [emptyAnchor.id]
            && disposition(empty) == "empty_neighbor" && lease.checkActive().charged.rawSourceBytes == emptyBefore.charged.rawSourceBytes
        let frozen = try expand([hit(tailAnchor)])
        checks["exchange_frozen_frontier_does_not_include_later_publication"] = frozen.hits.map(\.eventID) == [tailAnchor.id]
            && disposition(frozen) == "no_neighbor" && frozen.audit["source_frontier"] as? Int == frontier
        let selectedSpan = hit(neighbor, offset: 10, excerpt: String(neighbor.text.dropFirst(10)))
        let primaryNeighborBefore = try lease.checkActive(), primaryNeighbor = try expand([hit(anchor), selectedSpan])
        checks["exchange_nonzero_primary_span_preserved_alongside_funded_complete_prefix"] = try primaryNeighbor.hits.count == 3
            && primaryNeighbor.hits[1].excerptOffset == 0 && primaryNeighbor.hits[1].excerpt.utf8.elementsEqual(neighbor.text.utf8)
            && primaryNeighbor.hits[2].excerptOffset == 10 && primaryNeighbor.hits[2].excerpt.utf8.elementsEqual(selectedSpan.excerpt.utf8)
            && disposition(primaryNeighbor) == "included_prefix"
            && lease.checkActive().charged.rawSourceBytes - primaryNeighborBefore.charged.rawSourceBytes == 2 * (neighbor.byteCount + 1)
            && lease.checkActive().charged.metadataRows - primaryNeighborBefore.charged.metadataRows == 5
        let shortLineSpan = hit(lineNeighbor, excerpt: String(lineNeighbor.text.prefix(560)))
        let shortBefore = try lease.checkActive(), short = try expand([hit(lineAnchor), shortLineSpan]), shortAfter = try lease.checkActive()
        checks["exchange_short_offset_zero_primary_cannot_suppress_long_single_line_prefix"] = short.hits.map(\.eventID)
            == [lineAnchor.id, lineNeighbor.id, lineNeighbor.id] && short.hits.map { $0.excerpt.utf8.count } == [lineAnchor.byteCount, 1894, 560]
            && short.hits[1].excerpt.utf8.elementsEqual(lineNeighbor.text.utf8) && short.audit["added_neighbor_count"] as? Int == 1
            && shortAfter.charged.rawSourceBytes - shortBefore.charged.rawSourceBytes == 2 * 1895
            && shortAfter.charged.metadataRows - shortBefore.charged.metadataRows == 5
        let wholeBefore = try lease.checkActive(), whole = try expand([hit(anchor), hit(neighbor)]), wholeAfter = try lease.checkActive()
        checks["exchange_complete_future_primary_is_promoted_once_without_extra_payload_read"] = whole.hits.map(\.eventID) == [anchor.id, neighbor.id]
            && whole.hits[1].excerpt.utf8.elementsEqual(neighbor.text.utf8) && whole.audit["promoted_primary_count"] as? Int == 1
            && whole.audit["retained_primary_count"] as? Int == 2 && whole.audit["dropped_primary_count"] as? Int == 0
            && whole.audit["added_neighbor_count"] as? Int == 0 && disposition(whole) == "promoted_primary"
            && wholeAfter.charged.rawSourceBytes == wholeBefore.charged.rawSourceBytes
            && wholeAfter.charged.metadataRows - wholeBefore.charged.metadataRows == 3
        let retainedBefore = try lease.checkActive(), covered = try expand([hit(neighbor), hit(anchor)]), retainedAfter = try lease.checkActive()
        checks["exchange_already_retained_complete_prefix_suppresses_new_read"] = covered.hits.map(\.eventID) == [neighbor.id, anchor.id]
            && disposition(covered) == "covered_neighbor_prefix" && covered.audit["promoted_primary_count"] as? Int == 0
            && retainedAfter.charged.rawSourceBytes == retainedBefore.charged.rawSourceBytes
            && retainedAfter.charged.metadataRows - retainedBefore.charged.metadataRows == 4
        let disjoint = hit(longNeighbor, offset: 4097, excerpt: "tail")
        let disjointBefore = try lease.checkActive(), disjointResult = try expand([hit(longAnchor), disjoint]), disjointAfter = try lease.checkActive()
        checks["exchange_disjoint_primary_range_retained_with_scalar_safe_prefix"] = disjointResult.hits.count == 3
            && disjointResult.hits[1].excerpt.utf8.count == 4095 && disjointResult.hits[2].excerptOffset == 4097
            && disjointResult.hits[2].excerpt == "tail" && disjointResult.audit["promoted_primary_count"] as? Int == 0
            && disjointAfter.charged.rawSourceBytes - disjointBefore.charged.rawSourceBytes == 2 * 4097
            && disjointAfter.charged.metadataRows - disjointBefore.charged.metadataRows == 5
        let promotedTailBefore = try lease.checkActive()
        let promotedTail = try expand([hit(anchor)] + cappedAnchors.prefix(8).map { hit($0) } + [hit(neighbor)])
        let promotedTailAfter = try lease.checkActive()
        checks["exchange_future_tail_primary_promoted_before_candidate_cap_can_drop_it"] = promotedTail.hits.count == 16
            && Array(promotedTail.hits.prefix(2)).map(\.eventID) == [anchor.id, neighbor.id]
            && promotedTail.audit["promoted_primary_count"] as? Int == 1 && promotedTail.audit["retained_primary_count"] as? Int == 9
            && promotedTail.audit["dropped_primary_count"] as? Int == 1 && promotedTail.audit["added_neighbor_count"] as? Int == 7
            && promotedTailAfter.charged.rawSourceBytes - promotedTailBefore.charged.rawSourceBytes == 7 * 2 * (cappedNeighbors[0].byteCount + 1)
            && promotedTailAfter.charged.metadataRows - promotedTailBefore.charged.metadataRows == 31
        let shortTail = try expand([hit(lineAnchor)] + cappedAnchors.prefix(8).map { hit($0) } + [shortLineSpan])
        checks["exchange_insufficient_dropped_tail_primary_does_not_suppress_complete_prefix"] = shortTail.hits.count == 16
            && shortTail.hits[1].eventID == lineNeighbor.id && shortTail.hits[1].excerpt.utf8.elementsEqual(lineNeighbor.text.utf8)
            && shortTail.audit["promoted_primary_count"] as? Int == 0 && shortTail.audit["added_neighbor_count"] as? Int == 8
            && shortTail.audit["retained_primary_count"] as? Int == 8 && shortTail.audit["dropped_primary_count"] as? Int == 2
        let distinctSpanBefore = try lease.checkActive()
        let distinctSpans = try expand([hit(neighbor), selectedSpan, selectedSpan])
        let distinctSpanAfter = try lease.checkActive()
        checks["exchange_distinct_primary_ranges_preserved_and_identical_span_deduplicated"] = distinctSpans.hits.count == 2
            && distinctSpans.hits.map(\.excerptOffset) == [0, 10]
            && distinctSpans.hits[0].excerpt.utf8.elementsEqual(neighbor.text.utf8)
            && distinctSpans.hits[1].excerpt.utf8.elementsEqual(selectedSpan.excerpt.utf8)
            && distinctSpans.audit["retained_primary_count"] as? Int == 2 && distinctSpans.audit["dropped_primary_count"] as? Int == 1
            && distinctSpanAfter.charged.rawSourceBytes == distinctSpanBefore.charged.rawSourceBytes
            && distinctSpanAfter.charged.metadataRows - distinctSpanBefore.charged.metadataRows == 2
        let secondAnchorSpan = hit(anchor, offset: 10, excerpt: String(anchor.text.dropFirst(10)))
        let repeatedAnchorBefore = try lease.checkActive(), repeatedAnchor = try expand([hit(anchor), secondAnchorSpan])
        let repeatedAnchorAfter = try lease.checkActive()
        checks["exchange_distinct_anchor_spans_expand_same_neighbor_only_once"] = repeatedAnchor.hits.map(\.eventID) == [anchor.id, neighbor.id, anchor.id]
            && repeatedAnchor.hits[2].excerptOffset == 10 && repeatedAnchor.audit["added_neighbor_count"] as? Int == 1
            && repeatedAnchorAfter.charged.rawSourceBytes - repeatedAnchorBefore.charged.rawSourceBytes == 2 * (neighbor.byteCount + 1)
            && repeatedAnchorAfter.charged.metadataRows - repeatedAnchorBefore.charged.metadataRows == 5
        let excludedPrimaryBefore = try lease.checkActive(), excludedPrimary = try expand([hit(anchor)], exclusions: [anchor.id])
        checks["exchange_excluded_primary_does_not_read_metadata_or_payload"] = try excludedPrimary.hits.isEmpty
            && disposition(excludedPrimary) == "excluded_primary" && lease.checkActive().charged.metadataRows == excludedPrimaryBefore.charged.metadataRows
            && lease.checkActive().charged.rawSourceBytes == excludedPrimaryBefore.charged.rawSourceBytes
        let nestedBefore = try lease.checkActive()
        _ = try expand([hit(neighbor)], nested: true)
        checks["exchange_nested_composite_retains_original_operation_allowance"] = try lease.checkActive().charged.memoryOperations == nestedBefore.charged.memoryOperations
        let cappedBefore = try lease.checkActive(), capped = try expand(cappedAnchors.map { hit($0) }), cappedAfter = try lease.checkActive()
        let expectedCappedIDs = (0..<8).flatMap { [cappedAnchors[$0].id, cappedNeighbors[$0].id] }
        checks["exchange_candidate_cap_interleaves_first_ranked_pairs_and_reports_dropped_primary"] = capped.hits.map(\.eventID) == expectedCappedIDs
            && capped.hits.count == 16 && capped.audit["primary_count"] as? Int == 9
            && capped.audit["retained_primary_count"] as? Int == 8 && capped.audit["dropped_primary_count"] as? Int == 1
            && capped.audit["added_neighbor_count"] as? Int == 8
        checks["exchange_candidate_cap_never_reads_dropped_primary_or_its_neighbor"] = cappedAfter.charged.metadataRows - cappedBefore.charged.metadataRows == 32
            && cappedAfter.charged.rawSourceBytes - cappedBefore.charged.rawSourceBytes == 8 * 2 * (cappedNeighbors[0].byteCount + 1)
        let duplicate = try expand([hit(anchor), hit(anchor)])
        checks["exchange_duplicate_primary_keeps_one_original_and_one_prefix_with_explicit_count"] = duplicate.hits.map(\.eventID) == [anchor.id, neighbor.id]
            && duplicate.audit["retained_primary_count"] as? Int == 1 && duplicate.audit["dropped_primary_count"] as? Int == 1
        let futureBefore = try lease.checkActive()
        do {
            _ = try expand([hit(future)]); checks["exchange_future_primary_refused_before_payload"] = false
        } catch {
            checks["exchange_future_primary_refused_before_payload"] = try error is MeteredRetrievalError
                && lease.checkActive().charged.rawSourceBytes == futureBefore.charged.rawSourceBytes
                && lease.checkActive().charged.metadataRows == futureBefore.charged.metadataRows + 1
        }
        let foreignBefore = try lease.checkActive()
        do {
            _ = try expand([hit(foreign)]); checks["exchange_foreign_project_primary_refused_before_funding_or_payload"] = false
        } catch {
            checks["exchange_foreign_project_primary_refused_before_funding_or_payload"] = try error is MeteredRetrievalError
                && lease.checkActive().charged == foreignBefore.charged
        }
        let forged = MemoryHit(eventID: foreign.id, conversationID: foreign.conversationID, projectID: project, role: foreign.role,
            status: foreign.status, createdAt: foreign.createdAt, digest: foreign.digest, totalBytes: foreign.byteCount, excerptOffset: 0, excerpt: foreign.text)
        do {
            _ = try expand([forged]); checks["exchange_forged_scope_refused_before_payload"] = false
        } catch {
            checks["exchange_forged_scope_refused_before_payload"] = try error is MeteredRetrievalError
                && lease.checkActive().charged.rawSourceBytes == foreignBefore.charged.rawSourceBytes
        }
        _ = try lease.finish(reason: .cancelled)
        let terminal = try store.episodeReceipt(id: episodeID, clock: clock.now())
        do {
            _ = try expand([hit(anchor)]); checks["exchange_terminal_lease_cannot_renew_prefix_budget"] = false
        } catch {
            checks["exchange_terminal_lease_cannot_renew_prefix_budget"] = try error is EpisodeBudgetError
                && store.episodeReceipt(id: episodeID, clock: clock.now()).charged == terminal.charged
        }
        checks.merge(try exhaustionChecks(store: store, chat: chat, project: project, anchor: anchor, frontier: frontier, clock: clock)) { _, latest in latest }
        return checks
    }

    private static func exhaustionChecks(store: MemoryStore, chat: StoredConversation, project: String,
        anchor: MemoryEvent, frontier: Int, clock: Clock) throws -> [String: Bool] {
        var limits = EpisodeLimits(); limits.resources.rawSourceBytes = 0
        let id = UUID().uuidString
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "synthetic-exchange-exhaustion-turn",
            humanEventID: "exchange-exhaustion-request", episodeID: id, text: "Synthetic exhausted prefix request", limits: limits, clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: id, clock: clock)
        let before = try lease.checkActive()
        do {
            _ = try MeteredExchangeExpansion.expand(store: store, projectID: project, primaryHits: [hit(anchor)], sourceFrontier: frontier,
                excludingSourceIDs: ExactSourceIDs([]), episodeLease: lease)
            return ["exchange_raw_exhaustion_refuses_prefix_and_retains_prior_attempt_debits": false]
        } catch {
            let after = try store.episodeReceipt(id: id, clock: clock.now())
            return ["exchange_raw_exhaustion_refuses_prefix_and_retains_prior_attempt_debits": (error as? EpisodeBudgetError) == .exhausted
                && after.charged.rawSourceBytes == before.charged.rawSourceBytes
                && after.charged.metadataRows == before.charged.metadataRows + 4
                && after.charged.memoryOperations == before.charged.memoryOperations + 1 && after.limits == limits]
        }
    }
    private static func hit(_ source: MemoryEvent, offset: Int = 0, excerpt: String? = nil) -> MemoryHit {
        MemoryHit(eventID: source.id, conversationID: source.conversationID, projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: source.digest, totalBytes: source.byteCount,
            excerptOffset: offset, excerpt: excerpt ?? source.text)
    }
    private static func disposition(_ report: ExchangeExpansionReport) -> String? {
        (report.audit["decisions"] as? [[String: Any]])?.first?["disposition"] as? String
    }
    private static func decisionNeighbor(_ report: ExchangeExpansionReport) -> String? {
        (report.audit["decisions"] as? [[String: Any]])?.first?["neighbor_event_id"] as? String
    }
    private static func fixtureDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw MeteredRetrievalError.invalid }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent("boros-exchange-checks-" + UUID().uuidString)
    }
    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-exchange-clock", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }
}
