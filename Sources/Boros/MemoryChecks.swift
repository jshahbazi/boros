import Foundation
import CSQLite
import Darwin

/// Deterministic synthetic checks. No captured user content is read or printed.
enum MemoryChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-memory-check-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MemoryStore? = try MemoryStore(directory: directory)
        var checks: [String: Bool] = [:]
        let first = try store!.createConversation(projectID: "synthetic-alpha", title: "Synthetic history")
        let second = try store!.createConversation(projectID: "synthetic-beta", title: "Separate scope")
        let payload = String(repeating: "archived source line\n", count: 6000) + "MIDPAYLOAD_SENTINEL exact record café \u{1F680}\n" + String(repeating: "continued source line\n", count: 6000)
        let saved = try store!.append(conversationID: first.id, role: .human, text: payload, status: .complete, turnID: "turn-a", eventID: "synthetic-large-event")
        _ = try store!.append(conversationID: second.id, role: .human, text: "MIDPAYLOAD_SENTINEL in another project", status: .complete, turnID: "turn-b", eventID: "synthetic-other-project")
        let repeated = try store!.append(conversationID: first.id, role: .human, text: payload, status: .complete, turnID: "turn-a", eventID: saved.id)
        checks["idempotent_exact_capture"] = try saved.id == repeated.id && saved.createdAt == repeated.createdAt && store!.events(conversationID: first.id).count == 1
        checks["idempotency_conflict_rejected"] = rejects {
            _ = try store!.append(conversationID: first.id, role: .human, text: "changed", status: .complete, turnID: "turn-a", eventID: saved.id)
        }
        checks["idempotency_scope_conflict_rejected"] = rejects {
            _ = try store!.append(conversationID: second.id, role: .human, text: payload, status: .complete, turnID: "turn-a", eventID: saved.id)
        }
        checks["oversized_capture_rejected"] = rejects {
            _ = try store!.append(conversationID: first.id, role: .human, text: String(repeating: "x", count: MemoryStore.maximumPayloadBytes + 1), status: .complete, turnID: "oversized-turn", eventID: "oversized-event")
        }
        checks["rejected_capture_leaves_history_intact"] = try store!.events(conversationID: first.id).map(\.id) == [saved.id]
        checks["bounded_recent_query_and_count"] = try store!.recentEvents(conversationID: first.id, limit: 1).map(\.id) == [saved.id] && store!.eventCount(conversationID: first.id) == 1
        checks["recent_payload_bytes_bound_before_loading"] = try store!.recentEvents(conversationID: first.id, limit: 100, maximumBytes: 64).isEmpty
        let lexical = try store!.search(query: "MIDPAYLOAD_SENTINEL", projectID: "synthetic-alpha")
        let literal = try store!.literalSearch(query: "MIDPAYLOAD_SENTINEL exact record café", projectID: "synthetic-alpha")
        checks["lexical_middle_source_retrieval"] = lexical.count == 1 && lexical[0].eventID == saved.id && lexical[0].excerpt.contains("MIDPAYLOAD_SENTINEL") && lexical[0].excerptOffset > 0
        checks["literal_scope_isolation"] = literal.count == 1 && literal[0].projectID == "synthetic-alpha" && literal[0].eventID == saved.id
        let hitConversation = try store!.createConversation(projectID: "synthetic-hit", title: "Hit selection fixtures")
        let clustered = try store!.append(conversationID: hitConversation.id, role: .human,
            text: "unrelatedfirstterm " + String(repeating: " ", count: 900) + "densealpha densebeta densegamma", status: .complete,
            turnID: "hit-cluster-turn", eventID: "hit-cluster-event")
        let clusteredTerms = MemoryStore.hit(clustered, terms: ["unrelatedfirstterm", "densealpha", "densebeta", "densegamma"])
        let reorderedTerms = MemoryStore.hit(clustered, terms: ["densegamma", "unrelatedfirstterm", "densebeta", "densealpha"])
        checks["hit_centers_on_dense_distinctive_terms"] = clusteredTerms.excerpt.contains("densealpha") && clusteredTerms.excerpt.contains("densegamma")
            && clusteredTerms.excerptOffset > "unrelatedfirstterm ".utf8.count
        checks["hit_query_order_permutation_preserves_coverage"] = clusteredTerms.excerptOffset == reorderedTerms.excerptOffset
            && clusteredTerms.digest == reorderedTerms.digest
        let unicodePrefix = String(repeating: "x", count: 220)
        let unicodeHitEvent = try store!.append(conversationID: hitConversation.id, role: .assistant,
            text: unicodePrefix + " é 🚀 exactneedle suffix", status: .complete, turnID: "hit-unicode-turn", eventID: "hit-unicode-event")
        let unicodeHit = MemoryStore.hit(unicodeHitEvent, terms: ["exactneedle"])
        let unicodeBytes = Data(unicodeHitEvent.text.utf8)
        let unicodeEnd = min(unicodeBytes.count, unicodeHit.excerptOffset + unicodeHit.excerpt.utf8.count)
        let unicodeSlice = unicodeBytes.subdata(in: unicodeHit.excerptOffset..<unicodeEnd)
        checks["hit_unicode_offset_and_digest_are_exact"] = unicodeHit.excerpt.contains("exactneedle")
            && unicodeSlice == Data(unicodeHit.excerpt.utf8)
            && unicodeHit.digest == unicodeHitEvent.digest
        let repeatedLiteralEvent = try store!.append(conversationID: hitConversation.id, role: .human,
            text: "needle before " + String(repeating: "x", count: 700) + "needle after", status: .complete, turnID: "hit-literal-turn", eventID: "hit-literal-event")
        let repeatedLiteral = MemoryStore.hit(repeatedLiteralEvent, terms: ["needle"], literal: true)
        checks["hit_literal_keeps_first_match"] = repeatedLiteral.excerptOffset == 0 && !repeatedLiteral.excerpt.contains("needle after")
        let longGrapheme = "e" + String(repeating: "\u{301}", count: 128)
        let combiningPayload = "capneedle " + String(repeating: longGrapheme + " ", count: 600)
        let cappedEvent = try store!.append(conversationID: hitConversation.id, role: .human,
            text: combiningPayload,
            status: .complete, turnID: "hit-cap-turn", eventID: "hit-cap-event")
        let cappedHit = MemoryStore.hit(cappedEvent, terms: ["capneedle"])
        checks["hit_excerpt_respects_4096_utf8_bytes"] = cappedHit.excerpt.utf8.count <= MemoryStore.maximumPageBytes
            && cappedHit.excerpt.utf8.count >= MemoryStore.maximumPageBytes - 3
            && Data(cappedHit.excerpt.utf8) == Data(cappedEvent.text.utf8).prefix(cappedHit.excerpt.utf8.count)
        checks["quoted_fts_syntax_is_data"] = try store!.search(query: "MIDPAYLOAD_SENTINEL\" OR *", projectID: "synthetic-alpha").isEmpty
        let frozenFrontier = try store!.sourceFrontier(projectID: "synthetic-alpha")
        let references = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: 0, throughSequence: frozenFrontier, limit: 10)
        checks["source_manifest_is_scoped_payload_free_metadata"] = references.count == 1
            && references[0].eventID == saved.id && references[0].projectID == saved.projectID
            && references[0].conversationID == saved.conversationID && references[0].digest == saved.digest
            && references[0].byteCount == saved.byteCount && references[0].role == .human && references[0].status == .complete
        let candidates = try store!.lexicalCandidateReferences(query: "MIDPAYLOAD_SENTINEL", projectID: first.projectID)
        checks["metadata_lexical_candidates_preserve_scope_and_ranking"] = candidates == references
        checks["metadata_candidate_explicit_full_load_matches_source"] = try store!.loadCandidate(reference: candidates[0]).text == saved.text
        checks["metadata_recent_suffix_matches_payload_suffix"] = try store!.recentSourceReferences(conversationID: first.id, limit: 100, maximumBytes: saved.byteCount).map(\.eventID) == store!.recentEvents(conversationID: first.id, limit: 100, maximumBytes: saved.byteCount).map(\.id)
        checks["metadata_recent_bound_omits_unaffordable_suffix"] = try store!.recentSourceReferences(conversationID: first.id, limit: 100, maximumBytes: 64).isEmpty
        checks["metadata_conversation_scope_lookup"] = try store!.conversationProjectID(conversationID: first.id) == first.projectID
        checks["source_reference_matches_bounded_manifest"] = try store!.sourceReference(eventID: saved.id, projectID: saved.projectID) == references[0]
        checks["source_reference_cross_scope_denied"] = try store!.sourceReference(eventID: saved.id, projectID: second.projectID) == nil
        checks["source_reference_missing_is_explicit"] = try store!.sourceReference(eventID: "missing-reference", projectID: first.projectID) == nil
        checks["source_frontier_empty_project_is_zero"] = try store!.sourceFrontier(projectID: "synthetic-empty") == 0
        checks["source_manifest_invalid_bounds_rejected"] = rejects { _ = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: -1, limit: 1) }
            && rejects { _ = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: 0, throughSequence: -1, limit: 1) }
            && rejects { _ = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: 0, limit: 1001) }
        checks["source_manifest_zero_frontier_is_empty"] = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: 0, throughSequence: 0, limit: 10).isEmpty
        let unicode = try store!.append(conversationID: first.id, role: .assistant, text: "A\u{1F680}éZ", status: .cancelled, turnID: "unicode-turn", eventID: "unicode-event")
        checks["source_manifest_frozen_frontier_excludes_new_publications"] = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: 0, throughSequence: frozenFrontier, limit: 10) == references
        let nextReferences = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: frozenFrontier, limit: 1)
        checks["source_manifest_keyset_page_preserves_original_status"] = nextReferences.count == 1
            && nextReferences[0].eventID == unicode.id && nextReferences[0].status == .cancelled && nextReferences[0].sequence > frozenFrontier
        checks["source_manifest_cursor_beyond_upper_bound_is_empty"] = try store!.sourceManifest(projectID: "synthetic-alpha", afterSequence: nextReferences[0].sequence, throughSequence: frozenFrontier, limit: 1).isEmpty
        checks["utf8_start_boundary_rejected"] = rejects { _ = try store!.read(eventID: unicode.id, offset: 2, length: 4) }
        checks["utf8_small_page_rejected"] = rejects { _ = try store!.read(eventID: unicode.id, offset: 1, length: 1) }
        let boundary = try store!.read(eventID: unicode.id, offset: 0, length: 4)
        checks["utf8_end_boundary_shortened"] = boundary.text == "A" && boundary.nextOffset == 1 && boundary.byteCount == 1 && boundary.status == .cancelled
        checks["page_bounds_rejected"] = rejects { _ = try store!.read(eventID: saved.id, offset: saved.byteCount + 1, length: 16) } && rejects { _ = try store!.read(eventID: saved.id, offset: 0, length: 4097) }
        var reconstructed = Data()
        var offset = 0
        repeat {
            let page = try store!.read(eventID: saved.id, offset: offset, length: 1024)
            reconstructed.append(contentsOf: page.text.utf8)
            guard let next = page.nextOffset else { break }
            guard next > offset else { throw MemoryError.invalid("pagination failed to make progress") }
            offset = next
        } while true
        checks["exact_paginated_payload_roundtrip"] = reconstructed == Data(payload.utf8)
        let eof = try store!.read(eventID: saved.id, offset: saved.byteCount, length: 16)
        checks["empty_eof_page"] = eof.text.isEmpty && eof.nextOffset == nil && eof.byteCount == 0
        let nulPayload = "before\0NULAFTER_SENTINEL after"
        let nul = try store!.append(conversationID: first.id, role: .human, text: nulPayload, status: .complete, turnID: "nul-turn", eventID: "nul-event")
        checks["embedded_nul_roundtrip_and_literal_search"] = try store!.events(conversationID: first.id).last?.text == nulPayload && store!.literalSearch(query: "NULAFTER_SENTINEL", projectID: "synthetic-alpha").first?.eventID == nul.id
        checks["embedded_nul_lexical_search"] = try store!.search(query: "NULAFTER_SENTINEL", projectID: "synthetic-alpha").first?.eventID == nul.id
        try store!.saveDraft(conversationID: first.id, text: "unsent draft café\nexact line")
        try store!.saveSetting(key: "synthetic-setting", value: "retained configuration")
        checks["second_owner_rejected"] = rejects { _ = try MemoryStore(directory: directory) }
        checks["private_store_permissions"] = privatePermissions(directory, expected: 0o700) && privatePermissions(directory.appendingPathComponent("memory.sqlite3"), expected: 0o600) && privatePermissions(directory.appendingPathComponent("owner.lock"), expected: 0o600) && privatePermissions(directory.appendingPathComponent("memory.sqlite3-wal"), expected: 0o600) && privatePermissions(directory.appendingPathComponent("memory.sqlite3-shm"), expected: 0o600)
        let durability = try store!.durabilityConfiguration()
        checks["wal_full_durability_configuration"] = durability.journalMode == "wal" && durability.synchronous == 2

        let current = try store!.append(conversationID: first.id, role: .human, text: "current exact prompt", status: .complete, turnID: "current-turn", eventID: "current-human")
        let snapshot = try ContextAssembler.prepare(store: store!, conversationID: first.id, projectID: "synthetic-alpha", prompt: current.text, system: "Fixed test system", budgetBytes: 4096, excludingEventID: current.id, historicalQuery: "MIDPAYLOAD_SENTINEL", maximumRecentBytes: 512, maximumEvidenceBytes: 2048)
        checks["context_preserves_current_prompt_once"] = snapshot.messages.last?.content == current.text && snapshot.messages.filter { $0.content == current.text }.count == 1
        checks["context_matches_serialized_byte_budget"] = snapshot.serializedBytes == (try snapshot.serializedMessages().count) && snapshot.serializedBytes <= 4096
        checks["incomplete_history_explicitly_marked"] = snapshot.messages.contains { $0.role == "assistant" && $0.content.contains("capture status: cancelled") }
        checks["retrieved_evidence_retains_source_ids"] = snapshot.evidence.map(\.eventID).contains(saved.id) && snapshot.messages.contains { $0.role == "user" && $0.content.contains("event_id: \(saved.id)") }
        checks["retrieved_evidence_has_no_system_authority"] = snapshot.messages.filter { $0.role == "system" }.count == 1 && !snapshot.messages[0].content.contains("MIDPAYLOAD_SENTINEL")
        checks["mandatory_context_overflow_rejected"] = rejects {
            _ = try ContextAssembler.prepare(store: store!, conversationID: first.id, projectID: "synthetic-alpha", prompt: String(repeating: "x", count: 4096), system: "fixed", budgetBytes: 100)
        }
        checks["context_scope_mismatch_rejected"] = rejects {
            _ = try ContextAssembler.prepare(store: store!, conversationID: first.id, projectID: "synthetic-beta", prompt: "question", system: "fixed")
        }
        checks["context_omission_keeps_durable_full_history"] = try snapshot.omittedRecentCount > 0 && store!.events(conversationID: first.id).first?.text == payload
        checks.merge(try invocationChecks(store: store!, conversationID: first.id, otherConversationID: second.id)) { _, new in new }
        store = nil
        store = try MemoryStore(directory: directory)
        checks["restart_payload_draft_settings_persistence"] = try store!.events(conversationID: first.id).first?.text == payload && store!.loadDraft(conversationID: first.id) == "unsent draft café\nexact line" && store!.loadSetting(key: "synthetic-setting") == "retained configuration"
        checks["restart_retrieval_persistence"] = try store!.search(query: "MIDPAYLOAD_SENTINEL", projectID: "synthetic-alpha").first?.eventID == saved.id
        let recovered = try store!.invocation(id: "recovery-invocation")
        let recoveredEmpty = try store!.invocation(id: "empty-recovery-invocation")
        let recoveryEvents = try store!.events(conversationID: first.id)
        checks["interrupted_received_chunks_recovered_partial"] = recovered?.recovered == true && recovered?.finalStatus == .partial && recovered?.terminalReason == .interrupted && recoveryEvents.first { $0.id == "recovery-assistant" }?.text == "committed interrupted fragment café\u{1F680}"
        checks["interrupted_empty_attempt_recovered_failed"] = recoveredEmpty?.recovered == true && recoveredEmpty?.finalStatus == .failed && recoveredEmpty?.terminalReason == .interrupted && recoveryEvents.first { $0.id == "empty-recovery-assistant" }?.text == ""
        checks["interrupted_output_search_publication"] = try store!.search(query: "interrupted fragment", projectID: "synthetic-alpha").first?.eventID == "recovery-assistant"
        checks["late_terminal_callback_after_recovery_rejected"] = rejects { _ = try store!.finalizeInvocation(invocationID: "recovery-invocation", status: .complete) }
        let recoveredTimestamp = recovered?.finalizedAt
        store = nil
        store = try MemoryStore(directory: directory)
        checks["recovery_second_restart_does_not_duplicate_events"] = try store!.events(conversationID: first.id).count == recoveryEvents.count && store!.invocation(id: "recovery-invocation")?.finalizedAt == recoveredTimestamp
        checks.merge(try searchFrontierChecks(store: store!)) { _, new in new }
        store = nil
        checks.merge(try migrationChecks()) { _, new in new }
        return checks
    }

    private static func searchFrontierChecks(store: MemoryStore) throws -> [String: Bool] {
        let project = "synthetic-search-frontier"
        let chat = try store.createConversation(projectID: project, title: "Frozen raw candidates")
        let old = try store.append(conversationID: chat.id, role: .human, text: "frozenrawneedle original evidence",
            status: .complete, turnID: "frozen-search-old-turn", eventID: "frozen-search-old-source")
        let frontier = try store.sourceFrontier(projectID: project)
        for index in 0..<120 {
            _ = try store.append(conversationID: chat.id, role: .human, text: "frozenrawneedle later evidence",
                status: .complete, turnID: "frozen-search-later-\(index)", eventID: "frozen-search-later-\(index)")
        }
        return [
            "lexical_frontier_filters_before_candidate_limit": try store.search(query: "frozenrawneedle", projectID: project,
                limit: 100, throughSequence: frontier).map(\.eventID) == [old.id],
            "literal_frontier_filters_before_candidate_limit": try store.literalSearch(query: "frozenrawneedle", projectID: project,
                limit: 100, throughSequence: frontier).map(\.eventID) == [old.id],
            "raw_search_zero_frontier_is_empty": try store.search(query: "frozenrawneedle", projectID: project, throughSequence: 0).isEmpty
                && store.literalSearch(query: "frozenrawneedle", projectID: project, throughSequence: 0).isEmpty,
            "raw_search_negative_frontier_rejected": rejects { _ = try store.search(query: "frozenrawneedle", projectID: project, throughSequence: -1) }
                && rejects { _ = try store.literalSearch(query: "frozenrawneedle", projectID: project, throughSequence: -1) }
        ]
    }

    private static func invocationChecks(store: MemoryStore, conversationID: String, otherConversationID: String) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let human = try store.append(conversationID: conversationID, role: .human, text: "synthetic invocation question", status: .complete, turnID: "invocation-turn", eventID: "invocation-human")
        let body = Data("{ \"model\":\"synthetic\", \"messages\":[{\"role\":\"user\",\"content\":\"SNAPSHOT_ONLY_SENTINEL password is a word\"}], \"stream\":true }".utf8)
        let admission = Data("{ \"input_tokens\":17, \"output_reserve\":32, \"context_limit\":2048 }".utf8)
        func begin(id: String = "synthetic-invocation", assistant: String = "invocation-assistant", destination: String = "http://localhost:11234/v1/chat/completions", request: Data? = nil, receipt: Data? = nil, conversation: String? = nil, humanID: String? = nil) throws -> StoredInvocation {
            try store.beginInvocation(invocationID: id, conversationID: conversation ?? conversationID, turnID: human.turnID, humanEventID: humanID ?? human.id, assistantEventID: assistant, providerIdentity: destination, requestBody: request ?? body, admissionJSON: receipt ?? admission)
        }
        let attempt = try begin()
        let repeated = try begin()
        checks["invocation_exact_request_and_admission_snapshot"] = attempt.requestBody == body && attempt.admissionJSON == admission && attempt.providerIdentity == "http://localhost:11234/v1/chat/completions" && attempt.chunkCount == 0 && attempt.observedBytes == 0 && attempt.finalStatus == nil
        checks["invocation_begin_idempotent_without_new_attempt"] = attempt.id == repeated.id && attempt.createdAt == repeated.createdAt
        checks["invocation_request_replay_conflict_rejected"] = rejects { _ = try begin(request: Data("{}".utf8)) }
        checks["invocation_admission_replay_conflict_rejected"] = rejects { _ = try begin(receipt: Data("{}".utf8)) }
        checks["invocation_destination_replay_conflict_rejected"] = rejects { _ = try begin(destination: "http://127.0.0.1:11234/v1/chat/completions") }
        checks["invocation_scope_conflict_rejected"] = rejects { _ = try begin(conversation: otherConversationID) }
        checks["invocation_requires_matching_committed_human"] = rejects { _ = try begin(id: "wrong-human-attempt", assistant: "wrong-human-assistant", humanID: "unicode-event") }
        checks["invocation_missing_human_rejected"] = rejects { _ = try begin(id: "missing-human-attempt", assistant: "missing-human-assistant", humanID: "missing-human") }
        checks["invocation_assistant_id_reservation_unique"] = rejects { _ = try begin(id: "second-reserved-attempt") }
        checks["invocation_existing_event_id_rejected"] = rejects { _ = try begin(id: "existing-event-attempt", assistant: human.id) }
        checks["invocation_direct_event_publication_rejected"] = rejects { _ = try store.append(conversationID: conversationID, role: .assistant, text: "bypass", status: .complete, turnID: human.turnID, eventID: attempt.assistantEventID) }
        checks["invocation_credential_fields_rejected"] = ["{\"api_key\":\"synthetic\"}", "{\"nested\":[{\"Authorization\":\"synthetic\"}]}", "{\"headers\":{}}"].allSatisfy { value in
            rejects { _ = try begin(id: "credential-attempt", assistant: "credential-assistant", request: Data(value.utf8)) }
        }
        checks["invocation_invalid_request_encoding_rejected"] = rejects { _ = try begin(id: "invalid-request-attempt", assistant: "invalid-request-assistant", request: Data([0xff])) } && rejects { _ = try begin(id: "array-request-attempt", assistant: "array-request-assistant", request: Data("[]".utf8)) }
        checks["invocation_oversized_request_rejected"] = rejects { _ = try begin(id: "oversized-request-attempt", assistant: "oversized-request-assistant", request: Data(repeating: 0x20, count: MemoryStore.maximumPayloadBytes + 1)) }
        checks["invocation_oversized_or_credential_admission_rejected"] = rejects { _ = try begin(id: "oversized-admission-attempt", assistant: "oversized-admission-assistant", receipt: Data(repeating: 0x20, count: 65537)) } && rejects { _ = try begin(id: "credential-admission-attempt", assistant: "credential-admission-assistant", receipt: Data("{\"api_key\":\"synthetic\"}".utf8)) }
        checks["invocation_unsafe_provider_identity_rejected"] = ["https://example.com/v1/", "http://localhost:11234/v1/?key=synthetic", "http://user:synthetic@localhost:11234/v1/", "http://localhost:11234/v1/#key", "native:../profile"].allSatisfy { destination in
            rejects { _ = try begin(id: "unsafe-provider-attempt", assistant: "unsafe-provider-assistant", destination: destination) }
        }
        let chunk0 = "JOURNAL_SENTINEL exact\0café "
        let chunk1 = "\u{1F680} retained suffix"
        checks["invocation_out_of_order_first_chunk_rejected"] = rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 1, text: chunk1) }
        checks["invocation_empty_and_invalid_sequence_rejected"] = rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 0, text: "") } && rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: -1, text: chunk0) } && rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: MemoryStore.maximumStreamChunks, text: chunk0) }
        let firstReceipt = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 0, text: chunk0)
        let replayReceipt = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 0, text: chunk0)
        checks["invocation_chunk_replay_idempotent"] = try !firstReceipt.replayed && replayReceipt.replayed && store.invocation(id: attempt.id)?.observedBytes == chunk0.utf8.count && store.invocation(id: attempt.id)?.chunkCount == 1
        checks["invocation_conflicting_chunk_replay_rejected"] = rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 0, text: "different") }
        checks["invocation_chunk_gap_rejected"] = rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 2, text: chunk1) }
        checks["invocation_stream_total_quota_rejected"] = rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 1, text: String(repeating: "x", count: MemoryStore.maximumPayloadBytes)) }
        checks["invocation_unfinalized_chunks_not_search_published"] = try store.search(query: "JOURNAL_SENTINEL", projectID: "synthetic-alpha").isEmpty && !store.events(conversationID: conversationID).contains { $0.id == attempt.assistantEventID }
        _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 1, text: chunk1)
        checks["invocation_invalid_terminal_reason_rejected"] = rejects { _ = try store.finalizeInvocation(invocationID: attempt.id, status: .complete, reason: .transportFailure) }
        let usage = Data("{ \"prompt_tokens\":17, \"completion_tokens\":8, \"total_tokens\":25 }".utf8)
        checks["invocation_invalid_usage_rejected_before_publication"] = rejects { _ = try store.finalizeInvocation(invocationID: attempt.id, status: .complete, usageJSON: Data("{\"authorization\":\"synthetic\"}".utf8)) } && rejects { _ = try store.finalizeInvocation(invocationID: attempt.id, status: .complete, usageJSON: Data(repeating: 0x20, count: 65537)) }
        let finished = try store.finalizeInvocation(invocationID: attempt.id, status: .complete, usageJSON: usage)
        let finishedReplay = try store.finalizeInvocation(invocationID: attempt.id, status: .complete, usageJSON: usage)
        checks["invocation_exact_ordered_chunk_publication"] = finished.text == chunk0 + chunk1 && finished.byteCount == chunk0.utf8.count + chunk1.utf8.count && finished.status == .complete && finished.role == .assistant
        checks["invocation_atomic_search_publication"] = try store.search(query: "JOURNAL_SENTINEL", projectID: "synthetic-alpha").first?.eventID == finished.id && store.literalSearch(query: "café \u{1F680}", projectID: "synthetic-alpha").first?.eventID == finished.id
        checks["invocation_terminal_replay_idempotent"] = try finished.createdAt == finishedReplay.createdAt && store.events(conversationID: conversationID).filter { $0.id == finished.id }.count == 1
        checks["invocation_exact_usage_receipt_preserved"] = try store.invocation(id: attempt.id)?.usageJSON == usage
        checks["invocation_changed_usage_receipt_rejected"] = rejects { _ = try store.finalizeInvocation(invocationID: attempt.id, status: .complete, usageJSON: Data("{}".utf8)) }
        checks["invocation_conflicting_terminal_rejected"] = rejects { _ = try store.finalizeInvocation(invocationID: attempt.id, status: .cancelled) }
        checks["invocation_new_late_chunk_rejected"] = rejects { _ = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 2, text: "late") }
        checks["invocation_committed_chunk_replay_after_terminal_safe"] = try store.appendInvocationChunk(invocationID: attempt.id, sequence: 0, text: chunk0).replayed
        checks["invocation_terminal_begin_does_not_reopen"] = try begin().finalStatus == .complete && begin().chunkCount == 2
        checks["invocation_snapshot_private_to_journal"] = try store.search(query: "SNAPSHOT_ONLY_SENTINEL", projectID: "synthetic-alpha").isEmpty
        let cancelled = try begin(id: "cancelled-invocation", assistant: "cancelled-invocation-assistant", destination: "native:synthetic-profile")
        _ = try store.appendInvocationChunk(invocationID: cancelled.id, sequence: 0, text: "cancelled received fragment")
        checks["invocation_cancelled_capture_preserves_fragments"] = try store.finalizeInvocation(invocationID: cancelled.id, status: .cancelled).text == "cancelled received fragment" && store.invocation(id: cancelled.id)?.terminalReason == .cancelled
        let stopped = try begin(id: "stopped-partial-invocation", assistant: "stopped-partial-assistant", destination: "native:synthetic-profile")
        _ = try store.appendInvocationChunk(invocationID: stopped.id, sequence: 0, text: "synthetic stopped prefix")
        checks["invocation_stopped_partial_capture_preserves_reason"] = try store.finalizeInvocation(invocationID: stopped.id, status: .partial, reason: .cancelled).text == "synthetic stopped prefix"
            && store.invocation(id: stopped.id)?.terminalReason == .cancelled
        let failed = try begin(id: "failed-invocation", assistant: "failed-invocation-assistant")
        checks["invocation_failed_empty_attempt_is_recorded"] = try store.finalizeInvocation(invocationID: failed.id, status: .failed).text.isEmpty && store.invocation(id: failed.id)?.terminalReason == .transportFailure
        let denied = try store.beginInvocation(invocationID: "admission-denied-invocation", conversationID: conversationID, turnID: human.turnID, humanEventID: human.id, assistantEventID: "admission-denied-assistant", providerIdentity: "http://localhost:11234/v1/", requestBody: body)
        _ = try store.finalizeInvocation(invocationID: denied.id, status: .failed, reason: .admissionFailure)
        checks["invocation_admission_failure_distinct_from_dispatch"] = try store.invocation(id: denied.id)?.terminalReason == .admissionFailure && store.invocation(id: denied.id)?.admissionJSON == nil && store.invocation(id: denied.id)?.observedBytes == 0
        let rollback = try begin(id: "rollback-invocation", assistant: "rollback-assistant")
        try syntheticSQL(directory: store.directory, sql: "CREATE TRIGGER reject_chunk_manifest BEFORE UPDATE OF observed_bytes ON invocations BEGIN SELECT RAISE(ABORT, 'synthetic write rejection'); END;")
        let chunkRejected = rejects { _ = try store.appendInvocationChunk(invocationID: rollback.id, sequence: 0, text: "ROLLBACK_PUBLICATION_SENTINEL") }
        try syntheticSQL(directory: store.directory, sql: "DROP TRIGGER reject_chunk_manifest;")
        checks["invocation_chunk_failure_rolls_back_payload_and_manifest"] = try chunkRejected && store.invocation(id: rollback.id)?.chunkCount == 0 && store.invocation(id: rollback.id)?.observedBytes == 0
        let rollbackReceipt = try store.appendInvocationChunk(invocationID: rollback.id, sequence: 0, text: "ROLLBACK_PUBLICATION_SENTINEL")
        checks["invocation_failed_chunk_can_retry_same_sequence"] = !rollbackReceipt.replayed
        try syntheticSQL(directory: store.directory, sql: "CREATE TRIGGER reject_terminal_manifest BEFORE UPDATE OF final_status ON invocations BEGIN SELECT RAISE(ABORT, 'synthetic write rejection'); END;")
        let terminalRejected = rejects { _ = try store.finalizeInvocation(invocationID: rollback.id, status: .complete) }
        try syntheticSQL(directory: store.directory, sql: "DROP TRIGGER reject_terminal_manifest;")
        checks["invocation_terminal_failure_rolls_back_event_fts_and_state"] = try terminalRejected && store.invocation(id: rollback.id)?.finalStatus == nil && !store.events(conversationID: conversationID).contains { $0.id == rollback.assistantEventID } && store.search(query: "ROLLBACK_PUBLICATION_SENTINEL", projectID: "synthetic-alpha").isEmpty
        _ = try store.finalizeInvocation(invocationID: rollback.id, status: .complete)
        checks["invocation_failed_publication_retries_once"] = try store.events(conversationID: conversationID).filter { $0.id == rollback.assistantEventID }.count == 1 && store.search(query: "ROLLBACK_PUBLICATION_SENTINEL", projectID: "synthetic-alpha").first?.eventID == rollback.assistantEventID
        _ = try begin(id: "recovery-invocation", assistant: "recovery-assistant")
        _ = try store.appendInvocationChunk(invocationID: "recovery-invocation", sequence: 0, text: "committed interrupted fragment café\u{1F680}")
        _ = try begin(id: "empty-recovery-invocation", assistant: "empty-recovery-assistant")
        return checks
    }

    /// Fault injection modifies only disposable synthetic databases while the
    /// production owner is idle. There is no public SQL mutation interface.
    private static func syntheticSQL(directory: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("memory.sqlite3").path, &database) == SQLITE_OK, let opened = database else { throw MemoryError.database("could not open synthetic fault fixture") }
        defer { sqlite3_close(opened) }
        guard sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK else { throw MemoryError.database("could not prepare synthetic fault fixture") }
    }

    private static func migrationChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-v1-migration-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MemoryStore? = try MemoryStore(directory: directory)
        let conversation = try store!.createConversation(projectID: "migration-project", title: "Synthetic version one history")
        let history = "VERSION_ONE_SENTINEL complete retained bytes café\0tail"
        let original = try store!.append(conversationID: conversation.id, role: .human, text: history, status: .complete, turnID: "v1-turn", eventID: "v1-human")
        try store!.saveDraft(conversationID: conversation.id, text: "version one draft")
        try store!.saveSetting(key: "v1-setting", value: "version one setting")
        store = nil
        // Version one had these same event/FTS/draft/settings tables, without
        // invocation tables. Recreate that exact pre-upgrade schema boundary.
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("memory.sqlite3").path, &database) == SQLITE_OK, let opened = database else { throw MemoryError.database("could not prepare synthetic migration") }
        defer { sqlite3_close(opened) }
        // A genuine schema-1 fixture has no background inventory. Refuse to
        // discard any maintenance accounting when removing current-only tables.
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(opened, "SELECT (SELECT count(*) FROM background_index_work),(SELECT count(*) FROM background_index_windows)", -1, &pointer, nil) == SQLITE_OK,
              let counts = pointer else { throw MemoryError.database("could not inspect synthetic background inventory") }
        defer { sqlite3_finalize(counts) }
        guard sqlite3_step(counts) == SQLITE_ROW, sqlite3_column_int64(counts, 0) == 0,
              sqlite3_column_int64(counts, 1) == 0 else { throw MemoryError.database("historical fixture contains background work") }
        guard sqlite3_step(counts) == SQLITE_DONE else { throw MemoryError.database("could not inspect synthetic background inventory") }
        let authorityDrops = (EpisodeAccountingJournal.tableNames + AuthorityBindings.tableNames + AuthorityStateKernel.tableNames).map { "DROP TABLE " + $0 + ";" }.joined()
        guard sqlite3_exec(opened, authorityDrops + "DROP TABLE background_index_work; DROP TABLE background_index_windows; DROP TABLE invocation_chunks; DROP TABLE invocations; DROP TABLE episode_resource_totals; DROP TABLE episode_work; DROP TABLE episode_request_snapshots; DROP TABLE episodes; PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK else { throw MemoryError.database("could not prepare version one schema") }
        store = try MemoryStore(directory: directory)
        let restored = try store!.events(conversationID: conversation.id)
        let checks = [
            "version_one_migration_preserves_exact_history": restored.count == 1 && restored[0].text == history && restored[0].digest == original.digest && restored[0].createdAt == original.createdAt,
            "version_one_migration_preserves_search_draft_settings": try store!.search(query: "VERSION_ONE_SENTINEL", projectID: "migration-project").first?.eventID == original.id && store!.loadDraft(conversationID: conversation.id) == "version one draft" && store!.loadSetting(key: "v1-setting") == "version one setting"
        ]
        store = nil
        return checks
    }

    private static func rejects(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }

    private static func privatePermissions(_ url: URL, expected: UInt16) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_mode & 0o777 == expected
    }

}
