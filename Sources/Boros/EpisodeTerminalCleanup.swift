import Foundation
import CryptoKit
import CSQLite

struct EpisodeCleanupLimits: Codable, Equatable {
    static let defaults = EpisodeCleanupLimits()
    static let batchRows = 32
    /// Encoded row ceiling; this does not describe heap use or process latency.
    static let maximumMetadataBytes = 524_288
    static let attemptsPerWork = 2
    static let metadataRowsPerWork = 64
    /// Fixed terminal fence and batch overhead, including absent-key probes.
    static let metadataRowsPerBatch = 128
    var version: String
    var maximumWorkRows: Int

    init(version: String = "terminal-work-cleanup-v1", maximumWorkRows: Int = 100_000) {
        self.version = version; self.maximumWorkRows = maximumWorkRows
    }
    func validated() throws -> Self {
        guard version.utf8.elementsEqual("terminal-work-cleanup-v1".utf8),
            (1...100_000).contains(maximumWorkRows) else { throw EpisodeBudgetError.invalid }
        return self
    }
    private enum CodingKeys: String, CodingKey { case version, maximumWorkRows }
    init(from decoder: Decoder) throws {
        try requireEpisodeKeys(decoder, ["version", "maximumWorkRows"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try values.decode(String.self, forKey: .version),
            maximumWorkRows: try values.decode(Int.self, forKey: .maximumWorkRows))
        _ = try validated()
    }
}

enum EpisodeCleanupClassification: String, Codable {
    case prepaidV1 = "prepaid-v1"
    case legacyAdministrative = "legacy-administrative"
}

/// Observational cleanup accounting; it is not a dispatch capability.
struct EpisodeCleanupReceipt: Codable, Equatable {
    let episodeID: String
    let classification: EpisodeCleanupClassification
    let limitRows: Int
    let prepaidRows: Int
    let consumedRows: Int
    let pendingRows: Int
    let attemptedRows: Int
    let administrativeRows: Int
    let terminalTicks: UInt64
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.episodeID, rhs.episodeID) && lhs.classification == rhs.classification
            && lhs.limitRows == rhs.limitRows && lhs.prepaidRows == rhs.prepaidRows && lhs.consumedRows == rhs.consumedRows
            && lhs.pendingRows == rhs.pendingRows && lhs.attemptedRows == rhs.attemptedRows
            && lhs.administrativeRows == rhs.administrativeRows && lhs.terminalTicks == rhs.terminalTicks
    }
}

struct EpisodeCleanupInventory: Codable, Equatable {
    var version = "episode-cleanup-inventory-v1"
    let budgets: Int
    let prepaidBudgets: Int
    let legacyBudgets: Int
    let receipts: Int
    /// Historical structural slots are excluded from this prepaid total.
    let prepaidRows: Int
    let consumedRows: Int
    let pendingRows: Int
    let attemptedRows: Int
    let administrativeRows: Int
    let budgetSHA256: String
    let receiptSHA256: String
}

/// Schema-9 cleanup accounting. Original work and resource rows remain intact.
/// All mutations require the owner's already-open transaction and confidence
/// fence. These helpers do not inspect snapshot, observed or receipt payloads.
enum EpisodeTerminalCleanupJournal {
    static let tableNames = ["episode_cleanup_budget", "episode_cleanup_receipts"]
    static let schemaStatements = [
        "CREATE TABLE IF NOT EXISTS episode_cleanup_budget(episode_id TEXT COLLATE BINARY NOT NULL PRIMARY KEY REFERENCES episodes(id),classification TEXT NOT NULL CHECK(classification IN ('prepaid-v1','legacy-administrative')),limit_rows INTEGER NOT NULL CHECK(limit_rows>=1 AND limit_rows<=100000),prepaid_rows INTEGER NOT NULL CHECK(prepaid_rows>=0 AND prepaid_rows<=limit_rows),consumed_rows INTEGER NOT NULL CHECK(consumed_rows>=0 AND consumed_rows<=prepaid_rows),pending_rows INTEGER NOT NULL CHECK(pending_rows>=0 AND pending_rows<=prepaid_rows),attempted_rows INTEGER NOT NULL CHECK(attempted_rows>=0 AND attempted_rows<=2*prepaid_rows),administrative_rows INTEGER NOT NULL CHECK(administrative_rows>=0),terminal_ticks INTEGER NOT NULL CHECK(terminal_ticks>=0),CHECK(consumed_rows+pending_rows<=prepaid_rows))",
        "CREATE TABLE IF NOT EXISTS episode_cleanup_receipts(work_id TEXT COLLATE BINARY NOT NULL PRIMARY KEY REFERENCES episode_work(id),episode_id TEXT COLLATE BINARY NOT NULL REFERENCES episode_cleanup_budget(episode_id),from_state TEXT NOT NULL CHECK(from_state IN ('prepared','dispatchArmed','submitted')),ticks INTEGER NOT NULL CHECK(ticks>0))",
        "CREATE INDEX IF NOT EXISTS episode_cleanup_pending ON episode_work(episode_id,id) WHERE state IN ('prepared','dispatchArmed','submitted')"
    ]
    private typealias Cell = AuthorityStateKernel.Value
    private static let pendingPredicate = "state IN ('prepared','dispatchArmed','submitted')"
    private static func transactionRequired(_ db: OpaquePointer) throws {
        guard sqlite3_get_autocommit(db) == 0 else { throw AuthorityStateError.invalid }
    }
    private static func identifier(_ value: String) throws { try AuthorityStateKernel.identifier(value) }
    private static func tick(_ value: UInt64) throws -> Int {
        guard value > 0, value <= UInt64(Int64.max) else { throw AuthorityStateError.invalid }
        return Int(value)
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data { try AuthorityStateKernel.canonical(value) }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ values: [Cell] = []) throws {
        try AuthorityStateKernel.execute(db, sql, values)
    }
    private static func visit(_ db: OpaquePointer, _ sql: String, _ values: [Cell] = [],
        maximumTextBytes: Int = 256, _ body: ([Cell]) throws -> Void) throws {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else { throw AuthorityStateError.integrity }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case .text(let value): code = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
            case .bytes(let value): code = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
            case .integer(let value): code = sqlite3_bind_int64(statement, index, Int64(value))
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw AuthorityStateError.integrity }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw AuthorityStateError.integrity }
            var row: [Cell] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(Int(sqlite3_column_int64(statement, column))))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count <= maximumTextBytes, let pointer = sqlite3_column_text(statement, column),
                        let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else { throw AuthorityStateError.integrity }
                    row.append(.text(value))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count <= 65_536 else { throw AuthorityStateError.limit }
                    row.append(.bytes(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()))
                case SQLITE_NULL: row.append(.null)
                default: throw AuthorityStateError.integrity
                }
            }
            try body(row)
        }
    }
    private static func point(_ db: OpaquePointer, _ sql: String, _ values: [Cell] = []) throws -> [Cell]? {
        var row: [Cell]?
        try visit(db, sql, values) { value in
            guard row == nil else { throw AuthorityStateError.integrity }; row = value
        }
        return row
    }
    private static func integer(_ value: Cell) throws -> Int {
        guard case .integer(let value) = value else { throw AuthorityStateError.integrity }; return value
    }
    private static func text(_ value: Cell) throws -> String {
        guard case .text(let value) = value else { throw AuthorityStateError.integrity }; return value
    }
    private static func pending(_ state: EpisodeWorkState) -> Bool {
        [.prepared, .dispatchArmed, .submitted].contains(state)
    }
    private static func work(_ db: OpaquePointer, episodeID: String, workID: String) throws -> EpisodeWorkState {
        try identifier(episodeID); try identifier(workID)
        guard let row = try point(db, "SELECT episode_id,state FROM episode_work WHERE id=?", [.text(workID)]),
            row.count == 2, episodeIdentifierEqual(try text(row[0]), episodeID),
            let state = EpisodeWorkState(rawValue: try text(row[1])) else { throw AuthorityStateError.integrity }
        return state
    }
    private static func episodeState(_ db: OpaquePointer, _ id: String) throws -> EpisodeState {
        try identifier(id)
        guard let row = try point(db, "SELECT state FROM episodes WHERE id=?", [.text(id)]),
            let state = EpisodeState(rawValue: try text(row[0])) else { throw AuthorityStateError.integrity }
        return state
    }
    static func receipt(database: OpaquePointer, episodeID: String) throws -> EpisodeCleanupReceipt {
        try identifier(episodeID)
        guard let row = try point(database, "SELECT classification,limit_rows,prepaid_rows,consumed_rows,pending_rows,attempted_rows,administrative_rows,terminal_ticks FROM episode_cleanup_budget WHERE episode_id=?", [.text(episodeID)]),
            row.count == 8, let classification = EpisodeCleanupClassification(rawValue: try text(row[0])) else { throw AuthorityStateError.integrity }
        let limit = try integer(row[1]), prepaid = try integer(row[2]), consumed = try integer(row[3]), pending = try integer(row[4]), attempted = try integer(row[5]), administrative = try integer(row[6]), terminal = try integer(row[7])
        guard (1...100_000).contains(limit), (0...limit).contains(prepaid), (0...prepaid).contains(consumed),
            (0...prepaid).contains(pending), consumed + pending <= prepaid, (0...(EpisodeCleanupLimits.attemptsPerWork * prepaid)).contains(attempted),
            administrative >= 0, (consumed <= attempted || consumed - attempted <= administrative), terminal >= 0 else { throw AuthorityStateError.integrity }
        return EpisodeCleanupReceipt(episodeID: episodeID, classification: classification, limitRows: limit,
            prepaidRows: prepaid, consumedRows: consumed, pendingRows: pending, attemptedRows: attempted,
            administrativeRows: administrative, terminalTicks: UInt64(terminal))
    }
    static func install(database: OpaquePointer) throws {
        try transactionRequired(database)
        for sql in schemaStatements { try execute(database, sql) }
        try validateSchema(database: database)
    }
    private static let schemaQuery = "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE name='episode_cleanup_pending' OR tbl_name IN ('episode_cleanup_budget','episode_cleanup_receipts')"
    static func validateSchema(database: OpaquePointer) throws {
        var raw: OpaquePointer?
        guard sqlite3_open(":memory:", &raw) == SQLITE_OK, let reference = raw else { throw AuthorityStateError.integrity }
        defer { sqlite3_close(reference) }
        try execute(reference, "CREATE TABLE episode_work(episode_id TEXT,id TEXT,state TEXT)")
        for sql in schemaStatements { try execute(reference, sql) }
        var expected: [Data: Data] = [:]
        try visit(reference, schemaQuery, maximumTextBytes: 65_536) { row in expected[Data(try text(row[1]).utf8)] = try rowBytes(row) }
        try visit(database, schemaQuery, maximumTextBytes: 65_536) { row in
            guard let bytes = expected.removeValue(forKey: Data(try text(row[1]).utf8)), bytes == (try rowBytes(row)) else { throw AuthorityStateError.integrity }
        }
        guard expected.isEmpty else { throw AuthorityStateError.integrity }
    }
    static func create(database: OpaquePointer, episodeID: String, limits: EpisodeCleanupLimits) throws {
        try transactionRequired(database); try identifier(episodeID); let limits = try limits.validated()
        guard try episodeState(database, episodeID) == .active,
            let row = try point(database, "SELECT limits_json FROM episodes WHERE id=?", [.text(episodeID)]), let bytes = row[0].bytes else { throw AuthorityStateError.integrity }
        let frozen = try decodeLimits(bytes)
        guard frozen.terminalCleanup == limits else { throw AuthorityStateError.conflict }
        try execute(database, "INSERT INTO episode_cleanup_budget VALUES(?,'prepaid-v1',?,0,0,0,0,0,0)", [.text(episodeID), .integer(limits.maximumWorkRows)])
    }
    static func canReserve(database: OpaquePointer, episodeID: String) throws -> Bool {
        let budget = try receipt(database: database, episodeID: episodeID)
        return try budget.terminalTicks == 0 && budget.prepaidRows < budget.limitRows && episodeState(database, episodeID) == .active
    }
    static func recordReserved(database: OpaquePointer, episodeID: String, workID: String) throws {
        try transactionRequired(database)
        let budget = try receipt(database: database, episodeID: episodeID)
        guard try episodeState(database, episodeID) == .active, budget.terminalTicks == 0,
            budget.prepaidRows < budget.limitRows, try work(database, episodeID: episodeID, workID: workID) == .prepared,
            let accounting = try point(database, "SELECT work_count FROM episode_accounting WHERE episode_id=?", [.text(episodeID)]),
            try integer(accounting[0]) == budget.prepaidRows + 1 else { throw AuthorityStateError.integrity }
        try execute(database, "UPDATE episode_cleanup_budget SET prepaid_rows=prepaid_rows+1,pending_rows=pending_rows+1 WHERE episode_id=?", [.text(episodeID)])
        guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
    }
    @discardableResult static func terminalFence(database: OpaquePointer, episodeID: String, ticks: UInt64) throws -> UInt64 {
        try transactionRequired(database); let ticks = try tick(ticks)
        let budget = try receipt(database: database, episodeID: episodeID)
        guard try episodeState(database, episodeID) != .active else { throw AuthorityStateError.invalid }
        if budget.terminalTicks != 0 { return budget.terminalTicks }
        guard let row = try point(database, "SELECT created_ticks FROM episodes WHERE id=?", [.text(episodeID)]),
            try integer(row[0]) <= ticks else { throw AuthorityStateError.invalid }
        try execute(database, "UPDATE episode_cleanup_budget SET terminal_ticks=? WHERE episode_id=? AND terminal_ticks=0", [.integer(ticks), .text(episodeID)])
        guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
        return UInt64(ticks)
    }
    /// The owner commits this charge in a separate fenced transaction before
    /// attempting cleanup. A later batch rollback never refunds this counter.
    static func chargeAttempt(database: OpaquePointer, episodeID: String, maximumRows: Int,
        recovering: Bool = false) throws -> Int {
        try transactionRequired(database)
        guard (1...EpisodeCleanupLimits.batchRows).contains(maximumRows) else { throw EpisodeBudgetError.invalid }
        let budget = try receipt(database: database, episodeID: episodeID)
        guard try episodeState(database, episodeID) != .active, budget.terminalTicks > 0,
            budget.pendingRows > 0 else { throw EpisodeBudgetError.invalid }
        let allowance = recovering ? budget.pendingRows : EpisodeCleanupLimits.attemptsPerWork * budget.prepaidRows - budget.attemptedRows
        let count = min(maximumRows, budget.pendingRows, allowance)
        guard count > 0 else { throw EpisodeBudgetError.exhausted }
        if recovering {
            let (total, overflow) = budget.administrativeRows.addingReportingOverflow(count)
            guard !overflow, total <= Int64.max else { throw AuthorityStateError.limit }
            try execute(database, "UPDATE episode_cleanup_budget SET administrative_rows=? WHERE episode_id=?", [.integer(total), .text(episodeID)])
        } else {
            try execute(database, "UPDATE episode_cleanup_budget SET attempted_rows=attempted_rows+? WHERE episode_id=?", [.integer(count), .text(episodeID)])
        }
        guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
        return count
    }
    static func recordTransition(database: OpaquePointer, episodeID: String, workID: String,
        from: EpisodeWorkState, to: EpisodeWorkState) throws {
        try transactionRequired(database)
        guard try work(database, episodeID: episodeID, workID: workID) == to else { throw AuthorityStateError.integrity }
        let budget = try receipt(database: database, episodeID: episodeID), delta = (pending(to) ? 1 : 0) - (pending(from) ? 1 : 0)
        guard budget.pendingRows + delta >= 0, budget.pendingRows + delta <= budget.prepaidRows - budget.consumedRows else { throw AuthorityStateError.integrity }
        if pending(to) { guard try budget.terminalTicks == 0 && episodeState(database, episodeID) == .active else { throw AuthorityStateError.invalid } }
        if delta != 0 {
            try execute(database, "UPDATE episode_cleanup_budget SET pending_rows=pending_rows+? WHERE episode_id=?", [.integer(delta), .text(episodeID)])
            guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
        }
    }
    private static func permittedAfterCleanup(_ from: EpisodeWorkState, _ current: EpisodeWorkState) -> Bool {
        if from == .prepared { return current == .cancelledBeforeDispatch || current == .failedConfirmed }
        return (from == .dispatchArmed || from == .submitted) && [.outcomeUnknown, .completed, .failedConfirmed].contains(current)
    }
    static func recordCleanup(database: OpaquePointer, episodeID: String, workID: String,
        from: EpisodeWorkState, ticks: UInt64) throws {
        try transactionRequired(database); let ticks = try tick(ticks)
        let budget = try receipt(database: database, episodeID: episodeID), current = try work(database, episodeID: episodeID, workID: workID)
        guard pending(from), try episodeState(database, episodeID) != .active, budget.terminalTicks == UInt64(ticks),
            permittedAfterCleanup(from, current) else { throw AuthorityStateError.integrity }
        if let old = try point(database, "SELECT episode_id,from_state,ticks FROM episode_cleanup_receipts WHERE work_id=?", [.text(workID)]) {
            guard episodeIdentifierEqual(try text(old[0]), episodeID), try text(old[1]) == from.rawValue,
                try integer(old[2]) == ticks else { throw AuthorityStateError.conflict }
            return
        }
        let expected: EpisodeWorkState = from == .prepared ? .cancelledBeforeDispatch : .outcomeUnknown
        guard current == expected, budget.consumedRows < budget.prepaidRows - budget.pendingRows,
            (budget.consumedRows < budget.attemptedRows || budget.consumedRows - budget.attemptedRows < budget.administrativeRows),
            let row = try point(database, "SELECT ended_ticks FROM episode_work WHERE id=?", [.text(workID)]),
            try integer(row[0]) == ticks else { throw AuthorityStateError.integrity }
        try execute(database, "INSERT INTO episode_cleanup_receipts VALUES(?,?,?,?)", [.text(workID), .text(episodeID), .text(from.rawValue), .integer(ticks)])
        try execute(database, "UPDATE episode_cleanup_budget SET consumed_rows=consumed_rows+1 WHERE episode_id=?", [.text(episodeID)])
        guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
    }
    private static func decodeLimits(_ bytes: Data) throws -> EpisodeLimits {
        guard !bytes.isEmpty, bytes.count <= 65_536 else { throw AuthorityStateError.integrity }
        do {
            let limits = try JSONDecoder().decode(EpisodeLimits.self, from: bytes)
            _ = try limits.terminalCleanup?.validated(); return limits
        } catch { throw AuthorityStateError.integrity }
    }
    static func backfill(database: OpaquePointer) throws {
        try transactionRequired(database); try validateSchema(database: database)
        for table in tableNames {
            guard try point(database, "SELECT 1 FROM " + table + " LIMIT 1") == nil else { throw AuthorityStateError.conflict }
        }
        try visit(database, "SELECT id,limits_json,state FROM episodes ORDER BY id COLLATE BINARY") { row in
            let id = try text(row[0]); try identifier(id)
            guard let bytes = row[1].bytes, let state = EpisodeState(rawValue: try text(row[2])),
                let accounting = try point(database, "SELECT work_count FROM episode_accounting WHERE episode_id=?", [.text(id)]) else { throw AuthorityStateError.integrity }
            _ = try decodeLimits(bytes)
            let count = try integer(accounting[0]); guard (0...100_000).contains(count) else { throw AuthorityStateError.integrity }
            var pendingRows = 0
            try visit(database, "SELECT id FROM episode_work WHERE episode_id=? AND " + pendingPredicate + " ORDER BY id COLLATE BINARY", [.text(id)]) { pending in
                try identifier(try text(pending[0])); try AuthorityStateKernel.increment(&pendingRows)
                guard pendingRows <= count else { throw AuthorityStateError.integrity }
            }
            guard state == .active || pendingRows == 0 else { throw AuthorityStateError.integrity }
            // Every migrated episode has explicitly administrative slots. A
            // serialized policy field cannot manufacture historical payment.
            try execute(database, "INSERT INTO episode_cleanup_budget VALUES(?,'legacy-administrative',100000,?,0,?,0,0,0)", [.text(id), .integer(count), .integer(pendingRows)])
        }
    }
    private static func noRows(_ db: OpaquePointer, _ sql: String) throws {
        guard try point(db, sql + " LIMIT 1") == nil else { throw AuthorityStateError.integrity }
    }
    static func validate(database: OpaquePointer) throws {
        let ownsSnapshot = sqlite3_get_autocommit(database) != 0
        do {
            if ownsSnapshot { try execute(database, "BEGIN") }
            try validateSchema(database: database)
            try noRows(database, "SELECT 1 FROM episode_cleanup_budget b LEFT JOIN episodes e ON e.id=b.episode_id WHERE e.id IS NULL")
            try noRows(database, "SELECT 1 FROM episode_work w LEFT JOIN episodes e ON e.id=w.episode_id WHERE e.id IS NULL")
            try noRows(database, "SELECT 1 FROM episode_cleanup_receipts r LEFT JOIN episode_cleanup_budget b ON b.episode_id=r.episode_id LEFT JOIN episode_work w ON w.id=r.work_id WHERE b.episode_id IS NULL OR w.id IS NULL OR w.episode_id!=r.episode_id COLLATE BINARY")
            try visit(database, "SELECT id,limits_json,state,created_ticks FROM episodes ORDER BY id COLLATE BINARY") { row in
                let id = try text(row[0]); try identifier(id)
                guard let bytes = row[1].bytes, let state = EpisodeState(rawValue: try text(row[2])) else { throw AuthorityStateError.integrity }
                let limits = try decodeLimits(bytes), budget = try receipt(database: database, episodeID: id), created = try integer(row[3])
                guard created > 0 else { throw AuthorityStateError.integrity }
                if budget.classification == .prepaidV1 {
                    guard let policy = limits.terminalCleanup, policy.maximumWorkRows == budget.limitRows else { throw AuthorityStateError.integrity }
                } else { guard budget.limitRows == 100_000 else { throw AuthorityStateError.integrity } }
                if state == .active { guard budget.terminalTicks == 0 && budget.consumedRows == 0 && budget.attemptedRows == 0 && budget.administrativeRows == 0 else { throw AuthorityStateError.integrity } }
                else if budget.pendingRows > 0 || budget.classification == .prepaidV1 { guard budget.terminalTicks > 0 else { throw AuthorityStateError.integrity } }
                if budget.terminalTicks != 0 { guard budget.terminalTicks >= UInt64(created) else { throw AuthorityStateError.integrity } }
                var counted = 0, pendingRows = 0, cleaned = 0
                try visit(database, "SELECT id,episode_id,state,created_ticks,armed_ticks,ended_ticks,length(receipt_json) FROM episode_work WHERE episode_id=? ORDER BY id COLLATE BINARY", [.text(id)]) { work in
                    let workID = try text(work[0]); try identifier(workID)
                    guard episodeIdentifierEqual(try text(work[1]), id), let current = EpisodeWorkState(rawValue: try text(work[2])) else { throw AuthorityStateError.integrity }
                    let createdTicks = try integer(work[3]), armedTicks = try integer(work[4]), endedTicks = try integer(work[5])
                    guard createdTicks >= created, armedTicks >= 0, endedTicks >= 0 else { throw AuthorityStateError.integrity }
                    try AuthorityStateKernel.increment(&counted); guard counted <= budget.limitRows else { throw AuthorityStateError.integrity }
                    if pending(current) { try AuthorityStateKernel.increment(&pendingRows) }
                    let settlementBytes = try integer(work[6])
                    guard settlementBytes >= 0 else { throw AuthorityStateError.integrity }
                    let cleanup = try point(database, "SELECT episode_id,from_state,ticks FROM episode_cleanup_receipts WHERE work_id=?", [.text(workID)])
                    if budget.classification == .prepaidV1 && !pending(current) && settlementBytes == 0 {
                        guard cleanup != nil else { throw AuthorityStateError.integrity }
                    }
                    if let cleanup {
                        guard episodeIdentifierEqual(try text(cleanup[0]), id), let from = EpisodeWorkState(rawValue: try text(cleanup[1])),
                            pending(from), permittedAfterCleanup(from, current), state != .active else { throw AuthorityStateError.integrity }
                        let cleanupTicks = try integer(cleanup[2])
                        guard cleanupTicks > 0, UInt64(cleanupTicks) == budget.terminalTicks, cleanupTicks >= createdTicks,
                            endedTicks > 0 else { throw AuthorityStateError.integrity }
                        if from == .prepared { guard armedTicks == 0 else { throw AuthorityStateError.integrity } }
                        else { guard armedTicks >= createdTicks && armedTicks <= cleanupTicks else { throw AuthorityStateError.integrity } }
                        try AuthorityStateKernel.increment(&cleaned)
                    }
                }
                guard counted == budget.prepaidRows, pendingRows == budget.pendingRows, cleaned == budget.consumedRows,
                    pendingRows + cleaned <= counted else { throw AuthorityStateError.integrity }
                guard let accounting = try point(database, "SELECT work_count FROM episode_accounting WHERE episode_id=?", [.text(id)]),
                    try integer(accounting[0]) == counted else { throw AuthorityStateError.integrity }
            }
            if ownsSnapshot { try execute(database, "COMMIT") }
        } catch {
            if ownsSnapshot { try? execute(database, "ROLLBACK") }
            throw AuthorityStateError.integrity
        }
    }
    private struct EncodedCell: Encodable {
        let kind: String
        let text: String?
        let integer: Int?
    }
    private static func rowBytes(_ row: [Cell]) throws -> Data {
        try canonical(row.map { cell -> EncodedCell in
            switch cell {
            case .text(let value): return EncodedCell(kind: "text", text: value, integer: nil)
            case .integer(let value): return EncodedCell(kind: "integer", text: nil, integer: value)
            case .null: return EncodedCell(kind: "null", text: nil, integer: nil)
            default: throw AuthorityStateError.integrity
            }
        })
    }
    private static func add(_ value: inout Int, _ delta: Int) throws {
        let (next, overflow) = value.addingReportingOverflow(delta)
        guard delta >= 0, !overflow else { throw AuthorityStateError.limit }; value = next
    }
    static func inventory(database: OpaquePointer) throws -> EpisodeCleanupInventory {
        let ownsSnapshot = sqlite3_get_autocommit(database) != 0
        do {
            if ownsSnapshot { try execute(database, "BEGIN") }
            try validate(database: database)
            var budgets = 0, prepaidBudgets = 0, legacyBudgets = 0, receipts = 0, prepaidRows = 0, consumedRows = 0, pendingRows = 0, attemptedRows = 0, administrativeRows = 0
            var budgetHash = SHA256(), receiptHash = SHA256()
            budgetHash.update(data: Data("[".utf8)); receiptHash.update(data: Data("[".utf8))
            try visit(database, "SELECT episode_id,classification,limit_rows,prepaid_rows,consumed_rows,pending_rows,attempted_rows,administrative_rows,terminal_ticks FROM episode_cleanup_budget ORDER BY episode_id COLLATE BINARY") { row in
                if budgets > 0 { budgetHash.update(data: Data(",".utf8)) }; budgetHash.update(data: try rowBytes(row))
                try AuthorityStateKernel.increment(&budgets)
                if try text(row[1]) == EpisodeCleanupClassification.prepaidV1.rawValue {
                    try AuthorityStateKernel.increment(&prepaidBudgets); try add(&prepaidRows, integer(row[3]))
                } else { try AuthorityStateKernel.increment(&legacyBudgets) }
                try add(&consumedRows, integer(row[4])); try add(&pendingRows, integer(row[5]))
                try add(&attemptedRows, integer(row[6])); try add(&administrativeRows, integer(row[7]))
            }
            try visit(database, "SELECT work_id,episode_id,from_state,ticks FROM episode_cleanup_receipts ORDER BY work_id COLLATE BINARY") { row in
                if receipts > 0 { receiptHash.update(data: Data(",".utf8)) }; receiptHash.update(data: try rowBytes(row)); try AuthorityStateKernel.increment(&receipts)
            }
            budgetHash.update(data: Data("]".utf8)); receiptHash.update(data: Data("]".utf8))
            let result = EpisodeCleanupInventory(budgets: budgets, prepaidBudgets: prepaidBudgets, legacyBudgets: legacyBudgets,
                receipts: receipts, prepaidRows: prepaidRows, consumedRows: consumedRows, pendingRows: pendingRows,
                attemptedRows: attemptedRows, administrativeRows: administrativeRows,
                budgetSHA256: budgetHash.finalize().map { String(format: "%02x", $0) }.joined(),
                receiptSHA256: receiptHash.finalize().map { String(format: "%02x", $0) }.joined())
            if ownsSnapshot { try execute(database, "COMMIT") }
            return result
        } catch {
            if ownsSnapshot { try? execute(database, "ROLLBACK") }
            throw AuthorityStateError.integrity
        }
    }
}
