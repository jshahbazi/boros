import Foundation
import CSQLite
import Darwin

/// Public synthetic fixtures only. Injected vectors test protocol mechanics;
/// they are not a product encoder or retrieval-quality evidence.
enum SemanticChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-semantic-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MemoryStore? = try MemoryStore(directory: directory)
        let first = try store!.createConversation(projectID: "semantic-alpha", title: "Synthetic semantic history")
        let second = try store!.createConversation(projectID: "semantic-beta", title: "Separate synthetic scope")
        let originalDate = EventSourceTime(value: "2023-05-30", precision: "day", timezone: "unspecified",
            sourceSHA256: String(repeating: "b", count: 64), locator: "/synthetic/messages/0/timestamp", originalValue: "2023-05-30")
        let bike = try store!.append(conversationID: first.id, role: .human, text: "The bicycle has two wheels and its frame is painted blue.", status: .complete, turnID: "bike-turn", eventID: "semantic-bike", sourceTime: originalDate)
        let cat = try store!.append(conversationID: first.id, role: .assistant, text: "The cat sleeps on a warm cushion near the window.", status: .partial, turnID: "cat-turn", eventID: "semantic-cat")
        let unsupported = try store!.append(conversationID: first.id, role: .human, text: "UNSUPPORTED exact code identifier.swift", status: .complete, turnID: "code-turn", eventID: "semantic-unsupported")
        _ = try store!.append(conversationID: second.id, role: .human, text: bike.text, status: .complete, turnID: "other-turn", eventID: "semantic-foreign-bike")
        let encoder = FixtureEncoder()
        var index: SemanticIndex? = try SemanticIndex(store: store!, encoder: encoder)
        var checks: [String: Bool] = [:]

        let before = try index!.search(query: "bicycle", projectID: "semantic-alpha")
        checks["semantic_raw_fallback_before_any_job"] = before.hits.contains { $0.eventID == bike.id } && before.manifest.coverage.pendingSources == 3 && before.manifest.rawFallbackAvailable
        checks["semantic_source_frontier_scoped"] = before.manifest.sourceFrontier == (try store!.sourceFrontier(projectID: "semantic-alpha")) && before.manifest.coverage.sources.allSatisfy { $0.source.projectID == "semantic-alpha" }
        checks["semantic_second_sidecar_owner_rejected"] = rejects { _ = try SemanticIndex(store: store!, encoder: encoder) }
        let work = try index!.process(projectID: "semantic-alpha")
        _ = try index!.process(projectID: "semantic-beta")
        let after = try index!.search(query: "bike", lexicalQuery: "bike", projectID: "semantic-alpha")
        checks["semantic_real_path_with_no_lexical_match"] = after.hits.contains { $0.eventID == bike.id } && after.manifest.results.first(where: { $0.source.eventID == bike.id })?.retrievalPaths == ["semantic"]
        checks["semantic_source_date_preserved_in_hybrid_hits_and_manifest"] = after.hits.first(where: { $0.eventID == bike.id })?.sourceTime == originalDate
            && after.manifest.results.first(where: { $0.source.eventID == bike.id })?.source.sourceTime == originalDate
        checks["semantic_scope_filter_before_rank"] = after.hits.allSatisfy { $0.projectID == "semantic-alpha" && $0.eventID != "semantic-foreign-bike" }
        checks["semantic_typed_source_status_retained"] = after.hits.first(where: { $0.eventID == cat.id })?.status == .partial
        checks["semantic_coverage_holes_are_explicit"] = work.publishedChunks == 3 && after.manifest.coverage.completeSources == 2 && after.manifest.coverage.unsupportedSources == 1 && after.manifest.coverage.unsupportedChunks == 1 && !after.manifest.coverage.complete && after.manifest.coverage.holes.first?.eventID == unsupported.id
        let codeResult = try index!.search(query: "UNSUPPORTED", projectID: "semantic-alpha")
        checks["semantic_unsupported_query_original_fallback"] = codeResult.manifest.queryDisposition == SemanticUnsupportedReason.codeLike.rawValue && codeResult.hits.first?.eventID == unsupported.id && codeResult.manifest.results.first?.retrievalPaths.contains("literal") == true
        checks["semantic_exact_match_priority"] = try index!.search(query: "window", projectID: "semantic-alpha").hits.first?.eventID == cat.id
        let withoutLiteral = try index!.search(query: "bicycle", projectID: "semantic-alpha", includeLiteral: false)
        checks["semantic_automatic_mode_skips_literal_scan"] = !withoutLiteral.manifest.literalSearchPerformed && withoutLiteral.manifest.literalScanBytes == 0 && !withoutLiteral.manifest.results.contains { $0.retrievalPaths.contains("literal") } && withoutLiteral.hits.first?.eventID == bike.id
        checks["semantic_literal_mode_bound_in_query_fingerprint"] = withoutLiteral.manifest.queryConfigurationFingerprint != (try index!.search(query: "bicycle", projectID: "semantic-alpha").manifest.queryConfigurationFingerprint)
        checks["semantic_excluded_events_not_returned"] = try index!.search(query: "bike", projectID: "semantic-alpha", excludingEventIDs: [bike.id]).hits.allSatisfy { $0.eventID != bike.id }
        let repeatedWork = try index!.process(projectID: "semantic-alpha")
        let repeatedSearch = try index!.search(query: "bike", projectID: "semantic-alpha")
        checks["semantic_job_replay_idempotent"] = repeatedWork.scheduledSources == 0 && repeatedWork.publishedChunks == 0 && repeatedSearch.manifest == after.manifest && repeatedSearch.manifestID == after.manifestID
        checks["semantic_source_offsets_digest_exact"] = try after.manifest.results.allSatisfy { result in
            let page = try store!.read(eventID: result.source.eventID, offset: result.offset, length: result.byteCount)
            return SemanticIndex.digest(Data(page.text.utf8)) == result.excerptDigest && page.digest == result.source.digest && page.byteCount == result.byteCount
        }
        let serializedManifest = try after.serializedManifest()
        checks["semantic_fingerprints_and_content_free_manifest"] = after.manifest.indexFingerprint == index!.indexFingerprint && after.manifest.encoderFingerprint == index!.encoderFingerprint && after.manifest.rankingFingerprint == index!.rankingFingerprint && !(String(decoding: serializedManifest, as: UTF8.self).contains(bike.text))
        checks["semantic_manifest_wrong_scope_rejected"] = rejects { _ = try index!.replay(manifestID: after.manifestID, projectID: "semantic-beta") }
        let beforeReplay = try index!.replay(manifestID: before.manifestID, projectID: "semantic-alpha")
        checks["semantic_saved_pending_frontier_does_not_advance"] = beforeReplay.manifest == before.manifest && beforeReplay.manifest.coverage.pendingSources == 3 && beforeReplay.manifest.publishedChunkFrontier == 0
        checks["semantic_private_sidecar_permissions"] = privateMode(index!.directory, 0o700) && privateMode(index!.directory.appendingPathComponent("index.sqlite3"), 0o600) && privateMode(index!.directory.appendingPathComponent("owner.lock"), 0o600) && privateMode(index!.directory.appendingPathComponent("index.sqlite3-wal"), 0o600) && privateMode(index!.directory.appendingPathComponent("index.sqlite3-shm"), 0o600)

        let originalManifest = after.manifest
        let originalID = after.manifestID
        let sidecar = index!.directory.appendingPathComponent("index.sqlite3")
        index = nil; store = nil
        store = try MemoryStore(directory: directory)
        index = try SemanticIndex(store: store!, encoder: FixtureEncoder())
        let restored = try index!.replay(manifestID: originalID, projectID: "semantic-alpha")
        checks["semantic_manifest_replay_after_store_restart"] = restored.manifest == originalManifest && restored.hits.map(\.eventID) == after.hits.map(\.eventID) && restored.hits.map(\.excerpt) == after.hits.map(\.excerpt)
        checks["semantic_source_date_preserved_after_manifest_restart_replay"] = restored.hits.first(where: { $0.eventID == bike.id })?.sourceTime == originalDate
        checks["semantic_persisted_vectors_after_restart"] = try index!.search(query: "bike", projectID: "semantic-alpha").manifest == originalManifest

        // Corrupt only isolated derived fixtures. Foreign source publication
        // and byte/vector mismatches must fail closed, never become evidence.
        let source = try store!.sourceReference(eventID: bike.id, projectID: "semantic-alpha")!
        let foreign = try store!.sourceReference(eventID: "semantic-foreign-bike", projectID: "semantic-beta")!
        try alter(sidecar, sql: "UPDATE jobs SET source=? WHERE event_id='semantic-bike'", bytes: try SemanticIndex.canonical(foreign))
        checks["semantic_sidecar_scope_snapshot_mismatch_rejected"] = rejects { _ = try index!.search(query: "bike", projectID: "semantic-alpha") }
        try alter(sidecar, sql: "UPDATE jobs SET source=? WHERE event_id='semantic-bike'", bytes: try SemanticIndex.canonical(source))
        try alter(sidecar, sql: "UPDATE chunks SET vector=? WHERE event_id='semantic-bike'", bytes: Data(repeating: 0, count: 12))
        checks["semantic_invalid_persisted_vector_rejected"] = rejects { _ = try index!.search(query: "bike", projectID: "semantic-alpha") }
        try alter(sidecar, sql: "UPDATE chunks SET vector=? WHERE event_id='semantic-bike'", bytes: SemanticIndex.vectorData([1, 0, 0]))
        try alter(sidecar, sql: "UPDATE manifests SET payload=? WHERE id='\(originalID)'", bytes: Data("{}".utf8))
        checks["semantic_manifest_digest_corruption_rejected"] = rejects { _ = try index!.replay(manifestID: originalID, projectID: "semantic-alpha") }
        index = nil
        checks.merge(try continuationChecks(store: store!, conversationID: first.id)) { _, new in new }
        checks.merge(try failureChecks(store: store!)) { _, new in new }
        checks.merge(try sourceIntegrityChecks()) { _, new in new }
        checks.merge(try asynchronousChecks(store: store!)) { _, new in new }
        checks.merge(try nativeAdapterChecks()) { _, new in new }
        checks.merge(try meteredSearchChecks(store: store!)) { _, new in new }
        checks.merge(try GlobalSemanticSearchChecks.run()) { _, new in new }
        checks.merge(try SemanticRetrievalPolicyChecks.run()) { _, new in new }
        return checks
    }

    private static func continuationChecks(store: MemoryStore, conversationID: String) throws -> [String: Bool] {
        var configuration = SemanticIndexConfiguration()
        configuration.chunkBytes = 64; configuration.maximumManifestSources = 2; configuration.maximumCandidateChunks = 1; configuration.maximumNewSourcesPerRun = 2
        var index: SemanticIndex? = try SemanticIndex(store: store, encoder: FixtureEncoder(), configuration: configuration)
        let text = String(repeating: "A bicycle travels across the quiet town. café 🐈 ", count: 12)
        let long = try store.append(conversationID: conversationID, role: .human, text: text, status: .complete, turnID: "long-turn", eventID: "semantic-long-utf8")
        _ = try index!.process(projectID: "semantic-alpha", maximumChunks: 128)
        _ = try index!.process(projectID: "semantic-alpha", maximumChunks: 1)
        _ = try index!.process(projectID: "semantic-alpha", maximumChunks: 1)
        let partial = try index!.search(query: "bicycle", projectID: "semantic-alpha")
        var checks: [String: Bool] = [:]
        checks["semantic_metadata_bound_and_continuation"] = partial.manifest.coverage.inspectedSources == 2 && partial.manifest.coverage.metadataContinuationSequence != nil
        checks["semantic_vector_bound_and_continuation"] = partial.manifest.vectorCandidatesInspected == 1 && partial.manifest.vectorContinuation != nil
        let continued = try index!.search(query: "bicycle", projectID: "semantic-alpha", continuation: partial.manifest.vectorContinuation)
        checks["semantic_vector_continuation_fixed_frontiers"] = continued.manifest.sourceFrontier == partial.manifest.sourceFrontier && continued.manifest.publishedChunkFrontier == partial.manifest.publishedChunkFrontier && continued.manifest.vectorCandidatesInspected <= 1
        checks["semantic_vector_continuation_query_mismatch_rejected"] = rejects { _ = try index!.search(query: "cat", projectID: "semantic-alpha", continuation: partial.manifest.vectorContinuation) }
        checks["semantic_vector_continuation_scope_mismatch_rejected"] = rejects { _ = try index!.search(query: "bicycle", projectID: "semantic-beta", continuation: partial.manifest.vectorContinuation) }
        checks["semantic_vector_continuation_literal_mode_mismatch_rejected"] = rejects { _ = try index!.search(query: "bicycle", projectID: "semantic-alpha", includeLiteral: false, continuation: partial.manifest.vectorContinuation) }
        let directory = index!.directory.appendingPathComponent("index.sqlite3")
        let chunksBefore = try rows(directory, eventID: long.id)
        index = nil
        // Simulate an armed but unpublished calculation. Recovery must retain
        // committed ranges and resume without duplicate publication.
        try alter(directory, sql: "UPDATE jobs SET state='processing' WHERE event_id='semantic-long-utf8'", bytes: nil)
        index = try SemanticIndex(store: store, encoder: FixtureEncoder(), configuration: configuration)
        _ = try index!.process(projectID: "semantic-alpha", maximumChunks: 128)
        let chunksAfter = try rows(directory, eventID: long.id)
        let continuationAfterCompletion = try index!.search(query: "bicycle", projectID: "semantic-alpha", continuation: partial.manifest.vectorContinuation)
        checks["semantic_restart_resumes_committed_chunk_cursor"] = !chunksBefore.isEmpty && chunksAfter.count > chunksBefore.count && Array(chunksAfter.prefix(chunksBefore.count)).map(\.offset) == chunksBefore.map(\.offset)
        var reconstructed = Data(), next = 0, exact = true
        for range in chunksAfter {
            let page = try store.read(eventID: long.id, offset: range.offset, length: range.byteCount)
            exact = exact && range.offset == next && page.byteCount == range.byteCount && SemanticIndex.digest(Data(page.text.utf8)) == range.digest
            next += range.byteCount; reconstructed.append(Data(page.text.utf8))
        }
        checks["semantic_utf8_ranges_partition_complete_original"] = exact && reconstructed == Data(text.utf8) && next == long.byteCount && chunksAfter.allSatisfy { $0.byteCount <= configuration.chunkBytes }
        checks["semantic_frozen_manifest_after_jobs_finish"] = try index!.replay(manifestID: partial.manifestID, projectID: "semantic-alpha").manifest == partial.manifest
        checks["semantic_late_source_seal_excluded_from_frozen_vector_corpus"] = continuationAfterCompletion.manifest == continued.manifest
        for number in 0..<150 {
            _ = try store.append(conversationID: conversationID, role: .human, text: "bicycle bicycle bicycle future matching source", status: .complete,
                turnID: "late-turn-\(number)", eventID: "semantic-late-\(number)")
        }
        let afterFuture = try index!.search(query: "bicycle", projectID: "semantic-alpha", continuation: partial.manifest.vectorContinuation)
        checks["semantic_late_150_matches_cannot_crowd_frozen_raw_candidates"] = afterFuture.manifest.results == continued.manifest.results && afterFuture.hits.contains { $0.eventID == "semantic-bike" } && !afterFuture.hits.contains { $0.eventID.hasPrefix("semantic-late-") }
        checks["semantic_continuation_retains_initial_fts_ranks"] = afterFuture.manifest.rawSnapshotID == continued.manifest.rawSnapshotID && !afterFuture.manifest.literalSearchPerformed && afterFuture.manifest.literalScanBytes == 0
        var changedConfiguration = configuration; changedConfiguration.chunkBytes = 128
        let oldFingerprint = index!.indexFingerprint
        index = nil
        index = try SemanticIndex(store: store, encoder: FixtureEncoder(), configuration: changedConfiguration)
        let changed = try index!.search(query: "bicycle", projectID: "semantic-alpha")
        checks["semantic_config_change_excludes_old_vectors"] = index!.indexFingerprint != oldFingerprint && changed.manifest.vectorCandidatesInspected == 0 && changed.manifest.coverage.pendingSources == 2
        checks["semantic_old_manifest_replay_retains_original_config"] = try index!.replay(manifestID: partial.manifestID, projectID: "semantic-alpha").manifest.indexFingerprint == oldFingerprint
        index = nil
        return checks
    }

    private static func failureChecks(store: MemoryStore) throws -> [String: Bool] {
        let conversation = try store.createConversation(projectID: "semantic-failures", title: "Synthetic failure jobs")
        let source = try store.append(conversationID: conversation.id, role: .human, text: "A bicycle remains available during an indexing outage.", status: .complete, turnID: "failure-turn", eventID: "semantic-failure-source")
        let encoder = FixtureEncoder(); encoder.failing = true
        var index: SemanticIndex? = try SemanticIndex(store: store, encoder: encoder)
        let failed = try index!.process(projectID: "semantic-failures", maximumChunks: 100)
        let fallback = try index!.search(query: "bicycle", projectID: "semantic-failures")
        var checks: [String: Bool] = [:]
        checks["semantic_failed_jobs_have_bounded_attempts"] = failed.failedChunks == 3 && fallback.manifest.coverage.failedSources == 1 && fallback.manifest.coverage.sources.first?.failureAttempts == 3
        checks["semantic_encoder_failure_original_fallback"] = fallback.hits.first?.eventID == source.id && fallback.manifest.queryDisposition == "adapterUnavailable" && fallback.manifest.coverage.indexedBytes == 0
        checks["semantic_failure_does_not_advance_cursor"] = fallback.manifest.coverage.sources.first?.nextOffset == 0 && fallback.manifest.coverage.indexedChunks == 0
        checks["semantic_exhausted_job_not_retried_implicitly"] = try index!.process(projectID: "semantic-failures", maximumChunks: 100).failedChunks == 0
        index = nil
        let recoveryEncoder = FixtureEncoder(); recoveryEncoder.metadataVersion = "changed-adapter-v2"
        index = try SemanticIndex(store: store, encoder: recoveryEncoder)
        _ = try index!.process(projectID: "semantic-failures")
        checks["semantic_changed_encoder_starts_fresh_jobs"] = try index!.search(query: "bicycle", projectID: "semantic-failures").manifest.coverage.complete
        index = nil
        let unavailable = FixtureEncoder(); unavailable.unavailable = true; unavailable.metadataVersion = "unavailable-v1"
        index = try SemanticIndex(store: store, encoder: unavailable)
        _ = try index!.process(projectID: "semantic-failures")
        let missing = try index!.search(query: "bicycle", projectID: "semantic-failures")
        checks["semantic_unavailable_encoder_explicit_hole_fallback"] = missing.hits.first?.eventID == source.id && missing.manifest.coverage.unsupportedSources == 1 && missing.manifest.queryDisposition == "adapterUnavailable"
        index = nil
        checks["semantic_invalid_configuration_rejected"] = rejects {
            var configuration = SemanticIndexConfiguration(); configuration.chunkBytes = 1
            _ = try SemanticIndex(store: store, encoder: FixtureEncoder(), configuration: configuration)
        }
        checks["semantic_zero_vector_rejected"] = rejects { _ = try SemanticIndex.normalized([0, 0, 0], dimension: 3) }
        checks["semantic_nonfinite_vector_rejected"] = rejects { _ = try SemanticIndex.normalized([.nan, 0, 1], dimension: 3) }
        checks["semantic_wrong_dimension_rejected"] = rejects { _ = try SemanticIndex.normalized([1, 0], dimension: 3) }
        return checks
    }

    private static func nativeAdapterChecks() throws -> [String: Bool] {
        let adapter = AppleSentenceEmbeddingAdapter()
        let first = try adapter.encode("The bicycle has two wheels.")
        let second = try adapter.encode("A bike rolls on a pair of tires.")
        let available = adapter.metadata["probe_digest"] != "unavailable"
        var checks: [String: Bool] = ["semantic_apple_revision_dimension_fingerprint": adapter.dimension == 512 && adapter.metadata["revision"] == "1" && adapter.metadata["language"] == "en" && adapter.metadata["os"] != nil]
        if available {
            if case .vector(let a) = first, case .vector(let b) = second {
                checks["semantic_installed_apple_real_vectors_smoke"] = a.count == 512 && b.count == 512 && a.allSatisfy(\.isFinite) && b.allSatisfy(\.isFinite) && a != b
            } else { checks["semantic_installed_apple_real_vectors_smoke"] = false }
        } else {
            checks["semantic_apple_unavailable_explicit"] = reason(first) == .adapterUnavailable
        }
        checks["semantic_apple_nonenglish_rejected"] = reason(try adapter.encode("Je voudrais une bicyclette.")) == .nonEnglish || !available
        checks["semantic_apple_mixed_language_rejected"] = reason(try adapter.encode("The bicycle has two wheels. Je voudrais une bicyclette.")) == .nonEnglish || !available
        checks["semantic_apple_code_rejected"] = reason(try adapter.encode("let count = objects.filter { $0.active }.count")) == .codeLike || !available
        checks["semantic_apple_ambiguous_input_rejected"] = reason(try adapter.encode("1234")) == .ambiguousLanguage || !available
        checks["semantic_apple_input_bound_rejected"] = reason(try adapter.encode(String(repeating: "The bicycle has two wheels. ", count: 200))) == .inputTooLarge
        return checks
    }

    private static func sourceIntegrityChecks() throws -> [String: Bool] {
        // External source-corruption schedules cannot leave another fixture's
        // live owner trusted for later foreground accounting.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-semantic-source-integrity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let conversation = try store.createConversation(projectID: "semantic-integrity", title: "Synthetic source integrity")
        let original = String(repeating: "A bicycle follows the river road. ", count: 12)
        let saved = try store.append(conversationID: conversation.id, role: .human, text: original, status: .complete, turnID: "integrity-turn", eventID: "semantic-integrity-source")
        var configuration = SemanticIndexConfiguration(); configuration.chunkBytes = 64
        var index: SemanticIndex? = try SemanticIndex(store: store, encoder: FixtureEncoder(), configuration: configuration)
        // Same-length valid UTF-8 corruption, leaving manifest.digest intact.
        // Only an isolated synthetic store is modified.
        let changed = original.replacingOccurrences(of: "river", with: "plain")
        let database = store.directory.appendingPathComponent("memory.sqlite3")
        try alter(database, sql: "UPDATE events SET payload=? WHERE id='semantic-integrity-source'", bytes: Data(changed.utf8))
        let work = try index!.process(projectID: "semantic-integrity", maximumChunks: 100)
        let report = try index!.search(query: "absent identifier", projectID: "semantic-integrity")
        var checks: [String: Bool] = [:]
        checks["semantic_completion_hashes_full_original_source"] = work.failedChunks == 3 && report.manifest.coverage.failedSources == 1 && report.manifest.coverage.completeSources == 0 && report.manifest.coverage.sources.first!.nextOffset < saved.byteCount
        checks["semantic_failed_full_digest_source_vectors_not_served"] = report.manifest.results.isEmpty && report.manifest.vectorCandidatesInspected == 0
        try alter(database, sql: "UPDATE events SET payload=? WHERE id='semantic-integrity-source'", bytes: Data(original.utf8))
        index = nil

        let second = try store.createConversation(projectID: "semantic-publication", title: "Synthetic publication fence")
        let source = try store.append(conversationID: second.id, role: .human, text: "A bicycle is parked beside a garden.", status: .complete, turnID: "publication-turn", eventID: "semantic-publication-source")
        let encoder = FixtureEncoder()
        index = try SemanticIndex(store: store, encoder: encoder)
        let sidecar = index!.directory.appendingPathComponent("index.sqlite3")
        encoder.beforeEncoding = {
            encoder.beforeEncoding = nil
            // Calculation started with the original job. Changing its snapshot
            // before publication must reject the returned vector.
            try alter(sidecar, sql: "UPDATE jobs SET source=? WHERE event_id='semantic-publication-source'", bytes: Data("{}".utf8))
        }
        let stale = try index!.process(projectID: "semantic-publication", maximumChunks: 1)
        try alter(sidecar, sql: "UPDATE jobs SET source=? WHERE event_id='semantic-publication-source'", bytes: try SemanticIndex.canonical(store.sourceReference(eventID: source.id, projectID: "semantic-publication")!))
        let recovered = try index!.search(query: "bicycle", projectID: "semantic-publication")
        checks["semantic_late_vector_job_snapshot_fenced"] = stale.failedChunks == 1 && stale.publishedChunks == 0 && recovered.manifest.coverage.indexedChunks == 0 && recovered.manifest.coverage.failedSources == 1 && recovered.hits.first?.eventID == source.id
        index = nil
        return checks
    }

    private static func asynchronousChecks(store: MemoryStore) throws -> [String: Bool] {
        let conversation = try store.createConversation(projectID: "semantic-async", title: "Synthetic background jobs")
        let source = try store.append(conversationID: conversation.id, role: .human, text: "The bicycle is stored in a locked shed.", status: .complete, turnID: "async-turn", eventID: "semantic-async-source")
        let encoder = FixtureEncoder(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let callbackLock = NSLock()
        var first = true
        encoder.beforeEncoding = {
            callbackLock.lock(); let block = first; first = false; callbackLock.unlock()
            if block { started.signal(); guard release.wait(timeout: .now() + 5) == .success else { throw SemanticError.unavailable } }
        }
        let index = try SemanticIndex(store: store, encoder: encoder)
        let begin = ProcessInfo.processInfo.systemUptime
        index.schedule(projectID: "semantic-async")
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        let entered = started.wait(timeout: .now() + 2) == .success
        index.schedule(projectID: "semantic-async") // Coalesced while running.
        let pending = try index.search(query: "bicycle", projectID: "semantic-async")
        release.signal()
        var completed = false
        for _ in 0..<100 {
            if try index.search(query: "bicycle", projectID: "semantic-async").manifest.coverage.complete { completed = true; break }
            usleep(1000)
        }
        let chunkCount = try rows(index.directory.appendingPathComponent("index.sqlite3"), eventID: source.id).count
        return ["semantic_schedule_returns_before_encoder_completion": entered && elapsed < 1,
                "semantic_raw_search_available_during_background_job": pending.hits.first?.eventID == source.id && pending.manifest.coverage.pendingSources == 1,
                "semantic_async_job_completes_without_duplicate_publication": completed && chunkCount == 1]
    }

    private final class FixtureEncoder: SemanticEmbeddingAdapter {
        var metadataVersion = "synthetic-protocol-v1"
        var failing = false
        var unavailable = false
        var beforeEncoding: (() throws -> Void)?
        var metadata: [String: String] { ["provider": "test-only-fixture", "revision": metadataVersion, "dimension": "3"] }
        let dimension = 3
        func encode(_ text: String) throws -> SemanticEncoding {
            try beforeEncoding?()
            if failing { throw SemanticError.unavailable }
            if unavailable { return .unsupported(.adapterUnavailable) }
            if text.contains("UNSUPPORTED") { return .unsupported(.codeLike) }
            if text.contains("bicycle") || text.contains("bike") { return .vector([1, 0, 0]) }
            if text.contains("cat") { return .vector([0, 1, 0]) }
            return .vector([0, 0, 1])
        }
    }

    private static func meteredSearchChecks(store: MemoryStore) throws -> [String: Bool] {
        let project = "semantic-metered"
        let archive = try store.createConversation(projectID: project, title: "Metered semantic archive")
        let source = try store.append(conversationID: archive.id, role: .human,
            text: String(repeating: "A bicycle crosses the quiet town. ", count: 8), status: .complete,
            turnID: "semantic-metered-first-turn", eventID: "semantic-metered-first-source")
        let second = try store.append(conversationID: archive.id, role: .human,
            text: "A bicycle rests against the garden wall.", status: .complete,
            turnID: "semantic-metered-second-turn", eventID: "semantic-metered-second-source")
        let encoder = FixtureEncoder()
        var configuration = SemanticIndexConfiguration()
        configuration.chunkBytes = 64; configuration.maximumCandidateChunks = 1
        configuration.maximumManifestSources = 10; configuration.maximumReportedHoles = 4
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration)
        _ = try index.process(projectID: project, maximumChunks: 128)
        var calls = 0
        encoder.beforeEncoding = { calls += 1 }
        let fixture = try meteredEpisode(store: store, project: project)
        let report = try index.search(query: "bike", projectID: project, includeLiteral: false, episodeLease: fixture.lease)
        let receipt = try fixture.lease.checkActive()
        var checks: [String: Bool] = [
            "semantic_metered_query_encoder_has_call_and_unknown_input": calls == 1 && receipt.charged.modelCalls == 1 && receipt.unknownInputOperations == 1 && receipt.charged.encoderInputBytes == 4 && receipt.charged.inputTokens == 0,
            "semantic_metered_vector_budget_includes_lookahead_row": receipt.charged.vectorBytes == 2 * (encoder.dimension * 4 + 1) && report.manifest.vectorCandidatesInspected == 1,
            "semantic_metered_search_one_host_operation": receipt.charged.memoryOperations == 1,
            "semantic_metered_manifest_and_continuation_bind_episode": report.manifest.episodeID == fixture.lease.episodeID && report.manifest.vectorContinuation?.episodeID == fixture.lease.episodeID,
            "semantic_metered_result_reads_have_raw_charge": report.hits.count == 1 && receipt.charged.rawSourceBytes == (report.hits[0].excerpt.utf8.count + 1) * 2
        ]
        let replayed = try index.replay(manifestID: report.manifestID, projectID: project, episodeLease: fixture.lease)
        let replayReceipt = try fixture.lease.checkActive()
        checks["semantic_metered_replay_costs_slot_and_repeated_original_bytes"] = replayed.hits.map(\.excerpt) == report.hits.map(\.excerpt)
            && replayReceipt.charged.memoryOperations == 2 && replayReceipt.charged.rawSourceBytes == receipt.charged.rawSourceBytes * 2
        let continued = try index.search(query: "bike", projectID: project, includeLiteral: false,
            continuation: report.manifest.vectorContinuation, episodeLease: fixture.lease)
        checks["semantic_metered_continuation_preserves_frontier_and_raw_snapshot"] = continued.manifest.sourceFrontier == report.manifest.sourceFrontier
            && continued.manifest.rawSnapshotID == report.manifest.rawSnapshotID
            && continued.manifest.meteredLexicalCoverage == report.manifest.meteredLexicalCoverage
        let other = try meteredEpisode(store: store, project: project)
        checks["semantic_metered_continuation_rejects_replenished_episode"] = rejects {
            _ = try index.search(query: "bike", projectID: project, includeLiteral: false,
                continuation: report.manifest.vectorContinuation, episodeLease: other.lease)
        }
        var strictLimits = EpisodeLimits(); strictLimits.requireKnownModelInput = true
        let strict = try meteredEpisode(store: store, project: project, limits: strictLimits)
        let beforeStrict = calls
        let strictReport = try index.search(query: "bicycle", projectID: project, includeLiteral: false, episodeLease: strict.lease)
        let strictReceipt = try strict.lease.checkActive()
        checks["semantic_strict_input_mode_skips_opaque_encoder_before_inference"] = calls == beforeStrict && strictReceipt.charged.modelCalls == 0
            && strictReceipt.unknownInputOperations == 0 && strictReport.manifest.queryDisposition == "inputAccountingUnavailable"
        checks["semantic_strict_input_mode_retains_original_lexical_evidence"] = Set(strictReport.hits.map(\.eventID)) == [source.id, second.id]
            && strictReceipt.charged.vectorBytes == 0

        var smallLimits = EpisodeLimits(); smallLimits.resources.vectorBytes = 1
        let small = try meteredEpisode(store: store, project: project, limits: smallLimits)
        do {
            _ = try ChatContextPreparation.prepare(store: store, conversationID: small.conversationID, projectID: project,
                prompt: "Where is bicycle?", system: "", excludingEventID: small.humanEventID, semanticIndex: index, episodeLease: small.lease)
            checks["semantic_budget_failure_is_not_swallowed_by_lexical_fallback"] = false
        } catch let error as EpisodeBudgetError {
            let result = try store.episodeReceipt(id: small.lease.episodeID, clock: small.clock.now())
            checks["semantic_budget_failure_is_not_swallowed_by_lexical_fallback"] = error.failureCode == "episode_budget_exceeded"
                && result.charged.rawSourceBytes == (source.byteCount + second.byteCount) * 6 && result.charged.modelCalls == 1
        }
        let stopped = try meteredEpisode(store: store, project: project)
        encoder.beforeEncoding = { _ = try stopped.lease.finish(reason: .cancelled) }
        do {
            _ = try ChatContextPreparation.prepare(store: store, conversationID: stopped.conversationID, projectID: project,
                prompt: "Where is bicycle?", system: "", excludingEventID: stopped.humanEventID, semanticIndex: index, episodeLease: stopped.lease)
            checks["semantic_stop_during_encoder_fences_result_and_fallback"] = false
        } catch let error as EpisodeBudgetError {
            let result = try store.episodeReceipt(id: stopped.lease.episodeID, clock: stopped.clock.now())
            checks["semantic_stop_during_encoder_fences_result_and_fallback"] = error.failureCode == "episode_inactive"
                && result.charged.rawSourceBytes == (source.byteCount + second.byteCount) * 6 && result.charged.modelCalls == 1
        }
        let deadline = try meteredEpisode(store: store, project: project)
        encoder.beforeEncoding = { deadline.clock.ticks = 200_000_000_000 }
        do {
            _ = try ChatContextPreparation.prepare(store: store, conversationID: deadline.conversationID, projectID: project,
                prompt: "Where is bicycle?", system: "", excludingEventID: deadline.humanEventID, semanticIndex: index, episodeLease: deadline.lease)
            checks["semantic_deadline_during_encoder_fences_result_and_fallback"] = false
        } catch let error as EpisodeBudgetError {
            let result = try store.episodeReceipt(id: deadline.lease.episodeID, clock: deadline.clock.now())
            checks["semantic_deadline_during_encoder_fences_result_and_fallback"] = error.failureCode == "episode_deadline_exceeded"
                && result.charged.modelCalls == 1 && result.charged.vectorBytes == 0
        }
        encoder.beforeEncoding = nil
        let sidecar = index.directory.appendingPathComponent("index.sqlite3")
        try alter(sidecar, sql: "UPDATE chunks SET vector=? WHERE event_id='semantic-metered-first-source'", bytes: Data(repeating: 0, count: 1_048_576))
        let corrupt = try meteredEpisode(store: store, project: project)
        do {
            _ = try ChatContextPreparation.prepare(store: store, conversationID: corrupt.conversationID, projectID: project,
                prompt: "Where is bike?", system: "", excludingEventID: corrupt.humanEventID, semanticIndex: index, episodeLease: corrupt.lease)
            checks["semantic_oversized_vector_integrity_error_propagates_without_fallback"] = false
        } catch SemanticError.sourceMismatch {
            let result = try corrupt.lease.checkActive()
            checks["semantic_oversized_vector_integrity_error_propagates_without_fallback"] = result.charged.rawSourceBytes == 0
                && result.charged.vectorBytes == 2 * (encoder.dimension * 4 + 1) && result.charged.modelCalls == 1
        }
        try alter(sidecar, sql: "UPDATE chunks SET vector=? WHERE event_id='semantic-metered-first-source'", bytes: SemanticIndex.vectorData([1, 0, 0]))
        encoder.failing = true
        let encoderFailure = try meteredEpisode(store: store, project: project)
        let failedReport = try index.search(query: "bicycle", projectID: project, includeLiteral: false, episodeLease: encoderFailure.lease)
        let failureReceipt = try encoderFailure.lease.checkActive()
        checks["semantic_encoder_failure_keeps_spent_call_and_same_lease_lexical_evidence"] = failureReceipt.charged.modelCalls == 1
            && failureReceipt.unknownInputOperations == 1 && failedReport.hits.count == 2 && failedReport.manifest.queryDisposition == "adapterUnavailable"
        encoder.failing = false
        // A genuine sidecar outage after raw candidate work exercises the
        // coordinator fallback. The original sources and FTS remain usable.
        try alter(sidecar, sql: "ALTER TABLE chunks RENAME TO unavailable_chunks", bytes: nil)
        let fallback = try meteredEpisode(store: store, project: project)
        let fallbackSnapshot = try ChatContextPreparation.prepare(store: store, conversationID: fallback.conversationID, projectID: project,
            prompt: "Where is bicycle?", system: "", excludingEventID: fallback.humanEventID, semanticIndex: index, episodeLease: fallback.lease)
        let fallbackReceipt = try fallback.lease.checkActive()
        let audit = try JSONSerialization.jsonObject(with: fallbackSnapshot.retrievalAuditJSON!) as! [String: Any]
        checks["semantic_sidecar_outage_fallback_preserves_prior_raw_work"] = fallbackReceipt.charged.rawSourceBytes >= (source.byteCount + second.byteCount) * 10
            && fallbackReceipt.charged.modelCalls == 1 && fallbackReceipt.charged.memoryOperations == 1
            && audit["mode"] as? String == "lexical_fallback" && fallbackSnapshot.evidence.count == 2
        return checks
    }

    private struct MeteredFixture { let lease: EpisodeLease; let conversationID: String; let humanEventID: String; let clock: MeteredClock }
    private final class MeteredClock: EpisodeClockSource {
        var ticks: UInt64 = 1_000_000_000
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-semantic-metered-clock", continuousNanoseconds: ticks, utc: Date())
        }
    }
    private static func meteredEpisode(store: MemoryStore, project: String, limits: EpisodeLimits = .init()) throws -> MeteredFixture {
        let chat = try store.createConversation(projectID: project, title: "Synthetic metered query")
        let clock = MeteredClock(), id = UUID().uuidString, human = "semantic-metered-current-" + UUID().uuidString
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "semantic-metered-turn-" + id,
            humanEventID: human, episodeID: id, text: "Synthetic accepted query", limits: limits, clock: clock.now())
        return MeteredFixture(lease: EpisodeLease(ledger: store, episodeID: id, clock: clock), conversationID: chat.id, humanEventID: human, clock: clock)
    }

    private struct Range { let offset: Int; let byteCount: Int; let digest: String }
    private static func rows(_ url: URL, eventID: String) throws -> [Range] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw SemanticError.database }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT offset,byte_count,text_digest FROM chunks WHERE event_id=? ORDER BY offset", -1, &statement, nil) == SQLITE_OK else { throw SemanticError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, eventID, -1, transient) == SQLITE_OK else { throw SemanticError.database }
        var output: [Range] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW, let digest = sqlite3_column_text(statement, 2) else { throw SemanticError.database }
            output.append(Range(offset: Int(sqlite3_column_int64(statement, 0)), byteCount: Int(sqlite3_column_int64(statement, 1)), digest: String(cString: digest)))
        }
    }
    private static func alter(_ url: URL, sql: String, bytes: Data?) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw SemanticError.database }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw SemanticError.database }
        defer { sqlite3_finalize(statement) }
        if let bytes {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard bytes.withUnsafeBytes({ sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }) == SQLITE_OK else { throw SemanticError.database }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SemanticError.database }
    }
    private static func reason(_ encoding: SemanticEncoding) -> SemanticUnsupportedReason? { if case .unsupported(let reason) = encoding { return reason }; return nil }
    private static func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func privateMode(_ url: URL, _ mode: Int) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == mode }
}
