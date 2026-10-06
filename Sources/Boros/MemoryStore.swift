import Foundation
import CryptoKit
import Darwin
import CSQLite

enum MemoryRole: String, Codable { case human, assistant }
enum CaptureStatus: String, Codable { case complete, partial, failed, cancelled }
enum LexicalMatchMode { case allTerms, anyTerm }

enum InvocationTerminalReason: String, Codable {
    case completed, cancelled, upstreamIncomplete, transportFailure, captureFailure, admissionFailure, interrupted
}

/// Exact provider body is private evidence. HTTP headers and credentials are
/// excluded. This journal records received, committed visible-text chunks;
/// bytes never delivered by the provider cannot be recovered.
struct StoredInvocation: Identifiable, Codable {
    let id: String
    let conversationID: String
    let projectID: String
    let turnID: String
    let humanEventID: String
    let assistantEventID: String
    let providerIdentity: String
    let requestBody: Data
    let requestDigest: String
    let admissionJSON: Data?
    let usageJSON: Data?
    let createdAt: String
    let chunkCount: Int
    let observedBytes: Int
    let finalStatus: CaptureStatus?
    let terminalReason: InvocationTerminalReason?
    let finalizedAt: String?
    let recovered: Bool
    let episodeID: String?
    let episodeWorkID: String?
}

struct InvocationChunkReceipt {
    let sequence: Int
    let byteCount: Int
    let replayed: Bool
}

struct StoredConversation: Identifiable, Codable {
    let id: String
    let projectID: String
    let title: String
    let createdAt: String
    let updatedAt: String
}

struct MemoryEvent: Identifiable, Codable {
    let id: String
    let conversationID: String
    let projectID: String
    let role: MemoryRole
    let text: String
    let status: CaptureStatus
    let turnID: String
    let createdAt: String
    let digest: String
    let byteCount: Int
    var sourceTime: EventSourceTime? = nil
}

struct MemoryHit: Identifiable, Codable {
    var id: String { eventID }
    let eventID: String
    let conversationID: String
    let projectID: String
    let role: MemoryRole
    let status: CaptureStatus
    let createdAt: String
    let digest: String
    let totalBytes: Int
    let excerptOffset: Int
    let excerpt: String
    var sourceTime: EventSourceTime? = nil
    var preview: String { excerpt }
}

/// Payload-free source references for bounded asynchronous indexing. Sequence
/// is the store publication order, not an index coverage watermark.
struct MemorySourceReference: Identifiable, Codable, Equatable {
    var id: String { eventID }
    let sequence: Int
    let eventID: String
    let conversationID: String
    let projectID: String
    let role: MemoryRole
    let status: CaptureStatus
    let createdAt: String
    let digest: String
    let byteCount: Int
    var sourceTime: EventSourceTime? = nil
}

extension MemorySourceReference {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence && episodeIdentifierEqual(lhs.eventID, rhs.eventID)
            && episodeIdentifierEqual(lhs.conversationID, rhs.conversationID) && episodeIdentifierEqual(lhs.projectID, rhs.projectID)
            && lhs.role == rhs.role && lhs.status == rhs.status && episodeIdentifierEqual(lhs.createdAt, rhs.createdAt)
            && episodeIdentifierEqual(lhs.digest, rhs.digest) && lhs.byteCount == rhs.byteCount
            && (try? lhs.sourceTime?.canonicalData()) == (try? rhs.sourceTime?.canonicalData())
    }
}

/// Source IDs match SQLite BINARY identity. Swift Set<String> merges
/// canonically equivalent Unicode strings and cannot represent this contract.
struct ExactSourceIDs: Codable, Equatable, Sequence {
    private let keys: Set<Data>
    init(_ ids: [String]) { keys = Set(ids.map { Data($0.utf8) }) }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
    func contains(_ id: String) -> Bool { keys.contains(Data(id.utf8)) }
    func sorted() -> [String] { keys.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) } }
    func makeIterator() -> IndexingIterator<[String]> { sorted().makeIterator() }
    init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode([String].self)) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(sorted()) }
}

struct PayloadPage: Codable {
    let eventID: String
    let offset: Int
    let text: String
    let byteCount: Int
    let totalBytes: Int
    let nextOffset: Int?
    let digest: String
    let status: CaptureStatus
}

enum MemoryError: LocalizedError {
    case invalid(String)
    case missing(String)
    case conflict(String)
    case ownerBusy
    case database(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid memory operation: \(reason)"
        case .missing(let kind): return "The requested \(kind) does not exist."
        case .conflict(let reason): return "Memory capture conflict: \(reason)"
        case .ownerBusy: return "Another Boros process already owns this memory store."
        case .database(let reason): return "Memory database error: \(reason)"
        }
    }
}

/// Single-owner local store. All public database operations are serialized.
/// Payload capture is lossless UTF-8, bounded to 4 MiB per event or draft.
final class MemoryStore: @unchecked Sendable {
    static let maximumPayloadBytes = 4 * 1024 * 1024
    static let maximumPageBytes = 4096
    static let maximumStreamChunks = 65536
    static let maximumEpisodeWorkRecords = 100000
    // Every strict background recipe inspects >=1 metadata row, except the
    // fixed two-call probe. The six resource caps imply this row ceiling.
    static let maximumBackgroundWorkRecords = BackgroundIndexResources.developmentCaps.metadataRows
        + BackgroundIndexResources.developmentCaps.encoderCalls / 2
    static let maximumEpisodeSnapshotBytes = 64 * 1024 * 1024
    let directory: URL
    private var database: OpaquePointer?
    private var ownerFD: Int32 = -1
    private let mutex = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var activeSQLFence: EpisodeSQLFence?
    private let authorityValidationCheckpoint: ((String) throws -> Void)?
    private let authorityCacheLimits: AuthorityValidationCacheLimits
    private let authorityCacheCheckpoint: ((String, OpaquePointer) throws -> Void)?
    private let episodeAccountingCheckpoint: ((String, OpaquePointer) throws -> Void)?
    private var accountingExternalVersion: Int?
    private var accountingWriteGeneration: UInt64?
    private var accountingBootstrapping = true
    private let automaticallyDrainEpisodeCleanup: Bool
    private let episodeCleanupCheckpoint: ((String, OpaquePointer) throws -> Void)?
    private let episodeCleanupQueue = DispatchQueue(label: "boros.episode-terminal-cleanup")
    private var scheduledEpisodeCleanup = Set<Data>()
    private let authorityCacheWrites = AuthorityCacheWriteObserver()
    private var authorityCache: AuthorityValidationCacheEntry?
    private var authoritySessions: [Data: AuthorityValidationSession] = [:]
    private var authoritySessionOrder: [Data] = []
    private var authorityBoundaryDepth = 0
    private var authorityFullReplays = 0
    private var authoritySessionChecks = 0
    private var authorityCacheHits = 0
    private var claimedBackgroundReaders = Set<Data>()
    private var completedBackgroundSeals = Set<Data>()
    private var completedBackgroundChunkReads = Set<Data>()
    private let backgroundDiagnosticsLock = NSLock()
    private var backgroundPayloadPages = 0
    private var backgroundMaterializedBytes = 0

    init(directory: URL, episodeMigrationCheckpoint: ((String) throws -> Void)? = nil,
        authorityValidationCheckpoint: ((String) throws -> Void)? = nil,
        authorityCacheLimits: AuthorityValidationCacheLimits = .defaults,
        authorityCacheCheckpoint: ((String, OpaquePointer) throws -> Void)? = nil,
        episodeAccountingCheckpoint: ((String, OpaquePointer) throws -> Void)? = nil,
        automaticallyDrainEpisodeCleanup: Bool = true,
        episodeCleanupCheckpoint: ((String, OpaquePointer) throws -> Void)? = nil) throws {
        self.directory = directory.standardizedFileURL
        self.authorityValidationCheckpoint = authorityValidationCheckpoint
        self.authorityCacheLimits = try authorityCacheLimits.validated()
        self.authorityCacheCheckpoint = authorityCacheCheckpoint
        self.episodeAccountingCheckpoint = episodeAccountingCheckpoint
        self.automaticallyDrainEpisodeCleanup = automaticallyDrainEpisodeCleanup
        self.episodeCleanupCheckpoint = episodeCleanupCheckpoint
        do {
            try Self.prepareDirectory(self.directory)
            let lockPath = self.directory.appendingPathComponent("owner.lock").path
            ownerFD = try Self.openPrivateFile(lockPath)
            guard flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else { throw MemoryError.ownerBusy }
            let path = self.directory.appendingPathComponent("memory.sqlite3").path
            let descriptor = try Self.openPrivateFile(path)
            close(descriptor)
            try secureSidecars()
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw databaseError()
            }
            sqlite3_busy_timeout(database, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA temp_store=MEMORY")
            let version = try scalarInteger("PRAGMA user_version")
            guard (0...10).contains(version) else { throw MemoryError.invalid("unsupported database schema version") }
            if version == 7, let database { try AuthoritySchemaSeven.validate(database: database) }
            if version == 8, let database {
                try transaction {
                    try AuthoritySchemaEight.validate(database: database)
                    try Self.validateEpisodeJournal(database: database)
                }
            }
            if version == 9, let database {
                try transaction {
                    try AuthoritySchemaEight.validate(database: database, additionalStatements: AuthoritySchemaNine.cleanupStatements)
                    try Self.validateEpisodeJournal(database: database)
                }
            }
            if let database {
                if version < 10 { try SourceTimeSchema.requireAbsent(database: database) }
                else {
                    try AuthoritySchemaEight.validate(database: database, additionalStatements: EpisodeTerminalCleanupJournal.schemaStatements + SourceTimeSchema.schemaStatements)
                    try SourceTimeSchema.validate(database: database)
                }
            }
            if version < 9 {
                let names = (EpisodeTerminalCleanupJournal.tableNames + ["episode_cleanup_pending"]).map { "'" + $0 + "'" }.joined(separator: ",")
                guard try query("SELECT name FROM sqlite_schema WHERE name IN (" + names + ") OR tbl_name IN (" + names + ")", map: { string($0, 0) }).isEmpty else {
                    throw MemoryError.database("historical schema contains terminal cleanup accounting")
                }
            }
            if version < 8 {
                let names = EpisodeAccountingJournal.tableNames.map { "'" + $0 + "'" }.joined(separator: ",")
                guard try query("SELECT name FROM sqlite_schema WHERE name IN (" + names + ") OR tbl_name IN (" + names + ")", map: { string($0, 0) }).isEmpty else {
                    throw MemoryError.database("historical schema contains an accounting projection")
                }
            }
            if version >= 5 {
                guard let database else { throw MemoryError.database("closed owner") }
                try BackgroundIndexJournal.validate(database: database)
            } else {
                let existingBackground = try query("SELECT name FROM sqlite_master WHERE name IN ('background_index_windows','background_index_work','background_index_active_window','background_index_work_window','background_index_adapter_violation')") { string($0, 0) }
                guard existingBackground.isEmpty else { throw MemoryError.database("historical schema contains a background inventory") }
            }
            if version >= 6 {
                guard let database else { throw MemoryError.database("closed owner") }
                try AuthorityStateJournal.validate(database: database)
                if version >= 7 { try AuthorityBindingJournal.validate(database: database) }
            } else {
                let existingAuthority = try query("SELECT name FROM sqlite_master WHERE name LIKE 'authority_%'") { string($0, 0) }
                guard existingAuthority.isEmpty else { throw MemoryError.database("historical schema contains an authority inventory") }
            }
            if (3...7).contains(version), let database {
                try transaction { try Self.validateEpisodeJournal(database: database) }
            }
            // Foreign keys must be disabled outside the replacement transaction.
            // Children retain REFERENCES episodes while that parent is rebuilt.
            if version == 3 {
                guard let database else { throw MemoryError.database("closed owner") }
                try Self.validateEpisodeJournal(database: database)
                try execute("PRAGMA foreign_keys=OFF")
            }
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS conversations (
                      id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
                      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS events (
                      sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                      conversation_id TEXT NOT NULL REFERENCES conversations(id), project_id TEXT NOT NULL,
                      role TEXT NOT NULL CHECK(role IN ('human','assistant')),
                      status TEXT NOT NULL CHECK(status IN ('complete','partial','failed','cancelled')),
                      turn_id TEXT NOT NULL, created_at TEXT NOT NULL, digest TEXT NOT NULL,
                      byte_count INTEGER NOT NULL CHECK(byte_count >= 0 AND byte_count <= 4194304),
                      payload BLOB NOT NULL CHECK(length(payload) = byte_count)
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS event_conversation ON events(conversation_id, sequence)")
                try execute("CREATE INDEX IF NOT EXISTS event_project ON events(project_id, sequence)")
                try execute("CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(text, content='')")
                try execute("CREATE TABLE IF NOT EXISTS drafts (conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), payload BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS invocations (
                      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                      project_id TEXT NOT NULL, turn_id TEXT NOT NULL,
                      human_event_id TEXT NOT NULL REFERENCES events(id), assistant_event_id TEXT NOT NULL UNIQUE,
                      provider_identity TEXT NOT NULL, request_body BLOB NOT NULL,
                      request_digest TEXT NOT NULL, admission_json BLOB NOT NULL DEFAULT X'',
                      admission_digest TEXT NOT NULL DEFAULT '', usage_json BLOB NOT NULL DEFAULT X'',
                      usage_digest TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
                      chunk_count INTEGER NOT NULL DEFAULT 0 CHECK(chunk_count >= 0 AND chunk_count <= 65536),
                      observed_bytes INTEGER NOT NULL DEFAULT 0 CHECK(observed_bytes >= 0 AND observed_bytes <= 4194304),
                      final_status TEXT NOT NULL DEFAULT '' CHECK(final_status IN ('','complete','partial','failed','cancelled')),
                      terminal_reason TEXT NOT NULL DEFAULT '' CHECK(terminal_reason IN ('','completed','cancelled','upstreamIncomplete','transportFailure','captureFailure','admissionFailure','interrupted')),
                      finalized_at TEXT NOT NULL DEFAULT '', recovered INTEGER NOT NULL DEFAULT 0 CHECK(recovered IN (0,1)),
                      CHECK(length(request_body) > 0 AND length(request_body) <= 4194304),
                      CHECK((final_status = '' AND terminal_reason = '' AND finalized_at = '') OR
                            (final_status != '' AND terminal_reason != '' AND finalized_at != ''))
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS invocation_chunks (
                      invocation_id TEXT NOT NULL REFERENCES invocations(id),
                      chunk_sequence INTEGER NOT NULL CHECK(chunk_sequence >= 0 AND chunk_sequence < 65536),
                      byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 4194304),
                      digest TEXT NOT NULL, payload BLOB NOT NULL CHECK(length(payload) = byte_count),
                      PRIMARY KEY(invocation_id, chunk_sequence)
                    ) WITHOUT ROWID
                    """)
                if version == 3 { try migrateEpisodeSchemaThree(checkpoint: episodeMigrationCheckpoint) }
                try createEpisodeSchema()
                try createBackgroundIndexSchema()
                guard let database else { throw MemoryError.database("closed owner") }
                try AuthorityStateKernel.install(database: database, ownerID: "local-owner:\(geteuid())")
                try AuthorityBindings.install(database: database)
                if version < 7 { try AuthorityBindingJournal.classifyLegacy(database: database) }
                try EpisodeAccountingJournal.install(database: database)
                if version < 8 { try EpisodeAccountingJournal.backfill(database: database) }
                try EpisodeTerminalCleanupJournal.install(database: database)
                if version < 9 { try EpisodeTerminalCleanupJournal.backfill(database: database) }
                let violations = try query("PRAGMA foreign_key_check") { string($0, 0) }
                guard violations.isEmpty else { throw MemoryError.database("episode migration foreign-key failure") }
                if version < 10 { try SourceTimeSchema.install(database: database) }
                try execute("PRAGMA user_version=10")
                if version == 3 { try episodeMigrationCheckpoint?("beforeCommit") }
            }
            try execute("PRAGMA foreign_keys=ON")
            try transaction {
                guard let database else { throw MemoryError.database("closed owner") }
                try AuthorityStateKernel.advanceStartup(database: database)
            }
            // The exclusive process lock is already held. Publish interrupted
            // attempts before any caller can read history or start a request.
            try recoverInterruptedEpisodes()
            try recoverPendingEpisodeCleanup()
            try recoverInterruptedInvocations()
            try recoverInterruptedBackgroundWork()
            try secureSidecars()
            // Reconstruct authoritative ledger metadata under one write fence.
            // Never silently repair a current projection after corruption.
            try transaction {
                guard let database else { throw MemoryError.database("closed owner") }
                try AuthoritySchemaEight.validate(database: database, additionalStatements: EpisodeTerminalCleanupJournal.schemaStatements + SourceTimeSchema.schemaStatements)
                try SourceTimeSchema.validate(database: database)
                try Self.validateEpisodeJournal(database: database)
                accountingExternalVersion = try scalarInteger("PRAGMA data_version")
                accountingWriteGeneration = authorityCacheWrites.accountingGeneration
                accountingBootstrapping = false
            }
            if let database { try authorityCacheWrites.install(on: database) }
        } catch {
            if let database { sqlite3_close(database); self.database = nil }
            if ownerFD >= 0 { close(ownerFD); ownerFD = -1 }
            throw error
        }
    }

    deinit {
        if let database { sqlite3_set_authorizer(database, nil, nil); sqlite3_close(database) }
        if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD) }
    }

    /// Internal state foundation only. No GUI, CLI, ingestion or model path
    /// activates policy/task mutations until shared control gates are wired.
    func authorityStateSnapshot(now: Int64? = nil) throws -> AuthorityStateSnapshot {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard let database else { throw MemoryError.database("closed owner") }
            if let now {
                try transaction { try AuthorityStateKernel.advanceTime(database: database, now: now) }
            }
            return try AuthorityStateKernel.snapshot(database: database)
        }
    }

    func applyAuthorityOperation(request: AuthorityOperationRequest, authority: AuthorityContext,
                                 now: Int64) throws -> AuthorityOperationReceipt {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard let database else { throw MemoryError.database("closed owner") }
            try AuthorityStateKernel.validateAuthority(database: database, authority: authority)
            // Expiry survives a rejected mutation. Both commits share the
            // owner lock, so no handoff can interleave between them.
            try transaction { try AuthorityStateKernel.advanceTime(database: database, now: now) }
            return try transaction {
                try AuthorityStateKernel.apply(database: database, request: request, authority: authority, now: now)
            }
        }
    }

    /// Internal constructors only. Legacy adapters cannot dispatch this managed
    /// work until the shared boundary protocol is wired into every consumer.
    func acceptManagedHumanRequest(conversationID: String, turnID: String, humanEventID: String,
        episodeID: String, requestID: String, text: String, limits: EpisodeLimits,
        authority: AuthorityContext, taskIntent: HumanTaskIntent = .retainOrCreate,
        clock: EpisodeClockSnapshot) throws -> ManagedAcceptance {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard let database else { throw MemoryError.database("closed owner") }
            try AuthorityStateKernel.validateAuthority(database: database, authority: authority)
            try AuthorityStateKernel.identifier(requestID)
            let intentSHA = try AuthorityBindings.taskIntentSHA256(taskIntent)
            let now = try authorityWallTime(clock)
            try transaction { try AuthorityStateKernel.advanceTime(database: database, now: now) }
            if let old = try findEpisode(episodeID) {
                guard let binding = try AuthorityBindingJournal.managedEpisode(database: database, id: episodeID),
                    episodeIdentifierEqual(binding.requestID, requestID), binding.taskIntentSHA256 == intentSHA,
                    episodeIdentifierEqual(binding.ownerID, authority.ownerID),
                    binding.authenticatedOrigin.rawValue == authority.origin.rawValue else { throw AuthorityStateError.conflict }
                let receipt = try acceptRequestAndBeginEpisodeCore(conversationID: conversationID, turnID: turnID,
                    humanEventID: humanEventID, episodeID: episodeID, text: text, limits: limits,
                    clock: clock, managedAuthority: authority, buildBinding: nil)
                guard episodeIdentifierEqual(old.id, receipt.id) else { throw AuthorityStateError.integrity }
                return ManagedAcceptance(episode: receipt, binding: binding)
            }
            let prior = try query("SELECT id FROM authority_episode_bindings WHERE json_extract(payload,'$.managed.requestID')=? COLLATE BINARY", [.text(requestID)]) { string($0, 0) }
            guard prior.isEmpty else { throw AuthorityStateError.conflict }
            let receipt = try acceptRequestAndBeginEpisodeCore(conversationID: conversationID, turnID: turnID,
                humanEventID: humanEventID, episodeID: episodeID, text: text, limits: limits, clock: clock,
                managedAuthority: authority) {
                var state = try AuthorityStateKernel.snapshot(database: database)
                let project = try self.conversation(conversationID).projectID
                let selected = state.bindings.first { episodeIdentifierEqual($0.conversationID, conversationID) }
                var operation: AuthorityOperationRequest?
                switch taskIntent {
                case .retainOrCreate:
                    if selected == nil {
                        operation = AuthorityOperationRequest(requestID: "authority-accept-task:" + UUID().uuidString.lowercased(),
                            expectedRevision: state.revision, operation: .taskNew, taskID: UUID().uuidString.lowercased(),
                            projectID: project, conversationID: conversationID)
                    }
                case .new(let id):
                    operation = AuthorityOperationRequest(requestID: "authority-accept-task:" + UUID().uuidString.lowercased(),
                        expectedRevision: state.revision, operation: .taskNew, taskID: id, projectID: project, conversationID: conversationID)
                case .select(let id, let revision):
                    operation = AuthorityOperationRequest(requestID: "authority-accept-task:" + UUID().uuidString.lowercased(),
                        expectedRevision: state.revision, operation: .taskSelect, taskID: id, projectID: project,
                        conversationID: conversationID, expectedTaskRevision: revision)
                }
                if let operation {
                    _ = try AuthorityStateKernel.apply(database: database, request: operation, authority: authority, now: now)
                    state = try AuthorityStateKernel.snapshot(database: database)
                }
                guard let selection = state.bindings.first(where: { episodeIdentifierEqual($0.conversationID, conversationID) }),
                    let task = state.tasks.first(where: { episodeIdentifierEqual($0.id, selection.taskID) }), task.state == .active,
                    episodeIdentifierEqual(task.projectID, project), try !state.resolvedPolicies(projectID: project, taskID: task.id).blocked,
                    let source = try self.sourceReference(eventID: humanEventID, projectID: project) else { throw AuthorityStateError.conflict }
                let anchor = try AuthorityStateJournal.latestImmutable(database: database)
                let origin = EpisodeOrigin.chat(conversationID: conversationID, turnID: turnID, humanEventID: humanEventID)
                return AuthorityEpisodeBinding(episodeID: episodeID, storeID: state.storeID, ownerID: state.ownerID,
                    startupReceiptID: anchor.startupReceiptID, controlReceiptID: anchor.receipt.requestID,
                    controlEpoch: state.controlEpoch, authorityRevision: state.revision, projectID: project,
                    conversationID: conversationID, requestID: requestID,
                    authenticatedOrigin: authority.origin == .humanHost ? .humanHost : .humanCLI,
                    taskID: task.id, taskRevision: task.revision,
                    policyReferences: try AuthorityBindings.policyReferences(state: state, projectID: project, taskID: task.id),
                    resolutionSHA256: try AuthorityBindings.resolutionSHA256(state: state, projectID: project, taskID: task.id),
                    originSHA256: try Self.episodeOriginDigest(projectID: project, originJSON: self.episodeJSON(origin)),
                    acceptedSource: source, taskIntentSHA256: intentSHA)
            }
            guard let binding = try AuthorityBindingJournal.managedEpisode(database: database, id: episodeID) else { throw AuthorityStateError.integrity }
            return ManagedAcceptance(episode: receipt, binding: binding)
        }
    }
    func acceptManagedLocalRead(episodeID: String, projectID: String, binding: EpisodeLocalReadBinding,
        limits: EpisodeLimits, authority: AuthorityContext, taskID: String? = nil,
        clock: EpisodeClockSnapshot) throws -> ManagedAcceptance {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard let database else { throw MemoryError.database("closed owner") }
            try AuthorityStateKernel.validateAuthority(database: database, authority: authority)
            let now = try authorityWallTime(clock)
            struct TaskScope: Encodable { let version = "authority-local-read-task-scope-v1"; let taskID: String? }
            let intentSHA = AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(TaskScope(taskID: taskID)))
            try transaction { try AuthorityStateKernel.advanceTime(database: database, now: now) }
            if try findEpisode(episodeID) != nil {
                guard let old = try AuthorityBindings.managedEpisode(database: database, id: episodeID),
                    old.taskIntentSHA256 == intentSHA, episodeIdentifierEqual(old.ownerID, authority.ownerID),
                    old.authenticatedOrigin.rawValue == authority.origin.rawValue else { throw AuthorityStateError.conflict }
                let receipt = try beginLocalReadEpisodeCore(episodeID: episodeID, projectID: projectID, binding: binding,
                    limits: limits, clock: clock, managedAuthority: nil, buildBinding: nil)
                return ManagedAcceptance(episode: receipt, binding: old)
            }
            let receipt = try beginLocalReadEpisodeCore(episodeID: episodeID, projectID: projectID, binding: binding,
                limits: limits, clock: clock, managedAuthority: authority) {
                let state = try AuthorityStateKernel.snapshot(database: database)
                let task = taskID.flatMap { id in state.tasks.first { episodeIdentifierEqual($0.id, id) } }
                if taskID != nil {
                    guard let task, task.state == .active, episodeIdentifierEqual(task.projectID, projectID) else { throw AuthorityStateError.conflict }
                }
                guard try !state.resolvedPolicies(projectID: projectID, taskID: taskID).blocked else { throw AuthorityStateError.conflict }
                let anchor = try AuthorityStateJournal.latestImmutable(database: database)
                return AuthorityEpisodeBinding(episodeID: episodeID, storeID: state.storeID, ownerID: state.ownerID,
                    startupReceiptID: anchor.startupReceiptID, controlReceiptID: anchor.receipt.requestID,
                    controlEpoch: state.controlEpoch, authorityRevision: state.revision, projectID: projectID,
                    requestID: binding.requestID, authenticatedOrigin: authority.origin == .humanHost ? .humanHost : .humanCLI,
                    taskID: taskID, taskRevision: task?.revision,
                    policyReferences: try AuthorityBindings.policyReferences(state: state, projectID: projectID, taskID: taskID),
                    resolutionSHA256: try AuthorityBindings.resolutionSHA256(state: state, projectID: projectID, taskID: taskID),
                    originSHA256: try Self.episodeOriginDigest(projectID: projectID, originJSON: self.episodeJSON(EpisodeOrigin.localRead(binding))),
                    taskIntentSHA256: intentSHA)
            }
            guard let result = try AuthorityBindings.managedEpisode(database: database, id: episodeID) else { throw AuthorityStateError.integrity }
            return ManagedAcceptance(episode: receipt, binding: result)
        }
    }
    func managedEpisodeBinding(id: String) throws -> AuthorityEpisodeBinding? {
        try locked { guard let database else { throw MemoryError.database("closed owner") }; return try AuthorityBindingJournal.managedEpisode(database: database, id: id) }
    }
    func prepareManagedWork(episodeID: String, request: EpisodeWorkRequest, route: AuthorityLocalRoute,
        dependencies: [AuthoritySourceDependency] = [], rendererProofSHA256: String? = nil,
        clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        try locked {
            guard let database, let episode = try AuthorityBindingJournal.managedEpisode(database: database, id: episodeID) else { throw AuthorityStateError.unauthorized }
            let encoded = EpisodeWorkRequest(id: request.id, parentID: request.parentID, kind: request.kind,
                resources: request.resources, adapterIdentity: request.adapterIdentity, snapshot: nil, inputTokensKnown: request.inputTokensKnown)
            let binding = AuthorityWorkBinding(workID: request.id, episodeID: episodeID,
                episodeBindingSHA256: AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(episode)),
                requestSHA256: Self.digest(try episodeJSON(encoded)), snapshotSHA256: request.snapshot.map(Self.digest),
                localRoute: route, rendererProofSHA256: rendererProofSHA256, sourceDependencies: dependencies)
            return try reserveEpisodeWorkCore(episodeID: episodeID, request: request, clock: clock, authorityBinding: binding)
        }
    }
    /// Conservative full-replay recipe for the dormant managed path. Every
    /// inspection phase is durably charged before its body runs. No public
    /// lease dispatch funds this validator; accounting stays owner-internal.
    func validateManagedAuthority(episodeID: String, clock: EpisodeClockSnapshot) throws -> AuthorityValidationReceipt {
        try validateManagedAuthorityCore(episodeID: episodeID, clock: clock).receipt
    }
    private func validateManagedAuthorityCore(episodeID: String, clock: EpisodeClockSnapshot,
        progress: AuthorityValidationProgress? = nil) throws -> (receipt: AuthorityValidationReceipt,
        proof: AuthorityValidatedCurrent, binding: AuthorityEpisodeBinding, externalVersion: Int) {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            let initialGeneration = authorityCacheWrites.generation
            guard let database else { throw MemoryError.database("closed owner") }
            var operations: [String] = [], charged = EpisodeResources.zero
            func phase<T>(_ name: String, _ resources: EpisodeResources, _ body: () throws -> T) throws -> T {
                let result = try self.authorityValidationPhase(episodeID: episodeID, name: name, resources: resources, clock: clock, body)
                operations.append(result.1.id); charged = try charged.adding(resources)
                return result.0
            }
            // The first bounded recipe covers metadata enumeration and SQLite
            // schema/control probes, including unknown/corrupted cardinalities.
            let maximumRows = AuthorityStateKernel.maximumOperations + 3 * AuthorityStateKernel.maximumRecords + 256
            let metadata = try phase("metadata", EpisodeResources(memoryOperations: 1, metadataRows: maximumRows)) {
                let version = try self.scalarInteger("PRAGMA data_version")
                let operations = try AuthorityStateKernel.rows(database, "SELECT count(*),coalesce(sum(length(CAST(request_payload AS BLOB))),0),coalesce(sum(length(CAST(receipt_payload AS BLOB))),0),coalesce(sum(CASE WHEN (request_payload IS NOT NULL AND typeof(request_payload)!='blob') OR typeof(receipt_payload)!='blob' THEN 1 ELSE 0 END),0) FROM authority_operations")[0]
                guard operations[0].integer <= AuthorityStateKernel.maximumOperations, operations[3].integer == 0 else { throw AuthorityStateError.limit }
                var bytes = try EpisodeResources(rawSourceBytes: operations[1].integer).adding(EpisodeResources(rawSourceBytes: operations[2].integer)).rawSourceBytes
                var records = operations[0].integer
                guard bytes >= 0, bytes <= AuthorityStateKernel.maximumJournalBytes else { throw AuthorityStateError.limit }
                let control = try AuthorityStateKernel.rows(database, "SELECT length(CAST(payload AS BLOB)),typeof(payload) FROM authority_control WHERE id=1")
                guard control.count == 1, control[0][0].integer > 0, control[0][0].integer <= MemoryStore.maximumPayloadBytes, control[0][1].string == "blob" else { throw AuthorityStateError.integrity }
                for table in ["authority_tasks", "authority_bindings", "authority_policies"] {
                    let row = try AuthorityStateKernel.rows(database, "SELECT count(*),coalesce(sum(length(CAST(payload AS BLOB))),0),coalesce(sum(CASE WHEN typeof(payload)!='blob' THEN 1 ELSE 0 END),0) FROM " + table)[0]
                    guard row[0].integer <= AuthorityStateKernel.maximumRecords, row[1].integer >= 0,
                        row[1].integer <= AuthorityStateKernel.maximumJournalBytes, row[2].integer == 0 else { throw AuthorityStateError.limit }
                    bytes = try EpisodeResources(rawSourceBytes: bytes).adding(EpisodeResources(rawSourceBytes: row[1].integer)).rawSourceBytes
                    records += row[0].integer
                }
                let tail = try AuthorityStateKernel.rows(database, "SELECT length(CAST(receipt_payload AS BLOB)),typeof(receipt_payload) FROM authority_operations ORDER BY sequence DESC LIMIT 1")
                guard tail.count == 1, tail[0][0].integer > 0, tail[0][0].integer <= MemoryStore.maximumPayloadBytes, tail[0][1].string == "blob" else { throw AuthorityStateError.integrity }
                return (version, operations[0].integer, operations[1].integer, bytes, control[0][0].integer, records, tail[0][0].integer)
            }
            let sourceIDs: [String] = try phase("journal-descriptors",
                EpisodeResources(memoryOperations: 1, rawSourceBytes: metadata.2, metadataRows: metadata.1)) {
                return try self.transaction {
                    guard try self.scalarInteger("PRAGMA data_version") == metadata.0 else { throw AuthorityStateError.staleRevision }
                    var definitions: [Data: AuthorityPolicyDefinition] = [:], ids: [String] = []
                    try AuthorityBindings.visit(database: database, sql: "SELECT request_payload FROM authority_operations WHERE request_payload IS NOT NULL ORDER BY sequence") { row in
                        guard let bytes = row[0].bytes else { throw AuthorityStateError.integrity }
                        let request = try AuthorityStateKernel.decode(AuthorityOperationRequest.self, bytes)
                        if let definition = request.policy, let policyID = request.policyID {
                            guard definition.sources.count <= 16 else { throw AuthorityStateError.limit }
                            definitions[Data(policyID.utf8)] = definition
                            ids += definition.sources.map(\.eventID)
                        } else if request.operation == .policyActivate, let policyID = request.policyID {
                            guard let definition = definitions[Data(policyID.utf8)] else { throw AuthorityStateError.integrity }
                            ids += definition.sources.map(\.eventID)
                        }
                    }
                    guard ids.count <= 16 * AuthorityStateKernel.maximumOperations else { throw AuthorityStateError.limit }
                    return ids
                }
            }
            let proofBytes = try phase("source-metadata",
                EpisodeResources(memoryOperations: 1, metadataRows: sourceIDs.count + 2)) {
                var bytes = 0
                for id in sourceIDs {
                    let row = try AuthorityStateKernel.rows(database, "SELECT length(CAST(payload AS BLOB)),byte_count,typeof(payload) FROM events WHERE id=?", [.text(id)])
                    guard row.count == 1, row[0][0].integer == row[0][1].integer, row[0][0].integer >= 0,
                        row[0][0].integer <= MemoryStore.maximumPayloadBytes, row[0][2].string == "blob" else { throw AuthorityStateError.integrity }
                    bytes = try EpisodeResources(rawSourceBytes: bytes).adding(EpisodeResources(rawSourceBytes: row[0][0].integer)).rawSourceBytes
                }
                guard let binding = try AuthorityBindings.managedEpisode(database: database, id: episodeID) else { throw AuthorityStateError.unauthorized }
                var acceptedBytes = 0
                if let accepted = binding.acceptedSource {
                    let row = try AuthorityStateKernel.rows(database, "SELECT length(CAST(payload AS BLOB)),byte_count,typeof(payload) FROM events WHERE id=?", [.text(accepted.eventID)])
                    guard row.count == 1, row[0][0].integer == row[0][1].integer, row[0][0].integer == accepted.byteCount, row[0][2].string == "blob" else { throw AuthorityStateError.integrity }
                    acceptedBytes = accepted.byteCount
                }
                return (bytes, acceptedBytes)
            }
            // Retain the conservative two-pass replay ceiling. The validated
            // checkpoint now reuses one complete proof; extra control reads are
            // covered separately. SQLite data_version fences the planned sizes
            // against another connection before any original payload is read.
            let passes = try EpisodeResources(rawSourceBytes: metadata.3).adding(EpisodeResources(rawSourceBytes: proofBytes.0))
            var replay = try passes.adding(passes)
            // Temporal status/revision changes can grow each policy's JSON;
            // bound that growth and the clock/integer widths before charging.
            let controlCeiling = min(MemoryStore.maximumPayloadBytes, metadata.4 + 2 * AuthorityStateKernel.maximumRecords + 64)
            let extraRaw = 4 * controlCeiling + proofBytes.1 + metadata.6
            let replayRows = 2 * (metadata.5 + sourceIDs.count + metadata.1 + 128) + 8
            replay = try replay.adding(EpisodeResources(memoryOperations: 1, rawSourceBytes: extraRaw, metadataRows: replayRows))
            let validated = try phase("replay-and-clock", replay) {
                let now = try self.authorityWallTime(clock)
                let captured = try self.transaction {
                    guard try self.scalarInteger("PRAGMA data_version") == metadata.0,
                        let binding = try AuthorityBindings.managedEpisode(database: database, id: episodeID) else { throw AuthorityStateError.staleRevision }
                    guard authorityCacheWrites.generation == initialGeneration else { throw AuthorityStateError.staleRevision }
                    if authorityFullReplays < Int.max { authorityFullReplays += 1 }
                    let proof = try AuthorityStateJournal.validatedCurrent(database: database, progress: progress)
                    let result = try withAuthorityCacheWrites(.validatedClock) {
                        try AuthorityStateKernel.advanceTimeValidated(database: database, proof: proof,
                            expectedControlSHA256: proof.controlSHA256, expectedTailReceiptSHA256: proof.tailReceiptSHA256,
                            now: now, progress: progress)
                    }
                    guard authorityCacheWrites.generation == initialGeneration else { throw AuthorityStateError.staleRevision }
                    return (proof.anchor, binding, result.proof)
                }
                // Expiry remains committed if the accepted binding is stale.
                return try self.transaction {
                    guard try self.scalarInteger("PRAGMA data_version") == metadata.0,
                        let binding = try AuthorityBindings.managedEpisode(database: database, id: episodeID) else { throw AuthorityStateError.staleRevision }
                    guard try AuthorityStateKernel.canonical(binding) == AuthorityStateKernel.canonical(captured.1) else { throw AuthorityStateError.staleRevision }
                    guard authorityCacheWrites.generation == initialGeneration else { throw AuthorityStateError.staleRevision }
                    let state = try AuthorityStateKernel.snapshot(database: database)
                    guard episodeIdentifierEqual(state.storeID, binding.storeID), episodeIdentifierEqual(state.ownerID, binding.ownerID),
                        state.controlEpoch == binding.controlEpoch, state.revision == binding.authorityRevision,
                        try AuthorityBindings.resolutionSHA256(state: state, projectID: binding.projectID, taskID: binding.taskID) == binding.resolutionSHA256,
                        try !state.resolvedPolicies(projectID: binding.projectID, taskID: binding.taskID).blocked else { throw AuthorityStateError.staleRevision }
                    try AuthorityBindings.validateEpisode(database: database, binding: binding, verifySourceBytes: true, historical: captured.0)
                    try progress?()
                    return (state, binding, captured.2)
                }
            }
            let live = try episodeReceipt(id: episodeID, clock: clock)
            guard live.state == .active else {
                if live.state == .deadlineExceeded { throw EpisodeBudgetError.deadlineExceeded }
                if live.state == .budgetExceeded { throw EpisodeBudgetError.exhausted }
                throw EpisodeBudgetError.inactive
            }
            let receipt = AuthorityValidationReceipt(episodeID: episodeID,
                episodeBindingSHA256: AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(validated.1)),
                controlEpoch: validated.0.controlEpoch, authorityRevision: validated.0.revision, operationIDs: operations, charged: charged)
            guard authorityCacheWrites.generation == initialGeneration else { throw AuthorityStateError.staleRevision }
            return (receipt, validated.2, validated.1, metadata.0)
        }
    }
    /// Internal funded eligibility checks. Complete work/dependency proofs and
    /// actual consumer dispatch/delivery contracts remain separate prerequisites.
    func beginAuthorityValidationSession(lease: EpisodeLease, sessionID: String,
        maximumAttempts: Int = 256) throws -> AuthorityValidationSessionReceipt {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard lease.isOwned(by: self) else { throw AuthorityStateError.unauthorized }
            try AuthorityStateKernel.identifier(sessionID)
            guard (1...authorityCacheLimits.maximumAttempts).contains(maximumAttempts) else { throw AuthorityStateError.invalid }
            let key = Data(sessionID.utf8)
            if let old = authoritySessions[key] {
                guard episodeIdentifierEqual(old.episodeID, lease.episodeID), old.requestedAttempts == maximumAttempts else { throw EpisodeBudgetError.conflict }
                return old.receipt
            }
            guard authoritySessions.values.filter({ !$0.finished }).count < authorityCacheLimits.maximumSessions,
                let database else { throw AuthorityStateError.limit }
            // A lost/evicted/restarted private counter cannot be reconstructed
            // from a durable charge as fresh permission.
            guard try query("SELECT id FROM episode_work WHERE id=?", [.text(sessionID)], map: { string($0, 0) }).isEmpty else { throw AuthorityStateError.unauthorized }
            let fence = try lease.progressGuard()
            let clock = try lease.clockSnapshot()
            let entry: AuthorityValidationCacheEntry
            let cached = authorityCache
            if let cached, cached.generation == authorityCacheWrites.generation,
                cached.externalVersion == (try scalarInteger("PRAGMA data_version")),
                cached.bindings[Data(lease.episodeID.utf8)] != nil {
                entry = cached
            } else {
                let validated = try withAuthorityCacheSQLFence(fence) {
                    try validateManagedAuthorityCore(episodeID: lease.episodeID, clock: clock) {
                        try self.authorityCacheCheckpoint?("cold-replay-progress", database)
                        if let reason = fence.interruption() { throw reason }
                    }
                }
                var bindings: [Data: AuthorityEpisodeBinding] = [:]
                if let cached, cached.generation == authorityCacheWrites.generation,
                    cached.externalVersion == validated.externalVersion,
                    cached.proof.current.controlEpoch == validated.proof.current.controlEpoch,
                    cached.proof.current.revision == validated.proof.current.revision {
                    bindings = cached.bindings
                }
                bindings[Data(lease.episodeID.utf8)] = validated.binding
                entry = try AuthorityValidationCacheEntry(proof: validated.proof, externalVersion: validated.externalVersion,
                    generation: authorityCacheWrites.generation, bindings: bindings)
                try entry.checkLimits(authorityCacheLimits)
                guard authorityCacheWrites.canCache else { throw AuthorityStateError.limit }
                authorityCache = entry
            }
            guard let binding = entry.bindings[Data(lease.episodeID.utf8)] else { throw AuthorityStateError.integrity }
            // Pure clock work is prepaid for every permitted hit. Actual policy
            // transitions need their own additional funded maintenance phase.
            let ceiling = min(Self.maximumPayloadBytes, entry.proof.currentBytes + 2 * AuthorityStateKernel.maximumRecords + 64)
            let rawPerAttempt = 4 * ceiling + entry.proof.tailReceiptBytes + 64
            let metadataPerAttempt = 64
            let original = try episodeReceipt(id: lease.episodeID, clock: clock)
            let remaining = try original.limits.resources.subtracting(original.charged).subtracting(original.held)
            let count = min(maximumAttempts, remaining.rawSourceBytes / rawPerAttempt,
                max(0, remaining.metadataRows - 128) / metadataPerAttempt)
            guard count > 0, remaining.memoryOperations >= 1 else { throw EpisodeBudgetError.exhausted }
            let resources = EpisodeResources(memoryOperations: 1, rawSourceBytes: rawPerAttempt * count,
                metadataRows: metadataPerAttempt * count + 128)
            let bindingSHA = AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(binding))
            struct Descriptor: Encodable {
                let version = "authority-validation-session-v1"
                let episodeID: String
                let bindingSHA256: String
                let requestedAttempts: Int
                let maximumAttempts: Int
            }
            let identity = "authority-validation-session-v1"
            let request = EpisodeWorkRequest(id: sessionID, parentID: nil, kind: .authorityValidation,
                resources: resources, adapterIdentity: identity,
                snapshot: try AuthorityStateKernel.canonical(Descriptor(episodeID: lease.episodeID,
                    bindingSHA256: bindingSHA, requestedAttempts: maximumAttempts, maximumAttempts: count)), inputTokensKnown: true)
            try withAuthorityCacheWrites(.ledger) {
                let work = try prepareManagedWork(episodeID: lease.episodeID, request: request,
                    route: AuthorityLocalRoute(kind: .localMemory, identity: identity), clock: clock)
                _ = try armEpisodeWorkLocked(episodeID: lease.episodeID, operationID: work.id,
                    expectedRevision: work.revision, clock: clock, managedValidation: true)
            }
            guard entry.generation == authorityCacheWrites.generation else { throw AuthorityStateError.staleRevision }
            let session = AuthorityValidationSession(id: sessionID, episodeID: lease.episodeID,
                maximumAttempts: count, requestedAttempts: maximumAttempts, lease: lease, fence: fence,
                bindingSHA256: bindingSHA, generation: entry.generation, resources: resources)
            authoritySessions[key] = session; authoritySessionOrder.append(key)
            trimAuthoritySessionTombstones()
            return session.receipt
        }
    }

    func authorityValidationSessionReceipt(sessionID: String) throws -> AuthorityValidationSessionReceipt {
        try locked {
            guard let session = authoritySessions[Data(sessionID.utf8)] else { throw AuthorityStateError.missing }
            return session.receipt
        }
    }

    func withAuthorityValidationSession<T>(sessionID: String, lease: EpisodeLease,
        _ body: () throws -> T) throws -> T {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard let session = authoritySessions[Data(sessionID.utf8)], !session.finished else { throw AuthorityStateError.unauthorized }
            guard session.attemptsUsed < session.maximumAttempts else { throw EpisodeBudgetError.exhausted }
            session.attemptsUsed += 1
            if authoritySessionChecks < Int.max { authoritySessionChecks += 1 }
            guard lease.isOwned(by: self), ObjectIdentifier(lease) == session.leaseIdentity,
                episodeIdentifierEqual(lease.episodeID, session.episodeID) else { throw AuthorityStateError.unauthorized }
            guard let database, let entry = authorityCache,
                entry.generation == session.generation, entry.generation == authorityCacheWrites.generation,
                entry.bindings[Data(session.episodeID.utf8)] != nil else { throw AuthorityStateError.staleRevision }
            if let reason = session.fence.interruption() { throw reason }
            try self.authorityCacheCheckpoint?("before-session-fence", database)
            if let reason = session.fence.interruption() { throw reason }
            let now = try authorityWallTime(lease.clockSnapshot())
            let due = entry.proof.nextTemporalBoundary.map { now >= $0 } ?? false
            // Clock changes commit before eligibility rejection or delivery.
            func advance() throws -> AuthorityValidatedClockResult {
                try withAuthorityCacheSQLFence(session.fence) {
                    try transaction {
                        try checkAuthoritySessionWitness(entry, database: database)
                        try checkAuthoritySessionLifecycle(session, lease: lease)
                        return try withAuthorityCacheWrites(.validatedClock) {
                            try AuthorityStateKernel.advanceTimeValidated(database: database, proof: entry.proof,
                                expectedControlSHA256: entry.proof.controlSHA256,
                                expectedTailReceiptSHA256: entry.proof.tailReceiptSHA256, now: now) {
                                if let reason = session.fence.interruption() { throw reason }
                            }
                        }
                    }
                }
            }
            let advanced: AuthorityValidatedClockResult
            if due {
                // Reserve before BEGIN IMMEDIATE and settle after the actual
                // maintenance transaction. Failure retains the funded charge.
                let rows = entry.proof.current.tasks.count + entry.proof.current.bindings.count + entry.proof.current.policies.count
                let resources = EpisodeResources(memoryOperations: 1, rawSourceBytes: 8 * Self.maximumPayloadBytes,
                    metadataRows: 2 * rows + 64)
                advanced = try withAuthorityCacheSQLFence(session.fence) {
                    try authorityValidationPhase(episodeID: session.episodeID, name: "cached-temporal-maintenance",
                        resources: resources, clock: lease.clockSnapshot(), advance).0
                }
            } else { advanced = try advance() }
            entry.proof = advanced.proof
            do { try entry.checkLimits(authorityCacheLimits) }
            catch { authorityCache = nil; authorityCacheWrites.invalidate(); throw error }
            if advanced.changed {
                authorityCache = nil; authorityCacheWrites.invalidate()
                try self.authorityCacheCheckpoint?("session-stale", database)
                throw AuthorityStateError.staleRevision
            }
            try self.authorityCacheCheckpoint?("pure-clock-advance", database)
            let accepted = try withAuthorityCacheSQLFence(session.fence) {
                try transaction {
                    try checkAuthoritySessionWitness(entry, database: database)
                    try checkAuthoritySessionLifecycle(session, lease: lease)
                    let proof = entry.proof
                    guard let binding = entry.bindings[Data(session.episodeID.utf8)],
                        binding.controlEpoch == proof.current.controlEpoch, binding.authorityRevision == proof.current.revision,
                        episodeIdentifierEqual(binding.controlReceiptID, proof.anchor.receipt.requestID),
                        episodeIdentifierEqual(binding.startupReceiptID, proof.anchor.startupReceiptID) else { throw AuthorityStateError.staleRevision }
                    try self.authorityCacheCheckpoint?("before-session-acceptance", database)
                    try checkAuthoritySessionWitness(entry, database: database)
                    if let reason = session.fence.interruption() { throw reason }
                    // Time can cross a policy boundary between the committed
                    // clock checkpoint and this acceptance fence. That newly
                    // due transition has no prepaid maintenance allowance;
                    // refuse acceptance so a separately funded check can run.
                    let acceptanceTime = try authorityWallTime(lease.clockSnapshot())
                    guard proof.nextTemporalBoundary.map({ acceptanceTime < $0 }) ?? true else {
                        throw AuthorityStateError.staleRevision
                    }
                    let refreshed = try withAuthorityCacheWrites(.validatedClock) {
                        try AuthorityStateKernel.advanceTimeValidated(database: database, proof: proof,
                            expectedControlSHA256: proof.controlSHA256,
                            expectedTailReceiptSHA256: proof.tailReceiptSHA256, now: acceptanceTime) {
                            if let reason = session.fence.interruption() { throw reason }
                        }
                    }
                    guard !refreshed.changed else { throw AuthorityStateError.staleRevision }
                    try entry.checkLimits(authorityCacheLimits, candidate: refreshed.proof)
                    authorityBoundaryDepth += 1
                    defer { authorityBoundaryDepth -= 1 }
                    if authorityCacheHits < Int.max { authorityCacheHits += 1 }
                    return (try body(), refreshed.proof)
                }
            }
            // A thrown callback or failed COMMIT cannot publish a rolled-back
            // clock proof as the next owner cache witness.
            entry.proof = accepted.1
            return accepted.0
        }
    }

    /// Prepare mandatory policy bytes from the paid owner-private proof. The
    /// render charge commits before the session's eligibility transaction;
    /// denial, rollback and a thrown renderer cannot refund that work. The
    /// returned artifact grants no dispatch or delivery permission.
    func renderManagedPolicy(sessionID: String, lease: EpisodeLease, hostInstructions: String,
        limits: AuthorityPolicyRenderLimits = .defaults) throws -> AuthorityFundedPolicyRendering {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            let limits = try limits.validated()
            guard hostInstructions.utf8.count <= limits.maximumSystemBytes else { throw AuthorityStateError.limit }
            guard lease.isOwned(by: self), let database, let entry = authorityCache,
                  let session = authoritySessions[Data(sessionID.utf8)], !session.finished,
                  ObjectIdentifier(lease) == session.leaseIdentity,
                  episodeIdentifierEqual(session.episodeID, lease.episodeID),
                  entry.generation == session.generation, entry.generation == authorityCacheWrites.generation,
                  let binding = entry.bindings[Data(lease.episodeID.utf8)] else { throw AuthorityStateError.unauthorized }
            // Sizing uses scalar lengths from already paid private proof, not
            // fresh source or journal reads. Cover resolution passes, JSON
            // escaping and the complete encoded result under original caps.
            let stateCeiling = min(Self.maximumPayloadBytes, entry.proof.currentBytes + 2 * AuthorityStateKernel.maximumRecords + 64)
            let policyRows = entry.proof.current.policies.count
            let selectedRows = min(policyRows, limits.maximumPolicies)
            let sourceRows = min(16 * selectedRows, limits.maximumSourceSpans)
            let resources = EpisodeResources(memoryOperations: 1,
                rawSourceBytes: 2 * stateCeiling + hostInstructions.utf8.count + 2 * limits.maximumSystemBytes + 2 * limits.maximumPolicyBytes,
                // Conservative logical visit ceiling includes resolution's
                // filters/groups/ranks and bounded ID sorting (<=4096 rows),
                // task/selection checks and selected record/span inspection.
                metadataRows: 64 * policyRows + 4 * entry.proof.current.tasks.count + 2 * entry.proof.current.bindings.count
                    + 2 * sourceRows + 4 * selectedRows + 256)
            let funded = try authorityValidationPhase(episodeID: lease.episodeID, name: AuthorityPolicyRenderer.version,
                resources: resources, clock: lease.clockSnapshot()) {
                try self.withAuthorityValidationSession(sessionID: sessionID, lease: lease) {
                    let rendering = try AuthorityPolicyRenderer.render(state: entry.proof.current, binding: binding,
                        hostInstructions: hostInstructions, limits: limits)
                    if let reason = session.fence.interruption() { throw reason }
                    try self.checkAuthoritySessionWitness(entry, database: database)
                    let now = try self.authorityWallTime(lease.clockSnapshot())
                    guard entry.proof.nextTemporalBoundary.map({ now < $0 }) ?? true else { throw AuthorityStateError.staleRevision }
                    return rendering
                }
            }
            _ = try lease.checkActive()
            return AuthorityFundedPolicyRendering(rendering: funded.0, operationID: funded.1.id, charged: resources)
        }
    }

    func finishAuthorityValidationSession(sessionID: String, lease: EpisodeLease) throws {
        try locked {
            guard authorityBoundaryDepth == 0 else { throw AuthorityValidationCacheError.reentrant }
            guard let session = authoritySessions[Data(sessionID.utf8)], lease.isOwned(by: self),
                episodeIdentifierEqual(lease.episodeID, session.episodeID) else { throw AuthorityStateError.unauthorized }
            if session.finished { return }
            _ = try settleEpisodeWork(episodeID: session.episodeID, operationID: session.id,
                settlement: EpisodeWorkSettlement(receiptID: UUID().uuidString.lowercased(), outcome: .completed,
                    observed: nil, evidence: nil), clock: lease.clockSnapshot())
            session.finished = true
            if !authoritySessions.values.contains(where: { !$0.finished && episodeIdentifierEqual($0.episodeID, session.episodeID) }) {
                authorityCache?.bindings.removeValue(forKey: Data(session.episodeID.utf8))
            }
            trimAuthoritySessionTombstones()
        }
    }

    func authorityValidationCacheDiagnostics() -> AuthorityValidationCacheDiagnostics {
        mutex.lock(); defer { mutex.unlock() }
        return AuthorityValidationCacheDiagnostics(fullReplays: authorityFullReplays, sessionChecks: authoritySessionChecks,
            cacheHits: authorityCacheHits, invalidations: authorityCacheWrites.invalidations,
            sourcePayloadStatements: authorityCacheWrites.sourcePayloadStatements)
    }

    private func checkAuthoritySessionWitness(_ entry: AuthorityValidationCacheEntry, database: OpaquePointer) throws {
        guard authorityCacheWrites.canCache, entry.generation == authorityCacheWrites.generation,
            try scalarInteger("PRAGMA data_version") == entry.externalVersion else {
            authorityCache = nil; authorityCacheWrites.invalidate()
            throw AuthorityStateError.staleRevision
        }
    }
    private func checkAuthoritySessionLifecycle(_ session: AuthorityValidationSession, lease: EpisodeLease) throws {
        guard let database else { throw AuthorityStateError.integrity }
        let clock = try lease.clockSnapshot(); try validateEpisodeClock(clock)
        let row = try AuthorityStateKernel.rows(database,
            "SELECT state,clock_domain,deadline_ticks,last_ticks FROM episodes WHERE id=?", [.text(session.episodeID)])
        guard row.count == 1 else { throw AuthorityStateError.integrity }
        if row[0][0].string == EpisodeState.deadlineExceeded.rawValue { throw EpisodeBudgetError.deadlineExceeded }
        if row[0][0].string == EpisodeState.budgetExceeded.rawValue { throw EpisodeBudgetError.exhausted }
        guard row[0][0].string == EpisodeState.active.rawValue else { throw EpisodeBudgetError.inactive }
        guard row[0][2].integer > 0, row[0][3].integer > 0,
            episodeIdentifierEqual(row[0][1].string, clock.domain), clock.continuousNanoseconds >= UInt64(row[0][3].integer) else { throw EpisodeBudgetError.clockUnavailable }
        guard clock.continuousNanoseconds < UInt64(row[0][2].integer) else { throw EpisodeBudgetError.deadlineExceeded }
        let work = try AuthorityStateKernel.rows(database, "SELECT state,episode_id FROM episode_work WHERE id=?", [.text(session.id)])
        guard work.count == 1, work[0][0].string == EpisodeWorkState.dispatchArmed.rawValue,
            episodeIdentifierEqual(work[0][1].string, session.episodeID) else { throw EpisodeBudgetError.inactive }
        try withAuthorityCacheWrites(.ledger) {
            try execute("UPDATE episodes SET last_ticks=? WHERE id=?", [.integer(Int(clock.continuousNanoseconds)), .text(session.episodeID)])
        }
    }
    private func withAuthorityCacheSQLFence<T>(_ fence: EpisodeSQLFence, _ body: () throws -> T) throws -> T {
        guard let database else { throw AuthorityStateError.integrity }
        let previous = activeSQLFence; activeSQLFence = fence
        sqlite3_busy_handler(database, { pointer, attempts in
            guard let pointer, attempts < 5000 else { return 0 }
            let fence = Unmanaged<EpisodeSQLFence>.fromOpaque(pointer).takeUnretainedValue()
            guard fence.interruption() == nil else { return 0 }
            usleep(1000)
            return 1
        }, Unmanaged.passUnretained(fence).toOpaque())
        defer { sqlite3_busy_timeout(database, 5000); activeSQLFence = previous }
        return try fence.perform(on: database, restoring: previous, body)
    }
    private func trimAuthoritySessionTombstones() {
        var finished = authoritySessionOrder.filter { authoritySessions[$0]?.finished == true }
        while finished.count > 64 {
            let key = finished.removeFirst(); authoritySessions.removeValue(forKey: key)
            authoritySessionOrder.removeAll { $0 == key }
        }
    }

    private func authorityValidationPhase<T>(episodeID: String, name: String, resources: EpisodeResources,
        clock: EpisodeClockSnapshot, _ body: () throws -> T) throws -> (T, EpisodeWorkRecord) {
        let identity = "authority-validation-v1:" + name
        let request = EpisodeWorkRequest(id: UUID().uuidString.lowercased(), parentID: nil, kind: .authorityValidation,
            resources: resources, adapterIdentity: identity, snapshot: nil, inputTokensKnown: true)
        let work = try withAuthorityCacheWrites(.ledger) {
            let work = try prepareManagedWork(episodeID: episodeID, request: request,
                route: AuthorityLocalRoute(kind: .localMemory, identity: identity), clock: clock)
            _ = try armEpisodeWorkLocked(episodeID: episodeID, operationID: work.id,
                expectedRevision: work.revision, clock: clock, managedValidation: true)
            return work
        }
        do {
            try authorityValidationCheckpoint?(name)
            let result = try body()
            let settled = try settleEpisodeWork(episodeID: episodeID, operationID: work.id,
                settlement: EpisodeWorkSettlement(receiptID: UUID().uuidString.lowercased(), outcome: .completed, observed: nil, evidence: nil), clock: clock)
            return (result, settled)
        } catch {
            _ = try? settleEpisodeWork(episodeID: episodeID, operationID: work.id,
                settlement: EpisodeWorkSettlement(receiptID: UUID().uuidString.lowercased(), outcome: .failedConfirmed, observed: nil, evidence: nil), clock: clock)
            throw error
        }
    }

    private func authorityWallTime(_ clock: EpisodeClockSnapshot) throws -> Int64 {
        try validateEpisodeClock(clock)
        let value = (clock.utc.timeIntervalSince1970 * 1000).rounded(.down)
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { throw AuthorityStateError.invalid }
        return Int64(value)
    }

    func withEpisodeSQLFence<T>(lease: EpisodeLease, _ body: () throws -> T) throws -> T {
        let fence = try lease.progressGuard()
        return try locked {
            guard let database else { throw MemoryError.database("closed owner") }
            let previous = activeSQLFence
            activeSQLFence = fence
            defer { activeSQLFence = previous }
            return try fence.perform(on: database, restoring: previous, body)
        }
    }

    func createConversation(projectID: String, title: String) throws -> StoredConversation {
        try locked {
            try validateIdentifier(projectID, name: "project ID")
            guard !title.isEmpty, title.utf8.count <= 1024 else { throw MemoryError.invalid("conversation title must contain 1–1024 UTF-8 bytes") }
            let now = Self.timestamp()
            let result = StoredConversation(id: UUID().uuidString, projectID: projectID, title: title, createdAt: now, updatedAt: now)
            try execute("INSERT INTO conversations VALUES (?, ?, ?, ?, ?)", [.text(result.id), .text(projectID), .text(title), .text(now), .text(now)])
            return result
        }
    }

    func conversationProjectID(conversationID: String) throws -> String {
        try locked { try conversation(conversationID).projectID }
    }

    func listConversations(projectID: String) throws -> [StoredConversation] {
        try locked {
            try validateIdentifier(projectID, name: "project ID")
            return try query("SELECT id, project_id, title, created_at, updated_at FROM conversations WHERE project_id=? ORDER BY updated_at DESC, id", [.text(projectID)]) { statement in
                StoredConversation(id: string(statement, 0), projectID: string(statement, 1), title: string(statement, 2), createdAt: string(statement, 3), updatedAt: string(statement, 4))
            }
        }
    }

    func events(conversationID: String) throws -> [MemoryEvent] {
        try locked {
            _ = try conversation(conversationID)
            return try query("SELECT id, conversation_id, project_id, role, status, turn_id, created_at, digest, byte_count, payload, source_time_json FROM events WHERE conversation_id=? ORDER BY sequence", [.text(conversationID)], map: event)
        }
    }

    /// Bounded newest events for model preparation, returned chronologically.
    /// Browsing the complete conversation uses events(conversationID:).
    func recentEvents(conversationID: String, excludingEventID: String? = nil, limit: Int, maximumBytes: Int? = nil) throws -> [MemoryEvent] {
        try locked {
            _ = try conversation(conversationID)
            guard limit > 0, limit <= 10000 else { throw MemoryError.invalid("recent history limit must be 1–10000") }
            var bindings: [Value] = [.text(conversationID)]
            var exclusion = ""
            if let excludingEventID {
                try validateIdentifier(excludingEventID, name: "excluded event ID")
                exclusion = " AND id != ?"
                bindings.append(.text(excludingEventID))
            }
            bindings.append(.integer(limit))
            if let maximumBytes {
                guard maximumBytes >= 0 else { throw MemoryError.invalid("recent payload byte budget must be nonnegative") }
                bindings.append(.integer(maximumBytes))
                // The window sees only row IDs and byte counts; payload BLOBs
                // are joined for the fitting recent suffix after that bound.
                let sql = "WITH recent AS (SELECT sequence,SUM(byte_count) OVER (ORDER BY sequence DESC ROWS UNBOUNDED PRECEDING) AS running_bytes FROM events WHERE conversation_id=?" + exclusion + " ORDER BY sequence DESC LIMIT ?) SELECT e.id,e.conversation_id,e.project_id,e.role,e.status,e.turn_id,e.created_at,e.digest,e.byte_count,e.payload,e.source_time_json FROM recent JOIN events e ON e.sequence=recent.sequence WHERE running_bytes<=? ORDER BY e.sequence"
                return try queryEvents(sql, bindings)
            }
            return try queryEvents("SELECT id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload,source_time_json FROM events WHERE conversation_id=?" + exclusion + " ORDER BY sequence DESC LIMIT ?", bindings).reversed()
        }
    }

    func eventCount(conversationID: String, excludingEventID: String? = nil) throws -> Int {
        try locked {
            _ = try conversation(conversationID)
            var bindings: [Value] = [.text(conversationID)]
            var exclusion = ""
            if let excludingEventID {
                try validateIdentifier(excludingEventID, name: "excluded event ID")
                exclusion = " AND id != ?"
                bindings.append(.text(excludingEventID))
            }
            return try query("SELECT count(*) FROM events WHERE conversation_id=?" + exclusion, bindings) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    func sourceFrontier(projectID: String) throws -> Int {
        try locked {
            try validateIdentifier(projectID, name: "project ID")
            return try query("SELECT coalesce(max(sequence),0) FROM events WHERE project_id=?", [.text(projectID)]) {
                Int(sqlite3_column_int64($0, 0))
            }.first ?? 0
        }
    }

    /// Source bytes are read separately using read(eventID:offset:length:).
    /// A fixed upper frontier prevents later publications changing a scan.
    func sourceManifest(projectID: String, afterSequence: Int, throughSequence: Int? = nil, limit: Int, originalDayRange: ClosedRange<String>? = nil) throws -> [MemorySourceReference] {
        try sourceManifest(projectID: projectID, afterSequence: afterSequence, throughSequence: throughSequence,
            limit: limit, excludingSourceIDs: ExactSourceIDs([]), originalDayRange: originalDayRange)
    }

    func sourceManifest(projectID: String, afterSequence: Int, throughSequence: Int? = nil, limit: Int,
                        excludingSourceIDs: ExactSourceIDs, originalDayRange: ClosedRange<String>? = nil) throws -> [MemorySourceReference] {
        try locked {
            try validateIdentifier(projectID, name: "project ID")
            guard afterSequence >= 0, (throughSequence ?? 0) >= 0, (1...1000).contains(limit) else {
                throw MemoryError.invalid("source manifest requires nonnegative bounds and 1–1000 rows")
            }
            guard excludingSourceIDs.count <= 10000 else { throw MemoryError.invalid("source manifest excludes at most 10000 sources") }
            for id in excludingSourceIDs { try validateIdentifier(id, name: "excluded source ID") }
            var bindings: [Value] = [.text(projectID), .integer(afterSequence)]
            var upperBound = ""
            if let throughSequence { upperBound = " AND sequence<=?"; bindings.append(.integer(throughSequence)) }
            let exclusions = excludingSourceIDs.isEmpty ? "" : " AND id NOT IN (SELECT value FROM json_each(?))"
            if !excludingSourceIDs.isEmpty { bindings.append(.text(String(decoding: try JSONEncoder().encode(excludingSourceIDs.sorted()), as: UTF8.self))) }
            var sourceDays = ""
            if let originalDayRange {
                try SourceTimeSchema.validateDay(originalDayRange.lowerBound)
                try SourceTimeSchema.validateDay(originalDayRange.upperBound)
                sourceDays = " AND substr(json_extract(source_time_json,'$.value'),1,10)>=? AND substr(json_extract(source_time_json,'$.value'),1,10)<=?"
                bindings += [.text(originalDayRange.lowerBound), .text(originalDayRange.upperBound)]
            }
            bindings.append(.integer(limit))
            return try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count,source_time_json FROM events WHERE project_id=? AND sequence>?" + upperBound + exclusions + sourceDays + " ORDER BY sequence LIMIT ?", bindings, map: sourceReference)
        }
    }

    func sourceReference(eventID: String, projectID: String) throws -> MemorySourceReference? {
        try locked {
            try validateIdentifier(eventID, name: "event ID")
            try validateIdentifier(projectID, name: "project ID")
            return try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count,source_time_json FROM events WHERE id=? AND project_id=?",
                [.text(eventID), .text(projectID)], map: sourceReference).first
        }
    }

    /// One immediate publication in the same conversation. Human boundaries
    /// and excluded sources remain visible to the caller; this never skips
    /// forward to locate an assistant or assumes an event-ID naming scheme.
    func followingSourceReference(anchor: MemorySourceReference, throughSequence: Int) throws -> MemorySourceReference? {
        try locked {
            guard anchor.sequence > 0, throughSequence >= anchor.sequence,
                  try sourceReference(eventID: anchor.eventID, projectID: anchor.projectID) == anchor else {
                throw MemoryError.conflict("neighbor anchor metadata changed")
            }
            let next = try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count,source_time_json FROM events WHERE conversation_id=? AND sequence>? AND sequence<=? ORDER BY sequence LIMIT 1",
                [.text(anchor.conversationID), .integer(anchor.sequence), .integer(throughSequence)], map: sourceReference).first
            guard next == nil || episodeIdentifierEqual(next?.projectID, anchor.projectID) else {
                throw MemoryError.database("neighbor source scope mismatch")
            }
            return next
        }
    }

    /// One immediate prior publication in the same conversation. The caller
    /// decides whether its role and exclusions permit expansion; never skip
    /// a publication to manufacture a human/assistant relationship.
    func precedingSourceReference(anchor: MemorySourceReference, throughSequence: Int) throws -> MemorySourceReference? {
        try locked {
            guard anchor.sequence > 0, throughSequence >= anchor.sequence,
                  try sourceReference(eventID: anchor.eventID, projectID: anchor.projectID) == anchor else {
                throw MemoryError.conflict("neighbor anchor metadata changed")
            }
            let previous = try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count,source_time_json FROM events WHERE conversation_id=? AND sequence<? AND sequence<=? ORDER BY sequence DESC LIMIT 1",
                [.text(anchor.conversationID), .integer(anchor.sequence), .integer(throughSequence)], map: sourceReference).first
            guard previous == nil || episodeIdentifierEqual(previous?.projectID, anchor.projectID) else {
                throw MemoryError.database("neighbor source scope mismatch")
            }
            return previous
        }
    }

    /// Metadata-only FTS candidates; callers reserve full-source work before loading any payload.
    /// Compatibility for callers that already supply Swift-set identity.
    func lexicalCandidateReferences(query: String, projectID: String, limit: Int = 8, matching: LexicalMatchMode = .allTerms, throughSequence: Int? = nil, excludingEventIDs: Set<String> = []) throws -> [MemorySourceReference] {
        try lexicalCandidateReferences(query: query, projectID: projectID, limit: limit, matching: matching, throughSequence: throughSequence, excludingSourceIDs: ExactSourceIDs(Array(excludingEventIDs)))
    }

    func lexicalCandidateReferences(query: String, projectID: String, limit: Int = 8, matching: LexicalMatchMode = .allTerms, throughSequence: Int? = nil, excludingSourceIDs excludingEventIDs: ExactSourceIDs) throws -> [MemorySourceReference] {
        try locked {
            try validateSearch(query: query, projectID: projectID, limit: limit)
            if let throughSequence, throughSequence < 0 { throw MemoryError.invalid("source frontier must be nonnegative") }
            guard excludingEventIDs.count <= 10000 else { throw MemoryError.invalid("search excludes at most 10000 sources") }
            for id in excludingEventIDs { try validateIdentifier(id, name: "excluded source ID") }
            let terms = Self.searchTerms(query)
            guard terms.count <= 32 else { throw MemoryError.invalid("lexical search accepts at most 32 terms") }
            guard !terms.isEmpty else { return [] }
            let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: matching == .allTerms ? " AND " : " OR ")
            let upper = throughSequence == nil ? "" : " AND e.sequence<=?"
            let exclusion = excludingEventIDs.isEmpty ? "" : " AND e.id NOT IN (SELECT value FROM json_each(?))"
            var bindings: [Value] = [.text(expression), .text(projectID)]
            if let throughSequence { bindings.append(.integer(throughSequence)) }
            if !excludingEventIDs.isEmpty { bindings.append(.text(String(decoding: try JSONEncoder().encode(excludingEventIDs.sorted()), as: UTF8.self))) }
            bindings.append(.integer(limit))
            // Keep FTS as the outer loop. An ordinary JOIN can choose the project
            // index first and evaluate the same FTS match once per scoped event.
            return try self.query("SELECT e.sequence,e.id,e.conversation_id,e.project_id,e.role,e.status,e.created_at,e.digest,e.byte_count,e.source_time_json FROM event_fts CROSS JOIN events e ON e.sequence=event_fts.rowid WHERE event_fts MATCH ? AND e.project_id=?" + upper + exclusion + " ORDER BY bm25(event_fts),e.sequence DESC LIMIT ?", bindings, map: sourceReference)
        }
    }
    func loadCandidate(reference: MemorySourceReference) throws -> MemoryEvent {
        try locked {
            guard try sourceReference(eventID: reference.eventID, projectID: reference.projectID) == reference else { throw MemoryError.conflict("source candidate metadata changed") }
            guard let event = try findEvent(reference.eventID), episodeIdentifierEqual(event.projectID, reference.projectID),
                  episodeIdentifierEqual(event.conversationID, reference.conversationID), event.digest == reference.digest, event.byteCount == reference.byteCount else { throw MemoryError.database("source candidate failed integrity verification") }
            return event
        }
    }
    func recentSourceReferences(conversationID: String, excludingEventID: String? = nil, limit: Int, maximumBytes: Int? = nil) throws -> [MemorySourceReference] {
        try locked {
            _ = try conversation(conversationID)
            guard limit > 0, limit <= 10000 else { throw MemoryError.invalid("recent history limit must be 1–10000") }
            var bindings: [Value] = [.text(conversationID)], exclusion = ""
            if let excludingEventID {
                try validateIdentifier(excludingEventID, name: "excluded event ID")
                exclusion = " AND id != ?"; bindings.append(.text(excludingEventID))
            }
            bindings.append(.integer(limit))
            if let maximumBytes {
                guard maximumBytes >= 0 else { throw MemoryError.invalid("recent payload byte budget must be nonnegative") }
                bindings.append(.integer(maximumBytes))
                return try query("WITH recent AS (SELECT sequence,SUM(byte_count) OVER (ORDER BY sequence DESC ROWS UNBOUNDED PRECEDING) AS running_bytes FROM events WHERE conversation_id=?" + exclusion + " ORDER BY sequence DESC LIMIT ?) SELECT e.sequence,e.id,e.conversation_id,e.project_id,e.role,e.status,e.created_at,e.digest,e.byte_count,e.source_time_json FROM recent JOIN events e ON e.sequence=recent.sequence WHERE running_bytes<=? ORDER BY e.sequence", bindings, map: sourceReference)
            }
            return try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count,source_time_json FROM events WHERE conversation_id=?" + exclusion + " ORDER BY sequence DESC LIMIT ?", bindings, map: sourceReference).reversed()
        }
    }

    private func sourceReference(_ statement: OpaquePointer) throws -> MemorySourceReference {
        guard let role = MemoryRole(rawValue: string(statement, 4)), let status = CaptureStatus(rawValue: string(statement, 5)) else {
            throw MemoryError.database("invalid source metadata")
        }
        return MemorySourceReference(sequence: Int(sqlite3_column_int64(statement, 0)), eventID: string(statement, 1),
            conversationID: string(statement, 2), projectID: string(statement, 3), role: role, status: status,
            createdAt: string(statement, 6), digest: string(statement, 7), byteCount: Int(sqlite3_column_int64(statement, 8)),
            sourceTime: try SourceTimeSchema.decodeColumn(statement, index: 9))
    }

    /// Repeating an identical stable event ID returns the original event. Any
    /// changed role, scope, turn, completion status, or payload is a conflict.
    func append(conversationID: String, role: MemoryRole, text: String, status: CaptureStatus, turnID: String, eventID: String, sourceTime: EventSourceTime? = nil) throws -> MemoryEvent {
        try locked {
            try validateIdentifier(turnID, name: "turn ID")
            try validateIdentifier(eventID, name: "event ID")
            let payload = try validatePayload(text)
            let digest = Self.digest(payload)
            let sourceTime = try sourceTime?.validated()
            let scope = try conversation(conversationID)
            guard try query("SELECT id FROM invocations WHERE assistant_event_id=?", [.text(eventID)], map: { string($0, 0) }).isEmpty else {
                throw MemoryError.conflict("assistant event ID belongs to a durable invocation")
            }
            if let existing = try findEvent(eventID) {
                guard episodeIdentifierEqual(existing.conversationID, conversationID), episodeIdentifierEqual(existing.projectID, scope.projectID),
                      existing.role == role, existing.status == status, episodeIdentifierEqual(existing.turnID, turnID),
                      existing.digest == digest, episodeIdentifierEqual(existing.text, text),
                      (try existing.sourceTime?.canonicalData()) == (try sourceTime?.canonicalData()) else {
                    throw MemoryError.conflict("event ID was already used for different content or metadata")
                }
                return existing
            }
            let now = Self.timestamp()
            let result = MemoryEvent(id: eventID, conversationID: conversationID, projectID: scope.projectID, role: role, text: text, status: status, turnID: turnID, createdAt: now, digest: digest, byteCount: payload.count, sourceTime: sourceTime)
            try transaction {
                try insertEvent(result, payload: payload)
            }
            return result
        }
    }

    /// Inspect complete original-input provenance only after durable funding.
    /// This legacy preparation receipt grants no managed boundary permission.
    func prepareAnswerInputProof(lease: EpisodeLease, requestBody: Data, providerIdentity: String,
        admissionJSON: Data, answerRequest: EpisodeWorkRequest, hostInstructions: String) throws -> AnswerInputProofReceipt {
        try locked {
            guard lease.isOwned(by: self), authorityBoundaryDepth == 0, let database else { throw AuthorityStateError.unauthorized }
            let resources = try AuthorityInputProofJournal.resources(bodyBytes: requestBody.count, admissionBytes: admissionJSON.count)
            let descriptor = try AuthorityInputProofJournal.funding(episodeID: lease.episodeID,
                body: requestBody, admission: admissionJSON, host: hostInstructions)
            let work = try lease.prepare(kind: .sourceRead, resources: resources,
                adapterIdentity: AuthorityInputProofJournal.version, snapshot: AuthorityStateKernel.canonical(descriptor))
            let submitted = try lease.dispatch(work, start: {})
            do {
                let proof = try withEpisodeSQLFence(lease: lease) {
                    try transaction {
                        try AuthorityInputProofJournal.derive(database: database, funding: descriptor,
                            body: requestBody, provider: providerIdentity, admission: admissionJSON, answerRequest: answerRequest)
                    }
                }
                let evidence = try AuthorityStateKernel.canonical(proof)
                _ = try lease.settle(submitted, outcome: .completed, observed: resources, evidence: evidence)
                _ = try lease.checkActive()
                return AnswerInputProofReceipt(operationID: submitted.id, digest: Self.digest(evidence), proof: proof)
            } catch {
                _ = try? lease.settle(submitted, outcome: .failedConfirmed, observed: resources)
                throw error
            }
        }
    }

    /// Commit the exact credential-free provider request before dispatch.
    /// Identical replay returns the existing attempt and never dispatches it.
    func beginInvocation(invocationID: String, conversationID: String, turnID: String, humanEventID: String, assistantEventID: String, providerIdentity: String, requestBody: Data, admissionJSON: Data? = nil, episodeID: String? = nil, episodeWorkID: String? = nil) throws -> StoredInvocation {
        try locked {
            for (value, name) in [(invocationID, "invocation ID"), (turnID, "turn ID"), (humanEventID, "human event ID"), (assistantEventID, "assistant event ID")] {
                try validateIdentifier(value, name: name)
            }
            try validateProviderIdentity(providerIdentity)
            try validateRequestBody(requestBody)
            if let admissionJSON {
                guard admissionJSON.count <= 65536 else { throw MemoryError.invalid("admission receipt exceeds the metadata limit") }
                try validateRequestBody(admissionJSON)
            }
            let scope = try conversation(conversationID)
            if let existing = try findInvocation(invocationID) {
                guard episodeIdentifierEqual(existing.conversationID, conversationID), episodeIdentifierEqual(existing.projectID, scope.projectID),
                      episodeIdentifierEqual(existing.turnID, turnID), episodeIdentifierEqual(existing.humanEventID, humanEventID),
                      episodeIdentifierEqual(existing.assistantEventID, assistantEventID), episodeIdentifierEqual(existing.providerIdentity, providerIdentity),
                      existing.requestBody == requestBody, existing.admissionJSON == admissionJSON,
                      episodeIdentifierEqual(existing.episodeID, episodeID), episodeIdentifierEqual(existing.episodeWorkID, episodeWorkID) else {
                    throw MemoryError.conflict("invocation ID was already used for different request or scope")
                }
                if let episodeID = existing.episodeID {
                    guard let episode = try findEpisode(episodeID), !episode.origin.isLocalRead else { throw EpisodeBudgetError.invalid }
                }
                return existing
            }
            guard (episodeID == nil) == (episodeWorkID == nil) else { throw EpisodeBudgetError.invalid }
            if let episodeID, let episodeWorkID {
                try validateIdentifier(episodeID, name: "episode ID"); try validateIdentifier(episodeWorkID, name: "episode work ID")
                guard let episode = try findEpisode(episodeID), episode.state == .active, !episode.origin.isLocalRead,
                      episodeIdentifierEqual(episode.conversationID, conversationID), episodeIdentifierEqual(episode.projectID, scope.projectID),
                      episodeIdentifierEqual(episode.turnID, turnID), episodeIdentifierEqual(episode.humanEventID, humanEventID),
                      let work = try findEpisodeWork(episodeWorkID), episodeIdentifierEqual(work.episodeID, episodeID),
                      work.state == .prepared || work.state == .dispatchArmed,
                      work.request.kind == .answer || work.request.kind == .nativeInference,
                      work.request.snapshot == requestBody else { throw EpisodeBudgetError.inactive }
            }
            guard let human = try findEvent(humanEventID), human.role == .human,
                  human.status == .complete, episodeIdentifierEqual(human.conversationID, conversationID),
                  episodeIdentifierEqual(human.projectID, scope.projectID), episodeIdentifierEqual(human.turnID, turnID) else {
                throw MemoryError.invalid("invocation requires its committed complete human event in the same turn and scope")
            }
            guard !episodeIdentifierEqual(humanEventID, assistantEventID), try findEvent(assistantEventID) == nil,
                  try query("SELECT id FROM invocations WHERE assistant_event_id=?", [.text(assistantEventID)], map: { string($0, 0) }).isEmpty else {
                throw MemoryError.conflict("assistant event ID was already used or reserved")
            }
            try transaction {
                try execute("INSERT INTO invocations (id,conversation_id,project_id,turn_id,human_event_id,assistant_event_id,provider_identity,request_body,request_digest,admission_json,admission_digest,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [.text(invocationID), .text(conversationID), .text(scope.projectID), .text(turnID), .text(humanEventID), .text(assistantEventID), .text(providerIdentity), .blob(requestBody), .text(Self.digest(requestBody)), .blob(admissionJSON ?? Data()), .text(admissionJSON.map(Self.digest) ?? ""), .text(Self.timestamp())])
                if let episodeID, let episodeWorkID {
                    try execute("UPDATE invocations SET episode_id=?,episode_work_id=? WHERE id=?", [.text(episodeID), .text(episodeWorkID), .text(invocationID)])
                }
                guard let database else { throw MemoryError.database("store is closed") }
                // Assembly already metered and verified the original ranges.
                // This gate checks retained provenance and actual request
                // bytes without performing an additional raw-source read.
                try ContextComponentJournal.validate(database: database, invocationID: invocationID, verifySourceRanges: false)
                if let episodeWorkID, try AuthorityBindingJournal.managedWork(database: database, id: episodeWorkID) != nil {
                    try AuthorityBindingJournal.insertManagedInvocation(database: database, id: invocationID)
                } else { try AuthorityBindingJournal.insertLegacyInvocation(database: database, id: invocationID) }
            }
            guard let result = try findInvocation(invocationID) else { throw MemoryError.database("invocation publication failed") }
            return result
        }
    }

    func invocation(id: String) throws -> StoredInvocation? {
        try locked {
            try validateIdentifier(id, name: "invocation ID")
            return try findInvocation(id)
        }
    }

    /// Call this before making received text visible. Sequence starts at zero,
    /// grows contiguously, and identifies exactly one nonempty UTF-8 chunk.
    /// An identical retry is safe even after finalization; new late chunks fail.
    func appendInvocationChunk(invocationID: String, sequence: Int, text: String) throws -> InvocationChunkReceipt {
        try authorityChunkLocked {
            try validateIdentifier(invocationID, name: "invocation ID")
            guard (0..<Self.maximumStreamChunks).contains(sequence) else { throw MemoryError.invalid("stream chunk sequence is outside the supported limit") }
            let payload = try validatePayload(text)
            guard !payload.isEmpty else { throw MemoryError.invalid("stream chunks must contain received text") }
            let digest = Self.digest(payload)
            return try transaction {
                let rows = try query("SELECT chunk_count,observed_bytes,final_status FROM invocations WHERE id=?", [.text(invocationID)]) {
                    (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)), string($0, 2))
                }
                guard let (count, bytes, status) = rows.first else { throw MemoryError.missing("invocation") }
                let existing = try query("SELECT byte_count,digest,payload FROM invocation_chunks WHERE invocation_id=? AND chunk_sequence=?", [.text(invocationID), .integer(sequence)]) {
                    (Int(sqlite3_column_int64($0, 0)), string($0, 1), blob($0, 2))
                }.first
                if let (storedBytes, storedDigest, storedPayload) = existing {
                    guard storedBytes == payload.count, storedDigest == digest, storedPayload == payload else {
                        throw MemoryError.conflict("stream chunk sequence was already used for different text")
                    }
                    return InvocationChunkReceipt(sequence: sequence, byteCount: payload.count, replayed: true)
                }
                guard status.isEmpty else { throw MemoryError.conflict("invocation is already terminal") }
                if let episodeID = try findInvocation(invocationID)?.episodeID {
                    guard let episode = try findEpisode(episodeID), episode.state == .active else { throw EpisodeBudgetError.inactive }
                    if episode.clockDomain.hasPrefix("mach-continuous-v1:") {
                        let current = try SystemEpisodeClock().now()
                        guard episodeIdentifierEqual(current.domain, episode.clockDomain) else { throw EpisodeBudgetError.clockUnavailable }
                        guard current.continuousNanoseconds < episode.deadlineNanoseconds else { throw EpisodeBudgetError.deadlineExceeded }
                    }
                }
                guard sequence == count else { throw MemoryError.conflict("stream chunks must arrive in contiguous order") }
                guard bytes <= Self.maximumPayloadBytes - payload.count else { throw MemoryError.invalid("stream exceeds the 4 MiB capture limit; previous chunks remain committed") }
                try execute("INSERT INTO invocation_chunks (invocation_id,chunk_sequence,byte_count,digest,payload) VALUES (?,?,?,?,?)", [.text(invocationID), .integer(sequence), .integer(payload.count), .text(digest), .blob(payload)])
                try execute("UPDATE invocations SET chunk_count=?,observed_bytes=? WHERE id=?", [.integer(count + 1), .integer(bytes + payload.count), .text(invocationID)])
                return InvocationChunkReceipt(sequence: sequence, byteCount: payload.count, replayed: false)
            }
        }
    }

    /// Atomically publish all committed chunks as one immutable assistant
    /// event and its FTS row, then terminalize the origin invocation.
    func finalizeInvocation(invocationID: String, status: CaptureStatus, reason: InvocationTerminalReason? = nil, usageJSON: Data? = nil) throws -> MemoryEvent {
        try locked {
            try validateIdentifier(invocationID, name: "invocation ID")
            let reason = reason ?? Self.defaultTerminalReason(status)
            try validateTerminal(status: status, reason: reason)
            if let usageJSON {
                guard usageJSON.count <= 65536 else { throw MemoryError.invalid("usage receipt exceeds the metadata limit") }
                try validateRequestBody(usageJSON)
            }
            return try transaction {
                guard let attempt = try findInvocation(invocationID) else { throw MemoryError.missing("invocation") }
                return try publishInvocation(attempt, status: status, reason: reason, recovered: false, usageJSON: usageJSON)
            }
        }
    }

    /// Queries are converted to quoted lexical terms, never interpolated into
    /// SQL or accepted as raw FTS syntax. Manual search requires all terms;
    /// automatic context retrieval may explicitly request any-term matching.
    /// Compatibility for callers that already supply Swift-set identity.
    func search(query: String, projectID: String, limit: Int = 8, matching: LexicalMatchMode = .allTerms, throughSequence: Int? = nil, excludingEventIDs: Set<String> = []) throws -> [MemoryHit] {
        try search(query: query, projectID: projectID, limit: limit, matching: matching, throughSequence: throughSequence, excludingSourceIDs: ExactSourceIDs(Array(excludingEventIDs)))
    }

    func search(query: String, projectID: String, limit: Int = 8, matching: LexicalMatchMode = .allTerms, throughSequence: Int? = nil, excludingSourceIDs excludingEventIDs: ExactSourceIDs) throws -> [MemoryHit] {
        try locked {
            try validateSearch(query: query, projectID: projectID, limit: limit)
            if let throughSequence, throughSequence < 0 { throw MemoryError.invalid("source frontier must be nonnegative") }
            guard excludingEventIDs.count <= 10000 else { throw MemoryError.invalid("search excludes at most 10000 sources") }
            for id in excludingEventIDs { try validateIdentifier(id, name: "excluded source ID") }
            let terms = Self.searchTerms(query)
            guard terms.count <= 32 else { throw MemoryError.invalid("lexical search accepts at most 32 terms") }
            guard !terms.isEmpty else { return [] }
            let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: matching == .allTerms ? " AND " : " OR ")
            let upperBound = throughSequence == nil ? "" : " AND e.sequence<=?"
            let exclusions = excludingEventIDs.isEmpty ? "" : " AND e.id NOT IN (SELECT value FROM json_each(?))"
            // See lexicalCandidateReferences: CROSS JOIN prevents repeated FTS
            // evaluation under the project-index loop without changing ranking.
            let sql = "SELECT e.id,e.conversation_id,e.project_id,e.role,e.status,e.turn_id,e.created_at,e.digest,e.byte_count,e.payload,e.source_time_json FROM event_fts CROSS JOIN events e ON e.sequence=event_fts.rowid WHERE event_fts MATCH ? AND e.project_id=?" + upperBound + exclusions + " ORDER BY bm25(event_fts),e.sequence DESC LIMIT ?"
            var bindings: [Value] = [.text(expression), .text(projectID)]
            if let throughSequence { bindings.append(.integer(throughSequence)) }
            if !excludingEventIDs.isEmpty { bindings.append(.text(String(decoding: try JSONEncoder().encode(excludingEventIDs.sorted()), as: UTF8.self))) }
            bindings.append(.integer(limit))
            return try queryEvents(sql, bindings).map { Self.hit($0, terms: terms) }
        }
    }

    /// Literal search is case-sensitive over original UTF-8 payload bytes.
    /// Compatibility for callers that already supply Swift-set identity.
    func literalSearch(query: String, projectID: String, limit: Int = 8, throughSequence: Int? = nil, excludingEventIDs: Set<String> = []) throws -> [MemoryHit] {
        try literalSearch(query: query, projectID: projectID, limit: limit, throughSequence: throughSequence, excludingSourceIDs: ExactSourceIDs(Array(excludingEventIDs)))
    }

    func literalSearch(query: String, projectID: String, limit: Int = 8, throughSequence: Int? = nil, excludingSourceIDs excludingEventIDs: ExactSourceIDs) throws -> [MemoryHit] {
        try locked {
            try validateSearch(query: query, projectID: projectID, limit: limit)
            if let throughSequence, throughSequence < 0 { throw MemoryError.invalid("source frontier must be nonnegative") }
            guard excludingEventIDs.count <= 10000 else { throw MemoryError.invalid("search excludes at most 10000 sources") }
            for id in excludingEventIDs { try validateIdentifier(id, name: "excluded source ID") }
            guard !query.isEmpty else { return [] }
            let upperBound = throughSequence == nil ? "" : " AND sequence<=?"
            let exclusions = excludingEventIDs.isEmpty ? "" : " AND id NOT IN (SELECT value FROM json_each(?))"
            let sql = "SELECT id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload,source_time_json FROM events WHERE project_id=? AND instr(payload,?) > 0" + upperBound + exclusions + " ORDER BY sequence DESC LIMIT ?"
            var bindings: [Value] = [.text(projectID), .blob(Data(query.utf8))]
            if let throughSequence { bindings.append(.integer(throughSequence)) }
            if !excludingEventIDs.isEmpty { bindings.append(.text(String(decoding: try JSONEncoder().encode(excludingEventIDs.sorted()), as: UTF8.self))) }
            bindings.append(.integer(limit))
            return try queryEvents(sql, bindings).map { Self.hit($0, terms: [query], literal: true) }
        }
    }

    /// Offset and length are UTF-8 bytes. Offset must be a Unicode scalar
    /// boundary. The end is shortened to a boundary, with no replacement text.
    /// This method reads only the requested BLOB page, never the whole payload.
    func read(eventID: String, offset: Int, length: Int) throws -> PayloadPage {
        try locked {
            guard offset >= 0, length > 0, length <= Self.maximumPageBytes else { throw MemoryError.invalid("page offset must be nonnegative and page length must be 1–4096 bytes") }
            let rows = try query("SELECT byte_count,digest,status,substr(payload,?,?) FROM events WHERE id=?", [.integer(max(1, offset)), .integer(length + 1), .text(eventID)]) { statement in
                (Int(sqlite3_column_int64(statement, 0)), string(statement, 1), string(statement, 2), blob(statement, 3))
            }
            guard let (total, digest, statusText, bytes) = rows.first else { throw MemoryError.missing("event") }
            guard offset <= total else { throw MemoryError.invalid("page offset exceeds the source payload") }
            // SQLite substr is one-based. Fetching from offset (except at zero)
            // also gives the preceding byte for validating the requested start.
            let start = offset == 0 ? 0 : 1
            guard bytes.count >= start else { throw MemoryError.database("payload length disagrees with its manifest") }
            let requested = Data(bytes.dropFirst(start).prefix(length))
            if let first = requested.first, first & 0xC0 == 0x80 { throw MemoryError.invalid("page offset splits a UTF-8 scalar") }
            var end = requested.count
            var text: String?
            while end >= 0 {
                text = String(data: requested.prefix(end), encoding: .utf8)
                if text != nil { break }
                end -= 1
                if requested.count - end > 3 { throw MemoryError.database("payload is not valid UTF-8") }
            }
            guard let text, end > 0 || offset == total else { throw MemoryError.invalid("page length cannot contain the next UTF-8 scalar") }
            let next = offset + end
            guard let status = CaptureStatus(rawValue: statusText) else { throw MemoryError.database("invalid capture status") }
            return PayloadPage(eventID: eventID, offset: offset, text: text, byteCount: end, totalBytes: total, nextOffset: next < total ? next : nil, digest: digest, status: status)
        }
    }

    func saveDraft(conversationID: String, text: String) throws {
        try locked {
            _ = try conversation(conversationID)
            let payload = try validatePayload(text)
            try execute("INSERT INTO drafts(conversation_id,payload) VALUES (?,?) ON CONFLICT(conversation_id) DO UPDATE SET payload=excluded.payload", [.text(conversationID), .blob(payload)])
        }
    }

    func loadDraft(conversationID: String) throws -> String {
        try locked {
            _ = try conversation(conversationID)
            return try loadText("SELECT payload FROM drafts WHERE conversation_id=?", conversationID) ?? ""
        }
    }

    func saveSetting(key: String, value: String) throws {
        try locked {
            try validateIdentifier(key, name: "setting key")
            let payload = try validatePayload(value)
            try execute("INSERT INTO settings(key,payload) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", [.text(key), .blob(payload)])
        }
    }

    func loadSetting(key: String) throws -> String? {
        try locked {
            try validateIdentifier(key, name: "setting key")
            return try loadText("SELECT payload FROM settings WHERE key=?", key)
        }
    }

    /// Exposes connection configuration for deterministic self-checks.
    func durabilityConfiguration() throws -> (journalMode: String, synchronous: Int) {
        try locked {
            let mode = try query("PRAGMA journal_mode") { string($0, 0) }.first ?? ""
            return (mode, try scalarInteger("PRAGMA synchronous"))
        }
    }

    private func insertEvent(_ event: MemoryEvent, payload: Data) throws {
        try execute("INSERT INTO events (id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload,source_time_json) VALUES (?,?,?,?,?,?,?,?,?,?,?)", [.text(event.id), .text(event.conversationID), .text(event.projectID), .text(event.role.rawValue), .text(event.status.rawValue), .text(event.turnID), .text(event.createdAt), .text(event.digest), .integer(payload.count), .blob(payload), try event.sourceTime.map { .blob(try $0.validated().canonicalData()) } ?? .null])
        let rowID = sqlite3_last_insert_rowid(database)
        try execute("INSERT INTO event_fts(rowid,text) VALUES (?,?)", [.integer(Int(rowID)), .text(event.text)])
        try execute("UPDATE conversations SET updated_at=? WHERE id=?", [.text(event.createdAt), .text(event.conversationID)])
    }

    private func findInvocation(_ id: String) throws -> StoredInvocation? {
        try query("SELECT id,conversation_id,project_id,turn_id,human_event_id,assistant_event_id,provider_identity,request_body,request_digest,created_at,chunk_count,observed_bytes,final_status,terminal_reason,finalized_at,recovered,admission_json,admission_digest,usage_json,usage_digest,episode_id,episode_work_id FROM invocations WHERE id=?", [.text(id)]) { statement in
            let body = blob(statement, 7)
            let digest = string(statement, 8)
            guard !body.isEmpty, body.count <= Self.maximumPayloadBytes, Self.digest(body) == digest else { throw MemoryError.database("invocation request failed integrity verification") }
            let statusText = string(statement, 12)
            let reasonText = string(statement, 13)
            let finalizedText = string(statement, 14)
            let status = CaptureStatus(rawValue: statusText)
            let reason = InvocationTerminalReason(rawValue: reasonText)
            guard (statusText.isEmpty && reasonText.isEmpty && finalizedText.isEmpty) ||
                  (status != nil && reason != nil && !finalizedText.isEmpty) else {
                throw MemoryError.database("invalid invocation terminal state")
            }
            if let status, let reason { try validateTerminal(status: status, reason: reason) }
            let admission = blob(statement, 16)
            let usage = blob(statement, 18)
            guard admission.count <= 65536, usage.count <= 65536,
                  (admission.isEmpty ? "" : Self.digest(admission)) == string(statement, 17),
                  (usage.isEmpty ? "" : Self.digest(usage)) == string(statement, 19) else { throw MemoryError.database("invocation metadata receipt failed integrity verification") }
            return StoredInvocation(id: string(statement, 0), conversationID: string(statement, 1), projectID: string(statement, 2), turnID: string(statement, 3), humanEventID: string(statement, 4), assistantEventID: string(statement, 5), providerIdentity: string(statement, 6), requestBody: body, requestDigest: digest, admissionJSON: admission.isEmpty ? nil : admission, usageJSON: usage.isEmpty ? nil : usage, createdAt: string(statement, 9), chunkCount: Int(sqlite3_column_int64(statement, 10)), observedBytes: Int(sqlite3_column_int64(statement, 11)), finalStatus: status, terminalReason: reason, finalizedAt: finalizedText.isEmpty ? nil : finalizedText, recovered: sqlite3_column_int(statement, 15) == 1, episodeID: sqlite3_column_type(statement, 20) == SQLITE_NULL ? nil : string(statement, 20), episodeWorkID: sqlite3_column_type(statement, 21) == SQLITE_NULL ? nil : string(statement, 21))
        }.first
    }

    private func invocationPayload(_ attempt: StoredInvocation) throws -> Data {
        var payload = Data()
        payload.reserveCapacity(attempt.observedBytes)
        var sequence = 0
        _ = try query("SELECT chunk_sequence,byte_count,digest,payload FROM invocation_chunks WHERE invocation_id=? ORDER BY chunk_sequence", [.text(attempt.id)]) { statement in
            let chunk = blob(statement, 3)
            guard Int(sqlite3_column_int64(statement, 0)) == sequence,
                  Int(sqlite3_column_int64(statement, 1)) == chunk.count,
                  Self.digest(chunk) == string(statement, 2),
                  String(data: chunk, encoding: .utf8) != nil,
                  payload.count <= Self.maximumPayloadBytes - chunk.count else {
                throw MemoryError.database("invocation chunk failed integrity verification")
            }
            payload.append(chunk)
            sequence += 1
        }
        guard sequence == attempt.chunkCount, payload.count == attempt.observedBytes else { throw MemoryError.database("invocation chunk manifest failed integrity verification") }
        return payload
    }

    /// Caller already owns a write transaction. Never deletes the recovery
    /// journal before the event and search publication have committed.
    private func publishInvocation(_ attempt: StoredInvocation, status: CaptureStatus, reason: InvocationTerminalReason, recovered: Bool, usageJSON: Data? = nil) throws -> MemoryEvent {
        let payload = try invocationPayload(attempt)
        guard let text = String(data: payload, encoding: .utf8) else { throw MemoryError.database("invalid invocation text encoding") }
        if status == .complete, let episodeID = attempt.episodeID {
            guard let episode = try findEpisode(episodeID), episode.state == .completed else { throw EpisodeBudgetError.inactive }
        }
        if let existingStatus = attempt.finalStatus {
            guard existingStatus == status, attempt.terminalReason == reason, attempt.usageJSON == usageJSON,
                  let existing = try findEvent(attempt.assistantEventID),
                  episodeIdentifierEqual(existing.conversationID, attempt.conversationID), episodeIdentifierEqual(existing.projectID, attempt.projectID),
                  existing.role == .assistant, episodeIdentifierEqual(existing.turnID, attempt.turnID),
                  existing.status == status, episodeIdentifierEqual(existing.text, text) else {
                throw MemoryError.conflict("invocation was already finalized with a different terminal result")
            }
            return existing
        }
        let now = Self.timestamp()
        let result = MemoryEvent(id: attempt.assistantEventID, conversationID: attempt.conversationID, projectID: attempt.projectID, role: .assistant, text: text, status: status, turnID: attempt.turnID, createdAt: now, digest: Self.digest(payload), byteCount: payload.count)
        try insertEvent(result, payload: payload)
        try execute("UPDATE invocations SET final_status=?,terminal_reason=?,finalized_at=?,recovered=?,usage_json=?,usage_digest=? WHERE id=?", [.text(status.rawValue), .text(reason.rawValue), .text(now), .integer(recovered ? 1 : 0), .blob(usageJSON ?? Data()), .text(usageJSON.map(Self.digest) ?? ""), .text(attempt.id)])
        return result
    }

    private func recoverInterruptedInvocations() throws {
        try transaction {
            let ids = try query("SELECT id FROM invocations WHERE final_status='' ORDER BY created_at,id") { string($0, 0) }
            for id in ids {
                guard let attempt = try findInvocation(id) else { throw MemoryError.database("interrupted invocation disappeared") }
                let episode = try attempt.episodeID.flatMap(findEpisode)
                let cancelled = episode?.state == .cancelled
                _ = try publishInvocation(attempt, status: attempt.observedBytes == 0 ? (cancelled ? .cancelled : .failed) : .partial, reason: cancelled ? .cancelled : .interrupted, recovered: true)
            }
        }
    }

    private func validateProviderIdentity(_ identity: String) throws {
        guard identity.utf8.count <= 2048 else { throw MemoryError.invalid("provider identity exceeds the metadata limit") }
        if identity.hasPrefix("native:") {
            let profile = identity.dropFirst(7)
            guard !profile.isEmpty, profile.utf8.count <= 200,
                  profile.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) else {
                throw MemoryError.invalid("native provider identity must contain a safe profile ID")
            }
            return
        }
        guard let parts = URLComponents(string: identity), parts.scheme?.lowercased() == "http",
              let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!), parts.url != nil else {
            throw MemoryError.invalid("provider identity must be a credential-free loopback HTTP URL or safe native profile")
        }
    }

    private func validateRequestBody(_ body: Data) throws {
        guard !body.isEmpty, body.count <= Self.maximumPayloadBytes,
              String(data: body, encoding: .utf8) != nil else { throw MemoryError.invalid("provider request must be bounded UTF-8 JSON") }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: body) }
        catch { throw MemoryError.invalid("provider request must be a JSON object") }
        guard parsed is [String: Any] else { throw MemoryError.invalid("provider request must be a JSON object") }
        let forbidden = Set(["apikey", "authorization", "proxyauthorization", "password", "accesstoken", "bearer", "token", "headers", "cookies"])
        func credentialsPresent(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                return object.contains { key, child in
                    let normalized = key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
                    return forbidden.contains(normalized) || credentialsPresent(child)
                }
            }
            if let array = value as? [Any] { return array.contains(where: credentialsPresent) }
            return false
        }
        guard !credentialsPresent(parsed) else { throw MemoryError.invalid("provider request snapshots must exclude credentials and HTTP headers") }
    }

    private static func defaultTerminalReason(_ status: CaptureStatus) -> InvocationTerminalReason {
        switch status {
        case .complete: return .completed
        case .cancelled: return .cancelled
        case .partial: return .upstreamIncomplete
        case .failed: return .transportFailure
        }
    }

    private func validateTerminal(status: CaptureStatus, reason: InvocationTerminalReason) throws {
        let valid: Bool
        switch status {
        case .complete: valid = reason == .completed
        case .cancelled: valid = reason == .cancelled
        case .partial: valid = reason != .completed && reason != .admissionFailure
        case .failed: valid = reason != .completed && reason != .cancelled
        }
        guard valid else { throw MemoryError.invalid("capture status and invocation terminal reason disagree") }
    }

    private func conversation(_ id: String) throws -> StoredConversation {
        try validateIdentifier(id, name: "conversation ID")
        let rows = try query("SELECT id,project_id,title,created_at,updated_at FROM conversations WHERE id=?", [.text(id)]) { statement in
            StoredConversation(id: string(statement, 0), projectID: string(statement, 1), title: string(statement, 2), createdAt: string(statement, 3), updatedAt: string(statement, 4))
        }
        guard let result = rows.first else { throw MemoryError.missing("conversation") }
        return result
    }

    private func findEvent(_ id: String) throws -> MemoryEvent? {
        try queryEvents("SELECT id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload,source_time_json FROM events WHERE id=?", [.text(id)]).first
    }

    private func queryEvents(_ sql: String, _ bindings: [Value]) throws -> [MemoryEvent] {
        try query(sql, bindings, map: event)
    }

    private func event(_ statement: OpaquePointer) throws -> MemoryEvent {
        guard let role = MemoryRole(rawValue: string(statement, 3)), let status = CaptureStatus(rawValue: string(statement, 4)), let text = String(data: blob(statement, 9), encoding: .utf8) else {
            throw MemoryError.database("invalid event encoding")
        }
        let bytes = Int(sqlite3_column_int64(statement, 8))
        guard text.utf8.count == bytes, Self.digest(Data(text.utf8)) == string(statement, 7) else { throw MemoryError.database("event payload failed integrity verification") }
        return MemoryEvent(id: string(statement, 0), conversationID: string(statement, 1), projectID: string(statement, 2), role: role, text: text, status: status, turnID: string(statement, 5), createdAt: string(statement, 6), digest: string(statement, 7), byteCount: bytes, sourceTime: try SourceTimeSchema.decodeColumn(statement, index: 10))
    }

    private func loadText(_ sql: String, _ key: String) throws -> String? {
        try query(sql, [.text(key)]) { statement in
            guard let result = String(data: blob(statement, 0), encoding: .utf8) else { throw MemoryError.database("invalid stored UTF-8") }
            return result
        }.first
    }

    private enum Value { case text(String), integer(Int), blob(Data), null }

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch binding {
                case .null: result = sqlite3_bind_null(statement, index)
                case .text(let value):
                    result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
                case .integer(let value): result = sqlite3_bind_int64(statement, index, Int64(value))
                case .blob(let value):
                    // An empty payload must remain an empty BLOB, not SQL NULL.
                    if value.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                    else { result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) } }
                }
                guard result == SQLITE_OK else { throw databaseError() }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func execute(_ sql: String, _ bindings: [Value] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw databaseError() }
    }

    private func query<T>(_ sql: String, _ bindings: [Value] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw databaseError() }
            values.append(try map(statement))
        }
    }

    private func scalarInteger(_ sql: String) throws -> Int { try query(sql) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
    private func withAuthorityCacheWrites<T>(_ manifest: AuthorityCacheWriteObserver.Manifest,
        _ body: () throws -> T) rethrows -> T {
        let previous = authorityCacheWrites.manifest
        authorityCacheWrites.manifest = manifest
        defer { authorityCacheWrites.manifest = previous }
        return try body()
    }
    private func authorityLedgerLocked<T>(_ body: () throws -> T) throws -> T {
        try locked { try withAuthorityCacheWrites(.ledger, body) }
    }
    private func authorityLedgerTransaction<T>(_ body: () throws -> T) throws -> T {
        try withAuthorityCacheWrites(.ledger) { try transaction(body) }
    }
    private func authorityChunkLocked<T>(_ body: () throws -> T) throws -> T {
        try locked { try withAuthorityCacheWrites(.chunks, body) }
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); authorityCacheWrites.invalidate(); throw error }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        return try body()
    }
    private func databaseError() -> MemoryError {
        MemoryError.database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open the local database")
    }
    private func validateIdentifier(_ value: String, name: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else { throw MemoryError.invalid("\(name) must contain 1–256 UTF-8 bytes without NUL") }
    }
    private func validatePayload(_ text: String) throws -> Data {
        guard text.utf8.count <= Self.maximumPayloadBytes else { throw MemoryError.invalid("payload exceeds the 4 MiB capture limit; no content was stored") }
        return Data(text.utf8)
    }
    private func validateSearch(query: String, projectID: String, limit: Int) throws {
        try validateIdentifier(projectID, name: "project ID")
        guard query.utf8.count <= 4096, limit > 0, limit <= 100 else { throw MemoryError.invalid("search query must be at most 4096 bytes and limit must be 1–100") }
    }
    private static func searchTerms(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
    private static func digest(_ payload: Data) -> String { SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() }
    /// One bounded occurrence per distinct term. Choose the window containing
    /// the most complete matches, then the most matched term bytes. A common
    /// request word must not center the excerpt away from a denser term cluster.
    /// Literal search retains its exact first-match window.
    static func hit(_ event: MemoryEvent, terms: [String], literal: Bool = false) -> MemoryHit {
        var seen = Set<String>()
        let matches = terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.compactMap { term in
            event.text.range(of: term, options: literal ? [] : [.caseInsensitive, .diacriticInsensitive])
        }
        var lower = event.text.startIndex, upper = event.text.endIndex
        var bestCount = -1, bestBytes = -1
        for center in matches.isEmpty ? [event.text.startIndex] : matches.map(\.lowerBound) {
            let start = event.text.index(center, offsetBy: -160, limitedBy: event.text.startIndex) ?? event.text.startIndex
            let end = event.text.index(start, offsetBy: 560, limitedBy: event.text.endIndex) ?? event.text.endIndex
            let included = matches.filter { $0.lowerBound >= start && $0.upperBound <= end }
            let weight = included.reduce(0) { $0 + event.text[$1].utf8.count }
            if included.count > bestCount || (included.count == bestCount && (weight > bestBytes
                || (weight == bestBytes && start < lower))) {
                lower = start; upper = end; bestCount = included.count; bestBytes = weight
            }
            if literal { break }
        }
        let candidate = Data(event.text[lower..<upper].utf8)
        var length = min(candidate.count, maximumPageBytes)
        while length > 0 && String(data: candidate.prefix(length), encoding: .utf8) == nil { length -= 1 }
        let excerpt = String(decoding: candidate.prefix(length), as: UTF8.self)
        return MemoryHit(eventID: event.id, conversationID: event.conversationID, projectID: event.projectID, role: event.role, status: event.status, createdAt: event.createdAt, digest: event.digest, totalBytes: event.byteCount, excerptOffset: event.text[..<lower].utf8.count, excerpt: excerpt, sourceTime: event.sourceTime)
    }
    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid() else { throw MemoryError.invalid("memory directory must be a real directory owned by this user") }
        guard chmod(url.path, 0o700) == 0 else { throw MemoryError.invalid("could not make memory directory private") }
    }
    private static func openPrivateFile(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MemoryError.invalid("could not open a private memory file") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else {
            close(descriptor); throw MemoryError.invalid("memory file must be a regular file owned by this user")
        }
        return descriptor
    }
    private func secureSidecars() throws {
        for name in ["memory.sqlite3-wal", "memory.sqlite3-shm"] {
            let path = directory.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                let descriptor = try Self.openPrivateFile(path)
                close(descriptor)
            }
        }
    }
}

extension MemoryStore: EpisodeLedger {
    private func createEpisodeParent(table: String, ifAbsent: Bool) throws {
        guard table == "episodes" || table == "episodes_v4" else { throw EpisodeBudgetError.invalid }
        try execute("CREATE TABLE " + (ifAbsent ? "IF NOT EXISTS " : "") + "\"" + table + "\"" + """
             (
              id TEXT PRIMARY KEY, conversation_id TEXT REFERENCES conversations(id),
              project_id TEXT NOT NULL, turn_id TEXT, human_event_id TEXT UNIQUE REFERENCES events(id),
              limits_json BLOB NOT NULL CHECK(length(limits_json)>0 AND length(limits_json)<=65536),
              limits_digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','completed','failed','cancelled','interrupted','deadlineExceeded','budgetExceeded')),
              revision INTEGER NOT NULL CHECK(revision>=0), clock_domain TEXT NOT NULL,
              created_ticks INTEGER NOT NULL CHECK(created_ticks>0), deadline_ticks INTEGER NOT NULL CHECK(deadline_ticks>created_ticks),
              last_ticks INTEGER NOT NULL CHECK(last_ticks>=created_ticks), created_utc REAL NOT NULL,
              terminal_reason TEXT NOT NULL DEFAULT '',
              origin_json BLOB NOT NULL CHECK(length(origin_json)>0 AND length(origin_json)<=65536), origin_digest TEXT NOT NULL,
              CHECK((conversation_id IS NULL AND turn_id IS NULL AND human_event_id IS NULL) OR
                    (conversation_id IS NOT NULL AND turn_id IS NOT NULL AND human_event_id IS NOT NULL)),
              CHECK((state='active' AND terminal_reason='') OR (state!='active' AND terminal_reason!=''))
            )
            """)
    }
    private func migrateEpisodeSchemaThree(checkpoint: ((String) throws -> Void)?) throws {
        try createEpisodeParent(table: "episodes_v4", ifAbsent: false)
        let legacy = try query("SELECT id,conversation_id,turn_id,human_event_id,project_id FROM episodes") {
            (string($0, 0), string($0, 1), string($0, 2), string($0, 3), string($0, 4))
        }
        for (id, conversationID, turnID, humanEventID, projectID) in legacy {
            let origin = try episodeJSON(EpisodeOrigin.chat(conversationID: conversationID, turnID: turnID, humanEventID: humanEventID))
            try execute("""
                INSERT INTO episodes_v4 (id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,created_ticks,deadline_ticks,last_ticks,created_utc,terminal_reason,origin_json,origin_digest)
                SELECT id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,created_ticks,deadline_ticks,last_ticks,created_utc,terminal_reason,?,? FROM episodes WHERE id=?
                """, [.blob(origin), .text(try Self.episodeOriginDigest(projectID: projectID, originJSON: origin)), .text(id)])
        }
        try checkpoint?("beforeParentReplacement")
        try execute("DROP TABLE episodes")
        try execute("ALTER TABLE episodes_v4 RENAME TO episodes")
        try checkpoint?("afterParentReplacement")
    }
    private func createEpisodeSchema() throws {
        try createEpisodeParent(table: "episodes", ifAbsent: true)
        try execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS episode_local_read_request
            ON episodes(json_extract(origin_json,'$.binding.initiator'),json_extract(origin_json,'$.binding.requestID'))
            WHERE json_extract(origin_json,'$.kind')='localRead'
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS episode_resource_totals (
              episode_id TEXT NOT NULL REFERENCES episodes(id), resource TEXT NOT NULL,
              charged INTEGER NOT NULL CHECK(charged>=0), held INTEGER NOT NULL CHECK(held>=0), cap INTEGER NOT NULL CHECK(cap>=0),
              PRIMARY KEY(episode_id,resource)
            ) WITHOUT ROWID
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS episode_request_snapshots (
              digest TEXT PRIMARY KEY, byte_count INTEGER NOT NULL CHECK(byte_count>0 AND byte_count<=4194304),
              payload BLOB NOT NULL CHECK(length(payload)=byte_count)
            ) WITHOUT ROWID
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS episode_work (
              id TEXT PRIMARY KEY, episode_id TEXT NOT NULL REFERENCES episodes(id), parent_id TEXT REFERENCES episode_work(id),
              kind TEXT NOT NULL, adapter_identity TEXT NOT NULL, request_json BLOB NOT NULL CHECK(length(request_json)>0 AND length(request_json)<=65536),
              request_digest TEXT NOT NULL, snapshot_digest TEXT REFERENCES episode_request_snapshots(digest),
              revision INTEGER NOT NULL CHECK(revision>=0), state TEXT NOT NULL CHECK(state IN ('prepared','dispatchArmed','submitted','completed','failedConfirmed','outcomeUnknown','cancelledBeforeDispatch')),
              charged_json BLOB NOT NULL, held_json BLOB NOT NULL, observed_json BLOB NOT NULL DEFAULT X'',
              receipt_id TEXT, receipt_json BLOB NOT NULL DEFAULT X'', receipt_digest TEXT NOT NULL DEFAULT '',
              created_ticks INTEGER NOT NULL CHECK(created_ticks>0), armed_ticks INTEGER NOT NULL DEFAULT 0 CHECK(armed_ticks>=0),
              ended_ticks INTEGER NOT NULL DEFAULT 0 CHECK(ended_ticks>=0), recovered INTEGER NOT NULL DEFAULT 0 CHECK(recovered IN (0,1)),
              adapter_violation INTEGER NOT NULL DEFAULT 0 CHECK(adapter_violation IN (0,1)),
              UNIQUE(episode_id,receipt_id)
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS episode_work_episode ON episode_work(episode_id,id)")
        let columns = try query("PRAGMA table_info(invocations)") { string($0, 1) }
        if !columns.contains("episode_id") { try execute("ALTER TABLE invocations ADD COLUMN episode_id TEXT REFERENCES episodes(id)") }
        if !columns.contains("episode_work_id") { try execute("ALTER TABLE invocations ADD COLUMN episode_work_id TEXT REFERENCES episode_work(id)") }
    }
    /// Domain-separated binding of the exact stored origin bytes and project.
    static func episodeOriginDigest(projectID: String, originJSON: Data) throws -> String {
        guard !projectID.isEmpty, projectID.utf8.count <= 256, !projectID.contains("\0"),
              !originJSON.isEmpty, originJSON.count <= 65536 else { throw EpisodeBudgetError.invalid }
        return digest(Data(("boros-episode-origin-v1\0" + projectID + "\0").utf8) + originJSON)
    }
    private func episodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 65536 else { throw EpisodeBudgetError.invalid }
        return data
    }
    private func episodeDecode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard !data.isEmpty, data.count <= 65536 else { throw MemoryError.database("invalid episode metadata bounds") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw MemoryError.database("invalid episode metadata encoding") }
    }
    private func validateEpisodeClock(_ clock: EpisodeClockSnapshot) throws {
        guard !clock.domain.isEmpty, clock.domain.utf8.count <= 256, !clock.domain.contains("\0"),
              clock.continuousNanoseconds > 0, clock.continuousNanoseconds <= UInt64(Int64.max),
              clock.utc.timeIntervalSince1970.isFinite else { throw EpisodeBudgetError.clockUnavailable }
    }
    private func episodeRuntimeClock(_ supplied: EpisodeClockSnapshot) throws -> EpisodeClockSnapshot {
        try validateEpisodeClock(supplied)
        // Callers sample before acquiring this owner's lock. Refresh the real
        // clock here so concurrent callers cannot manufacture a false rollback
        // merely by reaching the lock in a different order.
        if supplied.domain.hasPrefix("mach-continuous-v1:") {
            let current = try SystemEpisodeClock().now()
            guard episodeIdentifierEqual(current.domain, supplied.domain) else { throw EpisodeBudgetError.clockUnavailable }
            return current
        }
        return supplied
    }
    private func validateEpisodeLimits(_ limits: EpisodeLimits) throws {
        try validateIdentifier(limits.version, name: "episode limit version")
        _ = try limits.resources.validated()
        _ = try limits.componentPolicy?.validated()
        _ = try limits.terminalCleanup?.validated()
        guard limits.deadlineMilliseconds > 0, limits.deadlineMilliseconds <= 86_400_000 else { throw EpisodeBudgetError.invalid }
    }
    private func requiredEpisodeCleanupLimits(_ limits: EpisodeLimits) throws -> EpisodeCleanupLimits {
        guard let cleanup = limits.terminalCleanup else { throw EpisodeBudgetError.invalid }
        return try cleanup.validated()
    }
    private func findEpisode(_ id: String) throws -> EpisodeReceipt? {
        guard let database else { throw MemoryError.database("closed owner") }
        if sqlite3_get_autocommit(database) != 0 {
            return try transaction { try findEpisode(id) }
        }
        try requireAccountingConfidenceLocked()
        return try query("SELECT id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,deadline_ticks,created_utc,origin_json,origin_digest FROM episodes WHERE id=?", [.text(id)]) { row in
            let data = blob(row, 5)
            guard Self.digest(data) == string(row, 6), let state = EpisodeState(rawValue: string(row, 7)) else { throw MemoryError.database("episode failed integrity verification") }
            let limits = try episodeDecode(EpisodeLimits.self, data)
            try validateEpisodeLimits(limits)
            let originBytes = blob(row, 12)
            guard try Self.episodeOriginDigest(projectID: string(row, 2), originJSON: originBytes) == string(row, 13) else { throw MemoryError.database("episode origin integrity failure") }
            let origin = try episodeDecode(EpisodeOrigin.self, originBytes)
            guard try episodeJSON(origin) == originBytes else { throw MemoryError.database("episode origin is not canonical") }
            let conversationID = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : string(row, 1)
            let turnID = sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : string(row, 3)
            let humanEventID = sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : string(row, 4)
            switch origin {
            case .chat(let conversation, let turn, let human):
                guard episodeIdentifierEqual(conversationID, conversation), episodeIdentifierEqual(turnID, turn), episodeIdentifierEqual(humanEventID, human) else { throw MemoryError.database("episode origin chat linkage mismatch") }
            case .localRead:
                guard conversationID == nil, turnID == nil, humanEventID == nil else { throw MemoryError.database("episode origin read linkage mismatch") }
            }
            var charged = EpisodeResources.zero, held = EpisodeResources.zero
            let totals = try query("SELECT resource,charged,held,cap FROM episode_resource_totals WHERE episode_id=?", [.text(id)]) { total in
                guard let resource = EpisodeResource(rawValue: string(total, 0)) else { throw MemoryError.database("unknown episode resource") }
                let spent = Int(sqlite3_column_int64(total, 1)), reserved = Int(sqlite3_column_int64(total, 2)), cap = Int(sqlite3_column_int64(total, 3))
                guard spent >= 0, reserved >= 0, cap == limits.resources[resource] else { throw MemoryError.database("invalid episode resource total") }
                charged[resource] = spent; held[resource] = reserved
                return resource
            }
            guard totals.count == EpisodeResource.allCases.count, Set(totals).count == totals.count else { throw MemoryError.database("episode resource vector incomplete") }
            let unknown = try EpisodeAccountingJournal.summary(database: database, episodeID: id).unknownInputOperations
            return EpisodeReceipt(id: string(row, 0), conversationID: conversationID, projectID: string(row, 2), turnID: turnID, humanEventID: humanEventID, origin: origin, limits: limits, state: state, revision: Int(sqlite3_column_int64(row, 8)), clockDomain: string(row, 9), deadlineNanoseconds: UInt64(sqlite3_column_int64(row, 10)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 11)), charged: charged, held: held, unknownInputOperations: unknown)
        }.first
    }
    private func requireAccountingConfidenceLocked() throws {
        guard let database, sqlite3_get_autocommit(database) == 0 else { throw AuthorityStateError.integrity }
        if accountingBootstrapping { return }
        func check() throws {
            guard authorityCacheWrites.canTrustAccounting,
                accountingWriteGeneration == authorityCacheWrites.accountingGeneration,
                accountingExternalVersion == (try scalarInteger("PRAGMA data_version")) else {
                throw AuthorityStateError.staleRevision
            }
        }
        try check()
        try withAuthorityCacheWrites(.unknown) {
            try episodeAccountingCheckpoint?("before-accounting-lookup", database)
        }
        try check()
    }
    private func findEpisodeWork(_ id: String) throws -> EpisodeWorkRecord? {
        try query("SELECT id,episode_id,request_json,request_digest,snapshot_digest,revision,state,charged_json,held_json,observed_json,receipt_id,recovered,receipt_json,receipt_digest FROM episode_work WHERE id=?", [.text(id)]) { row in
            let metadata = blob(row, 2)
            guard Self.digest(metadata) == string(row, 3), let state = EpisodeWorkState(rawValue: string(row, 6)) else { throw MemoryError.database("episode work failed integrity verification") }
            let encoded = try episodeDecode(EpisodeWorkRequest.self, metadata)
            var snapshot: Data?
            let snapshotDigest = string(row, 4)
            if !snapshotDigest.isEmpty {
                snapshot = try query("SELECT payload,byte_count FROM episode_request_snapshots WHERE digest=?", [.text(snapshotDigest)]) { source in
                    let payload = blob(source, 0)
                    guard payload.count == Int(sqlite3_column_int64(source, 1)), Self.digest(payload) == snapshotDigest else { throw MemoryError.database("episode snapshot failed integrity verification") }
                    return payload
                }.first
                guard snapshot != nil else { throw MemoryError.database("episode snapshot missing") }
            }
            let request = EpisodeWorkRequest(id: encoded.id, parentID: encoded.parentID, kind: encoded.kind, resources: encoded.resources, adapterIdentity: encoded.adapterIdentity, snapshot: snapshot, inputTokensKnown: encoded.inputTokensKnown)
            let observedData = blob(row, 9), receipt = blob(row, 12)
            guard (receipt.isEmpty ? "" : Self.digest(receipt)) == string(row, 13) else { throw MemoryError.database("episode receipt failed integrity verification") }
            return EpisodeWorkRecord(id: string(row, 0), episodeID: string(row, 1), request: request, revision: Int(sqlite3_column_int64(row, 5)), state: state,
                charged: try episodeDecode(EpisodeResources.self, blob(row, 7)).validated(), held: try episodeDecode(EpisodeResources.self, blob(row, 8)).validated(),
                observed: observedData.isEmpty ? nil : try episodeDecode(EpisodeResources.self, observedData).validated(), receiptID: sqlite3_column_type(row, 10) == SQLITE_NULL ? nil : string(row, 10), recovered: sqlite3_column_int(row, 11) == 1)
        }.first
    }
    private func updateEpisodeTotals(_ episode: EpisodeReceipt, replacing work: EpisodeWorkRecord?, charged: EpisodeResources, held: EpisodeResources) throws {
        let nextCharged = try episode.charged.subtracting(work?.charged ?? .zero).adding(charged)
        let nextHeld = try episode.held.subtracting(work?.held ?? .zero).adding(held)
        for resource in EpisodeResource.allCases {
            try execute("UPDATE episode_resource_totals SET charged=?,held=? WHERE episode_id=? AND resource=?", [.integer(nextCharged[resource]), .integer(nextHeld[resource]), .text(episode.id), .text(resource.rawValue)])
        }
    }
    /// The terminal fence is fixed-size. Metadata cleanup spends prepaid slots
    /// only after this transaction commits; its failure cannot reopen Stop.
    private func terminalizeEpisode(_ episode: EpisodeReceipt, reason: EpisodeState, ticks: UInt64) throws {
        try withAuthorityCacheWrites(.ledger) {
            guard reason != .active else { throw EpisodeBudgetError.invalid }
            if episode.state != .active { return }
            guard episode.revision < Int.max, let database else { throw EpisodeBudgetError.invalid }
            try requireAccountingConfidenceLocked()
            try execute("UPDATE episodes SET state=?,terminal_reason=?,revision=revision+1 WHERE id=? AND state='active'", [.text(reason.rawValue), .text(reason.rawValue), .text(episode.id)])
            _ = try EpisodeTerminalCleanupJournal.terminalFence(database: database, episodeID: episode.id, ticks: ticks)
        }
    }
    private func scheduleEpisodeCleanupLocked(_ episodeID: String) {
        guard !accountingBootstrapping, automaticallyDrainEpisodeCleanup else { return }
        let key = Data(episodeID.utf8)
        guard scheduledEpisodeCleanup.insert(key).inserted else { return }
        episodeCleanupQueue.async { [weak self] in
            guard let self else { return }
            // One transaction per queued turn, releasing the owner between
            // batches. A refusal leaves the explicit pending ledger intact.
            try? self.authorityLedgerLocked {
                self.scheduledEpisodeCleanup.remove(key)
                let receipt = try self.drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: EpisodeCleanupLimits.batchRows)
                if receipt.pendingRows > 0 { self.scheduleEpisodeCleanupLocked(episodeID) }
            }
        }
    }
    private func cleanupEpisodeWorkLocked(episodeID: String, workID: String, recovering: Bool = false) throws {
        guard let database, sqlite3_get_autocommit(database) == 0 else { throw AuthorityStateError.integrity }
        try requireAccountingConfidenceLocked()
        guard let episode = try findEpisode(episodeID) else { throw MemoryError.missing("episode") }
        guard episode.state != .active else { return }
        let budget = try EpisodeTerminalCleanupJournal.receipt(database: database, episodeID: episodeID)
        let rows = try query("SELECT id,episode_id,state,request_json,request_digest,charged_json,held_json,revision FROM episode_work WHERE id=?", [.text(workID)]) { row -> EpisodeWorkRecord in
            let metadata = blob(row, 3), charged = blob(row, 5), held = blob(row, 6)
            guard metadata.count + charged.count + held.count + string(row, 0).utf8.count + string(row, 1).utf8.count + 128 <= EpisodeCleanupLimits.maximumMetadataBytes,
                Self.digest(metadata) == string(row, 4), let state = EpisodeWorkState(rawValue: string(row, 2)) else { throw AuthorityStateError.integrity }
            let request = try episodeDecode(EpisodeWorkRequest.self, metadata)
            guard request.snapshot == nil, episodeIdentifierEqual(request.id, string(row, 0)), episodeIdentifierEqual(string(row, 1), episodeID) else { throw AuthorityStateError.integrity }
            return EpisodeWorkRecord(id: string(row, 0), episodeID: string(row, 1), request: request, revision: Int(sqlite3_column_int64(row, 7)), state: state,
                charged: try episodeDecode(EpisodeResources.self, charged).validated(), held: try episodeDecode(EpisodeResources.self, held).validated(), observed: nil, receiptID: nil, recovered: recovering)
        }
        guard let work = rows.first else { throw MemoryError.missing("episode work") }
        guard [.prepared, .dispatchArmed, .submitted].contains(work.state) else { return }
        guard budget.terminalTicks > 0, budget.pendingRows > 0, budget.consumedRows < budget.prepaidRows else { throw AuthorityStateError.integrity }
        let next: EpisodeWorkState = work.state == .prepared ? .cancelledBeforeDispatch : .outcomeUnknown
        if work.state == .prepared {
            guard work.charged == .zero, work.held == work.request.resources else { throw AuthorityStateError.integrity }
            try updateEpisodeTotals(episode, replacing: work, charged: .zero, held: .zero)
            try execute("UPDATE episode_work SET state=?,held_json=?,ended_ticks=?,recovered=max(recovered,?) WHERE id=? AND state='prepared'", [.text(next.rawValue), .blob(try episodeJSON(EpisodeResources.zero)), .integer(Int(budget.terminalTicks)), .integer(recovering ? 1 : 0), .text(workID)])
        } else {
            try execute("UPDATE episode_work SET state=?,ended_ticks=?,recovered=max(recovered,?) WHERE id=? AND state IN ('dispatchArmed','submitted')", [.text(next.rawValue), .integer(Int(budget.terminalTicks)), .integer(recovering ? 1 : 0), .text(workID)])
        }
        try withAuthorityCacheWrites(.unknown) { try episodeCleanupCheckpoint?("after-work-before-cleanup-receipt", database) }
        try requireAccountingConfidenceLocked()
        try EpisodeAccountingJournal.recordTransition(database: database, episodeID: episodeID, request: work.request, from: work.state, to: next)
        try EpisodeTerminalCleanupJournal.recordTransition(database: database, episodeID: episodeID, workID: workID, from: work.state, to: next)
        try EpisodeTerminalCleanupJournal.recordCleanup(database: database, episodeID: episodeID, workID: workID, from: work.state, ticks: budget.terminalTicks)
    }
    private func cleanupEpisodeTargetLocked(episodeID: String, workID: String) throws {
        guard let database else { throw AuthorityStateError.integrity }
        let pending = try authorityLedgerTransaction { () -> Bool in
            try requireAccountingConfidenceLocked()
            guard let episode = try findEpisode(episodeID), episode.state != .active else { return false }
            let rows = try query("SELECT episode_id,state FROM episode_work WHERE id=?", [.text(workID)]) { (string($0, 0), string($0, 1)) }
            guard let row = rows.first else { return false }
            guard episodeIdentifierEqual(row.0, episodeID) else { throw EpisodeBudgetError.conflict }
            return ["prepared", "dispatchArmed", "submitted"].contains(row.1)
        }
        guard pending else { return }
        _ = try authorityLedgerTransaction {
            try requireAccountingConfidenceLocked()
            return try EpisodeTerminalCleanupJournal.chargeAttempt(database: database, episodeID: episodeID, maximumRows: 1)
        }
        try withAuthorityCacheWrites(.unknown) { try episodeCleanupCheckpoint?("after-cleanup-attempt-commit", database) }
        try authorityLedgerTransaction { try cleanupEpisodeWorkLocked(episodeID: episodeID, workID: workID) }
        let after = try EpisodeTerminalCleanupJournal.receipt(database: database, episodeID: episodeID)
        if after.pendingRows > 0 { scheduleEpisodeCleanupLocked(episodeID) }
    }
    private func drainEpisodeCleanupLocked(episodeID: String, maximumRows: Int, recovering: Bool = false) throws -> EpisodeCleanupReceipt {
        guard (1...EpisodeCleanupLimits.batchRows).contains(maximumRows), let database else { throw EpisodeBudgetError.invalid }
        let before = try authorityLedgerTransaction {
            try requireAccountingConfidenceLocked()
            return try EpisodeTerminalCleanupJournal.receipt(database: database, episodeID: episodeID)
        }
        guard before.terminalTicks > 0 && before.pendingRows > 0 else { return before }
        // Charge a bounded attempt in its own durable transaction. A failed or
        // killed batch cannot refund permission for unlimited automatic retries.
        let fundedRows = try authorityLedgerTransaction {
            try requireAccountingConfidenceLocked()
            return try EpisodeTerminalCleanupJournal.chargeAttempt(database: database, episodeID: episodeID, maximumRows: maximumRows, recovering: recovering)
        }
        try withAuthorityCacheWrites(.unknown) { try episodeCleanupCheckpoint?("after-cleanup-attempt-commit", database) }
        let result = try authorityLedgerTransaction {
            try requireAccountingConfidenceLocked()
            guard let episode = try findEpisode(episodeID), episode.state != .active else { throw AuthorityStateError.integrity }
            let ids = try query("SELECT id FROM episode_work INDEXED BY episode_cleanup_pending WHERE episode_id=? AND state IN ('prepared','dispatchArmed','submitted') ORDER BY id LIMIT ?", [.text(episodeID), .integer(fundedRows)]) { string($0, 0) }
            guard !ids.isEmpty else { throw AuthorityStateError.integrity }
            for id in ids { try cleanupEpisodeWorkLocked(episodeID: episodeID, workID: id, recovering: recovering) }
            return try EpisodeTerminalCleanupJournal.receipt(database: database, episodeID: episodeID)
        }
        if result.pendingRows > 0 { scheduleEpisodeCleanupLocked(episodeID) }
        return result
    }
    /// Internal owner maintenance uses the original episode's frozen slots. It
    /// never admits work, reads source payloads or extends the content deadline.
    func drainEpisodeCleanup(episodeID: String, maximumRows: Int = EpisodeCleanupLimits.batchRows) throws -> EpisodeCleanupReceipt {
        try authorityLedgerLocked {
            try validateIdentifier(episodeID, name: "episode ID")
            return try drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: maximumRows)
        }
    }
    func episodeCleanupReceipt(episodeID: String) throws -> EpisodeCleanupReceipt {
        try authorityLedgerLocked {
            try authorityLedgerTransaction {
                try validateIdentifier(episodeID, name: "episode ID")
                try requireAccountingConfidenceLocked()
                guard let database else { throw AuthorityStateError.integrity }
                return try EpisodeTerminalCleanupJournal.receipt(database: database, episodeID: episodeID)
            }
        }
    }
    private func recoverPendingEpisodeCleanup() throws {
        // Administrative owner-open validation already established integrity.
        // Enumerate episode IDs with a cursor; never materialize all work rows.
        var previous: String?
        while true {
            let ids = try query("SELECT b.episode_id FROM episode_cleanup_budget b JOIN episodes e ON e.id=b.episode_id WHERE e.state!='active' AND b.pending_rows>0" + (previous == nil ? "" : " AND b.episode_id>?") + " ORDER BY b.episode_id LIMIT 1", previous.map { [.text($0)] } ?? []) { string($0, 0) }
            guard let id = ids.first else { break }
            var receipt: EpisodeCleanupReceipt
            repeat { receipt = try drainEpisodeCleanupLocked(episodeID: id, maximumRows: EpisodeCleanupLimits.batchRows, recovering: true) } while receipt.pendingRows > 0
            previous = id
        }
    }
    /// Returns an error only after the lifecycle mutation has committed.
    private func advanceEpisodeClock(_ episode: EpisodeReceipt, clock: EpisodeClockSnapshot) throws -> EpisodeBudgetError? {
        try validateEpisodeClock(clock)
        guard episode.state == .active else { return .inactive }
        let previous = try query("SELECT last_ticks FROM episodes WHERE id=?", [.text(episode.id)]) { UInt64(sqlite3_column_int64($0, 0)) }.first ?? 0
        if !episodeIdentifierEqual(episode.clockDomain, clock.domain) || clock.continuousNanoseconds < previous {
            try terminalizeEpisode(episode, reason: .interrupted, ticks: previous)
            return .clockUnavailable
        }
        try execute("UPDATE episodes SET last_ticks=? WHERE id=?", [.integer(Int(clock.continuousNanoseconds)), .text(episode.id)])
        if clock.continuousNanoseconds >= episode.deadlineNanoseconds {
            try terminalizeEpisode(episode, reason: .deadlineExceeded, ticks: clock.continuousNanoseconds)
            return .deadlineExceeded
        }
        return nil
    }

    func acceptRequestAndBeginEpisode(conversationID: String, turnID: String, humanEventID: String, episodeID: String, text: String, limits: EpisodeLimits, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt {
        try acceptRequestAndBeginEpisodeCore(conversationID: conversationID, turnID: turnID, humanEventID: humanEventID,
            episodeID: episodeID, text: text, limits: limits, clock: clock, managedAuthority: nil, buildBinding: nil)
    }
    private func acceptRequestAndBeginEpisodeCore(conversationID: String, turnID: String, humanEventID: String, episodeID: String,
        text: String, limits: EpisodeLimits, clock: EpisodeClockSnapshot, managedAuthority: AuthorityContext?,
        buildBinding: (() throws -> AuthorityEpisodeBinding)?) throws -> EpisodeReceipt {
        try authorityLedgerLocked {
            try validateEpisodeClock(clock); try validateEpisodeLimits(limits)
            for id in [turnID, humanEventID, episodeID] { try validateIdentifier(id, name: "episode identifier") }
            let scope = try conversation(conversationID), payload = try validatePayload(text)
            guard !payload.isEmpty else { throw EpisodeBudgetError.invalid }
            if let existing = try findEpisode(episodeID) {
                guard episodeIdentifierEqual(existing.conversationID, conversationID), episodeIdentifierEqual(existing.projectID, scope.projectID),
                      episodeIdentifierEqual(existing.turnID, turnID), episodeIdentifierEqual(existing.humanEventID, humanEventID), existing.limits == limits,
                      let human = try findEvent(humanEventID), episodeIdentifierEqual(human.text, text), human.role == .human,
                      human.status == .complete, episodeIdentifierEqual(human.turnID, turnID) else { throw EpisodeBudgetError.conflict }
                return existing
            }
            guard try findEvent(humanEventID) == nil,
                  try query("SELECT id FROM invocations WHERE assistant_event_id=?", [.text(humanEventID)], map: { string($0, 0) }).isEmpty else { throw EpisodeBudgetError.conflict }
            _ = try requiredEpisodeCleanupLimits(limits)
            let duration = UInt64(limits.deadlineMilliseconds) * 1_000_000
            let (deadline, overflow) = clock.continuousNanoseconds.addingReportingOverflow(duration)
            guard !overflow, deadline <= UInt64(Int64.max) else { throw EpisodeBudgetError.clockUnavailable }
            let limitsJSON = try episodeJSON(limits)
            let originJSON = try episodeJSON(EpisodeOrigin.chat(conversationID: conversationID, turnID: turnID, humanEventID: humanEventID))
            try transaction {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let human = MemoryEvent(id: humanEventID, conversationID: conversationID, projectID: scope.projectID, role: .human, text: text, status: .complete, turnID: turnID, createdAt: formatter.string(from: clock.utc), digest: Self.digest(payload), byteCount: payload.count)
                try insertEvent(human, payload: payload)
                try execute("INSERT INTO episodes (id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,created_ticks,deadline_ticks,last_ticks,created_utc,origin_json,origin_digest) VALUES (?,?,?,?,?,?,?,'active',0,?,?,?,?,?,?,?)", [.text(episodeID), .text(conversationID), .text(scope.projectID), .text(turnID), .text(humanEventID), .blob(limitsJSON), .text(Self.digest(limitsJSON)), .text(clock.domain), .integer(Int(clock.continuousNanoseconds)), .integer(Int(deadline)), .integer(Int(clock.continuousNanoseconds)), .text(String(clock.utc.timeIntervalSince1970)), .blob(originJSON), .text(try Self.episodeOriginDigest(projectID: scope.projectID, originJSON: originJSON))])
                for resource in EpisodeResource.allCases {
                    try execute("INSERT INTO episode_resource_totals VALUES (?,?,0,0,?)", [.text(episodeID), .text(resource.rawValue), .integer(limits.resources[resource])])
                }
                guard let database else { throw MemoryError.database("closed owner") }
                try EpisodeAccountingJournal.createEpisode(database: database, episodeID: episodeID)
                try EpisodeTerminalCleanupJournal.create(database: database, episodeID: episodeID, limits: try requiredEpisodeCleanupLimits(limits))
                if let buildBinding, let managedAuthority {
                    try AuthorityBindingJournal.insertManagedEpisode(database: database, binding: buildBinding(), authority: managedAuthority)
                } else { try AuthorityBindingJournal.insertLegacyEpisode(database: database, id: episodeID) }
            }
            guard let result = try findEpisode(episodeID) else { throw MemoryError.database("episode publication failed") }
            return result
        }
    }
    func beginLocalReadEpisode(episodeID: String, projectID: String, binding: EpisodeLocalReadBinding,
        limits: EpisodeLimits, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt {
        try beginLocalReadEpisodeCore(episodeID: episodeID, projectID: projectID, binding: binding,
            limits: limits, clock: clock, managedAuthority: nil, buildBinding: nil)
    }
    private func beginLocalReadEpisodeCore(episodeID: String, projectID: String, binding: EpisodeLocalReadBinding,
        limits: EpisodeLimits, clock: EpisodeClockSnapshot, managedAuthority: AuthorityContext?,
        buildBinding: (() throws -> AuthorityEpisodeBinding)?) throws -> EpisodeReceipt {
        try authorityLedgerLocked {
            try validateIdentifier(episodeID, name: "episode ID"); try validateIdentifier(projectID, name: "project ID")
            try validateEpisodeClock(clock); try validateEpisodeLimits(limits); _ = try binding.validated()
            let origin = EpisodeOrigin.localRead(binding)
            if let existing = try findEpisode(episodeID) {
                guard episodeIdentifierEqual(existing.projectID, projectID), existing.origin == origin, existing.limits == limits else { throw EpisodeBudgetError.conflict }
                return existing
            }
            // A stable local request identifies one allowance across episodes
            // and projects. The matching predicate uses the unique partial index.
            let priorRequest = try query("""
                SELECT id FROM episodes WHERE json_extract(origin_json,'$.kind')='localRead'
                  AND json_extract(origin_json,'$.binding.initiator')=? AND json_extract(origin_json,'$.binding.requestID')=?
                """, [.text(binding.initiator.rawValue), .text(binding.requestID)]) { string($0, 0) }
            guard priorRequest.isEmpty else { throw EpisodeBudgetError.conflict }
            _ = try requiredEpisodeCleanupLimits(limits)
            let (deadline, overflow) = clock.continuousNanoseconds.addingReportingOverflow(UInt64(limits.deadlineMilliseconds) * 1_000_000)
            guard !overflow, deadline <= UInt64(Int64.max) else { throw EpisodeBudgetError.clockUnavailable }
            let limitsJSON = try episodeJSON(limits), originJSON = try episodeJSON(origin)
            try transaction {
                try execute("""
                    INSERT INTO episodes (id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,created_ticks,deadline_ticks,last_ticks,created_utc,origin_json,origin_digest)
                    VALUES (?,NULL,?,NULL,NULL,?,?,'active',0,?,?,?,?,?,?,?)
                    """, [.text(episodeID), .text(projectID), .blob(limitsJSON), .text(Self.digest(limitsJSON)), .text(clock.domain),
                        .integer(Int(clock.continuousNanoseconds)), .integer(Int(deadline)), .integer(Int(clock.continuousNanoseconds)),
                        .text(String(clock.utc.timeIntervalSince1970)), .blob(originJSON), .text(try Self.episodeOriginDigest(projectID: projectID, originJSON: originJSON))])
                for resource in EpisodeResource.allCases {
                    try execute("INSERT INTO episode_resource_totals VALUES (?,?,0,0,?)", [.text(episodeID), .text(resource.rawValue), .integer(limits.resources[resource])])
                }
                guard let database else { throw MemoryError.database("closed owner") }
                try EpisodeAccountingJournal.createEpisode(database: database, episodeID: episodeID)
                try EpisodeTerminalCleanupJournal.create(database: database, episodeID: episodeID, limits: try requiredEpisodeCleanupLimits(limits))
                if let buildBinding, let managedAuthority {
                    try AuthorityBindings.insertManagedEpisode(database: database, binding: buildBinding(), authority: managedAuthority)
                } else { try AuthorityBindings.insertLegacyEpisode(database: database, id: episodeID) }
            }
            guard let receipt = try findEpisode(episodeID) else { throw MemoryError.database("local read episode publication failed") }
            return receipt
        }
    }
    func reserveEpisodeWork(episodeID: String, request: EpisodeWorkRequest, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        try reserveEpisodeWorkCore(episodeID: episodeID, request: request, clock: clock, authorityBinding: nil)
    }
    private func reserveEpisodeWorkCore(episodeID: String, request: EpisodeWorkRequest, clock: EpisodeClockSnapshot,
        authorityBinding: AuthorityWorkBinding?) throws -> EpisodeWorkRecord {
        try authorityLedgerLocked {
            let clock = try episodeRuntimeClock(clock)
            try validateEpisodeClock(clock)
            for id in [episodeID, request.id] { try validateIdentifier(id, name: "episode work identifier") }
            if let parent = request.parentID { try validateIdentifier(parent, name: "parent work identifier") }
            _ = try request.resources.validated()
            if request.resources.inputTokens > 0 || request.resources.outputTokens > 0 { guard request.resources.modelCalls > 0 else { throw EpisodeBudgetError.invalid } }
            switch request.kind {
            case .calibration, .answer, .nativeInference, .queryEmbedding:
                guard request.resources.modelCalls == 1 else { throw EpisodeBudgetError.invalid }
            case .providerDiscovery, .tokenizer:
                guard request.resources.modelCalls == 0, request.resources.httpAttempts == 1 else { throw EpisodeBudgetError.invalid }
            case .retrieval, .sourceRead, .authorityValidation:
                guard request.resources.modelCalls == 0 else { throw EpisodeBudgetError.invalid }
            }
            guard !request.adapterIdentity.isEmpty, request.adapterIdentity.utf8.count <= 2048, !request.adapterIdentity.contains("\0") else { throw EpisodeBudgetError.invalid }
            if request.adapterIdentity.hasPrefix("http:") || request.adapterIdentity.hasPrefix("https:") { try validateProviderIdentity(request.adapterIdentity) }
            if let snapshot = request.snapshot { try validateRequestBody(snapshot) }
            guard let originEpisode = try findEpisode(episodeID) else { throw MemoryError.missing("episode") }
            if originEpisode.origin.isLocalRead {
                guard [.retrieval, .sourceRead, .queryEmbedding, .authorityValidation].contains(request.kind), request.resources.outputTokens == 0 else { throw EpisodeBudgetError.invalid }
            }
            guard let database else { throw MemoryError.database("closed owner") }
            let managedEpisode = try AuthorityBindingJournal.managedEpisode(database: database, id: episodeID)
            guard (managedEpisode == nil) == (authorityBinding == nil) else { throw AuthorityStateError.unauthorized }
            if request.kind == .authorityValidation { guard authorityBinding != nil else { throw AuthorityStateError.unauthorized } }
            if let existing = try findEpisodeWork(request.id) {
                guard episodeIdentifierEqual(existing.episodeID, episodeID), existing.request == request else { throw EpisodeBudgetError.conflict }
                if let authorityBinding {
                    guard let retained = try AuthorityBindingJournal.managedWork(database: database, id: request.id),
                        try AuthorityStateKernel.canonical(retained) == AuthorityStateKernel.canonical(authorityBinding) else { throw AuthorityStateError.conflict }
                }
                return existing
            }
            var failure: EpisodeBudgetError?
            try transaction {
                guard let episode = try findEpisode(episodeID) else { throw MemoryError.missing("episode") }
                if let problem = try advanceEpisodeClock(episode, clock: clock) { failure = problem; return }
                if !request.inputTokensKnown && request.resources.modelCalls > 0 && episode.limits.requireKnownModelInput {
                    failure = .unobservableInput; return
                }
                if let parent = request.parentID {
                    guard let work = try findEpisodeWork(parent), episodeIdentifierEqual(work.episodeID, episodeID) else { throw EpisodeBudgetError.invalid }
                }
                guard try !episodeAdapterQuarantined(request.adapterIdentity) else { failure = .adapterViolation; return }
                let accounting = try EpisodeAccountingJournal.summary(database: database, episodeID: episodeID)
                let workCount = accounting.workCount
                var snapshotBytes = accounting.snapshotBytes
                if let snapshot = request.snapshot {
                    let digest = Self.digest(snapshot)
                    if try !EpisodeAccountingJournal.hasSnapshot(database: database, episodeID: episodeID, digest: digest) {
                        let (next, overflow) = snapshotBytes.addingReportingOverflow(snapshot.count)
                        guard !overflow else { throw EpisodeBudgetError.invalid }
                        snapshotBytes = next
                    }
                }
                guard workCount < Self.maximumEpisodeWorkRecords, snapshotBytes <= Self.maximumEpisodeSnapshotBytes,
                    try EpisodeTerminalCleanupJournal.canReserve(database: database, episodeID: episodeID) else {
                    try terminalizeEpisode(episode, reason: .budgetExceeded, ticks: clock.continuousNanoseconds)
                    failure = .exhausted; return
                }
                let total = try episode.charged.adding(episode.held).adding(request.resources)
                guard total.fits(within: episode.limits.resources) else {
                    try terminalizeEpisode(episode, reason: .budgetExceeded, ticks: clock.continuousNanoseconds)
                    failure = .exhausted; return
                }
                let encoded = EpisodeWorkRequest(id: request.id, parentID: request.parentID, kind: request.kind, resources: request.resources, adapterIdentity: request.adapterIdentity, snapshot: nil, inputTokensKnown: request.inputTokensKnown)
                let metadata = try episodeJSON(encoded)
                if let snapshot = request.snapshot {
                    let digest = Self.digest(snapshot)
                    if let old = try query("SELECT payload FROM episode_request_snapshots WHERE digest=?", [.text(digest)], map: { blob($0, 0) }).first {
                        guard old == snapshot else { throw EpisodeBudgetError.conflict }
                    } else { try execute("INSERT INTO episode_request_snapshots VALUES (?,?,?)", [.text(digest), .integer(snapshot.count), .blob(snapshot)]) }
                }
                // Nullable bindings use a prepared NULL expression rather than sentinel IDs.
                let parentSQL = request.parentID == nil ? "NULL" : "?", snapshotSQL = request.snapshot == nil ? "NULL" : "?"
                var bindings: [Value] = [.text(request.id), .text(episodeID)]
                if let parent = request.parentID { bindings.append(.text(parent)) }
                bindings += [.text(request.kind.rawValue), .text(request.adapterIdentity), .blob(metadata), .text(Self.digest(metadata))]
                if let snapshot = request.snapshot { bindings.append(.text(Self.digest(snapshot))) }
                bindings += [.integer(episode.revision), .blob(try episodeJSON(EpisodeResources.zero)), .blob(try episodeJSON(request.resources)), .integer(Int(clock.continuousNanoseconds))]
                try execute("INSERT INTO episode_work (id,episode_id,parent_id,kind,adapter_identity,request_json,request_digest,snapshot_digest,revision,state,charged_json,held_json,created_ticks) VALUES (?, ?, " + parentSQL + ",?,?,?,?," + snapshotSQL + ",?,'prepared',?,?,?)", bindings)
                try updateEpisodeTotals(episode, replacing: nil, charged: .zero, held: request.resources)
                try withAuthorityCacheWrites(.unknown) {
                    try self.episodeAccountingCheckpoint?("after-work-before-accounting", database)
                }
                try requireAccountingConfidenceLocked()
                try EpisodeAccountingJournal.recordReservedWork(database: database, episodeID: episodeID, request: request,
                    snapshotDigest: request.snapshot.map(Self.digest), snapshotByteCount: request.snapshot?.count ?? 0)
                try EpisodeTerminalCleanupJournal.recordReserved(database: database, episodeID: episodeID, workID: request.id)
                if let authorityBinding { try AuthorityBindingJournal.insertManagedWork(database: database, binding: authorityBinding) }
                else { try AuthorityBindingJournal.insertLegacyWork(database: database, id: request.id) }
            }
            if let failure {
                _ = try drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: EpisodeCleanupLimits.batchRows)
                throw failure
            }
            guard let result = try findEpisodeWork(request.id) else { throw MemoryError.database("episode reservation publication failed") }
            return result
        }
    }
    /// Keep full observation keys in the journal, while quarantine spans
    /// capacity/capability changes and the historical epoch key format.
    /// Matching is binary and validates each candidate's known identity shape.
    /// Unsupported adapter names retain their original exact-key semantics.
    private func episodeAdapterQuarantined(_ adapterIdentity: String) throws -> Bool {
        guard let database else { throw MemoryError.database("closed owner") }
        if sqlite3_get_autocommit(database) != 0 {
            return try transaction { try episodeAdapterQuarantined(adapterIdentity) }
        }
        try requireAccountingConfidenceLocked()
        return try EpisodeAccountingJournal.isQuarantined(database: database, adapterIdentity: adapterIdentity)
    }
    private func armEpisodeWorkLocked(episodeID: String, operationID: String, expectedRevision: Int, clock: EpisodeClockSnapshot, managedValidation: Bool = false) throws -> EpisodeWorkRecord {
        let clock = try episodeRuntimeClock(clock)
        var failure: EpisodeBudgetError?
        try authorityLedgerTransaction {
            guard let episode = try findEpisode(episodeID), let work = try findEpisodeWork(operationID), episodeIdentifierEqual(work.episodeID, episodeID) else { throw MemoryError.missing("episode work") }
            guard let database else { throw MemoryError.database("closed owner") }
            if try AuthorityBindingJournal.managedWork(database: database, id: operationID) != nil {
                guard managedValidation && work.request.kind == .authorityValidation else { throw AuthorityStateError.unauthorized }
            }
            if episode.origin.isLocalRead {
                guard [.retrieval, .sourceRead, .queryEmbedding, .authorityValidation].contains(work.request.kind), work.request.resources.outputTokens == 0 else { throw EpisodeBudgetError.invalid }
            }
            if let problem = try advanceEpisodeClock(episode, clock: clock) { failure = problem; return }
            guard expectedRevision == work.revision, expectedRevision == episode.revision else { failure = .staleRevision; return }
            if try episodeAdapterQuarantined(work.request.adapterIdentity) {
                try terminalizeEpisode(episode, reason: .failed, ticks: clock.continuousNanoseconds)
                failure = .adapterViolation; return
            }
            if work.state == .dispatchArmed { return }
            guard work.state == .prepared else { failure = .conflict; return }
            var charged = work.request.resources, held = EpisodeResources.zero
            held.outputTokens = charged.outputTokens; charged.outputTokens = 0
            try updateEpisodeTotals(episode, replacing: work, charged: charged, held: held)
            try execute("UPDATE episode_work SET state='dispatchArmed',charged_json=?,held_json=?,armed_ticks=? WHERE id=?", [.blob(try episodeJSON(charged)), .blob(try episodeJSON(held)), .integer(Int(clock.continuousNanoseconds)), .text(operationID)])
            try EpisodeAccountingJournal.recordTransition(database: database, episodeID: episodeID, request: work.request,
                from: work.state, to: .dispatchArmed)
            try EpisodeTerminalCleanupJournal.recordTransition(database: database, episodeID: episodeID, workID: operationID, from: work.state, to: .dispatchArmed)
        }
        if let failure {
            _ = try drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: EpisodeCleanupLimits.batchRows)
            throw failure
        }
        guard let result = try findEpisodeWork(operationID) else { throw MemoryError.database("episode arming failed") }
        return result
    }
    func armEpisodeWork(episodeID: String, operationID: String, expectedRevision: Int, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        try locked { try armEpisodeWorkLocked(episodeID: episodeID, operationID: operationID, expectedRevision: expectedRevision, clock: clock) }
    }
    func performEpisodeHandoff(episodeID: String, operationID: String, expectedRevision: Int, clock: EpisodeClockSnapshot, start: () -> Void) throws -> EpisodeWorkRecord {
        try locked {
            let work = try armEpisodeWorkLocked(episodeID: episodeID, operationID: operationID, expectedRevision: expectedRevision, clock: clock)
            // Arming is committed. Only this short synchronous handoff holds the
            // owner mutex, so Stop cannot interleave between its check and start.
            if let episode = try findEpisode(episodeID) {
                let finalClock = try episodeRuntimeClock(clock)
                if episode.state != .active || !episodeIdentifierEqual(finalClock.domain, episode.clockDomain) || finalClock.continuousNanoseconds >= episode.deadlineNanoseconds {
                    try transaction { try terminalizeEpisode(episode, reason: .deadlineExceeded, ticks: finalClock.continuousNanoseconds) }
                    _ = try drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: EpisodeCleanupLimits.batchRows)
                    throw EpisodeBudgetError.deadlineExceeded
                }
            } else { throw MemoryError.missing("episode") }
            start()
            try authorityLedgerTransaction {
                try requireAccountingConfidenceLocked()
                try execute("UPDATE episode_work SET state='submitted' WHERE id=? AND state='dispatchArmed'", [.text(operationID)])
                guard let database else { throw MemoryError.database("closed owner") }
                try EpisodeAccountingJournal.recordTransition(database: database, episodeID: episodeID,
                    request: work.request, from: .dispatchArmed, to: .submitted)
                try EpisodeTerminalCleanupJournal.recordTransition(database: database, episodeID: episodeID, workID: operationID, from: .dispatchArmed, to: .submitted)
            }
            guard let result = try findEpisodeWork(work.id) else { throw MemoryError.database("episode handoff failed") }
            return result
        }
    }

    func settleEpisodeWork(episodeID: String, operationID: String, settlement: EpisodeWorkSettlement, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        try authorityLedgerLocked {
            let clock = try episodeRuntimeClock(clock)
            try validateEpisodeClock(clock)
            for id in [episodeID, operationID, settlement.receiptID] { try validateIdentifier(id, name: "episode receipt identifier") }
            if let observed = settlement.observed { _ = try observed.validated() }
            if let evidence = settlement.evidence {
                guard evidence.count <= 16384 else { throw EpisodeBudgetError.invalid }
                try validateRequestBody(evidence)
            }
            try transaction {
                guard let episode = try findEpisode(episodeID) else { throw MemoryError.missing("episode") }
                if episode.state == .active { _ = try advanceEpisodeClock(episode, clock: clock) }
            }
            try cleanupEpisodeTargetLocked(episodeID: episodeID, workID: operationID)
            var failure: EpisodeBudgetError?
            try transaction {
                guard let episode = try findEpisode(episodeID) else { throw MemoryError.missing("episode") }
                guard let work = try findEpisodeWork(operationID), episodeIdentifierEqual(work.episodeID, episodeID) else { throw MemoryError.missing("episode work") }
                let oldData = try query("SELECT receipt_json FROM episode_work WHERE id=?", [.text(operationID)], map: { blob($0, 0) }).first ?? Data()
                var receipts = oldData.isEmpty ? [] : try episodeDecode([EpisodeWorkSettlement].self, oldData)
                if let previous = receipts.first(where: { episodeIdentifierEqual($0.receiptID, settlement.receiptID) }) {
                    guard previous == settlement else { failure = .conflict; return }
                    return
                }
                guard let database else { throw MemoryError.database("closed owner") }
                if try EpisodeAccountingJournal.settlementOwner(database: database, episodeID: episodeID, receiptID: settlement.receiptID) != nil {
                    failure = .conflict; return
                }
                guard receipts.count < 3 else { failure = .conflict; return }
                let wasPrepared = work.state == .prepared || work.state == .cancelledBeforeDispatch
                if !wasPrepared && work.state != .dispatchArmed && work.state != .submitted && work.state != .outcomeUnknown {
                    failure = .conflict; return
                }
                if work.state == .outcomeUnknown && !receipts.isEmpty && settlement.outcome == .outcomeUnknown {
                    // Identity evidence is independent of observed usage. A
                    // single late violation may follow unknown work without
                    // releasing its output bound; a later usage receipt can
                    // still settle that bound.
                    guard receipts.count == 1, receipts[0].outcome == .outcomeUnknown,
                          !receipts[0].adapterViolation, settlement.adapterViolation,
                          settlement.observed == nil else { failure = .conflict; return }
                }
                if settlement.outcome == .cancelledBeforeDispatch && !wasPrepared { failure = .conflict; return }
                if wasPrepared && settlement.outcome != .cancelledBeforeDispatch && settlement.outcome != .failedConfirmed { failure = .conflict; return }
                if wasPrepared && settlement.observed != nil && settlement.observed != .zero { failure = .adapterViolation; return }
                var charged = work.charged, held = work.held
                var violation = settlement.adapterViolation
                if wasPrepared { held = .zero }
                else if let observed = settlement.observed {
                    for resource in EpisodeResource.allCases {
                        if resource == .outputTokens {
                            if observed[resource] > work.request.resources[resource] { violation = true }
                            charged[resource] = max(charged[resource], observed[resource]); held[resource] = 0
                        } else {
                            if observed[resource] > work.request.resources[resource] { violation = true }
                            if resource == .inputTokens && work.request.inputTokensKnown && work.request.resources.modelCalls > 0 && observed[resource] != work.request.resources[resource] { violation = true }
                            // Bound charges preserve declared attempts/raw passes even
                            // when an adapter reports fewer observed units.
                            charged[resource] = max(charged[resource], observed[resource])
                        }
                    }
                }
                // Missing usage retains all uncertain output headroom. A label
                // such as failedConfirmed cannot establish token nonuse alone.
                let nextState: EpisodeWorkState
                switch settlement.outcome {
                case .completed: nextState = .completed
                case .failedConfirmed: nextState = .failedConfirmed
                case .outcomeUnknown: nextState = .outcomeUnknown
                case .cancelledBeforeDispatch: nextState = .cancelledBeforeDispatch
                }
                receipts.append(settlement)
                let receiptData = try episodeJSON(receipts)
                try updateEpisodeTotals(episode, replacing: work, charged: charged, held: held)
                try execute("UPDATE episode_work SET state=?,charged_json=?,held_json=?,observed_json=?,receipt_id=?,receipt_json=?,receipt_digest=?,ended_ticks=?,adapter_violation=max(adapter_violation,?) WHERE id=?", [.text(nextState.rawValue), .blob(try episodeJSON(charged)), .blob(try episodeJSON(held)), .blob(try settlement.observed.map(episodeJSON) ?? Data()), .text(settlement.receiptID), .blob(receiptData), .text(Self.digest(receiptData)), .integer(Int(clock.continuousNanoseconds)), .integer(violation ? 1 : 0), .text(operationID)])
                try withAuthorityCacheWrites(.unknown) {
                    try self.episodeAccountingCheckpoint?("after-settlement-before-accounting", database)
                }
                try requireAccountingConfidenceLocked()
                try EpisodeAccountingJournal.recordTransition(database: database, episodeID: episodeID, request: work.request,
                    from: work.state, to: nextState)
                try EpisodeTerminalCleanupJournal.recordTransition(database: database, episodeID: episodeID, workID: operationID, from: work.state, to: nextState)
                try EpisodeAccountingJournal.recordSettlement(database: database, episodeID: episodeID,
                    workID: operationID, ordinal: receipts.count - 1, settlement: settlement)
                if violation { try EpisodeAccountingJournal.recordQuarantine(database: database, workID: operationID, adapterIdentity: work.request.adapterIdentity) }
                if violation {
                    guard let changed = try findEpisode(episodeID) else { throw MemoryError.database("episode disappeared") }
                    try terminalizeEpisode(changed, reason: .failed, ticks: clock.continuousNanoseconds)
                    failure = .adapterViolation
                }
            }
            if let failure {
                _ = try drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: EpisodeCleanupLimits.batchRows)
                throw failure
            }
            if let budget = try database.map({ try EpisodeTerminalCleanupJournal.receipt(database: $0, episodeID: episodeID) }), budget.terminalTicks > 0 && budget.pendingRows > 0 { scheduleEpisodeCleanupLocked(episodeID) }
            guard let result = try findEpisodeWork(operationID) else { throw MemoryError.database("episode settlement publication failed") }
            return result
        }
    }
    func finishEpisode(episodeID: String, reason: EpisodeState, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt {
        try authorityLedgerLocked {
            let clock = try episodeRuntimeClock(clock)
            try validateIdentifier(episodeID, name: "episode ID"); try validateEpisodeClock(clock)
            guard reason != .active else { throw EpisodeBudgetError.invalid }
            var closedNow = false
            try transaction {
                guard let episode = try findEpisode(episodeID) else { throw MemoryError.missing("episode") }
                if episode.state == .active {
                    closedNow = true
                    if let _ = try advanceEpisodeClock(episode, clock: clock) { return }
                    try terminalizeEpisode(episode, reason: reason, ticks: clock.continuousNanoseconds)
                }
            }
            if closedNow {
                if let database { try withAuthorityCacheWrites(.unknown) { try episodeCleanupCheckpoint?("after-terminal-fence-commit", database) } }
                _ = try drainEpisodeCleanupLocked(episodeID: episodeID, maximumRows: EpisodeCleanupLimits.batchRows)
            }
            guard let result = try findEpisode(episodeID) else { throw MemoryError.database("episode terminal publication failed") }
            return result
        }
    }
    func episodeReceipt(id: String, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt {
        try authorityLedgerLocked {
            let clock = try episodeRuntimeClock(clock)
            try validateIdentifier(id, name: "episode ID"); try validateEpisodeClock(clock)
            var closedNow = false
            try transaction {
                guard let episode = try findEpisode(id) else { throw MemoryError.missing("episode") }
                if episode.state == .active { closedNow = try advanceEpisodeClock(episode, clock: clock) != nil }
            }
            if closedNow { _ = try drainEpisodeCleanupLocked(episodeID: id, maximumRows: EpisodeCleanupLimits.batchRows) }
            guard let result = try findEpisode(id) else { throw MemoryError.database("episode unavailable") }
            return result
        }
    }
    private func recoverInterruptedEpisodes() throws {
        try transaction {
            let ids = try query("SELECT id,last_ticks FROM episodes WHERE state='active' ORDER BY id") { (string($0, 0), UInt64(sqlite3_column_int64($0, 1))) }
            let now = try? SystemEpisodeClock().now()
            for (id, previous) in ids {
                guard let episode = try findEpisode(id) else { throw MemoryError.database("interrupted episode disappeared") }
                let comparable = episodeIdentifierEqual(now?.domain, episode.clockDomain)
                let ticks = comparable ? max(previous, now!.continuousNanoseconds) : previous
                let reason: EpisodeState = comparable && ticks >= episode.deadlineNanoseconds ? .deadlineExceeded : .interrupted
                try terminalizeEpisode(episode, reason: reason, ticks: ticks)

            }
        }
    }

    func episodeWork(episodeID: String, operationID: String) throws -> EpisodeWorkRecord? {
        try authorityLedgerLocked {
            try validateIdentifier(episodeID, name: "episode ID"); try validateIdentifier(operationID, name: "work ID")
            let terminalPending = try authorityLedgerTransaction {
                try requireAccountingConfidenceLocked()
                return try query("SELECT w.episode_id FROM episode_work w JOIN episode_cleanup_budget b ON b.episode_id=w.episode_id WHERE w.id=? AND b.terminal_ticks>0 AND w.state IN ('prepared','dispatchArmed','submitted')", [.text(operationID)]) { string($0, 0) }.first
            }
            if let terminalPending, episodeIdentifierEqual(terminalPending, episodeID) { try cleanupEpisodeTargetLocked(episodeID: episodeID, workID: operationID) }
            return try authorityLedgerTransaction {
                try requireAccountingConfidenceLocked()
                guard let work = try findEpisodeWork(operationID) else { return nil }
                guard episodeIdentifierEqual(work.episodeID, episodeID) else { throw EpisodeBudgetError.conflict }
                return work
            }
        }
    }

    /// Read-only archive validation. This accepts active snapshot records as
    /// well as recovered records; it never migrates or terminalizes a store.
    static func validateEpisodeJournal(database: OpaquePointer) throws {
        func rows<T>(_ sql: String, _ map: (OpaquePointer) throws -> T) throws -> [T] {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else { throw MemoryError.database("invalid episode archive schema") }
            defer { sqlite3_finalize(statement) }
            var results: [T] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return results }
                guard code == SQLITE_ROW else { throw MemoryError.database("episode archive query failed") }
                results.append(try map(statement))
            }
        }
        func text(_ row: OpaquePointer, _ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(row, column) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
        }
        func data(_ row: OpaquePointer, _ column: Int32) -> Data {
            guard let pointer = sqlite3_column_blob(row, column) else { return Data() }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, column)))
        }
        func identifier(_ value: String) throws {
            guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else { throw MemoryError.database("invalid episode archive identifier") }
        }
        func decode<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
            guard !bytes.isEmpty, bytes.count <= 65536 else { throw MemoryError.database("invalid episode archive metadata bounds") }
            do { return try JSONDecoder().decode(type, from: bytes) }
            catch { throw MemoryError.database("invalid episode archive metadata") }
        }
        func credentialFree(_ bytes: Data) throws {
            guard !bytes.isEmpty, bytes.count <= maximumPayloadBytes,
                  String(data: bytes, encoding: .utf8) != nil,
                  let parsed = try? JSONSerialization.jsonObject(with: bytes) else { throw MemoryError.database("invalid episode archive JSON") }
            let forbidden = Set(["apikey", "authorization", "proxyauthorization", "password", "accesstoken", "bearer", "token", "headers", "cookies"])
            func forbiddenKey(_ value: Any) -> Bool {
                if let object = value as? [String: Any] {
                    return object.contains { key, child in
                        let normalized = key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
                        return forbidden.contains(normalized) || forbiddenKey(child)
                    }
                }
                if let array = value as? [Any] { return array.contains(where: forbiddenKey) }
                return false
            }
            guard !forbiddenKey(parsed) else { throw MemoryError.database("episode archive contains forbidden credential metadata") }
        }
        let snapshots = try rows("SELECT digest,byte_count,payload FROM episode_request_snapshots") { row -> String in
            let payload = data(row, 2), digest = text(row, 0)
            guard payload.count == Int(sqlite3_column_int64(row, 1)), Self.digest(payload) == digest else { throw MemoryError.database("episode archive snapshot integrity failure") }
            try credentialFree(payload)
            return digest
        }
        guard Set(snapshots).count == snapshots.count else { throw MemoryError.database("duplicate episode archive snapshots") }
        let schemaVersion = try rows("PRAGMA user_version") { Int(sqlite3_column_int64($0, 0)) }.first ?? -1
        guard schemaVersion == 3 || schemaVersion == 4 || schemaVersion == 5 || schemaVersion == 6 || schemaVersion == 7 || schemaVersion == 8 || schemaVersion == 9 || schemaVersion == 10 else { throw MemoryError.database("unsupported episode archive schema") }
        if schemaVersion >= 6 { try AuthorityStateJournal.validate(database: database) }
        if schemaVersion >= 7 { try AuthorityBindingJournal.validate(database: database) }
        if schemaVersion >= 8 { try EpisodeAccountingJournal.validate(database: database) }
        if schemaVersion >= 9 { try EpisodeTerminalCleanupJournal.validate(database: database) }
        if schemaVersion >= 10 { try SourceTimeSchema.validate(database: database) }
        else { try SourceTimeSchema.requireAbsent(database: database) }
        struct CheckEpisode { let id: String; let origin: EpisodeOrigin; let limits: EpisodeLimits; let state: EpisodeState; let revision: Int; let created: Int; let deadline: Int; let last: Int }
        let originColumns = schemaVersion >= 4 ? ",origin_json,origin_digest" : ""
        var localReadRequestIDs = Set<Data>()
        let episodes = try rows("SELECT id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,created_ticks,deadline_ticks,last_ticks,created_utc,terminal_reason" + originColumns + " FROM episodes") { row -> CheckEpisode in
            for index: Int32 in [0,2,9] { try identifier(text(row, index)) }
            let origin: EpisodeOrigin
            if schemaVersion >= 4 {
                let originBytes = data(row, 15)
                guard try Self.episodeOriginDigest(projectID: text(row, 2), originJSON: originBytes) == text(row, 16) else { throw MemoryError.database("episode archive origin integrity failure") }
                origin = try decode(EpisodeOrigin.self, originBytes)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(origin) == originBytes else { throw MemoryError.database("episode archive origin is not canonical") }
            } else {
                origin = .chat(conversationID: text(row, 1), turnID: text(row, 3), humanEventID: text(row, 4))
                _ = try origin.validated()
            }
            switch origin {
            case .chat(let conversation, let turn, let human):
                guard [Int32(1), 3, 4].allSatisfy({ sqlite3_column_type(row, $0) != SQLITE_NULL }),
                      episodeIdentifierEqual(text(row, 1), conversation), episodeIdentifierEqual(text(row, 3), turn), episodeIdentifierEqual(text(row, 4), human) else { throw MemoryError.database("episode archive chat origin linkage failure") }
            case .localRead(let binding):
                guard [Int32(1), 3, 4].allSatisfy({ sqlite3_column_type(row, $0) == SQLITE_NULL }),
                      localReadRequestIDs.insert(Data((binding.initiator.rawValue + "\0" + binding.requestID).utf8)).inserted else { throw MemoryError.database("episode archive read origin linkage failure") }
            }
            let bytes = data(row, 5)
            guard Self.digest(bytes) == text(row, 6), let state = EpisodeState(rawValue: text(row, 7)) else { throw MemoryError.database("episode archive integrity failure") }
            try credentialFree(bytes)
            let limits = try decode(EpisodeLimits.self, bytes); _ = try limits.resources.validated(); try identifier(limits.version)
            _ = try limits.componentPolicy?.validated()
            _ = try limits.terminalCleanup?.validated()
            let revision = Int(sqlite3_column_int64(row, 8)), created = Int(sqlite3_column_int64(row, 10)), deadline = Int(sqlite3_column_int64(row, 11)), last = Int(sqlite3_column_int64(row, 12))
            guard limits.deadlineMilliseconds > 0, limits.deadlineMilliseconds <= 86_400_000,
                  created > 0, deadline > created, last >= created, revision >= 0,
                  deadline - created == limits.deadlineMilliseconds * 1_000_000,
                  sqlite3_column_double(row, 13).isFinite,
                  state == .active ? (text(row, 14).isEmpty && revision == 0) : (text(row, 14) == state.rawValue && revision > 0) else { throw MemoryError.database("invalid episode archive lifecycle") }
            return CheckEpisode(id: text(row, 0), origin: origin, limits: limits, state: state, revision: revision, created: created, deadline: deadline, last: last)
        }
        let invalidScopes = try rows("SELECT count(*) FROM episodes ep LEFT JOIN conversations c ON c.id=ep.conversation_id LEFT JOIN events e ON e.id=ep.human_event_id WHERE ep.conversation_id IS NOT NULL AND (c.id IS NULL OR e.id IS NULL OR ep.project_id!=c.project_id OR e.project_id!=ep.project_id OR e.conversation_id!=ep.conversation_id OR e.turn_id!=ep.turn_id OR e.role!='human' OR e.status!='complete')") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard invalidScopes == 0 else { throw MemoryError.database("episode archive scope mismatch") }
        struct CheckWork { let id: String; let episodeID: String; let request: EpisodeWorkRequest; let charged: EpisodeResources; let held: EpisodeResources; let violation: Bool }
        var receiptIDs = Set<Data>()
        let works = try rows("SELECT id,episode_id,parent_id,kind,adapter_identity,request_json,request_digest,snapshot_digest,revision,state,charged_json,held_json,observed_json,receipt_id,receipt_json,receipt_digest,created_ticks,armed_ticks,ended_ticks,recovered,adapter_violation FROM episode_work") { row -> CheckWork in
            let id = text(row, 0), episodeID = text(row, 1)
            try identifier(id); try identifier(episodeID)
            let metadata = data(row, 5)
            guard Self.digest(metadata) == text(row, 6), let state = EpisodeWorkState(rawValue: text(row, 9)) else { throw MemoryError.database("episode work archive integrity failure") }
            try credentialFree(metadata)
            let request = try decode(EpisodeWorkRequest.self, metadata)
            _ = try request.resources.validated()
            guard episodeIdentifierEqual(request.id, id), request.snapshot == nil, episodeIdentifierEqual(request.parentID, sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : text(row, 2)), request.kind.rawValue == text(row, 3), episodeIdentifierEqual(request.adapterIdentity, text(row, 4)),
                  !request.adapterIdentity.isEmpty, request.adapterIdentity.utf8.count <= 2048, !request.adapterIdentity.contains("\0"),
                  let episode = episodes.first(where: { episodeIdentifierEqual($0.id, episodeID) }), sqlite3_column_int64(row, 8) >= 0,
                  sqlite3_column_int64(row, 8) <= episode.revision,
                  sqlite3_column_int64(row, 16) >= episode.created,
                  [0,1].contains(sqlite3_column_int(row, 19)), [0,1].contains(sqlite3_column_int(row, 20)) else { throw MemoryError.database("invalid episode archive work linkage") }
            if episode.origin.isLocalRead {
                guard [.retrieval, .sourceRead, .queryEmbedding, .authorityValidation].contains(request.kind), request.resources.outputTokens == 0 else { throw MemoryError.database("local read episode archive contains generative work") }
            }
            switch request.kind {
            case .calibration, .answer, .nativeInference, .queryEmbedding:
                guard request.resources.modelCalls == 1 else { throw MemoryError.database("episode archive model call mismatch") }
            case .providerDiscovery, .tokenizer:
                guard request.resources.modelCalls == 0, request.resources.httpAttempts == 1 else { throw MemoryError.database("episode archive HTTP attempt mismatch") }
            case .retrieval, .sourceRead, .authorityValidation:
                guard request.resources.modelCalls == 0 else { throw MemoryError.database("episode archive retrieval call mismatch") }
            }
            guard (request.resources.inputTokens == 0 && request.resources.outputTokens == 0) || request.resources.modelCalls > 0 else { throw MemoryError.database("episode archive tokens lack model call") }
            let snapshot = text(row, 7)
            if !snapshot.isEmpty { guard snapshots.contains(snapshot) else { throw MemoryError.database("episode archive snapshot missing") } }
            let charged = try decode(EpisodeResources.self, data(row, 10)).validated(), held = try decode(EpisodeResources.self, data(row, 11)).validated()
            let observedBytes = data(row, 12)
            let observed = observedBytes.isEmpty ? nil : try decode(EpisodeResources.self, observedBytes).validated()
            let receiptBytes = data(row, 14)
            guard (receiptBytes.isEmpty ? "" : Self.digest(receiptBytes)) == text(row, 15) else { throw MemoryError.database("episode archive receipt integrity failure") }
            let receipts = receiptBytes.isEmpty ? [] : try decode([EpisodeWorkSettlement].self, receiptBytes)
            guard receipts.count <= 3, episodeIdentifierEqual(receipts.last?.receiptID, sqlite3_column_type(row, 13) == SQLITE_NULL ? nil : text(row, 13)), receipts.last?.observed == observed else { throw MemoryError.database("episode archive receipt linkage mismatch") }
            let createdTicks = sqlite3_column_int64(row, 16), armedTicks = sqlite3_column_int64(row, 17), endedTicks = sqlite3_column_int64(row, 18)
            guard createdTicks <= episode.last, createdTicks < episode.deadline,
                  armedTicks == 0 || (armedTicks >= createdTicks && armedTicks < episode.deadline),
                  endedTicks == 0 || endedTicks >= max(createdTicks, armedTicks) else {
                throw MemoryError.database("episode archive work clock mismatch")
            }
            if let last = receipts.last {
                guard state.rawValue == last.outcome.rawValue, endedTicks > 0 else {
                    throw MemoryError.database("episode archive terminal state disagrees with receipt")
                }
                if receipts.count >= 2 {
                    guard receipts[0].outcome == .outcomeUnknown, receipts[0].observed == nil,
                          last.outcome != .cancelledBeforeDispatch else {
                        throw MemoryError.database("episode archive receipt transition mismatch")
                    }
                    if receipts[1].outcome == .outcomeUnknown {
                        guard !receipts[0].adapterViolation, receipts[1].adapterViolation, receipts[1].observed == nil else {
                            throw MemoryError.database("episode archive unknown receipt has no new identity evidence")
                        }
                    } else if receipts.count == 3 { throw MemoryError.database("episode archive terminal receipt replay mismatch") }
                    if receipts.count == 3, last.outcome == .outcomeUnknown { throw MemoryError.database("episode archive repeated unknown receipt") }
                }
            } else {
                guard state != .completed && state != .failedConfirmed, observed == nil else {
                    throw MemoryError.database("episode archive terminal receipt missing")
                }
                if state == .prepared || state == .dispatchArmed || state == .submitted {
                    guard endedTicks == 0 else { throw MemoryError.database("episode archive unfinished work has terminal clock") }
                } else {
                    guard endedTicks > 0, state != .outcomeUnknown || episode.state != .active else {
                        throw MemoryError.database("episode archive recovery state mismatch")
                    }
                }
            }
            for receipt in receipts {
                try identifier(receipt.receiptID)
                guard receiptIDs.insert(Data((episodeID + "\0" + receipt.receiptID).utf8)).inserted else { throw MemoryError.database("duplicate episode archive receipt ID") }
                if let evidence = receipt.evidence { guard evidence.count <= 16384 else { throw MemoryError.database("episode archive receipt exceeds bound") }; try credentialFree(evidence) }
                if let usage = receipt.observed { _ = try usage.validated() }
            }
            let violation = sqlite3_column_int(row, 20) == 1
            if state == .prepared { guard charged == .zero, held == request.resources, (episode.state == .active || schemaVersion >= 9), sqlite3_column_int64(row, 17) == 0, receipts.isEmpty else { throw MemoryError.database("invalid prepared episode archive work") } }
            if state == .cancelledBeforeDispatch || (state == .failedConfirmed && sqlite3_column_int64(row, 17) == 0) { guard held == .zero, charged == .zero, observed == nil || observed == .zero else { throw MemoryError.database("invalid unarmed terminal episode archive work") } }
            if state == .dispatchArmed || state == .submitted { guard (episode.state == .active || schemaVersion >= 9), sqlite3_column_int64(row, 17) > 0, receipts.isEmpty else { throw MemoryError.database("invalid armed episode archive work") } }
            if state != .prepared && state != .cancelledBeforeDispatch && !(state == .failedConfirmed && sqlite3_column_int64(row, 17) == 0) {
                guard sqlite3_column_int64(row, 17) > 0 else { throw MemoryError.database("episode archive work never armed") }
                for resource in EpisodeResource.allCases {
                    if resource != .outputTokens { guard charged[resource] >= request.resources[resource], held[resource] == 0 else { throw MemoryError.database("episode archive lost armed charge") } }
                    if !violation { guard charged[resource] <= request.resources[resource], held[resource] <= request.resources[resource] else { throw MemoryError.database("episode archive work exceeds reservation") } }
                }
                if observed == nil { guard charged.outputTokens == 0, held.outputTokens == request.resources.outputTokens else { throw MemoryError.database("episode archive lost unknown output bound") } }
                else { guard held.outputTokens == 0 else { throw MemoryError.database("episode archive output settlement inconsistent") } }
                if let observed {
                    let numericViolation = EpisodeResource.allCases.contains { observed[$0] > request.resources[$0] }
                        || (request.inputTokensKnown && request.resources.modelCalls > 0 && observed.inputTokens != request.resources.inputTokens)
                    if numericViolation || receipts.contains(where: { $0.adapterViolation }) { guard violation else { throw MemoryError.database("episode archive adapter violation flag missing") } }
                } else if receipts.contains(where: { $0.adapterViolation }) { guard violation else { throw MemoryError.database("episode archive adapter violation flag missing") } }
            }
            return CheckWork(id: id, episodeID: episodeID, request: request, charged: charged, held: held, violation: violation)
        }
        for work in works {
            if let parent = work.request.parentID { guard works.contains(where: { episodeIdentifierEqual($0.id, parent) && episodeIdentifierEqual($0.episodeID, work.episodeID) }) else { throw MemoryError.database("episode archive parent scope mismatch") } }
        }
        let totals = try rows("SELECT episode_id,resource,charged,held,cap FROM episode_resource_totals") { row -> (String, EpisodeResource, Int, Int, Int) in
            guard let resource = EpisodeResource(rawValue: text(row, 1)) else { throw MemoryError.database("unknown episode archive resource") }
            return (text(row, 0), resource, Int(sqlite3_column_int64(row, 2)), Int(sqlite3_column_int64(row, 3)), Int(sqlite3_column_int64(row, 4)))
        }
        guard totals.count == episodes.count * EpisodeResource.allCases.count else { throw MemoryError.database("episode archive resource totals incomplete") }
        let snapshotTotals = try rows("SELECT ep.id,coalesce(sum(s.byte_count),0) FROM episodes ep LEFT JOIN (SELECT DISTINCT episode_id,snapshot_digest FROM episode_work WHERE snapshot_digest IS NOT NULL) w ON w.episode_id=ep.id LEFT JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest GROUP BY ep.id") { (text($0, 0), Int(sqlite3_column_int64($0, 1))) }
        for episode in episodes {
            var spent = EpisodeResources.zero, reserved = EpisodeResources.zero
            let ownWorks = works.filter { episodeIdentifierEqual($0.episodeID, episode.id) }
            guard ownWorks.count <= maximumEpisodeWorkRecords else { throw MemoryError.database("episode archive work row bound exceeded") }
            guard snapshotTotals.first(where: { episodeIdentifierEqual($0.0, episode.id) })?.1 ?? 0 <= maximumEpisodeSnapshotBytes else { throw MemoryError.database("episode archive snapshot bound exceeded") }
            for work in ownWorks { spent = try spent.adding(work.charged); reserved = try reserved.adding(work.held) }
            for resource in EpisodeResource.allCases {
                let matches = totals.filter { episodeIdentifierEqual($0.0, episode.id) && $0.1 == resource }
                guard matches.count == 1, matches[0].2 == spent[resource], matches[0].3 == reserved[resource], matches[0].4 == episode.limits.resources[resource] else { throw MemoryError.database("episode archive totals disagree with work") }
            }
            if !(try spent.adding(reserved)).fits(within: episode.limits.resources) { guard ownWorks.contains(where: { $0.violation }) else { throw MemoryError.database("episode archive budget exceeded without adapter violation") } }
        }
        let invocationMismatchSQL = """
            SELECT count(*) FROM invocations i
            LEFT JOIN episodes ep ON ep.id=i.episode_id
            LEFT JOIN episode_work w ON w.id=i.episode_work_id
            WHERE (i.episode_id IS NULL)!=(i.episode_work_id IS NULL)
               OR (i.episode_id IS NOT NULL AND (
                    ep.id IS NULL OR w.id IS NULL OR w.episode_id!=ep.id
                    OR ep.conversation_id IS NULL OR ep.turn_id IS NULL OR ep.human_event_id IS NULL
                    OR i.conversation_id!=ep.conversation_id OR i.project_id!=ep.project_id
                    OR i.turn_id!=ep.turn_id OR i.human_event_id!=ep.human_event_id
                    OR w.kind NOT IN ('answer','nativeInference')
                    OR w.snapshot_digest IS NULL OR w.snapshot_digest!=i.request_digest
                    OR (i.final_status='complete' AND ep.state!='completed')
                    OR (i.recovered=1 AND ep.state='cancelled' AND (
                        i.terminal_reason!='cancelled'
                        OR i.final_status!=CASE WHEN i.observed_bytes=0 THEN 'cancelled' ELSE 'partial' END))
                    OR (i.recovered=1 AND i.terminal_reason='cancelled' AND ep.state!='cancelled')
               ))
            """
        let invocationMismatch = try rows(invocationMismatchSQL) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard invocationMismatch == 0 else { throw MemoryError.database("episode archive invocation linkage mismatch") }
        try ContextComponentJournal.validate(database: database)
    }

}
// Durable optional maintenance shares a single global allowance in the main
// store. Every clock sample below occurs after acquiring the owner mutex.
final class SystemBackgroundIndexClock: BackgroundIndexClockSource {
    private let clock = SystemEpisodeClock()
    func now() throws -> BackgroundIndexClockSnapshot {
        let value = try clock.now()
        return try BackgroundIndexClockSnapshot(domain: value.domain, continuousNanoseconds: value.continuousNanoseconds, utc: value.utc)
    }
}

extension MemoryStore {
    private func createBackgroundIndexSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS background_index_windows (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              id TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN ('active','closed')),
              revision INTEGER NOT NULL CHECK(revision>=0),
              limits_json BLOB NOT NULL CHECK(length(limits_json)>0 AND length(limits_json)<=65536), limits_digest TEXT NOT NULL,
              started_clock_json BLOB NOT NULL CHECK(length(started_clock_json)>0 AND length(started_clock_json)<=65536), started_clock_digest TEXT NOT NULL,
              window_json BLOB NOT NULL CHECK(length(window_json)>0 AND length(window_json)<=262144),
              window_digest TEXT NOT NULL
            )
            """)
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS background_index_active_window ON background_index_windows(state) WHERE state='active'")
        try execute("""
            CREATE TABLE IF NOT EXISTS background_index_work (
              id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES background_index_windows(id),
              state TEXT NOT NULL CHECK(state IN ('prepared','armed','submitted','completed','failedConfirmed','outcomeUnknown','cancelledBeforeDispatch')),
              adapter_identity TEXT NOT NULL, binding_digest TEXT NOT NULL, request_digest TEXT NOT NULL,
              record_json BLOB NOT NULL CHECK(length(record_json)>0 AND length(record_json)<=262144),
              record_digest TEXT NOT NULL, receipt_id TEXT UNIQUE,
              adapter_violation INTEGER NOT NULL DEFAULT 0 CHECK(adapter_violation IN (0,1))
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS background_index_work_window ON background_index_work(window_id,id)")
        try execute("CREATE INDEX IF NOT EXISTS background_index_adapter_violation ON background_index_work(adapter_identity) WHERE adapter_violation=1")
    }

    private func backgroundWindow(_ id: String? = nil) throws -> BackgroundIndexWindow? {
        let sql = "SELECT id,state,revision,window_json,window_digest,limits_json,limits_digest,started_clock_json,started_clock_digest FROM background_index_windows " + (id == nil ? "WHERE state='active'" : "WHERE id=?")
        return try query(sql, id.map { [.text($0)] } ?? []) { row in
            let payload = blob(row, 3)
            guard Self.digest(payload) == string(row, 4) else { throw BackgroundIndexBudgetError.invalid }
            let window = try BackgroundIndexCanonical.decode(BackgroundIndexWindow.self, bytes: payload)
            let limitsBytes = blob(row, 5), clockBytes = blob(row, 7)
            guard backgroundIndexIdentifierEqual(window.id, string(row, 0)), window.state.rawValue == string(row, 1),
                  window.revision == Int(sqlite3_column_int64(row, 2)), Self.digest(limitsBytes) == string(row, 6),
                  Self.digest(clockBytes) == string(row, 8),
                  try BackgroundIndexCanonical.decode(BackgroundIndexLimits.self, bytes: limitsBytes) == window.limits,
                  try BackgroundIndexCanonical.decode(BackgroundIndexClockSnapshot.self, bytes: clockBytes) == window.startedClock else { throw BackgroundIndexBudgetError.invalid }
            return window
        }.first
    }
    private func saveBackgroundWindow(_ window: BackgroundIndexWindow) throws {
        try window.validate()
        let payload = try BackgroundIndexCanonical.data(window)
        let limits = try BackgroundIndexCanonical.data(window.limits), clock = try BackgroundIndexCanonical.data(window.startedClock)
        try execute("INSERT INTO background_index_windows(id,state,revision,window_json,window_digest,limits_json,limits_digest,started_clock_json,started_clock_digest) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,revision=excluded.revision,window_json=excluded.window_json,window_digest=excluded.window_digest",
            [.text(window.id), .text(window.state.rawValue), .integer(window.revision), .blob(payload), .text(Self.digest(payload)), .blob(limits), .text(Self.digest(limits)), .blob(clock), .text(Self.digest(clock))])
    }
    private func findBackgroundWork(_ id: String) throws -> BackgroundIndexWorkRecord? {
        try query("SELECT id,window_id,state,adapter_identity,binding_digest,request_digest,record_json,record_digest,receipt_id,adapter_violation FROM background_index_work WHERE id=?", [.text(id)]) { row in
            let payload = blob(row, 6)
            guard Self.digest(payload) == string(row, 7) else { throw BackgroundIndexBudgetError.invalid }
            let work = try BackgroundIndexCanonical.decode(BackgroundIndexWorkRecord.self, bytes: payload)
            guard backgroundIndexIdentifierEqual(work.request.id, string(row, 0)), backgroundIndexIdentifierEqual(work.windowID, string(row, 1)),
                  work.state.rawValue == string(row, 2), backgroundIndexIdentifierEqual(work.request.binding.adapterIdentity, string(row, 3)),
                  work.bindingDigest == string(row, 4), work.requestDigest == string(row, 5),
                  Int(sqlite3_column_int64(row, 9)) == (work.settlement?.adapterViolation == true ? 1 : 0),
                  backgroundIndexIdentifierEqual(work.settlement?.receiptID, sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : string(row, 8)) else {
                throw BackgroundIndexBudgetError.invalid
            }
            return work
        }.first
    }
    private func saveBackgroundWork(_ work: BackgroundIndexWorkRecord) throws {
        try work.validate()
        let payload = try BackgroundIndexCanonical.data(work)
        guard payload.count <= BackgroundIndexCanonical.maximumCanonicalRecordBytes else { throw BackgroundIndexBudgetError.invalid }
        let receipt: Value = work.settlement.map { .text($0.receiptID) } ?? .null
        try execute("INSERT INTO background_index_work(id,window_id,state,adapter_identity,binding_digest,request_digest,record_json,record_digest,receipt_id,adapter_violation) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,record_json=excluded.record_json,record_digest=excluded.record_digest,receipt_id=excluded.receipt_id,adapter_violation=excluded.adapter_violation",
            [.text(work.request.id), .text(work.windowID), .text(work.state.rawValue), .text(work.request.binding.adapterIdentity), .text(work.bindingDigest), .text(work.requestDigest), .blob(payload), .text(Self.digest(payload)), receipt, .integer(work.settlement?.adapterViolation == true ? 1 : 0)])
    }
    private func backgroundAdapterQuarantined(_ adapter: String) throws -> Bool {
        try !query("SELECT id FROM background_index_work WHERE adapter_identity=? AND adapter_violation=1 LIMIT 1", [.text(adapter)]) { string($0, 0) }.isEmpty
    }
    private func backgroundValidateSource(_ binding: BackgroundIndexBinding) throws {
        guard case .source(_, let descriptor) = binding.descriptor else { return }
        let source = descriptor.source
        guard let reference = try sourceReference(eventID: source.eventID, projectID: source.projectID),
              reference.sequence == source.sequence, backgroundIndexIdentifierEqual(reference.conversationID, source.conversationID),
              reference.role.rawValue == source.role, reference.status.rawValue == source.status,
              backgroundIndexIdentifierEqual(reference.createdAt, source.createdAt), reference.digest == source.digest,
              reference.byteCount == source.byteCount else { throw BackgroundIndexBudgetError.scopeMismatch }
    }
    private func observeBackgroundWindow(_ window: BackgroundIndexWindow, clock: BackgroundIndexClockSnapshot) throws -> BackgroundIndexWindowDecision {
        let decision = try window.observed(at: clock)
        try saveBackgroundWindow(decision.window)
        return decision
    }
    func reserveBackgroundWork(request: BackgroundIndexWorkRequest, clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock(),
                               limits: BackgroundIndexLimits = .development) throws -> BackgroundIndexWorkRecord {
        try locked {
            let clock = try clockSource.now(); try clock.validate(); try request.validate(); try limits.validate()
            var failure: Error?
            var result: BackgroundIndexWorkRecord?
            try transaction {
                if let existing = try findBackgroundWork(request.id) {
                    guard existing.request == request else { throw BackgroundIndexBudgetError.conflict }
                    result = existing; return
                }
                guard !(try backgroundAdapterQuarantined(request.binding.adapterIdentity)) else { throw BackgroundIndexBudgetError.adapterViolation }
                let previous = try backgroundWindow()
                if let previous, previous.limits != limits { throw BackgroundIndexBudgetError.conflict }
                let decision = try previous.map { try observeBackgroundWindow($0, clock: clock) }
                if decision?.pauseReason == .clockUnavailable { failure = BackgroundIndexBudgetError.clockUnavailable; return }
                let rotating = decision?.rolloverEligible == true
                let candidate = try previous == nil || rotating
                    ? BackgroundIndexWindow.begin(id: UUID().uuidString, limits: previous?.limits ?? limits, clock: clock,
                        previousUTCHighWaterMilliseconds: previous?.utcHighWaterMilliseconds)
                    : decision!.window
                let count = try query("SELECT count(*) FROM background_index_work WHERE window_id=?", [.text(candidate.id)]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
                guard count < Self.maximumBackgroundWorkRecords else { throw BackgroundIndexBudgetError.invalid }
                let reserved: BackgroundIndexWindow
                do { reserved = try candidate.reserving(request) }
                catch BackgroundIndexBudgetError.exhausted { failure = BackgroundIndexBudgetError.exhausted; return }
                if rotating, var old = decision?.window {
                    let prepared = try query("SELECT id FROM background_index_work WHERE window_id=? AND state='prepared' ORDER BY id", [.text(old.id)]) { string($0, 0) }
                    for id in prepared {
                        guard let work = try findBackgroundWork(id) else { throw BackgroundIndexBudgetError.invalid }
                        old = try old.releasingPrepared(work.request)
                        try saveBackgroundWork(work.settled(BackgroundIndexWorkSettlement(receiptID: UUID().uuidString, outcome: .cancelledBeforeDispatch)))
                    }
                    try saveBackgroundWindow(old.closing(at: clock))
                }
                try saveBackgroundWindow(reserved)
                let work = try BackgroundIndexWorkRecord.prepared(windowID: reserved.id, request: request, clock: clock)
                try saveBackgroundWork(work); result = work
            }
            if let failure { throw failure }
            guard let result else { throw BackgroundIndexBudgetError.invalid }; return result
        }
    }
    func armBackgroundWork(workID: String, bindingDigest: String, clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock()) throws -> BackgroundIndexWorkRecord {
        try locked {
            let clock = try clockSource.now(); try clock.validate(); try BackgroundIndexCanonical.identifier(workID)
            return try transaction {
                guard let work = try findBackgroundWork(workID) else { throw BackgroundIndexBudgetError.inactive }
                try work.accepts(bindingDigest: bindingDigest)
                guard !(try backgroundAdapterQuarantined(work.request.binding.adapterIdentity)) else { throw BackgroundIndexBudgetError.adapterViolation }
                guard work.state == .prepared else { throw BackgroundIndexBudgetError.inactive }
                guard let window = try backgroundWindow(work.windowID), window.state == .active else { throw BackgroundIndexBudgetError.inactive }
                let decision = try observeBackgroundWindow(window, clock: clock)
                guard !decision.rolloverEligible, decision.pauseReason != .clockUnavailable else { throw BackgroundIndexBudgetError.inactive }
                let armed = try work.armed(at: clock)
                try saveBackgroundWindow(decision.window.arming(work.request)); try saveBackgroundWork(armed)
                return armed
            }
        }
    }
    private func backgroundLiveWork(workID: String, bindingDigest: String, clock: BackgroundIndexClockSnapshot) throws -> BackgroundIndexWorkRecord {
        guard let work = try findBackgroundWork(workID), [.armed, .submitted].contains(work.state) else { throw BackgroundIndexBudgetError.inactive }
        try work.accepts(bindingDigest: bindingDigest)
        guard let armedClock = work.armedClock, backgroundIndexIdentifierEqual(armedClock.domain, clock.domain),
              clock.continuousNanoseconds >= armedClock.continuousNanoseconds else { throw BackgroundIndexBudgetError.clockUnavailable }
        guard !(try backgroundAdapterQuarantined(work.request.binding.adapterIdentity)) else { throw BackgroundIndexBudgetError.adapterViolation }
        return work
    }
    func checkBackgroundPublication(workID: String, bindingDigest: String, clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock()) throws -> BackgroundIndexWorkRecord {
        try locked {
            let clock = try clockSource.now(); try clock.validate()
            return try prepareBackgroundPublicationLocked(workID: workID, bindingDigest: bindingDigest, clock: clock)
        }
    }
    private func prepareBackgroundPublicationLocked(workID: String, bindingDigest: String, clock: BackgroundIndexClockSnapshot) throws -> BackgroundIndexWorkRecord {
        try transaction {
            let work = try backgroundLiveWork(workID: workID, bindingDigest: bindingDigest, clock: clock)
            try backgroundValidateSource(work.request.binding)
            try backgroundSourceExecutionComplete(work)
            if let window = try backgroundWindow(work.windowID), window.state == .active {
                _ = try observeBackgroundWindow(window, clock: clock)
            }
            let submitted = work.state == .armed ? try work.submitted() : work
            try saveBackgroundWork(submitted); return submitted
        }
    }
    /// Caller already holds its sidecar mutex. The operation may perform only
    /// bounded SQL/commit on that already-held sidecar, with no new sidecar
    /// lock, source read, hashing, encoder or blocking observer. This preserves
    /// sidecar -> main lock order through the final publication boundary.
    func withBackgroundPublication<T>(workID: String, bindingDigest: String,
                                      clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock(),
                                      operation: () throws -> T) throws -> T {
        try locked {
            let clock = try clockSource.now(); try clock.validate()
            _ = try prepareBackgroundPublicationLocked(workID: workID, bindingDigest: bindingDigest, clock: clock)
            // The main journal transaction committed before sidecar SQL. If
            // the process dies after sidecar commit, submitted work retains
            // its maximum charge and recovers unknown without encoder replay.
            return try operation()
        }
    }
    func settleBackgroundWork(workID: String, settlement: BackgroundIndexWorkSettlement, clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock()) throws -> BackgroundIndexWorkRecord {
        try locked {
            let clock = try clockSource.now(); try clock.validate(); try settlement.validate()
            let result = try transaction {
                guard let work = try findBackgroundWork(workID), let window = try backgroundWindow(work.windowID) else { throw BackgroundIndexBudgetError.inactive }
                if let existing = work.settlement {
                    guard existing == settlement else { throw BackgroundIndexBudgetError.conflict }; return work
                }
                if settlement.outcome == .completed { try backgroundSourceExecutionComplete(work) }
                let updated = try work.settled(settlement)
                var observedWindow = window
                if window.state == .active { observedWindow = try observeBackgroundWindow(window, clock: clock).window }
                if work.state == .prepared { observedWindow = try observedWindow.releasingPrepared(work.request) }
                try saveBackgroundWindow(observedWindow); try saveBackgroundWork(updated); return updated
            }
            let id = Data(workID.utf8)
            claimedBackgroundReaders.remove(id); completedBackgroundSeals.remove(id); completedBackgroundChunkReads.remove(id)
            return result
        }
    }
    func backgroundWork(workID: String) throws -> BackgroundIndexWorkRecord? {
        try locked { try BackgroundIndexCanonical.identifier(workID); return try findBackgroundWork(workID) }
    }
    func backgroundBudgetSnapshot(clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock()) throws -> BackgroundIndexBudgetSnapshot {
        try locked {
            let clock = try clockSource.now(); try clock.validate()
            return try transaction {
                guard let window = try backgroundWindow() else { return try BackgroundIndexBudgetSnapshot(window: nil) }
                let decision = try observeBackgroundWindow(window, clock: clock)
                let remaining = try decision.window.remaining()
                let exhausted = remaining.isZero || BackgroundIndexResource.allCases.contains { remaining[$0] == 0 }
                return try BackgroundIndexBudgetSnapshot(window: decision.window, rolloverEligible: decision.rolloverEligible,
                    pauseReason: decision.pauseReason ?? (exhausted && !decision.rolloverEligible ? .exhausted : nil))
            }
        }
    }
    private func recoverInterruptedBackgroundWork() throws {
        guard let database else { throw BackgroundIndexBudgetError.invalid }
        try BackgroundIndexJournal.validate(database: database)
        try transaction {
            let ids = try query("SELECT id FROM background_index_work WHERE state IN ('prepared','armed','submitted') ORDER BY id") { string($0, 0) }
            for id in ids {
                guard let work = try findBackgroundWork(id), var window = try backgroundWindow(work.windowID) else { throw BackgroundIndexBudgetError.invalid }
                if work.state == .prepared { window = try window.releasingPrepared(work.request) }
                let recovered = try work.recovered(receiptID: UUID().uuidString)
                try saveBackgroundWindow(window); try saveBackgroundWork(recovered)
            }
        }
        try BackgroundIndexJournal.validate(database: database)
    }
    func makeBackgroundSourceReader(for supplied: BackgroundIndexWorkRecord, clockSource: BackgroundIndexClockSource = SystemBackgroundIndexClock()) throws -> BackgroundSourceReader {
        try locked {
            let clock = try clockSource.now(); try clock.validate()
            let work = try backgroundLiveWork(workID: supplied.request.id, bindingDigest: supplied.bindingDigest, clock: clock)
            guard work == supplied, case .source = work.request.binding.descriptor,
                  claimedBackgroundReaders.insert(Data(work.request.id.utf8)).inserted else { throw BackgroundIndexBudgetError.conflict }
            do { return try BackgroundSourceReader(owner: self, work: work, clockSource: clockSource) }
            catch { claimedBackgroundReaders.remove(Data(work.request.id.utf8)); throw error }
        }
    }
    fileprivate func backgroundReaderGate(work: BackgroundIndexWorkRecord, clockSource: BackgroundIndexClockSource) throws {
        try locked {
            let clock = try clockSource.now(); try clock.validate()
            _ = try backgroundLiveWork(workID: work.request.id, bindingDigest: work.bindingDigest, clock: clock)
        }
    }
    private func backgroundSourceExecutionComplete(_ work: BackgroundIndexWorkRecord) throws {
        guard case .source(let operation, let binding) = work.request.binding.descriptor else { return }
        let id = Data(work.request.id.utf8)
        if operation == .chunkAttempt {
            guard completedBackgroundChunkReads.contains(id) else { throw BackgroundIndexBudgetError.inactive }
        }
        if operation == .initialSeal || operation == .emptySource || binding.requiresFinalSeal {
            guard completedBackgroundSeals.contains(id) else { throw BackgroundIndexBudgetError.inactive }
        }
    }
    fileprivate func backgroundReaderPerformed(work: BackgroundIndexWorkRecord, seal: Bool, clockSource: BackgroundIndexClockSource) throws {
        try locked {
            let clock = try clockSource.now(); try clock.validate()
            _ = try backgroundLiveWork(workID: work.request.id, bindingDigest: work.bindingDigest, clock: clock)
            if seal { completedBackgroundSeals.insert(Data(work.request.id.utf8)) }
            else { completedBackgroundChunkReads.insert(Data(work.request.id.utf8)) }
        }
    }
    func backgroundReaderDiagnostics() -> BackgroundReaderDiagnostics {
        backgroundDiagnosticsLock.lock(); defer { backgroundDiagnosticsLock.unlock() }
        return BackgroundReaderDiagnostics(payloadPages: backgroundPayloadPages, materializedBytes: backgroundMaterializedBytes)
    }
    fileprivate func backgroundReadPerformed(bytes: Int) {
        backgroundDiagnosticsLock.lock(); defer { backgroundDiagnosticsLock.unlock() }
        // Diagnostic-only saturating counters have no accounting authority.
        let (pages, pagesOverflow) = backgroundPayloadPages.addingReportingOverflow(1)
        let (total, bytesOverflow) = backgroundMaterializedBytes.addingReportingOverflow(bytes)
        backgroundPayloadPages = pagesOverflow ? Int.max : pages
        backgroundMaterializedBytes = bytesOverflow ? Int.max : total
    }
    static func validateBackgroundIndexJournal(database: OpaquePointer) throws { try BackgroundIndexJournal.validate(database: database) }
}

struct BackgroundReaderDiagnostics: Equatable {
    let payloadPages: Int
    let materializedBytes: Int
}

/// A private read-only SQLite connection owns no mutable main-store handle.
/// It strongly retains the process owner, and spends only the source functions
/// authorized by its one claimed, durably armed work descriptor.
final class BackgroundSourceReader: @unchecked Sendable {
    private let owner: MemoryStore
    private let work: BackgroundIndexWorkRecord
    private let clockSource: BackgroundIndexClockSource
    private let source: BackgroundIndexSourceReference
    private let operation: BackgroundIndexSourceOperation
    private let binding: BackgroundIndexSourceBinding
    private var database: OpaquePointer?
    private let mutex = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var didChunk = false
    private var didSeal = false
    private var explicitVerifications = 0

    fileprivate init(owner: MemoryStore, work: BackgroundIndexWorkRecord, clockSource: BackgroundIndexClockSource) throws {
        guard case .source(let operation, let binding) = work.request.binding.descriptor else { throw BackgroundIndexBudgetError.invalid }
        self.owner = owner; self.work = work; self.clockSource = clockSource
        self.source = binding.source; self.operation = operation; self.binding = binding
        let path = owner.directory.appendingPathComponent("memory.sqlite3").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database); self.database = nil }
            throw MemoryError.database("background source reader could not open")
        }
        sqlite3_busy_timeout(database, 5000)
    }
    deinit { if let database { sqlite3_close(database) } }

    private func assertSource(_ reference: MemorySourceReference) throws {
        guard reference.sequence == source.sequence, backgroundIndexIdentifierEqual(reference.eventID, source.eventID),
              backgroundIndexIdentifierEqual(reference.projectID, source.projectID), backgroundIndexIdentifierEqual(reference.conversationID, source.conversationID),
              reference.role.rawValue == source.role, reference.status.rawValue == source.status,
              backgroundIndexIdentifierEqual(reference.createdAt, source.createdAt), reference.digest == source.digest,
              reference.byteCount == source.byteCount else { throw BackgroundIndexBudgetError.scopeMismatch }
    }
    private func statement(projection: String, offset: Int? = nil, length: Int? = nil) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        let sql = "SELECT " + projection + " FROM events WHERE sequence=? AND id=? AND conversation_id=? AND project_id=? AND role=? AND status=? AND created_at=? AND digest=? AND byte_count=?"
        guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let prepared = pointer else { throw BackgroundIndexBudgetError.invalid }
        do {
            var index: Int32 = 1
            if let offset, let length {
                guard sqlite3_bind_int64(prepared, index, Int64(max(1, offset))) == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }; index += 1
                guard sqlite3_bind_int64(prepared, index, Int64(length + 1)) == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }; index += 1
            }
            guard sqlite3_bind_int64(prepared, index, Int64(source.sequence)) == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }; index += 1
            for value in [source.eventID, source.conversationID, source.projectID, source.role, source.status, source.createdAt, source.digest] {
                let result = value.withCString { sqlite3_bind_text(prepared, index, $0, Int32(value.utf8.count), transient) }
                guard result == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }; index += 1
            }
            guard sqlite3_bind_int64(prepared, index, Int64(source.byteCount)) == SQLITE_OK else { throw BackgroundIndexBudgetError.invalid }
            return prepared
        } catch { sqlite3_finalize(prepared); throw error }
    }
    private func verifyLocked() throws {
        let row = try statement(projection: "1")
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW, sqlite3_step(row) == SQLITE_DONE else { throw BackgroundIndexBudgetError.scopeMismatch }
    }
    func verify(source reference: MemorySourceReference) throws {
        try owner.backgroundReaderGate(work: work, clockSource: clockSource)
        mutex.lock(); defer { mutex.unlock() }
        try assertSource(reference)
        guard explicitVerifications < 2 else { throw BackgroundIndexBudgetError.inactive }
        explicitVerifications += 1
        try verifyLocked()
    }
    private func page(offset: Int, length: Int) throws -> PayloadPage {
        guard offset >= 0, offset <= source.byteCount, length > 0, length <= MemoryStore.maximumPageBytes else { throw BackgroundIndexBudgetError.invalid }
        let row = try statement(projection: "substr(payload,?,?)", offset: offset, length: length)
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw BackgroundIndexBudgetError.scopeMismatch }
        let bytes: Data
        if let pointer = sqlite3_column_blob(row, 0) { bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, 0))) }
        else { bytes = Data() }
        owner.backgroundReadPerformed(bytes: bytes.count)
        guard sqlite3_step(row) == SQLITE_DONE, bytes.count <= length + 1 else { throw BackgroundIndexBudgetError.invalid }
        let skip = offset == 0 ? 0 : 1
        guard bytes.count >= skip else { throw BackgroundIndexBudgetError.invalid }
        let requested = Data(bytes.dropFirst(skip).prefix(length))
        if let first = requested.first, first & 0xc0 == 0x80 { throw BackgroundIndexBudgetError.invalid }
        var end = requested.count
        var text: String?
        while end >= 0 {
            text = String(data: requested.prefix(end), encoding: .utf8)
            if text != nil { break }
            end -= 1
            guard requested.count - end <= 3 else { throw BackgroundIndexBudgetError.invalid }
        }
        guard let text, end > 0 || offset == source.byteCount else { throw BackgroundIndexBudgetError.invalid }
        let next = offset + end
        guard next <= source.byteCount else { throw BackgroundIndexBudgetError.invalid }
        return PayloadPage(eventID: source.eventID, offset: offset, text: text, byteCount: end, totalBytes: source.byteCount,
            nextOffset: next < source.byteCount ? next : nil, digest: source.digest, status: CaptureStatus(rawValue: source.status)!)
    }
    func readChunk(source reference: MemorySourceReference) throws -> PayloadPage {
        try owner.backgroundReaderGate(work: work, clockSource: clockSource)
        mutex.lock(); defer { mutex.unlock() }
        try assertSource(reference)
        guard operation == .chunkAttempt, !didChunk else { throw BackgroundIndexBudgetError.inactive }
        didChunk = true
        let value = try page(offset: binding.offset, length: binding.byteCount)
        try owner.backgroundReaderPerformed(work: work, seal: false, clockSource: clockSource)
        return value
    }
    func validateCompleteSource(source reference: MemorySourceReference) throws {
        try owner.backgroundReaderGate(work: work, clockSource: clockSource)
        mutex.lock(); defer { mutex.unlock() }
        try assertSource(reference)
        guard !didSeal, operation == .initialSeal || operation == .emptySource || (operation == .chunkAttempt && binding.requiresFinalSeal) else {
            throw BackgroundIndexBudgetError.inactive
        }
        didSeal = true
        try verifyLocked()
        var digest = SHA256(), offset = 0, pages = 0
        let maximumPages = source.byteCount / 4093 + 1
        while offset < source.byteCount {
            guard pages < maximumPages else { throw BackgroundIndexBudgetError.invalid }
            let value = try page(offset: offset, length: min(4096, source.byteCount - offset))
            let payload = Data(value.text.utf8)
            guard value.offset == offset, value.byteCount > 0, payload.count == value.byteCount else { throw BackgroundIndexBudgetError.invalid }
            digest.update(data: payload); offset += value.byteCount; pages += 1
        }
        guard offset == source.byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == source.digest else { throw BackgroundIndexBudgetError.invalid }
        try verifyLocked()
        try owner.backgroundReaderPerformed(work: work, seal: true, clockSource: clockSource)
    }
}
