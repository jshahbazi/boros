import Foundation
import CSQLite

struct BackgroundIndexInventory: Codable, Equatable {
    let windows: Int
    let works: Int
    let prepared: Int
    let uncertain: Int
    let charged: BackgroundIndexResources
    let held: BackgroundIndexResources
    let unknownEncoderCalls: Int
    let preparedRelease: BackgroundIndexResources
}

/// Main-store inventory validator shared by reopen and read-only archives.
/// The sidecar is derived; no sidecar presence or cursor can reset these sums.
enum BackgroundIndexJournal {
    static func inventory(database: OpaquePointer) throws -> BackgroundIndexInventory {
        try validate(database: database)
        func payloads(_ sql: String) throws -> [Data] {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw BackgroundIndexBudgetError.invalid }
            defer { sqlite3_finalize(statement) }
            var values: [Data] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return values }
                guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw BackgroundIndexBudgetError.invalid }
                values.append(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0))))
            }
        }
        let windows = try payloads("SELECT window_json FROM background_index_windows").map { try BackgroundIndexCanonical.decode(BackgroundIndexWindow.self, bytes: $0) }
        let works = try payloads("SELECT record_json FROM background_index_work").map { try BackgroundIndexCanonical.decode(BackgroundIndexWorkRecord.self, bytes: $0) }
        var charged = BackgroundIndexResources.zero, held = BackgroundIndexResources.zero, released = BackgroundIndexResources.zero, unknown = 0
        for window in windows {
            charged = try charged.adding(window.charged); held = try held.adding(window.held)
            let (sum, overflow) = unknown.addingReportingOverflow(window.unknownEncoderCalls)
            guard !overflow else { throw BackgroundIndexBudgetError.invalid }; unknown = sum
        }
        for work in works where work.state == .prepared { released = try released.adding(work.held) }
        return BackgroundIndexInventory(windows: windows.count, works: works.count, prepared: works.filter { $0.state == .prepared }.count,
            uncertain: works.filter { [.armed, .submitted, .outcomeUnknown].contains($0.state) }.count,
            charged: charged, held: held, unknownEncoderCalls: unknown, preparedRelease: released)
    }

    static func validate(database: OpaquePointer) throws {
        func rows<T>(_ sql: String, _ map: (OpaquePointer) throws -> T) throws -> [T] {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else {
                throw MemoryError.database("invalid background archive schema")
            }
            defer { sqlite3_finalize(statement) }
            var values: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return values }
                guard result == SQLITE_ROW else { throw MemoryError.database("background archive query failed") }
                values.append(try map(statement))
            }
        }
        func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
            guard sqlite3_column_type(row, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(row, column),
                  let value = String(data: Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8) else {
                throw BackgroundIndexBudgetError.invalid
            }
            return value
        }
        func bytes(_ row: OpaquePointer, _ column: Int32) throws -> Data {
            guard sqlite3_column_type(row, column) == SQLITE_BLOB else { throw BackgroundIndexBudgetError.invalid }
            guard let pointer = sqlite3_column_blob(row, column) else { return Data() }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, column)))
        }
        func integer(_ row: OpaquePointer, _ column: Int32) throws -> Int {
            guard sqlite3_column_type(row, column) == SQLITE_INTEGER else { throw BackgroundIndexBudgetError.invalid }
            return Int(sqlite3_column_int64(row, column))
        }
        struct WindowRow { let sequence: Int; let window: BackgroundIndexWindow }
        let windows = try rows("SELECT sequence,id,state,revision,window_json,window_digest,limits_json,limits_digest,started_clock_json,started_clock_digest FROM background_index_windows ORDER BY sequence") { row -> WindowRow in
            let data = try bytes(row, 4)
            guard BackgroundIndexCanonical.sha256(data) == (try text(row, 5)) else { throw BackgroundIndexBudgetError.invalid }
            let window = try BackgroundIndexCanonical.decode(BackgroundIndexWindow.self, bytes: data)
            let limitsBytes = try bytes(row, 6), clockBytes = try bytes(row, 8)
            guard backgroundIndexIdentifierEqual(window.id, try text(row, 1)), window.state.rawValue == (try text(row, 2)),
                  window.revision == (try integer(row, 3)), try integer(row, 0) > 0,
                  BackgroundIndexCanonical.sha256(limitsBytes) == (try text(row, 7)), BackgroundIndexCanonical.sha256(clockBytes) == (try text(row, 9)),
                  try BackgroundIndexCanonical.decode(BackgroundIndexLimits.self, bytes: limitsBytes) == window.limits,
                  try BackgroundIndexCanonical.decode(BackgroundIndexClockSnapshot.self, bytes: clockBytes) == window.startedClock else { throw BackgroundIndexBudgetError.invalid }
            return WindowRow(sequence: try integer(row, 0), window: window)
        }
        let works = try rows("SELECT id,window_id,state,adapter_identity,binding_digest,request_digest,record_json,record_digest,receipt_id,adapter_violation FROM background_index_work ORDER BY id") { row -> BackgroundIndexWorkRecord in
            let data = try bytes(row, 6)
            guard BackgroundIndexCanonical.sha256(data) == (try text(row, 7)) else { throw BackgroundIndexBudgetError.invalid }
            let work = try BackgroundIndexCanonical.decode(BackgroundIndexWorkRecord.self, bytes: data)
            guard backgroundIndexIdentifierEqual(work.request.id, try text(row, 0)), backgroundIndexIdentifierEqual(work.windowID, try text(row, 1)),
                  work.state.rawValue == (try text(row, 2)), backgroundIndexIdentifierEqual(work.request.binding.adapterIdentity, try text(row, 3)),
                  work.bindingDigest == (try text(row, 4)), work.requestDigest == (try text(row, 5)),
                  try integer(row, 9) == (work.settlement?.adapterViolation == true ? 1 : 0) else { throw BackgroundIndexBudgetError.invalid }
            if let receiptID = work.settlement?.receiptID {
                guard backgroundIndexIdentifierEqual(receiptID, try text(row, 8)) else { throw BackgroundIndexBudgetError.invalid }
            } else if sqlite3_column_type(row, 8) != SQLITE_NULL { throw BackgroundIndexBudgetError.invalid }
            return work
        }
        var workGroups = [Data: [BackgroundIndexWorkRecord]]()
        for work in works { workGroups[Data(work.windowID.utf8), default: []].append(work) }
        var windowIDs = Set<Data>(), workIDs = Set<Data>(), receiptIDs = Set<Data>()
        var previous: WindowRow?
        for row in windows {
            let window = row.window
            guard windowIDs.insert(Data(window.id.utf8)).inserted else { throw BackgroundIndexBudgetError.invalid }
            if backgroundIndexIdentifierEqual(window.anchor.domain, window.startedClock.domain) {
                guard window.anchor.continuousNanoseconds == window.startedClock.continuousNanoseconds,
                      window.anchor.establishedAgeNanoseconds == 0, !window.anchor.requiresUTCForRollover else {
                    throw BackgroundIndexBudgetError.invalid
                }
            } else if !window.anchor.requiresUTCForRollover { throw BackgroundIndexBudgetError.invalid }
            if let previous {
                guard previous.sequence < row.sequence, previous.window.state == .closed,
                      previous.window.closedClock == window.startedClock,
                      previous.window.limits == window.limits,
                      window.utcRolloverBaselineMilliseconds >= previous.window.utcHighWaterMilliseconds else {
                    throw BackgroundIndexBudgetError.invalid
                }
            }
            previous = row
            var charged = BackgroundIndexResources.zero, held = BackgroundIndexResources.zero, unknown = 0
            let own = workGroups[Data(window.id.utf8)] ?? []
            guard !own.isEmpty, own.count <= MemoryStore.maximumBackgroundWorkRecords else { throw BackgroundIndexBudgetError.invalid }
            let minimumRevision = own.count + own.filter({ !$0.charged.isZero }).count + own.filter({ $0.state == .cancelledBeforeDispatch }).count
            guard window.revision >= minimumRevision else { throw BackgroundIndexBudgetError.invalid }
            for work in own {
                guard workIDs.insert(Data(work.request.id.utf8)).inserted else { throw BackgroundIndexBudgetError.invalid }
                if let receiptID = work.settlement?.receiptID {
                    guard receiptIDs.insert(Data(receiptID.utf8)).inserted else { throw BackgroundIndexBudgetError.invalid }
                }
                guard window.utcHighWaterMilliseconds >= work.createdClock.utcMilliseconds,
                      work.armedClock == nil || window.utcHighWaterMilliseconds >= work.armedClock!.utcMilliseconds else {
                    throw BackgroundIndexBudgetError.invalid
                }
                if window.state == .closed && work.state == .prepared { throw BackgroundIndexBudgetError.invalid }
                if backgroundIndexIdentifierEqual(work.createdClock.domain, window.startedClock.domain) {
                    guard work.createdClock.continuousNanoseconds >= window.startedClock.continuousNanoseconds else { throw BackgroundIndexBudgetError.invalid }
                }
                if backgroundIndexIdentifierEqual(work.createdClock.domain, window.lastClock.domain) {
                    guard work.createdClock.continuousNanoseconds <= window.lastClock.continuousNanoseconds else { throw BackgroundIndexBudgetError.invalid }
                }
                if let armed = work.armedClock, backgroundIndexIdentifierEqual(armed.domain, window.lastClock.domain) {
                    guard armed.continuousNanoseconds <= window.lastClock.continuousNanoseconds else { throw BackgroundIndexBudgetError.invalid }
                }
                charged = try charged.adding(work.charged); held = try held.adding(work.held)
                if work.request.encoderInput == .unknown && !work.charged.isZero {
                    let (sum, overflow) = unknown.addingReportingOverflow(work.request.resources.encoderCalls)
                    guard !overflow else { throw BackgroundIndexBudgetError.invalid }; unknown = sum
                }
                let references: [BackgroundIndexSourceReference]
                switch work.request.binding.descriptor {
                case .source(_, let binding): references = [binding.source]
                case .metadataFrontier(let descriptor) where descriptor.target == .scheduleSources:
                    guard let payload = work.request.snapshot?.payload else { throw BackgroundIndexBudgetError.invalid }
                    references = try JSONDecoder().decode([BackgroundIndexSourceReference].self, from: payload)
                default: references = []
                }
                for source in references {
                    // Compare immutable metadata only. Core archive validation
                    // independently hashes the accepted payload inventory.
                    let matches = try rows("SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count FROM events WHERE sequence=" + String(source.sequence)) { sourceRow -> Bool in
                        try integer(sourceRow, 0) == source.sequence
                            && backgroundIndexIdentifierEqual(text(sourceRow, 1), source.eventID)
                            && backgroundIndexIdentifierEqual(text(sourceRow, 2), source.conversationID)
                            && backgroundIndexIdentifierEqual(text(sourceRow, 3), source.projectID)
                            && backgroundIndexIdentifierEqual(text(sourceRow, 4), source.role)
                            && backgroundIndexIdentifierEqual(text(sourceRow, 5), source.status)
                            && backgroundIndexIdentifierEqual(text(sourceRow, 6), source.createdAt)
                            && backgroundIndexIdentifierEqual(text(sourceRow, 7), source.digest)
                            && integer(sourceRow, 8) == source.byteCount
                    }
                    guard matches == [true] else { throw BackgroundIndexBudgetError.scopeMismatch }
                }
            }
            guard charged == window.charged, held == window.held, unknown == window.unknownEncoderCalls else { throw BackgroundIndexBudgetError.invalid }
        }
        guard workIDs.count == works.count, windows.filter({ $0.window.state == .active }).count <= 1,
              windows.last?.window.state != .closed || windows.isEmpty else { throw BackgroundIndexBudgetError.invalid }
        let foreignKeys = try rows("PRAGMA foreign_key_check") { _ in true }
        guard foreignKeys.isEmpty else { throw BackgroundIndexBudgetError.invalid }
    }
}
