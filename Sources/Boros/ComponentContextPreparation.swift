import Foundation

/// Host-owned provenance and frozen digests required again at transport handoff.
/// This contains no source text; the exact request is journaled independently.
struct ContextComponentDispatchBinding {
    let assignments: [ProviderMessageComponent]
    let sourceSnapshotDigest: String
    let policyDigest: String

    func accepts(receipt: EndpointAdmissionReceipt, body: Data, settings: GenerationSettings) -> Bool {
        guard let lease = settings.episodeLease, let proof = receipt.componentProof,
              let policy = try? lease.checkActive().limits.componentPolicy?.validated(),
              let policyBytes = try? policy.canonicalData(),
              policyDigest == EndpointRequest.digest(policyBytes) else { return false }
        return proof.accepts(body: body, assignments: assignments, sourceSnapshotDigest: sourceSnapshotDigest,
            policyDigest: policyDigest, episodeLease: lease, address: settings.endpointURL)
    }
}

struct PreparedComponentContext {
    let snapshot: ContextSnapshot
    let settings: GenerationSettings
    let body: Data
    let receipt: EndpointAdmissionReceipt
}

/// One cancellable selected-model session counts mandatory content before
/// optional reads, selects recent history before evidence, and never renews the
/// original allowance. Provider callbacks are serialized on this worker queue.
final class ComponentContextPreparationOperation {
    private let store: MemoryStore
    private let conversationID: String
    private let projectID: String
    private let humanEventID: String
    private let prompt: String
    private let settings: GenerationSettings
    private let conversation: Conversation
    private let semanticIndex: SemanticIndex?
    private let retrievalStrategy: ContextRetrievalStrategy
    private let lease: EpisodeLease
    private let queue = DispatchQueue(label: "Boros.context.components", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var session: ProviderComponentSession?
    private var completion: ((Result<PreparedComponentContext, Error>) -> Void)?
    private var policy = ContextComponentPolicy.selectedQwen
    private var policyDigest = ""

    init(store: MemoryStore, conversationID: String, projectID: String, humanEventID: String,
         prompt: String, settings: GenerationSettings, conversation: Conversation, semanticIndex: SemanticIndex?,
         retrievalStrategy: ContextRetrievalStrategy = .hybrid,
         episodeLease: EpisodeLease, completion: @escaping (Result<PreparedComponentContext, Error>) -> Void) {
        self.store = store; self.conversationID = conversationID; self.projectID = projectID
        self.humanEventID = humanEventID; self.prompt = prompt; self.settings = settings
        self.conversation = conversation; self.semanticIndex = semanticIndex; self.lease = episodeLease
        self.retrievalStrategy = retrievalStrategy
        self.completion = completion
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.checkActive()
                let episode = try self.lease.checkActive(projectID: self.projectID)
                guard case .chat(let acceptedConversation, _, let acceptedHuman) = episode.origin,
                      episodeIdentifierEqual(acceptedConversation, self.conversationID),
                      episodeIdentifierEqual(acceptedHuman, self.humanEventID) else {
                    throw EpisodeBudgetError.scopeMismatch
                }
                guard self.settings.profile == .customLocal, let frozenPolicy = episode.limits.componentPolicy else {
                    throw ProviderAdmissionError.unverifiedAdapter
                }
                self.policy = try frozenPolicy.validated()
                self.policyDigest = EndpointRequest.digest(try self.policy.canonicalData())
                var mandatory = self.settings
                mandatory.messagesOverride = ContextAssembler.mandatoryMessages(prompt: self.prompt, system: self.settings.system)
                    .map { ["role": $0.role, "content": $0.content] }
                let body = try EndpointRequest.build(prompt: self.prompt, settings: mandatory, conversation: self.conversation)
                let session = ProviderAdmission.beginComponentSession(mandatoryBody: body,
                    address: self.settings.endpointURL, apiKey: self.settings.endpointAPIKey,
                    contextLimit: self.settings.endpointContextLimit, safetyTokens: self.settings.endpointSafetyTokens,
                    episodeLease: self.lease) { [weak self] outcome in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        switch outcome {
                        case .success:
                            do {
                                try self.checkActive()
                                let recent = try ContextAssembler.prepareRecent(store: self.store,
                                    conversationID: self.conversationID, projectID: self.projectID,
                                    prompt: self.prompt, system: self.settings.system, excludingEventID: self.humanEventID,
                                    budgetBytes: self.policy.maximumMessageBytes, maximumRecentBytes: self.policy.recentBytes,
                                    maximumRecentRows: self.policy.recentCandidates, episodeLease: self.lease)
                                self.countRecent(recent, prepareEvidence: true)
                            } catch { self.finish(.failure(error)) }
                        case .failure(let error): self.finish(.failure(error))
                        }
                    }
                }
                self.lock.lock(); self.session = session; let cancelled = self.cancelled; self.lock.unlock()
                if cancelled { session.cancel() }
            } catch { self.finish(.failure(error)) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let current = session; lock.unlock()
        lease.interruptLocally(reason: .cancelled)
        current?.cancel()
        queue.async { [weak self] in self?.finish(.failure(ProviderAdmissionError.cancelled)) }
    }

    private func checkActive() throws {
        lock.lock(); let stopped = cancelled || finished; lock.unlock()
        guard !stopped else { throw ProviderAdmissionError.cancelled }
        _ = try lease.checkActive(projectID: projectID)
    }

    private func body(_ snapshot: ContextSnapshot) throws -> Data {
        var candidate = settings
        candidate.messagesOverride = snapshot.messages.map { ["role": $0.role, "content": $0.content] }
        return try EndpointRequest.build(prompt: prompt, settings: candidate, conversation: conversation)
    }

    private func assignments(_ snapshot: ContextSnapshot) throws -> [ProviderMessageComponent] {
        try snapshot.componentAssignments().map {
            switch $0 {
            case .mandatory: return .mandatory
            case .recent: return .recent
            case .historicalEvidence: return .evidence
            }
        }
    }

    private func countRecent(_ snapshot: ContextSnapshot, prepareEvidence: Bool) {
        do {
            try checkActive()
            guard let session else { throw ProviderAdmissionError.unavailable }
            let bytes = try body(snapshot), assignment = try assignments(snapshot)
            session.countComponent(requestBody: bytes, assignments: assignment, component: .recent) { [weak self] outcome in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.checkActive()
                        switch outcome {
                        case .failure(let error): self.finish(.failure(error))
                        case .success(let receipt):
                            if receipt.tokens > self.policy.recentTokens {
                                guard let reduced = try snapshot.reducedRecentForComponentCap() else {
                                    throw ProviderAdmissionError.countMismatch
                                }
                                self.countRecent(reduced, prepareEvidence: prepareEvidence)
                            } else if prepareEvidence {
                                let candidate = try ChatContextPreparation.prepareEvidence(recent: snapshot,
                                    store: self.store, conversationID: self.conversationID, projectID: self.projectID,
                                    prompt: self.prompt, excludingEventID: self.humanEventID,
                                    semanticIndex: self.semanticIndex, retrievalStrategy: self.retrievalStrategy,
                                    episodeLease: self.lease)
                                self.countEvidence(candidate, recentReceipt: receipt)
                            } else { self.countEvidence(snapshot, recentReceipt: receipt) }
                        }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func countEvidence(_ snapshot: ContextSnapshot, recentReceipt: ProviderComponentCountReceipt) {
        do {
            try checkActive()
            guard let session else { throw ProviderAdmissionError.unavailable }
            let bytes = try body(snapshot), assignment = try assignments(snapshot)
            session.countComponent(requestBody: bytes, assignments: assignment, component: .evidence) { [weak self] outcome in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.checkActive()
                        switch outcome {
                        case .failure(let error): self.finish(.failure(error))
                        case .success(let receipt):
                            if receipt.tokens > self.policy.evidenceTokens {
                                guard let reduced = try snapshot.reducedEvidenceForComponentCap() else {
                                    throw ProviderAdmissionError.countMismatch
                                }
                                self.countEvidence(reduced, recentReceipt: recentReceipt)
                            } else { self.admit(snapshot, recentReceipt: recentReceipt, evidenceReceipt: receipt) }
                        }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func admit(_ snapshot: ContextSnapshot, recentReceipt: ProviderComponentCountReceipt,
                       evidenceReceipt: ProviderComponentCountReceipt) {
        do {
            try checkActive()
            guard let session else { throw ProviderAdmissionError.unavailable }
            let bytes = try body(snapshot), assignment = try assignments(snapshot)
            let sourceDigest = try snapshot.selectionDigest()
            session.admit(requestBody: bytes, assignments: assignment, sourceSnapshotDigest: sourceDigest,
                policyDigest: policyDigest, recentReceipt: recentReceipt, evidenceReceipt: evidenceReceipt) { [weak self] outcome in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.checkActive()
                        switch outcome {
                        case .failure(let error):
                            if error == .contextOverflow, let reduced = try snapshot.reducedForTokenAdmission() {
                                self.countRecent(reduced, prepareEvidence: false)
                            } else { self.finish(.failure(error)) }
                        case .success(let receipt):
                            let binding = ContextComponentDispatchBinding(assignments: assignment,
                                sourceSnapshotDigest: sourceDigest, policyDigest: self.policyDigest)
                            var ready = self.settings
                            ready.messagesOverride = snapshot.messages.map { ["role": $0.role, "content": $0.content] }
                            ready.preparedEndpointBody = bytes; ready.endpointAdmission = receipt
                            ready.preparedContextComponents = binding
                            guard binding.accepts(receipt: receipt, body: bytes, settings: ready) else {
                                throw ProviderAdmissionError.countMismatch
                            }
                            var audited = snapshot
                            audited.componentAuditJSON = try receipt.componentProof.map { try JSONEncoder().encode($0) }
                            // Keep the full bounded provenance document in the
                            // existing authoritative snapshot journal. The
                            // small delivery audit links it by work ID.
                            let resources = EpisodeResources(memoryOperations: 1,
                                metadataRows: snapshot.recentSources.count + snapshot.evidence.count + 8)
                            let work = try self.lease.prepare(kind: .sourceRead, resources: resources,
                                adapterIdentity: snapshot.selectionBinding?.version ?? ContextSourceFraming.currentSelectionVersion,
                                snapshot: snapshot.selectionEvidence())
                            let submitted = try self.lease.dispatch(work, start: {})
                            _ = try self.lease.settle(submitted, outcome: .completed, observed: resources)
                            audited.selectionWorkID = work.id
                            self.finish(.success(PreparedComponentContext(snapshot: audited, settings: ready,
                                body: bytes, receipt: receipt)))
                        }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<PreparedComponentContext, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let callback = completion; completion = nil
        let session = self.session; self.session = nil
        lock.unlock()
        session?.close()
        DispatchQueue.main.async { [self] in
            guard let callback else { return }
            var delivered = result
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { delivered = .failure(ProviderAdmissionError.cancelled) }
            else if case .success(let value) = result {
                do {
                    _ = try lease.checkActive(projectID: projectID)
                    guard value.settings.preparedContextComponents?.accepts(receipt: value.receipt,
                        body: value.body, settings: value.settings) == true else {
                        throw ProviderAdmissionError.countMismatch
                    }
                } catch { delivered = .failure(error) }
            }
            callback(delivered)
        }
    }

    static func failureCode(_ error: Error) -> String {
        if let error = error as? ProviderAdmissionError { return error.failureCode }
        if let error = error as? EpisodeBudgetError { return error.failureCode }
        if case ContextError.mandatoryOverflow = error { return "context_full" }
        return "context_preparation_failed"
    }
}
