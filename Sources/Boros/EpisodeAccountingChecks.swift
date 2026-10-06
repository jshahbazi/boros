import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Controlled private metadata fixtures. Reports contain fixed Boolean keys only.
enum EpisodeAccountingChecks {
    enum CheckError: Error { case injected, invalid }
    final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-accounting-clock", continuousNanoseconds: 100_000_000,
                utc: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
    struct Fixture {
        let owner: MemoryStore
        let chat: StoredConversation
        let clock: Clock
        let lease: EpisodeLease
    }
    static let snapshotA = Data("{\"fixture\":\"synthetic accounting A\"}".utf8)
    static let snapshotB = Data("{\"fixture\":\"synthetic accounting B distinct\"}".utf8)
    static private(set) var vmEvidence: [String: [Int]] = [:]
    private static func reject(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func stale(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch AuthorityStateError.staleRevision { return true } catch { return false } }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data { try AuthorityStateKernel.canonical(value) }
    private static func database<T>(_ directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let db = raw else { throw CheckError.invalid }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }
    private static func begin(_ owner: MemoryStore, chat: StoredConversation, clock: Clock, id: String,
        known: Bool = true) throws -> EpisodeLease {
        var limits = EpisodeLimits(); limits.requireKnownModelInput = known
        _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: id + "-turn",
            humanEventID: id + "-human", episodeID: id, text: "Synthetic accounting accepted request",
            limits: limits, clock: clock.now())
        return EpisodeLease(ledger: owner, episodeID: id, clock: clock)
    }
    private static func fixture(_ directory: URL, checkpoint: ((String, OpaquePointer) throws -> Void)? = nil,
        known: Bool = true) throws -> Fixture {
        let owner = try MemoryStore(directory: directory, episodeAccountingCheckpoint: checkpoint), clock = Clock()
        let chat = try owner.createConversation(projectID: "synthetic-accounting-project", title: "Synthetic accounting")
        return Fixture(owner: owner, chat: chat, clock: clock, lease: try begin(owner, chat: chat, clock: clock, id: "accounting-episode", known: known))
    }
    private static func summary(_ directory: URL, _ id: String = "accounting-episode") throws -> EpisodeAccountingSummary {
        try database(directory) { try EpisodeAccountingJournal.summary(database: $0, episodeID: id) }
    }
    private static func inventory(_ directory: URL) throws -> EpisodeAccountingInventory {
        try database(directory) { try EpisodeAccountingJournal.inventory(database: $0) }
    }
    private static func rowsDigest(_ directory: URL) throws -> String {
        try database(directory) { db in
            var bytes = Data()
            for table in ["episodes", "episode_resource_totals", "episode_work", "episode_request_snapshots"] + EpisodeAccountingJournal.tableNames + ["authority_work_bindings"] {
                let columns = try AuthorityStateKernel.rows(db, "PRAGMA table_info(" + table + ")").map { row in
                    let name = "\"" + row[1].string.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    return row[2].string == "REAL" ? "CAST(" + name + " AS TEXT)" : name
                }.joined(separator: ",")
                let rows = try AuthorityStateKernel.rows(db, "SELECT " + columns + " FROM " + table + " ORDER BY 1 COLLATE BINARY,2 COLLATE BINARY")
                for row in rows {
                    let cells = row.map { value -> Data in
                        switch value {
                        case .text(let text): return Data([0]) + Data(text.utf8)
                        case .integer(let integer): return Data([1]) + Data(String(integer).utf8)
                        case .bytes(let data): return Data([2]) + data
                        case .null: return Data([3])
                        }
                    }
                    bytes.append(try canonical(cells))
                }
            }
            return AuthorityStateKernel.digest(bytes)
        }
    }
    static func run() throws -> [String: Bool] {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CheckError.invalid }
        let temporary = URL(fileURLWithPath: String(cString: path), isDirectory: true); free(path)
        let root = temporary.appendingPathComponent("boros-accounting-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var checks: [String: Bool] = [:]
        let groups: [(String, (URL, inout [String: Bool]) throws -> Void)] = [
            ("dedup", dedup), ("unknown", unknown), ("late_violation", lateViolation), ("quarantine", quarantine), ("rollback", rollback),
            ("confidence", confidence), ("corruption", corruption), ("indexed", indexed)
        ]
        for (name, body) in groups {
            do { try body(root.appendingPathComponent(name), &checks) }
            catch { checks["accounting_" + name + "_fixture"] = false }
        }
        return checks
    }
    private static func dedup(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let f = try fixture(directory)
        let first = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-dedup", snapshot: snapshotA, operationID: "first")
        let second = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-dedup", snapshot: snapshotA, operationID: "second")
        let third = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-dedup", snapshot: snapshotB, operationID: "third")
        let before = try summary(directory), beforeInventory = try inventory(directory)
        checks["accounting_snapshot_bytes_dedup_exact_digest_per_episode"] = before.workCount == 3 && before.snapshotBytes == snapshotA.count + snapshotB.count && beforeInventory.snapshotReferences == 2
        checks["accounting_exact_reservation_retry_does_not_double_project"] = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-dedup", snapshot: snapshotA, operationID: first.id) == first && summary(directory) == before
        checks["accounting_changed_reservation_retry_rejects_without_projection_write"] = try reject { _ = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-dedup", snapshot: snapshotB, operationID: first.id) } && summary(directory) == before
        let composed = "receipt-é", decomposed = "receipt-e\u{301}"
        let a = try f.lease.settle(first, outcome: .cancelledBeforeDispatch, receiptID: composed)
        let b = try f.lease.settle(second, outcome: .cancelledBeforeDispatch, receiptID: decomposed)
        checks["accounting_settlement_unicode_ids_remain_binary_distinct"] = try database(directory) { db in
            let one = try EpisodeAccountingJournal.settlementOwner(database: db, episodeID: f.lease.episodeID, receiptID: composed)
            let two = try EpisodeAccountingJournal.settlementOwner(database: db, episodeID: f.lease.episodeID, receiptID: decomposed)
            return episodeIdentifierEqual(one, first.id) && episodeIdentifierEqual(two, second.id) && !episodeIdentifierEqual(one, two)
        }
        checks["accounting_same_episode_receipt_id_cannot_be_reused_on_other_work"] = reject { _ = try f.lease.settle(third, outcome: .cancelledBeforeDispatch, receiptID: composed) }
        let after = try inventory(directory)
        checks["accounting_exact_settlement_retry_is_projection_idempotent"] = try f.lease.settle(a, outcome: .cancelledBeforeDispatch, receiptID: composed) == a && inventory(directory) == after
        checks["accounting_changed_settlement_same_receipt_rejects"] = reject { _ = try f.lease.settle(a, outcome: .failedConfirmed, receiptID: composed) }
        let other = try begin(f.owner, chat: f.chat, clock: f.clock, id: "other-accounting")
        let shared = try other.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-dedup", snapshot: snapshotA, operationID: "other-work")
        _ = try other.settle(shared, outcome: .cancelledBeforeDispatch, receiptID: composed)
        checks["accounting_snapshot_and_receipt_dedup_scopes_are_episode_local"] = try summary(directory, other.episodeID).snapshotBytes == snapshotA.count && inventory(directory).snapshotReferences == 3 && inventory(directory).settlementReceipts == 3
        checks["accounting_settlement_keeps_original_snapshots_and_work_inventory"] = try summary(directory).workCount == 3 && summary(directory).snapshotBytes == before.snapshotBytes && b.request.snapshot == snapshotA
        for (name, value) in [("empty", ""), ("nul", "bad\0id"), ("oversized", String(repeating: "x", count: 257))] {
            checks["accounting_malformed_" + name + "_receipt_id_rejects"] = reject { _ = try f.lease.settle(third, outcome: .cancelledBeforeDispatch, receiptID: value) }
        }
        checks["accounting_live_known_atomic_writes_retain_projection_confidence"] = try f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()).unknownInputOperations == 0
        checks["accounting_complete_projection_matches_original_metadata"] = try inventory(directory).settlementReceipts == 3
    }
    private static func unknown(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let f = try fixture(directory, known: false)
        let model = try f.lease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1),
            adapterIdentity: "synthetic-unknown-model", snapshot: snapshotA, inputTokensKnown: false, operationID: "unknown-model")
        let metadata = try f.lease.prepare(kind: .retrieval, resources: EpisodeResources(memoryOperations: 1),
            adapterIdentity: "synthetic-unknown-metadata", inputTokensKnown: false, operationID: "unknown-metadata")
        let unused = try f.lease.prepare(kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1),
            adapterIdentity: "synthetic-unused-model", inputTokensKnown: false, operationID: "unused-model")
        checks["accounting_prepared_unknown_input_is_not_an_attempt"] = try summary(directory).unknownInputOperations == 0
        let armed = try f.lease.arm(model)
        checks["accounting_armed_unknown_model_counts_once"] = try summary(directory).unknownInputOperations == 1 && f.lease.checkActive().unknownInputOperations == 1
        _ = try f.lease.arm(armed); _ = try f.lease.arm(metadata)
        _ = try f.lease.settle(unused, outcome: .cancelledBeforeDispatch, receiptID: "unused-cancel")
        checks["accounting_predicate_requires_unknown_input_and_model_attempt"] = try summary(directory).unknownInputOperations == 1
        let submitted = try f.lease.dispatch(armed) {}, uncertain = try f.lease.settle(submitted, outcome: .outcomeUnknown, receiptID: "unknown-receipt")
        _ = try f.lease.finish(reason: .cancelled)
        let late = try f.lease.settle(uncertain, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "late-usage")
        checks["accounting_late_usage_preserves_literal_unknown_input_predicate"] = try summary(directory).unknownInputOperations == 1 && f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()).unknownInputOperations == 1 && late.held == .zero
        checks["accounting_late_usage_projects_both_original_receipts"] = try inventory(directory).settlementReceipts == 3 && summary(directory).workCount == 3
        let lateBefore = try inventory(directory)
        _ = try f.lease.settle(late, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "late-usage")
        checks["accounting_late_usage_retry_retains_charge_and_receipt_projection"] = try inventory(directory) == lateBefore && f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()).charged.outputTokens == 2
    }
    private static func violate(_ f: Fixture, id: String, adapter: String) throws -> EpisodeWorkRecord {
        let lease = try begin(f.owner, chat: f.chat, clock: f.clock, id: id)
        let prepared = try lease.prepare(kind: .calibration, resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1), adapterIdentity: adapter, operationID: id + "-work")
        let armed = try lease.arm(prepared)
        guard reject({ _ = try lease.settle(armed, outcome: .completed, observed: EpisodeResources(inputTokens: 4, outputTokens: 1, modelCalls: 1), receiptID: id + "-receipt") }) else { throw CheckError.invalid }
        return try f.owner.episodeWork(episodeID: lease.episodeID, operationID: armed.id)!
    }
    private static func lateViolation(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let f = try fixture(directory, known: false)
        let prepared = try f.lease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1),
            adapterIdentity: "synthetic-late-violation", snapshot: snapshotA, inputTokensKnown: false, operationID: "late-violation-work")
        let submitted = try f.lease.dispatch(prepared) {}
        let unknown = try f.lease.settle(submitted, outcome: .outcomeUnknown, receiptID: "initial-unknown")
        let initial = try inventory(directory)
        let violation = EpisodeWorkSettlement(receiptID: "late-identity-violation", outcome: .outcomeUnknown, observed: nil, evidence: nil, adapterViolation: true)
        var violationRecorded = false
        do { _ = try f.owner.settleEpisodeWork(episodeID: f.lease.episodeID, operationID: unknown.id, settlement: violation, clock: f.clock.now()) }
        catch EpisodeBudgetError.adapterViolation { violationRecorded = true } catch { }
        let violated = try f.owner.episodeWork(episodeID: f.lease.episodeID, operationID: unknown.id)!, after = try inventory(directory)
        checks["accounting_late_identity_violation_projects_new_receipt_and_quarantine"] = violationRecorded && after.settlementReceipts == initial.settlementReceipts + 1 && after.quarantineKeys == 1
        checks["accounting_late_identity_violation_preserves_unknown_output_hold_and_count"] = try violated.state == .outcomeUnknown && violated.held.outputTokens == 4 && summary(directory).unknownInputOperations == 1 && f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()).state == .failed
        let late = try f.lease.settle(violated, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "final-late-usage")
        checks["accounting_three_receipt_ordinals_preserve_original_identity_and_usage"] = try database(directory) { db in
            let values = try AuthorityStateKernel.rows(db, "SELECT receipt_id,ordinal FROM episode_settlement_receipts WHERE work_id=? ORDER BY ordinal", [.text(unknown.id)])
            return values.count == 3 && values[0][0].string == "initial-unknown" && values[0][1].integer == 0 && values[1][0].string == "late-identity-violation" && values[1][1].integer == 1 && values[2][0].string == "final-late-usage" && values[2][1].integer == 2
        }
        checks["accounting_late_usage_does_not_erase_terminal_failure_or_quarantine"] = try late.held == .zero && f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()).state == .failed && f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()).charged.outputTokens == 2 && inventory(directory).quarantineKeys == 1
        let stable = try inventory(directory)
        checks["accounting_fourth_receipt_is_denied_without_projection_mutation"] = try reject { _ = try f.lease.settle(late, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "fourth-receipt") } && inventory(directory) == stable
    }
    private static func quarantine(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let f = try fixture(directory), endpoint = "http://localhost:11234/v1/chat/completions"
        let pinned = endpoint + "|" + Qwen38TextRendering.modelID + "|" + Qwen38TextRendering.serverVersion + "|" + Qwen38TextRendering.templateDigest
        let legacy = "mlx-serve-qwen38-text-v1|" + pinned + "|1700000000|thinking=false"
        let current = "mlx-serve-qwen38-observed-text-v1|" + pinned + "|observed=" + String(repeating: "a", count: 64) + "|instance=unobservable|thinking=false"
        let malformed = "mlx-serve-qwen38-text-v1|" + pinned + "|01|thinking=false"
        _ = try violate(f, id: "lookalike", adapter: malformed)
        checks["accounting_malformed_family_lookalike_retains_exact_quarantine_key"] = try database(directory) { try EpisodeAccountingJournal.isQuarantined(database: $0, adapterIdentity: malformed) && !EpisodeAccountingJournal.isQuarantined(database: $0, adapterIdentity: current) }
        _ = try violate(f, id: "legacy", adapter: legacy)
        checks["accounting_historical_violation_quarantines_current_stable_family"] = try database(directory) { db in
            try EpisodeAccountingJournal.isQuarantined(database: db, adapterIdentity: current) && EpisodeAccountingJournal.isQuarantined(database: db, adapterIdentity: legacy.replacingOccurrences(of: "1700000000", with: "1700000001"))
        }
        checks["accounting_family_quarantine_preserves_endpoint_and_thinking_scope"] = try database(directory) { db in
            try !EpisodeAccountingJournal.isQuarantined(database: db, adapterIdentity: current.replacingOccurrences(of: "thinking=false", with: "thinking=true")) && !EpisodeAccountingJournal.isQuarantined(database: db, adapterIdentity: current.replacingOccurrences(of: "11234", with: "11235"))
        }
        let blocked = try begin(f.owner, chat: f.chat, clock: f.clock, id: "blocked-family")
        checks["accounting_owner_reservation_enforces_projected_family_quarantine"] = reject { _ = try blocked.prepare(kind: .answer, resources: EpisodeResources(modelCalls: 1), adapterIdentity: current) }
        let unsupported = "synthetic-adapter-é", distinct = "synthetic-adapter-e\u{301}"
        _ = try violate(f, id: "unsupported", adapter: unsupported)
        checks["accounting_unsupported_adapter_quarantine_preserves_exact_unicode_bytes"] = try database(directory) { try EpisodeAccountingJournal.isQuarantined(database: $0, adapterIdentity: unsupported) && !EpisodeAccountingJournal.isQuarantined(database: $0, adapterIdentity: distinct) }
        for (name, identity) in [("empty", ""), ("nul", "adapter\0nul"), ("oversized", String(repeating: "a", count: 2049))] {
            checks["accounting_invalid_" + name + "_quarantine_identity_rejects"] = try database(directory) { db in reject { _ = try EpisodeAccountingJournal.isQuarantined(database: db, adapterIdentity: identity) } }
        }
        checks["accounting_quarantine_projection_reconstructs_from_original_violation_rows"] = try inventory(directory).quarantineKeys == 3
    }
    private static func rollback(_ directory: URL, _ checks: inout [String: Bool]) throws {
        var failWork = false, failSettlement = false, enteredWork = false, enteredSettlement = false
        let f = try fixture(directory, checkpoint: { name, _ in
            if failWork && name == "after-work-before-accounting" { failWork = false; enteredWork = true; throw CheckError.injected }
            if failSettlement && name == "after-settlement-before-accounting" { failSettlement = false; enteredSettlement = true; throw CheckError.injected }
        })
        let before = try rowsDigest(directory)
        failWork = true
        checks["accounting_exception_between_work_and_projection_rejects"] = reject { _ = try f.lease.prepare(kind: .retrieval, resources: EpisodeResources(memoryOperations: 1), adapterIdentity: "synthetic-atomic", snapshot: snapshotA, operationID: "atomic-work") } && enteredWork
        checks["accounting_failed_reservation_rolls_back_work_snapshot_totals_and_projection"] = try rowsDigest(directory) == before && summary(directory).workCount == 0 && f.lease.checkActive().held == .zero
        let work = try f.lease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1), adapterIdentity: "synthetic-atomic", snapshot: snapshotA, operationID: "atomic-work")
        let armed = try f.lease.arm(work), settlementBefore = try rowsDigest(directory)
        failSettlement = true
        checks["accounting_exception_between_settlement_and_projection_rejects"] = reject { _ = try f.lease.settle(armed, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "atomic-receipt") } && enteredSettlement
        checks["accounting_failed_settlement_rolls_back_original_receipt_totals_and_projection"] = try rowsDigest(directory) == settlementBefore && f.owner.episodeWork(episodeID: f.lease.episodeID, operationID: armed.id) == armed && inventory(directory).settlementReceipts == 0
        let settled = try f.lease.settle(armed, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "atomic-receipt")
        checks["accounting_retry_after_rollback_publishes_one_receipt_and_exact_usage"] = try settled.state == .completed && inventory(directory).settlementReceipts == 1 && f.lease.checkActive().charged.outputTokens == 2
    }
    private static func confidence(_ directory: URL, _ checks: inout [String: Bool]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for reverted in [false, true] {
            let name = reverted ? "external-edit-revert" : "external-commit", location = directory.appendingPathComponent(name)
            do {
                let f = try fixture(location)
                let work = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-confidence", operationID: "confidence-work")
                _ = try f.owner.append(conversationID: f.chat.id, role: .human, text: "Synthetic immutable source append", status: .complete, turnID: "source-only", eventID: "source-only")
                checks["accounting_" + name.replacingOccurrences(of: "-", with: "_") + "_owner_source_append_retains_confidence"] = try f.lease.checkActive().state == .active
                try database(location) { db in
                    try AuthorityStateKernel.execute(db, "UPDATE conversations SET title='Synthetic external title'")
                    if reverted { try AuthorityStateKernel.execute(db, "UPDATE conversations SET title='Synthetic accounting'") }
                }
                checks["accounting_" + name.replacingOccurrences(of: "-", with: "_") + "_blocks_projection_receipt"] = stale { _ = try f.lease.checkActive() }
                checks["accounting_" + name.replacingOccurrences(of: "-", with: "_") + "_blocks_new_reservation_and_settlement"] = stale { _ = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-confidence", operationID: "denied-confidence") } && stale { _ = try f.lease.settle(work, outcome: .cancelledBeforeDispatch, receiptID: "denied-receipt") }
                checks["accounting_" + name.replacingOccurrences(of: "-", with: "_") + "_does_not_silently_rebuild_live_confidence"] = stale { _ = try f.owner.episodeReceipt(id: f.lease.episodeID, clock: f.clock.now()) }
            }
            let reopened = try MemoryStore(directory: location)
            checks["accounting_" + name.replacingOccurrences(of: "-", with: "_") + "_validated_reopen_reestablishes_confidence"] = try reopened.episodeReceipt(id: "accounting-episode", clock: Clock().now()).state == .interrupted && inventory(location).episodes == 1
        }
        for name in ["noop-accounting", "delete-projection", "ddl", "after-work", "after-settlement"] {
            let location = directory.appendingPathComponent(name)
            do {
                var inject = false, entered = false
                let checkpoint = name == "after-work" ? "after-work-before-accounting" : (name == "after-settlement" ? "after-settlement-before-accounting" : "before-accounting-lookup")
                let f = try fixture(location, checkpoint: { stage, db in
                    guard inject && stage == checkpoint else { return }
                    inject = false; entered = true
                    if name == "delete-projection" { try AuthorityStateKernel.execute(db, "DELETE FROM episode_accounting WHERE episode_id='accounting-episode'") }
                    else if name == "ddl" { try AuthorityStateKernel.execute(db, "CREATE INDEX accounting_injected_index ON episode_accounting(work_count)") }
                    else { try AuthorityStateKernel.execute(db, "UPDATE episode_accounting SET work_count=work_count WHERE episode_id='accounting-episode'") }
                })
                let existing = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-confidence", operationID: "existing")
                let before = try rowsDigest(location)
                inject = true
                let denied: Bool
                if name == "after-work" { denied = stale { _ = try f.lease.prepare(kind: .retrieval, resources: EpisodeResources(memoryOperations: 1), adapterIdentity: "synthetic-confidence", snapshot: snapshotA, operationID: "injected") } }
                else if name == "after-settlement" { denied = stale { _ = try f.lease.settle(existing, outcome: .cancelledBeforeDispatch, receiptID: "injected") } }
                else { denied = stale { _ = try f.lease.checkActive() } }
                let key = name.replacingOccurrences(of: "-", with: "_")
                checks["accounting_same_connection_" + key + "_denied_at_whole_read_fence"] = denied && entered
                checks["accounting_same_connection_" + key + "_rollback_preserves_original_and_projection_bytes"] = try rowsDigest(location) == before
                checks["accounting_same_connection_" + key + "_confidence_stays_lost_after_rollback"] = stale { _ = try f.lease.checkActive() }
                try database(location) { try EpisodeAccountingJournal.validate(database: $0) }
                checks["accounting_same_connection_" + key + "_rollback_remains_valid_offline"] = true
            }
            let reopened = try MemoryStore(directory: location)
            checks["accounting_same_connection_" + name.replacingOccurrences(of: "-", with: "_") + "_reopen_reconstructs_trust"] = try reopened.episodeReceipt(id: "accounting-episode", clock: Clock().now()).state == .interrupted
        }
        var probe = false, fenced = false
        let location = directory.appendingPathComponent("lookup-fence")
        let f = try fixture(location, checkpoint: { stage, _ in
            if probe && stage == "before-accounting-lookup" {
                probe = false
                fenced = try database(location) { db in
                    sqlite3_busy_timeout(db, 0)
                    let result = sqlite3_exec(db, "UPDATE conversations SET title='Synthetic blocked external title'", nil, nil, nil)
                    return result == SQLITE_BUSY || result == SQLITE_LOCKED
                }
            }
        })
        probe = true
        checks["accounting_trust_check_and_projection_lookup_share_external_write_fence"] = try f.lease.checkActive().state == .active && fenced
    }
    private static func corruption(_ directory: URL, _ checks: inout [String: Bool]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let cases = ["missing-summary", "wrong-count", "wrong-bytes", "wrong-unknown", "missing-snapshot", "orphan-snapshot", "rehashed-receipt", "wrong-ordinal", "wrong-quarantine", "extra-index", "missing-table", "rehashed-original-receipt", "malformed-identity", "numeric-bool", "resource-total"]
        for name in cases {
            let location = directory.appendingPathComponent(name)
            do {
                let f = try fixture(location)
                let work = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-corruption", snapshot: snapshotA, operationID: "original-work")
                _ = try f.lease.settle(work, outcome: .cancelledBeforeDispatch, receiptID: "original-receipt")
                _ = try violate(f, id: "violation", adapter: "synthetic-corrupt-quarantine")
                _ = try inventory(location)
            }
            try database(location) { db in
                switch name {
                case "missing-summary": try AuthorityStateKernel.execute(db, "DELETE FROM episode_accounting WHERE episode_id='accounting-episode'")
                case "wrong-count": try AuthorityStateKernel.execute(db, "UPDATE episode_accounting SET work_count=work_count+1 WHERE episode_id='accounting-episode'")
                case "wrong-bytes": try AuthorityStateKernel.execute(db, "UPDATE episode_accounting SET snapshot_bytes=0 WHERE episode_id='accounting-episode'")
                case "wrong-unknown": try AuthorityStateKernel.execute(db, "UPDATE episode_accounting SET unknown_input_operations=1 WHERE episode_id='accounting-episode'")
                case "missing-snapshot": try AuthorityStateKernel.execute(db, "DELETE FROM episode_snapshot_references WHERE episode_id='accounting-episode'")
                case "orphan-snapshot": try AuthorityStateKernel.execute(db, "INSERT INTO episode_snapshot_references VALUES('missing-episode',?)", [.text(AuthorityStateKernel.digest(snapshotA))])
                case "rehashed-receipt": try AuthorityStateKernel.execute(db, "UPDATE episode_settlement_receipts SET receipt_sha256=? WHERE episode_id='accounting-episode'", [.text(String(repeating: "0", count: 64))])
                case "wrong-ordinal": try AuthorityStateKernel.execute(db, "UPDATE episode_settlement_receipts SET ordinal=1 WHERE episode_id='accounting-episode'")
                case "wrong-quarantine": try AuthorityStateKernel.execute(db, "UPDATE episode_adapter_quarantine SET identity='synthetic-other-quarantine'")
                case "extra-index": try AuthorityStateKernel.execute(db, "CREATE INDEX accounting_unrecognized_index ON episode_accounting(work_count)")
                case "missing-table": try AuthorityStateKernel.execute(db, "DROP TABLE episode_settlement_receipts")
                case "rehashed-original-receipt":
                    let values = [EpisodeWorkSettlement(receiptID: "replacement-receipt", outcome: .cancelledBeforeDispatch, observed: nil, evidence: nil)], bytes = try canonical(values)
                    try AuthorityStateKernel.execute(db, "UPDATE episode_work SET receipt_id='replacement-receipt',receipt_json=?,receipt_digest=? WHERE id='original-work'", [.bytes(bytes), .text(AuthorityStateKernel.digest(bytes))])
                case "malformed-identity", "numeric-bool":
                    let value = try AuthorityStateKernel.rows(db, "SELECT request_json FROM episode_work WHERE id='original-work'")[0][0].bytes!
                    var parsed = try JSONSerialization.jsonObject(with: value) as! [String: Any]
                    if name == "malformed-identity" { parsed["adapterIdentity"] = "synthetic\0invalid" }
                    else { parsed["inputTokensKnown"] = 0 }
                    let bytes = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
                    if name == "malformed-identity" { try AuthorityStateKernel.execute(db, "UPDATE episode_work SET adapter_identity=?,request_json=?,request_digest=? WHERE id='original-work'", [.text("synthetic\0invalid"), .bytes(bytes), .text(AuthorityStateKernel.digest(bytes))]) }
                    else { try AuthorityStateKernel.execute(db, "UPDATE episode_work SET request_json=?,request_digest=? WHERE id='original-work'", [.bytes(bytes), .text(AuthorityStateKernel.digest(bytes))]) }
                default: try AuthorityStateKernel.execute(db, "UPDATE episode_resource_totals SET charged=1 WHERE episode_id='accounting-episode' AND resource='memoryOperations'")
                }
            }
            let key = name.replacingOccurrences(of: "-", with: "_")
            if name != "resource-total" {
                checks["accounting_" + key + "_independent_reconstruction_rejects"] = try database(location) { db in reject { try EpisodeAccountingJournal.validate(database: db) } }
            }
            checks["accounting_" + key + "_current_owner_startup_rejects_without_repair"] = reject { _ = try MemoryStore(directory: location) }
        }
    }
    private final class VMStats {
        var active = false, installed = false
        var steps = 0, scans = 0, statements = 0
        func reset() { steps = 0; scans = 0; statements = 0; active = true }
        func install(_ db: OpaquePointer) throws {
            guard !installed else { return }
            let result = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, raw, _ in
                guard let context, let raw else { return 0 }
                let stats = Unmanaged<VMStats>.fromOpaque(context).takeUnretainedValue()
                if stats.active {
                    let statement = OpaquePointer(raw)
                    stats.steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                    stats.scans += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
                    stats.statements += 1
                }
                return 0
            }, Unmanaged.passUnretained(self).toOpaque())
            guard result == SQLITE_OK else { throw CheckError.invalid }; installed = true
        }
        var sample: [Int] { [steps, scans, statements] }
    }
    /// Add canonical original rows only while no owner is live, then exercise
    /// the genuine schema-7 to schema-8 migration. Projections are never repaired
    /// or re-trusted inside an existing episode.
    private static func seedBulk(_ directory: URL, count: Int) throws {
        do {
            let f = try fixture(directory)
            for (id, receipt) in [("seed-work", "seed-receipt"), ("collision-work", "collision-receipt")] {
                let work = try f.lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-bulk", snapshot: snapshotA, operationID: id)
                _ = try f.lease.settle(work, outcome: .cancelledBeforeDispatch, receiptID: receipt)
            }
        }
        try database(directory) { db in
            try AuthorityStateKernel.execute(db, "BEGIN IMMEDIATE")
            do {
                try AuthorityStateKernel.execute(db, "DROP INDEX episode_cleanup_pending")
                for name in EpisodeTerminalCleanupJournal.tableNames.reversed() { try AuthorityStateKernel.execute(db, "DROP TABLE " + name) }
                for name in EpisodeAccountingJournal.tableNames.reversed() { try AuthorityStateKernel.execute(db, "DROP TABLE " + name) }
                try AuthorityStateKernel.execute(db, "PRAGMA user_version=7")
                for index in 0..<count {
                    let id = "bulk-work-" + String(index), receiptID = "bulk-receipt-" + String(index)
                    let metadata = try canonical(EpisodeWorkRequest(id: id, parentID: nil, kind: .retrieval, resources: .zero,
                        adapterIdentity: "synthetic-bulk", snapshot: nil, inputTokensKnown: true))
                    let receipt = try canonical([EpisodeWorkSettlement(receiptID: receiptID, outcome: .cancelledBeforeDispatch, observed: nil, evidence: nil)])
                    try AuthorityStateKernel.execute(db, """
                        INSERT INTO episode_work(id,episode_id,parent_id,kind,adapter_identity,request_json,request_digest,snapshot_digest,revision,state,charged_json,held_json,observed_json,receipt_id,receipt_json,receipt_digest,created_ticks,armed_ticks,ended_ticks,recovered,adapter_violation)
                        SELECT ?,episode_id,parent_id,kind,adapter_identity,?,?,snapshot_digest,revision,state,charged_json,held_json,observed_json,?,?,?,created_ticks,armed_ticks,ended_ticks,recovered,adapter_violation FROM episode_work WHERE id='seed-work'
                        """, [.text(id), .bytes(metadata), .text(AuthorityStateKernel.digest(metadata)), .text(receiptID), .bytes(receipt), .text(AuthorityStateKernel.digest(receipt))])
                    try AuthorityBindingJournal.insertLegacyWork(database: db, id: id)
                }
                try AuthorityStateKernel.execute(db, "COMMIT")
            } catch { try? AuthorityStateKernel.execute(db, "ROLLBACK"); throw error }
        }
    }
    private static func measure(_ directory: URL, count: Int) throws -> [[Int]] {
        try seedBulk(directory, count: count)
        let stats = VMStats()
        let owner = try MemoryStore(directory: directory, episodeAccountingCheckpoint: { name, db in
            if name == "before-accounting-lookup" { try stats.install(db) }
        }), clock = Clock()
        let chat = try owner.listConversations(projectID: "synthetic-accounting-project")[0]
        let fresh = try begin(owner, chat: chat, clock: clock, id: "measured-fresh")
        _ = try owner.episodeReceipt(id: "accounting-episode", clock: clock.now())
        var samples: [[Int]] = []
        stats.reset(); let old = try owner.episodeReceipt(id: "accounting-episode", clock: clock.now()); stats.active = false; samples.append(stats.sample)
        guard old.state == .interrupted, old.unknownInputOperations == 0 else { throw CheckError.invalid }
        stats.reset()
        let work = try fresh.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-measured-unquarantined", snapshot: snapshotB, operationID: "measured-work")
        stats.active = false; samples.append(stats.sample)
        stats.reset()
        _ = try fresh.settle(work, outcome: .cancelledBeforeDispatch, receiptID: "measured-receipt")
        stats.active = false; samples.append(stats.sample)
        stats.reset()
        let collision = reject { _ = try owner.settleEpisodeWork(episodeID: "accounting-episode", operationID: "seed-work",
            settlement: EpisodeWorkSettlement(receiptID: "collision-receipt", outcome: .cancelledBeforeDispatch, observed: nil, evidence: nil), clock: clock.now()) }
        stats.active = false; samples.append(stats.sample)
        guard collision, try summary(directory).workCount == count + 2, try summary(directory).snapshotBytes == snapshotA.count,
            try inventory(directory).settlementReceipts == count + 3 else { throw CheckError.invalid }
        withExtendedLifetime((owner, stats)) {}
        return samples
    }
    private static func indexed(_ directory: URL, _ checks: inout [String: Bool]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let small = try measure(directory.appendingPathComponent("small"), count: 0)
        let large = try measure(directory.appendingPathComponent("large"), count: 4096)
        let names = ["receipt", "reserve", "settlement", "duplicate_receipt"]
        for index in names.indices {
            vmEvidence["small_" + names[index]] = small[index]
            vmEvidence["large_" + names[index]] = large[index]
            checks["accounting_indexed_" + names[index] + "_uses_no_inventory_full_scan"] = small[index][1] == 0 && large[index][1] == 0
            checks["accounting_indexed_" + names[index] + "_vm_work_stays_bounded_with_4096_original_records"] = large[index][0] > 0 && large[index][0] <= small[index][0] + 128 && large[index][0] < 2000 && large[index][2] <= small[index][2] + 2
        }
        checks["accounting_bulk_fixture_uses_validated_old_schema_upgrade"] = try database(directory.appendingPathComponent("large")) { db in
            try AuthorityStateKernel.rows(db, "PRAGMA user_version")[0][0].integer == 9 && EpisodeAccountingJournal.summary(database: db, episodeID: "accounting-episode").workCount == 4098
        }
    }
    /// Standalone runner process boundaries. Only fixed readiness or Boolean
    /// results escape; the Python runner sends real SIGKILL at the checkpoints.
    static func process(mode: String, directory: URL) throws -> [String: Bool] {
        let clock = SystemEpisodeClock()
        if mode == "kill-work" || mode == "kill-settlement" {
            let checkpoint = mode == "kill-work" ? "after-work-before-accounting" : "after-settlement-before-accounting"
            let owner = try MemoryStore(directory: directory, episodeAccountingCheckpoint: { name, _ in
                if name == checkpoint { print("ready"); fflush(stdout); _ = readLine() }
            })
            let chat = try owner.createConversation(projectID: "synthetic-accounting-process", title: "Synthetic process accounting")
            var limits = EpisodeLimits(); limits.requireKnownModelInput = false
            _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "process-turn", humanEventID: "process-human",
                episodeID: "process-episode", text: "Synthetic complete accounting process capture", limits: limits, clock: clock.now())
            let request = EpisodeWorkRequest(id: "process-work", parentID: nil, kind: .answer,
                resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1), adapterIdentity: "synthetic-process",
                snapshot: snapshotA, inputTokensKnown: false)
            let work = try owner.reserveEpisodeWork(episodeID: "process-episode", request: request, clock: clock.now())
            let armed = try owner.armEpisodeWork(episodeID: "process-episode", operationID: work.id, expectedRevision: work.revision, clock: clock.now())
            _ = try owner.settleEpisodeWork(episodeID: "process-episode", operationID: armed.id,
                settlement: EpisodeWorkSettlement(receiptID: "process-receipt", outcome: .completed,
                    observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), evidence: nil), clock: clock.now())
            withExtendedLifetime(owner) {}; throw CheckError.invalid
        }
        let owner = try MemoryStore(directory: directory)
        let receipt = try owner.episodeReceipt(id: "process-episode", clock: clock.now())
        let work = try owner.episodeWork(episodeID: receipt.id, operationID: "process-work"), projection = try summary(directory, receipt.id), proof = try inventory(directory)
        var checks: [String: Bool] = [:]
        checks["accounting_process_recovery_retains_complete_original_human_capture"] = try owner.events(conversationID: receipt.conversationID!).count == 1 && owner.events(conversationID: receipt.conversationID!).first!.text == "Synthetic complete accounting process capture"
        checks["accounting_process_recovery_publishes_schema_eight_and_valid_projection"] = try database(directory) { try AuthorityStateKernel.rows($0, "PRAGMA user_version")[0][0].integer == 9 } && proof.episodes == 1
        checks["accounting_process_recovery_never_publishes_interrupted_settlement_receipt"] = proof.settlementReceipts == 0
        if mode == "recover-work" {
            checks["accounting_process_work_prefix_rolls_back_original_and_projection"] = work == nil && projection.workCount == 0 && projection.snapshotBytes == 0 && projection.unknownInputOperations == 0 && proof.snapshotReferences == 0
            checks["accounting_process_work_prefix_rolls_back_resource_capacity"] = receipt.charged == .zero && receipt.held == .zero && receipt.state == .interrupted
        } else if mode == "recover-settlement" {
            checks["accounting_process_settlement_prefix_recovers_original_unknown_charge"] = work?.state == .outcomeUnknown && work?.recovered == true && receipt.charged == EpisodeResources(inputTokens: 3, modelCalls: 1) && receipt.held == EpisodeResources(outputTokens: 4) && receipt.state == .interrupted
            checks["accounting_process_settlement_prefix_preserves_snapshot_and_literal_unknown_count"] = work?.request.snapshot == snapshotA && projection.workCount == 1 && projection.snapshotBytes == snapshotA.count && projection.unknownInputOperations == 1 && receipt.unknownInputOperations == 1 && proof.snapshotReferences == 1
        } else { throw CheckError.invalid }
        return checks
    }
}
