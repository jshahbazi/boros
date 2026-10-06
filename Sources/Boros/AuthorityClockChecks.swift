import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Private synthetic clocks and receipt bytes only. No source or policy value is
/// printed; failed setup returns a fixed stage key rather than an error message.
enum AuthorityClockChecks {
    static func run() throws -> [String: Bool] {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CheckError.invalid }
        let temporaryRoot = String(cString: resolved); free(resolved)
        let scratch = URL(fileURLWithPath: temporaryRoot, isDirectory: true).appendingPathComponent("boros-authority-clock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var checks: [String: Bool] = [:], stage = "initial_clock"
        do {
            let directory = scratch.appendingPathComponent("source")
            var owner: MemoryStore? = try MemoryStore(directory: directory)
            let database = directory.appendingPathComponent("memory.sqlite3")
            let initial = try owner!.authorityStateSnapshot()
            let startup = try entries(database)
            let first = try owner!.authorityStateSnapshot(now: 1)
            let firstEntries = try entries(database)
            let originalCheckpoint = try receipt(firstEntries.last!)
            checks["authority_clock_first_tick_has_v2_checkpoint"] = originalCheckpoint.version == "authority-receipt-v2"
                && originalCheckpoint.kind == "clockCheckpoint" && originalCheckpoint.origin == "scheduler"
                && originalCheckpoint.operation == nil && originalCheckpoint.requestSHA256 == nil && originalCheckpoint.expiredPolicyIDs.isEmpty
            checks["authority_clock_first_tick_changes_no_control_revision"] = first.revision == initial.revision
                && first.controlEpoch == initial.controlEpoch && first.journalSequence == initial.journalSequence + 1 && first.timeHighWater == 1
            stage = "long_clock_sequence"
            for tick in 2...9000 { _ = try owner!.authorityStateSnapshot(now: Int64(tick)) }
            let many = try owner!.authorityStateSnapshot()
            let manyEntries = try entries(database), updatedCheckpoint = try receipt(manyEntries.last!)
            checks["authority_clock_more_than_operation_limit_reads_do_not_exhaust_journal"] = many.timeHighWater == 9000
                && 9000 > AuthorityStateKernel.maximumOperations
                && many.journalSequence == first.journalSequence && manyEntries.count == firstEntries.count
                && manyEntries.count < AuthorityStateKernel.maximumOperations
            checks["authority_clock_checkpoint_keeps_original_sequence_id_and_anchor"] = updatedCheckpoint.journalSequence == originalCheckpoint.journalSequence
                && episodeIdentifierEqual(updatedCheckpoint.requestID, originalCheckpoint.requestID)
                && updatedCheckpoint.previousStateSHA256 == originalCheckpoint.previousStateSHA256
            checks["authority_clock_updates_only_final_checkpoint_receipt"] = Array(manyEntries.dropLast()) == startup
                && manyEntries.last!.receipt != firstEntries.last!.receipt
            checks["authority_clock_coalescing_preserves_control_revision_and_epoch"] = many.revision == initial.revision && many.controlEpoch == initial.controlEpoch
            let beforeRollback = try canonical(many)
            _ = try owner!.authorityStateSnapshot(now: 100)
            checks["authority_clock_backward_observation_keeps_exact_state"] = try canonical(owner!.authorityStateSnapshot()) == beforeRollback

            stage = "human_receipt_boundary"
            let humanRequest = AuthorityOperationRequest(requestID: "synthetic-clock-human-operation", expectedRevision: many.revision,
                operation: .taskNew, taskID: "synthetic-clock-task", projectID: "synthetic-clock-project")
            let context = AuthorityContext(ownerID: many.ownerID, origin: .humanHost)
            let humanReceipt = try owner!.applyAuthorityOperation(request: humanRequest, authority: context, now: 9001)
            let afterHumanEntries = try entries(database)
            let frozenCheckpoint = afterHumanEntries[afterHumanEntries.count - 2]
            let humanEntry = afterHumanEntries.last!
            _ = try owner!.authorityStateSnapshot(now: 9002)
            _ = try owner!.authorityStateSnapshot(now: 9003)
            let laterEntries = try entries(database)
            checks["authority_clock_human_operation_freezes_previous_checkpoint"] = laterEntries.contains(frozenCheckpoint)
                && laterEntries.contains(humanEntry) && laterEntries.count == afterHumanEntries.count + 1
            let retry = try owner!.applyAuthorityOperation(request: humanRequest, authority: context, now: 9004)
            checks["authority_clock_human_retry_returns_original_receipt_bytes"] = try canonical(retry) == canonical(humanReceipt)
                && entries(database).contains(humanEntry)
            checks["authority_clock_human_retry_advances_highwater_without_revising_control"] = try owner!.authorityStateSnapshot().timeHighWater == 9004
                && owner!.authorityStateSnapshot().revision == humanReceipt.revision && owner!.authorityStateSnapshot().controlEpoch == humanReceipt.controlEpoch

            stage = "temporal_transition_boundary"
            let policyState = try owner!.authorityStateSnapshot()
            let policyDefinition = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .global), rule: "synthetic-clock-expiry",
                value: "Synthetic temporary value", expiresAt: 10000)
            _ = try owner!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-clock-dated-policy",
                expectedRevision: policyState.revision, operation: .policySet, policyID: "synthetic-clock-expiring-policy", policy: policyDefinition),
                authority: context, now: 9005)
            _ = try owner!.authorityStateSnapshot(now: 9999)
            let beforeExpiry = try owner!.authorityStateSnapshot(), expiryEntries = try entries(database)
            let expiredRequest = AuthorityOperationRequest(requestID: "synthetic-clock-stale-cas", expectedRevision: beforeExpiry.revision,
                operation: .taskNew, taskID: "synthetic-clock-expired-cas-task", projectID: "synthetic-clock-project")
            checks["authority_clock_due_expiry_rejects_old_cas"] = rejects {
                _ = try owner!.applyAuthorityOperation(request: expiredRequest, authority: context, now: 10000)
            }
            let expired = try owner!.authorityStateSnapshot(), expiredEntries = try entries(database)
            let expiryReceipt = try receipt(expiredEntries.last!)
            checks["authority_clock_due_expiry_freezes_checkpoint_and_appends_temporal_receipt"] = Array(expiredEntries.dropLast()) == expiryEntries
                && expiryReceipt.version == "authority-receipt-v1" && expiryReceipt.kind == "time"
                && expiryReceipt.expiredPolicyIDs.contains("synthetic-clock-expiring-policy")
            checks["authority_clock_due_expiry_revises_epoch_and_policy"] = expired.revision == beforeExpiry.revision + 1
                && expired.controlEpoch == beforeExpiry.controlEpoch + 1 && expired.policies.first!.state == .expired
            _ = try owner!.authorityStateSnapshot(now: 10001)
            let nextEntries = try entries(database)
            let nextReceipt = try receipt(nextEntries.last!)
            checks["authority_clock_post_transition_starts_new_checkpoint"] = nextEntries.count == expiredEntries.count + 1
                && Array(nextEntries.dropLast()) == expiredEntries && nextReceipt.kind == "clockCheckpoint"

            stage = "activation_boundary"
            let activationState = try owner!.authorityStateSnapshot()
            let scheduled = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .global), rule: "synthetic-clock-activation",
                value: "Synthetic scheduled value", effectiveFrom: 11000)
            _ = try owner!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-clock-scheduled-policy",
                expectedRevision: activationState.revision, operation: .policySet, policyID: "synthetic-clock-scheduled-policy", policy: scheduled),
                authority: context, now: 10002)
            _ = try owner!.authorityStateSnapshot(now: 10999)
            let beforeActivation = try owner!.authorityStateSnapshot(), activationEntries = try entries(database)
            _ = try owner!.authorityStateSnapshot(now: 11000)
            let activated = try owner!.authorityStateSnapshot(), activatedEntries = try entries(database)
            let activationReceipt = try receipt(activatedEntries.last!)
            checks["authority_clock_due_activation_appends_immutable_temporal_receipt"] = Array(activatedEntries.dropLast()) == activationEntries
                && activationReceipt.kind == "time" && activated.controlEpoch == beforeActivation.controlEpoch + 1
                && activated.policies.contains { episodeIdentifierEqual($0.id, "synthetic-clock-scheduled-policy") && $0.state == .active }
            _ = try owner!.authorityStateSnapshot(now: 11001)
            _ = try owner!.authorityStateSnapshot(now: 11002)
            let terminalState = try owner!.authorityStateSnapshot(), terminalEntries = try entries(database)
            checks["authority_clock_earlier_temporal_receipts_remain_byte_identical"] = terminalEntries.contains(expiredEntries.last!)
                && terminalEntries.contains(activatedEntries.last!) && terminalEntries.contains(humanEntry)

            stage = "rollback_transaction"
            owner = nil
            try rollbackChecks(database: database, checks: &checks)
            owner = try MemoryStore(directory: directory)
            let reopened = try owner!.authorityStateSnapshot(), reopenedEntries = try entries(database)
            checks["authority_clock_startup_freezes_final_checkpoint"] = Array(reopenedEntries.dropLast()) == terminalEntries
                && reopened.controlEpoch == terminalState.controlEpoch + 1 && reopened.timeHighWater == terminalState.timeHighWater

            stage = "archive_and_corruption"
            _ = try owner!.authorityStateSnapshot(now: 11003)
            let archiveState = try owner!.authorityStateSnapshot(), archiveEntries = try entries(database)
            let archive = scratch.appendingPathComponent("archive")
            let manifest = try BackupArchive.create(from: owner!, at: archive)
            checks["authority_clock_trailing_checkpoint_archive_verifies"] = try BackupArchive.verify(at: archive) == manifest
                && receipt(archiveEntries.last!).kind == "clockCheckpoint"
            let restored = scratch.appendingPathComponent("restored")
            _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
            let restoredOwner = try MemoryStore(directory: restored)
            let restoredState = try restoredOwner.authorityStateSnapshot()
            checks["authority_clock_trailing_checkpoint_restore_keeps_highwater_and_startup_advances"] = restoredState.timeHighWater == archiveState.timeHighWater
                && restoredState.controlEpoch == archiveState.controlEpoch + 2 && restoredState.revision == archiveState.revision + 2
                && restoredState.journalSequence == archiveState.journalSequence + 2
            checks["authority_clock_restore_retains_original_checkpoint_and_receipts"] = try Array(entries(restored.appendingPathComponent("memory.sqlite3")).prefix(archiveEntries.count)) == archiveEntries
            try legacyChecks(scratch: scratch, checks: &checks)
            try corruptionChecks(scratch: scratch, archive: archive, checks: &checks)
            try transitionCorruptionChecks(scratch: scratch, checks: &checks)
            checks["authority_clock_run_completed"] = true
        } catch {
            checks["authority_clock_run_completed"] = false
            checks["authority_clock_failure_stage_" + stage] = false
            if let error = error as? AuthorityStateError { checks["authority_clock_failure_" + error.failureCode] = false }
            else { checks["authority_clock_failure_fixed_fixture_code"] = false }
        }
        return checks
    }

    /// Diagnostic producer accepts only a fresh private fixture directory. The
    /// parent kills this process after the fixed ready barrier, before commit.
    static func produceCrashFixture(directory: URL, coalescing: Bool = true) throws {
        let normalized = directory.standardizedFileURL
        guard directory.path.utf8.elementsEqual(normalized.path.utf8) else { throw CheckError.invalid }
        var target = stat()
        guard lstat(directory.path, &target) != 0, errno == ENOENT else { throw CheckError.invalid }
        let parent = directory.deletingLastPathComponent()
        guard let realParent = realpath(parent.path, nil) else { throw CheckError.invalid }
        let parentPath = String(cString: realParent); free(realParent)
        var parentMetadata = stat()
        guard parent.path.utf8.elementsEqual(parentPath.utf8), lstat(parent.path, &parentMetadata) == 0,
            parentMetadata.st_mode & S_IFMT == S_IFDIR, parentMetadata.st_mode & 0o777 == 0o700,
            parentMetadata.st_uid == getuid() else { throw CheckError.invalid }
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let committed = try owner!.authorityStateSnapshot(now: coalescing ? 100 : nil)
        let database = directory.appendingPathComponent("memory.sqlite3")
        let committedEntries = try entries(database)
        try privateWrite(canonical(committed), directory.appendingPathComponent("clock-before-state.json"))
        try privateWrite(canonical(committedEntries), directory.appendingPathComponent("clock-before-receipts.json"))
        owner = nil
        try withDatabase(database) { handle in
            try AuthorityStateKernel.execute(handle, "BEGIN IMMEDIATE")
            try AuthorityStateKernel.advanceTime(database: handle, now: 200)
            guard try AuthorityStateKernel.snapshot(database: handle).timeHighWater == 200 else { throw CheckError.invalid }
            let barrier = Data("ready\n".utf8)
            guard barrier.withUnsafeBytes({ Darwin.write(STDOUT_FILENO, $0.baseAddress, barrier.count) }) == barrier.count else { throw CheckError.invalid }
            while true { _ = Darwin.pause() }
        }
    }

    static func verifyCrashFixture(directory: URL, coalescing: Bool = true) throws -> [String: Bool] {
        let baseline = try JSONDecoder().decode(AuthorityStateSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("clock-before-state.json")))
        let baselineEntries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: directory.appendingPathComponent("clock-before-receipts.json")))
        let expectedHighWater: Int64 = coalescing ? 100 : 0, expectedEntries = coalescing ? 2 : 1
        guard baseline.timeHighWater == expectedHighWater, baseline.tasks.isEmpty, baseline.bindings.isEmpty, baseline.policies.isEmpty,
            baselineEntries.count == expectedEntries, baseline.journalSequence == expectedEntries,
            try receipt(baselineEntries.last!).kind == (coalescing ? "clockCheckpoint" : "startup") else { throw CheckError.invalid }
        let database = directory.appendingPathComponent("memory.sqlite3")
        let before = try withDatabase(database) { handle -> AuthorityStateSnapshot in
            try AuthorityStateJournal.validate(database: handle)
            return try AuthorityStateKernel.snapshot(database: handle)
        }
        let beforeEntries = try entries(database)
        let owner = try MemoryStore(directory: directory)
        let after = try owner.authorityStateSnapshot(), afterEntries = try entries(database)
        let noSources = try withDatabase(database) { handle in
            try AuthorityStateKernel.rows(handle, "SELECT count(*) FROM events")[0][0].integer == 0
                && AuthorityStateKernel.rows(handle, "SELECT count(*) FROM conversations")[0][0].integer == 0
        }
        return [
            "authority_clock_sigkill_discards_uncommitted_highwater": before.timeHighWater == expectedHighWater && after.timeHighWater == expectedHighWater,
            "authority_clock_sigkill_preserves_committed_receipt_bytes": Array(beforeEntries.prefix(expectedEntries)) == baselineEntries && Array(afterEntries.prefix(expectedEntries)) == baselineEntries,
            "authority_clock_sigkill_preserves_original_owner_and_store_identity": episodeIdentifierEqual(before.storeID, baseline.storeID)
                && episodeIdentifierEqual(before.ownerID, baseline.ownerID) && episodeIdentifierEqual(after.storeID, baseline.storeID),
            "authority_clock_sigkill_reopen_advances_epoch_revision_once": after.controlEpoch == before.controlEpoch + 1 && after.revision == before.revision + 1,
            "authority_clock_sigkill_reopen_adds_one_startup_receipt": after.journalSequence == before.journalSequence + 1
                && afterEntries.count == beforeEntries.count + 1 && Array(afterEntries.dropLast()) == beforeEntries,
            "authority_clock_sigkill_fixture_has_no_tasks_policies_or_sources": after.tasks.isEmpty && after.policies.isEmpty && after.bindings.isEmpty
                && noSources
        ]
    }

    private struct Entry: Codable, Equatable { let sequence: Int; let id: Data; let request: Data?; let receipt: Data; let digest: String }
    private enum CheckError: Error { case invalid }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data { try AuthorityStateKernel.canonical(value) }
    private static func receipt(_ entry: Entry) throws -> AuthorityOperationReceipt { try AuthorityStateKernel.decode(AuthorityOperationReceipt.self, entry.receipt) }
    private static func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    private static func withDatabase<T>(_ url: URL, _ operation: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else { throw CheckError.invalid }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)
        return try operation(database)
    }
    private static func entries(_ url: URL) throws -> [Entry] {
        try withDatabase(url) { database in
            try AuthorityStateKernel.rows(database, "SELECT sequence,request_id,request_payload,receipt_payload,receipt_digest FROM authority_operations ORDER BY sequence").map {
                guard $0.count == 5, let receipt = $0[3].bytes else { throw CheckError.invalid }
                return Entry(sequence: $0[0].integer, id: Data($0[1].string.utf8), request: $0[2].bytes, receipt: receipt, digest: $0[4].string)
            }
        }
    }
    private static func rollbackChecks(database: URL, checks: inout [String: Bool]) throws {
        let beforeEntries = try entries(database)
        try withDatabase(database) { handle in
            let before = try AuthorityStateKernel.snapshot(database: handle)
            try AuthorityStateKernel.execute(handle, "BEGIN IMMEDIATE")
            do {
                try AuthorityStateKernel.advanceTime(database: handle, now: before.timeHighWater + 1)
                let pending = try AuthorityStateKernel.snapshot(database: handle)
                checks["authority_clock_pending_checkpoint_replacement_is_visible_inside_transaction"] = pending.timeHighWater == before.timeHighWater + 1
                    && pending.journalSequence == before.journalSequence
                try AuthorityStateKernel.execute(handle, "ROLLBACK")
            } catch { try? AuthorityStateKernel.execute(handle, "ROLLBACK"); throw error }
            checks["authority_clock_transaction_rollback_retains_exact_control_state"] = try canonical(AuthorityStateKernel.snapshot(database: handle)) == canonical(before)
            try AuthorityStateJournal.validate(database: handle)
            try AuthorityStateKernel.execute(handle, "BEGIN IMMEDIATE")
            do {
                try AuthorityStateKernel.advanceTime(database: handle, now: before.timeHighWater + 2)
                checks["authority_clock_later_sql_failure_occurs_after_checkpoint_update"] = rejects {
                    try AuthorityStateKernel.execute(handle, "INSERT INTO authority_control(id,payload,digest) VALUES(2,X'01','synthetic-invalid-digest')")
                }
                try AuthorityStateKernel.execute(handle, "ROLLBACK")
            } catch { try? AuthorityStateKernel.execute(handle, "ROLLBACK"); throw error }
            checks["authority_clock_failed_transaction_retains_exact_control_state"] = try canonical(AuthorityStateKernel.snapshot(database: handle)) == canonical(before)
            try AuthorityStateJournal.validate(database: handle)
        }
        checks["authority_clock_rollback_and_failure_preserve_all_receipt_bytes"] = try entries(database) == beforeEntries
    }
    private static func corruptionChecks(scratch: URL, archive: URL, checks: inout [String: Bool]) throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("version", { $0["version"] = "authority-receipt-v1" }),
            ("kind", { $0["kind"] = "time" }),
            ("origin", { $0["origin"] = "humanHost" }),
            ("operation", { $0["operation"] = "policySet" }),
            ("request_hash", { $0["requestSHA256"] = String(repeating: "0", count: 64) }),
            ("expired_ids", { $0["expiredPolicyIDs"] = ["synthetic-clock-expiring-policy"] }),
            ("epoch", { $0["controlEpoch"] = ($0["controlEpoch"] as! Int) + 1 }),
            ("revision", { $0["revision"] = ($0["revision"] as! Int) + 1 }),
            ("sequence", { $0["journalSequence"] = ($0["journalSequence"] as! Int) + 1 }),
            ("time_rollback", { $0["timeHighWater"] = 0 }),
            ("previous_anchor", { $0["previousStateSHA256"] = String(repeating: "0", count: 64) }),
            ("current_anchor", { $0["stateSHA256"] = String(repeating: "0", count: 64) })
        ]
        for (name, mutation) in mutations {
            let copy = scratch.appendingPathComponent("clock-corrupt-" + name)
            try FileManager.default.copyItem(at: archive, to: copy)
            let database = copy.appendingPathComponent("memory.sqlite3")
            try withDatabase(database) { handle in
                let rows = try AuthorityStateKernel.rows(handle, "SELECT sequence,receipt_payload FROM authority_operations ORDER BY sequence DESC LIMIT 1")
                guard rows.count == 1, let bytes = rows[0][1].bytes else { throw CheckError.invalid }
                var value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                mutation(&value)
                let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                try AuthorityStateKernel.execute(handle, "UPDATE authority_operations SET receipt_payload=?,receipt_digest=? WHERE sequence=?",
                    [.bytes(changed), .text(AuthorityStateKernel.digest(changed)), .integer(rows[0][0].integer)])
                checks["authority_clock_" + name + "_rebound_tamper_cannot_be_coalesced"] = rejects {
                    try AuthorityStateKernel.advanceTime(database: handle, now: 12000)
                }
            }
            try refreshDatabaseHash(copy)
            checks["authority_clock_" + name + "_rebound_tamper_archive_refused"] = rejects { _ = try BackupArchive.verify(at: copy) }
            checks["authority_clock_" + name + "_rebound_tamper_reopen_refused"] = rejects { _ = try MemoryStore(directory: copy) }
        }
    }
    private static func legacyChecks(scratch: URL, checks: inout [String: Bool]) throws {
        let directory = scratch.appendingPathComponent("legacy-time")
        do { let owner = try MemoryStore(directory: directory); withExtendedLifetime(owner) {} }
        let database = directory.appendingPathComponent("memory.sqlite3")
        try withDatabase(database) { handle in
            let before = try AuthorityStateKernel.snapshot(database: handle)
            var after = before; after.timeHighWater = 100; after.journalSequence += 1
            try AuthorityStateKernel.execute(handle, "BEGIN IMMEDIATE")
            do {
                _ = try AuthorityStateKernel.record(handle, before: before, after: after, request: nil,
                    kind: "time", origin: "scheduler", requestID: "authority-time:" + UUID().uuidString.lowercased())
                try AuthorityStateKernel.execute(handle, "COMMIT")
            } catch { try? AuthorityStateKernel.execute(handle, "ROLLBACK"); throw error }
            try AuthorityStateJournal.validate(database: handle)
        }
        let legacyEntries = try entries(database), legacyReceipt = try receipt(legacyEntries.last!)
        checks["authority_clock_genuine_legacy_pure_time_receipt_validates"] = legacyReceipt.version == "authority-receipt-v1" && legacyReceipt.kind == "time"
        try withDatabase(database) { handle in
            try AuthorityStateKernel.execute(handle, "BEGIN IMMEDIATE")
            do { try AuthorityStateKernel.advanceTime(database: handle, now: 101); try AuthorityStateKernel.execute(handle, "COMMIT") }
            catch { try? AuthorityStateKernel.execute(handle, "ROLLBACK"); throw error }
            try AuthorityStateJournal.validate(database: handle)
        }
        let currentEntries = try entries(database)
        checks["authority_clock_legacy_time_receipt_is_never_coalesced"] = Array(currentEntries.dropLast()) == legacyEntries
            && currentEntries.count == legacyEntries.count + 1
        checks["authority_clock_after_legacy_time_appends_v2_checkpoint"] = try receipt(currentEntries.last!).version == "authority-receipt-v2"
            && receipt(currentEntries.last!).kind == "clockCheckpoint"
        try withDatabase(database) { handle in
            let before = try AuthorityStateKernel.snapshot(database: handle)
            let request = AuthorityOperationRequest(requestID: "authority-clock:legacy-human", expectedRevision: before.revision,
                operation: .taskNew, taskID: "synthetic-legacy-clock-prefix-task", projectID: "synthetic-clock-project")
            let after = try AuthorityStateKernel.reduce(before, request: request, database: handle)
            try AuthorityStateKernel.execute(handle, "BEGIN IMMEDIATE")
            let original: AuthorityOperationReceipt
            do {
                original = try AuthorityStateKernel.record(handle, before: before, after: after, request: request,
                    kind: "mutation", origin: "humanHost", requestID: request.requestID)
                try AuthorityStateKernel.execute(handle, "COMMIT")
            } catch { try? AuthorityStateKernel.execute(handle, "ROLLBACK"); throw error }
            try AuthorityStateJournal.validate(database: handle)
            let context = AuthorityContext(ownerID: before.ownerID, origin: .humanHost)
            let retried = try AuthorityStateKernel.apply(database: handle, request: request, authority: context, now: before.timeHighWater)
            checks["authority_clock_historical_human_prefix_retry_preserves_receipt"] = try canonical(retried) == canonical(original)
            checks["authority_clock_new_human_request_cannot_claim_checkpoint_prefix"] = rejects {
                _ = try AuthorityStateKernel.apply(database: handle, request: AuthorityOperationRequest(requestID: "authority-clock:new-human",
                    expectedRevision: after.revision, operation: .taskNew, taskID: "synthetic-rejected-clock-prefix-task", projectID: "synthetic-clock-project"),
                    authority: context, now: before.timeHighWater)
            }
        }
    }
    private static func transitionCorruptionChecks(scratch: URL, checks: inout [String: Bool]) throws {
        let directory = scratch.appendingPathComponent("transition-source")
        let owner = try MemoryStore(directory: directory)
        let initial = try owner.authorityStateSnapshot()
        let definition = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .global), rule: "synthetic-checkpoint-transition",
            value: "Synthetic timed policy", expiresAt: 200)
        _ = try owner.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-transition-policy",
            expectedRevision: initial.revision, operation: .policySet, policyID: "synthetic-transition-policy", policy: definition),
            authority: AuthorityContext(ownerID: initial.ownerID, origin: .humanHost), now: 100)
        _ = try owner.authorityStateSnapshot(now: 150)
        let archive = scratch.appendingPathComponent("transition-archive")
        _ = try BackupArchive.create(from: owner, at: archive)
        let database = archive.appendingPathComponent("memory.sqlite3")
        try withDatabase(database) { handle in
            let controlRows = try AuthorityStateKernel.rows(handle, "SELECT payload FROM authority_control WHERE id=1")
            let receiptRows = try AuthorityStateKernel.rows(handle, "SELECT sequence,receipt_payload FROM authority_operations ORDER BY sequence DESC LIMIT 1")
            guard let controlBytes = controlRows[0][0].bytes, let receiptBytes = receiptRows[0][1].bytes else { throw CheckError.invalid }
            var control = try JSONSerialization.jsonObject(with: controlBytes) as! [String: Any]
            control["timeHighWater"] = 200
            let changedControl = try JSONSerialization.data(withJSONObject: control, options: [.sortedKeys, .withoutEscapingSlashes])
            var receipt = try JSONSerialization.jsonObject(with: receiptBytes) as! [String: Any]
            receipt["timeHighWater"] = 200; receipt["stateSHA256"] = AuthorityStateKernel.digest(changedControl)
            let changedReceipt = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes])
            try AuthorityStateKernel.execute(handle, "UPDATE authority_control SET payload=?,digest=? WHERE id=1",
                [.bytes(changedControl), .text(AuthorityStateKernel.digest(changedControl))])
            try AuthorityStateKernel.execute(handle, "UPDATE authority_operations SET receipt_payload=?,receipt_digest=? WHERE sequence=?",
                [.bytes(changedReceipt), .text(AuthorityStateKernel.digest(changedReceipt)), .integer(receiptRows[0][0].integer)])
            checks["authority_clock_checkpoint_cannot_hide_due_expiry_with_all_hashes_rebound"] = rejects { try AuthorityStateJournal.validate(database: handle) }
        }
        try refreshDatabaseHash(archive)
        checks["authority_clock_hidden_temporal_transition_archive_refused"] = rejects { _ = try BackupArchive.verify(at: archive) }
        checks["authority_clock_hidden_temporal_transition_owner_reopen_refused"] = rejects { _ = try MemoryStore(directory: archive) }
    }
    private static func refreshDatabaseHash(_ archive: URL) throws {
        let manifest = archive.appendingPathComponent("manifest.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var files = value["files"] as! [[String: Any]]
        guard let index = files.firstIndex(where: { $0["name"] as? String == "memory.sqlite3" }) else { throw CheckError.invalid }
        let bytes = try Data(contentsOf: archive.appendingPathComponent("memory.sqlite3"))
        files[index]["bytes"] = bytes.count; files[index]["sha256"] = AuthorityStateKernel.digest(bytes); value["files"] = files
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    private static func privateWrite(_ bytes: Data, _ url: URL) throws {
        try bytes.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
