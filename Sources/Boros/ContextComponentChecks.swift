import Foundation

/// Synthetic provenance/selection checks. Provider fixtures separately verify
/// tokenizer receipts; no byte count here is treated as a token estimate.
enum ContextComponentChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-context-components-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let project = "synthetic-component-project", prompt = "componentneedle current request 日本語"
        let chat = try store.createConversation(projectID: project, title: "Synthetic component suffix")
        var events: [MemoryEvent] = []
        for index in 0..<7 {
            events.append(try append(store, chat.id, "component-source-\(index)", index == 0 ? "componentneedle source zero" : "Synthetic recent \(index) é e\u{301}",
                role: index % 2 == 0 ? .human : .assistant, status: index == 3 ? .partial : .complete))
        }
        let current = try append(store, chat.id, "component-current", prompt)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: current.id)
        var checks: [String: Bool] = [:]
        checks["component_recent_whole_ordered_sources"] = recent.recentSourceIDs == events.map(\.id)
            && recent.includedRecentCount == 7 && recent.evidence.isEmpty
        checks["component_host_provenance_labels"] = try recent.componentAssignments() == [.mandatory]
            + Array(repeating: .recent, count: 7) + [.mandatory]
        checks["component_recent_capture_label_in_actual_message"] = recent.messages[4].content.hasPrefix("[Incomplete historical assistant message; capture status: partial.]")
        checks["component_current_request_intact_utf8"] = recent.messages.last!.content.utf8.elementsEqual(prompt.utf8)
        checks["component_source_snapshot_seals_scope_and_accepted_request"] = recent.selectionBinding?.projectID == project
            && recent.selectionBinding?.conversationID == chat.id && recent.selectionBinding?.acceptedHumanEventID == current.id
            && recent.recentSources.map(\.digest) == events.map(\.digest)
        let first = try recent.reducedRecentForComponentCap()!
        let second = try first.reducedRecentForComponentCap()!
        let last = try second.reducedRecentForComponentCap()!
        checks["component_geometric_recent_ceil_half_suffix"] = first.recentSourceIDs == Array(events.suffix(3).map(\.id))
            && second.recentSourceIDs == [events[6].id] && last.recentSourceIDs.isEmpty
        checks["component_recent_reductions_keep_mandatory"] = [first, second, last].allSatisfy {
            $0.messages.first == recent.messages.first && $0.messages.last == recent.messages.last
        }
        checks["component_recent_token_exclusions_separate_from_bytes"] = last.selectionAudit?.recentTokenExcludedCount == 7
            && last.selectionAudit?.recentByteExcludedCount == 0 && last.selectionAudit?.recentReductionRounds == 3
        checks["component_recent_empty_reduction_terminates"] = try last.reducedRecentForComponentCap() == nil
        checks["component_selection_digest_changes_with_retained_sources"] = try recent.selectionDigest() != first.selectionDigest()
            && first.selectionDigest() != second.selectionDigest()
        let retrieved = try ChatContextPreparation.prepareEvidence(recent: first, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: current.id)
        checks["component_dropped_recent_becomes_historical_eligible"] = retrieved.evidence.contains { $0.eventID == events[0].id }
        checks["component_retrieval_keeps_final_recent_suffix"] = retrieved.recentSourceIDs == first.recentSourceIDs
            && retrieved.messages.dropFirst().prefix(first.includedRecentCount).elementsEqual(first.messages.dropFirst().prefix(first.includedRecentCount))
        checks["component_evidence_host_assignment_separate_from_recent_user"] = try retrieved.componentAssignments() == [.mandatory]
            + Array(repeating: .recent, count: 3) + [.historicalEvidence, .mandatory]
        do {
            _ = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
                prompt: "changed synthetic request", system: "Synthetic host", excludingEventID: current.id)
            checks["component_changed_accepted_request_rejected"] = false
        } catch { checks["component_changed_accepted_request_rejected"] = error is ContextError }
        do {
            _ = try ChatContextPreparation.prepareEvidence(recent: first, store: store, conversationID: chat.id,
                projectID: project, prompt: "Changed synthetic retrieval", excludingEventID: current.id)
            checks["component_changed_retrieval_request_rejected"] = false
        } catch { checks["component_changed_retrieval_request_rejected"] = error is ContextError }
        let byteBound = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: current.id, maximumRecentBytes: 128)
        checks["component_byte_guard_retains_whole_suffix"] = byteBound.includedRecentCount < 7
            && byteBound.recentSourceIDs == Array(events.suffix(byteBound.includedRecentCount).map(\.id))
            && byteBound.selectionAudit?.recentByteExcludedCount == 7 - byteBound.includedRecentCount
            && byteBound.selectionAudit?.recentTokenExcludedCount == 0

        let archive = try store.createConversation(projectID: project, title: "Synthetic component evidence")
        var hits: [MemoryHit] = []
        for index in 0..<17 {
            let event = try append(store, archive.id, "component-span-\(index)", String(repeating: "x", count: 4096))
            hits.append(hit(event))
        }
        let fullEvidence = try ContextAssembler.addEvidence(to: first, store: store, conversationID: chat.id,
            projectID: project, excludingEventID: current.id, historicalHits: hits)
        checks["component_sixteen_whole_4096_byte_spans_fit_guard"] = fullEvidence.evidence.count == 16
            && fullEvidence.evidence.allSatisfy { $0.excerpt.utf8.count == 4096 }
            && fullEvidence.selectionAudit?.evidenceRowExcludedCount == 1
            && fullEvidence.selectionAudit?.evidenceByteExcludedCount == 0
        let five = try ContextAssembler.addEvidence(to: first, store: store, conversationID: chat.id,
            projectID: project, excludingEventID: current.id, historicalHits: Array(hits.prefix(5)))
        let two = try five.reducedEvidenceForComponentCap()!
        let one = try two.reducedEvidenceForComponentCap()!
        let none = try one.reducedEvidenceForComponentCap()!
        checks["component_geometric_evidence_ceil_half_prefix"] = two.evidence.map(\.eventID) == Array(hits.prefix(2).map(\.eventID))
            && one.evidence.map(\.eventID) == [hits[0].eventID] && none.evidence.isEmpty
        checks["component_evidence_reduction_preserves_ranges_and_bytes"] = two.evidence[0].excerptOffset == hits[0].excerptOffset
            && two.evidence[0].digest == hits[0].digest && two.evidence[0].excerpt.utf8.elementsEqual(hits[0].excerpt.utf8)
        checks["component_evidence_reduction_preserves_recent_and_mandatory"] = [two, one, none].allSatisfy {
            $0.recentSourceIDs == first.recentSourceIDs && $0.messages.first == first.messages.first && $0.messages.last == first.messages.last
        }
        checks["component_evidence_token_exclusions_audited"] = none.selectionAudit?.evidenceTokenExcludedCount == 5
            && none.selectionAudit?.evidenceReductionRounds == 3 && none.selectionAudit?.evidenceByteExcludedCount == 0
        let envelope = try five.reducedForTokenAdmission()!
        checks["component_envelope_reduces_evidence_before_recent"] = envelope.evidence.count == 2
            && envelope.recentSourceIDs == first.recentSourceIDs && envelope.selectionAudit?.evidenceEnvelopeExcludedCount == 3
            && envelope.selectionAudit?.evidenceTokenExcludedCount == 0
        let recentEnvelope = try none.reducedForTokenAdmission()!
        checks["component_envelope_recent_ceil_half_after_evidence_empty"] = recentEnvelope.recentSourceIDs == [events[6].id]
            && recentEnvelope.selectionAudit?.recentEnvelopeExcludedCount == 2
        let byteEvidence = try ContextAssembler.addEvidence(to: first, store: store, conversationID: chat.id,
            projectID: project, excludingEventID: current.id, historicalHits: hits, maximumEvidenceBytes: 100)
        checks["component_evidence_byte_exclusions_separate_from_token"] = byteEvidence.evidence.isEmpty
            && byteEvidence.selectionAudit?.evidenceByteExcludedCount == 17 && byteEvidence.selectionAudit?.evidenceTokenExcludedCount == 0
        let auditBytes = try two.deliveryAudit(), audit = try JSONSerialization.jsonObject(with: auditBytes) as! [String: Any]
        let auditSources = audit["historical_sources"] as! [[String: Any]], finalDigest = try two.selectionDigest()
        checks["component_delivery_audit_only_final_retained_spans"] = auditSources.map { $0["event_id"] as! String } == Array(hits.prefix(2).map(\.eventID))
            && audit["source_snapshot_sha256"] as? String == finalDigest
        checks["component_delivery_audit_content_free_bounded"] = auditBytes.count <= 32768
            && !String(decoding: auditBytes, as: UTF8.self).contains(String(repeating: "x", count: 64))
            && !String(decoding: auditBytes, as: UTF8.self).contains(prompt)
        var counted = five
        counted.componentAuditJSON = Data("{\"verified\":true}".utf8)
        checks["component_reduction_invalidates_previous_count_receipts"] = try counted.reducedEvidenceForComponentCap()!.componentAuditJSON == nil
        let altered = ContextSnapshot(messages: [ContextMessage(role: "system", content: "Changed host")] + first.messages.dropFirst(),
            evidence: [], serializedBytes: try ContextAssembler.serializedMessages([ContextMessage(role: "system", content: "Changed host")] + first.messages.dropFirst()).count,
            omittedRecentCount: first.omittedRecentCount, includedRecentCount: first.includedRecentCount,
            recentSourceIDs: first.recentSourceIDs, recentSources: first.recentSources, selectionBinding: first.selectionBinding, selectionAudit: first.selectionAudit)
        do { _ = try altered.componentAssignments(); checks["component_changed_mandatory_binding_rejected"] = false }
        catch { checks["component_changed_mandatory_binding_rejected"] = error is ContextError }

        let windowChat = try store.createConversation(projectID: "synthetic-component-window", title: "Fixed metadata window")
        for index in 0..<257 { _ = try append(store, windowChat.id, "component-window-\(index)", "z") }
        let windowCurrent = try append(store, windowChat.id, "component-window-current", "Synthetic window request")
        let window = try ContextAssembler.prepareRecent(store: store, conversationID: windowChat.id, projectID: "synthetic-component-window",
            prompt: windowCurrent.text, system: "", excludingEventID: windowCurrent.id)
        checks["component_fixed_recent_row_window_audited"] = window.includedRecentCount == 256
            && window.selectionAudit?.recentRowExcludedCount == 1 && window.selectionAudit?.recentByteExcludedCount == 0
            && window.recentSourceIDs.first == "component-window-1"
        checks["component_enlarged_guards_frozen_independently"] = window.selectionAudit?.maximumRecentBytes == 180000
            && window.selectionAudit?.maximumRecentRows == 256 && window.selectionAudit?.maximumEvidenceSpans == 16
            && window.selectionAudit?.maximumEvidenceSpanBytes == 4096 && window.selectionAudit?.maximumEvidenceBytes == 131072
            && window.selectionAudit?.maximumSerializedBytes == 1900000
        let largeChat = try store.createConversation(projectID: project, title: "Enlarged whole recent allocations")
        for index in 0..<2 { _ = try append(store, largeChat.id, "component-large-\(index)", String(repeating: "x", count: 70_000)) }
        let largeCurrent = try append(store, largeChat.id, "component-large-current", "Synthetic large allocation request")
        let large = try ContextAssembler.prepareRecent(store: store, conversationID: largeChat.id, projectID: project,
            prompt: largeCurrent.text, system: "", excludingEventID: largeCurrent.id)
        let largeFramingBytes = try large.recentSources.reduce(0) { total, source in
            total + (try ContextSourceFraming.recentPrefix(eventID: source.eventID, role: source.role.rawValue,
                status: source.status.rawValue, selectionVersion: ContextSourceFraming.currentSelectionVersion,
                capturedAt: source.createdAt, sourceTime: source.sourceTime)).utf8.count
        }
        checks["component_recent_guard_enlarged_beyond_legacy_bytes"] = large.includedRecentCount == 2
            && large.messages.dropFirst().dropLast().reduce(0) { $0 + $1.content.utf8.count } == 140_000 + largeFramingBytes
        do {
            _ = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
                prompt: prompt, system: "Synthetic host", excludingEventID: current.id, budgetBytes: 100)
            checks["component_mandatory_byte_overflow_preserves_request"] = false
        } catch ContextError.mandatoryOverflow(let required, let available) {
            let expected = try ContextAssembler.serializedMessages(ContextAssembler.mandatoryMessages(prompt: prompt, system: "Synthetic host")).count
            checks["component_mandatory_byte_overflow_preserves_request"] = available == 100 && required == expected
        }
        let unicode = try append(store, archive.id, "component-unicode-excerpt", "e\u{301}")
        let aliased = MemoryHit(eventID: unicode.id, conversationID: unicode.conversationID, projectID: unicode.projectID,
            role: unicode.role, status: unicode.status, createdAt: unicode.createdAt, digest: unicode.digest,
            totalBytes: unicode.byteCount, excerptOffset: 0, excerpt: "é")
        do {
            _ = try ContextAssembler.addEvidence(to: first, store: store, conversationID: chat.id, projectID: project,
                excludingEventID: current.id, historicalHits: [aliased])
            checks["component_excerpt_validation_uses_exact_utf8"] = false
        } catch { checks["component_excerpt_validation_uses_exact_utf8"] = error is ContextError || error is MemoryError }
        let clock = CheckClock(), episodeID = UUID().uuidString
        let binding = EpisodeLocalReadBinding(version: "local-read-v1", initiator: .syntheticEvaluation,
            purpose: .contextSelection, requestID: episodeID, descriptorVersion: "context-component-check-v1",
            descriptorSHA256: ContextSnapshot.digest(Data("synthetic component accounting".utf8)))
        _ = try store.beginLocalReadEpisode(episodeID: episodeID, projectID: project, binding: binding, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        let meteredRecent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: current.id, episodeLease: lease)
        let meteredReduced = try meteredRecent.reducedRecentForComponentCap()!
        let beforeEvidence = try lease.checkActive()
        _ = try ContextAssembler.addEvidence(to: meteredReduced, store: store, conversationID: chat.id,
            projectID: project, excludingEventID: current.id, historicalHits: [hits[0]], episodeLease: lease)
        let afterEvidence = try lease.checkActive()
        checks["component_stages_keep_one_original_episode"] = afterEvidence.id == episodeID
            && afterEvidence.charged.memoryOperations == 2 && beforeEvidence.charged.memoryOperations == 1
        checks["component_evidence_stage_does_not_reload_recent_sources"] = afterEvidence.charged.rawSourceBytes - beforeEvidence.charged.rawSourceBytes == (hits[0].excerpt.utf8.count + 1) * 2
        _ = try lease.finish(reason: .cancelled)
        let stopped = try store.episodeReceipt(id: episodeID, clock: clock.now())
        do {
            _ = try ChatContextPreparation.prepareEvidence(recent: meteredReduced, store: store, conversationID: chat.id,
                projectID: project, prompt: prompt, excludingEventID: current.id, episodeLease: lease)
            checks["component_stop_blocks_later_preparation_before_resources"] = false
        } catch let error as EpisodeBudgetError {
            let after = try store.episodeReceipt(id: episodeID, clock: clock.now())
            checks["component_stop_blocks_later_preparation_before_resources"] = error.failureCode == "episode_inactive"
                && after.charged == stopped.charged && after.held == stopped.held
        }
        checks.merge(try utf8ExclusionChecks(store: store)) { _, latest in latest }
        return checks
    }

    private static func utf8ExclusionChecks(store: MemoryStore) throws -> [String: Bool] {
        let project = "synthetic-component-utf8-exclusions"
        let chat = try store.createConversation(projectID: project, title: "Exact UTF8 exclusions")
        let archived = try append(store, chat.id, "component-utf8-archive",
            String(repeating: "archived unrelated words ", count: 2000) + "unicodecrowdkey original")
        for index in 0..<128 {
            for id in ["component-é-\(index)", "component-e\u{301}-\(index)"] { _ = try append(store, chat.id, id, "unicodecrowdkey") }
        }
        let current = try append(store, chat.id, "component-utf8-current", "Where is unicodecrowdkey?")
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: current.text, system: "Synthetic host", excludingEventID: current.id)
        let excluded = ExactSourceIDs(recent.recentSourceIDs + [current.id])
        var checks: [String: Bool] = [
            "component_utf8_exclusions_preserve_256_binary_recent_ids": recent.includedRecentCount == 256
                && ExactSourceIDs(recent.recentSourceIDs).count == 256 && Set(recent.recentSourceIDs).count == 128,
            "component_utf8_exact_collection_dedup_only_identical_bytes": ExactSourceIDs(["é", "e\u{301}", "é"]).count == 2,
            "component_utf8_exclusion_order_is_byte_lexicographic": ExactSourceIDs(["é", "e\u{301}"]).sorted() == ["e\u{301}", "é"]
        ]
        let references = try store.lexicalCandidateReferences(query: "unicodecrowdkey", projectID: project, limit: 16,
            matching: .anyTerm, excludingSourceIDs: excluded)
        checks["component_utf8_sql_exclusions_precede_candidate_limit"] = references.map(\.eventID) == [archived.id]
        checks["component_utf8_literal_sql_exclusions_precede_limit"] = try store.literalSearch(query: "unicodecrowdkey",
            projectID: project, limit: 16, excludingSourceIDs: excluded).map(\.eventID) == [archived.id]
        checks["component_utf8_source_manifest_exclusions_precede_window"] = try store.sourceManifest(projectID: project,
            afterSequence: 0, limit: 1, excludingSourceIDs: excluded).map(\.eventID) == [archived.id]
        let lexical = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: current.text, excludingEventID: current.id)
        checks["component_utf8_lexical_reaches_eligible_archived_source"] = lexical.evidence.map(\.eventID) == [archived.id]
        let clock = CheckClock(), id = UUID().uuidString
        let binding = EpisodeLocalReadBinding(version: "local-read-v1", initiator: .syntheticEvaluation,
            purpose: .contextSelection, requestID: id, descriptorVersion: "exact-utf8-exclusion-check-v1",
            descriptorSHA256: ContextSnapshot.digest(Data("synthetic exact UTF8 exclusion fixture".utf8)))
        _ = try store.beginLocalReadEpisode(episodeID: id, projectID: project, binding: binding, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: id, clock: clock)
        let raw = try MeteredRetrieval.lexicalSearch(store: store, query: "unicodecrowdkey", projectID: project,
            limit: 16, matching: .anyTerm, excludingSourceIDs: excluded, lease: lease)
        checks["component_utf8_metered_lexical_excludes_before_materialization"] = raw.inspectedCandidates == 1
            && raw.hits.map(\.eventID) == [archived.id] && !raw.candidateWindowFull
        let literal = try MeteredRetrieval.literalSearch(store: store, query: "unicodecrowdkey", projectID: project,
            limit: 16, excludingSourceIDs: excluded, lease: lease, maximumSources: 1)
        checks["component_utf8_metered_literal_excludes_before_source_window"] = literal.inspectedSources == 1
            && literal.hits.map(\.eventID) == [archived.id]
        let metered = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: current.text, excludingEventID: current.id, episodeLease: lease)
        checks["component_utf8_metered_selection_delivers_original_archive"] = metered.evidence.map(\.eventID) == [archived.id]
        let semantic = try SemanticIndex(store: store)
        let hybrid = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: current.text, excludingEventID: current.id, semanticIndex: semantic, episodeLease: lease)
        let manifest = try JSONDecoder().decode(SemanticSearchManifest.self, from: hybrid.retrievalManifestJSON!)
        checks["component_utf8_hybrid_preserves_full_exclusions_and_delivery"] = manifest.excludedEventIDs.count == 257
            && ExactSourceIDs(manifest.excludedEventIDs) == excluded && hybrid.evidence.map(\.eventID) == [archived.id]
        let replay = try semantic.replay(manifestID: hybrid.retrievalManifestID!, projectID: project, episodeLease: lease)
        checks["component_utf8_manifest_replay_preserves_original_archived_source"] = replay.hits.map(\.eventID) == [archived.id]
        checks["component_utf8_exclusion_digest_cannot_alias_single_id"] = try MeteredRetrieval.exclusionDigest(ExactSourceIDs(["é", "e\u{301}"]))
            != MeteredRetrieval.exclusionDigest(ExactSourceIDs(["é"]))
        let pairChat = try store.createConversation(projectID: "synthetic-utf8-unexcluded", title: "Distinct candidate source identities")
        let pairFirst = try append(store, pairChat.id, "component-archive-é", "pairkey source")
        let pairSecond = try append(store, pairChat.id, "component-archive-e\u{301}", "pairkey source")
        let pairReport = try semantic.search(query: "pairkey", projectID: pairChat.projectID, limit: 2, includeLiteral: false)
        checks["component_utf8_hybrid_candidate_dedup_preserves_distinct_sources"] = pairReport.hits.count == 2
            && ExactSourceIDs(pairReport.hits.map(\.eventID)) == ExactSourceIDs([pairFirst.id, pairSecond.id])
        let pairReplay = try semantic.replay(manifestID: pairReport.manifestID, projectID: pairChat.projectID)
        checks["component_utf8_distinct_candidate_manifest_replay_preserved"] = pairReplay.hits.count == 2
            && ExactSourceIDs(pairReplay.hits.map(\.eventID)) == ExactSourceIDs([pairFirst.id, pairSecond.id])
        _ = try lease.finish(reason: .completed)
        return checks
    }

    private final class CheckClock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-context-components", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }
    private static func append(_ store: MemoryStore, _ conversationID: String, _ eventID: String, _ text: String,
        role: MemoryRole = .human, status: CaptureStatus = .complete) throws -> MemoryEvent {
        try store.append(conversationID: conversationID, role: role, text: text, status: status,
            turnID: "synthetic-turn-" + eventID, eventID: eventID)
    }
    private static func hit(_ event: MemoryEvent) -> MemoryHit {
        MemoryHit(eventID: event.id, conversationID: event.conversationID, projectID: event.projectID,
            role: event.role, status: event.status, createdAt: event.createdAt, digest: event.digest,
            totalBytes: event.byteCount, excerptOffset: 0, excerpt: event.text)
    }
}
