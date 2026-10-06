import Foundation

/// Callbacks must be serialized in stream order. Implementations settle their
/// transport work on the supplied original lease; the host owns capture.
/// Completion of owned work signals readiness with isRunning false; a busy
/// refusal does not acquire another attempt's runner. Later provider
/// evidence may still refine the same durable work without permitting replay.
protocol AnswerAttemptRunning: AnyObject {
    var isRunning: Bool { get }
    func start(prompt: String, settings: GenerationSettings, conversation: Conversation,
               onText: @escaping (String) -> Void, onComplete: @escaping (GenerationResult) -> Void)
    func cancel()
}

extension ModelRunner: AnswerAttemptRunning {}

struct AnswerAttemptIdentifiers: Codable, Equatable {
    let turnID: String
    let humanEventID: String
    let assistantEventID: String
    let invocationID: String
    let episodeID: String

    init() {
        turnID = UUID().uuidString; humanEventID = UUID().uuidString
        assistantEventID = UUID().uuidString; invocationID = UUID().uuidString
        episodeID = UUID().uuidString
    }
}

enum AnswerAttemptStage { case preparing, answering }

/// Only provenance and count metadata cross the host boundary here.
struct AnswerAttemptPreparation {
    let requestDigest: String
    let sourceSelectionDigest: String
    let sourceSelectionWorkID: String?
    let answerWorkID: String
    let admission: EndpointAdmissionReceipt
    let admissionAuditJSON: Data
    let contextAudit: Data
    let retrievalNotice: String?
}

struct AnswerAttemptTiming: Codable {
    let preparationMilliseconds: Double?
    let firstDurableVisibleDeltaMilliseconds: Double?
    let fullCompletionMilliseconds: Double?
    let providerCompletionMilliseconds: Double?
    let finalizationMilliseconds: Double?
}

/// Final text is deliberately a separate transient completion argument. This
/// result has no task-score input and contains no prompt, body or source text.
/// Its receipt is authoritative as of host completion; late usage evidence can
/// subsequently refine that original receipt without starting another attempt.
struct AnswerAttemptCompletion {
    let identifiers: AnswerAttemptIdentifiers
    let generation: GenerationResult
    let episode: EpisodeReceipt?
    let preparation: AnswerAttemptPreparation?
    let invocationStarted: Bool
    let captureStatus: CaptureStatus?
    let terminalReason: InvocationTerminalReason?
    let captureHealthy: Bool
    let accountingHealthy: Bool
    let responseBytes: Int
    let responseDigest: String
    let timing: AnswerAttemptTiming
}

/// Shared selected-Qwen host lifecycle. Acceptance and start are separate so a
/// GUI can save its draft/preferences and install presentation state first.
/// All mutable lifecycle state and callbacks are serialized on the main queue.
/// Stop can fence the original lease immediately from any thread.
final class AnswerAttemptCoordinator {
    private static let mainQueueKey: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>(); DispatchQueue.main.setSpecific(key: key, value: true); return key
    }()
    static var isOnMainQueue: Bool {
        let key = mainQueueKey
        return Thread.isMainThread || DispatchQueue.getSpecific(key: key) == true
    }
    let identifiers = AnswerAttemptIdentifiers()
    let lease: EpisodeLease
    private let store: MemoryStore
    private let conversationID: String
    private let projectID: String
    private let prompt: String
    private let lexicalQueryUTF8Range: Range<Int>?
    private let semanticQueryUTF8Range: Range<Int>?
    private let settings: GenerationSettings
    private let conversation: Conversation
    private let semanticIndex: SemanticIndex?
    private let retrievalStrategy: ContextRetrievalStrategy
    private let limits: EpisodeLimits
    private let clock: EpisodeClockSource
    private let runner: AnswerAttemptRunning
    private var onText: ((String) -> Void)?
    private var onStage: ((AnswerAttemptStage, AnswerAttemptPreparation?) -> Void)?
    private var onComplete: ((AnswerAttemptCompletion, String) -> Void)?
    private enum State { case idle, accepted, preparing, answering, finishing, finished }
    private var state: State = .idle
    private let interruptionLock = NSLock()
    private var interruption: (EpisodeState, String?)?
    private var operation: ComponentContextPreparationOperation?
    private var timer: DispatchSourceTimer?
    private var lifetime: AnswerAttemptCoordinator?
    private var startedClock: EpisodeClockSnapshot?
    private var preparationMilliseconds: Double?
    private var firstVisibleMilliseconds: Double?
    private var providerCompletionMilliseconds: Double?
    private var preparation: AnswerAttemptPreparation?
    private var invocationStarted = false
    private var chunkSequence = 0
    private var captureFailed = false
    private var response = ""
    private var runnerStarted = false
    private var runnerCompletion: GenerationResult?
    private var closingResult: GenerationResult?
    private var closingReceipt: EpisodeReceipt?
    private var closingAccountingHealthy = true

    init(store: MemoryStore, conversationID: String, projectID: String, prompt: String,
         settings: GenerationSettings, conversation: Conversation = Conversation(), semanticIndex: SemanticIndex? = nil,
         retrievalStrategy: ContextRetrievalStrategy = .hybrid, limits: EpisodeLimits = EpisodeLimits(),
         lexicalQueryUTF8Range: Range<Int>? = nil,
         semanticQueryUTF8Range: Range<Int>? = nil,
         clock: EpisodeClockSource = SystemEpisodeClock(), runner: AnswerAttemptRunning = ModelRunner(),
         onStage: ((AnswerAttemptStage, AnswerAttemptPreparation?) -> Void)? = nil,
         onText: @escaping (String) -> Void, onComplete: @escaping (AnswerAttemptCompletion, String) -> Void) {
        self.store = store; self.conversationID = conversationID; self.projectID = projectID
        self.prompt = prompt; self.conversation = conversation; self.semanticIndex = semanticIndex
        self.lexicalQueryUTF8Range = lexicalQueryUTF8Range
        self.semanticQueryUTF8Range = semanticQueryUTF8Range
        self.retrievalStrategy = retrievalStrategy; self.clock = clock; self.runner = runner
        self.onStage = onStage; self.onText = onText; self.onComplete = onComplete
        var frozenLimits = limits
        if frozenLimits.componentPolicy == nil { frozenLimits.componentPolicy = .selectedQwen }
        self.limits = frozenLimits
        lease = EpisodeLease(ledger: store, episodeID: identifiers.episodeID, clock: clock)
        var frozen = settings
        frozen.messagesOverride = nil; frozen.preparedEndpointBody = nil; frozen.endpointAdmission = nil
        frozen.preparedNativeBody = nil; frozen.preparedAnswerWork = nil; frozen.preparedContextComponents = nil
        frozen.episodeLease = lease
        self.settings = frozen
    }

    @discardableResult
    func accept() throws -> EpisodeReceipt {
        guard Self.isOnMainQueue, state == .idle, currentInterruption() == nil else { throw EpisodeBudgetError.invalid }
        guard !runner.isRunning else { throw EpisodeBudgetError.inactive }
        guard settings.profile == .customLocal else { throw ProviderAdmissionError.unverifiedAdapter }
        guard episodeIdentifierEqual(try store.conversationProjectID(conversationID: conversationID), projectID) else {
            throw EpisodeBudgetError.scopeMismatch
        }
        // Validate the endpoint/envelope before accepting content. Optional
        // history is selected only inside the metered preparation operation.
        var mandatory = settings
        mandatory.messagesOverride = ContextAssembler.mandatoryMessages(prompt: prompt, system: settings.system)
            .map { ["role": $0.role, "content": $0.content] }
        _ = try EndpointRequest.build(prompt: prompt, settings: mandatory, conversation: conversation)
        let sampled = try clock.now()
        let receipt = try store.acceptRequestAndBeginEpisode(conversationID: conversationID,
            turnID: identifiers.turnID, humanEventID: identifiers.humanEventID, episodeID: identifiers.episodeID,
            text: prompt, limits: limits, clock: sampled)
        startedClock = sampled; state = .accepted; lifetime = self
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkDeadline() }
        self.timer = timer; timer.resume()
        // A concurrent Stop may have won while atomic acceptance was running.
        if let stopped = currentInterruption() {
            DispatchQueue.main.async { [self] in finish(interruptionResult(stopped), forcedReason: stopped.0) }
        }
        return receipt
    }

    func start() throws {
        guard Self.isOnMainQueue, state == .accepted else { throw EpisodeBudgetError.inactive }
        if let stopped = currentInterruption() {
            finish(interruptionResult(stopped), forcedReason: stopped.0); return
        }
        do {
            _ = try lease.checkActive(projectID: projectID)
            state = .preparing; onStage?(.preparing, nil)
            guard state == .preparing else { return }
            let operation = ComponentContextPreparationOperation(store: store, conversationID: conversationID,
                projectID: projectID, humanEventID: identifiers.humanEventID, prompt: prompt,
                settings: settings, conversation: conversation, semanticIndex: semanticIndex,
                retrievalStrategy: retrievalStrategy, lexicalQueryUTF8Range: lexicalQueryUTF8Range,
                semanticQueryUTF8Range: semanticQueryUTF8Range,
                episodeLease: lease) { [self] outcome in
                    prepared(outcome)
                }
            self.operation = operation; operation.start()
        } catch { finish(failureResult(error)) }
    }

    func cancel() { terminate(reason: .cancelled) }

    /// Host failures and deadline fences share the same conservative closure.
    /// An external caller cannot turn incomplete transport into completion.
    func terminate(reason: EpisodeState, failure: String? = nil) {
        guard [.cancelled, .failed, .deadlineExceeded, .budgetExceeded, .interrupted].contains(reason) else { return }
        interruptionLock.lock()
        if interruption == nil { interruption = (reason, Self.safeFailure(failure)) }
        let stopped = interruption!
        interruptionLock.unlock()
        lease.interruptLocally(reason: stopped.0)
        onMain { [self] in
            guard state != .idle, state != .finished, state != .finishing else { return }
            finish(interruptionResult(stopped), forcedReason: stopped.0)
        }
    }

    private func currentInterruption() -> (EpisodeState, String?)? {
        interruptionLock.lock(); defer { interruptionLock.unlock() }; return interruption
    }

    private func prepared(_ outcome: Result<PreparedComponentContext, Error>) {
        guard state == .preparing else { return }
        operation = nil
        switch outcome {
        case .failure(let error): finish(failureResult(error))
        case .success(let value):
            do {
                _ = try lease.checkActive(projectID: projectID)
                guard value.settings.episodeLease === lease,
                      value.settings.preparedContextComponents?.accepts(receipt: value.receipt,
                        body: value.body, settings: value.settings) == true,
                      try value.snapshot.selectionDigest() == value.settings.preparedContextComponents?.sourceSnapshotDigest else {
                    throw ProviderAdmissionError.countMismatch
                }
                let work = try lease.prepare(kind: .answer,
                    resources: EpisodeResources(inputTokens: value.receipt.promptTokens,
                        outputTokens: settings.maximumOutput, modelCalls: 1, httpAttempts: 1),
                    adapterIdentity: value.receipt.answerAdapterIdentity, snapshot: value.body)
                let audit = try value.snapshot.deliveryAudit()
                let baseAdmission = try JSONEncoder().encode(AdmissionAudit(version: 2, receipt: value.receipt,
                    attempts: value.receipt.accounting.map { [$0] } ?? [], nativeConfiguration: nil, context: audit))
                let inputProof = try store.prepareAnswerInputProof(lease: lease, requestBody: value.body,
                    providerIdentity: value.receipt.endpoint, admissionJSON: baseAdmission,
                    answerRequest: work.request, hostInstructions: settings.system)
                let admission = try JSONEncoder().encode(AdmissionAudit(version: 3, receipt: value.receipt,
                    attempts: value.receipt.accounting.map { [$0] } ?? [], nativeConfiguration: nil, context: audit,
                    inputProofWorkID: inputProof.operationID, inputProofSHA256: inputProof.digest))
                _ = try store.beginInvocation(invocationID: identifiers.invocationID, conversationID: conversationID,
                    turnID: identifiers.turnID, humanEventID: identifiers.humanEventID,
                    assistantEventID: identifiers.assistantEventID, providerIdentity: value.receipt.endpoint,
                    requestBody: value.body, admissionJSON: admission, episodeID: identifiers.episodeID, episodeWorkID: work.id)
                invocationStarted = true
                preparation = AnswerAttemptPreparation(requestDigest: EndpointRequest.digest(value.body),
                    sourceSelectionDigest: try value.snapshot.selectionDigest(),
                    sourceSelectionWorkID: value.snapshot.selectionWorkID, answerWorkID: work.id,
                    admission: value.receipt, admissionAuditJSON: admission,
                    contextAudit: audit, retrievalNotice: value.snapshot.retrievalNotice)
                preparationMilliseconds = elapsedMilliseconds()
                var ready = value.settings; ready.preparedAnswerWork = work
                state = .answering; onStage?(.answering, preparation)
                guard state == .answering else { return }
                _ = try lease.checkActive(projectID: projectID)
                guard !runner.isRunning else {
                    finish(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: "busy", stopped: false)); return
                }
                runnerStarted = true
                runner.start(prompt: prompt, settings: ready, conversation: conversation, onText: { [self] text in
                    onMain { [self] in receive(text) }
                }, onComplete: { [self] result in
                    onMain { [self] in transportCompleted(Self.safeResult(result)) }
                })
            } catch { finish(failureResult(error)) }
        }
    }

    private struct AdmissionAudit: Codable {
        let version: Int
        let receipt: EndpointAdmissionReceipt
        let attempts: [ProviderAdmissionAccounting]
        let nativeConfiguration: Data?
        let context: Data
        var inputProofWorkID: String? = nil
        var inputProofSHA256: String? = nil
    }

    private func receive(_ text: String) {
        guard state == .answering, !text.isEmpty else { return }
        do {
            _ = try lease.checkActive(projectID: projectID)
            _ = try store.appendInvocationChunk(invocationID: identifiers.invocationID, sequence: chunkSequence, text: text)
            chunkSequence += 1; response += text
            if firstVisibleMilliseconds == nil { firstVisibleMilliseconds = elapsedMilliseconds() }
            // Reentrant Stop is allowed; the next callback sees finished state.
            onText?(text)
        } catch {
            if !(error is EpisodeBudgetError) { captureFailed = true }
            finish(failureResult(error, capture: captureFailed))
        }
    }

    private func checkDeadline() {
        guard state != .idle, state != .finished, state != .finishing else { return }
        do { _ = try lease.checkActive(projectID: projectID) }
        catch { finish(failureResult(error)) }
    }

    private func finish(_ result: GenerationResult, forcedReason: EpisodeState? = nil) {
        guard state != .idle, state != .finished, state != .finishing else { return }
        state = .finishing; timer?.cancel(); timer = nil
        var resolved = Self.safeResult(result)
        if resolved.failure == nil, !resolved.stopped, response.isEmpty {
            resolved = GenerationResult(elapsed: resolved.elapsed, tokensPerSecond: resolved.tokensPerSecond,
                failure: "empty_result", stopped: false,
                providerUsage: resolved.providerUsage, providerAdmission: resolved.providerAdmission)
        }
        let terminal = forcedReason ?? (resolved.stopped ? .cancelled
            : resolved.failure == "episode_deadline_exceeded" ? .deadlineExceeded
            : resolved.failure == "episode_budget_exceeded" ? .budgetExceeded
            : resolved.failure != nil || captureFailed ? .failed : .completed)
        closingResult = resolved
        lease.interruptLocally(reason: terminal)
        operation?.cancel(); operation = nil
        // Close the durable allowance immediately. Host readiness still waits
        // for transport drain, while uncertain dispatched work retains bounds.
        do { closingReceipt = try lease.finish(reason: terminal) }
        catch { closingAccountingHealthy = false }
        if runnerStarted, runnerCompletion == nil {
            // Before our handoff, ModelRunner may be returning an async busy
            // refusal for another job. The original lease fence suppresses
            // our future dispatch; cancel only proven owned transport work.
            if !answerWasNeverDispatched() { runner.cancel() }
            return // Even synchronous cancel completion is handled below.
        }
        completeAfterDrain()
    }

    private func transportCompleted(_ result: GenerationResult) {
        guard state == .answering || state == .finishing, runnerCompletion == nil else { return }
        providerCompletionMilliseconds = elapsedMilliseconds()
        // ModelRunner can lose a concurrent busy race after the preflight
        // check. Its refusal never dispatched our prepared answer work and
        // must not make us wait for or cancel the unrelated current job.
        if result.failure == "busy", answerWasNeverDispatched() {
            runnerStarted = false
        }
        runnerCompletion = result
        if state == .answering { finish(result) }
        else { completeAfterDrain() }
    }

    private func answerWasNeverDispatched() -> Bool {
        guard let preparation,
              let work = try? store.episodeWork(episodeID: identifiers.episodeID, operationID: preparation.answerWorkID),
              work.charged == .zero else { return false }
        return work.state == .prepared || (work.state == .cancelledBeforeDispatch && work.held == .zero)
    }

    private func completeAfterDrain() {
        guard state == .finishing, let original = closingResult,
              !runnerStarted || (runnerCompletion != nil && !runner.isRunning) else { return }
        let finalizationStarted = elapsedMilliseconds()
        state = .finished
        let usage = runnerCompletion?.providerUsage ?? original.providerUsage
        var resolved = GenerationResult(elapsed: runnerCompletion?.elapsed ?? original.elapsed,
            tokensPerSecond: runnerCompletion?.tokensPerSecond ?? original.tokensPerSecond,
            failure: original.failure ?? runnerCompletion?.failure, stopped: original.stopped,
            providerUsage: usage, providerAdmission: runnerCompletion?.providerAdmission ?? original.providerAdmission)
        var receipt = closingReceipt
        var accountingHealthy = closingAccountingHealthy
        do {
            receipt = try store.episodeReceipt(id: identifiers.episodeID, clock: clock.now())
            if receipt?.state == .active { accountingHealthy = false }
        } catch { accountingHealthy = false }
        if accountingHealthy, let receipt { resolved = resolved.reconcilingEpisodeState(receipt.state) }
        else {
            resolved = GenerationResult(elapsed: resolved.elapsed, tokensPerSecond: resolved.tokensPerSecond,
                failure: "episode_accounting_failed", stopped: resolved.stopped,
                providerUsage: resolved.providerUsage, providerAdmission: resolved.providerAdmission)
        }
        let status: CaptureStatus = captureFailed ? (response.isEmpty ? .failed : .partial)
            : resolved.stopped ? (response.isEmpty ? .cancelled : .partial)
            : resolved.failure != nil || response.isEmpty ? (response.isEmpty ? .failed : .partial) : .complete
        let reason: InvocationTerminalReason = captureFailed || !accountingHealthy ? .captureFailure
            : resolved.stopped ? .cancelled : resolved.failure == "incomplete_result" ? .upstreamIncomplete
            : !invocationStarted && resolved.failure != nil ? .admissionFailure
            : status == .complete ? .completed : .transportFailure
        var capturedStatus: CaptureStatus? = status, capturedReason: InvocationTerminalReason? = reason
        do {
            if invocationStarted {
                _ = try store.finalizeInvocation(invocationID: identifiers.invocationID, status: status, reason: reason,
                    usageJSON: try usage.map { try JSONEncoder().encode($0) })
            } else {
                _ = try store.append(conversationID: conversationID, role: .assistant, text: "", status: status,
                    turnID: identifiers.turnID, eventID: identifiers.assistantEventID)
            }
        } catch {
            captureFailed = true; capturedStatus = nil; capturedReason = nil
            resolved = GenerationResult(elapsed: resolved.elapsed, tokensPerSecond: resolved.tokensPerSecond,
                failure: "capture_failure", stopped: resolved.stopped,
                providerUsage: resolved.providerUsage, providerAdmission: resolved.providerAdmission)
        }
        let text = response; response = ""
        let fullCompletion = elapsedMilliseconds()
        let finalizationDuration = finalizationStarted.flatMap { start in fullCompletion.map { max(0, $0 - start) } }
        let completion = AnswerAttemptCompletion(identifiers: identifiers, generation: resolved, episode: receipt,
            preparation: preparation, invocationStarted: invocationStarted, captureStatus: capturedStatus,
            terminalReason: capturedReason, captureHealthy: !captureFailed, accountingHealthy: accountingHealthy,
            responseBytes: text.utf8.count, responseDigest: EndpointRequest.digest(Data(text.utf8)),
            timing: AnswerAttemptTiming(preparationMilliseconds: preparationMilliseconds,
                firstDurableVisibleDeltaMilliseconds: firstVisibleMilliseconds, fullCompletionMilliseconds: fullCompletion,
                providerCompletionMilliseconds: providerCompletionMilliseconds, finalizationMilliseconds: finalizationDuration))
        let callback = onComplete; onComplete = nil; onText = nil; onStage = nil; lifetime = nil
        callback?(completion, text)
    }

    private func elapsedMilliseconds() -> Double? {
        guard let start = startedClock, let now = try? clock.now(), episodeIdentifierEqual(start.domain, now.domain),
              now.continuousNanoseconds >= start.continuousNanoseconds else { return nil }
        return Double(now.continuousNanoseconds - start.continuousNanoseconds) / 1_000_000
    }

    private func interruptionResult(_ stopped: (EpisodeState, String?)) -> GenerationResult {
        let failure = stopped.1 ?? (stopped.0 == .deadlineExceeded ? "episode_deadline_exceeded"
            : stopped.0 == .budgetExceeded ? "episode_budget_exceeded"
            : stopped.0 == .cancelled ? nil : "episode_inactive")
        return GenerationResult(elapsed: (elapsedMilliseconds() ?? 0) / 1000, tokensPerSecond: nil,
            failure: failure, stopped: stopped.0 == .cancelled)
    }

    private func failureResult(_ error: Error, capture: Bool = false) -> GenerationResult {
        let failure = capture ? "capture_failure" : ComponentContextPreparationOperation.failureCode(error)
        return GenerationResult(elapsed: (elapsedMilliseconds() ?? 0) / 1000, tokensPerSecond: nil,
            failure: failure, stopped: failure == "cancelled")
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Self.isOnMainQueue { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private static func safeResult(_ result: GenerationResult) -> GenerationResult {
        GenerationResult(elapsed: result.elapsed.isFinite && result.elapsed >= 0 ? result.elapsed : 0,
            tokensPerSecond: result.tokensPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            failure: safeFailure(result.failure), stopped: result.stopped,
            providerUsage: result.providerUsage, providerAdmission: result.providerAdmission)
    }

    private static func safeFailure(_ failure: String?) -> String? {
        guard let failure else { return nil }
        let allowed: Set<String> = ["busy", "io_failed", "process_failed", "timeout", "context_full", "empty_result",
            "incomplete_result", "invalid_endpoint", "http_failed", "redirect_rejected", "invalid_stream", "output_limit",
            "provider_admission_unavailable", "provider_adapter_unverified", "provider_template_mismatch", "admission_mismatch",
            "provider_count_mismatch", "episode_budget_exceeded", "episode_deadline_exceeded", "episode_inactive",
            "episode_input_unobservable", "episode_adapter_violation", "episode_clock_unavailable", "episode_accounting_failed",
            "context_preparation_failed", "capture_failure", "cancelled", "host_settings_failure"]
        return allowed.contains(failure) ? failure : "process_failed"
    }
}
