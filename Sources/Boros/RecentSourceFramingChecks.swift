import Foundation

/// Synthetic checks inspect exact source bytes and the dispatched framing.
/// They report only fixed check names and booleans; no payload is emitted.
enum RecentSourceFramingChecks {
    static func run() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let legacy = ContextSourceFraming.legacySelectionVersion
        let current = ContextSourceFraming.currentSelectionVersion
        let identity = ContextSourceFraming.identitySelectionVersion
        let captured = "2026-10-06T12:00:00Z"
        func time(_ literal: String, locator: String = "/synthetic/time") throws -> EventSourceTime {
            let normalized = try EventSourceTime.normalize(literal)
            return try EventSourceTime(value: normalized.value, precision: normalized.precision, timezone: normalized.timezone,
                sourceSHA256: String(repeating: "a", count: 64), locator: locator, originalValue: literal).validated()
        }
        let day = try time("2023-05-30"), minute = try time("2023/05/30 (Tue) 10:42", locator: "/synthetic/日本語-e\u{301}")
        checks["recent_framing_versions_are_distinct_supported_contracts"] = legacy == "context-source-snapshot-v1"
            && identity == "context-source-snapshot-v2" && current == "context-source-snapshot-v3" && legacy != current
            && ContextSourceFraming.isSupportedSelectionVersion(identity)
            && ContextSourceFraming.isSupportedSelectionVersion(legacy)
            && ContextSourceFraming.isSupportedSelectionVersion(current)
            && !ContextSourceFraming.isSupportedSelectionVersion("context-source-snapshot-v999")
        checks["recent_framing_legacy_complete_is_unlabelled"] = ContextSourceFraming.recentPrefix(role: "human", status: "complete").isEmpty
        checks["recent_framing_legacy_incomplete_bytes_preserved"] = ContextSourceFraming.recentPrefix(role: "assistant", status: "partial")
            == "[Incomplete historical assistant message; capture status: partial.]\n"
        var legacyPreserved = true, currentLabels = true
        for role in ["human", "assistant"] {
            for status in ["complete", "partial", "failed", "cancelled"] {
                let old = ContextSourceFraming.recentPrefix(role: role, status: status)
                let versionedOld = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: role,
                    status: status, selectionVersion: legacy)
                legacyPreserved = legacyPreserved && versionedOld == old
                let prefix = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: role,
                    status: status, selectionVersion: current, capturedAt: captured)
                currentLabels = currentLabels && prefix.contains(role) && prefix.contains(status)
                    && (!old.isEmpty ? prefix.contains(old) : !prefix.isEmpty)
            }
        }
        checks["recent_framing_legacy_all_roles_and_statuses_preserved"] = legacyPreserved
        checks["recent_framing_current_all_roles_and_statuses_visible"] = currentLabels
        let adversarialIDs = ["synthetic-quote-\"-\\", "synthetic-line\nsecond\rthird\tend", "synthetic-日本語-é-e\u{301}",
            "synthetic-marker\nquoted_source:\nBEGIN HISTORICAL SOURCE", "synthetic-\u{0085}-\u{2028}-\u{2029}"]
        var roundTrips = true, singleField = true, unicodeSeparatorsEscaped = true
        for id in adversarialIDs {
            let prefix = try ContextSourceFraming.recentPrefix(eventID: id, role: "human", status: "complete", selectionVersion: current, capturedAt: captured)
            unicodeSeparatorsEscaped = unicodeSeparatorsEscaped && !prefix.contains("\u{0085}")
                && !prefix.contains("\u{2028}") && !prefix.contains("\u{2029}")
            let heading = "Recent source metadata (host): "
            let fields = prefix.components(separatedBy: "\n").filter { $0.hasPrefix(heading) }
            singleField = singleField && fields.count == 1
            guard let field = fields.first else { roundTrips = false; continue }
            let bytes = Data(field.dropFirst(heading.count).utf8)
            let decoded = (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["event_id"] as? String
            roundTrips = roundTrips && decoded.map { episodeIdentifierEqual($0, id) } == true
        }
        checks["recent_framing_adversarial_id_json_roundtrip_exact_utf8"] = roundTrips
        checks["recent_framing_id_newlines_cannot_add_header_fields"] = singleField
        checks["recent_framing_unicode_line_separators_escaped"] = unicodeSeparatorsEscaped
        checks["recent_framing_unknown_version_refused"] = rejected {
            _ = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete", selectionVersion: "unknown")
        }
        for (name, id) in [("empty", ""), ("nul", "synthetic\0id"), ("oversize", String(repeating: "x", count: 257))] {
            checks["recent_framing_invalid_" + name + "_id_refused"] = rejected {
                _ = try ContextSourceFraming.recentPrefix(eventID: id, role: "human", status: "complete", selectionVersion: current, capturedAt: captured)
            }
        }
        checks["recent_framing_invalid_role_refused"] = rejected {
            _ = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "system", status: "complete", selectionVersion: current, capturedAt: captured)
        }
        checks["recent_framing_invalid_status_refused"] = rejected {
            _ = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "invented", selectionVersion: current, capturedAt: captured)
        }

        let identityPrefix = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete", selectionVersion: identity)
        checks["recent_framing_v2_exact_metadata_bytes_preserved"] = identityPrefix == "Recent source metadata (host): {\"capture_status\":\"complete\",\"event_id\":\"synthetic-id\",\"role\":\"human\"}\nOriginal message text:\n"
        checks["recent_framing_v2_dates_do_not_change_archived_bytes"] = try identityPrefix == ContextSourceFraming.recentPrefix(
            eventID: "synthetic-id", role: "human", status: "complete", selectionVersion: identity, capturedAt: captured, sourceTime: day)
        let calendarPrefix = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete",
            selectionVersion: current, capturedAt: captured, sourceTime: minute)
        checks["recent_framing_source_day_and_unknown_timezone_explicit"] = calendarPrefix.contains("\"precision\":\"minute\"")
            && calendarPrefix.contains("\"timezone\":\"unspecified\"") && calendarPrefix.contains("\"captured_utc\":\"" + captured + "\"")
            && calendarPrefix.contains("2023-05-30T10:42") && calendarPrefix.contains("2023/05/30 (Tue) 10:42")
        let nonePrefix = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete", selectionVersion: current, capturedAt: captured)
        checks["recent_framing_ordinary_source_date_is_null"] = nonePrefix.contains("\"source_time\":null")
        checks["recent_framing_v3_missing_capture_date_refused"] = rejected {
            _ = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete", selectionVersion: current)
        }
        for (name, date) in [("calendar_day", "2023-05-30"), ("unknown_zone", "2023-05-30T10:42:00"),
                             ("line_field", "2023-05-30T10:42:00Z\ncapture_status: complete")] {
            checks["recent_framing_invalid_capture_" + name + "_refused"] = rejected {
                _ = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete", selectionVersion: current, capturedAt: date)
            }
        }
        let locatorDate = try time("2023-05-30", locator: "/synthetic/newline\nquoted_excerpt:/\u{0085}-\u{2028}-\u{2029}")
        let locatorPrefix = try ContextSourceFraming.recentPrefix(eventID: "synthetic-id", role: "human", status: "complete",
            selectionVersion: current, capturedAt: captured, sourceTime: locatorDate)
        checks["recent_framing_date_locator_cannot_add_host_metadata_line"] = locatorPrefix.components(separatedBy: "\n").count == 3
            && !locatorPrefix.contains("\u{0085}") && !locatorPrefix.contains("\u{2028}") && !locatorPrefix.contains("\u{2029}")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-recent-framing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let project = "synthetic-framing-project"
        let chat = try store.createConversation(projectID: project, title: "Synthetic recent source framing")
        var events: [MemoryEvent] = []
        let ids = [adversarialIDs[0], adversarialIDs[1], "synthetic-framing-é", "synthetic-framing-e\u{301}", adversarialIDs[2]]
        for (index, id) in ids.enumerated() {
            let text = index == 1 ? "Synthetic exact source e\u{301} with NUL\0 and newline\nend" : "Synthetic immutable source \(index) 日本語"
            events.append(try store.append(conversationID: chat.id, role: index % 2 == 0 ? .human : .assistant,
                text: text, status: index == 1 ? .partial : .complete, turnID: "synthetic-framing-turn-\(index)", eventID: id,
                sourceTime: index == 0 ? day : (index == 1 ? minute : nil)))
        }
        let request = try store.append(conversationID: chat.id, role: .human, text: "Synthetic current request retained exactly",
            status: .complete, turnID: "synthetic-framing-current-turn", eventID: "synthetic-framing-current")
        let snapshot = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: request.text, system: "Synthetic host instructions", excludingEventID: request.id)
        checks["recent_framing_live_selection_uses_current_contract"] = snapshot.selectionBinding?.version == current
            && snapshot.includedRecentCount == events.count
        checks["recent_framing_live_selection_keeps_source_identity_order"] = ExactSourceIDs(snapshot.recentSourceIDs) == ExactSourceIDs(events.map(\.id))
            && zip(snapshot.recentSourceIDs, events).allSatisfy { episodeIdentifierEqual($0.0, $0.1.id) }
        checks["recent_framing_original_payload_bytes_unchanged_in_store"] = try store.events(conversationID: chat.id).dropLast().enumerated().allSatisfy {
            $0.element.text.utf8.elementsEqual(events[$0.offset].text.utf8) && $0.element.digest == events[$0.offset].digest
                && $0.element.byteCount == events[$0.offset].byteCount
        }
        var bodiesExact = true
        for (index, event) in events.enumerated() {
            let prefix = try ContextSourceFraming.recentPrefix(eventID: event.id, role: event.role.rawValue,
                status: event.status.rawValue, selectionVersion: current, capturedAt: event.createdAt, sourceTime: event.sourceTime)
            bodiesExact = bodiesExact && snapshot.messages[index + 1].content.utf8.elementsEqual((prefix + event.text).utf8)
                && snapshot.messages[index + 1].role == (event.role == .human ? "user" : "assistant")
        }
        checks["recent_framing_dispatched_prefix_and_original_bytes_exact"] = bodiesExact
        let expectedMandatory = ContextAssembler.mandatoryMessages(prompt: request.text, system: "Synthetic host instructions")
        let deliveredMandatory = [snapshot.messages[0], snapshot.messages.last!]
        let expectedMandatoryBytes = try ContextAssembler.serializedMessages(expectedMandatory)
        checks["recent_framing_current_mandatory_bytes_unchanged"] = try ContextAssembler.serializedMessages(deliveredMandatory) == expectedMandatoryBytes
            && deliveredMandatory[0].content.hasPrefix("Synthetic host instructions\n\n")
            && deliveredMandatory[1].content.utf8.elementsEqual(request.text.utf8)
            && snapshot.selectionBinding?.mandatoryMessagesSHA256 == ContextSnapshot.digest(expectedMandatoryBytes)
        checks["recent_framing_selection_document_version_matches_binding"] = try documentVersion(snapshot) == current
        checks["recent_framing_source_byte_counts_exclude_labels"] = zip(snapshot.recentSources, events).allSatisfy {
            $0.0.byteCount == $0.1.byteCount && $0.0.digest == $0.1.digest
        }
        let reduced = try snapshot.reducedRecentForComponentCap()!
        let reducedVersion = try documentVersion(reduced)
        checks["recent_framing_reduction_preserves_exact_suffix_labels_and_ids"] = reduced.includedRecentCount == 2
            && reduced.messages.dropFirst().dropLast().elementsEqual(snapshot.messages.dropFirst().dropLast().suffix(2))
            && zip(reduced.recentSourceIDs, events.suffix(2)).allSatisfy { episodeIdentifierEqual($0.0, $0.1.id) }
            && reduced.selectionBinding?.version == current && reducedVersion == current
        checks["recent_framing_reduction_keeps_original_source_proofs"] = zip(reduced.recentSources, events.suffix(2)).allSatisfy {
            $0.0.digest == $0.1.digest && $0.0.byteCount == $0.1.byteCount && $0.0.role == $0.1.role && $0.0.status == $0.1.status
        }

        // Each mutation leaves the other independent source/body commitments
        // intact, so rejection establishes the corresponding validation edge.
        checks["recent_framing_changed_body_prefix_refused"] = try changedMessage(snapshot, index: 1,
            content: "[fabricated source label]\n" + snapshot.messages[1].content).isRejected
        checks["recent_framing_changed_original_payload_refused"] = try changedMessage(snapshot, index: 1,
            content: snapshot.messages[1].content + " altered").isRejected
        checks["recent_framing_changed_message_role_refused"] = try changedMessage(snapshot, index: 1, role: "assistant").isRejected
        checks["recent_framing_changed_source_event_id_refused"] = try changedSource(snapshot, index: 0, key: "eventID", value: "synthetic-replaced-id").isRejected
        checks["recent_framing_unicode_equivalent_source_id_refused"] = try changedSource(snapshot, index: 2, key: "eventID", value: "synthetic-framing-e\u{301}").isRejected
        checks["recent_framing_changed_source_role_refused"] = try changedSource(snapshot, index: 0, key: "role", value: "assistant").isRejected
        checks["recent_framing_changed_capture_status_refused"] = try changedSource(snapshot, index: 0, key: "status", value: "partial").isRejected
        checks["recent_framing_changed_source_digest_refused"] = try changedSource(snapshot, index: 0, key: "digest", value: String(repeating: "0", count: 64)).isRejected
        checks["recent_framing_changed_capture_date_refused"] = try changedSource(snapshot, index: 0, key: "createdAt", value: captured).isRejected
        checks["recent_framing_changed_source_calendar_refused"] = try changedSource(snapshot, index: 0, key: "sourceTime", value: time("2023-05-31").object).isRejected
        checks["recent_framing_changed_source_byte_count_refused"] = try changedSource(snapshot, index: 0, key: "byteCount", value: events[0].byteCount + 1).isRejected
        var unknownBinding = snapshot.selectionBinding!; unknownBinding.version = "context-source-snapshot-v999"
        checks["recent_framing_unknown_snapshot_version_refused"] = try rebuilt(snapshot, binding: unknownBinding).isRejected
        var oldBinding = snapshot.selectionBinding!; oldBinding.version = legacy
        checks["recent_framing_legacy_binding_current_body_refused"] = try rebuilt(snapshot, binding: oldBinding).isRejected

        var identityBinding = snapshot.selectionBinding!; identityBinding.version = identity
        let identityRecent = try events.map { event in
            ContextMessage(role: event.role == .human ? "user" : "assistant", content: try ContextSourceFraming.recentPrefix(
                eventID: event.id, role: event.role.rawValue, status: event.status.rawValue, selectionVersion: identity) + event.text)
        }
        let identitySnapshot = try rebuilt(snapshot, messages: [snapshot.messages[0]] + identityRecent + [snapshot.messages.last!], binding: identityBinding)
        let identitySelection = try JSONSerialization.jsonObject(with: identitySnapshot.selectionEvidence()) as! [String: Any]
        let identityReduction = try identitySnapshot.reducedRecentForComponentCap()!.messages.dropFirst().dropLast().elementsEqual(identityRecent.suffix(2))
        checks["recent_framing_v2_original_snapshot_and_reduction_validate"] = !identitySnapshot.isRejected
            && identitySelection["version"] as? String == identity
            && (identitySelection["recent_sources"] as? [[String: Any]])?.allSatisfy { $0["sourceTime"] == nil && $0["source_time"] == nil } == true
            && identityReduction
        checks["recent_framing_v3_binding_v2_body_refused"] = try rebuilt(identitySnapshot, binding: snapshot.selectionBinding!).isRejected

        let noRecent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: request.text, system: "Synthetic host instructions", excludingEventID: request.id, maximumRecentBytes: 0)
        let original = events[0]
        let hit = MemoryHit(eventID: original.id, conversationID: original.conversationID, projectID: original.projectID,
            role: original.role, status: original.status, createdAt: original.createdAt, digest: original.digest,
            totalBytes: original.byteCount, excerptOffset: 0, excerpt: original.text, sourceTime: original.sourceTime)
        let historical = try ContextAssembler.addEvidence(to: noRecent, store: store, conversationID: chat.id, projectID: project,
            excludingEventID: request.id, historicalHits: [hit])
        let historyDocument = try JSONSerialization.jsonObject(with: historical.selectionEvidence()) as! [String: Any]
        let historyAudit = (historyDocument["historical_sources"] as! [[String: Any]])[0]
        checks["recent_framing_historical_dates_are_delivered_and_proof_bound"] = historical.messages[1].content.contains("captured_utc: " + original.createdAt)
            && historical.messages[1].content.contains("source_time: {\"locator\":")
            && historical.messages[1].content.contains("\"value\":\"2023-05-30\"")
            && historical.messages[1].content.contains(original.text) && historyAudit["captured_utc"] as? String == original.createdAt
            && (historyAudit["source_time"] as? [String: String]) == day.object && historyAudit["source_created_utc"] == nil
        var changedHit = hit; changedHit.sourceTime = try time("2023-05-31")
        checks["recent_framing_historical_changed_source_date_refused"] = rejected {
            _ = try ContextAssembler.addEvidence(to: noRecent, store: store, conversationID: chat.id, projectID: project,
                excludingEventID: request.id, historicalHits: [changedHit])
        }
        let oldHeader = try ContextSourceFraming.evidenceHeader(eventID: original.id, conversationID: original.conversationID,
            role: original.role.rawValue, status: original.status.rawValue, createdAt: original.createdAt,
            digest: original.digest, offset: 0, totalBytes: original.byteCount, selectionVersion: legacy)
        let identityHeader = try ContextSourceFraming.evidenceHeader(eventID: original.id, conversationID: original.conversationID,
            role: original.role.rawValue, status: original.status.rawValue, createdAt: original.createdAt,
            digest: original.digest, offset: 0, totalBytes: original.byteCount, selectionVersion: identity, sourceTime: day)
        checks["recent_framing_v1_v2_historical_header_bytes_preserved"] = oldHeader == identityHeader
            && oldHeader.contains("source_created_utc: " + original.createdAt) && !oldHeader.contains("source_time:")

        // Construct the authentic legacy message bytes from source originals;
        // changing a v2 version string alone is deliberately tested above.
        let oldRecent = events.map {
            ContextMessage(role: $0.role == .human ? "user" : "assistant",
                content: ContextSourceFraming.recentPrefix(role: $0.role.rawValue, status: $0.status.rawValue) + $0.text)
        }
        let oldMessages = [snapshot.messages[0]] + oldRecent + [snapshot.messages.last!]
        let oldSnapshot = try rebuilt(snapshot, messages: oldMessages, binding: oldBinding)
        let oldVersion = try documentVersion(oldSnapshot)
        checks["recent_framing_original_legacy_snapshot_validates"] = !oldSnapshot.isRejected
            && oldVersion == legacy
        checks["recent_framing_legacy_reduction_preserves_original_unlabelled_body"] = try oldSnapshot.reducedRecentForComponentCap()!.messages.dropFirst().dropLast()
            .elementsEqual(oldRecent.suffix(2))
        checks["recent_framing_current_binding_legacy_body_refused"] = try rebuilt(oldSnapshot, binding: snapshot.selectionBinding!).isRejected
        checks["recent_framing_legacy_original_byte_tampering_refused"] = try changedMessage(oldSnapshot, index: 1,
            content: oldSnapshot.messages[1].content + " altered").isRejected
        checks["recent_framing_version_change_changes_selection_digest"] = try snapshot.selectionDigest() != oldSnapshot.selectionDigest()
        return checks
    }

    private static func rejected(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return error is ContextError }
    }
    private static func documentVersion(_ snapshot: ContextSnapshot) throws -> String? {
        (try JSONSerialization.jsonObject(with: snapshot.selectionEvidence()) as? [String: Any])?["version"] as? String
    }
    private static func rebuilt(_ snapshot: ContextSnapshot, messages: [ContextMessage]? = nil,
        sources: [ContextRecentSource]? = nil, binding: ContextSelectionBinding? = nil) throws -> ContextSnapshot {
        let messages = messages ?? snapshot.messages
        return ContextSnapshot(messages: messages, evidence: snapshot.evidence,
            serializedBytes: try ContextAssembler.serializedMessages(messages).count, omittedRecentCount: snapshot.omittedRecentCount,
            includedRecentCount: snapshot.includedRecentCount, recentSourceIDs: snapshot.recentSourceIDs,
            recentSources: sources ?? snapshot.recentSources, selectionBinding: binding ?? snapshot.selectionBinding,
            selectionAudit: snapshot.selectionAudit)
    }
    private static func changedMessage(_ snapshot: ContextSnapshot, index: Int, role: String? = nil, content: String? = nil) throws -> ContextSnapshot {
        var messages = snapshot.messages
        messages[index] = ContextMessage(role: role ?? messages[index].role, content: content ?? messages[index].content)
        return try rebuilt(snapshot, messages: messages)
    }
    private static func changedSource(_ snapshot: ContextSnapshot, index: Int, key: String, value: Any) throws -> ContextSnapshot {
        var documents = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.recentSources)) as! [[String: Any]]
        documents[index][key] = value
        let sources = try JSONDecoder().decode([ContextRecentSource].self, from: JSONSerialization.data(withJSONObject: documents))
        return try rebuilt(snapshot, sources: sources)
    }
}

private extension ContextSnapshot {
    var isRejected: Bool {
        do { _ = try componentAssignments(); return false } catch { return error is ContextError }
    }
}
