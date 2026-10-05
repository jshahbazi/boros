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
        let candidate = try Database(copied.appendingPathComponent("memory.sqlite3"), writable: false)
        defer { candidate.close() }
        let version = try candidate.integer("PRAGMA user_version")
        guard version == 1 || version == 2 else { throw BackupError.invalid("source database has an unsupported schema") }
        let actualSchema = try schemaObjects(candidate)
        candidate.close()
        do {
            let owner = try MemoryStore(directory: reference)
            withExtendedLifetime(owner) {}
        }
        let referenceDB = try Database(reference.appendingPathComponent("memory.sqlite3"), writable: false)
        defer { referenceDB.close() }
        let expected = try schemaObjects(referenceDB).filter { version == 2 || !["invocations", "invocation_chunks"].contains($0.table) }
        guard actualSchema == expected else { throw BackupError.invalid("source table, column, index or constraint contract is not a recognized Boros schema") }
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
        let manifest = BackupManifest(archiveVersion: 1, databaseSchema: 2, archiveID: UUID().uuidString,
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
        guard manifest.archiveVersion == 1, manifest.databaseSchema == 2,
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
        guard try inspectDatabase(archive.appendingPathComponent("memory.sqlite3")) == manifest.inventory else {
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
              restored.events == manifest.inventory.events + manifest.inventory.unfinishedInvocations,
              restored.invocations == manifest.inventory.invocations,
              restored.chunks == manifest.inventory.chunks,
              restored.chunkBytes == manifest.inventory.chunkBytes else { throw BackupError.invalid("restored startup recovery inventory mismatch") }
        // No stale archive manifest is placed alongside the recovered database.
        let receipt: [String: Any] = ["archive_id": manifest.archiveID, "restored_at": timestamp(),
            "archive_database_sha256": manifest.files.first { $0.name == "memory.sqlite3" }!.sha256,
            "recovered_interrupted_attempts": manifest.inventory.unfinishedInvocations,
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
        guard try db.integer("PRAGMA user_version") == 2 else { throw BackupError.invalid("unsupported database schema") }
        guard try db.texts("PRAGMA integrity_check") == ["ok"], try db.integer("SELECT count(*) FROM pragma_foreign_key_check") == 0 else {
            throw BackupError.invalid("SQLite integrity or foreign-key check failed")
        }
        let allowedTables = Set(["conversations", "events", "drafts", "settings", "invocations", "invocation_chunks", "sqlite_sequence", "event_fts", "event_fts_data", "event_fts_idx", "event_fts_docsize", "event_fts_config"])
        guard Set(try db.texts("SELECT name FROM sqlite_schema WHERE type='table'")) == allowedTables,
              try db.integer("SELECT count(*) FROM sqlite_schema WHERE type IN ('view','trigger')") == 0 else {
            throw BackupError.invalid("unsupported database object inventory")
        }
        let columns: [String: [String]] = [
            "conversations": ["id", "project_id", "title", "created_at", "updated_at"],
            "events": ["sequence", "id", "conversation_id", "project_id", "role", "status", "turn_id", "created_at", "digest", "byte_count", "payload"],
            "drafts": ["conversation_id", "payload"], "settings": ["key", "payload"],
            "invocations": ["id", "conversation_id", "project_id", "turn_id", "human_event_id", "assistant_event_id", "provider_identity", "request_body", "request_digest", "admission_json", "admission_digest", "usage_json", "usage_digest", "created_at", "chunk_count", "observed_bytes", "final_status", "terminal_reason", "finalized_at", "recovered"],
            "invocation_chunks": ["invocation_id", "chunk_sequence", "byte_count", "digest", "payload"]]
        for (table, expected) in columns {
            guard try db.texts("SELECT name FROM pragma_table_info('\(table)') ORDER BY cid") == expected else { throw BackupError.invalid("unsupported table contract") }
        }
        guard try db.integer("SELECT count(*) FROM events e LEFT JOIN conversations c ON e.conversation_id=c.id WHERE c.id IS NULL OR e.project_id!=c.project_id OR e.role NOT IN ('human','assistant') OR e.status NOT IN ('complete','partial','failed','cancelled')") == 0,
              try db.integer("SELECT count(*) FROM drafts d LEFT JOIN conversations c ON d.conversation_id=c.id WHERE c.id IS NULL") == 0,
              try db.integer("SELECT count(*) FROM invocation_chunks x LEFT JOIN invocations i ON x.invocation_id=i.id WHERE i.id IS NULL") == 0 else {
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
        try db.each("SELECT payload,byte_count,digest FROM invocation_chunks") { row in
            let data = db.blob(row, 0)
            guard !data.isEmpty, data.count <= MemoryStore.maximumPayloadBytes, data.count == db.int(row, 1), digest(data) == db.text(row, 2), String(data: data, encoding: .utf8) != nil else { throw BackupError.invalid("invocation chunk failed integrity verification") }
        }
        var providers = Set<String>(), models = Set<String>()
        try db.each("SELECT id,conversation_id,project_id,turn_id,human_event_id,assistant_event_id,provider_identity,request_body,request_digest,admission_json,admission_digest,usage_json,usage_digest,chunk_count,observed_bytes,final_status,terminal_reason,finalized_at,recovered FROM invocations") { row in
            let id = db.text(row, 0), conversation = db.text(row, 1), project = db.text(row, 2), turn = db.text(row, 3)
            let human = db.text(row, 4), assistant = db.text(row, 5), provider = db.text(row, 6)
            try verifyProvider(provider)
            providers.insert(provider)
            let request = db.blob(row, 7)
            guard !request.isEmpty, request.count <= MemoryStore.maximumPayloadBytes, digest(request) == db.text(row, 8) else { throw BackupError.invalid("invocation request digest mismatch") }
            let object = try credentialFreeObject(request)
            if let model = object["model"] as? String { models.insert(model) }
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
                      !finalized.isEmpty, terminalCompatible(status, reason), recovered == 0 || reason == .interrupted else { throw BackupError.invalid("invalid invocation terminal state") }
                var matches = false
                try db.each("SELECT conversation_id,project_id,turn_id,role,status,payload FROM events WHERE id=?", bindings: [assistant]) { event in
                    matches = db.text(event, 0) == conversation && db.text(event, 1) == project && db.text(event, 2) == turn && db.text(event, 3) == "assistant" && db.text(event, 4) == statusText && db.blob(event, 5) == payload
                }
                guard matches else { throw BackupError.invalid("terminal invocation disagrees with assistant source") }
            }
        }
        var scopes: [BackupScopeCount] = []
        try db.each("SELECT project_id,count(*) FROM conversations GROUP BY project_id ORDER BY project_id") { row in
            let project = db.text(row, 0)
            scopes.append(BackupScopeCount(projectID: project, conversations: db.int(row, 1),
                events: try db.integer("SELECT count(*) FROM events WHERE project_id=?", bindings: [project]),
                sourceBytes: Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM events WHERE project_id=?", bindings: [project])),
                invocations: try db.integer("SELECT count(*) FROM invocations WHERE project_id=?", bindings: [project])))
        }
        return BackupInventory(conversations: try db.integer("SELECT count(*) FROM conversations"),
            events: try db.integer("SELECT count(*) FROM events"), sourceBytes: Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM events")),
            drafts: try db.integer("SELECT count(*) FROM drafts"), settings: try db.integer("SELECT count(*) FROM settings"),
            invocations: try db.integer("SELECT count(*) FROM invocations"), unfinishedInvocations: try db.integer("SELECT count(*) FROM invocations WHERE final_status=''"),
            chunks: try db.integer("SELECT count(*) FROM invocation_chunks"), chunkBytes: Int64(try db.integer("SELECT coalesce(sum(byte_count),0) FROM invocation_chunks")),
            providerIdentities: providers.sorted(), servedModels: models.sorted(), scopes: scopes)
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
