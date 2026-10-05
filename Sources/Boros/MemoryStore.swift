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
    let directory: URL
    private var database: OpaquePointer?
    private var ownerFD: Int32 = -1
    private let mutex = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
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
            guard (0...2).contains(version) else { throw MemoryError.invalid("unsupported database schema version") }
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
                try execute("PRAGMA user_version=2")
            }
            // The exclusive process lock is already held. Publish interrupted
            // attempts before any caller can read history or start a request.
            try recoverInterruptedInvocations()
            try secureSidecars()
        } catch {
            if let database { sqlite3_close(database); self.database = nil }
            if ownerFD >= 0 { close(ownerFD); ownerFD = -1 }
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
        if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD) }
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
            return try query("SELECT id, conversation_id, project_id, role, status, turn_id, created_at, digest, byte_count, payload FROM events WHERE conversation_id=? ORDER BY sequence", [.text(conversationID)], map: event)
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
                let sql = "WITH recent AS (SELECT sequence,SUM(byte_count) OVER (ORDER BY sequence DESC ROWS UNBOUNDED PRECEDING) AS running_bytes FROM events WHERE conversation_id=?" + exclusion + " ORDER BY sequence DESC LIMIT ?) SELECT e.id,e.conversation_id,e.project_id,e.role,e.status,e.turn_id,e.created_at,e.digest,e.byte_count,e.payload FROM recent JOIN events e ON e.sequence=recent.sequence WHERE running_bytes<=? ORDER BY e.sequence"
                return try queryEvents(sql, bindings)
            }
            return try queryEvents("SELECT id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload FROM events WHERE conversation_id=?" + exclusion + " ORDER BY sequence DESC LIMIT ?", bindings).reversed()
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
    func sourceManifest(projectID: String, afterSequence: Int, throughSequence: Int? = nil, limit: Int) throws -> [MemorySourceReference] {
        try locked {
            try validateIdentifier(projectID, name: "project ID")
            guard afterSequence >= 0, (throughSequence ?? 0) >= 0, (1...1000).contains(limit) else {
                throw MemoryError.invalid("source manifest requires nonnegative bounds and 1–1000 rows")
            }
            var bindings: [Value] = [.text(projectID), .integer(afterSequence)]
            var upperBound = ""
            if let throughSequence { upperBound = " AND sequence<=?"; bindings.append(.integer(throughSequence)) }
            bindings.append(.integer(limit))
            return try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count FROM events WHERE project_id=? AND sequence>?" + upperBound + " ORDER BY sequence LIMIT ?", bindings, map: sourceReference)
        }
    }

    func sourceReference(eventID: String, projectID: String) throws -> MemorySourceReference? {
        try locked {
            try validateIdentifier(eventID, name: "event ID")
            try validateIdentifier(projectID, name: "project ID")
            return try query("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count FROM events WHERE id=? AND project_id=?",
                [.text(eventID), .text(projectID)], map: sourceReference).first
        }
    }

    private func sourceReference(_ statement: OpaquePointer) throws -> MemorySourceReference {
        guard let role = MemoryRole(rawValue: string(statement, 4)), let status = CaptureStatus(rawValue: string(statement, 5)) else {
            throw MemoryError.database("invalid source metadata")
        }
        return MemorySourceReference(sequence: Int(sqlite3_column_int64(statement, 0)), eventID: string(statement, 1),
            conversationID: string(statement, 2), projectID: string(statement, 3), role: role, status: status,
            createdAt: string(statement, 6), digest: string(statement, 7), byteCount: Int(sqlite3_column_int64(statement, 8)))
    }

    /// Repeating an identical stable event ID returns the original event. Any
    /// changed role, scope, turn, completion status, or payload is a conflict.
    func append(conversationID: String, role: MemoryRole, text: String, status: CaptureStatus, turnID: String, eventID: String) throws -> MemoryEvent {
        try locked {
            try validateIdentifier(turnID, name: "turn ID")
            try validateIdentifier(eventID, name: "event ID")
            let payload = try validatePayload(text)
            let digest = Self.digest(payload)
            let scope = try conversation(conversationID)
            guard try query("SELECT id FROM invocations WHERE assistant_event_id=?", [.text(eventID)], map: { string($0, 0) }).isEmpty else {
                throw MemoryError.conflict("assistant event ID belongs to a durable invocation")
            }
            if let existing = try findEvent(eventID) {
                guard existing.conversationID == conversationID, existing.projectID == scope.projectID,
                      existing.role == role, existing.status == status, existing.turnID == turnID,
                      existing.digest == digest, existing.text == text else {
                    throw MemoryError.conflict("event ID was already used for different content or metadata")
                }
                return existing
            }
            let now = Self.timestamp()
            let result = MemoryEvent(id: eventID, conversationID: conversationID, projectID: scope.projectID, role: role, text: text, status: status, turnID: turnID, createdAt: now, digest: digest, byteCount: payload.count)
            try transaction {
                try insertEvent(result, payload: payload)
            }
            return result
        }
    }

    /// Commit the exact credential-free provider request before dispatch.
    /// An identical begin replay returns the same attempt, including its
    /// terminal state; beginning again never automatically dispatches it.
    func beginInvocation(invocationID: String, conversationID: String, turnID: String, humanEventID: String, assistantEventID: String, providerIdentity: String, requestBody: Data, admissionJSON: Data? = nil) throws -> StoredInvocation {
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
                guard existing.conversationID == conversationID, existing.projectID == scope.projectID,
                      existing.turnID == turnID, existing.humanEventID == humanEventID,
                      existing.assistantEventID == assistantEventID, existing.providerIdentity == providerIdentity,
                      existing.requestBody == requestBody, existing.admissionJSON == admissionJSON else {
                    throw MemoryError.conflict("invocation ID was already used for different request or scope")
                }
                return existing
            }
            guard let human = try findEvent(humanEventID), human.role == .human,
                  human.status == .complete, human.conversationID == conversationID,
                  human.projectID == scope.projectID, human.turnID == turnID else {
                throw MemoryError.invalid("invocation requires its committed complete human event in the same turn and scope")
            }
            guard humanEventID != assistantEventID, try findEvent(assistantEventID) == nil,
                  try query("SELECT id FROM invocations WHERE assistant_event_id=?", [.text(assistantEventID)], map: { string($0, 0) }).isEmpty else {
                throw MemoryError.conflict("assistant event ID was already used or reserved")
            }
            try transaction {
                try execute("INSERT INTO invocations (id,conversation_id,project_id,turn_id,human_event_id,assistant_event_id,provider_identity,request_body,request_digest,admission_json,admission_digest,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [.text(invocationID), .text(conversationID), .text(scope.projectID), .text(turnID), .text(humanEventID), .text(assistantEventID), .text(providerIdentity), .blob(requestBody), .text(Self.digest(requestBody)), .blob(admissionJSON ?? Data()), .text(admissionJSON.map(Self.digest) ?? ""), .text(Self.timestamp())])
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
        try locked {
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
    func search(query: String, projectID: String, limit: Int = 8, matching: LexicalMatchMode = .allTerms, throughSequence: Int? = nil, excludingEventIDs: Set<String> = []) throws -> [MemoryHit] {
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
            let sql = "SELECT e.id,e.conversation_id,e.project_id,e.role,e.status,e.turn_id,e.created_at,e.digest,e.byte_count,e.payload FROM event_fts JOIN events e ON e.sequence=event_fts.rowid WHERE event_fts MATCH ? AND e.project_id=?" + upperBound + exclusions + " ORDER BY bm25(event_fts),e.sequence DESC LIMIT ?"
            var bindings: [Value] = [.text(expression), .text(projectID)]
            if let throughSequence { bindings.append(.integer(throughSequence)) }
            if !excludingEventIDs.isEmpty { bindings.append(.text(String(decoding: try JSONEncoder().encode(excludingEventIDs.sorted()), as: UTF8.self))) }
            bindings.append(.integer(limit))
            return try queryEvents(sql, bindings).map { Self.hit($0, terms: terms) }
        }
    }

    /// Literal search is case-sensitive over original UTF-8 payload bytes.
    func literalSearch(query: String, projectID: String, limit: Int = 8, throughSequence: Int? = nil, excludingEventIDs: Set<String> = []) throws -> [MemoryHit] {
        try locked {
            try validateSearch(query: query, projectID: projectID, limit: limit)
            if let throughSequence, throughSequence < 0 { throw MemoryError.invalid("source frontier must be nonnegative") }
            guard excludingEventIDs.count <= 10000 else { throw MemoryError.invalid("search excludes at most 10000 sources") }
            for id in excludingEventIDs { try validateIdentifier(id, name: "excluded source ID") }
            guard !query.isEmpty else { return [] }
            let upperBound = throughSequence == nil ? "" : " AND sequence<=?"
            let exclusions = excludingEventIDs.isEmpty ? "" : " AND id NOT IN (SELECT value FROM json_each(?))"
            let sql = "SELECT id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload FROM events WHERE project_id=? AND instr(payload,?) > 0" + upperBound + exclusions + " ORDER BY sequence DESC LIMIT ?"
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
        try execute("INSERT INTO events (id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload) VALUES (?,?,?,?,?,?,?,?,?,?)", [.text(event.id), .text(event.conversationID), .text(event.projectID), .text(event.role.rawValue), .text(event.status.rawValue), .text(event.turnID), .text(event.createdAt), .text(event.digest), .integer(payload.count), .blob(payload)])
        let rowID = sqlite3_last_insert_rowid(database)
        try execute("INSERT INTO event_fts(rowid,text) VALUES (?,?)", [.integer(Int(rowID)), .text(event.text)])
        try execute("UPDATE conversations SET updated_at=? WHERE id=?", [.text(event.createdAt), .text(event.conversationID)])
    }

    private func findInvocation(_ id: String) throws -> StoredInvocation? {
        try query("SELECT id,conversation_id,project_id,turn_id,human_event_id,assistant_event_id,provider_identity,request_body,request_digest,created_at,chunk_count,observed_bytes,final_status,terminal_reason,finalized_at,recovered,admission_json,admission_digest,usage_json,usage_digest FROM invocations WHERE id=?", [.text(id)]) { statement in
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
            return StoredInvocation(id: string(statement, 0), conversationID: string(statement, 1), projectID: string(statement, 2), turnID: string(statement, 3), humanEventID: string(statement, 4), assistantEventID: string(statement, 5), providerIdentity: string(statement, 6), requestBody: body, requestDigest: digest, admissionJSON: admission.isEmpty ? nil : admission, usageJSON: usage.isEmpty ? nil : usage, createdAt: string(statement, 9), chunkCount: Int(sqlite3_column_int64(statement, 10)), observedBytes: Int(sqlite3_column_int64(statement, 11)), finalStatus: status, terminalReason: reason, finalizedAt: finalizedText.isEmpty ? nil : finalizedText, recovered: sqlite3_column_int(statement, 15) == 1)
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
        if let existingStatus = attempt.finalStatus {
            guard existingStatus == status, attempt.terminalReason == reason, attempt.usageJSON == usageJSON,
                  let existing = try findEvent(attempt.assistantEventID),
                  existing.conversationID == attempt.conversationID, existing.projectID == attempt.projectID,
                  existing.role == .assistant, existing.turnID == attempt.turnID,
                  existing.status == status, existing.text == text else {
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
                _ = try publishInvocation(attempt, status: attempt.observedBytes == 0 ? .failed : .partial, reason: .interrupted, recovered: true)
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
        try queryEvents("SELECT id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload FROM events WHERE id=?", [.text(id)]).first
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
        return MemoryEvent(id: string(statement, 0), conversationID: string(statement, 1), projectID: string(statement, 2), role: role, text: text, status: status, turnID: string(statement, 5), createdAt: string(statement, 6), digest: string(statement, 7), byteCount: bytes)
    }

    private func loadText(_ sql: String, _ key: String) throws -> String? {
        try query(sql, [.text(key)]) { statement in
            guard let result = String(data: blob(statement, 0), encoding: .utf8) else { throw MemoryError.database("invalid stored UTF-8") }
            return result
        }.first
    }

    private enum Value { case text(String), integer(Int), blob(Data) }

    private func prepare(_ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch binding {
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
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
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
    private static func hit(_ event: MemoryEvent, terms: [String], literal: Bool = false) -> MemoryHit {
        let target = terms.compactMap { event.text.range(of: $0, options: literal ? [] : [.caseInsensitive, .diacriticInsensitive]) }.first
        let center = target?.lowerBound ?? event.text.startIndex
        let lower = event.text.index(center, offsetBy: -160, limitedBy: event.text.startIndex) ?? event.text.startIndex
        let upper = event.text.index(lower, offsetBy: 560, limitedBy: event.text.endIndex) ?? event.text.endIndex
        let excerpt = String(event.text[lower..<upper])
        return MemoryHit(eventID: event.id, conversationID: event.conversationID, projectID: event.projectID, role: event.role, status: event.status, createdAt: event.createdAt, digest: event.digest, totalBytes: event.byteCount, excerptOffset: event.text[..<lower].utf8.count, excerpt: excerpt)
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
