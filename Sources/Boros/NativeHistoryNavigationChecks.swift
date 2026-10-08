import Foundation
import CSQLite

/// Public synthetic originals in disposable stores. No provider or corpus use.
enum NativeHistoryNavigationChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-native-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let project = "synthetic-navigation-project"
        let chat = try store.createConversation(projectID: project, title: "Synthetic private_abs conversation")
        let second = try store.createConversation(projectID: project, title: "Synthetic update")
        let outsider = try store.createConversation(projectID: "other-project", title: "Synthetic other scope")
        let day = EventSourceTime(value: "2026-09-01", precision: "day", timezone: "unspecified",
            sourceSHA256: String(repeating: "a", count: 64), locator: "/private_abs/calendar", originalValue: "2026-09-01")
        func append(_ conversation: String, _ id: String, _ text: String, _ role: MemoryRole = .human,
                    _ status: CaptureStatus = .complete, _ sourceTime: EventSourceTime? = nil) throws {
            _ = try store.append(conversationID: conversation, role: role, text: text, status: status,
                turnID: "synthetic-turn-" + id, eventID: id, sourceTime: sourceTime)
        }
        try append(chat.id, "private_abs-old-human", "Where is the crimson compass?", .human, .complete, day)
        try append(chat.id, "private_abs-old-assistant", "The compass is in the north drawer.", .assistant, .partial, day)
        for index in 0..<80 {
            try append(chat.id, "private_abs-filler-\(index)", "Synthetic weather record \(index).")
        }
        try append(second.id, "private_abs-later-human", "The crimson compass moved.")
        try append(second.id, "private_abs-later-assistant", "The compass is now on the south shelf.", .assistant)
        let unicodeText = String(repeating: "界", count: 1500) + " café finalneedle"
        try append(second.id, "unicode-é", unicodeText)
        try append(second.id, "unicode-e\u{301}", "Canonical identity remains distinct.", .assistant)
        try append(outsider.id, "outside-source", "outsideneedle")
        let clock = SystemEpisodeClock(), currentID = "private_abs-current", episodeID = UUID().uuidString
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "synthetic-current-turn",
            humanEventID: currentID, episodeID: episodeID, text: "Synthetic accepted question", limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        let before = try lease.checkActive()
        let history = try NativeHistoryNavigation.load(store: store, projectID: project, excludingEventID: currentID, lease: lease)
        let loaded = try lease.checkActive()
        let all = try history.modelRecords(blockIDs: history.orderedBlockIDs)
        let hostIDs = history.orderedBlockIDs.flatMap { history.blocks[$0]!.hostSourceIDs }
        let modelJSON = try NativeInvestigationJSON.data(all)
        let view = try history.overview()
        let viewJSON = try NativeInvestigationJSON.data(view)
        var checks: [String: Bool] = [
            "native_navigation_snapshot_is_complete_and_scoped": all.count == 86 && !hostIDs.contains("outside-source") && !hostIDs.contains(currentID),
            "native_navigation_prepaid_raw_and_metadata_work": loaded.charged.rawSourceBytes > before.charged.rawSourceBytes
                && loaded.charged.metadataRows > before.charged.metadataRows && loaded.charged.memoryOperations == before.charged.memoryOperations + 1,
            "native_navigation_does_not_generate_or_embed": loaded.charged.modelCalls == before.charged.modelCalls
                && loaded.charged.inputTokens == before.charged.inputTokens && loaded.charged.vectorBytes == before.charged.vectorBytes,
            "native_navigation_model_projection_has_opaque_ids_and_no_locators": !String(decoding: modelJSON + viewJSON, as: UTF8.self).contains("private_abs")
                && !String(decoding: modelJSON + viewJSON, as: UTF8.self).contains("locator"),
            "native_navigation_preserves_role_status_and_original_calendar": all[1]["role"] as? String == "assistant"
                && all[1]["status"] as? String == "partial" && (all[1]["source_time"] as? [String: String])?["original_value"] == day.originalValue,
            "native_navigation_unknown_time_remains_unknown": all[2]["source_time"] is NSNull,
            "native_navigation_distinct_unicode_host_ids_survive": ExactSourceIDs(hostIDs.filter { $0.hasPrefix("unicode-") }).count == 2,
            "native_navigation_whole_project_header_is_explicit": (view["header"] as? [String: Any])?["aggregate_covers_all_original_records"] as? Bool == true
                && (view["header"] as? [String: Any])?["source_records"] as? Int == 86,
            "native_navigation_original_block_sources_remain_private": !String(decoding: viewJSON, as: UTF8.self).contains("private_abs-old")
        ]
        let query = String(repeating: "weather instruction filler ", count: 30) + "finalneedle"
        let late = try history.search(query: query, pageSize: 128)
        checks["native_navigation_late_query_anchor_reaches_full_snapshot"] = late.blockIDs.contains { history.blocks[$0]!.hostSourceIDs.contains("unicode-é") }
        checks["native_navigation_punctuated_diacritic_literal_search"] = try history.search(query: "CAFÉ!", pageSize: 128).blockIDs.contains { history.blocks[$0]!.hostSourceIDs.contains("unicode-é") }
        let compass = try history.search(query: "compass", pageSize: 1)
        let remaining = try history.search(query: "compass", cursor: compass.nextCursor, pageSize: 1)
        checks["native_navigation_search_pages_reach_original_and_update"] = compass.nextCursor != nil
            && Set(compass.blockIDs + remaining.blockIDs).count == 2
            && (compass.blockIDs + remaining.blockIDs).flatMap { history.blocks[$0]!.hostSourceIDs }.contains("private_abs-old-human")
            && (compass.blockIDs + remaining.blockIDs).flatMap { history.blocks[$0]!.hostSourceIDs }.contains("private_abs-later-assistant")
        checks["native_navigation_cursor_rejects_changed_query"] = rejected { _ = try history.search(query: "weather", cursor: compass.nextCursor) }
        checks["native_navigation_cursor_rejects_unknown_and_wrong_operation"] = rejected { _ = try history.search(query: "compass", cursor: "unknown") }
            && rejected { _ = try history.zoom(regionID: history.rootRegionID, cursor: compass.nextCursor) }
        let zoom = try history.zoom(regionID: history.rootRegionID, pageSize: 1)
        let zoomNext = try history.zoom(regionID: history.rootRegionID, cursor: zoom.nextCursor, pageSize: 1)
        checks["native_navigation_zoom_pagination_preserves_whole_blocks"] = zoom.nextCursor != nil && zoom.blockIDs != zoomNext.blockIDs
            && history.blocks[zoom.blockIDs[0]]!.sourceIDs.count == 2
        let overview = try history.overview(pageSize: 1)
        let overviewNext = try history.overview(cursor: overview["next_cursor"] as? String, pageSize: 1)
        checks["native_navigation_overview_pagination_has_all_history_header"] = overview["next_cursor"] is String
            && (overviewNext["header"] as? [String: Any])?["source_records"] as? Int == 86
        let block = history.blocks[late.blockIDs.first { history.blocks[$0]!.hostSourceIDs.contains("unicode-é") }!]!
        let fragments = block.hits.filter { episodeIdentifierEqual($0.eventID, "unicode-é") }
        checks["native_navigation_scalar_safe_hits_cover_exact_complete_original"] = fragments.count == 2
            && fragments.allSatisfy { $0.excerpt.utf8.count <= 4096 }
            && fragments.map(\.excerpt).joined().utf8.elementsEqual(unicodeText.utf8)
            && fragments[1].excerptOffset == fragments[0].excerpt.utf8.count
        let temporal = try NativeInvestigationTimeFilter.parse(["start": "2026-09-01", "end": "2026-09-01", "include_unknown": false])!
        let dated = try history.search(query: "compass", timeFilter: temporal)
        checks["native_navigation_time_filter_uses_original_dates"] = dated.blockIDs.count == 1
            && history.blocks[dated.blockIDs[0]]!.hostSourceIDs.contains("private_abs-old-human")
        checks["native_navigation_plan_strict_fields_duplicate_keys_and_boolean_types"] = rejected {
            _ = try NativeInvestigationPlan.parse("{\"action\":\"finish\",\"action\":\"search\"}")
        } && rejected { _ = try NativeInvestigationTimeFilter.parse(["start": NSNull(), "end": NSNull(), "include_unknown": 1]) }
        let finish: [String: Any] = ["action": "finish", "query": "", "region_id": "", "cursor": NSNull(),
            "time_filter": NSNull(), "pin_block_ids": [], "missing_facts": []]
        checks["native_navigation_plan_accepts_bounded_exact_contract"] = try NativeInvestigationPlan.parse(String(decoding: NativeInvestigationJSON.data(finish), as: UTF8.self)).action == "finish"
        let selectedID = compass.blockIDs[0], selected = history.blocks[selectedID]!, sourceID = selected.sourceIDs[0]
        let sourceText = selected.modelRecords[0]["content"] as! String
        let extraction: [String: Any] = ["facts": [["claim": "A synthetic source statement.", "source_ids": [sourceID],
            "quotes": [["source_id": sourceID, "text": sourceText]]]], "unresolved": ["A synthetic missing fact."]]
        let parsed = try NativeInvestigationExtraction.parse(String(decoding: NativeInvestigationJSON.data(extraction), as: UTF8.self), navigation: history, selectedBlockIDs: [selectedID])
        checks["native_navigation_extraction_requires_selected_original_exact_quote"] = parsed.sourceIDs == [sourceID]
            && parsed.unresolved.count == 1 && rejected {
                _ = try NativeInvestigationExtraction.parse(String(decoding: NativeInvestigationJSON.data(extraction), as: UTF8.self), navigation: history, selectedBlockIDs: [])
            }
        var fabricated = extraction
        fabricated["facts"] = [["claim": "A synthetic assertion.", "source_ids": [sourceID], "quotes": [["source_id": sourceID, "text": "a fabricated quotation"]]]]
        checks["native_navigation_extraction_fabricated_quote_rejected"] = rejected {
            _ = try NativeInvestigationExtraction.parse(String(decoding: NativeInvestigationJSON.data(fabricated), as: UTF8.self), navigation: history, selectedBlockIDs: [selectedID])
        }
        checks["native_navigation_descriptor_contains_no_source_content"] = !String(decoding: try history.descriptor(blockIDs: [selectedID]), as: UTF8.self).contains(sourceText)
        let beforeScope = try lease.checkActive()
        checks["native_navigation_wrong_scope_refused_before_source_work"] = try rejected {
            _ = try NativeHistoryNavigation.load(store: store, projectID: "other-project", excludingEventID: currentID, lease: lease)
        } && (try lease.checkActive()).charged.rawSourceBytes == beforeScope.charged.rawSourceBytes
        try append(second.id, "after-frontier", "newpublicationneedle")
        checks["native_navigation_frontier_is_frozen_after_load"] = try history.search(query: "newpublicationneedle").blockIDs.isEmpty
        _ = try lease.finish(reason: .completed)
        checks["native_navigation_terminal_lease_fences_cached_reads"] = rejected { _ = try history.search(query: "compass") }
        checks.merge(try emptyAndBudgetChecks()) { _, latest in latest }
        checks.merge(try sealAndCapChecks()) { _, latest in latest }
        return checks
    }
    private static func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func emptyAndBudgetChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-navigation-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), clock = SystemEpisodeClock()
        let chat = try store.createConversation(projectID: "synthetic-empty", title: "Synthetic empty")
        func accept(_ id: String, limits: EpisodeLimits = EpisodeLimits()) throws -> EpisodeLease {
            _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "turn-" + id,
                humanEventID: id, episodeID: "episode-" + id, text: "Synthetic accepted text", limits: limits, clock: clock.now())
            return EpisodeLease(ledger: store, episodeID: "episode-" + id, clock: clock)
        }
        let emptyLease = try accept("empty-current")
        let empty = try NativeHistoryNavigation.load(store: store, projectID: "synthetic-empty", excludingEventID: "empty-current", lease: emptyLease)
        var checks: [String: Bool] = ["native_navigation_empty_snapshot_still_has_explicit_map": try empty.orderedBlockIDs.isEmpty
            && (try empty.overview()["header"] as? [String: Any])?["source_records"] as? Int == 0]
        _ = try emptyLease.finish(reason: .completed)
        var limits = EpisodeLimits(); limits.resources.rawSourceBytes = 1
        let cappedLease = try accept("capped-current", limits: limits)
        checks["native_navigation_insufficient_raw_allowance_refuses_before_payload_read"] = try rejected {
            _ = try NativeHistoryNavigation.load(store: store, projectID: "synthetic-empty", excludingEventID: "capped-current", lease: cappedLease)
        } && (try store.episodeReceipt(id: "episode-capped-current", clock: clock.now())).charged.rawSourceBytes == 0
        return checks
    }
    private static func sealAndCapChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-navigation-seal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var corrupt = false
        let store = try MemoryStore(directory: directory, episodeAccountingCheckpoint: { phase, database in
            if phase == "before-accounting-lookup", corrupt {
                corrupt = false
                guard sqlite3_exec(database, "UPDATE events SET payload=zeroblob(byte_count) WHERE id='synthetic-seal-source'", nil, nil, nil) == SQLITE_OK else {
                    throw NativeHistoryNavigationError.sourceMismatch
                }
            }
        })
        let clock = SystemEpisodeClock()
        let chat = try store.createConversation(projectID: "synthetic-seal", title: "Synthetic seal")
        _ = try store.append(conversationID: chat.id, role: .human, text: "Synthetic original source.", status: .complete,
            turnID: "seal-source-turn", eventID: "synthetic-seal-source")
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "seal-current-turn", humanEventID: "seal-current",
            episodeID: "seal-episode", text: "Synthetic accepted request.", limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: "seal-episode", clock: clock)
        corrupt = true
        let sealRefused = rejected { _ = try NativeHistoryNavigation.load(store: store, projectID: "synthetic-seal", excludingEventID: "seal-current", lease: lease) }
        _ = try lease.finish(reason: .failed)
        let capped = try store.createConversation(projectID: "synthetic-size-cap", title: "Synthetic byte cap")
        let payload = String(repeating: "x", count: MemoryStore.maximumPayloadBytes)
        for index in 0..<8 {
            _ = try store.append(conversationID: capped.id, role: .human, text: payload, status: .complete,
                turnID: "cap-turn-\(index)", eventID: "cap-source-\(index)")
        }
        _ = try store.append(conversationID: capped.id, role: .human, text: "Synthetic overflow.", status: .complete,
            turnID: "cap-overflow-turn", eventID: "cap-overflow")
        _ = try store.acceptRequestAndBeginEpisode(conversationID: capped.id, turnID: "cap-current-turn", humanEventID: "cap-current",
            episodeID: "cap-episode", text: "Synthetic accepted request.", limits: EpisodeLimits(), clock: clock.now())
        let capLease = EpisodeLease(ledger: store, episodeID: "cap-episode", clock: clock)
        var capRefused = false
        do { _ = try NativeHistoryNavigation.load(store: store, projectID: "synthetic-size-cap", excludingEventID: "cap-current", lease: capLease) }
        catch NativeHistoryNavigationError.snapshotLimit { capRefused = true }
        catch {}
        return ["native_navigation_full_source_digest_refuses_corrupted_bytes": sealRefused,
                "native_navigation_snapshot_byte_cap_refuses_before_any_payload": try capRefused && capLease.checkActive().charged.rawSourceBytes == 0]
    }
}
