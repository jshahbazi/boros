import Foundation
import CSQLite
import Darwin

/// Private synthetic fixtures; output is limited to fixed Boolean checks.
enum EpisodeCleanupChecks {
    enum Failure: Error { case injected, invalid }
    final class Clock: EpisodeClockSource {
        var ticks: UInt64 = 100_000_000
        func now() throws -> EpisodeClockSnapshot { EpisodeClockSnapshot(domain: "synthetic-cleanup-clock", continuousNanoseconds: ticks, utc: Date(timeIntervalSince1970: 1_700_000_000)) }
    }
    private static func db<T>(_ directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let raw else { throw Failure.invalid }
        defer { sqlite3_close(raw) }
        return try body(raw)
    }
    private static func reject(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func begin(_ owner: MemoryStore, clock: Clock, id: String = "cleanup-episode", maximum: Int = 100000) throws -> EpisodeLease {
        let chat = try owner.createConversation(projectID: "synthetic-cleanup", title: "Synthetic cleanup fixture")
        var limits = EpisodeLimits(); var cleanup = EpisodeCleanupLimits.defaults; cleanup.maximumWorkRows = maximum; limits.terminalCleanup = cleanup
        _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: id + "-turn", humanEventID: id + "-human", episodeID: id,
            text: "Synthetic accepted cleanup input", limits: limits, clock: clock.now())
        return EpisodeLease(ledger: owner, episodeID: id, clock: clock)
    }
    private static func prepare(_ lease: EpisodeLease, count: Int, snapshot: Data? = nil) throws {
        for index in 0..<count { _ = try lease.prepare(kind: .retrieval, resources: EpisodeResources(rawSourceBytes: 1), adapterIdentity: "synthetic-cleanup", snapshot: snapshot, operationID: "cleanup-work-" + String(format: "%05d", index)) }
    }
    private static func valid(_ directory: URL) throws -> Bool { try db(directory) { try MemoryStore.validateEpisodeJournal(database: $0); return true } }
    private final class VM {
        var active = false, installed = false
        var steps = 0, scans = 0, statements = 0, snapshotStatements = 0
        func install(_ db: OpaquePointer) throws {
            guard !installed else { return }
            guard sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, raw, _ in
                guard let context, let raw else { return 0 }
                let stats = Unmanaged<VM>.fromOpaque(context).takeUnretainedValue()
                if stats.active {
                    let statement = OpaquePointer(raw)
                    stats.steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                    stats.scans += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
                    stats.statements += 1
                    if let sql = sqlite3_sql(statement), String(cString: sql).contains("episode_request_snapshots") { stats.snapshotStatements += 1 }
                }
                return 0
            }, Unmanaged.passUnretained(self).toOpaque()) == SQLITE_OK else { throw Failure.invalid }
            installed = true
        }
    }
    static private(set) var vmEvidence: [String: [Int]] = [:]
    private static func measure(_ directory: URL, unrelated: Int) throws -> [Int] {
        let stats = VM(), clock = Clock()
        let owner = try MemoryStore(directory: directory, episodeAccountingCheckpoint: { _, db in try stats.install(db) }, automaticallyDrainEpisodeCleanup: false)
        let lease = try begin(owner, clock: clock)
        try prepare(lease, count: 70)
        if unrelated > 0 {
            let other = try begin(owner, clock: clock, id: "cleanup-unrelated")
            for index in 0..<unrelated { _ = try other.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-unrelated", operationID: "unrelated-work-" + String(index)) }
        }
        stats.active = true
        _ = try lease.finish(reason: .cancelled)
        stats.active = false
        return [stats.steps, stats.scans, stats.statements, stats.snapshotStatements]
    }
    static func run() throws -> [String: Bool] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boros-cleanup-checks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks: [String: Bool] = [:]
        func suite(_ name: String, _ body: () throws -> Void) { do { try body() } catch { checks["cleanup_" + name + "_completed"] = false } }
        suite("bounded") {
            let directory = root.appendingPathComponent("bounded"), clock = Clock()
            let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
            let lease = try begin(owner, clock: clock)
            try prepare(lease, count: 70, snapshot: Data("{\"fixture\":\"".utf8) + Data(repeating: 65, count: 4 * 1048576 - 14) + Data("\"}".utf8))
            let armed = try lease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 4, outputTokens: 8, modelCalls: 1), adapterIdentity: "synthetic-cleanup-model", operationID: "zz-cleanup-armed")
            _ = try lease.arm(armed)
            let before = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            checks["cleanup_new_work_prepays_original_slots"] = before.prepaidRows == 71 && before.pendingRows == 71 && before.consumedRows == 0
            let ended = try lease.finish(reason: .cancelled)
            let first = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            checks["cleanup_stop_closes_revision_before_all_work_is_cleaned"] = ended.state == .cancelled && ended.revision == 1 && first.consumedRows == 32 && first.pendingRows == 39 && ended.held.rawSourceBytes == 38 && ended.held.outputTokens == 8
            checks["cleanup_terminal_pending_archive_is_valid"] = try valid(directory)
            checks["cleanup_no_late_dispatch_or_new_work"] = reject { _ = try lease.dispatch(armed) {} } && reject { _ = try lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-denied") }
            checks["cleanup_raised_batch_denied"] = reject { _ = try owner.drainEpisodeCleanup(episodeID: lease.episodeID, maximumRows: 33) }
            checks["cleanup_denied_batch_preserves_slots"] = try owner.episodeCleanupReceipt(episodeID: lease.episodeID) == first
            let settled = try lease.settle(armed, outcome: .completed, observed: EpisodeResources(inputTokens: 4, outputTokens: 2, modelCalls: 1), receiptID: "cleanup-late-usage")
            let point = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            checks["cleanup_late_usage_cleans_original_target_then_settles"] = settled.state == .completed && settled.charged.outputTokens == 2 && settled.held.outputTokens == 0 && point.consumedRows == 33 && point.pendingRows == 38
            _ = try lease.settle(armed, outcome: .completed, observed: EpisodeResources(inputTokens: 4, outputTokens: 2, modelCalls: 1), receiptID: "cleanup-late-usage")
            checks["cleanup_late_usage_retry_does_not_consume_twice"] = try owner.episodeCleanupReceipt(episodeID: lease.episodeID) == point
            _ = try owner.drainEpisodeCleanup(episodeID: lease.episodeID, maximumRows: 32)
            let final = try owner.drainEpisodeCleanup(episodeID: lease.episodeID, maximumRows: 32)
            checks["cleanup_all_batches_account_exactly"] = final.pendingRows == 0 && final.prepaidRows == 71 && final.consumedRows == 71
            let retry = try owner.drainEpisodeCleanup(episodeID: lease.episodeID)
            checks["cleanup_completed_batch_retry_is_idempotent"] = retry == final
            checks["cleanup_preserves_all_original_snapshots_requests_and_accepted_input"] = try db(directory) {
                let k = AuthorityStateKernel.self
                return try k.rows($0, "SELECT count(*) FROM episode_work")[0][0].integer == 71 && k.rows($0, "SELECT count(*) FROM episode_request_snapshots")[0][0].integer == 1 && k.rows($0, "SELECT count(*) FROM events WHERE role='human'")[0][0].integer == 1
            }
            checks["cleanup_late_settlement_journal_valid"] = try valid(directory)
        }
        suite("exhaustion") {
            let directory = root.appendingPathComponent("exhaustion"), clock = Clock(), owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
            let lease = try begin(owner, clock: clock, maximum: 2)
            try prepare(lease, count: 2)
            checks["cleanup_original_slot_cap_cannot_be_replenished"] = reject { _ = try lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-denied", operationID: "over-cap") }
            let receipt = try owner.episodeReceipt(id: lease.episodeID, clock: clock.now()), budget = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            checks["cleanup_exhaustion_still_funds_stop_and_releases_proven_prepared_holds"] = receipt.state == .budgetExceeded && receipt.held == .zero && budget.prepaidRows == 2 && budget.consumedRows == 2 && budget.pendingRows == 0
            checks["cleanup_exhaustion_journal_valid"] = try valid(directory)
        }
        suite("failure") {
            let directory = root.appendingPathComponent("failure"), clock = Clock()
            var fail = true
            let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false, episodeCleanupCheckpoint: { stage, _ in if fail && stage == "after-work-before-cleanup-receipt" { throw Failure.injected } })
            let lease = try begin(owner, clock: clock); try prepare(lease, count: 40)
            checks["cleanup_injected_batch_failure_is_reported"] = reject { _ = try lease.finish(reason: .cancelled) }
            let receipt = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            checks["cleanup_batch_rollback_does_not_reopen_committed_stop"] = try db(directory) { try AuthorityStateKernel.rows($0, "SELECT state,revision FROM episodes")[0][0].string == "cancelled" && AuthorityStateKernel.rows($0, "SELECT state,revision FROM episodes")[0][1].integer == 1 } && receipt.pendingRows == 40 && receipt.consumedRows == 0
            checks["cleanup_batch_rollback_retains_all_holds_and_originals"] = try db(directory) { try AuthorityStateKernel.rows($0, "SELECT count(*) FROM episode_work WHERE state='prepared'")[0][0].integer == 40 && AuthorityStateKernel.rows($0, "SELECT held FROM episode_resource_totals WHERE resource='rawSourceBytes'")[0][0].integer == 40 }
            checks["cleanup_failed_batch_journal_valid"] = try valid(directory)
            fail = false
            let first = try owner.drainEpisodeCleanup(episodeID: lease.episodeID)
            checks["cleanup_retry_resumes_only_original_prepaid_batch"] = first.consumedRows == 32 && first.pendingRows == 8
        }
        suite("attempts") {
            let directory = root.appendingPathComponent("attempts"), clock = Clock()
            do {
                let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false, episodeCleanupCheckpoint: { stage, _ in if stage == "after-work-before-cleanup-receipt" { throw Failure.injected } })
                let lease = try begin(owner, clock: clock, maximum: 2); try prepare(lease, count: 2)
                _ = reject { _ = try lease.finish(reason: .cancelled) }
                _ = reject { _ = try owner.drainEpisodeCleanup(episodeID: lease.episodeID) }
                let before = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
                checks["cleanup_failed_attempts_are_durably_charged_without_releasing_holds"] = before.attemptedRows == 4 && before.consumedRows == 0 && before.pendingRows == 2
                checks["cleanup_automatic_attempt_budget_is_finite"] = reject { _ = try owner.drainEpisodeCleanup(episodeID: lease.episodeID) }
                checks["cleanup_denied_attempt_does_not_reset_or_recharge"] = try owner.episodeCleanupReceipt(episodeID: lease.episodeID) == before
                let ended = try lease.finish(reason: .cancelled)
                checks["cleanup_exhausted_cleanup_still_allows_idempotent_stop_receipt"] = ended.state == .cancelled && ended.held.rawSourceBytes == 2
                checks["cleanup_attempt_exhaustion_pending_journal_valid"] = try valid(directory)
            }
            let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
            let restored = try owner.episodeCleanupReceipt(episodeID: "cleanup-episode")
            checks["cleanup_startup_admin_does_not_refund_original_attempts"] = restored.attemptedRows == 4 && restored.administrativeRows == 2 && restored.pendingRows == 0 && restored.consumedRows == 2
        }
        suite("automatic") {
            let directory = root.appendingPathComponent("automatic"), clock = Clock()
            let owner = try MemoryStore(directory: directory), lease = try begin(owner, clock: clock)
            try prepare(lease, count: 70); _ = try lease.finish(reason: .cancelled)
            var receipt = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            for _ in 0..<200 {
                if receipt.pendingRows == 0 { break }
                Thread.sleep(forTimeInterval: 0.005)
                receipt = try owner.episodeCleanupReceipt(episodeID: lease.episodeID)
            }
            checks["cleanup_private_queue_drains_in_bounded_prepaid_turns"] = receipt.pendingRows == 0 && receipt.consumedRows == 70 && receipt.attemptedRows == 70 && receipt.administrativeRows == 0
        }
        suite("recovery") {
            let directory = root.appendingPathComponent("recovery"), clock = Clock()
            do {
                let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false), lease = try begin(owner, clock: clock)
                try prepare(lease, count: 70); _ = try lease.finish(reason: .cancelled)
            }
            var original: EpisodeCleanupInventory?
            do {
                let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
                let receipt = try owner.episodeCleanupReceipt(episodeID: "cleanup-episode")
                checks["cleanup_reopen_resumes_terminal_pending_batches_before_admission"] = receipt.pendingRows == 0 && receipt.consumedRows == 70 && receipt.classification == .prepaidV1
                original = try db(directory) { try EpisodeTerminalCleanupJournal.inventory(database: $0) }
            }
            do {
                let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
                let current = try db(directory) { try EpisodeTerminalCleanupJournal.inventory(database: $0) }
                checks["cleanup_repeated_reopen_keeps_cleanup_receipts_exact"] = try original == current && (owner.episodeReceipt(id: "cleanup-episode", clock: clock.now())).state == .cancelled
            }
            checks["cleanup_recovered_journal_valid"] = try valid(directory)
        }
        suite("confidence") {
            let directory = root.appendingPathComponent("confidence"), clock = Clock()
            do {
                let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false), lease = try begin(owner, clock: clock)
                try prepare(lease, count: 40); _ = try lease.finish(reason: .cancelled)
                try db(directory) { try AuthorityStateKernel.execute($0, "UPDATE conversations SET title='Synthetic changed title'") }
                checks["cleanup_external_commit_refuses_work_snapshot_publication"] = reject { _ = try owner.episodeWork(episodeID: lease.episodeID, operationID: "cleanup-work-00000") }
                checks["cleanup_external_commit_cannot_spend_cached_slots"] = reject { _ = try owner.drainEpisodeCleanup(episodeID: lease.episodeID) }
                checks["cleanup_confidence_refusal_preserves_pending_holds"] = try db(directory) { try EpisodeTerminalCleanupJournal.receipt(database: $0, episodeID: lease.episodeID).pendingRows == 8 }
            }
            let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
            checks["cleanup_validated_reopen_recovers_confidence_and_pending_cleanup"] = try owner.episodeCleanupReceipt(episodeID: "cleanup-episode").pendingRows == 0
        }
        suite("corruption") {
            let mutations = [
                "UPDATE episode_cleanup_budget SET pending_rows=1,consumed_rows=1",
                "UPDATE episode_cleanup_budget SET attempted_rows=0",
                "UPDATE episode_cleanup_budget SET terminal_ticks=terminal_ticks+1",
                "DELETE FROM episode_cleanup_receipts WHERE work_id='cleanup-work-00000'; UPDATE episode_cleanup_budget SET consumed_rows=1",
                "UPDATE episode_cleanup_receipts SET from_state='submitted' WHERE work_id='cleanup-work-00000'",
                "DROP INDEX episode_cleanup_pending; CREATE INDEX episode_cleanup_pending ON episode_work(episode_id,id)"
            ]
            for (index, mutation) in mutations.enumerated() {
                let directory = root.appendingPathComponent("corrupt-" + String(index)), clock = Clock()
                do {
                    let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false), lease = try begin(owner, clock: clock)
                    try prepare(lease, count: 2); _ = try lease.finish(reason: .cancelled)
                }
                try db(directory) { guard sqlite3_exec($0, mutation, nil, nil, nil) == SQLITE_OK else { throw Failure.invalid } }
                checks["cleanup_corrupt_" + String(index) + "_independent_validator_refuses"] = reject { _ = try valid(directory) }
                checks["cleanup_corrupt_" + String(index) + "_owner_refuses_without_repair"] = reject { _ = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false) }
            }
        }
        suite("indexed") {
            let small = try measure(root.appendingPathComponent("small"), unrelated: 0)
            let large = try measure(root.appendingPathComponent("large"), unrelated: 4096)
            vmEvidence = ["small": small, "large": large]
            checks["cleanup_batch_statement_count_independent_of_4096_unrelated_records"] = small[2] == large[2]
            checks["cleanup_4096_unrelated_records_add_fewer_than_128_vm_steps"] = large[0] <= small[0] + 128
            checks["cleanup_pending_selection_has_zero_full_scan_steps"] = small[1] == 0 && large[1] == 0
            checks["cleanup_terminalization_reads_no_request_snapshots"] = small[3] == 0 && large[3] == 0
        }
        return checks
    }
    static func process(mode: String, directory: URL) throws -> [String: Bool] {
        let clock = Clock()
        if mode == "seed-fence" || mode == "seed-batch" || mode == "seed-attempt" {
            let stage = mode == "seed-fence" ? "after-terminal-fence-commit" : mode == "seed-attempt" ? "after-cleanup-attempt-commit" : "after-work-before-cleanup-receipt"
            let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false, episodeCleanupCheckpoint: { name, _ in
                if name == stage { print("ready"); fflush(stdout); while true { pause() } }
            })
            let lease = try begin(owner, clock: clock); try prepare(lease, count: 70); _ = try lease.finish(reason: .cancelled)
            return ["cleanup_process_seed_reached_stop": false]
        }
        let before = try db(directory) { raw -> EpisodeCleanupReceipt in
            try MemoryStore.validateEpisodeJournal(database: raw)
            return try EpisodeTerminalCleanupJournal.receipt(database: raw, episodeID: "cleanup-episode")
        }
        let owner = try MemoryStore(directory: directory, automaticallyDrainEpisodeCleanup: false)
        let after = try owner.episodeCleanupReceipt(episodeID: "cleanup-episode")
        return ["cleanup_process_committed_stop_precedes_kill": (try owner.episodeReceipt(id: "cleanup-episode", clock: clock.now())).state == .cancelled,
                "cleanup_process_uncommitted_batch_preserves_all_prepaid_holds": before.pendingRows == 70 && before.consumedRows == 0,
                "cleanup_process_recovery_spends_exactly_original_slots": after.pendingRows == 0 && after.prepaidRows == 70 && after.consumedRows == 70,
                "cleanup_process_original_journal_valid": try valid(directory)]
    }
}
