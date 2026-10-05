import Foundation
import CSQLite

/// SQLite callbacks inspect only this independent clock/cancellation guard.
/// They never acquire the database owner or query the durable ledger.
final class EpisodeSQLFence {
    private let clock: EpisodeClockSource
    private let domain: String
    private let deadline: UInt64
    private let cancellation: () -> EpisodeBudgetError?

    init(clock: EpisodeClockSource, domain: String, deadline: UInt64,
         cancellation: @escaping () -> EpisodeBudgetError?) {
        self.clock = clock; self.domain = domain; self.deadline = deadline; self.cancellation = cancellation
    }

    func interruption() -> EpisodeBudgetError? {
        if let reason = cancellation() { return reason }
        guard let current = try? clock.now(), current.domain == domain else { return .clockUnavailable }
        return current.continuousNanoseconds >= deadline ? .deadlineExceeded : nil
    }

    private static func install(_ fence: EpisodeSQLFence?, on database: OpaquePointer) {
        guard let fence else { sqlite3_progress_handler(database, 0, nil, nil); return }
        sqlite3_progress_handler(database, 1000, { pointer in
            guard let pointer else { return 1 }
            let fence = Unmanaged<EpisodeSQLFence>.fromOpaque(pointer).takeUnretainedValue()
            return fence.interruption() == nil ? 0 : 1
        }, Unmanaged.passUnretained(fence).toOpaque())
    }

    func perform<T>(on database: OpaquePointer, restoring previous: EpisodeSQLFence? = nil,
                    _ body: () throws -> T) throws -> T {
        if let reason = interruption() { throw reason }
        Self.install(self, on: database)
        defer { Self.install(previous, on: database) }
        do {
            let value = try body()
            if let reason = interruption() { throw reason }
            return value
        } catch {
            if let reason = interruption() { throw reason }
            throw error
        }
    }
}
