import Foundation
import CSQLite

/// Deterministic protocol checks using only public synthetic sources. These
/// fixtures exercise the actual worker and durable main ledger, not a mock
/// accounting layer. They do not measure encoder quality or physical I/O.
enum BackgroundIndexWorkerChecks {
    static func run() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for resource in BackgroundIndexResource.allCases {
            checks.merge(try denial(resource: resource)) { _, new in new }
        }
        checks.merge(try fullSource()) { _, new in new }
        checks.merge(try utf8AndScopes()) { _, new in new }
        checks.merge(try integrity()) { _, new in new }
        checks.merge(try probe()) { _, new in new }
        checks.merge(try initialDenial()) { _, new in new }
        checks.merge(try settlementGap()) { _, new in new }
        checks.merge(try armedRollover()) { _, new in new }
        checks.merge(try schedulingSnapshot()) { _, new in new }
        checks.merge(try fingerprintBudget()) { _, new in new }
        checks.merge(try publicationQuarantine()) { _, new in new }
        return checks
    }

    /// SIGKILL driver: publish only this fixed marker, then retain the live
    /// owner/worker while waiting on stdin at an actual runtime boundary.
    static func produce(directory: URL, barrier: String) throws {
        guard ["armed", "encoder", "before-publication", "after-publication"].contains(barrier) else { throw SemanticError.invalid }
        let store = try MemoryStore(directory: directory), encoder = Encoder()
        let chat = try store.createConversation(projectID: "worker-kill-public", title: "Public process kill fixture")
        _ = try store.append(conversationID: chat.id, role: .human, text: String(repeating: "a", count: 128),
            status: .complete, turnID: "worker-kill-public", eventID: "worker-kill-public-source")
        let ready = {
            FileHandle.standardOutput.write(Data("BOROS_BACKGROUND_WORKER_READY\n".utf8))
            _ = readLine()
        }
        if barrier == "encoder" { encoder.beforeEncode = { if encoder.calls == 1 { ready() } } }
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), workerObserver: { stage, work in
            guard case .source(.chunkAttempt, let source) = work.request.binding.descriptor else { return }
            if barrier == "armed" && stage == .armed && source.offset == 0 { ready() }
            if barrier == "before-publication" && stage == .beforePublication && source.requiresFinalSeal { ready() }
            if barrier == "after-publication" && stage == .publishedBeforeSettlement && source.offset == 0 { ready() }
        })
        _ = try index.process(projectID: chat.projectID, maximumChunks: 4)
        withExtendedLifetime(index) {}
    }

    /// Reopening performs journal recovery only. Set resume=false for repeated
    /// reopen checks, then true for an explicit freshly charged worker trigger.
    static func verifyRecovery(directory: URL, barrier: String, resume: Bool) throws -> [String: Bool] {
        guard ["armed", "encoder", "before-publication", "after-publication"].contains(barrier) else { throw SemanticError.invalid }
        let store = try MemoryStore(directory: directory), encoder = Encoder()
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration())
        let before = try index.backgroundBudgetSnapshot(), state = try job(index, eventID: "worker-kill-public-source")
        let records = try workRecords(store)
        let unknown = records.filter { $0.state == .outcomeUnknown }
        let offset = barrier == "before-publication" || barrier == "after-publication" ? 64 : 0
        let calls = barrier == "before-publication" ? 2 : 1
        let expectedRaw = barrier == "before-publication" ? 1048 : 524
        let oldRanges = try ranges(index, eventID: "worker-kill-public-source")
        let prefix = "background_worker_kill_" + barrier.replacingOccurrences(of: "-", with: "_")
        var checks: [String: Bool] = [
            prefix + "_reopen_retains_maximum_charges": before.window?.charged.encoderCalls == calls && before.window?.charged.rawSourceBytes == expectedRaw && before.window?.held == .zero,
            prefix + "_unknown_attempt_is_not_replayed": unknown.count == 1 && unknown.first?.recovered == true && encoder.calls == 0,
            prefix + "_pending_cursor_failure_attempts_preserved": state?.state == "pending" && state?.offset == offset && state?.attempts == 0,
            prefix + "_unsealed_prefix_unavailable": state?.ready == 0 && oldRanges.count == offset / 64,
            prefix + "_all_publications_have_armed_charge": records.filter { $0.request.resources.encoderCalls > 0 }.allSatisfy { $0.charged == $0.request.resources && $0.state.wasArmed },
        ]
        if resume {
            let work = try index.process(projectID: "worker-kill-public", maximumChunks: 4)
            let after = try index.backgroundBudgetSnapshot(), last = try job(index, eventID: "worker-kill-public-source")
            let ranges = try self.ranges(index, eventID: "worker-kill-public-source")
            let remainingCalls = offset == 0 ? 2 : 1
            let extraRaw = offset == 0 ? 1048 : 788
            let recoveredRecords = try workRecords(store)
            checks[prefix + "_new_attempt_resumes_exact_cursor"] = work.publishedChunks == remainingCalls && encoder.calls == remainingCalls && last?.state == "complete" && last?.offset == 128 && last?.attempts == 0 && ranges.map(\.offset) == [0, 64]
            checks[prefix + "_resume_reseals_and_charges_new_work"] = after.window?.id == before.window?.id && after.window?.charged.rawSourceBytes == expectedRaw + extraRaw && after.window?.charged.encoderCalls == calls + remainingCalls
            checks[prefix + "_old_unknown_record_is_immutable"] = unknown.first.map { old in recoveredRecords.first { $0.request.id == old.request.id } == old } == true
            checks[prefix + "_complete_ready_frontier_and_exact_ranges"] = last?.ready == ranges.last?.publication && ranges.allSatisfy { $0.count == 64 && $0.digest == SemanticIndex.digest(Data(String(repeating: "a", count: 64).utf8)) }
        }
        return checks
    }

    private static func workRecords(_ store: MemoryStore) throws -> [BackgroundIndexWorkRecord] {
        try query(store.directory.appendingPathComponent("memory.sqlite3"), sql: "SELECT record_json FROM background_index_work ORDER BY id", arguments: []) { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw SemanticError.database }
            return try BackgroundIndexCanonical.decode(BackgroundIndexWorkRecord.self, bytes: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
    }

    /// Longer standalone acceptance fixture: actual 4 MiB source, all 4,096
    /// ranges, real public startup probes, cap pause, next-window completion.
    /// Kept separate from the short app suite so its runtime is explicit.
    static func runFullLargeSource() throws -> [String: Bool] {
        let directory = temporary("full-4mib")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), clock = Clock(), encoder = Encoder()
        let chat = try store.createConversation(projectID: "worker-full-4mib", title: "Public full four MiB quota fixture")
        let event = try store.append(conversationID: chat.id, role: .human,
            text: String(repeating: "x", count: MemoryStore.maximumPayloadBytes), status: .complete,
            turnID: "worker-full-4mib-public", eventID: "worker-full-4mib-public-source")
        _ = try BackgroundWorkerAccounting.probe(store: store, encoder: encoder, adapterIdentity: "public-full-4mib-probe", clock: clock, limits: .development)
        var config = configuration(); config.chunkBytes = 1024
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: config, backgroundClock: clock)
        let first = try index.process(projectID: chat.projectID, maximumChunks: 4096)
        let initial = try index.backgroundBudgetSnapshot(), paused = try job(index, eventID: event.id)
        let source = BackgroundWorkerAccounting.reference(try store.sourceReference(eventID: event.id, projectID: chat.projectID)!)
        let seal = try BackgroundWorkerRawRules.initialSeal(source: source).rawSourceBytes
        var checks: [String: Bool] = [
            "background_worker_full_4mib_4096_calls_include_probes": initial.window?.charged.encoderCalls == 4096 && encoder.calls == 4096 && first.publishedChunks == 4094,
            "background_worker_full_4mib_cap_pause_exact_cursor": first.failedChunks == 0 && paused?.attempts == 0 && paused?.state == "pending" && paused?.offset == 4094 * 1024 && paused?.ready == 0,
            "background_worker_full_4mib_first_window_bounded_raw": initial.window?.charged.rawSourceBytes == seal + 4094 * 4 * 1025,
        ]
        clock.advanceDay()
        let second = try index.process(projectID: chat.projectID, maximumChunks: 4)
        let complete = try job(index, eventID: event.id), final = try index.backgroundBudgetSnapshot()
        let chunks = try ranges(index, eventID: event.id)
        let pieceDigest = SemanticIndex.digest(Data(String(repeating: "x", count: 1024).utf8))
        let exactRanges = chunks.enumerated().allSatisfy { position, value in value.offset == position * 1024 && value.count == 1024 && value.digest == pieceDigest }
        let combinedRaw = (initial.window?.charged.rawSourceBytes ?? 0) + (final.window?.charged.rawSourceBytes ?? 0)
        checks["background_worker_full_4mib_second_window_finishes_two_ranges"] = second.publishedChunks == 2 && second.failedChunks == 0 && final.window?.charged.encoderCalls == 2 && encoder.calls == 4098
        checks["background_worker_full_4mib_all_original_ranges_exact"] = chunks.count == 4096 && exactRanges && complete?.offset == MemoryStore.maximumPayloadBytes && complete?.state == "complete" && complete?.ready == chunks.last?.publication
        checks["background_worker_full_4mib_pause_reseal_charged"] = combinedRaw == 3 * seal + 4096 * 4 * 1025 && combinedRaw == 41_984_024
        let history = try query(store.directory.appendingPathComponent("memory.sqlite3"), sql: "SELECT window_json FROM background_index_windows WHERE id=?", arguments: [initial.window!.id]) { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw SemanticError.database }
            return try BackgroundIndexCanonical.decode(BackgroundIndexWindow.self, bytes: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }.first
        checks["background_worker_full_4mib_original_window_retained"] = initial.window?.id != final.window?.id && history?.charged == initial.window?.charged && history?.state == .closed
        return checks
    }

    private static func denial(resource: BackgroundIndexResource) throws -> [String: Bool] {
        let directory = temporary("deny-" + resource.rawValue)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let conversation = try store.createConversation(projectID: "worker-denial", title: "Public worker quota fixture")
        let event = try store.append(conversationID: conversation.id, role: .human,
            text: String(repeating: "a", count: 64), status: .complete, turnID: "public-denial", eventID: "public-worker-denial")
        let encoder = Encoder(), clock = Clock()
        let source = BackgroundWorkerAccounting.reference(try store.sourceReference(eventID: event.id, projectID: event.projectID)!)
        let seal = try BackgroundWorkerRawRules.initialSeal(source: source)
        let final = try BackgroundWorkerRawRules.chunkAttempt(source: source, offset: 0, chunkBytes: 64, dimension: 3)
        let cap = BackgroundIndexResources.developmentCaps
        // Initial scheduling consumes 6 rows, peek 1, initial seal 3. The
        // composite final attempt requires another 8. Deny that exact request.
        let limits = BackgroundIndexLimits(resources: .init(
            rawSourceBytes: resource == .rawSourceBytes ? seal.rawSourceBytes + final.rawSourceBytes - 1 : cap.rawSourceBytes,
            encoderCalls: resource == .encoderCalls ? 0 : cap.encoderCalls,
            encoderInputBytes: resource == .encoderInputBytes ? 63 : cap.encoderInputBytes,
            vectorBytes: resource == .vectorBytes ? 11 : cap.vectorBytes,
            metadataRows: resource == .metadataRows ? 17 : cap.metadataRows,
            sourceJobs: resource == .sourceJobs ? 0 : cap.sourceJobs))
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), backgroundClock: clock, backgroundLimits: limits)
        let receipt = try index.process(projectID: event.projectID)
        let state = try job(index, eventID: event.id)
        let budget = try index.backgroundBudgetSnapshot()
        let reads = store.backgroundReaderDiagnostics()
        let prefix = "background_worker_" + resource.rawValue
        var checks: [String: Bool] = [
            prefix + "_denial_pauses": receipt.budgetPauseReason == BackgroundIndexBudgetError.exhausted.failureCode,
            prefix + "_no_encoder_or_publication": encoder.calls == 0 && receipt.publishedChunks == 0 && receipt.failedChunks == 0,
            prefix + "_cursor_attempts_unchanged": resource == .sourceJobs ? state == nil : state?.offset == 0 && state?.attempts == 0 && state?.state == "pending",
            prefix + "_maximum_holds_released": budget.window?.held == .zero,
        ]
        checks[prefix + "_no_payload_after_denied_page"] = reads.payloadPages == (resource == .sourceJobs ? 0 : 1)
            && reads.materializedBytes == (resource == .sourceJobs ? 0 : 64)
        checks[prefix + "_raw_before_denied_page_only"] = budget.window?.charged.rawSourceBytes == (resource == .sourceJobs ? 0 : seal.rawSourceBytes)
        // Repeating a denied trigger cannot renew the window or spend an
        // encoder attempt, advance a source, or turn a hole into completion.
        let windowID = budget.window?.id
        let repeated = try index.process(projectID: event.projectID)
        checks[prefix + "_repeat_keeps_global_window"] = try index.backgroundBudgetSnapshot().window?.id == windowID
            && repeated.publishedChunks == 0 && repeated.failedChunks == 0 && encoder.calls == 0
        return checks
    }

    private static func initialDenial() throws -> [String: Bool] {
        let directory = temporary("initial-denial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), encoder = Encoder(), clock = Clock()
        let chat = try store.createConversation(projectID: "worker-initial-denial", title: "Public initial seal quota")
        let event = try store.append(conversationID: chat.id, role: .human, text: String(repeating: "a", count: 64), status: .complete, turnID: "initial-seal", eventID: "initial-seal-public")
        let cap = BackgroundIndexResources.developmentCaps
        let limits = BackgroundIndexLimits(resources: .init(rawSourceBytes: 135, encoderCalls: cap.encoderCalls,
            encoderInputBytes: cap.encoderInputBytes, vectorBytes: cap.vectorBytes, metadataRows: cap.metadataRows, sourceJobs: cap.sourceJobs))
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), backgroundClock: clock, backgroundLimits: limits)
        let receipt = try index.process(projectID: event.projectID), state = try job(index, eventID: event.id)
        return [
            "background_worker_initial_seal_denied_before_payload": store.backgroundReaderDiagnostics().payloadPages == 0 && encoder.calls == 0,
            "background_worker_initial_seal_denial_preserves_job": receipt.failedChunks == 0 && receipt.publishedChunks == 0 && state?.offset == 0 && state?.attempts == 0 && state?.state == "pending",
        ]
    }

    private static func fullSource() throws -> [String: Bool] {
        let directory = temporary("large")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let conversation = try store.createConversation(projectID: "worker-large", title: "Public four MiB source")
        let event = try store.append(conversationID: conversation.id, role: .human,
            text: String(repeating: "x", count: MemoryStore.maximumPayloadBytes), status: .complete,
            turnID: "public-large", eventID: "public-worker-large")
        let encoder = Encoder(), clock = Clock()
        var config = configuration(); config.chunkBytes = 1024
        let limits = BackgroundIndexLimits(resources: .init(rawSourceBytes: 512 * 1_048_576, encoderCalls: 3,
            encoderInputBytes: 16 * 1_048_576, vectorBytes: 32 * 1_048_576, metadataRows: 100_000, sourceJobs: 4096))
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: config, backgroundClock: clock, backgroundLimits: limits)
        let receipt = try index.process(projectID: event.projectID, maximumChunks: 4)
        let state = try job(index, eventID: event.id), budget = try index.backgroundBudgetSnapshot()
        let source = BackgroundWorkerAccounting.reference(try store.sourceReference(eventID: event.id, projectID: event.projectID)!)
        let expected = try BackgroundWorkerRawRules.initialSeal(source: source).rawSourceBytes + 3 * 4 * 1025
        let callsAtPause = encoder.calls
        let before = try index.search(query: "missing", projectID: event.projectID, includeLiteral: false)
        var checks: [String: Bool] = [
            "background_worker_4mib_bounded_pages_charge": budget.window?.charged.rawSourceBytes == expected && expected < 3 * event.byteCount,
            "background_worker_4mib_encoder_cap_retains_pending_cursor": callsAtPause == 3 && receipt.publishedChunks == 3 && state?.offset == 3072 && state?.state == "pending" && state?.attempts == 0,
            "background_worker_4mib_prefix_never_ready": state?.ready == 0 && before.manifest.coverage.pendingSources == 1 && before.manifest.results.isEmpty,
            "background_worker_4mib_unknown_input_explicit": budget.window?.unknownEncoderCalls == 3,
        ]
        // A continuous-day rollover opens a new window; it does not rewrite the
        // old work or resume inference merely by reading a budget snapshot.
        clock.advanceDay()
        let snapshot = try index.backgroundBudgetSnapshot()
        checks["background_worker_snapshot_does_not_auto_resume"] = snapshot.rolloverEligible && encoder.calls == 4 // search above encoded one query
        let resumed = try index.process(projectID: event.projectID, maximumChunks: 1)
        let resumedState = try job(index, eventID: event.id), resumedWindow = try index.backgroundBudgetSnapshot().window
        checks["background_worker_rollover_resume_preserves_offset"] = resumed.publishedChunks == 1 && resumedState?.offset == 4096
            && resumedWindow?.id != budget.window?.id
        return checks
    }

    private static func utf8AndScopes() throws -> [String: Bool] {
        let directory = temporary("utf8")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), encoder = Encoder(), clock = Clock()
        let first = try store.createConversation(projectID: "worker-caf\u{e9}", title: "Public UTF8 fixture")
        let second = try store.createConversation(projectID: "worker-cafe\u{301}", title: "Distinct UTF8 scope")
        let text = String(repeating: "public café 中文 🐈 scope. ", count: 8)
        let event = try store.append(conversationID: first.id, role: .human, text: text, status: .partial, turnID: "utf8-first", eventID: "utf8-public-caf\u{e9}")
        let foreign = try store.append(conversationID: second.id, role: .human, text: "A foreign public source.", status: .complete, turnID: "utf8-second", eventID: "utf8-public-cafe\u{301}")
        let empty = try store.append(conversationID: first.id, role: .assistant, text: "", status: .complete, turnID: "utf8-empty", eventID: "utf8-public-empty")
        var config = configuration(); config.maximumNewSourcesPerRun = 2
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: config, backgroundClock: clock)
        let firstReceipt = try index.process(projectID: first.projectID, maximumChunks: 64)
        let firstWindow = try index.backgroundBudgetSnapshot().window
        let secondReceipt = try index.process(projectID: second.projectID, maximumChunks: 64)
        let rows = try ranges(index, eventID: event.id)
        var rebuilt = Data(), next = 0, exact = true
        for row in rows {
            let page = try store.read(eventID: event.id, offset: row.offset, length: row.count)
            exact = exact && page.offset == next && page.byteCount == row.count && SemanticIndex.digest(Data(page.text.utf8)) == row.digest
            rebuilt.append(Data(page.text.utf8)); next += row.count
        }
        let secondWindow = try index.backgroundBudgetSnapshot().window
        let foreignState = try job(index, eventID: foreign.id), emptyState = try job(index, eventID: empty.id)
        let emptyRanges = try ranges(index, eventID: empty.id), eventState = try job(index, eventID: event.id)
        return [
            "background_worker_utf8_ranges_reconstruct_complete_source": exact && rebuilt == Data(text.utf8) && next == event.byteCount && rows.count > 1,
            "background_worker_utf8_scope_ids_are_distinct": firstReceipt.scheduledSources == 2 && secondReceipt.scheduledSources == 1 && foreignState?.state == "complete",
            "background_worker_projects_share_daily_window": firstWindow?.id == secondWindow?.id && (secondWindow?.charged.encoderCalls ?? 0) > (firstWindow?.charged.encoderCalls ?? 0),
            "background_worker_empty_source_sealed_without_encoder": emptyState?.state == "complete" && emptyRanges.isEmpty,
            "background_worker_complete_source_ready_frontier": eventState?.ready == rows.last?.publication,
        ]
    }

    private static func integrity() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for stage in ["initial", "final", "temporary"] {
            let directory = temporary("integrity-" + stage)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try MemoryStore(directory: directory), encoder = Encoder(), clock = Clock()
            let conversation = try store.createConversation(projectID: "worker-integrity", title: "Public integrity fixture")
            let original = String(repeating: "a", count: 128)
            let event = try store.append(conversationID: conversation.id, role: .human, text: original, status: .complete,
                turnID: "public-integrity", eventID: "public-worker-integrity")
            let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), backgroundClock: clock)
            if stage == "initial" { try corrupt(store, eventID: event.id, payload: Data(String(repeating: "b", count: 128).utf8)) }
            if stage == "final" {
                _ = try index.process(projectID: event.projectID, maximumChunks: 1)
                try corrupt(store, eventID: event.id, payload: Data((String(repeating: "b", count: 64) + String(repeating: "a", count: 64)).utf8))
            }
            if stage == "temporary" {
                // Corrupt after the initial seal, encode that bounded prefix,
                // then restore before the final seal. The current protocol
                // explicitly does not prove every earlier vector's original
                // bytes; delivered range validation remains the later gate.
                encoder.beforeEncode = {
                    if encoder.calls == 1 { try corrupt(store, eventID: event.id, payload: Data((String(repeating: "a", count: 64) + String(repeating: "b", count: 64)).utf8)) }
                    if encoder.calls == 2 { try corrupt(store, eventID: event.id, payload: Data(original.utf8)) }
                }
            }
            let receipt = try index.process(projectID: event.projectID, maximumChunks: stage == "temporary" ? 3 : 1)
            let state = try job(index, eventID: event.id)
            if stage == "initial" {
                checks["background_worker_initial_corruption_before_encoder"] = encoder.calls == 0 && receipt.failedChunks == 1 && state?.attempts == 1 && state?.ready == 0
            } else if stage == "final" {
                checks["background_worker_fresh_final_seal_rejects_corruption"] = encoder.calls == 2 && receipt.publishedChunks == 0 && state?.state == "failed" && state?.offset == 64 && state?.ready == 0
            } else {
                let chunks = try ranges(index, eventID: event.id)
                checks["background_worker_temporary_restore_limitation_explicit"] = state?.state == "complete" && (state?.ready ?? 0) > 0
                    && chunks.count == 2 && chunks[1].digest != SemanticIndex.digest(Data(String(repeating: "a", count: 64).utf8))
            }
        }
        return checks
    }

    private static func probe() throws -> [String: Bool] {
        let directory = temporary("probe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), encoder = Encoder(), clock = Clock()
        let cap = BackgroundIndexLimits(resources: .init(encoderCalls: 1, encoderInputBytes: 65))
        var denied = false
        do { _ = try BackgroundWorkerAccounting.probe(store: store, encoder: encoder, adapterIdentity: "public-test-probe", clock: clock, limits: cap) }
        catch let error as BackgroundIndexBudgetError { denied = error == .exhausted }
        let before = try store.backgroundBudgetSnapshot(clockSource: clock)
        let metadata = try BackgroundWorkerAccounting.probe(store: store, encoder: encoder, adapterIdentity: "public-test-probe", clock: clock, limits: .development)
        let after = try store.backgroundBudgetSnapshot(clockSource: clock)
        return [
            "background_worker_probe_preflight_denies_all_inference": denied && before.window == nil,
            "background_worker_probe_actual_two_calls_charged": encoder.calls == 2 && after.window?.charged.encoderCalls == 2 && after.window?.charged.encoderInputBytes == 65,
            "background_worker_probe_fingerprint_bound_to_vectors": metadata["probe_digest"] != "unavailable" && after.window?.unknownEncoderCalls == 2,
        ]
    }

    private static func settlementGap() throws -> [String: Bool] {
        let directory = temporary("settlement-gap")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MemoryStore? = try MemoryStore(directory: directory)
        let encoder = Encoder(), clock = Clock()
        let chat = try store!.createConversation(projectID: "worker-gap", title: "Public settlement gap")
        let event = try store!.append(conversationID: chat.id, role: .human, text: String(repeating: "a", count: 128), status: .complete, turnID: "gap-public", eventID: "gap-public-source")
        var interruptedWorkID: String?
        var index: SemanticIndex? = try SemanticIndex(store: store!, encoder: encoder, configuration: configuration(), backgroundClock: clock, workerObserver: { stage, work in
            if stage == .publishedBeforeSettlement, case .source(.chunkAttempt, _) = work.request.binding.descriptor {
                interruptedWorkID = work.request.id
                throw SemanticError.unavailable
            }
        })
        let receipt = try index!.process(projectID: event.projectID, maximumChunks: 4)
        let before = try index!.backgroundBudgetSnapshot(), firstState = try job(index!, eventID: event.id)
        var checks: [String: Bool] = [
            "background_worker_gap_commit_preserves_cursor_charge": receipt.publishedChunks == 1 && receipt.failedChunks == 0 && firstState?.offset == 64 && firstState?.attempts == 0 && firstState?.state == "pending" && before.window?.charged.encoderCalls == 1,
            "background_worker_gap_prefix_stays_unavailable": firstState?.ready == 0,
        ]
        index = nil; store = nil
        store = try MemoryStore(directory: directory)
        let recovered = try store!.backgroundWork(workID: interruptedWorkID!)
        let reopened = try store!.backgroundBudgetSnapshot(clockSource: clock)
        checks["background_worker_gap_reopen_unknown_without_refund"] = recovered?.state == .outcomeUnknown && recovered?.recovered == true && reopened.window?.charged == before.window?.charged && reopened.window?.id == before.window?.id
        store = nil; store = try MemoryStore(directory: directory)
        let again = try store!.backgroundBudgetSnapshot(clockSource: clock)
        checks["background_worker_gap_repeated_reopen_stable"] = again.window?.charged == reopened.window?.charged && again.window?.held == .zero
        let resumedEncoder = Encoder()
        index = try SemanticIndex(store: store!, encoder: resumedEncoder, configuration: configuration(), backgroundClock: clock)
        let pendingState = try job(index!, eventID: event.id)
        checks["background_worker_gap_no_startup_encoder_replay"] = resumedEncoder.calls == 0 && pendingState?.offset == 64
        let resumed = try index!.process(projectID: event.projectID, maximumChunks: 1)
        let lastState = try job(index!, eventID: event.id), chunks = try ranges(index!, eventID: event.id)
        checks["background_worker_gap_resume_has_no_duplicate_ranges"] = resumed.publishedChunks == 1 && resumedEncoder.calls == 1 && chunks.map(\.offset) == [0, 64] && lastState?.state == "complete" && lastState?.ready == chunks.last?.publication
        let source = BackgroundWorkerAccounting.reference(try store!.sourceReference(eventID: event.id, projectID: event.projectID)!)
        let initial = try BackgroundWorkerRawRules.initialSeal(source: source).rawSourceBytes
        let final = try BackgroundWorkerRawRules.chunkAttempt(source: source, offset: 64, chunkBytes: 64, dimension: 3).rawSourceBytes
        let after = try index!.backgroundBudgetSnapshot()
        checks["background_worker_gap_resume_reseals_under_new_charge"] = after.window?.charged.rawSourceBytes == (before.window?.charged.rawSourceBytes ?? 0) + initial + final
        return checks
    }

    private static func armedRollover() throws -> [String: Bool] {
        let directory = temporary("armed-rollover")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), encoder = Encoder(), clock = Clock()
        let chat = try store.createConversation(projectID: "worker-rollover", title: "Public armed rollover")
        let event = try store.append(conversationID: chat.id, role: .human, text: String(repeating: "a", count: 64), status: .complete, turnID: "armed-rollover", eventID: "armed-rollover-public")
        var originalWork: BackgroundIndexWorkRecord?
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), backgroundClock: clock, workerObserver: { stage, work in
            if stage == .armed, case .source(.chunkAttempt, _) = work.request.binding.descriptor {
                originalWork = work; clock.advanceDay()
            }
        })
        let receipt = try index.process(projectID: event.projectID, maximumChunks: 1)
        let settled = try store.backgroundWork(workID: originalWork!.request.id), snapshot = try index.backgroundBudgetSnapshot()
        return [
            "background_worker_armed_attempt_finishes_original_window": receipt.publishedChunks == 1 && settled?.state == .completed && settled?.windowID == originalWork?.windowID && snapshot.window?.id == originalWork?.windowID,
            "background_worker_rollover_is_not_implicit_deadline": snapshot.rolloverEligible && encoder.calls == 1 && snapshot.window?.charged.encoderCalls == 1,
        ]
    }

    private static func schedulingSnapshot() throws -> [String: Bool] {
        let directory = temporary("schedule-snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), encoder = Encoder(), clock = Clock()
        let chat = try store.createConversation(projectID: "worker-large-public-scheduling", title: "Public snapshot bounded scheduling")
        for number in 0..<256 {
            _ = try store.append(conversationID: chat.id, role: .human, text: "public", status: .complete,
                turnID: "schedule-public-" + String(number), eventID: "public-scheduling-event-" + String(repeating: "s", count: 120) + String(number))
        }
        var config = configuration(); config.maximumNewSourcesPerRun = 256
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: config, backgroundClock: clock)
        let first = try index.process(projectID: chat.projectID, maximumChunks: 0)
        var count = first.scheduledSources
        for _ in 0..<10 {
            let next = try index.process(projectID: chat.projectID, maximumChunks: 0)
            count += next.scheduledSources
            if next.scheduledSources == 0 { break }
        }
        let snapshot = try index.backgroundBudgetSnapshot()
        return [
            "background_worker_schedule_snapshot_uses_bounded_prefix": first.scheduledSources > 0 && first.scheduledSources < 256 && first.budgetPauseReason == nil,
            "background_worker_schedule_prefix_resumes_without_skipping": count == 256 && snapshot.window?.charged.sourceJobs == 256,
            "background_worker_metadata_scheduling_loads_no_source_bytes": encoder.calls == 0 && store.backgroundReaderDiagnostics().payloadPages == 0,
        ]
    }

    private static func fingerprintBudget() throws -> [String: Bool] {
        let directory = temporary("fingerprint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), clock = Clock(), encoder = Encoder()
        let chat = try store.createConversation(projectID: "worker-fingerprint", title: "Public fingerprint quota fixture")
        let event = try store.append(conversationID: chat.id, role: .human, text: "Public source for reindex quota.", status: .complete,
            turnID: "fingerprint-public", eventID: "fingerprint-public-source")
        let cap = BackgroundIndexResources.developmentCaps
        let limits = BackgroundIndexLimits(resources: .init(rawSourceBytes: cap.rawSourceBytes, encoderCalls: 1,
            encoderInputBytes: cap.encoderInputBytes, vectorBytes: cap.vectorBytes, metadataRows: cap.metadataRows, sourceJobs: cap.sourceJobs))
        var index: SemanticIndex? = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), backgroundClock: clock, backgroundLimits: limits)
        _ = try index!.process(projectID: chat.projectID, maximumChunks: 1)
        let before = try index!.backgroundBudgetSnapshot(), firstFingerprint = index!.indexFingerprint
        index = nil
        var changed = configuration(); changed.chunkBytes = 128
        index = try SemanticIndex(store: store, encoder: encoder, configuration: changed, backgroundClock: clock, backgroundLimits: limits)
        let receipt = try index!.process(projectID: chat.projectID, maximumChunks: 1)
        let after = try index!.backgroundBudgetSnapshot(), state = try job(index!, eventID: event.id)
        return [
            "background_worker_fingerprints_share_global_allowance": firstFingerprint != index!.indexFingerprint && before.window?.id == after.window?.id && after.window?.charged.encoderCalls == 1,
            "background_worker_reindex_denial_retains_pending_hole": receipt.publishedChunks == 0 && receipt.failedChunks == 0 && receipt.budgetPauseReason == BackgroundIndexBudgetError.exhausted.failureCode && state?.state == "pending" && state?.offset == 0 && state?.attempts == 0,
            "background_worker_reindex_jobs_charged_without_encoder_reset": after.window?.charged.sourceJobs == 2 && encoder.calls == 1,
        ]
    }

    private static func publicationQuarantine() throws -> [String: Bool] {
        let directory = temporary("publication-quarantine")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), clock = Clock(), encoder = Encoder()
        let chat = try store.createConversation(projectID: "worker-quarantine", title: "Public publication gate race")
        let event = try store.append(conversationID: chat.id, role: .human, text: String(repeating: "a", count: 64), status: .complete,
            turnID: "quarantine-public", eventID: "quarantine-public-source")
        var blockedWorkID: String?
        let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration(), backgroundClock: clock, workerObserver: { stage, work in
            guard stage == .beforePublication, case .source(.chunkAttempt, _) = work.request.binding.descriptor else { return }
            blockedWorkID = work.request.id
            let request = try BackgroundIndexWorkRequest.metadata(id: UUID().uuidString,
                projectID: work.request.binding.projectID!, indexFingerprint: work.request.binding.indexFingerprint!,
                adapterIdentity: work.request.binding.adapterIdentity,
                descriptor: .init(target: .captureSourceFrontier, afterSequence: 0, throughSequence: nil, limit: 1, sourceReferencesSHA256: nil))
            let fault = try store.reserveBackgroundWork(request: request, clockSource: clock)
            _ = try store.armBackgroundWork(workID: fault.request.id, bindingDigest: fault.bindingDigest, clockSource: clock)
            _ = try store.settleBackgroundWork(workID: fault.request.id, settlement: .init(receiptID: UUID().uuidString,
                outcome: .failedConfirmed, adapterViolation: true), clockSource: clock)
        })
        let receipt = try index.process(projectID: chat.projectID, maximumChunks: 1)
        let state = try job(index, eventID: event.id), blocked = try store.backgroundWork(workID: blockedWorkID!)
        let access = store.backgroundReaderDiagnostics(), budget = try index.backgroundBudgetSnapshot()
        let second = try index.process(projectID: chat.projectID, maximumChunks: 1)
        let publishedRanges = try ranges(index, eventID: event.id)
        return [
            "background_worker_quarantine_before_atomic_gate_blocks_commit": receipt.publishedChunks == 0 && publishedRanges.isEmpty && encoder.calls == 1,
            "background_worker_quarantine_preserves_pending_cursor_attempts": state?.state == "pending" && state?.offset == 0 && state?.attempts == 0 && receipt.failedChunks == 0,
            "background_worker_quarantine_retains_original_charged_unknown": blocked?.state == .outcomeUnknown && blocked?.charged.encoderCalls == 1 && budget.window?.charged.encoderCalls == 1,
            "background_worker_quarantine_stops_repeat_before_source_encoder": second.publishedChunks == 0 && second.failedChunks == 0 && second.budgetPauseReason == BackgroundIndexBudgetError.adapterViolation.failureCode && store.backgroundReaderDiagnostics() == access && encoder.calls == 1,
        ]
    }

    private static func configuration() -> SemanticIndexConfiguration {
        var value = SemanticIndexConfiguration(); value.chunkBytes = 64; value.maximumNewSourcesPerRun = 1; value.maximumChunksPerRun = 64
        return value
    }
    private static func temporary(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("boros-background-worker-" + suffix + "-" + UUID().uuidString)
    }
    private final class Clock: BackgroundIndexClockSource {
        private let mutex = NSLock()
        private var ticks: UInt64 = 1_000_000
        func now() throws -> BackgroundIndexClockSnapshot {
            mutex.lock(); defer { mutex.unlock() }
            ticks += 1
            return .init(domain: "public-worker-clock", continuousNanoseconds: ticks, utcMilliseconds: 1_000_000)
        }
        func advanceDay() { mutex.lock(); ticks += BackgroundIndexLimits.durationNanoseconds; mutex.unlock() }
    }
    private final class Encoder: SemanticEmbeddingAdapter {
        let metadata = ["provider": "public-worker-fixture", "revision": "1", "dimension": "3"]
        let dimension = 3
        var calls = 0
        var beforeEncode: (() throws -> Void)?
        func encode(_ text: String) throws -> SemanticEncoding { calls += 1; try beforeEncode?(); return .vector([1, 0, 0]) }
    }
    private struct JobState { let state: String; let offset: Int; let attempts: Int; let ready: Int }
    private struct Range { let offset: Int; let count: Int; let digest: String; let publication: Int }
    private static func job(_ index: SemanticIndex, eventID: String) throws -> JobState? {
        try query(index.directory.appendingPathComponent("index.sqlite3"), sql: "SELECT state,next_offset,failure_attempts,ready_publication FROM jobs WHERE index_id=? AND event_id=?", arguments: [index.indexFingerprint, eventID]) { statement in
            JobState(state: String(cString: sqlite3_column_text(statement, 0)), offset: Int(sqlite3_column_int64(statement, 1)), attempts: Int(sqlite3_column_int64(statement, 2)), ready: Int(sqlite3_column_int64(statement, 3)))
        }.first
    }
    private static func ranges(_ index: SemanticIndex, eventID: String) throws -> [Range] {
        try query(index.directory.appendingPathComponent("index.sqlite3"), sql: "SELECT offset,byte_count,text_digest,publication FROM chunks WHERE index_id=? AND event_id=? ORDER BY offset", arguments: [index.indexFingerprint, eventID]) {
            Range(offset: Int(sqlite3_column_int64($0, 0)), count: Int(sqlite3_column_int64($0, 1)), digest: String(cString: sqlite3_column_text($0, 2)), publication: Int(sqlite3_column_int64($0, 3)))
        }
    }
    private static func query<T>(_ path: URL, sql: String, arguments: [String], map: (OpaquePointer) throws -> T) throws -> [T] {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SemanticError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in arguments.enumerated() { sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) }
        var result: [T] = [], step = sqlite3_step(statement)
        while step == SQLITE_ROW { result.append(try map(statement)); step = sqlite3_step(statement) }
        guard step == SQLITE_DONE else { throw SemanticError.database }
        return result
    }
    private static func corrupt(_ store: MemoryStore, eventID: String, payload: Data) throws {
        var db: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(store.directory.appendingPathComponent("memory.sqlite3").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SemanticError.database }
        defer { sqlite3_close(db) }
        guard sqlite3_prepare_v2(db, "UPDATE events SET payload=? WHERE id=?", -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_text(statement, 2, eventID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) == 1 else { throw SemanticError.database }
    }
}
