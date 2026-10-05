import Foundation

enum LocalReadSearchMode: String, Codable { case lexical, literal }

/// A selected hit's source identity is carried into every explicit page read.
/// Search excerpts are never accepted as the source payload.
struct LocalReadSourceIdentity: Codable, Equatable {
    let sequence: Int?
    let eventID: String
    let conversationID: String
    let projectID: String
    let role: MemoryRole
    let status: CaptureStatus
    let createdAt: String
    let digest: String
    let byteCount: Int

    init(hit: MemoryHit) {
        sequence = nil
        eventID = hit.eventID; conversationID = hit.conversationID; projectID = hit.projectID
        role = hit.role; status = hit.status; createdAt = hit.createdAt
        digest = hit.digest; byteCount = hit.totalBytes
    }
    init(reference: MemorySourceReference) {
        sequence = reference.sequence
        eventID = reference.eventID; conversationID = reference.conversationID; projectID = reference.projectID
        role = reference.role; status = reference.status; createdAt = reference.createdAt
        digest = reference.digest; byteCount = reference.byteCount
    }
    func matches(_ reference: MemorySourceReference) -> Bool {
        (sequence == nil || sequence == reference.sequence) && episodeIdentifierEqual(eventID, reference.eventID)
            && episodeIdentifierEqual(conversationID, reference.conversationID) && episodeIdentifierEqual(projectID, reference.projectID)
            && role == reference.role && status == reference.status && createdAt == reference.createdAt
            && digest == reference.digest && byteCount == reference.byteCount
    }
}

enum LocalReadCoverage: String {
    case complete, candidateWindow, resultLimit, sourceWindow, resourceLimited
}

struct LocalReadSearchResult {
    let hits: [MemoryHit]
    let coverage: LocalReadCoverage
    let firstPage: PayloadPage?
}

enum LocalReadContent {
    case search(LocalReadSearchResult)
    case page(PayloadPage)
}

enum LocalReadOutcome: String {
    case completed, budgetLimited, deadlineExceeded, cancelled, failed
}

struct LocalReadToken: Equatable {
    let requestID: String
    let episodeID: String
}

struct LocalReadDelivery {
    let token: LocalReadToken
    let outcome: LocalReadOutcome
    let receipt: EpisodeReceipt?
    let content: LocalReadContent?
}

/// Each human operation has one durable lease. Supersession interrupts local
/// SQLite work immediately; durable cancellation is queued independently of the
/// serial read worker. UI callbacks belong on the same serial queue as actions.
final class LocalReadCoordinator: @unchecked Sendable {
    private struct Descriptor: Encodable {
        let version = "boros-local-browser-read-v1"
        let projectID: String
        let purpose: EpisodeLocalReadPurpose
        let mode: LocalReadSearchMode?
        let query: String?
        let source: LocalReadSourceIdentity?
        let offset: Int?
        let length: Int?
        let resultLimit: Int?
    }
    private final class Operation: @unchecked Sendable {
        let token: LocalReadToken
        let generation: UInt64
        let lease: EpisodeLease
        let receipt: EpisodeReceipt
        var timer: DispatchSourceTimer?
        init(token: LocalReadToken, generation: UInt64, lease: EpisodeLease, receipt: EpisodeReceipt) {
            self.token = token; self.generation = generation; self.lease = lease; self.receipt = receipt
        }
    }

    private let store: MemoryStore
    private let projectID: String
    private let clock: EpisodeClockSource
    private let limits: EpisodeLimits
    private let workQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let lifecycleQueue = DispatchQueue(label: "dev.boros.local-read.lifecycle")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var current: Operation?
    private var closed = false

    init(store: MemoryStore, projectID: String, limits: EpisodeLimits = .init(),
         clock: EpisodeClockSource = SystemEpisodeClock(),
         workQueue: DispatchQueue = DispatchQueue(label: "dev.boros.local-read.work", qos: .userInitiated),
         deliveryQueue: DispatchQueue = .main) {
        self.store = store; self.projectID = projectID; self.limits = limits
        self.clock = clock; self.workQueue = workQueue; self.deliveryQueue = deliveryQueue
    }

    @discardableResult
    func search(query: String, mode: LocalReadSearchMode, limit: Int = 8,
                completion: @escaping (LocalReadDelivery) -> Void) throws -> LocalReadToken {
        guard query.utf8.count <= MemoryStore.maximumPageBytes, (1...100).contains(limit),
              mode != .literal || !query.isEmpty else { cancel(); throw MeteredRetrievalError.invalid }
        let descriptor = Descriptor(projectID: projectID, purpose: .searchInitialPage, mode: mode,
            query: query, source: nil, offset: nil, length: nil, resultLimit: limit)
        let operation = try begin(descriptor: descriptor)
        workQueue.async { [weak self] in
            guard let self else { return }
            var partial: LocalReadSearchResult?
            do {
                _ = try operation.lease.checkActive(projectID: self.projectID)
                let hits: [MemoryHit], coverage: LocalReadCoverage
                if mode == .literal {
                    let report = try MeteredRetrieval.literalSearch(store: self.store, query: query,
                        projectID: self.projectID, limit: limit, lease: operation.lease)
                    hits = report.hits
                    switch report.incompleteReason {
                    case "raw_source_budget": coverage = .resourceLimited
                    case "result_limit": coverage = .resultLimit
                    case "source_window": coverage = .sourceWindow
                    case nil: coverage = .complete
                    default: throw MeteredRetrievalError.invalid
                    }
                } else {
                    let report = try MeteredRetrieval.lexicalSearch(store: self.store, query: query,
                        projectID: self.projectID, limit: limit, lease: operation.lease)
                    hits = report.hits
                    coverage = report.continuation != nil ? .resourceLimited
                        : report.candidateWindowFull ? .candidateWindow : .complete
                }
                partial = LocalReadSearchResult(hits: hits, coverage: coverage, firstPage: nil)
                // A partial raw-budget scan cannot silently spend more work on
                // an implicit first page. Selecting a hit is a new human action.
                if coverage == .resourceLimited {
                    self.finish(operation, reason: .budgetExceeded, content: .search(partial!), completion: completion)
                    return
                }
                let page = try hits.first.map {
                    try self.readPage(source: LocalReadSourceIdentity(hit: $0), offset: 0,
                        length: MemoryStore.maximumPageBytes, lease: operation.lease)
                }
                let result = LocalReadSearchResult(hits: hits, coverage: coverage, firstPage: page)
                self.finish(operation, reason: .completed, content: .search(result), completion: completion)
            } catch {
                let reason = Self.reason(error)
                let content: LocalReadContent? = reason == .budgetExceeded
                    ? partial.map { .search(LocalReadSearchResult(hits: $0.hits, coverage: .resourceLimited, firstPage: nil)) }
                    : nil
                self.finish(operation, reason: reason, content: content, completion: completion)
            }
        }
        return operation.token
    }

    @discardableResult
    func sourcePage(source: LocalReadSourceIdentity, offset: Int,
                    length: Int = MemoryStore.maximumPageBytes,
                    completion: @escaping (LocalReadDelivery) -> Void) throws -> LocalReadToken {
        guard episodeIdentifierEqual(source.projectID, projectID), source.byteCount >= 0,
              source.byteCount <= MemoryStore.maximumPayloadBytes,
              offset >= 0, offset <= source.byteCount, length > 0,
              length <= MemoryStore.maximumPageBytes else { cancel(); throw MeteredRetrievalError.invalid }
        let descriptor = Descriptor(projectID: projectID, purpose: .sourcePage, mode: nil, query: nil,
            source: source, offset: offset, length: length, resultLimit: nil)
        let operation = try begin(descriptor: descriptor)
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let page = try self.readPage(source: source, offset: offset, length: length, lease: operation.lease)
                self.finish(operation, reason: .completed, content: .page(page), completion: completion)
            } catch { self.finish(operation, reason: Self.reason(error), content: nil, completion: completion) }
        }
        return operation.token
    }

    @discardableResult
    func sourcePage(source: MemorySourceReference, offset: Int,
                    length: Int = MemoryStore.maximumPageBytes,
                    completion: @escaping (LocalReadDelivery) -> Void) throws -> LocalReadToken {
        try sourcePage(source: LocalReadSourceIdentity(reference: source), offset: offset,
            length: length, completion: completion)
    }

    /// Cancelling a window/action never waits for a store transaction.
    func cancel() { invalidate(close: false) }
    func close() { invalidate(close: true) }
    deinit { invalidate(close: true) }

    private func readPage(source: LocalReadSourceIdentity, offset: Int, length: Int,
                          lease: EpisodeLease) throws -> PayloadPage {
        _ = try lease.checkActive(projectID: projectID)
        return try MeteredRetrieval.operation(lease: lease) {
            guard let reference = try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 1, {
                try store.sourceReference(eventID: source.eventID, projectID: projectID)
            }), source.matches(reference) else { throw MeteredRetrievalError.sourceMismatch }
            return try MeteredRetrieval.read(store: store, source: reference, offset: offset,
                length: length, lease: lease, nested: true)
        }
    }

    private func begin(descriptor: Descriptor) throws -> Operation {
        // Freeze the continuous clock at the human action, before cancellation,
        // durable initiation or time spent waiting in the worker queue.
        let started = try clock.now()
        lock.lock()
        guard !closed else { lock.unlock(); throw EpisodeBudgetError.inactive }
        generation &+= 1
        let version = generation, previous = current
        current = nil
        lock.unlock()
        cancel(previous)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(descriptor)
        guard bytes.count <= 32 * 1024 else { throw MeteredRetrievalError.invalid }
        let token = LocalReadToken(requestID: UUID().uuidString, episodeID: UUID().uuidString)
        let binding = EpisodeLocalReadBinding(initiator: .humanBrowser, purpose: descriptor.purpose,
            requestID: token.requestID, descriptorVersion: descriptor.version,
            descriptorSHA256: MeteredRetrieval.digest(bytes))
        let receipt = try store.beginLocalReadEpisode(episodeID: token.episodeID, projectID: projectID,
            binding: binding, limits: limits, clock: started)
        let operation = Operation(token: token, generation: version,
            lease: EpisodeLease(ledger: store, episodeID: token.episodeID, clock: clock), receipt: receipt)
        lock.lock()
        let accepted = !closed && generation == version
        if accepted { current = operation }
        lock.unlock()
        guard accepted else { cancel(operation); throw EpisodeBudgetError.inactive }
        startDeadlineTimer(operation)
        return operation
    }

    private func startDeadlineTimer(_ operation: Operation) {
        let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak operation, clock] in
            guard let operation else { return }
            do {
                let now = try clock.now()
                guard now.domain != operation.receipt.clockDomain
                        || now.continuousNanoseconds >= operation.receipt.deadlineNanoseconds else { return }
                let reason: EpisodeState = now.domain == operation.receipt.clockDomain ? .deadlineExceeded : .interrupted
                operation.lease.interruptLocally(reason: reason)
                _ = try operation.lease.finish(reason: reason)
            } catch {
                operation.lease.interruptLocally(reason: .interrupted)
                _ = try? operation.lease.finish(reason: .interrupted)
            }
        }
        lock.lock()
        let accepted = current === operation && !closed
        if accepted { operation.timer = timer }
        lock.unlock()
        if accepted { timer.resume() } else { timer.setEventHandler {}; timer.resume(); timer.cancel() }
    }

    private func invalidate(close: Bool) {
        lock.lock()
        generation &+= 1
        if close { closed = true }
        let operation = current; current = nil
        lock.unlock()
        cancel(operation)
    }

    private func cancel(_ operation: Operation?) {
        guard let operation else { return }
        operation.lease.interruptLocally(reason: .cancelled)
        lock.lock(); let timer = operation.timer; operation.timer = nil; lock.unlock()
        timer?.cancel()
        lifecycleQueue.async { _ = try? operation.lease.finish(reason: .cancelled) }
    }

    private func finish(_ operation: Operation, reason: EpisodeState, content: LocalReadContent?,
                        completion: @escaping (LocalReadDelivery) -> Void) {
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let accepted = !self.closed && self.generation == operation.generation && self.current === operation
            self.lock.unlock()
            guard accepted else { return }
            // Keep the episode active while publication is queued. The final
            // short ledger transaction belongs to this delivery gate; source
            // reads and matching have already finished on the worker queue.
            let receipt = try? operation.lease.finish(reason: reason)
            self.lock.lock(); let timer = operation.timer; operation.timer = nil; self.lock.unlock()
            timer?.cancel()
            var outcome: LocalReadOutcome
            switch receipt?.state {
            case .completed: outcome = .completed
            case .budgetExceeded: outcome = .budgetLimited
            case .deadlineExceeded: outcome = .deadlineExceeded
            case .cancelled: outcome = .cancelled
            default: outcome = .failed
            }
            // If the boundary crosses during that final transaction, suppress
            // delivery without rewriting a receipt already durably terminal.
            if outcome == .completed || outcome == .budgetLimited {
                if let now = try? self.clock.now(), let receipt,
                   now.domain == receipt.clockDomain,
                   now.continuousNanoseconds < receipt.deadlineNanoseconds {
                    // Publication remains inside its original continuous bound.
                } else { outcome = .deadlineExceeded }
            }
            self.lock.lock()
            let stillCurrent = !self.closed && self.generation == operation.generation && self.current === operation
            if stillCurrent { self.current = nil }
            self.lock.unlock()
            guard stillCurrent else { return }
            // Failed or expired publication cannot expose source bytes.
            let deliveredContent = outcome == .completed || outcome == .budgetLimited ? content : nil
            completion(LocalReadDelivery(token: operation.token, outcome: outcome,
                receipt: receipt, content: deliveredContent))
        }
    }

    private static func reason(_ error: Error) -> EpisodeState {
        switch error as? EpisodeBudgetError {
        case .exhausted: return .budgetExceeded
        case .deadlineExceeded: return .deadlineExceeded
        case .inactive: return .cancelled
        default: return .failed
        }
    }
}
