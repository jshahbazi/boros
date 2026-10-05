import Foundation
import Darwin
import CSQLite

/// Public synthetic fixtures exercise actual owner transactions and private
/// bounded readers. No accepted user content or source bytes are printed.
enum BackgroundIndexLedgerChecks {
    final class Clock: BackgroundIndexClockSource, @unchecked Sendable {
        var domain = "synthetic-background-clock"
        var ticks: UInt64 = 1_000_000_000
        var utc: Int64 = 1_700_000_000_000
        func now() throws -> BackgroundIndexClockSnapshot {
            BackgroundIndexClockSnapshot(domain: domain, continuousNanoseconds: ticks, utcMilliseconds: utc)
        }
    }
    private final class Counts: @unchecked Sendable {
        let lock = NSLock(); var accepted = 0; var denied = 0
        func add(_ value: Bool) { lock.lock(); defer { lock.unlock() }; if value { accepted += 1 } else { denied += 1 } }
    }
    private final class GateClock: BackgroundIndexClockSource, @unchecked Sendable {
        let base: Clock
        let entered = DispatchSemaphore(value: 0)
        init(_ base: Clock) { self.base = base }
        func now() throws -> BackgroundIndexClockSnapshot { entered.signal(); return try base.now() }
    }
    private final class PublicationSQL: @unchecked Sendable {
        let database: OpaquePointer
        init(path: String) throws {
            var pointer: OpaquePointer?
            guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else { throw BackgroundIndexBudgetError.invalid }
            database = pointer; sqlite3_busy_timeout(database, 5000)
        }
        deinit { sqlite3_close(database) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }
        }
        func rows() throws -> Int {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT count(*) FROM public_publications", -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw BackgroundIndexBudgetError.invalid }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw BackgroundIndexBudgetError.invalid }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
    private static func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func rejected(_ expected: BackgroundIndexBudgetError, _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch let error as BackgroundIndexBudgetError { return error == expected } catch { return false }
    }
    private static let fingerprint = String(repeating: "a", count: 64)
    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("boros-background-ledger-check-" + UUID().uuidString)
    }
    private static func source(_ store: MemoryStore, text: String = String(repeating: "public synthetic sentence. ", count: 20), event: String = "public-source", project: String = "public-project") throws -> MemorySourceReference {
        let chat = try store.createConversation(projectID: project, title: "Public synthetic background ledger")
        _ = try store.append(conversationID: chat.id, role: .human, text: text, status: .complete, turnID: "public-turn", eventID: event)
        guard let source = try store.sourceReference(eventID: event, projectID: project) else { throw BackgroundIndexBudgetError.invalid }
        return source
    }
    private static func budgetSource(_ source: MemorySourceReference) -> BackgroundIndexSourceReference {
        BackgroundIndexSourceReference(sequence: source.sequence, eventID: source.eventID, conversationID: source.conversationID,
            projectID: source.projectID, role: source.role.rawValue, status: source.status.rawValue, createdAt: source.createdAt,
            digest: source.digest, byteCount: source.byteCount)
    }
    private static func metadata(_ id: String, rows: Int = 1, project: String = "public-project", fingerprint: String = fingerprint) throws -> BackgroundIndexWorkRequest {
        try .metadata(id: id, projectID: project, indexFingerprint: fingerprint, adapterIdentity: "public-encoder",
            descriptor: BackgroundIndexMetadataDescriptor(target: .sourceManifest, afterSequence: 0, throughSequence: 10000, limit: rows, sourceReferencesSHA256: nil))
    }
    private static func copy(_ request: BackgroundIndexWorkRequest, id: String) -> BackgroundIndexWorkRequest {
        BackgroundIndexWorkRequest(id: id, binding: request.binding, resources: request.resources, encoderInput: request.encoderInput, snapshot: request.snapshot)
    }
    private static func caps(_ values: BackgroundIndexResources, resource: BackgroundIndexResource, amount: Int) -> BackgroundIndexLimits {
        .init(resources: BackgroundIndexResources(rawSourceBytes: resource == .rawSourceBytes ? amount : values.rawSourceBytes,
            encoderCalls: resource == .encoderCalls ? amount : values.encoderCalls,
            encoderInputBytes: resource == .encoderInputBytes ? amount : values.encoderInputBytes,
            vectorBytes: resource == .vectorBytes ? amount : values.vectorBytes,
            metadataRows: resource == .metadataRows ? amount : values.metadataRows,
            sourceJobs: resource == .sourceJobs ? amount : values.sourceJobs))
    }
    private static func inventory(_ store: MemoryStore) throws -> BackgroundIndexInventory {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(store.directory.appendingPathComponent("memory.sqlite3").path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = pointer else { throw BackgroundIndexBudgetError.invalid }
        defer { sqlite3_close(database) }
        return try BackgroundIndexJournal.inventory(database: database)
    }
    static func run() throws -> [String: Bool] {
        var checks = [String: Bool]()
        for resource in BackgroundIndexResource.allCases {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock()
            let reference = try source(store), exact = budgetSource(reference)
            let request: BackgroundIndexWorkRequest
            switch resource {
            case .encoderCalls: request = try .publicEncoderProbe(id: "cap-work", adapterIdentity: "public-encoder")
            case .metadataRows: request = try metadata("cap-work", rows: 3)
            case .sourceJobs:
                let payload = try BackgroundIndexCanonical.data([exact])
                request = try .metadata(id: "cap-work", projectID: reference.projectID, indexFingerprint: fingerprint,
                    adapterIdentity: "public-encoder", descriptor: .init(target: .scheduleSources, afterSequence: 0,
                        throughSequence: reference.sequence, limit: 1, sourceReferencesSHA256: BackgroundIndexCanonical.sha256(payload)), sourceReferences: [exact])
            default: request = try .chunkAttempt(id: "cap-work", source: exact, offset: 0, chunkBytes: 64, dimension: 2,
                indexFingerprint: fingerprint, adapterIdentity: "public-encoder")
            }
            let tooLow = caps(.developmentCaps, resource: resource, amount: request.resources[resource] - 1)
            checks["background_" + resource.rawValue + "_preflight_cap_minus_one"] = rejected(.exhausted) {
                _ = try store.reserveBackgroundWork(request: request, clockSource: clock, limits: tooLow)
            }
            checks["background_" + resource.rawValue + "_denial_no_window_or_payload"] = try store.backgroundBudgetSnapshot(clockSource: clock).window == nil
                && store.backgroundReaderDiagnostics() == BackgroundReaderDiagnostics(payloadPages: 0, materializedBytes: 0)
            let limits = caps(.developmentCaps, resource: resource, amount: request.resources[resource])
            let held = try store.reserveBackgroundWork(request: request, clockSource: clock, limits: limits)
            checks["background_" + resource.rawValue + "_exact_cap_reserved"] = try held.held == request.resources
                && store.backgroundBudgetSnapshot(clockSource: clock).window?.held == request.resources
            let armed = try store.armBackgroundWork(workID: request.id, bindingDigest: held.bindingDigest, clockSource: clock)
            _ = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "cap-receipt", outcome: .failedConfirmed), clockSource: clock)
            checks["background_" + resource.rawValue + "_armed_failure_keeps_charge"] = try armed.charged == request.resources
                && store.backgroundBudgetSnapshot(clockSource: clock).window?.charged == request.resources
            checks["background_" + resource.rawValue + "_second_work_exhausted"] = rejected(.exhausted) {
                _ = try store.reserveBackgroundWork(request: copy(request, id: "next-cap-work"), clockSource: clock, limits: limits)
            }
            checks["background_" + resource.rawValue + "_archive_inventory_recomputed"] = try inventory(store).charged == request.resources && inventory(store).held == .zero
        }
        do {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock()
            let request = try metadata("replay")
            let first = try store.reserveBackgroundWork(request: request, clockSource: clock)
            checks["background_replay_exact_request"] = try first == store.reserveBackgroundWork(request: request, clockSource: clock)
            checks["background_changed_binding_conflict"] = rejected(.conflict) { _ = try store.reserveBackgroundWork(request: metadata("replay", project: "different-project"), clockSource: clock) }
            checks["background_changed_limits_conflict"] = rejected(.conflict) {
                _ = try store.reserveBackgroundWork(request: metadata("other"), clockSource: clock,
                    limits: caps(.developmentCaps, resource: .metadataRows, amount: 10))
            }
            _ = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "cancel-receipt", outcome: .cancelledBeforeDispatch), clockSource: clock)
            checks["background_prepared_cancel_releases_only_hold"] = try inventory(store).held == .zero && inventory(store).charged == .zero
            checks["background_terminal_exact_replay"] = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "cancel-receipt", outcome: .cancelledBeforeDispatch), clockSource: clock).state == .cancelledBeforeDispatch
            checks["background_terminal_changed_receipt_conflict"] = rejected(.conflict) {
                _ = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "changed", outcome: .cancelledBeforeDispatch), clockSource: clock)
            }
            let a = try store.reserveBackgroundWork(request: metadata("shared-a", project: "project-a"), clockSource: clock)
            let b = try store.reserveBackgroundWork(request: metadata("shared-b", project: "project-b", fingerprint: String(repeating: "b", count: 64)), clockSource: clock)
            checks["background_projects_fingerprints_share_window"] = a.windowID == b.windowID
            let utfA = try store.reserveBackgroundWork(request: metadata("caf\u{e9}"), clockSource: clock)
            let utfB = try store.reserveBackgroundWork(request: metadata("cafe\u{301}"), clockSource: clock)
            checks["background_work_ids_exact_utf8"] = try utfA.request.id.utf8.elementsEqual(utfB.request.id.utf8) == false && inventory(store).works == 5
            let duplicateReceipt = try store.armBackgroundWork(workID: a.request.id, bindingDigest: a.bindingDigest, clockSource: clock)
            checks["background_receipt_globally_unique"] = rejected {
                _ = try store.settleBackgroundWork(workID: duplicateReceipt.request.id, settlement: .init(receiptID: "cancel-receipt", outcome: .failedConfirmed), clockSource: clock)
            }
            checks["background_receipt_conflict_atomic"] = try store.backgroundWork(workID: a.request.id)?.state == .armed
        }
        do {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock(), counts = Counts()
            let limits = caps(.developmentCaps, resource: .metadataRows, amount: 3)
            DispatchQueue.concurrentPerform(iterations: 12) { i in
                do { _ = try store.reserveBackgroundWork(request: metadata("race-" + String(i)), clockSource: clock, limits: limits); counts.add(true) }
                catch { counts.add(false) }
            }
            checks["background_concurrent_admission_one_global_cap"] = counts.accepted == 3 && counts.denied == 9
            checks["background_concurrent_totals_exact"] = try inventory(store).held.metadataRows == 3 && inventory(store).works == 3
        }
        checks.merge(try clockChecks()) { _, value in value }
        checks.merge(try readerChecks()) { _, value in value }
        checks.merge(try recoveryChecks()) { _, value in value }
        checks.merge(try corruptionChecks()) { _, value in value }
        checks.merge(try publicationChecks()) { _, value in value }
        checks.merge(try liveAnchorCorruptionChecks()) { _, value in value }
        return checks
    }
    private static func clockChecks() throws -> [String: Bool] {
        var checks = [String: Bool]()
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MemoryStore(directory: location), clock = Clock()
        let first = try store.reserveBackgroundWork(request: metadata("old-prepared"), clockSource: clock)
        let armed = try store.armBackgroundWork(workID: first.request.id, bindingDigest: first.bindingDigest, clockSource: clock)
        let stillPrepared = try store.reserveBackgroundWork(request: metadata("old-held"), clockSource: clock)
        clock.utc += 20 * BackgroundIndexLimits.durationMilliseconds
        clock.ticks += 1
        checks["background_wall_forward_cannot_renew_same_boot"] = try !store.backgroundBudgetSnapshot(clockSource: clock).rolloverEligible
        clock.utc = 1_600_000_000_000
        clock.ticks += BackgroundIndexLimits.durationNanoseconds
        checks["background_original_boot_continuous_day_rolls_despite_utc_regression"] = try store.backgroundBudgetSnapshot(clockSource: clock).rolloverEligible
        let next = try store.reserveBackgroundWork(request: metadata("new-window"), clockSource: clock)
        checks["background_rotation_creates_new_window_and_releases_old_prepared"] = try next.windowID != first.windowID
            && store.backgroundWork(workID: stillPrepared.request.id)?.state == .cancelledBeforeDispatch
        checks["background_rotation_retains_old_armed_charge"] = try inventory(store).windows == 2 && inventory(store).charged.metadataRows == 1 && inventory(store).held.metadataRows == 1
        _ = try store.checkBackgroundPublication(workID: armed.request.id, bindingDigest: armed.bindingDigest, clockSource: clock)
        _ = try store.settleBackgroundWork(workID: armed.request.id, settlement: .init(receiptID: "old-finished", outcome: .completed), clockSource: clock)
        checks["background_closed_window_armed_work_can_finish_original_charge"] = try store.backgroundWork(workID: armed.request.id)?.state == .completed && inventory(store).charged.metadataRows == 1
        checks["background_new_window_preserves_utc_high_water_baseline"] = try store.backgroundBudgetSnapshot(clockSource: clock).window!.utcRolloverBaselineMilliseconds > clock.utc
        clock.domain = "synthetic-new-boot"; clock.ticks = 100
        checks["background_reboot_utc_regression_explicit_pause"] = try store.backgroundBudgetSnapshot(clockSource: clock).pauseReason == .clockUnavailable
        checks["background_reboot_clock_failure_does_not_admit_new_work"] = rejected(.clockUnavailable) { _ = try store.reserveBackgroundWork(request: metadata("bad-clock"), clockSource: clock) }
        clock.utc = 1_900_000_000_000; clock.ticks += 1
        checks["background_later_reboot_wall_jump_cannot_shortcut_anchor"] = try !store.backgroundBudgetSnapshot(clockSource: clock).rolloverEligible
        clock.ticks += BackgroundIndexLimits.durationNanoseconds
        checks["background_reboot_both_utc_and_continuous_allow_rotation"] = try store.backgroundBudgetSnapshot(clockSource: clock).rolloverEligible
        _ = try store.reserveBackgroundWork(request: metadata("third-window"), clockSource: clock)
        checks["background_rotation_history_inventory_valid"] = try inventory(store).windows == 3 && inventory(store).works == 4
        let validLocation = directory(); defer { try? FileManager.default.removeItem(at: validLocation) }
        let validStore = try MemoryStore(directory: validLocation), validClock = Clock()
        _ = try validStore.reserveBackgroundWork(request: metadata("before-valid-reboot"), clockSource: validClock)
        validClock.domain = "synthetic-valid-reboot"; validClock.ticks = 100
        validClock.utc += 3_600_000
        let validPrepared = try validStore.reserveBackgroundWork(request: metadata("after-valid-reboot"), clockSource: validClock)
        validClock.ticks += 1
        checks["background_valid_reboot_under_day_can_arm_remaining_allowance"] = !rejected {
            _ = try validStore.armBackgroundWork(workID: validPrepared.request.id, bindingDigest: validPrepared.bindingDigest, clockSource: validClock)
        }
        return checks
    }
    private static func readerChecks() throws -> [String: Bool] {
        var checks = [String: Bool]()
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let store = try MemoryStore(directory: location), clock = Clock()
        let reference = try source(store, text: String(repeating: "café 中文. ", count: 80)), exact = budgetSource(reference)
        let request = try BackgroundIndexWorkRequest.initialSeal(id: "seal", source: exact, indexFingerprint: fingerprint, adapterIdentity: "public-encoder")
        let prepared = try store.reserveBackgroundWork(request: request, clockSource: clock)
        checks["background_reader_requires_armed_durable_work"] = rejected { _ = try store.makeBackgroundSourceReader(for: prepared, clockSource: clock) }
        let armed = try store.armBackgroundWork(workID: request.id, bindingDigest: prepared.bindingDigest, clockSource: clock)
        let evidence = BackgroundIndexWorkerEvidence(sourceReferenceSHA256: try exact.canonicalDigest(), offset: 0,
            byteCount: exact.byteCount, sourceSealedSHA256: exact.digest, sourceSealedByteCount: exact.byteCount)
        checks["background_fabricated_seal_evidence_cannot_complete"] = rejected(.inactive) {
            _ = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "fabricated", outcome: .completed, evidence: evidence.canonicalData()), clockSource: clock)
        }
        let reader = try store.makeBackgroundSourceReader(for: armed, clockSource: clock)
        checks["background_reader_single_claim"] = rejected { _ = try store.makeBackgroundSourceReader(for: armed, clockSource: clock) }
        try reader.validateCompleteSource(source: reference)
        checks["background_seal_reads_bounded_source_pages"] = store.backgroundReaderDiagnostics().payloadPages > 0
            && store.backgroundReaderDiagnostics().materializedBytes <= exact.byteCount + 4 * (exact.byteCount / 4093 + 1)
        checks["background_seal_cannot_repeat_without_new_charge"] = rejected { try reader.validateCompleteSource(source: reference) }
        _ = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "real-seal", outcome: .completed, evidence: evidence.canonicalData()), clockSource: clock)
        let chunkRequest = try BackgroundIndexWorkRequest.chunkAttempt(id: "chunk", source: exact, offset: 0, chunkBytes: 64, dimension: 3, indexFingerprint: fingerprint, adapterIdentity: "public-encoder")
        let chunk = try store.reserveBackgroundWork(request: chunkRequest, clockSource: clock)
        let chunkArmed = try store.armBackgroundWork(workID: chunkRequest.id, bindingDigest: chunk.bindingDigest, clockSource: clock)
        let chunkReader = try store.makeBackgroundSourceReader(for: chunkArmed, clockSource: clock)
        let before = store.backgroundReaderDiagnostics(), page = try chunkReader.readChunk(source: reference), after = store.backgroundReaderDiagnostics()
        checks["background_chunk_projection_bounded_L_plus_one"] = after.payloadPages == before.payloadPages + 1 && after.materializedBytes - before.materializedBytes <= 65 && page.byteCount <= 64
        checks["background_nonfinal_chunk_cannot_claim_final_seal"] = rejected { try chunkReader.validateCompleteSource(source: reference) }
        checks["background_chunk_read_cannot_repeat"] = rejected { _ = try chunkReader.readChunk(source: reference) }
        _ = try store.checkBackgroundPublication(workID: chunkRequest.id, bindingDigest: chunk.bindingDigest, clockSource: clock)
        let chunkEvidence = BackgroundIndexWorkerEvidence(sourceReferenceSHA256: try exact.canonicalDigest(), offset: 0,
            byteCount: page.byteCount, textSHA256: BackgroundIndexCanonical.sha256(Data(page.text.utf8)), vectorByteCount: 12, publicationSequence: 1)
        _ = try store.settleBackgroundWork(workID: chunkRequest.id, settlement: .init(receiptID: "chunk-receipt", outcome: .completed, evidence: chunkEvidence.canonicalData()), clockSource: clock)
        checks["background_chunk_completed_evidence_and_charges_survive_inventory"] = try inventory(store).charged == request.resources.adding(chunkRequest.resources)
        let finalRequest = try BackgroundIndexWorkRequest.chunkAttempt(id: "final", source: exact, offset: exact.byteCount - 32, chunkBytes: 64, dimension: 3, indexFingerprint: fingerprint, adapterIdentity: "public-encoder")
        let final = try store.reserveBackgroundWork(request: finalRequest, clockSource: clock)
        let finalArmed = try store.armBackgroundWork(workID: finalRequest.id, bindingDigest: final.bindingDigest, clockSource: clock)
        checks["background_final_requires_own_fresh_seal_before_publication"] = rejected(.inactive) { _ = try store.checkBackgroundPublication(workID: finalRequest.id, bindingDigest: finalArmed.bindingDigest, clockSource: clock) }
        _ = try store.settleBackgroundWork(workID: finalRequest.id, settlement: .init(receiptID: "aborted-final", outcome: .outcomeUnknown), clockSource: clock)
        checks["background_unknown_final_keeps_maximum_charge"] = try inventory(store).charged == request.resources.adding(chunkRequest.resources).adding(finalRequest.resources)
        checks["background_settled_reader_access_fenced"] = rejected { try chunkReader.verify(source: reference) }
        return checks
    }
    private static func recoveryChecks() throws -> [String: Bool] {
        var checks = [String: Bool]()
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let clock = Clock()
        var store: MemoryStore? = try MemoryStore(directory: location)
        let prepared = try store!.reserveBackgroundWork(request: metadata("recover-prepared", rows: 2), clockSource: clock)
        let held = try store!.reserveBackgroundWork(request: .publicEncoderProbe(id: "recover-armed", adapterIdentity: "public-encoder"), clockSource: clock)
        let armed = try store!.armBackgroundWork(workID: held.request.id, bindingDigest: held.bindingDigest, clockSource: clock)
        let submittedHeld = try store!.reserveBackgroundWork(request: metadata("recover-submitted"), clockSource: clock)
        let submitted = try store!.armBackgroundWork(workID: submittedHeld.request.id, bindingDigest: submittedHeld.bindingDigest, clockSource: clock)
        _ = try store!.checkBackgroundPublication(workID: submitted.request.id, bindingDigest: submitted.bindingDigest, clockSource: clock)
        let prior = try inventory(store!); store = nil
        store = try MemoryStore(directory: location)
        let recovered = try inventory(store!)
        checks["background_reopen_prepared_releases_only_unused"] = try store!.backgroundWork(workID: prepared.request.id)?.state == .cancelledBeforeDispatch
            && recovered.held == .zero && recovered.charged == prior.charged
        checks["background_reopen_armed_unknown_retains_encoder_unknown"] = try store!.backgroundWork(workID: armed.request.id)?.state == .outcomeUnknown
            && recovered.unknownEncoderCalls == 2 && recovered.uncertain == 2
        checks["background_reopen_submitted_unknown_no_automatic_replay"] = try store!.backgroundWork(workID: submitted.request.id)?.state == .outcomeUnknown
            && store!.backgroundReaderDiagnostics().payloadPages == 0
        checks["background_recovered_work_cannot_rearm"] = rejected(.inactive) { _ = try store!.armBackgroundWork(workID: armed.request.id, bindingDigest: armed.bindingDigest, clockSource: clock) }
        store = nil; store = try MemoryStore(directory: location)
        checks["background_repeated_reopen_inventory_stable"] = try inventory(store!) == recovered
        let resumed = try store!.reserveBackgroundWork(request: metadata("explicit-new-attempt"), clockSource: clock)
        checks["background_explicit_resume_same_window_new_work"] = resumed.windowID == armed.windowID && resumed.request.id != armed.request.id
        let pending = try store!.reserveBackgroundWork(request: metadata("prepared-before-violation"), clockSource: clock)
        let beforeFault = try store!.reserveBackgroundWork(request: metadata("armed-before-violation"), clockSource: clock)
        let live = try store!.armBackgroundWork(workID: beforeFault.request.id, bindingDigest: beforeFault.bindingDigest, clockSource: clock)
        let fault = try store!.reserveBackgroundWork(request: metadata("established-violation"), clockSource: clock)
        _ = try store!.armBackgroundWork(workID: fault.request.id, bindingDigest: fault.bindingDigest, clockSource: clock)
        _ = try store!.settleBackgroundWork(workID: fault.request.id, settlement: .init(receiptID: "violation-receipt", outcome: .failedConfirmed, adapterViolation: true), clockSource: clock)
        checks["background_adapter_violation_blocks_new_reservation"] = rejected(.adapterViolation) { _ = try store!.reserveBackgroundWork(request: metadata("after-fault"), clockSource: clock) }
        checks["background_adapter_violation_blocks_prepared_arm"] = rejected(.adapterViolation) { _ = try store!.armBackgroundWork(workID: pending.request.id, bindingDigest: pending.bindingDigest, clockSource: clock) }
        checks["background_adapter_violation_blocks_already_armed_publication"] = rejected(.adapterViolation) { _ = try store!.checkBackgroundPublication(workID: live.request.id, bindingDigest: live.bindingDigest, clockSource: clock) }
        return checks
    }

    private static func corruptionChecks() throws -> [String: Bool] {
        var checks = [String: Bool]()
        let original = directory(); defer { try? FileManager.default.removeItem(at: original) }
        do {
            let store = try MemoryStore(directory: original), clock = Clock(), reference = try source(store), exact = budgetSource(reference)
            let payload = try BackgroundIndexCanonical.data([exact])
            let request = try BackgroundIndexWorkRequest.metadata(id: "corruption-seed", projectID: exact.projectID,
                indexFingerprint: fingerprint, adapterIdentity: "public-encoder", descriptor: .init(target: .scheduleSources,
                    afterSequence: 0, throughSequence: exact.sequence, limit: 1, sourceReferencesSHA256: BackgroundIndexCanonical.sha256(payload)), sourceReferences: [exact])
            _ = try store.reserveBackgroundWork(request: request, clockSource: clock, limits: caps(.developmentCaps, resource: .metadataRows, amount: 10))
            _ = try store.settleBackgroundWork(workID: request.id, settlement: .init(receiptID: "corruption-cancel", outcome: .cancelledBeforeDispatch), clockSource: clock)
        }
        func edit(_ database: OpaquePointer, sql: String, payload: Data? = nil) throws {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw BackgroundIndexBudgetError.invalid }
            defer { sqlite3_finalize(statement) }
            if let payload {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let digest = BackgroundIndexCanonical.sha256(payload)
                guard payload.withUnsafeBytes({ sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(payload.count), transient) }) == SQLITE_OK,
                      digest.withCString({ sqlite3_bind_text(statement, 2, $0, Int32(digest.utf8.count), transient) }) == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw BackgroundIndexBudgetError.invalid }
        }
        func object(_ database: OpaquePointer, table: String, column: String) throws -> [String: Any] {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT " + column + " FROM " + table + " LIMIT 1", -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw BackgroundIndexBudgetError.invalid }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0),
                  let object = try JSONSerialization.jsonObject(with: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) as? [String: Any] else { throw BackgroundIndexBudgetError.invalid }
            return object
        }
        for mutation in ["missing_inventory", "window_limits", "window_start", "original_anchor", "window_totals", "work_digest", "work_scope", "scheduled_source"] {
            let target = directory(); defer { try? FileManager.default.removeItem(at: target) }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let path = target.appendingPathComponent("memory.sqlite3")
            try FileManager.default.copyItem(at: original.appendingPathComponent("memory.sqlite3"), to: path)
            var pointer: OpaquePointer?
            guard sqlite3_open_v2(path.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = pointer else { throw BackgroundIndexBudgetError.invalid }
            do {
                if mutation == "missing_inventory" { try edit(database, sql: "DROP TABLE background_index_work") }
                else if mutation.hasPrefix("window_") || mutation == "original_anchor" {
                    var value = try object(database, table: "background_index_windows", column: "window_json")
                    if mutation == "window_limits" {
                        var limits = value["limits"] as! [String: Any], resources = limits["resources"] as! [String: Any]
                        resources["metadataRows"] = 11; limits["resources"] = resources; value["limits"] = limits
                    } else if mutation == "window_start" {
                        var start = value["startedClock"] as! [String: Any]
                        start["utcMilliseconds"] = 1_699_999_999_999 as Int64; value["startedClock"] = start
                    } else if mutation == "original_anchor" {
                        var anchor = value["anchor"] as! [String: Any]
                        anchor["establishedAgeNanoseconds"] = 1; value["anchor"] = anchor
                    } else {
                        var charged = value["charged"] as! [String: Any]; charged["metadataRows"] = 1; value["charged"] = charged
                    }
                    try edit(database, sql: "UPDATE background_index_windows SET window_json=?,window_digest=?", payload: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
                } else {
                    var value = try object(database, table: "background_index_work", column: "record_json")
                    if mutation == "work_digest" { value["requestDigest"] = String(repeating: "f", count: 64) }
                    else if mutation == "work_scope" { value["windowID"] = "different-window" }
                    else {
                        let old = try JSONDecoder().decode(BackgroundIndexWorkRecord.self, from: JSONSerialization.data(withJSONObject: value))
                        guard case .metadataFrontier(let descriptor) = old.request.binding.descriptor,
                              let snapshot = old.request.snapshot else { throw BackgroundIndexBudgetError.invalid }
                        let sources = try JSONDecoder().decode([BackgroundIndexSourceReference].self, from: snapshot.payload)
                        let source = sources[0]
                        let changed = BackgroundIndexSourceReference(sequence: source.sequence, eventID: source.eventID,
                            conversationID: source.conversationID, projectID: source.projectID, role: "assistant", status: source.status,
                            createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount)
                        let payload = try BackgroundIndexCanonical.data([changed])
                        let request = try BackgroundIndexWorkRequest.metadata(id: old.request.id, projectID: source.projectID,
                            indexFingerprint: old.request.binding.indexFingerprint!, adapterIdentity: old.request.binding.adapterIdentity,
                            descriptor: .init(target: .scheduleSources, afterSequence: descriptor.afterSequence,
                                throughSequence: descriptor.throughSequence, limit: descriptor.limit,
                                sourceReferencesSHA256: BackgroundIndexCanonical.sha256(payload)), sourceReferences: [changed])
                        let changedRecord = BackgroundIndexWorkRecord(windowID: old.windowID, request: request, requestDigest: try request.digest(),
                            bindingDigest: try request.binding.digest(), state: old.state, revision: old.revision,
                            charged: old.charged, held: old.held, createdClock: old.createdClock, armedClock: old.armedClock,
                            settlement: old.settlement, recovered: old.recovered)
                        try changedRecord.validate()
                        value = try JSONSerialization.jsonObject(with: BackgroundIndexCanonical.data(changedRecord)) as! [String: Any]
                        // Both interpolated values are validated lowercase SHA-256,
                        // never source content or credentials.
                        try edit(database, sql: "UPDATE background_index_work SET binding_digest='" + changedRecord.bindingDigest + "',request_digest='" + changedRecord.requestDigest + "'")
                    }
                    try edit(database, sql: "UPDATE background_index_work SET record_json=?,record_digest=?", payload: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
                }
                sqlite3_close(database)
            } catch { sqlite3_close(database); throw error }
            checks["background_refreshed_digest_" + mutation + "_rejected_before_repair"] = rejected { _ = try MemoryStore(directory: target) }
        }
        return checks
    }

    private static func publicationChecks() throws -> [String: Bool] {
        var checks = [String: Bool]()
        do {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock()
            let prepared = try store.reserveBackgroundWork(request: metadata("terminal-before-publication"), clockSource: clock)
            let work = try store.armBackgroundWork(workID: prepared.request.id, bindingDigest: prepared.bindingDigest, clockSource: clock)
            _ = try store.settleBackgroundWork(workID: work.request.id, settlement: .init(receiptID: "terminal-receipt", outcome: .outcomeUnknown), clockSource: clock)
            var publications = 0
            checks["background_prior_terminalization_prevents_publication_callback"] = rejected(.inactive) {
                _ = try store.withBackgroundPublication(workID: work.request.id, bindingDigest: work.bindingDigest, clockSource: clock) { publications += 1 }
            } && publications == 0
        }
        do {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock()
            let prepared = try store.reserveBackgroundWork(request: metadata("quarantine-before-publication"), clockSource: clock)
            let work = try store.armBackgroundWork(workID: prepared.request.id, bindingDigest: prepared.bindingDigest, clockSource: clock)
            let faultPrepared = try store.reserveBackgroundWork(request: metadata("publication-fault"), clockSource: clock)
            let fault = try store.armBackgroundWork(workID: faultPrepared.request.id, bindingDigest: faultPrepared.bindingDigest, clockSource: clock)
            _ = try store.settleBackgroundWork(workID: fault.request.id, settlement: .init(receiptID: "publication-fault-receipt", outcome: .failedConfirmed, adapterViolation: true), clockSource: clock)
            var publications = 0
            checks["background_prior_quarantine_prevents_publication_callback"] = rejected(.adapterViolation) {
                _ = try store.withBackgroundPublication(workID: work.request.id, bindingDigest: work.bindingDigest, clockSource: clock) { publications += 1 }
            } && publications == 0
        }
        for mutation in ["terminalization", "quarantine"] {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock(), gateClock = GateClock(clock)
            let prepared = try store.reserveBackgroundWork(request: metadata("concurrent-publication"), clockSource: clock)
            let work = try store.armBackgroundWork(workID: prepared.request.id, bindingDigest: prepared.bindingDigest, clockSource: clock)
            let mutationWork: BackgroundIndexWorkRecord
            if mutation == "quarantine" {
                let faultPrepared = try store.reserveBackgroundWork(request: metadata("concurrent-adapter-fault"), clockSource: clock)
                mutationWork = try store.armBackgroundWork(workID: faultPrepared.request.id, bindingDigest: faultPrepared.bindingDigest, clockSource: clock)
            } else { mutationWork = work }
            let path = location.appendingPathComponent("public-sidecar.sqlite3").path
            let blocker = try PublicationSQL(path: path), publication = try PublicationSQL(path: path)
            try blocker.execute("CREATE TABLE public_publications(id INTEGER PRIMARY KEY)")
            // The test barrier is acquired outside the owner gate. The gated
            // callback contains only bounded sidecar SQL, never an observer wait.
            try blocker.execute("BEGIN IMMEDIATE")
            let group = DispatchGroup(), attempted = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0), results = Counts(), sidecarMutex = NSLock()
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                sidecarMutex.lock(); defer { sidecarMutex.unlock() }
                do {
                    try store.withBackgroundPublication(workID: work.request.id, bindingDigest: work.bindingDigest, clockSource: gateClock) {
                        try publication.execute("INSERT INTO public_publications VALUES(1)")
                    }
                    results.add(true)
                } catch { results.add(false) }
            }
            let entered = gateClock.entered.wait(timeout: .now() + 2) == .success
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave(); finished.signal() }
                attempted.signal()
                do {
                    _ = try store.settleBackgroundWork(workID: mutationWork.request.id,
                        settlement: .init(receiptID: "concurrent-mutation", outcome: mutation == "quarantine" ? .failedConfirmed : .outcomeUnknown,
                            adapterViolation: mutation == "quarantine"), clockSource: clock)
                    results.add(true)
                } catch { results.add(false) }
            }
            let startedMutation = attempted.wait(timeout: .now() + 2) == .success
            let mutationBlocked = finished.wait(timeout: .now() + 0.15) == .timedOut
            try blocker.execute("COMMIT")
            let completed = group.wait(timeout: .now() + 5) == .success
            checks["background_owner_gate_serializes_concurrent_" + mutation + "_through_sidecar_sql"] = entered && startedMutation && mutationBlocked && completed && results.accepted == 2 && results.denied == 0
            checks["background_gated_commit_then_" + mutation + "_has_one_charged_publication"] = try publication.rows() == 1
                && store.backgroundWork(workID: work.request.id)?.state == (mutation == "quarantine" ? .submitted : .outcomeUnknown)
                && inventory(store).charged.metadataRows == (mutation == "quarantine" ? 2 : 1)
            if mutation == "quarantine" {
                checks["background_concurrent_violation_after_commit_fences_later_publication"] = try rejected(.adapterViolation) {
                    try store.withBackgroundPublication(workID: work.request.id, bindingDigest: work.bindingDigest, clockSource: clock) {
                        try publication.execute("INSERT INTO public_publications VALUES(2)")
                    }
                } && (try publication.rows()) == 1
            }
        }
        return checks
    }

    private static func liveAnchorCorruptionChecks() throws -> [String: Bool] {
        var checks = [String: Bool]()
        for mutation in ["age", "ticks", "utcflag"] {
            let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
            let store = try MemoryStore(directory: location), clock = Clock()
            _ = try store.reserveBackgroundWork(request: metadata("live-anchor-original"), clockSource: clock)
            var pointer: OpaquePointer?
            guard sqlite3_open_v2(location.appendingPathComponent("memory.sqlite3").path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = pointer else { throw BackgroundIndexBudgetError.invalid }
            defer { sqlite3_close(database) }
            var readPointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT window_json FROM background_index_windows", -1, &readPointer, nil) == SQLITE_OK, let read = readPointer else { throw BackgroundIndexBudgetError.invalid }
            guard sqlite3_step(read) == SQLITE_ROW, let raw = sqlite3_column_blob(read, 0) else { sqlite3_finalize(read); throw BackgroundIndexBudgetError.invalid }
            let original = Data(bytes: raw, count: Int(sqlite3_column_bytes(read, 0)))
            sqlite3_finalize(read)
            var value = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var anchor = value["anchor"] as! [String: Any]
            switch mutation {
            case "age": anchor["establishedAgeNanoseconds"] = BackgroundIndexLimits.durationNanoseconds - 1
            case "ticks": anchor["continuousNanoseconds"] = clock.ticks - 1
            default: anchor["requiresUTCForRollover"] = true
            }
            value["anchor"] = anchor
            let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            let digest = BackgroundIndexCanonical.sha256(payload)
            var writePointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, "UPDATE background_index_windows SET window_json=?,window_digest=?", -1, &writePointer, nil) == SQLITE_OK, let write = writePointer else { throw BackgroundIndexBudgetError.invalid }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard payload.withUnsafeBytes({ sqlite3_bind_blob(write, 1, $0.baseAddress, Int32(payload.count), transient) }) == SQLITE_OK,
                  digest.withCString({ sqlite3_bind_text(write, 2, $0, Int32(digest.utf8.count), transient) }) == SQLITE_OK,
                  sqlite3_step(write) == SQLITE_DONE else { sqlite3_finalize(write); throw BackgroundIndexBudgetError.invalid }
            sqlite3_finalize(write)
            clock.ticks += 3
            checks["background_live_owner_refreshed_anchor_" + mutation + "_snapshot_refused"] = rejected { _ = try store.backgroundBudgetSnapshot(clockSource: clock) }
            checks["background_live_owner_refreshed_anchor_" + mutation + "_reservation_refused"] = rejected { _ = try store.reserveBackgroundWork(request: metadata("premature-new-window"), clockSource: clock) }
            checks["background_live_owner_refreshed_anchor_" + mutation + "_offline_matches_runtime"] = rejected { _ = try BackgroundIndexJournal.inventory(database: database) }
            var countPointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT (SELECT count(*) FROM background_index_windows),(SELECT count(*) FROM background_index_work)", -1, &countPointer, nil) == SQLITE_OK, let count = countPointer else { throw BackgroundIndexBudgetError.invalid }
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW else { throw BackgroundIndexBudgetError.invalid }
            checks["background_live_owner_refreshed_anchor_" + mutation + "_no_new_allowance_or_work"] = sqlite3_column_int64(count, 0) == 1 && sqlite3_column_int64(count, 1) == 1
        }
        return checks
    }

    /// Separate-process drivers call this and kill only after the public ready
    /// marker. The store remains strongly owned while waiting on stdin.
    static func produceProcessFixture(directory: URL) throws {
        let store = try MemoryStore(directory: directory), clock = Clock()
        _ = try store.reserveBackgroundWork(request: metadata("kill-prepared", rows: 2), clockSource: clock)
        let probe = try store.reserveBackgroundWork(request: .publicEncoderProbe(id: "kill-armed", adapterIdentity: "public-encoder"), clockSource: clock)
        _ = try store.armBackgroundWork(workID: probe.request.id, bindingDigest: probe.bindingDigest, clockSource: clock)
        let request = try store.reserveBackgroundWork(request: metadata("kill-submitted"), clockSource: clock)
        let armed = try store.armBackgroundWork(workID: request.request.id, bindingDigest: request.bindingDigest, clockSource: clock)
        _ = try store.checkBackgroundPublication(workID: armed.request.id, bindingDigest: armed.bindingDigest, clockSource: clock)
        _ = try inventory(store)
        print("background_process_fixture_ready"); fflush(stdout)
        _ = readLine()
        _ = store.directory
    }
    static func verifyProcessFixture(directory: URL) throws -> [String: Bool] {
        let store = try MemoryStore(directory: directory), result = try inventory(store)
        return [
            "background_sigkill_prepared_released": try store.backgroundWork(workID: "kill-prepared")?.state == .cancelledBeforeDispatch && result.held == .zero,
            "background_sigkill_armed_unknown": try store.backgroundWork(workID: "kill-armed")?.state == .outcomeUnknown,
            "background_sigkill_submitted_unknown": try store.backgroundWork(workID: "kill-submitted")?.state == .outcomeUnknown,
            "background_sigkill_charges_exact": result.charged == BackgroundIndexResources(encoderCalls: 2, encoderInputBytes: 65, metadataRows: 1),
            "background_sigkill_unknown_encoder_preserved": result.unknownEncoderCalls == 2,
            "background_sigkill_no_replay": result.windows == 1 && result.works == 3 && result.prepared == 0 && result.uncertain == 2 && store.backgroundReaderDiagnostics().payloadPages == 0
        ]
    }
}
