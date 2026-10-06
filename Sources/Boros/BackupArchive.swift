import Foundation
import CryptoKit
import CSQLite
import Darwin

/// A versioned hook for the future external deletion ledger. Current stores
/// have no deletion controls: restoring a store that ever enabled them is
/// refused until ledger application and suppression verification exist.
struct BackupControlState: Codable, Equatable {
    let authorityID: String
    let epoch: UInt64
    let deletionControlsEnabled: Bool
    let ledgerDigest: String?

    static let unmanagedNoDeletion = BackupControlState(authorityID: "boros-unmanaged-schema-2", epoch: 0,
        deletionControlsEnabled: false, ledgerDigest: nil)
}

struct BackupFile: Codable, Equatable {
    let name: String
    let bytes: Int64
    let sha256: String
}

struct BackupScopeCount: Codable, Equatable {
    let projectID: String
    let conversations: Int
    let events: Int
    let sourceBytes: Int64
    let invocations: Int
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.projectID, rhs.projectID) && lhs.conversations == rhs.conversations
            && lhs.events == rhs.events && lhs.sourceBytes == rhs.sourceBytes && lhs.invocations == rhs.invocations
    }
}

struct BackupInventory: Codable, Equatable {
    let conversations: Int
    let events: Int
    let sourceBytes: Int64
    let drafts: Int
    let settings: Int
    let invocations: Int
    let unfinishedInvocations: Int
    let chunks: Int
    let chunkBytes: Int64
    let providerIdentities: [String]
    let servedModels: [String]
    let scopes: [BackupScopeCount]
    // Schema 1/2 have no episode journal. Schema 3 records the historical
    // chat-only journal; schema 4 additionally records explicit origin counts.
    var chatEpisodes: Int? = nil
    var localReadEpisodes: Int? = nil
    var episodes: Int? = nil
    var unfinishedEpisodes: Int? = nil
    var episodeWork: Int? = nil
    var episodeSnapshots: Int? = nil
    var episodeSnapshotBytes: Int64? = nil
    var episodePreparedWork: Int? = nil
    var episodeUncertainWork: Int? = nil
    var episodeCharged: EpisodeResources? = nil
    var episodeHeld: EpisodeResources? = nil
    // Schemas 5 and newer have authoritative background maintenance accounting.
    // Recognized schemas 1–4 establish that this inventory is absent.
    var backgroundIndex: BackgroundIndexInventory? = nil
    // Historical schemas 1–5 have no standing-policy/task authority state.
    // This foundation inventory is separate from the external deletion hook.
    var authorityState: AuthorityStateInventory? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        // Canonical bytes preserve SQLite's exact identifier semantics for
        // scopes, providers and model IDs, including equivalent-looking Unicode.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }
}

struct BackupManifest: Codable, Equatable {
    let archiveVersion: Int
    let databaseSchema: Int
    let archiveID: String
    let createdAt: String
    let databaseCapture: String
    let settingsCapture: String
    let control: BackupControlState
    let files: [BackupFile]
    let inventory: BackupInventory
    let excluded: [String]
}

enum BackupError: LocalizedError {
    case invalid(String)
    case database
    case io(String)
    case cancelled
    case authorityUnavailable
    case publicationDurabilityUnknown
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Backup verification failed: \(detail)."
        case .database: return "Backup database operation failed."
        case .io(let detail): return "Backup filesystem operation failed: \(detail)."
        case .cancelled: return "Backup creation was cancelled before publication."
        case .authorityUnavailable: return "Restore requires a compatible current deletion authority; applying deletion ledgers is not implemented."
        case .publicationDurabilityUnknown: return "The verified destination was published, but its parent directory sync failed; publication durability is unknown."
        }
    }
}

/// Archives contain a verified SQLite online snapshot, an optional independent
/// point capture of nonsensitive settings.json, and an inventory manifest.
/// The explicit archive destination must not exist. All directories and files
/// created here are private. Neither create nor restore replaces an item.
enum BackupArchive {
    private static let excluded = ["credentials-and-Keychain", "models-and-runtimes", "owner-lock-and-WAL-sidecars", "derived-semantic-index-rebuild-required"]
    private static let databaseCapture = "sqlite-online-backup-pinned-read-transaction"
    private static let manifestLimit = 1024 * 1024

    /// Recognize an existing offline store without opening or changing it with
    /// SQLite. The caller probes its existing owner lock before calling this.
    /// Private copies preserve WAL state and confine SHM creation/migration to
    /// scratch. A schema version number by itself is never a Boros identity.
    static func recognizeExistingSource(at directory: URL) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("boros-source-recognition-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copied = scratch.appendingPathComponent("source", isDirectory: true)
        let reference = scratch.appendingPathComponent("reference", isDirectory: true)
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try copyNewFile(from: directory.appendingPathComponent("memory.sqlite3"), to: copied.appendingPathComponent("memory.sqlite3"))
        let sourceWAL = directory.appendingPathComponent("memory.sqlite3-wal")
        if try itemExists(sourceWAL) {
            try copyNewFile(from: sourceWAL, to: copied.appendingPathComponent("memory.sqlite3-wal"))
        }
        // Source SHM is derived and never copied or opened. SQLite may create
        // a private SHM file next to the isolated copied WAL.
        // A cleanly closed WAL-mode source may have no WAL/SHM files. SQLite
        // must be allowed to create them beside this private copy to read its
        // header. The original source is still never opened or changed here.
        let candidate = try Database(copied.appendingPathComponent("memory.sqlite3"), writable: true)
        defer { candidate.close() }
        let version = try candidate.integer("PRAGMA user_version")
        guard (1...6).contains(version) else { throw BackupError.invalid("source database has an unsupported schema") }
        let actualSchema = try schemaObjects(candidate)
        candidate.close()
        guard actualSchema == (try recognizedSchemaObjects(version: version, at: reference)) else {
            throw BackupError.invalid("source table, column, index or constraint contract is not a recognized Boros schema")
        }
        // Only the already recognized private copy may undergo legacy upgrade
        // and recovery before complete content/metadata integrity checks.
        do {
            let owner = try MemoryStore(directory: copied)
            withExtendedLifetime(owner) {}
        }
        _ = try inspectDatabase(copied.appendingPathComponent("memory.sqlite3"), standalone: false)
    }

    private struct SchemaObject: Equatable {
        let type: String
        let name: String
        let table: String
        let sql: String
    }
    private static func schemaObjects(_ database: Database) throws -> [SchemaObject] {
        var result: [SchemaObject] = []
        try database.each("SELECT type,name,tbl_name,coalesce(sql,'') FROM sqlite_schema ORDER BY type,name") { row in
            let sql = database.text(row, 3).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(SchemaObject(type: database.text(row, 0), name: database.text(row, 1), table: database.text(row, 2), sql: sql))
        }
        return result
    }

    /// Frozen historical contracts captured from checkpoint 22c3402. Legacy
    /// recognition never derives old constraints by subtracting newer DDL.
    private static func historicalSchemaSQL(version: Int) throws -> String {
        if version == 5 { return AuthoritySchemaFive.sql }
        // Genuine schema 4 captured from immutable checkpoint 9cf4d11 before
        // adding background accounting. Never derive this from the current store.
        if version == 4 { return """
        CREATE TABLE conversations (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE drafts (conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), payload BLOB NOT NULL);
        CREATE TABLE episode_request_snapshots (
          digest TEXT PRIMARY KEY, byte_count INTEGER NOT NULL CHECK(byte_count>0 AND byte_count<=4194304),
          payload BLOB NOT NULL CHECK(length(payload)=byte_count)
        ) WITHOUT ROWID;
        CREATE TABLE episode_resource_totals (
          episode_id TEXT NOT NULL REFERENCES episodes(id), resource TEXT NOT NULL,
          charged INTEGER NOT NULL CHECK(charged>=0), held INTEGER NOT NULL CHECK(held>=0), cap INTEGER NOT NULL CHECK(cap>=0),
          PRIMARY KEY(episode_id,resource)
        ) WITHOUT ROWID;
        CREATE TABLE episode_work (
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
        );
        CREATE TABLE "episodes" (
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
        );
        CREATE VIRTUAL TABLE event_fts USING fts5(text, content='');
        CREATE TABLE events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          conversation_id TEXT NOT NULL REFERENCES conversations(id), project_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('human','assistant')),
          status TEXT NOT NULL CHECK(status IN ('complete','partial','failed','cancelled')),
          turn_id TEXT NOT NULL, created_at TEXT NOT NULL, digest TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK(byte_count >= 0 AND byte_count <= 4194304),
          payload BLOB NOT NULL CHECK(length(payload) = byte_count)
        );
        CREATE TABLE invocation_chunks (
          invocation_id TEXT NOT NULL REFERENCES invocations(id),
          chunk_sequence INTEGER NOT NULL CHECK(chunk_sequence >= 0 AND chunk_sequence < 65536),
          byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 4194304),
          digest TEXT NOT NULL, payload BLOB NOT NULL CHECK(length(payload) = byte_count),
          PRIMARY KEY(invocation_id, chunk_sequence)
        ) WITHOUT ROWID;
        CREATE TABLE invocations (
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
          finalized_at TEXT NOT NULL DEFAULT '', recovered INTEGER NOT NULL DEFAULT 0 CHECK(recovered IN (0,1)), episode_id TEXT REFERENCES episodes(id), episode_work_id TEXT REFERENCES episode_work(id),
          CHECK(length(request_body) > 0 AND length(request_body) <= 4194304),
          CHECK((final_status = '' AND terminal_reason = '' AND finalized_at = '') OR
                (final_status != '' AND terminal_reason != '' AND finalized_at != ''))
        );
        CREATE TABLE settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
        CREATE UNIQUE INDEX episode_local_read_request
        ON episodes(json_extract(origin_json,'$.binding.initiator'),json_extract(origin_json,'$.binding.requestID'))
        WHERE json_extract(origin_json,'$.kind')='localRead';
        CREATE INDEX episode_work_episode ON episode_work(episode_id,id);
        CREATE INDEX event_conversation ON events(conversation_id, sequence);
        CREATE INDEX event_project ON events(project_id, sequence);
        PRAGMA user_version=4;
        """ }
        guard (1...3).contains(version) else { throw BackupError.invalid("unsupported historical schema") }
        var sql = """
        CREATE TABLE IF NOT EXISTS conversations (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          conversation_id TEXT NOT NULL REFERENCES conversations(id), project_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('human','assistant')),
          status TEXT NOT NULL CHECK(status IN ('complete','partial','failed','cancelled')),
          turn_id TEXT NOT NULL, created_at TEXT NOT NULL, digest TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK(byte_count >= 0 AND byte_count <= 4194304),
          payload BLOB NOT NULL CHECK(length(payload) = byte_count)
        );
        CREATE INDEX IF NOT EXISTS event_conversation ON events(conversation_id, sequence);
        CREATE INDEX IF NOT EXISTS event_project ON events(project_id, sequence);
        CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(text, content='');
        CREATE TABLE IF NOT EXISTS drafts (conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
        """
        if version >= 2 { sql += """

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
        );
        CREATE TABLE IF NOT EXISTS invocation_chunks (
          invocation_id TEXT NOT NULL REFERENCES invocations(id),
          chunk_sequence INTEGER NOT NULL CHECK(chunk_sequence >= 0 AND chunk_sequence < 65536),
          byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 4194304),
          digest TEXT NOT NULL, payload BLOB NOT NULL CHECK(length(payload) = byte_count),
          PRIMARY KEY(invocation_id, chunk_sequence)
        ) WITHOUT ROWID;
        """ }
        if version == 3 { sql += """

        CREATE TABLE IF NOT EXISTS episodes (
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
          project_id TEXT NOT NULL, turn_id TEXT NOT NULL, human_event_id TEXT NOT NULL UNIQUE REFERENCES events(id),
          limits_json BLOB NOT NULL CHECK(length(limits_json)>0 AND length(limits_json)<=65536),
          limits_digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','completed','failed','cancelled','interrupted','deadlineExceeded','budgetExceeded')),
          revision INTEGER NOT NULL CHECK(revision>=0), clock_domain TEXT NOT NULL,
          created_ticks INTEGER NOT NULL CHECK(created_ticks>0), deadline_ticks INTEGER NOT NULL CHECK(deadline_ticks>created_ticks),
          last_ticks INTEGER NOT NULL CHECK(last_ticks>=created_ticks), created_utc REAL NOT NULL,
          terminal_reason TEXT NOT NULL DEFAULT '', CHECK((state='active' AND terminal_reason='') OR (state!='active' AND terminal_reason!=''))
        );
        CREATE TABLE IF NOT EXISTS episode_resource_totals (
          episode_id TEXT NOT NULL REFERENCES episodes(id), resource TEXT NOT NULL,
          charged INTEGER NOT NULL CHECK(charged>=0), held INTEGER NOT NULL CHECK(held>=0), cap INTEGER NOT NULL CHECK(cap>=0),
          PRIMARY KEY(episode_id,resource)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS episode_request_snapshots (
          digest TEXT PRIMARY KEY, byte_count INTEGER NOT NULL CHECK(byte_count>0 AND byte_count<=4194304),
          payload BLOB NOT NULL CHECK(length(payload)=byte_count)
        ) WITHOUT ROWID;
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
        );
        CREATE INDEX IF NOT EXISTS episode_work_episode ON episode_work(episode_id,id);
        ALTER TABLE invocations ADD COLUMN episode_id TEXT REFERENCES episodes(id);
        ALTER TABLE invocations ADD COLUMN episode_work_id TEXT REFERENCES episode_work(id);
        """ }
        return sql + "PRAGMA user_version=\(version);"
    }

    private static func recognizedSchemaObjects(version: Int, at directory: URL) throws -> [SchemaObject] {
        if version == 6 {
            // Only the current contract derives from the current owner. All
            // historical schemas 1–5 retain their frozen DDL.
            do { let owner = try MemoryStore(directory: directory); withExtendedLifetime(owner) {} }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try writeNewFile(Data(), at: directory.appendingPathComponent("memory.sqlite3"))
            let writable = try Database(directory.appendingPathComponent("memory.sqlite3"), writable: true)
            let sql = try historicalSchemaSQL(version: version)
            guard sqlite3_exec(writable.handle, sql, nil, nil, nil) == SQLITE_OK else {
                writable.close(); throw BackupError.database
            }
            writable.close()
        }
        let reference = try Database(directory.appendingPathComponent("memory.sqlite3"), writable: false)
        defer { reference.close() }
        return try schemaObjects(reference)
    }

    private static func validateSchemaObjects(_ database: Database, version: Int) throws {
        let reference = FileManager.default.temporaryDirectory.appendingPathComponent("boros-backup-contract-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: reference) }
        guard try schemaObjects(database) == recognizedSchemaObjects(version: version, at: reference) else {
            throw BackupError.invalid("table, column, index or constraint contract is not a recognized Boros schema")
        }
    }

    static func create(from store: MemoryStore, at destination: URL,
                       control: BackupControlState = .unmanagedNoDeletion,
                       cancellation: (() -> Bool)? = nil) throws -> BackupManifest {
        try requireCurrentAuthority(archive: control, current: control)
        let target = try NewDestination(destination)
        defer { target.closeParent() }
        let staging = try target.makeStaging()
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        func checkCancellation() throws { if cancellation?() == true { throw BackupError.cancelled } }
        try checkCancellation()
        let source = store.directory.appendingPathComponent("memory.sqlite3")
        try requireRegular(source)
        let snapshot = staging.appendingPathComponent("memory.sqlite3")
        try onlineSnapshot(source: source, destination: snapshot, cancellation: checkCancellation)
        let inventory = try inspectDatabase(snapshot)
        var files = [try fileRecord(snapshot, name: "memory.sqlite3")]
        let settingsSource = store.directory.appendingPathComponent("settings.json")
        var settingsCapture = "absent"
        if try itemExists(settingsSource) {
            let settings = try readFile(settingsSource, limit: manifestLimit)
            _ = try credentialFreeObject(settings)
            try writeNewFile(settings, at: staging.appendingPathComponent("settings.json"))
            files.append(try fileRecord(staging.appendingPathComponent("settings.json"), name: "settings.json"))
            settingsCapture = "independent-atomic-file-point-capture"
        }
        let manifest = BackupManifest(archiveVersion: 1, databaseSchema: 6, archiveID: UUID().uuidString,
            createdAt: timestamp(), databaseCapture: databaseCapture, settingsCapture: settingsCapture,
            control: control, files: files, inventory: inventory, excluded: excluded)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeNewFile(try encoder.encode(manifest), at: staging.appendingPathComponent("manifest.json"))
        _ = try verify(at: staging)
        try syncDirectory(staging)
        try checkCancellation()
        try target.publish(staging)
        published = true
        return manifest
    }

    static func verify(at archive: URL) throws -> BackupManifest {
        try requireDirectory(archive)
        let manifestData = try readFile(archive.appendingPathComponent("manifest.json"), limit: manifestLimit)
        let manifest: BackupManifest
        do { manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData) }
        catch { throw BackupError.invalid("missing or malformed archive manifest") }
        guard manifest.archiveVersion == 1, (1...6).contains(manifest.databaseSchema),
              UUID(uuidString: manifest.archiveID) != nil, !manifest.createdAt.isEmpty,
              manifest.databaseCapture == databaseCapture, manifest.excluded == excluded,
              ["absent", "independent-atomic-file-point-capture"].contains(manifest.settingsCapture),
              manifest.control == .unmanagedNoDeletion else {
            throw BackupError.invalid("unsupported archive format, schema, or control metadata")
        }
        let names = manifest.files.map(\.name)
        let expected = manifest.settingsCapture == "absent" ? ["memory.sqlite3"] : ["memory.sqlite3", "settings.json"]
        guard names.sorted() == expected.sorted(), Set(names).count == names.count else {
            throw BackupError.invalid("unsupported or duplicate file inventory")
        }
        let actual = try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted()
        guard actual == (expected + ["manifest.json"]).sorted() else { throw BackupError.invalid("archive contains missing or unlisted files") }
        for record in manifest.files {
            guard record.bytes >= 0, record.sha256.count == 64,
                  try fileRecord(archive.appendingPathComponent(record.name), name: record.name) == record else {
                throw BackupError.invalid("file length or checksum mismatch")
            }
        }
        if names.contains("settings.json") { _ = try credentialFreeObject(readFile(archive.appendingPathComponent("settings.json"), limit: manifestLimit)) }
        let archiveDatabase = archive.appendingPathComponent("memory.sqlite3")
        try requireStandaloneHeader(archiveDatabase)
        let schemaDB = try Database(archiveDatabase, writable: false)
        defer { schemaDB.close() }
        guard try schemaDB.integer("PRAGMA user_version") == manifest.databaseSchema,
              try inspectDatabase(archiveDatabase) == manifest.inventory else {
            throw BackupError.invalid("database inventory differs from manifest")
        }
        return manifest
    }

    /// The current authority is a required argument. This prevents a future
    /// controlled store silently restoring an old unmanaged archive. Until
    /// deletion exists, only the explicit unmanaged state is accepted.
    @discardableResult
    static func restore(from archive: URL, to destination: URL, authority: BackupControlState) throws -> BackupManifest {
        let manifest = try verify(at: archive)
        try requireCurrentAuthority(archive: manifest.control, current: authority)
        let target = try NewDestination(destination)
        defer { target.closeParent() }
        let staging = try target.makeStaging()
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        for record in manifest.files {
            let output = staging.appendingPathComponent(record.name)
            try copyNewFile(from: archive.appendingPathComponent(record.name), to: output)
            guard try fileRecord(output, name: record.name) == record else { throw BackupError.invalid("archive changed during restore") }
        }
        guard try inspectDatabase(staging.appendingPathComponent("memory.sqlite3")) == manifest.inventory else {
            throw BackupError.invalid("copied database inventory mismatch")
        }
        let preparedHold = manifest.databaseSchema >= 3
            ? try preparedEpisodeHold(staging.appendingPathComponent("memory.sqlite3")) : .zero
        let unfinishedBytes = manifest.databaseSchema == 1 ? 0 : try unfinishedInvocationBytes(staging.appendingPathComponent("memory.sqlite3"))
        // Startup recovery is completed in private staging, before publication.
        // It terminalizes archived unfinished attempts as interrupted, retaining
        // committed chunks and publishing partial/failed assistant evidence.
        do {
            let owner = try MemoryStore(directory: staging)
            try verifyExactReads(owner: owner, scopes: manifest.inventory.scopes)
            withExtendedLifetime(owner) {}
        }
        try rebuildLexicalIndex(staging.appendingPathComponent("memory.sqlite3"))
        let restored = try inspectDatabase(staging.appendingPathComponent("memory.sqlite3"), standalone: false)
        guard restored.unfinishedInvocations == 0,
              restored.conversations == manifest.inventory.conversations,
              restored.drafts == manifest.inventory.drafts,
              restored.settings == manifest.inventory.settings,
              restored.events == manifest.inventory.events + manifest.inventory.unfinishedInvocations,
              restored.sourceBytes == manifest.inventory.sourceBytes + unfinishedBytes,
              restored.invocations == manifest.inventory.invocations,
              restored.chunks == manifest.inventory.chunks,
              restored.chunkBytes == manifest.inventory.chunkBytes,
              restored.providerIdentities == manifest.inventory.providerIdentities,
              restored.servedModels == manifest.inventory.servedModels else { throw BackupError.invalid("restored startup recovery inventory mismatch") }
        if manifest.databaseSchema >= 3 {
            guard let archivedHeld = manifest.inventory.episodeHeld,
                  restored.unfinishedEpisodes == 0, restored.episodes == manifest.inventory.episodes,
                  restored.episodeWork == manifest.inventory.episodeWork,
                  restored.episodeSnapshots == manifest.inventory.episodeSnapshots,
                  restored.episodeSnapshotBytes == manifest.inventory.episodeSnapshotBytes,
                  restored.episodePreparedWork == 0,
                  restored.episodeUncertainWork == manifest.inventory.episodeUncertainWork,
                  restored.episodeCharged == manifest.inventory.episodeCharged,
                  restored.episodeHeld == (try archivedHeld.subtracting(preparedHold)),
                  restored.chatEpisodes == (manifest.databaseSchema >= 4 ? manifest.inventory.chatEpisodes : manifest.inventory.episodes),
                  restored.localReadEpisodes == (manifest.databaseSchema >= 4 ? manifest.inventory.localReadEpisodes : 0) else {
                throw BackupError.invalid("restored episode recovery inventory mismatch")
            }
        }
        if manifest.databaseSchema < 3 {
            guard restored.episodes == 0, restored.chatEpisodes == 0, restored.localReadEpisodes == 0 else {
                throw BackupError.invalid("legacy restore introduced episode records")
            }
        }
        guard let background = restored.backgroundIndex else { throw BackupError.invalid("restored background inventory is missing") }
        if manifest.databaseSchema >= 5 {
            guard let archived = manifest.inventory.backgroundIndex,
                  background.windows == archived.windows, background.works == archived.works,
                  background.prepared == 0, background.uncertain == archived.uncertain,
                  background.charged == archived.charged,
                  background.held == (try archived.held.subtracting(archived.preparedRelease)),
                  background.unknownEncoderCalls == archived.unknownEncoderCalls,
                  background.preparedRelease == .zero else {
                throw BackupError.invalid("restored background recovery inventory mismatch")
            }
        } else {
            guard manifest.inventory.backgroundIndex == nil,
                  background.windows == 0, background.works == 0,
                  background.charged == .zero, background.held == .zero,
                  background.unknownEncoderCalls == 0 else {
                throw BackupError.invalid("legacy restore introduced background work")
            }
        }
        guard let restoredAuthority = restored.authorityState else {
            throw BackupError.invalid("restored authority state inventory is missing")
        }
        if manifest.databaseSchema == 6 {
            guard let archivedAuthority = manifest.inventory.authorityState else {
                throw BackupError.invalid("archived authority state inventory is missing")
            }
            let authorityDB = try Database(staging.appendingPathComponent("memory.sqlite3"), writable: false)
            defer { authorityDB.close() }
            guard let handle = authorityDB.handle else { throw BackupError.database }
            do { try AuthorityStateJournal.validateRestore(database: handle, archived: archivedAuthority) }
            catch { throw BackupError.invalid("restored authority state recovery inventory mismatch") }
        } else {
            // Legacy archives acquire only an empty authority foundation on
            // upgrade. Historical human-role text never creates tasks/policies.
            guard manifest.inventory.authorityState == nil,
                  restoredAuthority.tasks == 0, restoredAuthority.bindings == 0, restoredAuthority.policies == 0 else {
                throw BackupError.invalid("legacy restore introduced authority records")
            }
        }
        // No stale archive manifest is placed alongside the recovered database.
        let receipt: [String: Any] = ["archive_id": manifest.archiveID, "restored_at": timestamp(),
            "archive_database_sha256": manifest.files.first { $0.name == "memory.sqlite3" }!.sha256,
            "recovered_interrupted_attempts": manifest.inventory.unfinishedInvocations,
            "recovered_interrupted_episodes": manifest.inventory.unfinishedEpisodes ?? 0,
            "derived_semantic_index": "absent-rebuild-required", "lexical_index": "rebuilt-from-exact-sources", "control_state": "unmanaged-no-deletion"]
        try writeNewFile(try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                         at: staging.appendingPathComponent("restored-from.json"))
        for name in try FileManager.default.contentsOfDirectory(atPath: staging.path) {
            try syncFile(staging.appendingPathComponent(name))
        }
        try syncDirectory(staging)
        try target.publish(staging)
        published = true
        return manifest
    }

    private static func requireCurrentAuthority(archive: BackupControlState, current: BackupControlState) throws {
        guard archive == .unmanagedNoDeletion, current == .unmanagedNoDeletion else { throw BackupError.authorityUnavailable }
    }

    private static func onlineSnapshot(source: URL, destination: URL, cancellation: () throws -> Void) throws {
        let sourceDB = try Database(source, writable: false)
        defer { sourceDB.close() }
        try sourceDB.execute("BEGIN")
        _ = try sourceDB.integer("SELECT count(*) FROM sqlite_schema") // establish the read snapshot
        defer { try? sourceDB.execute("ROLLBACK") }
        try writeNewFile(Data(), at: destination)
        let destinationDB = try Database(destination, writable: true)
        defer { destinationDB.close() }
        try destinationDB.execute("PRAGMA synchronous=FULL")
        guard let handle = sqlite3_backup_init(destinationDB.handle, "main", sourceDB.handle, "main") else { throw BackupError.database }
        var result: Int32 = SQLITE_OK
        let deadline = Date().addingTimeInterval(30)
        do {
            repeat {
                try cancellation()
                guard Date() < deadline else { throw BackupError.invalid("online snapshot exceeded its deadline") }
                result = sqlite3_backup_step(handle, 128)
                if result == SQLITE_BUSY || result == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01) }
            } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        } catch { sqlite3_backup_finish(handle); throw error }
        let finish = sqlite3_backup_finish(handle)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw BackupError.database }
        // Online backup copies the WAL mode flag. Convert the standalone
        // snapshot after completion, yielding one self-contained file.
        destinationDB.close()
        let standalone = try Database(destination, writable: true)
        defer { standalone.close() }
        try standalone.execute("PRAGMA synchronous=FULL")
        try standalone.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try standalone.execute("PRAGMA journal_mode=DELETE")
        standalone.close()
        try requireStandaloneHeader(destination)
        // SQLite may leave an unreferenced SHM file after converting the new
        // snapshot out of WAL. All snapshot connections are now closed; the
        // rollback-mode header proves it has no live WAL dependency.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if try itemExists(sidecar) { try requireRegular(sidecar); try FileManager.default.removeItem(at: sidecar) }
        }
        try syncFile(destination)
    }

    private static func inspectDatabase(_ url: URL, standalone: Bool = true) throws -> BackupInventory {
        try requireRegular(url)
        // Reject WAL-mode archives before SQLite can create sidecars while
        // reading them. A published archive is one standalone rollback-mode DB.
        if standalone { try requireStandaloneHeader(url) }
        let db = try Database(url, writable: false)
        defer { db.close() }
        let schema = try db.integer("PRAGMA user_version")
        guard (1...6).contains(schema) else { throw BackupError.invalid("unsupported database schema") }
        guard try db.texts("PRAGMA integrity_check") == ["ok"], try db.integer("SELECT count(*) FROM pragma_foreign_key_check") == 0 else {
            throw BackupError.invalid("SQLite integrity or foreign-key check failed")
        }
        try validateSchemaObjects(db, version: schema)
        var allowedTables = Set(["conversations", "events", "drafts", "settings", "sqlite_sequence", "event_fts", "event_fts_data", "event_fts_idx", "event_fts_docsize", "event_fts_config"])
        if schema >= 2 { allowedTables.formUnion(["invocations", "invocation_chunks"]) }
        if schema >= 3 { allowedTables.formUnion(["episodes", "episode_resource_totals", "episode_request_snapshots", "episode_work"]) }
        if schema >= 5 { allowedTables.formUnion(["background_index_windows", "background_index_work"]) }
        if schema == 6 { allowedTables.formUnion(AuthorityStateKernel.tableNames) }
        guard Set(try db.texts("SELECT name FROM sqlite_schema WHERE type='table'")) == allowedTables,
              try db.integer("SELECT count(*) FROM sqlite_schema WHERE type IN ('view','trigger')") == 0 else {
            throw BackupError.invalid("unsupported database object inventory")
        }
        var columns: [String: [String]] = [
            "conversations": ["id", "project_id", "title", "created_at", "updated_at"],
            "events": ["sequence", "id", "conversation_id", "project_id", "role", "status", "turn_id", "created_at", "digest", "byte_count", "payload"],
            "drafts": ["conversation_id", "payload"], "settings": ["key", "payload"],
            "invocations": ["id", "conversation_id", "project_id", "turn_id", "human_event_id", "assistant_event_id", "provider_identity", "request_body", "request_digest", "admission_json", "admission_digest", "usage_json", "usage_digest", "created_at", "chunk_count", "observed_bytes", "final_status", "terminal_reason", "finalized_at", "recovered"],
            "invocation_chunks": ["invocation_id", "chunk_sequence", "byte_count", "digest", "payload"]]
        if schema >= 3 {
            columns["invocations"]! += ["episode_id", "episode_work_id"]
            columns["episodes"] = ["id", "conversation_id", "project_id", "turn_id", "human_event_id", "limits_json", "limits_digest", "state", "revision", "clock_domain", "created_ticks", "deadline_ticks", "last_ticks", "created_utc", "terminal_reason"]
            columns["episode_resource_totals"] = ["episode_id", "resource", "charged", "held", "cap"]
            columns["episode_request_snapshots"] = ["digest", "byte_count", "payload"]
            columns["episode_work"] = ["id", "episode_id", "parent_id", "kind", "adapter_identity", "request_json", "request_digest", "snapshot_digest", "revision", "state", "charged_json", "held_json", "observed_json", "receipt_id", "receipt_json", "receipt_digest", "created_ticks", "armed_ticks", "ended_ticks", "recovered", "adapter_violation"]
        }
        if schema == 1 { columns.removeValue(forKey: "invocations"); columns.removeValue(forKey: "invocation_chunks") }
        if schema >= 4 { columns["episodes"]! += ["origin_json", "origin_digest"] }
        if schema >= 5 {
            columns["background_index_windows"] = ["sequence", "id", "state", "revision", "limits_json", "limits_digest", "started_clock_json", "started_clock_digest", "window_json", "window_digest"]
            columns["background_index_work"] = ["id", "window_id", "state", "adapter_identity", "binding_digest", "request_digest", "record_json", "record_digest", "receipt_id", "adapter_violation"]
        }
        if schema == 6 {
            columns["authority_control"] = ["id", "payload", "digest"]
            columns["authority_tasks"] = ["id", "payload", "digest"]
            columns["authority_bindings"] = ["conversation_id", "payload", "digest"]
            columns["authority_policies"] = ["id", "payload", "digest"]
            columns["authority_operations"] = ["sequence", "request_id", "request_payload", "receipt_payload", "receipt_digest"]
        }
        for (table, expected) in columns {
            guard try db.texts("SELECT name FROM pragma_table_info('\(table)') ORDER BY cid") == expected else { throw BackupError.invalid("unsupported table contract") }
        }
        if schema >= 3, let handle = db.handle {
            do { try MemoryStore.validateEpisodeJournal(database: handle) }
            catch { throw BackupError.invalid("episode journal failed integrity verification") }
        }
        guard try db.integer("SELECT count(*) FROM events e LEFT JOIN conversations c ON e.conversation_id=c.id WHERE c.id IS NULL OR e.project_id!=c.project_id OR e.role NOT IN ('human','assistant') OR e.status NOT IN ('complete','partial','failed','cancelled')") == 0,
              try db.integer("SELECT count(*) FROM drafts d LEFT JOIN conversations c ON d.conversation_id=c.id WHERE c.id IS NULL") == 0,
              (try (schema == 1 || db.integer("SELECT count(*) FROM invocation_chunks x LEFT JOIN invocations i ON x.invocation_id=i.id WHERE i.id IS NULL") == 0)) else {
            throw BackupError.invalid("invalid event scope or capture state")
        }
        try db.each("SELECT payload,byte_count,digest FROM events") { row in
            let data = db.blob(row, 0)
            guard data.count <= MemoryStore.maximumPayloadBytes, data.count == db.int(row, 1), digest(data) == db.text(row, 2), String(data: data, encoding: .utf8) != nil else { throw BackupError.invalid("source payload failed digest, length or UTF-8 verification") }
        }
        for table in ["drafts", "settings"] {
            try db.each("SELECT payload FROM \(table)") { row in
                let data = db.blob(row, 0)
                guard data.count <= MemoryStore.maximumPayloadBytes, String(data: data, encoding: .utf8) != nil else { throw BackupError.invalid("invalid draft or stored setting") }
            }
        }
        if schema >= 2 {
            try db.each("SELECT payload,byte_count,digest FROM invocation_chunks") { row in
                let data = db.blob(row, 0)
                guard !data.isEmpty, data.count <= MemoryStore.maximumPayloadBytes, data.count == db.int(row, 1), digest(data) == db.text(row, 2), String(data: data, encoding: .utf8) != nil else { throw BackupError.invalid("invocation chunk failed integrity verification") }
            }
        }
        var providers = Set<Data>(), models = Set<Data>()
        if schema >= 2 {
            try db.each("SELECT id,conversation_id,project_id,turn_id,human_event_id,assistant_event_id,provider_identity,request_body,request_digest,admission_json,admission_digest,usage_json,usage_digest,chunk_count,observed_bytes,final_status,terminal_reason,finalized_at,recovered FROM invocations") { row in
                let id = db.text(row, 0), conversation = db.text(row, 1), project = db.text(row, 2), turn = db.text(row, 3)
                let human = db.text(row, 4), assistant = db.text(row, 5), provider = db.text(row, 6)
                try verifyProvider(provider)
                providers.insert(Data(provider.utf8))
                let request = db.blob(row, 7)
                guard !request.isEmpty, request.count <= MemoryStore.maximumPayloadBytes, digest(request) == db.text(row, 8) else { throw BackupError.invalid("invocation request digest mismatch") }
                let object = try credentialFreeObject(request)
                if let model = object["model"] as? String { models.insert(Data(model.utf8)) }
                for (payloadColumn, digestColumn) in [(Int32(9), Int32(10)), (Int32(11), Int32(12))] {
                    let data = db.blob(row, payloadColumn)
                    guard data.count <= 65536, (data.isEmpty ? "" : digest(data)) == db.text(row, digestColumn) else { throw BackupError.invalid("admission or usage receipt digest mismatch") }
                    if !data.isEmpty { _ = try credentialFreeObject(data) }
                }
                guard try db.integer("SELECT count(*) FROM events e JOIN conversations c ON c.id=e.conversation_id WHERE e.id=? AND e.conversation_id=? AND e.project_id=? AND e.turn_id=? AND e.role='human' AND e.status='complete' AND c.project_id=e.project_id", bindings: [human, conversation, project, turn]) == 1 else { throw BackupError.invalid("invocation lacks its matching human source") }
                var payload = Data(), sequence = 0
                try db.each("SELECT chunk_sequence,payload FROM invocation_chunks WHERE invocation_id=? ORDER BY chunk_sequence", bindings: [id]) { chunk in
                    let data = db.blob(chunk, 1)
                    guard db.int(chunk, 0) == sequence, sequence < MemoryStore.maximumStreamChunks,
                          payload.count <= MemoryStore.maximumPayloadBytes - data.count else { throw BackupError.invalid("noncontiguous or oversized invocation stream") }
                    payload.append(data); sequence += 1
                }
                guard sequence == db.int(row, 13), payload.count == db.int(row, 14) else { throw BackupError.invalid("invocation chunk manifest mismatch") }
                let statusText = db.text(row, 15), reasonText = db.text(row, 16), finalized = db.text(row, 17), recovered = db.int(row, 18)
                guard recovered == 0 || recovered == 1 else { throw BackupError.invalid("invalid recovered state") }
                if statusText.isEmpty {
                    guard reasonText.isEmpty, finalized.isEmpty, recovered == 0,
                          try db.integer("SELECT count(*) FROM events WHERE id=?", bindings: [assistant]) == 0 else { throw BackupError.invalid("unfinished invocation has a published result") }
                } else {
                    guard let status = CaptureStatus(rawValue: statusText), let reason = InvocationTerminalReason(rawValue: reasonText),
                          !finalized.isEmpty, terminalCompatible(status, reason) else { throw BackupError.invalid("invalid invocation terminal state") }
                    if recovered == 1 && reason != .interrupted {
                        guard schema >= 3, reason == .cancelled,
                              status == (payload.isEmpty ? .cancelled : .partial),
                              try db.integer("SELECT count(*) FROM invocations i JOIN episodes ep ON ep.id=i.episode_id WHERE i.id=? AND ep.state='cancelled'", bindings: [id]) == 1 else {
                            throw BackupError.invalid("invalid recovered cancellation state")
                        }
                    }
                    var matches = false
                    try db.each("SELECT conversation_id,project_id,turn_id,role,status,payload FROM events WHERE id=?", bindings: [assistant]) { event in
                        matches = episodeIdentifierEqual(db.text(event, 0), conversation)
                            && episodeIdentifierEqual(db.text(event, 1), project) && episodeIdentifierEqual(db.text(event, 2), turn)
                            && db.text(event, 3) == "assistant" && db.text(event, 4) == statusText && db.blob(event, 5) == payload
                    }
                    guard matches else { throw BackupError.invalid("terminal invocation disagrees with assistant source") }
                }
            }
        }
        if schema >= 4 {
            guard try db.integer("SELECT count(*) FROM invocations i JOIN episodes ep ON ep.id=i.episode_id WHERE ep.conversation_id IS NULL OR ep.turn_id IS NULL OR ep.human_event_id IS NULL") == 0 else {
                throw BackupError.invalid("local read episode cannot own an invocation")
            }
        }
        var scopes: [BackupScopeCount] = []
        let scopeQuery = schema >= 4
            ? "SELECT project_id,(SELECT count(*) FROM conversations c WHERE c.project_id=p.project_id) FROM (SELECT project_id FROM conversations UNION SELECT project_id FROM episodes) p ORDER BY project_id"
            : "SELECT project_id,count(*) FROM conversations GROUP BY project_id ORDER BY project_id"
        try db.each(scopeQuery) { row in
            let project = db.text(row, 0)
            scopes.append(BackupScopeCount(projectID: project, conversations: db.int(row, 1),
                events: try db.integer("SELECT count(*) FROM events WHERE project_id=?", bindings: [project]),
                sourceBytes: Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM events WHERE project_id=?", bindings: [project])),
                invocations: schema == 1 ? 0 : try db.integer("SELECT count(*) FROM invocations WHERE project_id=?", bindings: [project])))
        }
        var inventory = BackupInventory(conversations: try db.integer("SELECT count(*) FROM conversations"),
            events: try db.integer("SELECT count(*) FROM events"), sourceBytes: Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM events")),
            drafts: try db.integer("SELECT count(*) FROM drafts"), settings: try db.integer("SELECT count(*) FROM settings"),
            invocations: schema == 1 ? 0 : try db.integer("SELECT count(*) FROM invocations"), unfinishedInvocations: schema == 1 ? 0 : try db.integer("SELECT count(*) FROM invocations WHERE final_status=''"),
            chunks: schema == 1 ? 0 : try db.integer("SELECT count(*) FROM invocation_chunks"), chunkBytes: schema == 1 ? 0 : Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM invocation_chunks")),
            providerIdentities: providers.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) },
            servedModels: models.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) }, scopes: scopes)
        if schema >= 3 {
            inventory.episodes = try db.integer("SELECT count(*) FROM episodes")
            inventory.unfinishedEpisodes = try db.integer("SELECT count(*) FROM episodes WHERE state='active'")
            inventory.episodeWork = try db.integer("SELECT count(*) FROM episode_work")
            inventory.episodeSnapshots = try db.integer("SELECT count(*) FROM episode_request_snapshots")
            inventory.episodeSnapshotBytes = Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM episode_request_snapshots"))
            inventory.episodePreparedWork = try db.integer("SELECT count(*) FROM episode_work WHERE state='prepared'")
            inventory.episodeUncertainWork = try db.integer("SELECT count(*) FROM episode_work WHERE state IN ('dispatchArmed','submitted','outcomeUnknown')")
            var charged = EpisodeResources.zero, held = EpisodeResources.zero
            try db.each("SELECT resource,coalesce(sum(charged),0),coalesce(sum(held),0) FROM episode_resource_totals GROUP BY resource") { row in
                guard let resource = EpisodeResource(rawValue: db.text(row, 0)) else { throw BackupError.invalid("unknown episode resource") }
                charged[resource] = db.int(row, 1); held[resource] = db.int(row, 2)
            }
            inventory.episodeCharged = charged
            inventory.episodeHeld = held
            if schema >= 4 {
                var chat = 0, localRead = 0
                try db.each("SELECT origin_json FROM episodes") { row in
                    let origin = try JSONDecoder().decode(EpisodeOrigin.self, from: db.blob(row, 0))
                    switch origin { case .chat: chat += 1; case .localRead: localRead += 1 }
                }
                guard chat + localRead == inventory.episodes else { throw BackupError.invalid("episode origin inventory mismatch") }
                inventory.chatEpisodes = chat; inventory.localReadEpisodes = localRead
            }
        }
        if schema >= 5 {
            guard let handle = db.handle else { throw BackupError.database }
            do { inventory.backgroundIndex = try BackgroundIndexJournal.inventory(database: handle) }
            catch { throw BackupError.invalid("background index journal failed integrity verification") }
        }
        if schema == 6 {
            guard let handle = db.handle else { throw BackupError.database }
            do {
                try AuthorityStateJournal.validate(database: handle)
                inventory.authorityState = try AuthorityStateJournal.inventory(database: handle)
            } catch { throw BackupError.invalid("authority state journal failed integrity verification") }
        }
        return inventory
    }

    /// Recovery can release only reservations for work durably proven unarmed.
    /// Already armed output remains uncertain even after a copied store opens.
    private static func preparedEpisodeHold(_ url: URL) throws -> EpisodeResources {
        let db = try Database(url, writable: false)
        defer { db.close() }
        var result = EpisodeResources.zero
        try db.each("SELECT held_json FROM episode_work WHERE state='prepared'") { row in
            let held = try JSONDecoder().decode(EpisodeResources.self, from: db.blob(row, 0)).validated()
            result = try result.adding(held)
        }
        return result
    }

    private static func unfinishedInvocationBytes(_ url: URL) throws -> Int64 {
        let db = try Database(url, writable: false)
        defer { db.close() }
        return Int64(try db.integer("SELECT coalesce(sum(observed_bytes),0) FROM invocations WHERE final_status=''"))
    }

    private static func verifyExactReads(owner: MemoryStore, scopes: [BackupScopeCount]) throws {
        for scope in scopes {
            let frontier = try owner.sourceFrontier(projectID: scope.projectID)
            var after = 0
            while true {
                let sources = try owner.sourceManifest(projectID: scope.projectID, afterSequence: after, throughSequence: frontier, limit: 1000)
                if sources.isEmpty { break }
                for source in sources {
                    var payload = Data(), offset = 0
                    while true {
                        let page = try owner.read(eventID: source.eventID, offset: offset, length: MemoryStore.maximumPageBytes)
                        guard page.digest == source.digest, page.status == source.status else { throw BackupError.invalid("restored exact-read metadata mismatch") }
                        payload.append(contentsOf: page.text.utf8)
                        guard let next = page.nextOffset else { break }
                        guard next > offset else { throw BackupError.invalid("restored exact read failed to advance") }
                        offset = next
                    }
                    guard payload.count == source.byteCount, digest(payload) == source.digest else { throw BackupError.invalid("restored exact read failed source checksum") }
                    after = source.sequence
                }
            }
        }
    }

    private static func rebuildLexicalIndex(_ url: URL) throws {
        let db = try Database(url, writable: true)
        defer { db.close() }
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("INSERT INTO event_fts(event_fts) VALUES('delete-all')")
            try db.execute("INSERT INTO event_fts(rowid,text) SELECT sequence,CAST(payload AS TEXT) FROM events ORDER BY sequence")
            try db.execute("INSERT INTO event_fts(event_fts) VALUES('integrity-check')")
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
    }

    private static func terminalCompatible(_ status: CaptureStatus, _ reason: InvocationTerminalReason) -> Bool {
        switch status {
        case .complete: return reason == .completed
        case .cancelled: return reason == .cancelled
        case .partial: return reason != .completed && reason != .admissionFailure
        case .failed: return reason != .completed && reason != .cancelled
        }
    }

    private static func credentialFreeObject(_ data: Data) throws -> [String: Any] {
        guard String(data: data, encoding: .utf8) != nil,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw BackupError.invalid("invalid JSON metadata") }
        let forbidden = Set(["apikey", "authorization", "proxyauthorization", "password", "accesstoken", "bearer", "token", "headers", "cookies"])
        func containsCredential(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                return object.contains { key, child in
                    let normalized = key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
                    return forbidden.contains(normalized) || containsCredential(child)
                }
            }
            if let array = value as? [Any] { return array.contains(where: containsCredential) }
            return false
        }
        guard !containsCredential(object) else { throw BackupError.invalid("credential fields are excluded from archive configuration") }
        return object
    }

    private static func verifyProvider(_ provider: String) throws {
        if provider.hasPrefix("native:") {
            let suffix = provider.dropFirst(7)
            guard !suffix.isEmpty, suffix.utf8.count <= 200, suffix.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) else { throw BackupError.invalid("invalid native provider identity") }
            return
        }
        guard let parts = URLComponents(string: provider), parts.scheme == "http", let host = parts.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port.map({ (1...65535).contains($0) }) ?? true else { throw BackupError.invalid("invalid loopback provider identity") }
    }

    private final class Database {
        var handle: OpaquePointer?
        private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        init(_ url: URL, writable: Bool) throws {
            let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else { close(); throw BackupError.database }
            sqlite3_busy_timeout(handle, 5000)
            do { try execute("PRAGMA trusted_schema=OFF"); try execute("PRAGMA temp_store=MEMORY") }
            catch { close(); throw error }
        }
        deinit { close() }
        func close() { if let handle { sqlite3_close(handle); self.handle = nil } }
        func each(_ sql: String, bindings: [String] = [], _ callback: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw BackupError.database }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bindings.enumerated() {
                guard value.withCString({ sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient) }) == SQLITE_OK else { throw BackupError.database }
            }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw BackupError.database }
                try callback(statement)
            }
        }
        func execute(_ sql: String) throws { try each(sql) { _ in } }
        func integer(_ sql: String, bindings: [String] = []) throws -> Int {
            var result = 0; try each(sql, bindings: bindings) { result = int($0, 0) }; return result
        }
        func texts(_ sql: String) throws -> [String] {
            var result: [String] = []; try each(sql) { result.append(text($0, 0)) }; return result
        }
        func int(_ row: OpaquePointer, _ index: Int32) -> Int { Int(sqlite3_column_int64(row, index)) }
        func text(_ row: OpaquePointer, _ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(row, index) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
        }
        func blob(_ row: OpaquePointer, _ index: Int32) -> Data {
            guard let pointer = sqlite3_column_blob(row, index) else { return Data() }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, index)))
        }
    }

    /// Walk existing parents with openat/O_NOFOLLOW. Publication uses the held
    /// parent descriptor and RENAME_EXCL, retaining no-clobber semantics if a
    /// competing process creates the requested final path.
    private final class NewDestination {
        let parent: URL
        let name: String
        private var parentFD: Int32 = -1
        init(_ destination: URL) throws {
            guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.contains("\0") else { throw BackupError.invalid("destination must be an absolute local path") }
            // Foundation's standardizedFileURL rewrites existing /private/var
            // paths to /var on macOS, introducing an otherwise absent symlink.
            // Retain the supplied absolute path and reject dot components.
            guard !destination.pathComponents.contains("."), !destination.pathComponents.contains("..") else { throw BackupError.invalid("destination path cannot contain dot components") }
            let normalized = destination
            name = normalized.lastPathComponent
            parent = normalized.deletingLastPathComponent()
            guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw BackupError.invalid("invalid destination name") }
            parentFD = try BackupArchive.openDirectoryChain(parent)
            var metadata = stat()
            guard fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { closeParent(); throw BackupError.invalid("destination already exists") }
        }
        deinit { closeParent() }
        func closeParent() { if parentFD >= 0 { close(parentFD); parentFD = -1 } }
        func makeStaging() throws -> URL {
            let temporary = ".boros-staging-" + UUID().uuidString
            guard mkdirat(parentFD, temporary, 0o700) == 0 else { throw BackupError.io("cannot create private staging directory") }
            // The held parent's inode must still be reachable by the path used
            // by SQLite. Abort when a parent was renamed/replaced after open.
            try validateParentIdentity()
            return parent.appendingPathComponent(temporary, isDirectory: true)
        }
        private func validateParentIdentity() throws {
            let current = try BackupArchive.openDirectoryChain(parent)
            defer { close(current) }
            var held = stat(), actual = stat()
            guard fstat(parentFD, &held) == 0, fstat(current, &actual) == 0,
                  held.st_ino == actual.st_ino, held.st_dev == actual.st_dev else { throw BackupError.io("destination parent changed") }
        }
        func publish(_ staging: URL) throws {
            try validateParentIdentity()
            guard renameatx_np(parentFD, staging.lastPathComponent, parentFD, name, UInt32(RENAME_EXCL)) == 0 else { throw BackupError.io("atomic publication refused an existing or invalid destination") }
            guard fsync(parentFD) == 0 else { throw BackupError.publicationDurabilityUnknown }
        }
    }

    private static func openDirectoryChain(_ url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BackupError.io("cannot open filesystem root") }
        for component in url.pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(descriptor)
            guard next >= 0 else { throw BackupError.invalid("destination parent is missing or contains a symbolic link") }
            descriptor = next
        }
        return descriptor
    }

    private static func itemExists(_ url: URL) throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 { return true }
        guard errno == ENOENT else { throw BackupError.io("cannot inspect source item") }
        return false
    }
    private static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { throw BackupError.invalid("archive must be a private real directory owned by this user") }
    }
    private static func requireRegular(_ url: URL) throws {
        let descriptor = try openRegular(url); close(descriptor)
    }
    private static func requireStandaloneHeader(_ url: URL) throws {
        let descriptor = try openRegular(url)
        defer { close(descriptor) }
        var header = [UInt8](repeating: 0, count: 100)
        let count = read(descriptor, &header, header.count)
        guard count == 100, Data(header.prefix(16)) == Data("SQLite format 3\0".utf8),
              header[18] == 1, header[19] == 1 else { throw BackupError.invalid("database is not a standalone SQLite snapshot") }
    }
    private static func openRegular(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BackupError.invalid("required regular file is missing or symbolic") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1 else {
            close(descriptor); throw BackupError.invalid("archive files must be private regular files without hard links")
        }
        return descriptor
    }
    private static func fileRecord(_ url: URL, name: String) throws -> BackupFile {
        let descriptor = try openRegular(url)
        defer { close(descriptor) }
        var hash = SHA256(), bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw BackupError.io("file hash read failed") }
            hash.update(data: Data(buffer.prefix(count))); bytes += Int64(count)
        }
        return BackupFile(name: name, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        let descriptor = try openRegular(url)
        defer { close(descriptor) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw BackupError.io("metadata read failed") }
            guard result.count <= limit - count else { throw BackupError.invalid("archive metadata exceeds its size limit") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func writeNewFile(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BackupError.io("cannot create private file") }
        defer { close(descriptor) }
        try writeBytes(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw BackupError.io("file sync failed") }
    }
    private static func copyNewFile(from source: URL, to destination: URL) throws {
        let input = try openRegular(source)
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw BackupError.io("cannot create restored file") }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw BackupError.io("archive copy read failed") }
            try writeBytes(Data(buffer.prefix(count)), descriptor: output)
        }
        guard fsync(output) == 0 else { throw BackupError.io("restored file sync failed") }
    }
    private static func writeBytes(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw BackupError.io("file write failed") }
                guard count > 0 else { throw BackupError.io("file write made no progress") }
                offset += count
            }
        }
    }
    private static func syncFile(_ url: URL) throws {
        let descriptor = try openRegular(url)
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BackupError.io("file sync failed") }
    }
    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BackupError.io("cannot open staging directory for sync") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BackupError.io("staging directory sync failed") }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
