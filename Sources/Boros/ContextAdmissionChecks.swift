import Foundation
import CSQLite

enum ContextAdmissionChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-context-admission-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var corruptEventID: String?
        let store = try MemoryStore(directory: directory, episodeAccountingCheckpoint: { phase, database in
            if phase == "before-accounting-lookup", let eventID = corruptEventID {
                corruptEventID = nil
                try alterSource(database, id: eventID)
            }
        })
        let chat = try store.createConversation(projectID: "synthetic", title: "Synthetic admission history")
        let archive = try store.createConversation(projectID: "synthetic", title: "Synthetic archived evidence")
        _ = try store.append(conversationID: archive.id, role: .human, text: "syntheticrarekey archive evidence",
            status: .complete, turnID: "archive-turn", eventID: "archive-event")
        for index in 0..<7 {
            _ = try store.append(conversationID: chat.id, role: index % 2 == 0 ? .human : .assistant,
                text: "Synthetic recent source \(index)", status: .complete, turnID: "turn-\(index)", eventID: "event-\(index)")
        }
        let snapshot = try ContextAssembler.prepare(store: store, conversationID: chat.id, projectID: "synthetic",
            prompt: "Synthetic current request 日本語", system: "Synthetic host instruction", historicalQuery: "syntheticrarekey")
        var checks: [String: Bool] = [:]
        checks["optional_evidence_available"] = snapshot.evidence.count == 1 && snapshot.includedRecentCount == 7
        checks["recent_source_provenance_retained"] = snapshot.recentSourceIDs == (0..<7).map { "event-\($0)" }
        let audit = try snapshot.deliveryAudit()
        let auditValue = try JSONSerialization.jsonObject(with: audit) as! [String: Any]
        let deliveries = auditValue["historical_sources"] as! [[String: Any]]
        checks["delivery_audit_retains_exact_source_range"] = deliveries.count == 1
            && deliveries[0]["event_id"] as? String == "archive-event"
            && deliveries[0]["excerpt_bytes"] as? Int == snapshot.evidence[0].excerpt.utf8.count
            && deliveries[0]["excerpt_offset"] as? Int == snapshot.evidence[0].excerptOffset
        checks["delivery_audit_is_content_free_and_bounded"] = audit.count <= 32768
            && !String(decoding: audit, as: UTF8.self).contains("syntheticrarekey archive evidence")
            && auditValue["recent_source_count"] as? Int == 7
        let semantic = try SemanticIndex(store: store)
        _ = try semantic.process(projectID: "synthetic", maximumChunks: 16)
        let hybrid = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: "synthetic",
            prompt: "What happened to syntheticrarekey archive evidence?", system: "Synthetic host rule",
            excludingEventID: "event-6", semanticIndex: semantic)
        let manifest = try JSONDecoder().decode(SemanticSearchManifest.self, from: hybrid.retrievalManifestJSON!)
        checks["send_hybrid_manifest_matches_delivery"] = hybrid.retrievalManifestID != nil
            && manifest.projectID == "synthetic" && hybrid.evidence.contains { $0.eventID == "archive-event" }
        checks["send_hybrid_excludes_recent_and_current_sources"] = manifest.excludedEventIDs.contains("event-6")
            && Set(hybrid.recentSourceIDs).isSubset(of: Set(manifest.excludedEventIDs))
            && hybrid.evidence.allSatisfy { !manifest.excludedEventIDs.contains($0.eventID) }
        let hybridAudit = try JSONSerialization.jsonObject(with: hybrid.retrievalAuditJSON!) as! [String: Any]
        checks["send_hybrid_avoids_implicit_full_literal_scan"] = hybridAudit["literal_search"] as? Bool == false
        let prunedHybrid = try hybrid.reducedForTokenAdmission()!
        let prunedAudit = try JSONSerialization.jsonObject(with: prunedHybrid.deliveryAudit()) as! [String: Any]
        checks["token_reduction_audits_delivered_sources_only"] = (prunedAudit["historical_sources"] as? [[String: Any]])?.isEmpty == true
            && prunedHybrid.retrievalManifestID == hybrid.retrievalManifestID
            && prunedHybrid.retrievalAuditJSON == hybrid.retrievalAuditJSON
        let actualHit = snapshot.evidence[0]
        let changedHit = MemoryHit(eventID: actualHit.eventID, conversationID: actualHit.conversationID, projectID: actualHit.projectID,
            role: actualHit.role, status: actualHit.status, createdAt: actualHit.createdAt, digest: actualHit.digest,
            totalBytes: actualHit.totalBytes, excerptOffset: actualHit.excerptOffset, excerpt: "Synthetic changed source text")
        do {
            _ = try ContextAssembler.prepare(store: store, conversationID: chat.id, projectID: "synthetic", prompt: "Synthetic current",
                system: "Synthetic rule", historicalHits: [changedHit])
            checks["supplied_source_tampering_rejected"] = false
        } catch { checks["supplied_source_tampering_rejected"] = true }
        let other = try store.createConversation(projectID: "other-synthetic", title: "Foreign source")
        _ = try store.append(conversationID: other.id, role: .human, text: "Foreign synthetic exact excerpt", status: .complete,
            turnID: "foreign-turn", eventID: "foreign-event")
        let foreignHit = try store.search(query: "Foreign", projectID: "other-synthetic")[0]
        do {
            _ = try ContextAssembler.prepare(store: store, conversationID: chat.id, projectID: "synthetic", prompt: "Synthetic current",
                system: "Synthetic rule", historicalHits: [foreignHit])
            checks["supplied_cross_project_source_rejected"] = false
        } catch { checks["supplied_cross_project_source_rejected"] = true }
        let reduced = try snapshot.reducedForTokenAdmission()!
        checks["token_reduction_drops_evidence_before_recent"] = reduced.evidence.isEmpty
            && reduced.includedRecentCount == snapshot.includedRecentCount && reduced.omittedRecentCount == snapshot.omittedRecentCount
        checks["token_reduction_preserves_mandatory_exactly"] = reduced.messages.first == snapshot.messages.first
            && reduced.messages.last == snapshot.messages.last
        checks["token_reduction_keeps_original_snapshot_immutable"] = snapshot.evidence.count == 1 && snapshot.messages.count == 10
        var candidate = reduced
        var steps = 0
        while let next = try candidate.reducedForTokenAdmission() {
            checks["reduction_\(steps)_reduces_optional_messages"] = next.messages.count < candidate.messages.count
            checks["reduction_\(steps)_keeps_recent_suffix"] = Array(next.messages.dropFirst().dropLast())
                == Array(candidate.messages.dropFirst().dropLast().suffix(next.includedRecentCount))
            checks["reduction_\(steps)_keeps_source_id_suffix"] = next.recentSourceIDs == Array(candidate.recentSourceIDs.suffix(next.includedRecentCount))
            checks["reduction_\(steps)_preserves_complete_mandatory"] = next.messages.first == snapshot.messages.first
                && next.messages.last == snapshot.messages.last
            candidate = next; steps += 1
        }
        let terminalReduction = try candidate.reducedForTokenAdmission()
        checks["mandatory_only_cannot_be_reduced"] = candidate.messages.count == 2 && candidate.includedRecentCount == 0
            && candidate.omittedRecentCount == 7 && terminalReduction == nil
        checks["candidate_byte_count_matches_actual_serialization"] = candidate.serializedBytes == (try candidate.serializedMessages().count)
        let oldSettings = Data("{\"conversationID\":\"synthetic-existing-chat\",\"endpointURL\":\"http://localhost:11234/v1/\",\"endpointModel\":\"synthetic-model\",\"profile\":\"custom-local\"}".utf8)
        try oldSettings.write(to: directory.appendingPathComponent("settings.json"))
        let loaded = LocalSettings.load(in: directory)
        checks["token_setting_migration_preserves_existing_selection"] = loaded.conversationID == "synthetic-existing-chat"
            && loaded.endpointModel == "synthetic-model" && loaded.endpointTokenBudget == nil
        checks["instructions_migration_preserves_historical_default"] = loaded.systemInstructions == nil
        var saved = loaded
        let instructions = "  Synthetic café e\u{301}\r\nUse exact sources.\t\u{0}\n  "
        saved.systemInstructions = instructions
        try saved.save(in: directory)
        let savedBytes = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        checks["saved_instructions_preserve_exact_utf8"] = LocalSettings.load(in: directory).systemInstructions.map { Data($0.utf8) } == Data(instructions.utf8)
        checks["saved_instructions_file_private"] = (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("settings.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
        saved.systemInstructions = String(repeating: "x", count: LocalSettings.maximumInstructionBytes + 1)
        do { try saved.save(in: directory); checks["oversized_instructions_refused_without_replacing_settings"] = false }
        catch { checks["oversized_instructions_refused_without_replacing_settings"] = try Data(contentsOf: directory.appendingPathComponent("settings.json")) == savedBytes }
        saved.systemInstructions = "Synthetic bounded instructions"
        saved.endpointModel = String(repeating: "x", count: LocalSettings.maximumEncodedBytes)
        do { try saved.save(in: directory); checks["oversized_encoded_settings_refused_without_replacement"] = false }
        catch { checks["oversized_encoded_settings_refused_without_replacement"] = try Data(contentsOf: directory.appendingPathComponent("settings.json")) == savedBytes }
        saved = loaded; saved.systemInstructions = String(repeating: "\u{0}", count: LocalSettings.maximumInstructionBytes)
        try saved.save(in: directory)
        checks["maximal_json_escaping_remains_backuppable"] = try Data(contentsOf: directory.appendingPathComponent("settings.json")).count <= LocalSettings.maximumEncodedBytes
            && LocalSettings.load(in: directory).systemInstructions.map { Data($0.utf8) } == Data(saved.systemInstructions!.utf8)
        saved.systemInstructions = ""
        try saved.save(in: directory)
        checks["empty_saved_instructions_survive_reload"] = LocalSettings.load(in: directory).systemInstructions?.isEmpty == true
        checks.merge(try recentCandidateChecks(store: store, semantic: semantic)) { _, new in new }
        checks.merge(try meteredContextChecks(store: store)) { _, new in new }
        checks.merge(try meteredLiteralChecks(store: store)) { _, new in new }
        checks.merge(try meteredLargeCandidateChecks(store: store, corrupt: { corruptEventID = $0 })) { _, new in new }
        checks.merge(try sqliteFenceChecks(store: store)) { _, new in new }
        checks.merge(try standaloneScopeChecks(store: store, semantic: semantic)) { _, new in new }
        checks.merge(try ReadCoverageChecks.run(store: store, semantic: semantic)) { _, new in new }
        checks.merge(try ContextComponentChecks.run()) { _, new in new }
        return checks
    }

    private static func standaloneScopeChecks(store: MemoryStore, semantic: SemanticIndex) throws -> [String: Bool] {
        let clock = SystemEpisodeClock(), id = UUID().uuidString
        let binding = EpisodeLocalReadBinding(version: "local-read-v1", initiator: .syntheticEvaluation,
            purpose: .contextSelection, requestID: id, descriptorVersion: "scope-fixture-v1",
            descriptorSHA256: MeteredRetrieval.digest(Data("synthetic scope fixture".utf8)))
        _ = try store.beginLocalReadEpisode(episodeID: id, projectID: "synthetic", binding: binding,
            limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: id, clock: clock)
        let foreign = try store.sourceReference(eventID: "foreign-event", projectID: "other-synthetic")!
        let manifest = try semantic.search(query: "Foreign", projectID: "other-synthetic", includeLiteral: false)
        let attempts: [(String, () throws -> Void)] = [
            ("read_scope_lexical_before_metadata", { _ = try MeteredRetrieval.lexicalSearch(store: store, query: "Foreign", projectID: foreign.projectID, lease: lease) }),
            ("read_scope_literal_before_metadata", { _ = try MeteredRetrieval.literalSearch(store: store, query: "Foreign", projectID: foreign.projectID, lease: lease) }),
            ("read_scope_source_load_before_payload", { _ = try MeteredRetrieval.load(store: store, reference: foreign, lease: lease) }),
            ("read_scope_page_before_payload", { _ = try MeteredRetrieval.page(store: store, eventID: foreign.eventID, projectID: foreign.projectID, offset: 0, length: 32, lease: lease) }),
            ("read_scope_reference_before_payload", { _ = try MeteredRetrieval.read(store: store, source: foreign, offset: 0, length: 32, lease: lease) }),
            ("read_scope_context_before_conversation", { _ = try ContextAssembler.prepare(store: store, conversationID: foreign.conversationID, projectID: foreign.projectID, prompt: "Synthetic", system: "Synthetic", episodeLease: lease) }),
            ("read_scope_chat_helper_before_conversation", { _ = try ChatContextPreparation.prepare(store: store, conversationID: foreign.conversationID, projectID: foreign.projectID, prompt: "Synthetic", system: "Synthetic", excludingEventID: "absent", episodeLease: lease) }),
            ("read_scope_semantic_before_encoder", { _ = try semantic.search(query: "Foreign", projectID: foreign.projectID, episodeLease: lease) }),
            ("read_scope_replay_before_manifest", { _ = try semantic.replay(manifestID: manifest.manifestID, projectID: foreign.projectID, episodeLease: lease) })
        ]
        var checks: [String: Bool] = [:]
        for (name, action) in attempts {
            do { try action(); checks[name] = false }
            catch { checks[name] = (error as? EpisodeBudgetError)?.failureCode == "episode_scope_mismatch" }
        }
        let beforeForgery = try lease.checkActive()
        checks["read_scope_rejection_inspects_no_resources"] = beforeForgery.charged == .zero && beforeForgery.held == .zero
        let forged = MemorySourceReference(sequence: foreign.sequence, eventID: foreign.eventID,
            conversationID: foreign.conversationID, projectID: "synthetic", role: foreign.role, status: foreign.status,
            createdAt: foreign.createdAt, digest: foreign.digest, byteCount: foreign.byteCount)
        do {
            _ = try MeteredRetrieval.read(store: store, source: forged, offset: 0, length: 32, lease: lease)
            checks["read_scope_forged_project_reference_rejected"] = false
        } catch { checks["read_scope_forged_project_reference_rejected"] = error is MeteredRetrievalError }
        let afterForgery = try lease.checkActive()
        checks["read_scope_forgery_never_charges_payload"] = afterForgery.charged.rawSourceBytes == 0
            && afterForgery.held.rawSourceBytes == 0 && afterForgery.charged.metadataRows == 1
        _ = try lease.finish(reason: .completed)
        return checks
    }

    private static func recentCandidateChecks(store: MemoryStore, semantic: SemanticIndex) throws -> [String: Bool] {
        let project = "synthetic-recent-candidate-cap"
        let chat = try store.createConversation(projectID: project, title: "Recent candidate starvation")
        let old = try store.append(conversationID: chat.id, role: .human,
            text: String(repeating: "Archived unrelated historical words. ", count: 1000) + "crowdoutkey original decision",
            status: .complete, turnID: "candidate-old-turn", eventID: "candidate-old-source")
        var excluded: Set<String> = []
        // Exceed the 100-candidate raw limit while keeping all complete recent
        // messages, including v3 metadata, within the unchanged 24 KiB cap.
        for index in 0..<101 {
            let id = "r\(index)"
            _ = try store.append(conversationID: chat.id, role: .human, text: "crowdoutkey",
                status: .complete, turnID: "candidate-turn-\(index)", eventID: id)
            excluded.insert(id)
        }
        let prompt = "What happened to crowdoutkey?"
        let recent = try ContextAssembler.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host rule", maximumEvidenceBytes: 0)
        let lexical = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host rule", excludingEventID: "synthetic-unsaved-current")
        let hybrid = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host rule", excludingEventID: "synthetic-unsaved-current", semanticIndex: semantic)
        return [
            "candidate_starvation_fixture_exceeds_raw_cap": recent.includedRecentCount == 101 && recent.omittedRecentCount == 1,
            "lexical_exclusions_apply_before_candidate_limit": try store.search(query: "crowdoutkey", projectID: project,
                limit: 100, excludingEventIDs: excluded).map(\.eventID) == [old.id],
            "literal_exclusions_apply_before_candidate_limit": try store.literalSearch(query: "crowdoutkey", projectID: project,
                limit: 100, excludingEventIDs: excluded).map(\.eventID) == [old.id],
            "send_lexical_reaches_archive_after_recent_exclusion": lexical.evidence.contains { $0.eventID == old.id },
            "send_hybrid_raw_fallback_reaches_archive_after_recent_exclusion": hybrid.evidence.contains { $0.eventID == old.id }
        ]
    }

    private static func meteredContextChecks(store: MemoryStore) throws -> [String: Bool] {
        let project = "synthetic-metered-context"
        let chat = try store.createConversation(projectID: project, title: "Metered recent context")
        let archive = try store.createConversation(projectID: project, title: "Metered archive")
        let recent = try store.append(conversationID: chat.id, role: .assistant, text: "Synthetic earlier complete source.",
            status: .complete, turnID: "metered-recent-turn", eventID: "metered-recent-source")
        let old = try store.append(conversationID: archive.id, role: .human, text: "meteredkey café archived original evidence.",
            status: .complete, turnID: "metered-old-turn", eventID: "metered-old-source")
        let fixture = try episode(store: store, conversationID: chat.id)
        let snapshot = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: "Where is meteredkey?", system: "Synthetic instruction", excludingEventID: fixture.currentID,
            episodeLease: fixture.lease)
        let receipt = try fixture.lease.checkActive()
        let queryPasses = 6 // load, digest, term search, two windows, excerpt materialization
        let expected = recent.byteCount * 2 + old.byteCount * queryPasses + (snapshot.evidence[0].excerpt.utf8.count + 1) * 2
        var checks: [String: Bool] = [
            "metered_context_one_composite_memory_operation": receipt.charged.memoryOperations == 1,
            "metered_context_counts_recent_load_digest_and_evidence_reread": receipt.charged.rawSourceBytes == expected,
            "metered_context_preserves_exact_request_and_historical_range": snapshot.messages.last?.content == "Where is meteredkey?" && snapshot.evidence.first?.eventID == old.id,
            "metered_context_audit_has_raw_work_version": String(decoding: snapshot.retrievalAuditJSON!, as: UTF8.self).contains("raw_work_v1")
        ]
        let again = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: "Where is meteredkey?", system: "Synthetic instruction", excludingEventID: fixture.currentID,
            episodeLease: fixture.lease)
        let repeated = try fixture.lease.checkActive()
        checks["metered_repeated_context_never_refunds_cached_source_work"] = repeated.charged.rawSourceBytes == expected * 2
            && repeated.charged.memoryOperations == 2 && again.evidence.first?.excerpt == snapshot.evidence.first?.excerpt
        _ = try fixture.lease.finish(reason: .cancelled)
        do {
            _ = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
                prompt: "Where is meteredkey?", system: "", excludingEventID: fixture.currentID, episodeLease: fixture.lease)
            checks["metered_context_stop_blocks_new_source_work"] = false
        } catch let error as EpisodeBudgetError {
            checks["metered_context_stop_blocks_new_source_work"] = error.failureCode == "episode_inactive"
        }
        var limits = EpisodeLimits(); limits.resources.memoryOperations = 0
        let noSlot = try episode(store: store, conversationID: chat.id, limits: limits)
        do {
            _ = try ContextAssembler.prepare(store: store, conversationID: chat.id, projectID: project,
                prompt: "meteredkey", system: "", episodeLease: noSlot.lease)
            checks["metered_context_empty_operation_budget_fails_before_payload_read"] = false
        } catch let error as EpisodeBudgetError {
            let state = try store.episodeReceipt(id: noSlot.lease.episodeID, clock: noSlot.clock.now())
            checks["metered_context_empty_operation_budget_fails_before_payload_read"] = error.failureCode == "episode_budget_exceeded" && state.charged.rawSourceBytes == 0
        }
        return checks
    }

    private static func meteredLiteralChecks(store: MemoryStore) throws -> [String: Bool] {
        let project = "synthetic-metered-literal"
        let archive = try store.createConversation(projectID: project, title: "Paged UTF8 matching")
        let text = String(repeating: "x", count: 4094) + "é🐈targetcafé suffix"
        let first = try store.append(conversationID: archive.id, role: .human, text: text,
            status: .complete, turnID: "literal-utf8-turn", eventID: "literal-utf8-source")
        let second = try store.append(conversationID: archive.id, role: .human, text: "A second é🐈target matching source.",
            status: .complete, turnID: "literal-second-turn", eventID: "literal-second-source")
        let fixture = try episode(store: store, conversationID: archive.id)
        let report = try MeteredRetrieval.literalSearch(store: store, query: "é🐈target", projectID: project,
            limit: 1, lease: fixture.lease, maximumSources: 1)
        let page = try MeteredRetrieval.page(store: store, eventID: first.id, projectID: project,
            offset: report.hits[0].excerptOffset, length: report.hits[0].excerpt.utf8.count, lease: fixture.lease)
        let beforeRepeat = try fixture.lease.checkActive()
        _ = try MeteredRetrieval.page(store: store, eventID: first.id, projectID: project,
            offset: report.hits[0].excerptOffset, length: report.hits[0].excerpt.utf8.count, lease: fixture.lease)
        let afterRepeat = try fixture.lease.checkActive()
        let frontier = report.sourceFrontier
        _ = try store.append(conversationID: archive.id, role: .human, text: "Future é🐈target result outside snapshot.",
            status: .complete, turnID: "literal-future-turn", eventID: "literal-future-source")
        let continued = try MeteredRetrieval.literalSearch(store: store, query: "é🐈target", projectID: project,
            limit: 8, lease: fixture.lease, continuation: report.continuation)
        var checks: [String: Bool] = [
            "metered_literal_match_crosses_page_and_utf8_boundaries": report.hits[0].eventID == first.id && report.hits[0].excerptOffset == 4094 && page.text == "é🐈target",
            "metered_literal_returned_match_has_complete_source_seal": report.inspectedSources == 1 && report.rawWorkCharged > first.byteCount * 4,
            "metered_literal_source_window_has_explicit_continuation": report.continuation != nil && !report.complete && report.incompleteReason != nil,
            "metered_literal_continuation_freezes_source_frontier": continued.sourceFrontier == frontier && continued.hits.map(\.eventID) == [second.id],
            "metered_source_pages_each_cost_one_host_operation": afterRepeat.charged.memoryOperations == beforeRepeat.charged.memoryOperations + 1,
            "metered_repeated_source_page_counts_materialized_lookahead": afterRepeat.charged.rawSourceBytes == beforeRepeat.charged.rawSourceBytes + page.byteCount + 1
        ]
        let newEpisode = try episode(store: store, conversationID: archive.id)
        do {
            _ = try MeteredRetrieval.literalSearch(store: store, query: "é🐈target", projectID: project,
                lease: newEpisode.lease, continuation: report.continuation)
            checks["metered_literal_continuation_cannot_replenish_another_episode"] = false
        } catch { checks["metered_literal_continuation_cannot_replenish_another_episode"] = true }
        do {
            _ = try MeteredRetrieval.literalSearch(store: store, query: "changed", projectID: project,
                lease: fixture.lease, continuation: report.continuation)
            checks["metered_literal_continuation_query_mismatch_rejected"] = false
        } catch { checks["metered_literal_continuation_query_mismatch_rejected"] = true }
        do {
            _ = try MeteredRetrieval.page(store: store, eventID: first.id, projectID: project,
                offset: Int.max, length: 4096, lease: fixture.lease)
            checks["metered_page_overflowing_range_rejected_before_source_read"] = false
        } catch { checks["metered_page_overflowing_range_rejected_before_source_read"] = true }
        return checks
    }

    private static func meteredLargeCandidateChecks(store: MemoryStore, corrupt: (String) -> Void) throws -> [String: Bool] {
        let project = "synthetic-metered-large-candidates"
        let archive = try store.createConversation(projectID: project, title: "One hundred bounded maximum sources")
        // NUL padding keeps this 400 MiB authoritative fixture's FTS index
        // small while retaining the complete 4 MiB payload on every event.
        let prefix = "budgetneedle "
        let text = prefix + String(repeating: "\0", count: MemoryStore.maximumPayloadBytes - prefix.utf8.count)
        for number in 0..<100 {
            _ = try store.append(conversationID: archive.id, role: .human, text: text, status: .complete,
                turnID: "large-metered-turn-\(number)", eventID: "large-metered-source-\(number)")
        }
        let references = try store.lexicalCandidateReferences(query: "budgetneedle", projectID: project, limit: 100)
        var limits = EpisodeLimits(); limits.resources.rawSourceBytes = 30 * 1_048_576
        let fixture = try episode(store: store, conversationID: archive.id, limits: limits)
        // The next ranked candidate has a genuinely bad digest. A bounded
        // search must stop before loading it, even though FTS can find it.
        // Same-connection source-only corruption preserves the accounting
        // confidence needed to test actual admission before payload access.
        corrupt(references[1].eventID)
        let report = try MeteredRetrieval.lexicalSearch(store: store, query: "budgetneedle", projectID: project,
            limit: 100, lease: fixture.lease)
        let again = try MeteredRetrieval.lexicalSearch(store: store, query: "budgetneedle", projectID: project,
            limit: 100, lease: fixture.lease, continuation: report.continuation)
        let receipt = try fixture.lease.checkActive()
        var checks: [String: Bool] = [
            "metered_stress_has_one_hundred_four_mib_metadata_candidates": references.count == 100 && references.allSatisfy { $0.byteCount == MemoryStore.maximumPayloadBytes },
            "metered_lexical_stops_before_unaffordable_ranked_blob": report.inspectedCandidates == 1 && report.hits.count == 1 && report.continuation?.nextCandidate == 1,
            "metered_lexical_stress_counts_digest_and_preview_passes": receipt.charged.rawSourceBytes == MemoryStore.maximumPayloadBytes * 6 && report.rawWorkCharged == receipt.charged.rawSourceBytes,
            "metered_lexical_continuation_retains_unaffordable_candidate": again.inspectedCandidates == 0 && again.rawWorkCharged == 0 && again.continuation?.candidates == report.continuation?.candidates && again.continuation?.nextCandidate == 1
        ]
        do {
            _ = try store.loadCandidate(reference: references[1])
            checks["metered_unread_candidate_fixture_has_real_source_corruption"] = false
        } catch { checks["metered_unread_candidate_fixture_has_real_source_corruption"] = true }
        let literal = try episode(store: store, conversationID: archive.id, limits: limits)
        let miss = try MeteredRetrieval.literalSearch(store: store, query: "absent-public-marker", projectID: project,
            lease: literal.lease)
        checks["metered_literal_miss_cannot_scan_unbounded_archive"] = miss.hits.isEmpty && miss.inspectedSources == 1
            && miss.incompleteReason == "raw_source_budget" && miss.continuation != nil && miss.rawWorkCharged <= limits.resources.rawSourceBytes
        let deadline = try episode(store: store, conversationID: archive.id)
        deadline.clock.calls = 0; deadline.clock.expireAfterCalls = 100
        do {
            _ = try MeteredRetrieval.literalSearch(store: store, query: "absent-public-marker", projectID: project, lease: deadline.lease)
            checks["metered_literal_deadline_interrupts_source_page_walk"] = false
        } catch let error as EpisodeBudgetError {
            checks["metered_literal_deadline_interrupts_source_page_walk"] = error.failureCode == "episode_deadline_exceeded"
        }
        return checks
    }

    private static func sqliteFenceChecks(store: MemoryStore) throws -> [String: Bool] {
        let chat = try store.createConversation(projectID: "synthetic-sql-fence", title: "Interruptible metadata work")
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(":memory:", &database) == SQLITE_OK, let database else { throw MemoryError.database("fixture open failed") }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        let sql = "WITH RECURSIVE rows(value) AS (SELECT 1 UNION ALL SELECT value+1 FROM rows WHERE value<100000000) SELECT sum(value) FROM rows"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw MemoryError.database("fixture prepare failed") }
        let deadline = try episode(store: store, conversationID: chat.id)
        let fence = try deadline.lease.progressGuard()
        var interruptedBySQLite = false, checks: [String: Bool] = [:]
        do {
            _ = try fence.perform(on: database) {
                // Expiration occurs in the actual SQLite VM callback, after
                // the wrapper's preliminary clock checks have completed.
                deadline.clock.expireAfterCalls = deadline.clock.calls + 2
                let code = sqlite3_step(statement)
                interruptedBySQLite = code == SQLITE_INTERRUPT
                guard code == SQLITE_ROW else { throw MemoryError.database("fixture query interrupted") }
                return Int(sqlite3_column_int64(statement, 0))
            }
            checks["sqlite_progress_fence_interrupts_expensive_actual_vm_at_deadline"] = false
        } catch let error as EpisodeBudgetError {
            checks["sqlite_progress_fence_interrupts_expensive_actual_vm_at_deadline"] = interruptedBySQLite && error.failureCode == "episode_deadline_exceeded"
        }
        sqlite3_finalize(statement); statement = nil
        guard sqlite3_prepare_v2(database, "SELECT 1", -1, &statement, nil) == SQLITE_OK else { throw MemoryError.database("fixture reprepare failed") }
        checks["sqlite_progress_fence_restores_handler_after_interruption"] = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement); statement = nil
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw MemoryError.database("fixture reprepare failed") }
        let stopped = try episode(store: store, conversationID: chat.id), stoppedLease = stopped.lease
        let entered = DispatchSemaphore(value: 0), stopFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            entered.wait()
            _ = try? stoppedLease.finish(reason: .cancelled)
            stopFinished.signal()
        }
        interruptedBySQLite = false
        do {
            _ = try store.withEpisodeSQLFence(lease: stoppedLease) {
                // Hold the authoritative owner mutex while the other thread
                // requests Stop. The progress callback must not reenter it.
                let guardForSQL = try stoppedLease.progressGuard()
                return try guardForSQL.perform(on: database) {
                    entered.signal()
                    let code = sqlite3_step(statement)
                    interruptedBySQLite = code == SQLITE_INTERRUPT
                    guard code == SQLITE_ROW else { throw MemoryError.database("fixture query interrupted") }
                    return Int(sqlite3_column_int64(statement, 0))
                }
            }
            checks["sqlite_progress_stop_interrupts_while_owner_mutex_is_held"] = false
        } catch let error as EpisodeBudgetError {
            checks["sqlite_progress_stop_interrupts_while_owner_mutex_is_held"] = interruptedBySQLite && error.failureCode == "episode_inactive"
        }
        checks["sqlite_progress_stop_releases_owner_without_callback_deadlock"] = stopFinished.wait(timeout: .now() + 2) == .success
        return checks
    }

    private struct EpisodeFixture { let lease: EpisodeLease; let currentID: String; let clock: FixtureClock }
    private final class FixtureClock: EpisodeClockSource {
        private let lock = NSLock()
        var ticks: UInt64 = 1_000_000_000, calls = 0
        var expireAfterCalls: Int?
        func now() throws -> EpisodeClockSnapshot {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if let expireAfterCalls, calls >= expireAfterCalls { ticks = 200_000_000_000 }
            return EpisodeClockSnapshot(domain: "synthetic-metered-context-clock", continuousNanoseconds: ticks, utc: Date())
        }
    }
    private static func episode(store: MemoryStore, conversationID: String, limits: EpisodeLimits = .init()) throws -> EpisodeFixture {
        let clock = FixtureClock(), id = UUID().uuidString, currentID = "metered-current-" + UUID().uuidString
        _ = try store.acceptRequestAndBeginEpisode(conversationID: conversationID, turnID: "metered-turn-" + id,
            humanEventID: currentID, episodeID: id, text: "Synthetic accepted top-level request", limits: limits, clock: clock.now())
        return EpisodeFixture(lease: EpisodeLease(ledger: store, episodeID: id, clock: clock), currentID: currentID, clock: clock)
    }
    private static func alterSource(_ database: OpaquePointer, id: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "UPDATE events SET payload=zeroblob(byte_count) WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw MemoryError.database("fixture prepare failed") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw MemoryError.database("fixture mutation failed") }
    }
}
