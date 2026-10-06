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
        let originalDate = EventSourceTime(value: "2023-05-30T10:42", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "a", count: 64), locator: "/synthetic/message/timestamp", originalValue: "2023/05/30 (Tue) 10:42")
        func append(_ id: String, _ text: String, _ role: MemoryRole = .human, _ status: CaptureStatus = .complete,
            conversationID: String? = nil) throws -> MemoryEvent {
            try store.append(conversationID: conversationID ?? archive.id, role: role, text: text, status: status,
                turnID: "synthetic-independent-turn-" + id, eventID: id,
                sourceTime: id == "exchange-neighbor-é" ? originalDate : nil)
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
        checks["exchange_following_assistant_preserves_calendar_evidence"] = first.hits[1].sourceTime == originalDate
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
        checks.merge(try completionChecks()) { _, latest in latest }
        return checks
    }

    private static func completionChecks() throws -> [String: Bool] {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-primary-completion"
        let archive = try store.createConversation(projectID: project, title: "Synthetic short sources")
        let chat = try store.createConversation(projectID: project, title: "Synthetic completion request")
        let date = EventSourceTime(value: "2023-05-30T10:42", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "b", count: 64), locator: "/synthetic/date", originalValue: "2023/05/30 (Tue) 10:42")
        let source = try store.append(conversationID: archive.id, role: .assistant, text: "é\u{0}before needle after e\u{301}",
            status: .partial, turnID: "short-source-turn", eventID: "short-source", sourceTime: date)
        let exact = try store.append(conversationID: archive.id, role: .human, text: String(repeating: "a", count: 4096),
            status: .complete, turnID: "exact-page-turn", eventID: "exact-page")
        let long = try store.append(conversationID: archive.id, role: .human, text: String(repeating: "b", count: 4097),
            status: .complete, turnID: "long-page-turn", eventID: "long-page")
        let frontier = try store.sourceFrontier(projectID: project)
        let future = try store.append(conversationID: archive.id, role: .human, text: "Synthetic future",
            status: .complete, turnID: "future-turn", eventID: "future-short-source")
        let foreignChat = try store.createConversation(projectID: "foreign-completion", title: "Synthetic foreign")
        let foreign = try store.append(conversationID: foreignChat.id, role: .human, text: "Synthetic foreign",
            status: .complete, turnID: "foreign-turn", eventID: "foreign-short-source")
        let clock = Clock(), id = UUID().uuidString
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "completion-turn", humanEventID: "completion-request",
            episodeID: id, text: "Synthetic completion request", limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: id, clock: clock)
        func complete(_ hits: [MemoryHit], excluded: [String] = [], nested: Bool = false) throws -> ExchangeExpansionReport {
            try MeteredExchangeExpansion.completeShortPrimaries(store: store, projectID: project, primaryHits: hits,
                sourceFrontier: frontier, excludingSourceIDs: ExactSourceIDs(excluded), episodeLease: lease, operationIsNested: nested)
        }
        let fragment = hit(source, offset: 10, excerpt: "needle")
        let before = try lease.checkActive(), report = try complete([fragment]), after = try lease.checkActive()
        let completionAudit = try JSONSerialization.data(withJSONObject: report.audit)
        var checks: [String: Bool] = [
            "primary_completion_preserves_complete_original_utf8_nul_scope_date_and_partial_status": report.hits.count == 1
                && Data(report.hits[0].excerpt.utf8) == Data(source.text.utf8) && report.hits[0].excerptOffset == 0
                && report.hits[0].totalBytes == source.byteCount && report.hits[0].digest == source.digest
                && report.hits[0].sourceTime == date && report.hits[0].status == .partial
                && report.hits[0].conversationID == archive.id && report.hits[0].projectID == project,
            "primary_completion_prefunds_original_lease_without_model_or_encoder_work": after.id == before.id && after.limits == before.limits
                && after.charged.rawSourceBytes - before.charged.rawSourceBytes == 3 * (source.byteCount + 1)
                && after.charged.metadataRows - before.charged.metadataRows == 2
                && after.charged.memoryOperations - before.charged.memoryOperations == 1
                && after.charged.modelCalls == before.charged.modelCalls && after.charged.encoderInputBytes == before.charged.encoderInputBytes,
            "primary_completion_audit_contains_only_identity_counts_and_disposition": report.audit["completed_primary_count"] as? Int == 1
                && completionAudit.range(of: Data(source.text.utf8)) == nil
        ]
        let retainedBefore = try lease.checkActive(), retained = try complete([hit(source)]), retainedAfter = try lease.checkActive()
        checks["primary_completion_full_source_is_retained_without_payload_read"] = retained.hits[0].excerpt == source.text
            && retainedAfter.charged.rawSourceBytes == retainedBefore.charged.rawSourceBytes
        let boundary = try complete([hit(exact, offset: 1, excerpt: "a"), hit(long, offset: 1, excerpt: "b")])
        checks["primary_completion_exact_page_is_complete_and_larger_source_remains_fragment"] = boundary.hits[0].excerpt.utf8.count == 4096
            && boundary.hits[0].excerptOffset == 0 && boundary.hits[1].excerpt == "b" && boundary.hits[1].excerptOffset == 1
        let excludedBefore = try lease.checkActive(), excluded = try complete([fragment], excluded: [source.id]), excludedAfter = try lease.checkActive()
        checks["primary_completion_exclusion_precedes_metadata_and_payload"] = excluded.hits.isEmpty
            && excludedBefore.charged.metadataRows == excludedAfter.charged.metadataRows && excludedBefore.charged.rawSourceBytes == excludedAfter.charged.rawSourceBytes
        for (name, bad, expectedRaw) in [
            ("corrupt_fragment", hit(source, offset: 10, excerpt: "broken"), 3 * (source.byteCount + 1)),
            ("split_scalar_empty_fragment", hit(source, offset: 1, excerpt: ""), 3 * (source.byteCount + 1)),
            ("future_source", hit(future, offset: 0, excerpt: "Synthetic"), 0),
            ("foreign_source", hit(foreign, offset: 0, excerpt: "Synthetic"), 0)
        ] {
            let prior = try lease.checkActive()
            do { _ = try complete([bad]); checks["primary_completion_refuses_" + name] = false }
            catch {
                let current = try lease.checkActive()
                checks["primary_completion_refuses_" + name] = error is MeteredRetrievalError
                    && current.charged.rawSourceBytes - prior.charged.rawSourceBytes == expectedRaw
            }
        }
        let forged = MemoryHit(eventID: source.id, conversationID: chat.id, projectID: project, role: source.role, status: source.status,
            createdAt: source.createdAt, digest: source.digest, totalBytes: source.byteCount, excerptOffset: 10, excerpt: "needle", sourceTime: date)
        do { _ = try complete([forged]); checks["primary_completion_refuses_forged_conversation"] = false }
        catch { checks["primary_completion_refuses_forged_conversation"] = error is MeteredRetrievalError }
        let duplicate = try complete([fragment, fragment])
        checks["primary_completion_duplicate_fragments_are_each_verified_and_remain_bounded"] = duplicate.hits.count == 2
            && duplicate.hits.allSatisfy { Data($0.excerpt.utf8) == Data(source.text.utf8) }
        do { _ = try complete(Array(repeating: fragment, count: 17)); checks["primary_completion_candidate_limit_is_unchanged"] = false }
        catch { checks["primary_completion_candidate_limit_is_unchanged"] = error is MeteredRetrievalError }
        let nestedBefore = try lease.checkActive(); _ = try complete([fragment], nested: true); let nestedAfter = try lease.checkActive()
        checks["primary_completion_nested_operation_does_not_duplicate_operation_charge"] = nestedBefore.charged.memoryOperations == nestedAfter.charged.memoryOperations
        _ = try lease.finish(reason: .cancelled)
        do { _ = try complete([fragment]); checks["primary_completion_terminal_lease_refuses_work"] = false }
        catch { checks["primary_completion_terminal_lease_refuses_work"] = error is EpisodeBudgetError }
        var limits = EpisodeLimits(); limits.resources.rawSourceBytes = 0
        let exhaustedID = UUID().uuidString
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "completion-exhausted-turn", humanEventID: "completion-exhausted-request",
            episodeID: exhaustedID, text: "Synthetic exhausted completion", limits: limits, clock: clock.now())
        let exhaustedLease = EpisodeLease(ledger: store, episodeID: exhaustedID, clock: clock)
        let prior = try exhaustedLease.checkActive()
        do {
            _ = try MeteredExchangeExpansion.completeShortPrimaries(store: store, projectID: project, primaryHits: [fragment],
                sourceFrontier: frontier, excludingSourceIDs: ExactSourceIDs([]), episodeLease: exhaustedLease)
            checks["primary_completion_raw_exhaustion_retains_prior_metadata_and_operation_charges"] = false
        } catch {
            let current = try store.episodeReceipt(id: exhaustedID, clock: clock.now())
            checks["primary_completion_raw_exhaustion_retains_prior_metadata_and_operation_charges"] = (error as? EpisodeBudgetError) == .exhausted
                && current.charged.rawSourceBytes == prior.charged.rawSourceBytes && current.charged.metadataRows == prior.charged.metadataRows + 2
                && current.charged.memoryOperations == prior.charged.memoryOperations + 1
        }
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
            excerptOffset: offset, excerpt: excerpt ?? source.text, sourceTime: source.sourceTime)
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
