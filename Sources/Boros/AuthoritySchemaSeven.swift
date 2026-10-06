import Foundation
import CSQLite

/// Complete schema-7 DDL captured by the immutable verified 27cdc4c owner.
/// Recreating this contract reproduces all SQLite objects, including FTS
/// shadow tables, automatic indexes and sqlite_sequence. Historical recognition
/// never subtracts new tables or constraints from a newer owner.
enum AuthoritySchemaSeven {
    static let sql = """
    CREATE TABLE authority_bindings(conversation_id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE authority_control(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE authority_episode_bindings(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE authority_invocation_bindings(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE authority_operations(sequence INTEGER PRIMARY KEY,request_id TEXT COLLATE BINARY UNIQUE NOT NULL,request_payload BLOB,receipt_payload BLOB NOT NULL,receipt_digest TEXT NOT NULL);
    CREATE TABLE authority_policies(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE authority_tasks(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE authority_work_bindings(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL);
    CREATE TABLE background_index_windows (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN ('active','closed')),
      revision INTEGER NOT NULL CHECK(revision>=0),
      limits_json BLOB NOT NULL CHECK(length(limits_json)>0 AND length(limits_json)<=65536), limits_digest TEXT NOT NULL,
      started_clock_json BLOB NOT NULL CHECK(length(started_clock_json)>0 AND length(started_clock_json)<=65536), started_clock_digest TEXT NOT NULL,
      window_json BLOB NOT NULL CHECK(length(window_json)>0 AND length(window_json)<=262144),
      window_digest TEXT NOT NULL
    );
    CREATE TABLE background_index_work (
      id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES background_index_windows(id),
      state TEXT NOT NULL CHECK(state IN ('prepared','armed','submitted','completed','failedConfirmed','outcomeUnknown','cancelledBeforeDispatch')),
      adapter_identity TEXT NOT NULL, binding_digest TEXT NOT NULL, request_digest TEXT NOT NULL,
      record_json BLOB NOT NULL CHECK(length(record_json)>0 AND length(record_json)<=262144),
      record_digest TEXT NOT NULL, receipt_id TEXT UNIQUE,
      adapter_violation INTEGER NOT NULL DEFAULT 0 CHECK(adapter_violation IN (0,1))
    );
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
    CREATE UNIQUE INDEX background_index_active_window ON background_index_windows(state) WHERE state='active';
    CREATE INDEX background_index_adapter_violation ON background_index_work(adapter_identity) WHERE adapter_violation=1;
    CREATE INDEX background_index_work_window ON background_index_work(window_id,id);
    CREATE UNIQUE INDEX episode_local_read_request
    ON episodes(json_extract(origin_json,'$.binding.initiator'),json_extract(origin_json,'$.binding.requestID'))
    WHERE json_extract(origin_json,'$.kind')='localRead';
    CREATE INDEX episode_work_episode ON episode_work(episode_id,id);
    CREATE INDEX event_conversation ON events(conversation_id, sequence);
    CREATE INDEX event_project ON events(project_id, sequence);
    PRAGMA user_version=7;
    """

    /// Default recognition is the immutable 53-object historical contract.
    /// Explicit current schema additions are trusted host DDL, never imported
    /// database instructions or a subtraction from a newer historical store.
    static func validate(database: OpaquePointer, additionalStatements: [String] = []) throws {
        var reference: OpaquePointer?
        guard sqlite3_open(":memory:", &reference) == SQLITE_OK, let reference else { throw AuthorityStateError.integrity }
        defer { sqlite3_close(reference) }
        guard sqlite3_exec(reference, sql, nil, nil, nil) == SQLITE_OK else { throw AuthorityStateError.integrity }
        for statement in additionalStatements {
            guard sqlite3_exec(reference, statement, nil, nil, nil) == SQLITE_OK else { throw AuthorityStateError.integrity }
        }
        guard try objects(database) == objects(reference) else { throw AuthorityStateError.integrity }
    }

    private static func objects(_ database: OpaquePointer) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT type,name,tbl_name,coalesce(sql,'') FROM sqlite_schema ORDER BY type,name", -1, &statement, nil) == SQLITE_OK, let statement else { throw AuthorityStateError.integrity }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw AuthorityStateError.integrity }
            var row: [String] = []
            for index in 0..<4 {
                guard let value = sqlite3_column_text(statement, Int32(index)) else { throw AuthorityStateError.integrity }
                let bytes = Data(bytes: value, count: Int(sqlite3_column_bytes(statement, Int32(index))))
                guard let text = String(data: bytes, encoding: .utf8) else { throw AuthorityStateError.integrity }
                row.append(index == 3 ? text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) : text)
            }
            result.append(row)
        }
    }
}
