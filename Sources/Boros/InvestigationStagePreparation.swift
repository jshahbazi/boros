import Foundation

enum InvestigationStageKind: String, Codable {
    case planner, extraction

    var outputReserve: Int { self == .planner ? 1024 : 2048 }
}

/// Private stages have their own exact count and source binding. Their answer
/// work is accounted on the accepted lease without creating a visible turn.
struct PreparedInvestigationStage {
    let stage: InvestigationStageKind
    let settings: GenerationSettings
    let body: Data
    let receipt: EndpointAdmissionReceipt
    let sourceBindingDigest: String
    let work: EpisodeWorkRecord
}

/// Admits an already selected private stage. The caller owns original-source
/// validation and its private descriptor journal. No stage can reuse another
/// stage's count proof, extend the accepted allowance, or silently lose sources.
final class InvestigationStagePreparationOperation {
    private let stage: InvestigationStageKind
    private let messages: [ContextMessage]
    private let assignments: [ProviderMessageComponent]
    private let sourceBindingData: Data
    private let baseSettings: GenerationSettings
    private let lease: EpisodeLease
    private let queue = DispatchQueue(label: "Boros.investigation.admission", qos: .userInitiated)
    private let lock = NSLock()
    private var session: ProviderComponentSession?
    private var completion: ((Result<PreparedInvestigationStage, Error>) -> Void)?
    private var started = false
    private var cancelled = false
    private var finished = false
    private var handedOff = false
    private var preparedWork: EpisodeWorkRecord?
    private var settings: GenerationSettings?
    private var requestBody: Data?
    private var policyDigest = ""
    private var sourceDigest = ""
    private var policy = ContextComponentPolicy.selectedQwen

    init(stage: InvestigationStageKind, messages: [ContextMessage], assignments: [ProviderMessageComponent],
         sourceBindingData: Data, settings: GenerationSettings, episodeLease: EpisodeLease,
         completion: @escaping (Result<PreparedInvestigationStage, Error>) -> Void) {
        self.stage = stage; self.messages = messages; self.assignments = assignments
        self.sourceBindingData = sourceBindingData; baseSettings = settings; lease = episodeLease
        self.completion = completion
    }

    /// Synchronous structural checks perform no source reads or provider work.
    static func validate(messages: [ContextMessage], assignments: [ProviderMessageComponent],
                         sourceBindingData: Data, policy: ContextComponentPolicy) throws {
        _ = try policy.validated()
        guard messages.count >= 2, messages.count == assignments.count,
              messages.first?.role == "system", messages.last?.role == "user",
              assignments.first == .mandatory, assignments.last == .mandatory,
              messages.allSatisfy({ ["system", "user", "assistant"].contains($0.role) }),
              !messages.dropFirst().contains(where: { $0.role == "system" }),
              !sourceBindingData.isEmpty, sourceBindingData.count <= 4 * 1_048_576,
              let descriptor = try JSONSerialization.jsonObject(with: sourceBindingData) as? [String: Any],
              !descriptor.isEmpty else { throw ProviderAdmissionError.invalidRequest }
        let optional = Array(assignments.dropFirst().dropLast())
        guard optional.allSatisfy({ $0 == .recent || $0 == .evidence }),
              optional.filter({ $0 == .evidence }).count <= 1,
              !optional.contains(.evidence) || optional.last == .evidence,
              optional.filter({ $0 == .recent }).count <= policy.recentCandidates,
              zip(messages, assignments).allSatisfy({ message, component in
                  component != .evidence || message.role == "user"
              }) else { throw ProviderAdmissionError.invalidRequest }
        let recent = zip(messages, assignments).filter { $0.1 == .recent }.map { $0.0 }
        let evidence = zip(messages, assignments).filter { $0.1 == .evidence }.map { $0.0 }
        guard try ContextAssembler.serializedMessages(messages).count <= policy.maximumMessageBytes,
              try ContextAssembler.serializedMessages(recent).count <= policy.recentBytes,
              try ContextAssembler.serializedMessages(evidence).count <= policy.evidenceBytes else {
            throw ProviderAdmissionError.contextOverflow
        }
    }

    func start() {
        queue.async { [self] in
            lock.lock()
            guard !started else { lock.unlock(); return }
            started = true; lock.unlock()
            do {
                try checkActive()
                let episode = try lease.checkActive()
                guard case .chat = episode.origin, let frozenPolicy = episode.limits.componentPolicy,
                      baseSettings.profile == .customLocal,
                      baseSettings.endpointModel == Qwen38TextAdapter.modelID else {
                    throw ProviderAdmissionError.unverifiedAdapter
                }
                policy = try frozenPolicy.validated()
                try Self.validate(messages: messages, assignments: assignments,
                    sourceBindingData: sourceBindingData, policy: policy)
                policyDigest = EndpointRequest.digest(try policy.canonicalData())
                sourceDigest = EndpointRequest.digest(sourceBindingData)
                var ready = baseSettings
                ready.thinkingEnabled = false; ready.maximumOutput = stage.outputReserve
                ready.messagesOverride = messages.map { ["role": $0.role, "content": $0.content] }
                ready.episodeLease = lease; ready.preparedEndpointBody = nil; ready.endpointAdmission = nil
                ready.preparedNativeBody = nil; ready.preparedAnswerWork = nil; ready.preparedContextComponents = nil
                settings = ready
                requestBody = try EndpointRequest.build(prompt: "", settings: ready, conversation: Conversation())
                var mandatory = ready
                mandatory.messagesOverride = zip(messages, assignments).filter { $0.1 == .mandatory }
                    .map { ["role": $0.0.role, "content": $0.0.content] }
                let body = try EndpointRequest.build(prompt: "", settings: mandatory, conversation: Conversation())
                let opened = ProviderAdmission.beginComponentSession(mandatoryBody: body,
                    address: ready.endpointURL, apiKey: ready.endpointAPIKey,
                    contextLimit: ready.endpointContextLimit, safetyTokens: ready.endpointSafetyTokens,
                    episodeLease: lease) { [weak self] outcome in
                        self?.queue.async { [weak self] in
                            guard let self else { return }
                            do {
                                try self.checkActive()
                                switch outcome {
                                case .success: self.countRecent()
                                case .failure(let error): self.finish(.failure(error))
                                }
                            } catch { self.finish(.failure(error)) }
                        }
                    }
                lock.lock(); session = opened; let stopped = cancelled; lock.unlock()
                if stopped { opened.cancel() }
            } catch { finish(.failure(error)) }
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let current = session; lock.unlock()
        lease.interruptLocally(reason: .cancelled)
        current?.cancel()
        queue.async { [self] in finish(.failure(ProviderAdmissionError.cancelled)) }
    }

    private func checkActive() throws {
        lock.lock(); let stopped = cancelled || finished; lock.unlock()
        guard !stopped else { throw ProviderAdmissionError.cancelled }
        _ = try lease.checkActive()
    }

    private func countRecent() {
        do {
            try checkActive()
            guard let session, let body = requestBody else { throw ProviderAdmissionError.unavailable }
            session.countComponent(requestBody: body, assignments: assignments, component: .recent) { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.checkActive()
                        switch result {
                        case .failure(let error): self.finish(.failure(error))
                        case .success(let recent):
                            guard recent.tokens <= self.policy.recentTokens else { throw ProviderAdmissionError.contextOverflow }
                            self.countEvidence(recent: recent)
                        }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func countEvidence(recent: ProviderComponentCountReceipt) {
        do {
            try checkActive()
            guard let session, let body = requestBody else { throw ProviderAdmissionError.unavailable }
            session.countComponent(requestBody: body, assignments: assignments, component: .evidence) { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.checkActive()
                        switch result {
                        case .failure(let error): self.finish(.failure(error))
                        case .success(let evidence):
                            guard evidence.tokens <= self.policy.evidenceTokens else { throw ProviderAdmissionError.contextOverflow }
                            self.admit(recent: recent, evidence: evidence)
                        }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func admit(recent: ProviderComponentCountReceipt, evidence: ProviderComponentCountReceipt) {
        do {
            try checkActive()
            guard let session, let body = requestBody else { throw ProviderAdmissionError.unavailable }
            session.admit(requestBody: body, assignments: assignments, sourceSnapshotDigest: sourceDigest,
                policyDigest: policyDigest, recentReceipt: recent, evidenceReceipt: evidence) { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        do {
                            try self.checkActive()
                            switch result {
                            case .failure(let error): self.finish(.failure(error))
                            case .success(let receipt):
                                guard var ready = self.settings else { throw ProviderAdmissionError.unavailable }
                                let binding = ContextComponentDispatchBinding(assignments: self.assignments,
                                    sourceSnapshotDigest: self.sourceDigest, policyDigest: self.policyDigest)
                                ready.preparedEndpointBody = body; ready.endpointAdmission = receipt
                                ready.preparedContextComponents = binding
                                guard binding.accepts(receipt: receipt, body: body, settings: ready) else {
                                    throw ProviderAdmissionError.countMismatch
                                }
                                let work = try self.lease.prepare(kind: .answer,
                                    resources: EpisodeResources(inputTokens: receipt.promptTokens,
                                        outputTokens: receipt.outputReserve, modelCalls: 1, httpAttempts: 1),
                                    adapterIdentity: receipt.answerAdapterIdentity, snapshot: body)
                                self.preparedWork = work; ready.preparedAnswerWork = work
                                self.finish(.success(PreparedInvestigationStage(stage: self.stage, settings: ready,
                                    body: body, receipt: receipt, sourceBindingDigest: self.sourceDigest, work: work)))
                            }
                        } catch { self.finish(.failure(error)) }
                    }
                }
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<PreparedInvestigationStage, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let callback = completion; completion = nil
        let current = session; session = nil
        lock.unlock()
        current?.close()
        DispatchQueue.main.async { [self] in
            guard let callback else { return }
            var delivered = result
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { delivered = .failure(ProviderAdmissionError.cancelled) }
            else if case .success(let value) = result {
                do {
                    _ = try lease.checkActive()
                    guard value.settings.preparedContextComponents?.accepts(receipt: value.receipt,
                        body: value.body, settings: value.settings) == true,
                        value.settings.preparedAnswerWork?.id == value.work.id,
                        value.work.request.snapshot == value.body,
                        value.sourceBindingDigest == EndpointRequest.digest(sourceBindingData) else {
                        throw ProviderAdmissionError.countMismatch
                    }
                } catch { delivered = .failure(error) }
            }
            if case .success = delivered {
                lock.lock(); handedOff = true; lock.unlock()
            } else { releaseUnhandedWork() }
            callback(delivered)
        }
    }

    private func releaseUnhandedWork() {
        lock.lock(); let owned = !handedOff; let work = preparedWork; lock.unlock()
        if owned, let work { _ = try? lease.settle(work, outcome: .cancelledBeforeDispatch) }
    }
}
