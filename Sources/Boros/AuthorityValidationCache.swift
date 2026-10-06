import Foundation
import CSQLite

enum AuthorityValidationCacheError: Error { case reentrant }

/// Lower-only test/configuration bounds. No runtime interface exposes them.
struct AuthorityValidationCacheLimits {
    static let defaults = AuthorityValidationCacheLimits()
    var maximumSessions = 4
    var maximumAttempts = 256
    var maximumCanonicalBytes = 16 * 1024 * 1024
    var maximumProofDescriptors = 4096

    func validated() throws -> Self {
        guard (0...4).contains(maximumSessions), (1...256).contains(maximumAttempts),
            (0...16 * 1024 * 1024).contains(maximumCanonicalBytes),
            (0...4096).contains(maximumProofDescriptors) else { throw AuthorityStateError.invalid }
        return self
    }
}

/// Observational accounting only; never a serialized boundary capability.
struct AuthorityValidationSessionReceipt: Equatable {
    let sessionID: String
    let episodeID: String
    let maximumAttempts: Int
    let attemptsUsed: Int
    let operationID: String
    let charged: EpisodeResources
}

struct AuthorityValidationCacheDiagnostics {
    let fullReplays: Int
    let sessionChecks: Int
    let cacheHits: Int
    let invalidations: Int
    /// Preparation of an events.payload read, including metadata length reads.
    let sourcePayloadStatements: Int
}

final class AuthorityValidationSession {
    let id: String
    let episodeID: String
    let maximumAttempts: Int
    let requestedAttempts: Int
    weak var lease: EpisodeLease?
    let leaseIdentity: ObjectIdentifier
    let fence: EpisodeSQLFence
    let bindingSHA256: String
    let generation: UInt64
    let resources: EpisodeResources
    var attemptsUsed = 0
    var finished = false

    init(id: String, episodeID: String, maximumAttempts: Int, requestedAttempts: Int, lease: EpisodeLease,
        fence: EpisodeSQLFence, bindingSHA256: String, generation: UInt64, resources: EpisodeResources) {
        self.id = id; self.episodeID = episodeID; self.maximumAttempts = maximumAttempts
        self.requestedAttempts = requestedAttempts; self.lease = lease
        self.leaseIdentity = ObjectIdentifier(lease); self.fence = fence
        self.bindingSHA256 = bindingSHA256; self.generation = generation; self.resources = resources
    }
    var receipt: AuthorityValidationSessionReceipt {
        AuthorityValidationSessionReceipt(sessionID: id, episodeID: episodeID,
            maximumAttempts: maximumAttempts, attemptsUsed: attemptsUsed, operationID: id, charged: resources)
    }
}

final class AuthorityValidationCacheEntry {
    var proof: AuthorityValidatedCurrent
    let externalVersion: Int
    let generation: UInt64
    var bindings: [Data: AuthorityEpisodeBinding]
    let bindingCanonicalBytes: Int
    let acceptedProofDescriptors: Int

    init(proof: AuthorityValidatedCurrent, externalVersion: Int, generation: UInt64,
        bindings: [Data: AuthorityEpisodeBinding]) throws {
        self.proof = proof; self.externalVersion = externalVersion
        self.generation = generation; self.bindings = bindings
        var bytes = 0, descriptors = 0
        for binding in bindings.values {
            bytes = try EpisodeResources(rawSourceBytes: bytes)
                .adding(EpisodeResources(rawSourceBytes: AuthorityStateKernel.canonical(binding).count)).rawSourceBytes
            if binding.acceptedSource != nil { descriptors += 1 }
        }
        bindingCanonicalBytes = bytes; acceptedProofDescriptors = descriptors
    }
    func checkLimits(_ limits: AuthorityValidationCacheLimits, candidate: AuthorityValidatedCurrent? = nil) throws {
        let proof = candidate ?? self.proof
        let bytes = try EpisodeResources(rawSourceBytes: proof.retainedCanonicalBytes)
            .adding(EpisodeResources(rawSourceBytes: bindingCanonicalBytes)).rawSourceBytes
        guard bytes <= limits.maximumCanonicalBytes,
            proof.sourceProofDescriptors + acceptedProofDescriptors <= limits.maximumProofDescriptors else {
            throw AuthorityStateError.limit
        }
    }
}

/// The SQLite authorizer sees direct kernel SQL as well as owner helpers. It
/// records bounded flags/counters only and never queries or reenters the owner.
final class AuthorityCacheWriteObserver {
    enum Manifest { case unknown, ledger, chunks, validatedClock }
    var manifest: Manifest = .unknown
    private(set) var generation: UInt64 = 0
    private(set) var accountingGeneration: UInt64 = 0
    private(set) var invalidations = 0
    private(set) var sourcePayloadStatements = 0

    func invalidate() {
        if generation < UInt64.max { generation += 1 }
        if invalidations < Int.max { invalidations += 1 }
    }
    var canCache: Bool { generation < UInt64.max }
    var canTrustAccounting: Bool { accountingGeneration < UInt64.max }
    private func invalidateAccounting() {
        if accountingGeneration < UInt64.max { accountingGeneration += 1 }
    }

    func install(on database: OpaquePointer) throws {
        let result = sqlite3_set_authorizer(database, { context, action, first, second, _, _ in
            guard let context else { return SQLITE_DENY }
            let observer = Unmanaged<AuthorityCacheWriteObserver>.fromOpaque(context).takeUnretainedValue()
            return observer.observe(action: action, table: first.map(String.init(cString:)), column: second.map(String.init(cString:)))
        }, Unmanaged.passUnretained(self).toOpaque())
        guard result == SQLITE_OK else { throw AuthorityStateError.integrity }
    }

    private static let writes: Set<Int32> = [SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE,
            SQLITE_CREATE_INDEX, SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_INDEX, SQLITE_CREATE_TEMP_TABLE,
            SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW, SQLITE_CREATE_TRIGGER, SQLITE_CREATE_VIEW,
            SQLITE_DROP_INDEX, SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_INDEX, SQLITE_DROP_TEMP_TABLE,
            SQLITE_DROP_TEMP_TRIGGER, SQLITE_DROP_TEMP_VIEW, SQLITE_DROP_TRIGGER, SQLITE_DROP_VIEW,
            SQLITE_ALTER_TABLE, SQLITE_REINDEX, SQLITE_ANALYZE, SQLITE_CREATE_VTABLE, SQLITE_DROP_VTABLE,
            SQLITE_ATTACH, SQLITE_DETACH]
    private static let accountingTables: Set<String> = ["episodes", "episode_resource_totals", "episode_work",
        "episode_request_snapshots", "episode_accounting", "episode_snapshot_references",
        "episode_settlement_receipts", "episode_adapter_quarantine", "episode_cleanup_budget", "episode_cleanup_receipts"]

    private func observe(action: Int32, table: String?, column: String?) -> Int32 {
        if action == SQLITE_READ, table == "events", column == "payload", sourcePayloadStatements < Int.max {
            sourcePayloadStatements += 1
        }
        if Self.writes.contains(action) {
            if !permits(action: action, table: table, column: column) {
                invalidate()
                if ![SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE].contains(action) ||
                    Self.accountingTables.contains(table ?? "") { invalidateAccounting() }
            }
        } else if action == SQLITE_PRAGMA, column != nil, !["table_info", "table_xinfo", "index_info", "index_xinfo", "index_list", "foreign_key_list", "foreign_key_check", "integrity_check", "quick_check"].contains(table ?? "") {
            // Read probes have no value argument. Unknown writable pragmas are
            // conservative invalidations, including schema/user_version changes.
            invalidate()
            invalidateAccounting()
        }
        return SQLITE_OK
    }

    private func permits(action: Int32, table: String?, column: String?) -> Bool {
        guard let table else { return false }
        switch manifest {
        case .unknown: return false
        case .ledger:
            if action == SQLITE_INSERT {
                return ["episodes", "episode_resource_totals", "episode_work", "episode_request_snapshots", "authority_work_bindings",
                    "episode_accounting", "episode_snapshot_references", "episode_settlement_receipts", "episode_adapter_quarantine", "episode_cleanup_budget", "episode_cleanup_receipts"].contains(table)
            }
            guard action == SQLITE_UPDATE, let column else { return false }
            switch table {
            case "episodes": return ["state", "terminal_reason", "revision", "last_ticks"].contains(column)
            case "episode_resource_totals": return ["charged", "held"].contains(column)
            case "episode_work": return ["state", "charged_json", "held_json", "observed_json", "armed_ticks",
                "ended_ticks", "receipt_id", "receipt_json", "receipt_digest", "adapter_violation", "recovered"].contains(column)
            case "episode_accounting": return ["work_count", "snapshot_bytes", "unknown_input_operations"].contains(column)
            case "episode_adapter_quarantine": return column == "witness_work_id"
            case "episode_cleanup_budget": return ["prepaid_rows", "consumed_rows", "pending_rows", "attempted_rows", "administrative_rows", "terminal_ticks"].contains(column)
            default: return false
            }
        case .chunks:
            let previous = manifest
            manifest = .ledger
            let ledger = permits(action: action, table: table, column: column)
            manifest = previous
            return ledger || (action == SQLITE_INSERT && table == "invocation_chunks") ||
                (action == SQLITE_UPDATE && table == "invocations" && ["chunk_count", "observed_bytes"].contains(column ?? ""))
        case .validatedClock:
            if action == SQLITE_UPDATE {
                return (table == "authority_control" && ["payload", "digest"].contains(column ?? "")) ||
                    (table == "authority_operations" && ["receipt_payload", "receipt_digest"].contains(column ?? ""))
            }
            if action == SQLITE_INSERT { return AuthorityStateKernel.tableNames.contains(table) }
            return action == SQLITE_DELETE && ["authority_tasks", "authority_bindings", "authority_policies"].contains(table)
        }
    }
}
