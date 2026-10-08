import Foundation
import Darwin

/// Only fixed synthetic sources enter these fixtures. The entrypoint returns
/// named booleans and never reports source payloads or exception descriptions.
enum NeighborhoodExpansionChecks {
    static func run() -> [String: Bool] {
        do { return try checks() }
        catch { return ["neighborhood_fixture_setup_and_execution": false] }
    }

    private static func checks() throws -> [String: Bool] {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = fixture.store, project = fixture.project
        let archive = try fixture.conversation("ordinary")
        let prior = try fixture.append("prior-assistant", "Synthetic prior assistant", .assistant, archive)
        let human = try fixture.append("human-anchor", "Synthetic human anchor", .human, archive)
        let interleaved = try fixture.conversation("interleaved")
        let unrelated = try fixture.append("unrelated", "Synthetic unrelated publication", .assistant, interleaved)
        let assistant = try fixture.append("assistant-anchor", "Synthetic assistant anchor", .assistant, archive, .partial)
        let date = EventSourceTime(value: "2023-05-30T10:42", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "a", count: 64), locator: "/synthetic/neighbor/timestamp",
            originalValue: "2023/05/30 (Tue) 10:42")
        let correction = try fixture.append("correction-é", "Synthetic human café e\u{301}\u{0} correction", .human,
            archive, .cancelled, date)
        let later = try fixture.append("later-assistant", "Synthetic later assistant", .assistant, archive, .failed)

        let cap = try fixture.conversation("cap")
        var ranked: [MemoryEvent] = [], neighbors: [MemoryEvent] = []
        // Separate conversations give every primary two unique neighbors.
        // Sixteen primaries and thirty-two neighbors exercise the actual cap.
        for rank in 0..<16 {
            let conversation = try fixture.conversation("rank-\(rank)")
            neighbors.append(try fixture.append("rank-\(rank)-previous", "Synthetic previous answer \(rank)", .assistant, conversation))
            ranked.append(try fixture.append("rank-\(rank)-primary", "Synthetic ranked request \(rank)", .human, conversation))
            neighbors.append(try fixture.append("rank-\(rank)-next", "Synthetic next answer \(rank)", .assistant, conversation))
        }
        _ = try fixture.append("unused-cap-source", "Synthetic unused source", .human, cap)
        let longConversation = try fixture.conversation("long")
        let left = try fixture.append("long-left", "Synthetic prefix request", .human, longConversation)
        let long = try fixture.append("long-assistant", String(repeating: "x", count: 4095) + "é" + "tail",
            .assistant, longConversation, .failed)
        let right = try fixture.append("long-right", "Synthetic subsequent request", .human, longConversation)
        let boundaryConversation = try fixture.conversation("boundary")
        let boundary = try fixture.append("boundary-anchor", "Synthetic boundary request", .human, boundaryConversation)
        let sameRole = try fixture.append("same-role-boundary", "Synthetic intervening human", .human, boundaryConversation)
        let beyondBoundary = try fixture.append("beyond-boundary", "Synthetic later answer", .assistant, boundaryConversation)
        let emptyConversation = try fixture.conversation("empty")
        let emptyAnchor = try fixture.append("empty-anchor", "Synthetic empty-neighbor request", .human, emptyConversation)
        let empty = try fixture.append("empty-assistant", "", .assistant, emptyConversation, .failed)
        let unicodeConversation = try fixture.conversation("unicode")
        let composed = try fixture.append("unicode-é", "Synthetic composed request", .human, unicodeConversation)
        let decomposed = try fixture.append("unicode-e\u{301}", "Synthetic decomposed answer", .assistant, unicodeConversation)
        let futureConversation = try fixture.conversation("frontier")
        let frozen = try fixture.append("frozen-anchor", "Synthetic frozen request", .human, futureConversation)
        let frontier = try store.sourceFrontier(projectID: project)
        let future = try fixture.append("future-assistant", "Synthetic future answer", .assistant, futureConversation)
        let foreignConversation = try store.createConversation(projectID: "synthetic-neighborhood-foreign", title: "Synthetic foreign scope")
        let foreign = try fixture.append("foreign-source", "Synthetic foreign source", .assistant, foreignConversation)

        func expand(_ primary: [MemoryHit], exclusions: [String] = [], upper: Int? = nil,
            nested: Bool = false, lease: EpisodeLease? = nil) throws -> ExchangeExpansionReport {
            let active = try lease ?? fixture.lease()
            return try BoundedNeighborhoodExpansion.expand(store: store, projectID: project, primaryHits: primary,
                sourceFrontier: upper ?? frontier, excludingSourceIDs: ExactSourceIDs(exclusions),
                episodeLease: active, operationIsNested: nested)
        }
        func rejected(_ primary: [MemoryHit], exclusions: [String] = [], upper: Int? = nil) throws -> Bool {
            let lease = try fixture.lease(), before = try lease.checkActive()
            do { _ = try expand(primary, exclusions: exclusions, upper: upper, lease: lease); return false }
            catch {
                let after = try store.episodeReceipt(id: before.id, clock: fixture.clock.now())
                return error is MeteredRetrievalError && after.charged.rawSourceBytes == before.charged.rawSourceBytes
            }
        }

        let lease = try fixture.lease(), before = try lease.checkActive()
        let bidirectional = try expand([hit(human)], lease: lease), after = try lease.checkActive()
        let expectedRaw = 2 * (prior.byteCount + 1 + assistant.byteCount + 1)
        let auditBytes = try JSONSerialization.data(withJSONObject: bidirectional.audit)
        var result: [String: Bool] = [
            "neighborhood_human_primary_reads_previous_and_next_assistant": exactIDs(bidirectional.hits) == exactIDs([human, prior, assistant]),
            "neighborhood_same_conversation_adjacency_ignores_interleaved_publications": !bidirectional.hits.contains { episodeIdentifierEqual($0.eventID, unrelated.id) },
            "neighborhood_original_lease_and_limits_preserved": before.id == after.id && before.limits == after.limits,
            "neighborhood_metadata_and_raw_pages_prefunded_exactly": after.charged.metadataRows - before.charged.metadataRows == 7
                && after.charged.rawSourceBytes - before.charged.rawSourceBytes == expectedRaw,
            "neighborhood_one_composite_operation_and_no_provider_or_encoder_calls": after.charged.memoryOperations - before.charged.memoryOperations == 1
                && after.charged.modelCalls == before.charged.modelCalls && after.charged.httpAttempts == before.charged.httpAttempts
                && after.charged.encoderInputBytes == before.charged.encoderInputBytes && after.charged.vectorBytes == before.charged.vectorBytes,
            "neighborhood_versioned_audit_contains_no_source_payload": bidirectional.audit["version"] as? String == BoundedNeighborhoodExpansion.version
                && [human, prior, assistant].allSatisfy { auditBytes.range(of: Data($0.text.utf8)) == nil }
        ]
        let defaultPolicy = try ContextComponentPolicy.currentSelectedQwen.validated()
        let defaultPolicyBytes = try defaultPolicy.canonicalData()
        let historicalPolicyBytes = try ContextComponentPolicy.selectedQwen.canonicalData()
        result["neighborhood_default_remains_exact_historical_v1_sixteen_spans_pending_answer_quality_evidence"] =
            defaultPolicy == .selectedQwen && defaultPolicyBytes == historicalPolicyBytes
            && defaultPolicy.version == "selected-model-context-components-v1" && defaultPolicy.evidenceSpans == 16
            && defaultPolicy.reductionVersion == "whole-source-geometric-v1" && !defaultPolicy.usesBoundedNeighborhood
        let experimentalPolicy = try ContextComponentPolicy.selectedQwenNeighborhood.validated()
        result["neighborhood_explicit_v2_policy_remains_available_without_changing_default"] =
            experimentalPolicy.version == "selected-model-context-components-v2" && experimentalPolicy.evidenceSpans == 48
            && experimentalPolicy.usesBoundedNeighborhood && experimentalPolicy != defaultPolicy
        let reversed = try expand([hit(assistant)])
        result["neighborhood_assistant_primary_reads_previous_and_next_human"] = exactIDs(reversed.hits) == exactIDs([assistant, human, correction])
        result["neighborhood_neighbor_preserves_unicode_nul_date_status_digest_and_scope"] = reversed.hits.count == 3
            && Data(reversed.hits[2].excerpt.utf8) == Data(correction.text.utf8)
            && reversed.hits[2].sourceTime == date && reversed.hits[2].status == .cancelled
            && reversed.hits[2].digest == correction.digest && reversed.hits[2].totalBytes == correction.byteCount
            && episodeIdentifierEqual(reversed.hits[2].projectID, project)
            && episodeIdentifierEqual(reversed.hits[2].conversationID, archive.id)
        result["neighborhood_neighbor_only_sources_never_recursively_expand"] = !reversed.hits.contains { episodeIdentifierEqual($0.eventID, later.id) }
        let futurePrimaryLease = try fixture.lease(), futurePrimaryBefore = try futurePrimaryLease.checkActive()
        let originalNeighbors = try expand([hit(human), hit(assistant), hit(correction)], lease: futurePrimaryLease)
        let futurePrimaryAfter = try futurePrimaryLease.checkActive()
        result["neighborhood_future_primary_keeps_own_neighbors_after_prefix_dedup"] = exactIDs(originalNeighbors.hits)
            == exactIDs([human, assistant, correction, prior, later])
        result["neighborhood_all_original_primaries_precede_new_neighbors"] = exactIDs(Array(originalNeighbors.hits.prefix(3))) == exactIDs([human, assistant, correction])
        result["neighborhood_existing_full_primary_prefix_has_no_extra_payload_read"] = futurePrimaryAfter.charged.rawSourceBytes - futurePrimaryBefore.charged.rawSourceBytes
            == 2 * (prior.byteCount + 1 + later.byteCount + 1)
        let cappedLease = try fixture.lease(), cappedBefore = try cappedLease.checkActive()
        let capped = try expand(ranked.map { hit($0) }, lease: cappedLease), cappedAfter = try cappedLease.checkActive()
        result["neighborhood_sixteen_ranked_primaries_survive_thirty_two_neighbors"] = capped.hits.count == 48
            && exactIDs(Array(capped.hits.prefix(16))) == exactIDs(ranked)
            && exactIDs(Array(capped.hits.dropFirst(16))) == exactIDs(neighbors)
            && capped.audit["retained_primary_count"] as? Int == 16 && capped.audit["dropped_primary_count"] as? Int == 0
            && capped.audit["added_neighbor_count"] as? Int == 32
        result["neighborhood_late_rank_fifteen_primary_retained_before_expansion"] = episodeIdentifierEqual(capped.hits[15].eventID, ranked[15].id)
        result["neighborhood_full_cap_uses_original_resource_limits_without_relaxation"] = cappedBefore.limits == cappedAfter.limits
            && cappedAfter.charged.metadataRows - cappedBefore.charged.metadataRows == 112
            && cappedAfter.charged.rawSourceBytes - cappedBefore.charged.rawSourceBytes == neighbors.reduce(0) { $0 + 2 * ($1.byteCount + 1) }
        let cappedDecisions = decisions(capped)
        result["neighborhood_audit_explicit_primary_neighbor_origin_direction_and_final_rank"] = cappedDecisions.count == 48
            && cappedDecisions.prefix(16).enumerated().allSatisfy { $0.element["origin"] as? String == "primary"
                && $0.element["primary_rank"] as? Int == $0.offset && $0.element["final_rank"] as? Int == $0.offset }
            && cappedDecisions.dropFirst(16).enumerated().allSatisfy { $0.element["origin"] as? String == "neighbor"
                && $0.element["direction"] as? String == ($0.offset % 2 == 0 ? "previous" : "next")
                && $0.element["final_rank"] as? Int == $0.offset + 16 && $0.element["payload_funded"] as? Bool == true }

        let duplicate = try expand([hit(human), hit(human)])
        result["neighborhood_duplicate_primary_span_retained_once_and_expands_once"] = exactIDs(duplicate.hits) == exactIDs([human, prior, assistant])
            && duplicate.audit["duplicate_primary_span_count"] as? Int == 1
        let fragment = hit(human, offset: 10, excerpt: String(human.text.dropFirst(10)))
        let distinct = try expand([hit(human), fragment, fragment])
        result["neighborhood_distinct_original_ranges_preserved_in_rank_order"] = distinct.hits.count == 4
            && distinct.hits[0].excerptOffset == 0 && distinct.hits[1].excerptOffset == 10
            && Data(distinct.hits[1].excerpt.utf8) == Data(fragment.excerpt.utf8)
            && distinct.audit["retained_primary_count"] as? Int == 2 && distinct.audit["added_neighbor_count"] as? Int == 2
        result["neighborhood_duplicate_span_changed_status_refused"] = try rejected([hit(human), altered(hit(human), status: .failed)])
        result["neighborhood_duplicate_span_changed_digest_refused"] = try rejected([hit(human), altered(hit(human), digest: String(repeating: "0", count: 64))])
        result["neighborhood_duplicate_span_changed_calendar_metadata_refused"] = try rejected([hit(correction), altered(hit(correction), removeTime: true)])
        result["neighborhood_changed_conversation_metadata_refused"] = try rejected([altered(hit(human), conversationID: interleaved.id)])
        result["neighborhood_forged_source_project_refused_before_payload"] = try rejected([altered(hit(foreign), projectID: project)])
        result["neighborhood_foreign_project_input_refused_before_payload"] = try rejected([hit(foreign)])
        result["neighborhood_primary_beyond_frozen_frontier_refused"] = try rejected([hit(future)])
        result["neighborhood_negative_offset_refused_before_payload"] = try rejected([hit(human, offset: -1)])
        result["neighborhood_range_outside_original_total_refused_before_payload"] = try rejected([hit(human, offset: human.byteCount)])
        result["neighborhood_oversized_incoming_span_refused_before_payload"] = try rejected([hit(long)])
        result["neighborhood_more_than_sixteen_inputs_refused_before_payload"] = try rejected(Array(repeating: hit(human), count: 17))
        let frozenReport = try expand([hit(frozen)])
        result["neighborhood_post_frontier_neighbor_never_selected"] = exactIDs(frozenReport.hits) == exactIDs([frozen])
            && !frozenReport.hits.contains { episodeIdentifierEqual($0.eventID, future.id) }
        let boundaryReport = try expand([hit(boundary)])
        result["neighborhood_same_role_publication_stops_without_skipping"] = exactIDs(boundaryReport.hits) == exactIDs([boundary])
            && decisions(boundaryReport).contains { $0["neighbor_event_id"] as? String == sameRole.id && $0["disposition"] as? String == "same_role_boundary" }
            && !boundaryReport.hits.contains { episodeIdentifierEqual($0.eventID, beyondBoundary.id) }
        let excludedLease = try fixture.lease(), excludedBefore = try excludedLease.checkActive()
        let excluded = try expand([hit(left)], exclusions: [long.id], lease: excludedLease), excludedAfter = try excludedLease.checkActive()
        result["neighborhood_excluded_neighbor_has_no_payload_read_or_forward_skip"] = exactIDs(excluded.hits) == exactIDs([left])
            && excludedAfter.charged.rawSourceBytes == excludedBefore.charged.rawSourceBytes
            && decisions(excluded).contains { $0["disposition"] as? String == "excluded_neighbor" }
        let excludedPrimary = try expand([hit(left)], exclusions: [left.id])
        result["neighborhood_excluded_primary_validated_but_not_expanded"] = excludedPrimary.hits.isEmpty
            && decisions(excludedPrimary).count == 1 && excludedPrimary.audit["excluded_primary_count"] as? Int == 1
        let emptyLease = try fixture.lease(), emptyBefore = try emptyLease.checkActive()
        let emptyReport = try expand([hit(emptyAnchor)], lease: emptyLease), emptyAfter = try emptyLease.checkActive()
        result["neighborhood_empty_neighbor_metadata_retained_without_payload_read"] = exactIDs(emptyReport.hits) == exactIDs([emptyAnchor])
            && emptyAfter.charged.rawSourceBytes == emptyBefore.charged.rawSourceBytes
            && decisions(emptyReport).contains { $0["neighbor_event_id"] as? String == empty.id && $0["disposition"] as? String == "empty_neighbor" }
        let unicode = try expand([hit(composed), hit(decomposed)])
        result["neighborhood_unicode_equivalent_event_ids_remain_distinct"] = exactIDs(unicode.hits) == exactIDs([composed, decomposed])
            && unicode.audit["retained_primary_count"] as? Int == 2

        let longLease = try fixture.lease(), longBefore = try longLease.checkActive()
        let longReport = try expand([hit(left), hit(right)], lease: longLease), longAfter = try longLease.checkActive()
        result["neighborhood_large_neighbor_scalar_safe_prefix_preserves_original_total_status"] = longReport.hits.count == 3
            && longReport.hits[2].excerptOffset == 0 && longReport.hits[2].excerpt.utf8.count == 4095
            && longReport.hits[2].totalBytes == long.byteCount && longReport.hits[2].digest == long.digest
            && longReport.hits[2].status == .failed && longReport.audit["prefix_truncated_count"] as? Int == 1
        result["neighborhood_shared_scalar_safe_prefix_read_once_without_refund"] = longAfter.charged.rawSourceBytes - longBefore.charged.rawSourceBytes == 2 * 4097
            && decisions(longReport).contains { $0["disposition"] as? String == "covered_funded_neighbor_prefix" && $0["payload_funded"] as? Bool == false }
        let tail = hit(long, offset: 4097, excerpt: "tail")
        let tailReport = try expand([hit(left), tail])
        result["neighborhood_primary_tail_and_neighbor_prefix_both_remain_exact_ranges"] = tailReport.hits.count == 4
            && tailReport.hits[1].excerptOffset == 4097 && tailReport.hits[1].excerpt == "tail"
            && tailReport.hits[2].excerptOffset == 0 && tailReport.hits[2].excerpt.utf8.count == 4095
            && episodeIdentifierEqual(tailReport.hits[1].eventID, tailReport.hits[2].eventID)
        let nestedLease = try fixture.lease(), nestedBefore = try nestedLease.checkActive()
        _ = try expand([hit(left)], nested: true, lease: nestedLease)
        result["neighborhood_nested_operation_does_not_duplicate_composite_charge"] = try nestedLease.checkActive().charged.memoryOperations == nestedBefore.charged.memoryOperations
        let repeatLease = try fixture.lease()
        _ = try expand([hit(left)], lease: repeatLease)
        let repeatBefore = try repeatLease.checkActive()
        _ = try expand([hit(left)], lease: repeatLease)
        result["neighborhood_repeated_expansion_retains_new_read_debits"] = try repeatLease.checkActive().charged.rawSourceBytes - repeatBefore.charged.rawSourceBytes == 2 * 4097
        result["neighborhood_empty_primary_set_preserves_empty_result"] = try expand([]).hits.isEmpty

        var rawLimits = EpisodeLimits(); rawLimits.resources.rawSourceBytes = 0
        let rawLease = try fixture.lease(rawLimits), rawBefore = try rawLease.checkActive()
        do {
            _ = try expand([hit(human)], lease: rawLease)
            result["neighborhood_raw_budget_refusal_before_payload_with_funded_metadata"] = false
        } catch {
            let receipt = try store.episodeReceipt(id: rawBefore.id, clock: fixture.clock.now())
            result["neighborhood_raw_budget_refusal_before_payload_with_funded_metadata"] = (error as? EpisodeBudgetError) == .exhausted
                && receipt.charged.rawSourceBytes == 0 && receipt.charged.metadataRows == 4
                && receipt.limits == rawBefore.limits && receipt.charged.modelCalls == 0 && receipt.held == .zero
        }
        var metadataLimits = EpisodeLimits(); metadataLimits.resources.metadataRows = 0
        let metadataLease = try fixture.lease(metadataLimits), metadataBefore = try metadataLease.checkActive()
        do {
            _ = try expand([hit(human)], lease: metadataLease)
            result["neighborhood_metadata_budget_refusal_before_source_lookup"] = false
        } catch {
            let receipt = try store.episodeReceipt(id: metadataBefore.id, clock: fixture.clock.now())
            result["neighborhood_metadata_budget_refusal_before_source_lookup"] = (error as? EpisodeBudgetError) == .exhausted
                && receipt.charged.metadataRows == 0 && receipt.charged.rawSourceBytes == 0
                && receipt.limits == metadataBefore.limits && receipt.held == .zero
        }
        result.merge(try assemblyChecks(fixture: fixture, ranked: ranked, capped: capped,
            human: human, unicode: correction, frontier: frontier)) { _, latest in latest }
        return result
    }

    private static func assemblyChecks(fixture: Fixture, ranked: [MemoryEvent], capped: ExchangeExpansionReport,
        human: MemoryEvent, unicode: MemoryEvent, frontier: Int) throws -> [String: Bool] {
        let store = fixture.store, project = fixture.project, policy = ContextComponentPolicy.selectedQwenNeighborhood
        var limits = EpisodeLimits(); limits.componentPolicy = policy
        let lease = try fixture.lease(limits), accepted = try lease.checkActive(), currentID = accepted.humanEventID!
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: fixture.requests.id,
            projectID: project, prompt: "Synthetic neighborhood request", system: "Synthetic neighborhood host",
            excludingEventID: currentID, episodeLease: lease, componentPolicy: policy)
        let provenance = try BoundedNeighborhoodExpansion.provenance(for: capped)
        let before = try lease.checkActive()
        var selected = try ContextAssembler.addEvidence(to: recent, store: store, conversationID: fixture.requests.id,
            projectID: project, excludingEventID: currentID, historicalHits: capped.hits,
            maximumEvidenceSpans: policy.evidenceSpans, episodeLease: lease, componentPolicy: policy,
            historicalProvenance: provenance)
        var retrieval = try object(selected.retrievalAuditJSON!)
        retrieval["exchange_expansion"] = capped.audit
        selected.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: retrieval, options: [.sortedKeys])
        let after = try lease.checkActive()
        let full = try object(selected.selectionEvidence()), audit = try object(selected.deliveryAudit())
        let provenanceDigest = ContextSnapshot.digest(try JSONSerialization.data(withJSONObject: full["historical_provenance"]!, options: [.sortedKeys]))
        var checks: [String: Bool] = [
            "neighborhood_assembler_admits_forty_eight_original_ranges_under_same_byte_bounds": selected.evidence.count == 48
                && selected.protectedPrimarySpanCount == 16 && selected.selectionAudit?.maximumEvidenceSpans == 48
                && selected.selectionAudit?.maximumEvidenceBytes == 131072 && selected.serializedBytes <= 1900000,
            "neighborhood_assembler_funds_actual_original_span_validation": after.charged.rawSourceBytes - before.charged.rawSourceBytes
                == capped.hits.reduce(0) { $0 + 2 * ($1.excerpt.utf8.count + 1) }
                && after.charged.metadataRows - before.charged.metadataRows == 96 && after.limits == before.limits,
            "neighborhood_full_provenance_and_trace_bound_in_selection_snapshot": (full["historical_provenance"] as? [[String: Any]])?.count == 48
                && (full["historical_selection_trace"] as? [String: Any])?["candidate_count"] as? Int == 48
                && full["neighborhood_expansion"] is [String: Any]
                && audit["historical_provenance_sha256"] as? String == provenanceDigest,
            "neighborhood_primary_cap_remains_sixteen_and_new_policy_is_exact": ContextAssembler.componentMaximumEvidenceSpans == 16
                && ContextComponentPolicy.selectedQwen.evidenceSpans == 16 && policy.evidenceSpans == 48
                && policy.recentTokens == 8000 && policy.evidenceTokens == 12000
                && policy.evidenceBytes == ContextComponentPolicy.selectedQwen.evidenceBytes
                && policy.maximumMessageBytes == ContextComponentPolicy.selectedQwen.maximumMessageBytes
        ]
        let originalAssembly = try object(selected.retrievalAuditJSON!)["selection_trace"] as! [String: Any]
        var reduced = selected
        var neighborRounds = 0
        while reduced.evidence.count > 16 {
            guard let next = try reduced.reducedEvidenceForComponentCap() else { throw ContextError.sourceMismatch }
            reduced = next; neighborRounds += 1
            guard reduced.protectedPrimarySpanCount == 16 else { throw ContextError.sourceMismatch }
        }
        checks["neighborhood_count_reduction_removes_neighbors_before_any_primary"] = reduced.evidence.count == 16
            && exactIDs(reduced.evidence) == exactIDs(ranked) && neighborRounds == 6
            && reduced.selectionAudit?.evidenceTokenExcludedCount == 32
        let primaryReduced = try reduced.reducedEvidenceForComponentCap()!
        checks["neighborhood_count_reduction_then_halves_protected_primaries_if_needed"] = primaryReduced.evidence.count == 8
            && primaryReduced.protectedPrimarySpanCount == 8 && exactIDs(primaryReduced.evidence) == exactIDs(Array(ranked.prefix(8)))
        let reducedTrace = try object(primaryReduced.retrievalAuditJSON!)["selection_trace"] as! [String: Any]
        checks["neighborhood_reduction_keeps_initial_assembly_and_rebuilds_exact_delivery"] = try canonical(reducedTrace["assembly"]!) == canonical(originalAssembly["assembly"]!)
            && reducedTrace["candidate_count"] as? Int == 48 && reducedTrace["delivered_count"] as? Int == 8
            && (reducedTrace["delivery"] as? [[String: Any]])?.count == 8
            && (try object(primaryReduced.selectionEvidence())["historical_provenance"] as? [[String: Any]])?.count == 8
        let envelopeReduced = try selected.reducedForTokenAdmission()!
        checks["neighborhood_envelope_reduction_preserves_all_protected_primaries_first"] = envelopeReduced.evidence.count == 32
            && envelopeReduced.protectedPrimarySpanCount == 16 && envelopeReduced.selectionAudit?.evidenceEnvelopeExcludedCount == 16
            && envelopeReduced.messages.first == selected.messages.first && envelopeReduced.messages.last == selected.messages.last
            && envelopeReduced.recentSourceIDs == selected.recentSourceIDs
        var oversizedAudit = selected
        var largeRetrieval = try object(oversizedAudit.retrievalAuditJSON!)
        var largeTrace = largeRetrieval["selection_trace"] as! [String: Any]
        largeTrace["synthetic_padding"] = String(repeating: "x", count: 33000)
        largeRetrieval["selection_trace"] = largeTrace
        oversizedAudit.retrievalAuditJSON = try canonical(largeRetrieval)
        let bounded = try object(oversizedAudit.deliveryAudit()), retained = try object(oversizedAudit.selectionEvidence())
        let deliveredRetrieval = bounded["retrieval"] as! [String: Any]
        checks["neighborhood_small_delivery_omits_large_trace_with_explicit_bound_digest"] = try deliveredRetrieval["selection_trace"] == nil
            && deliveredRetrieval["selection_trace_omitted"] as? String == "metadata_limit"
            && bounded["historical_selection_trace_sha256"] as? String == ContextSnapshot.digest(canonical(retained["historical_selection_trace"]!))
            && (retained["historical_selection_trace"] as? [String: Any])?["synthetic_padding"] as? String == String(repeating: "x", count: 33000)

        let auditBefore = try lease.checkActive()
        var alreadyFits = selected
        alreadyFits.componentAuditJSON = try canonical(["synthetic_proof": true])
        alreadyFits.selectionWorkID = "00000000-0000-0000-0000-000000000001"
        let unnecessaryReduction = try alreadyFits.fittedForDeliveryAudit()
        checks["neighborhood_delivery_fit_keeps_every_span_when_exact_proof_audit_fits"] = unnecessaryReduction == nil
            && alreadyFits.selectionAudit?.evidenceAuditExcludedCount == 0
        var proofHeadroom = alreadyFits
        let proofBytes = try canonical(["synthetic_proof_headroom": String(repeating: "p", count: 20000)])
        proofHeadroom.componentAuditJSON = proofBytes
        guard var auditReduced = try proofHeadroom.fittedForDeliveryAudit() else { throw ContextError.sourceMismatch }
        let removedForAudit = 48 - auditReduced.evidence.count
        checks["neighborhood_audit_size_reduction_keeps_protected_ranges_and_clears_stale_proof"] =
            auditReduced.protectedPrimarySpanCount == 16 && removedForAudit > 0
            && auditReduced.componentAuditJSON == nil && auditReduced.selectionWorkID == nil
            && auditReduced.selectionAudit?.evidenceAuditExcludedCount == removedForAudit
            && auditReduced.selectionAudit?.evidenceAuditReductionRounds == removedForAudit
            && auditReduced.selectionAudit?.evidenceTokenExcludedCount == 0
            && auditReduced.selectionAudit?.evidenceEnvelopeExcludedCount == 0
        auditReduced.componentAuditJSON = proofBytes; auditReduced.selectionWorkID = alreadyFits.selectionWorkID
        let fittedTrace = try object(auditReduced.retrievalAuditJSON!)["selection_trace"] as! [String: Any]
        checks["neighborhood_audit_size_rebuilds_delivery_and_preserves_initial_assembly"] = try auditReduced.deliveryAudit().count <= 32768
            && canonical(fittedTrace["assembly"]!) == canonical(originalAssembly["assembly"]!)
            && fittedTrace["audit_size_excluded_count"] as? Int == removedForAudit
            && fittedTrace["delivery_reduction_reason"] as? String == "audit_size"
            && (fittedTrace["delivery"] as? [[String: Any]])?.count == auditReduced.evidence.count
        var impossible = alreadyFits
        impossible.componentAuditJSON = try canonical(["synthetic_proof_headroom": String(repeating: "p", count: 40000)])
        var hardRefusal = false
        do { _ = try impossible.fittedForDeliveryAudit() } catch ContextError.invalidBudget { hardRefusal = true }
        let auditAfter = try lease.checkActive()
        checks["neighborhood_impossible_audit_refuses_without_cap_changes_or_unfunded_work"] = hardRefusal
            && auditAfter.charged == auditBefore.charged && auditAfter.held == auditBefore.held && auditAfter.limits == auditBefore.limits

        func refuseOriginal(_ forged: MemoryHit, key: String) throws {
            let original = ContextEvidenceProvenance(eventID: forged.eventID, offset: forged.excerptOffset,
                byteLength: forged.excerpt.utf8.count, excerptSHA256: ContextSnapshot.digest(Data(forged.excerpt.utf8)),
                candidateRank: 0, origin: "primary", primaryRank: 0, anchorEventID: nil, direction: nil)
            let refusalBefore = try lease.checkActive()
            do {
                _ = try ContextAssembler.addEvidence(to: recent, store: store, conversationID: fixture.requests.id,
                    projectID: project, excludingEventID: currentID, historicalHits: [forged], maximumEvidenceSpans: 48,
                    episodeLease: lease, componentPolicy: policy, historicalProvenance: [original])
                checks[key] = false
            } catch {
                let receipt = try store.episodeReceipt(id: lease.episodeID, clock: fixture.clock.now())
                checks[key] = (error is ContextError || error is MemoryError) && receipt.limits == refusalBefore.limits
                    && receipt.charged.rawSourceBytes - refusalBefore.charged.rawSourceBytes == 2 * (forged.excerpt.utf8.count + 1)
                    && receipt.charged.metadataRows - refusalBefore.charged.metadataRows == 2
                    && receipt.charged.modelCalls == 0 && receipt.charged.encoderInputBytes == 0
            }
        }
        try refuseOriginal(hit(human, excerpt: "X" + String(human.text.dropFirst())), key: "neighborhood_forged_original_payload_refused_by_funded_assembler")
        let split = Array(unicode.text.utf8).firstIndex(of: 0xc3)! + 1
        try refuseOriginal(hit(unicode, offset: split, excerpt: "a"), key: "neighborhood_split_original_utf8_offset_refused_by_funded_assembler")
        var alteredPolicy = policy; alteredPolicy.evidenceSpans = 49
        do { _ = try alteredPolicy.validated(); checks["neighborhood_unrecognized_policy_cap_refused"] = false }
        catch { checks["neighborhood_unrecognized_policy_cap_refused"] = error is EpisodeBudgetError }
        checks["neighborhood_historical_v1_policy_still_decodes_exactly"] = try JSONDecoder().decode(ContextComponentPolicy.self,
            from: ContextComponentPolicy.selectedQwen.canonicalData()) == .selectedQwen
        return checks
    }

    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ContextError.sourceMismatch }
        return value
    }
    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func decisions(_ report: ExchangeExpansionReport) -> [[String: Any]] {
        report.audit["decisions"] as? [[String: Any]] ?? []
    }
    private static func exactIDs(_ hits: [MemoryHit]) -> [Data] { hits.map { Data($0.eventID.utf8) } }
    private static func exactIDs(_ events: [MemoryEvent]) -> [Data] { events.map { Data($0.id.utf8) } }
    private static func hit(_ event: MemoryEvent, offset: Int = 0, excerpt: String? = nil) -> MemoryHit {
        MemoryHit(eventID: event.id, conversationID: event.conversationID, projectID: event.projectID,
            role: event.role, status: event.status, createdAt: event.createdAt, digest: event.digest,
            totalBytes: event.byteCount, excerptOffset: offset, excerpt: excerpt ?? event.text, sourceTime: event.sourceTime)
    }
    private static func altered(_ hit: MemoryHit, projectID: String? = nil, conversationID: String? = nil,
        status: CaptureStatus? = nil, digest: String? = nil, removeTime: Bool = false) -> MemoryHit {
        MemoryHit(eventID: hit.eventID, conversationID: conversationID ?? hit.conversationID,
            projectID: projectID ?? hit.projectID, role: hit.role, status: status ?? hit.status,
            createdAt: hit.createdAt, digest: digest ?? hit.digest, totalBytes: hit.totalBytes,
            excerptOffset: hit.excerptOffset, excerpt: hit.excerpt, sourceTime: removeTime ? nil : hit.sourceTime)
    }
    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-neighborhood-clock", continuousNanoseconds: 1_000_000,
                utc: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
    private final class Fixture {
        let directory: URL
        let store: MemoryStore
        let project = "synthetic-neighborhood-project"
        let clock = Clock()
        let requests: StoredConversation
        private var requestOrdinal = 0
        init() throws {
            guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw MeteredRetrievalError.invalid }
            defer { free(path) }
            directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("boros-neighborhood-checks-" + UUID().uuidString)
            store = try MemoryStore(directory: directory)
            requests = try store.createConversation(projectID: project, title: "Synthetic neighborhood requests")
        }
        func conversation(_ label: String) throws -> StoredConversation {
            try store.createConversation(projectID: project, title: "Synthetic neighborhood " + label)
        }
        func append(_ id: String, _ text: String, _ role: MemoryRole, _ conversation: StoredConversation,
            _ status: CaptureStatus = .complete, _ time: EventSourceTime? = nil) throws -> MemoryEvent {
            try store.append(conversationID: conversation.id, role: role, text: text, status: status,
                turnID: "synthetic-neighborhood-turn-" + id, eventID: id, sourceTime: time)
        }
        func lease(_ limits: EpisodeLimits = EpisodeLimits()) throws -> EpisodeLease {
            requestOrdinal += 1
            let id = UUID().uuidString, suffix = String(requestOrdinal)
            _ = try store.acceptRequestAndBeginEpisode(conversationID: requests.id, turnID: "synthetic-neighborhood-request-turn-" + suffix,
                humanEventID: "synthetic-neighborhood-request-" + suffix, episodeID: id,
                text: "Synthetic neighborhood request", limits: limits, clock: clock.now())
            return EpisodeLease(ledger: store, episodeID: id, clock: clock)
        }
    }
}
