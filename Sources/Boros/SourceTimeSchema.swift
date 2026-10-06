import Foundation
import CSQLite

/// Schema 10 stores source-calendar evidence separately from ingestion time.
/// The index compares literal civil days, without assigning a timezone.
enum SourceTimeSchema {
    static let schemaStatements = [
        "ALTER TABLE events ADD COLUMN source_time_json BLOB CHECK(source_time_json IS NULL OR (typeof(source_time_json)='blob' AND length(source_time_json)>0 AND length(source_time_json)<=4096))",
        "CREATE INDEX events_source_day ON events(substr(json_extract(source_time_json,'$.value'),1,10),project_id,sequence)"
    ]
    static func install(database: OpaquePointer) throws {
        for sql in schemaStatements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MemoryError.database("source time migration failed") }
        }
    }
    static func requireAbsent(database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "SELECT (SELECT count(*) FROM pragma_table_info('events') WHERE name='source_time_json')+(SELECT count(*) FROM sqlite_schema WHERE name='events_source_day')"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MemoryError.database("source time inventory failed") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) == 0, sqlite3_step(statement) == SQLITE_DONE else {
            throw MemoryError.database("historical schema contains source time metadata")
        }
    }
    static func decodeColumn(_ statement: OpaquePointer, index: Int32) throws -> EventSourceTime? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else { throw MemoryError.database("source time metadata is not a blob") }
        let size = Int(sqlite3_column_bytes(statement, index))
        guard size > 0, size <= EventSourceTime.maximumBytes, let pointer = sqlite3_column_blob(statement, index) else { throw MemoryError.database("invalid source time metadata size") }
        do { return try EventSourceTime.decodeCanonical(Data(bytes: pointer, count: size)) }
        catch { throw MemoryError.database("source time metadata failed canonical validation") }
    }
    static func validate(database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT source_time_json FROM events", -1, &statement, nil) == SQLITE_OK, let statement else { throw MemoryError.database("source time schema missing") }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw MemoryError.database("source time scan failed") }
            _ = try decodeColumn(statement, index: 0)
        }
    }
    static func validateDay(_ value: String) throws {
        let normalized = try EventSourceTime.normalize(value)
        guard normalized.precision == "day", normalized.value == value else { throw MemoryError.invalid("source day filter requires calendar days") }
    }
}
