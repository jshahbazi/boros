import Foundation

enum ContextAdmissionChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-context-admission-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
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
        checks.merge(try recentCandidateChecks(store: store, semantic: semantic)) { _, new in new }
        return checks
    }

    private static func recentCandidateChecks(store: MemoryStore, semantic: SemanticIndex) throws -> [String: Bool] {
        let project = "synthetic-recent-candidate-cap"
        let chat = try store.createConversation(projectID: project, title: "Recent candidate starvation")
        let old = try store.append(conversationID: chat.id, role: .human,
            text: String(repeating: "Archived unrelated historical words. ", count: 1000) + "crowdoutkey original decision",
            status: .complete, turnID: "candidate-old-turn", eventID: "candidate-old-source")
        var excluded: Set<String> = []
        for index in 0..<120 {
            let id = "candidate-recent-\(index)"
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
            "candidate_starvation_fixture_exceeds_raw_cap": recent.includedRecentCount == 120 && recent.omittedRecentCount == 1,
            "lexical_exclusions_apply_before_candidate_limit": try store.search(query: "crowdoutkey", projectID: project,
                limit: 100, excludingEventIDs: excluded).map(\.eventID) == [old.id],
            "literal_exclusions_apply_before_candidate_limit": try store.literalSearch(query: "crowdoutkey", projectID: project,
                limit: 100, excludingEventIDs: excluded).map(\.eventID) == [old.id],
            "send_lexical_reaches_archive_after_recent_exclusion": lexical.evidence.contains { $0.eventID == old.id },
            "send_hybrid_raw_fallback_reaches_archive_after_recent_exclusion": hybrid.evidence.contains { $0.eventID == old.id }
        ]
    }
}
