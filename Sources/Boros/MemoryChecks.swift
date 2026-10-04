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
        checks["quoted_fts_syntax_is_data"] = try store!.search(query: "MIDPAYLOAD_SENTINEL\" OR *", projectID: "synthetic-alpha").isEmpty
        let unicode = try store!.append(conversationID: first.id, role: .assistant, text: "A\u{1F680}éZ", status: .cancelled, turnID: "unicode-turn", eventID: "unicode-event")
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
        store = nil
        store = try MemoryStore(directory: directory)
        checks["restart_payload_draft_settings_persistence"] = try store!.events(conversationID: first.id).first?.text == payload && store!.loadDraft(conversationID: first.id) == "unsent draft café\nexact line" && store!.loadSetting(key: "synthetic-setting") == "retained configuration"
        checks["restart_retrieval_persistence"] = try store!.search(query: "MIDPAYLOAD_SENTINEL", projectID: "synthetic-alpha").first?.eventID == saved.id
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
