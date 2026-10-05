import Foundation
import Darwin

/// The continuous Mach clock advances during sleep. A kernel boot UUID makes
/// persisted ticks comparable across application restarts, never across boots.
final class SystemEpisodeClock: EpisodeClockSource {
    private let domain: String?
    init() {
        var count = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0,
           count > 1, count <= 128 {
            var bytes = [CChar](repeating: 0, count: count)
            if sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0,
               let uuid = UUID(uuidString: String(cString: bytes)) {
                domain = "mach-continuous-v1:" + uuid.uuidString.lowercased()
                return
            }
        }
        domain = nil
    }
    func now() throws -> EpisodeClockSnapshot {
        guard let domain else { throw EpisodeBudgetError.clockUnavailable }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else {
            throw EpisodeBudgetError.clockUnavailable
        }
        let ticks = mach_continuous_time()
        let numerator = UInt64(timebase.numer), denominator = UInt64(timebase.denom)
        let (whole, overflow) = (ticks / denominator).multipliedReportingOverflow(by: numerator)
        let fraction = (ticks % denominator) * numerator / denominator
        let (nanoseconds, additionOverflow) = whole.addingReportingOverflow(fraction)
        guard !overflow, !additionOverflow, nanoseconds > 0, nanoseconds <= UInt64(Int64.max) else {
            throw EpisodeBudgetError.clockUnavailable
        }
        return EpisodeClockSnapshot(domain: domain, continuousNanoseconds: nanoseconds, utc: Date())
    }
}

/// Every adapter shares the same durable episode. A lease has no local quota
/// reset and does not interpret cancellation as proof of unused server work.
final class EpisodeLease: @unchecked Sendable {
    private let ledger: EpisodeLedger
    private let clock: EpisodeClockSource
    private let lifecycleLock = NSLock()
    private var localInterruption: EpisodeBudgetError?
    let episodeID: String

    init(ledger: EpisodeLedger, episodeID: String, clock: EpisodeClockSource = SystemEpisodeClock()) {
        self.ledger = ledger; self.episodeID = episodeID; self.clock = clock
    }
    func checkActive() throws -> EpisodeReceipt {
        if let reason = progressCancellationReason() { throw reason }
        let receipt = try ledger.episodeReceipt(id: episodeID, clock: clock.now())
        guard receipt.state == .active else {
            if receipt.state == .deadlineExceeded { throw EpisodeBudgetError.deadlineExceeded }
            if receipt.state == .budgetExceeded { throw EpisodeBudgetError.exhausted }
            throw EpisodeBudgetError.inactive
        }
        return receipt
    }
    func checkActive(projectID: String) throws -> EpisodeReceipt {
        let receipt = try checkActive()
        guard episodeIdentifierEqual(receipt.projectID, projectID) else { throw EpisodeBudgetError.scopeMismatch }
        return receipt
    }
    func prepare(kind: EpisodeWorkKind, resources: EpisodeResources, adapterIdentity: String,
        snapshot: Data? = nil, inputTokensKnown: Bool = true, parentID: String? = nil,
        operationID: String = UUID().uuidString) throws -> EpisodeWorkRecord {
        if let reason = progressCancellationReason() { throw reason }
        return try ledger.reserveEpisodeWork(episodeID: episodeID,
            request: EpisodeWorkRequest(id: operationID, parentID: parentID, kind: kind,
                resources: resources, adapterIdentity: adapterIdentity, snapshot: snapshot, inputTokensKnown: inputTokensKnown),
            clock: clock.now())
    }
    func arm(_ work: EpisodeWorkRecord) throws -> EpisodeWorkRecord {
        if let reason = progressCancellationReason() { throw reason }
        guard episodeIdentifierEqual(work.episodeID, episodeID) else { throw EpisodeBudgetError.invalid }
        return try ledger.armEpisodeWork(episodeID: episodeID, operationID: work.id,
            expectedRevision: work.revision, clock: clock.now())
    }
    func dispatch(_ work: EpisodeWorkRecord, start: () -> Void) throws -> EpisodeWorkRecord {
        if let reason = progressCancellationReason() { throw reason }
        guard episodeIdentifierEqual(work.episodeID, episodeID) else { throw EpisodeBudgetError.invalid }
        var suppressed: EpisodeBudgetError?
        let handed = try ledger.performEpisodeHandoff(episodeID: episodeID, operationID: work.id,
            expectedRevision: work.revision, clock: clock.now()) {
                if let reason = self.progressCancellationReason() { suppressed = reason; return }
                start()
            }
        if let suppressed { throw suppressed }
        return handed
    }
    func settle(_ work: EpisodeWorkRecord, outcome: EpisodeWorkOutcome,
        observed: EpisodeResources? = nil, evidence: Data? = nil,
        receiptID: String = UUID().uuidString, adapterViolation: Bool = false) throws -> EpisodeWorkRecord {
        guard episodeIdentifierEqual(work.episodeID, episodeID) else { throw EpisodeBudgetError.invalid }
        return try ledger.settleEpisodeWork(episodeID: episodeID, operationID: work.id,
            settlement: EpisodeWorkSettlement(receiptID: receiptID, outcome: outcome, observed: observed, evidence: evidence, adapterViolation: adapterViolation),
            clock: clock.now())
    }
    func finish(reason: EpisodeState) throws -> EpisodeReceipt {
        guard reason != .active else { throw EpisodeBudgetError.invalid }
        interruptLocally(reason: reason)
        return try ledger.finishEpisode(episodeID: episodeID, reason: reason, clock: clock.now())
    }
    /// This immediate fence performs no database work and may be called from
    /// the UI before scheduling durable terminalization on an owner queue.
    func interruptLocally(reason: EpisodeState) {
        precondition(reason != .active)
        lifecycleLock.lock()
        if localInterruption == nil {
            localInterruption = reason == .deadlineExceeded ? .deadlineExceeded : reason == .budgetExceeded ? .exhausted : .inactive
        }
        lifecycleLock.unlock()
    }
    private func progressCancellationReason() -> EpisodeBudgetError? {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return localInterruption
    }
    func progressGuard() throws -> EpisodeSQLFence {
        let receipt = try checkActive()
        return EpisodeSQLFence(clock: clock, domain: receipt.clockDomain, deadline: receipt.deadlineNanoseconds,
            cancellation: { [weak self] in self?.progressCancellationReason() ?? (self == nil ? .inactive : nil) })
    }
    func remainingSeconds() throws -> TimeInterval {
        let current = try clock.now()
        let receipt = try ledger.episodeReceipt(id: episodeID, clock: current)
        guard receipt.state == .active else {
            if receipt.state == .deadlineExceeded { throw EpisodeBudgetError.deadlineExceeded }
            if receipt.state == .budgetExceeded { throw EpisodeBudgetError.exhausted }
            throw EpisodeBudgetError.inactive
        }
        guard current.domain == receipt.clockDomain, current.continuousNanoseconds < receipt.deadlineNanoseconds else {
            throw EpisodeBudgetError.deadlineExceeded
        }
        return Double(receipt.deadlineNanoseconds - current.continuousNanoseconds) / 1_000_000_000
    }
}
