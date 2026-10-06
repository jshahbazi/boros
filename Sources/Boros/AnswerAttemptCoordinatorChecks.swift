import Foundation
import Darwin

/// Actual component preparation and authoritative store, followed by a fake
/// answering transport. All source and output text is public synthetic data.
enum AnswerAttemptCoordinatorChecks {
    static func run(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        Suite(baseURL: baseURL, completion: completion).next()
    }

    private enum Case: String, CaseIterable {
        case success, lexicalRange, wrongAnswer, unknownUsage, partialFailure, emptyAnswer, duplicateCallbacks
        case cancelBeforeStart, cancelPreparing, cancelBeforeDispatch, cancelAfterDispatch, cancelAfterChunk
        case delayedCancel, concurrentAcceptanceStop, hostSaveFailure
        case deadlineBeforeStart, deadlineAfterDispatch, captureFailure, adapterViolation, sanitizedFailure
        case wrongScope, wrongProfile, invalidEndpoint, doubleStart
        case busyAfterPreparation, busyOnStart, delayedBusyCancel, stopBeforeHandoff
    }

    private final class Clock: EpisodeClockSource {
        private let lock = NSLock()
        private var ticks: UInt64 = 1_000_000_000
        var onNextSample: (() -> Void)?
        func expire() { lock.lock(); ticks = 200_000_000_000; lock.unlock() }
        func advance() { lock.lock(); ticks += 50_000_000; lock.unlock() }
        func now() throws -> EpisodeClockSnapshot {
            lock.lock(); let sampled = ticks, hook = onNextSample; onNextSample = nil; lock.unlock()
            hook?()
            return EpisodeClockSnapshot(domain: "synthetic-answer-coordinator-v1",
                continuousNanoseconds: sampled, utc: Date(timeIntervalSince1970: 1_770_000_000))
        }
    }

    private final class Suite {
        let baseURL: String
        let completion: ([String: Bool]) -> Void
        var cases = Array(Case.allCases)
        var checks: [String: Bool] = [:]
        var current: Attempt?
        init(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.completion = completion
        }
        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try Attempt(kind: kind, baseURL: baseURL) { [self] result in
                    checks.merge(result) { _, latest in latest }; current = nil; next()
                }
                current = attempt; attempt.start()
            } catch {
                checks["answer_coordinator_\(kind.rawValue)_fixture_started"] = false; next()
            }
        }
    }

    private final class Attempt {
        let kind: Case
        let directory: URL
        let store: MemoryStore
        let chat: StoredConversation
        let clock = Clock()
        let completion: ([String: Bool]) -> Void
        let runner: FakeRunner
        var settings = GenerationSettings()
        var coordinator: AnswerAttemptCoordinator?
        var checks: [String: Bool] = [:]
        var text = ""
        var deliveries = 0
        var completionCount = 0
        var finished = false
        var expectedChunks = 0
        var answerWorkID: String?
        let prompt: String

        init(kind: Case, baseURL: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.completion = completion; runner = FakeRunner(kind: kind)
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw MemoryError.invalid("synthetic temporary path unavailable")
            }
            let path = String(cString: resolved); free(resolved)
            directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("boros-answer-check-" + UUID().uuidString)
            store = try MemoryStore(directory: directory)
            chat = try store.createConversation(projectID: "synthetic-answer-coordinator", title: "Public answer lifecycle fixture")
            _ = try store.append(conversationID: chat.id, role: .human, text: "Public prior source café κ.",
                status: .complete, turnID: "synthetic-prior-turn", eventID: "synthetic-prior-event")
            prompt = kind == .lexicalRange ? "Question Date: 2023/05/23 (Tue) 11:23\nQuestion: Recall cobaltfixture café κ."
                : "Give the public synthetic fixture answer."
            if kind == .lexicalRange {
                let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic archived query evidence")
                _ = try store.append(conversationID: archive.id, role: .human, text: "cobaltfixture exact archived source",
                    status: .complete, turnID: "range-archive-turn", eventID: "range-archive-event")
            }
            settings.profile = kind == .wrongProfile ? .bonsai : .customLocal
            settings.endpointURL = kind == .invalidEndpoint ? "https://example.invalid/v1" : baseURL
            settings.endpointModel = Qwen38TextAdapter.modelID
            settings.system = "Use public synthetic source evidence."
            settings.maximumOutput = 64; settings.temperature = 0
            // These hostile stale fields must be discarded by the coordinator.
            settings.messagesOverride = [["role": "user", "content": "Stale synthetic override must disappear."]]
            settings.preparedEndpointBody = Data("stale synthetic body".utf8)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var prefix: String { "answer_coordinator_" + kind.rawValue }

        func start() {
            let operation = AnswerAttemptCoordinator(store: store, conversationID: chat.id,
                projectID: kind == .wrongScope ? "synthetic-other-scope" : chat.projectID, prompt: prompt,
                settings: settings, retrievalStrategy: kind == .lexicalRange ? .hybrid : .recentOnly,
                lexicalQueryUTF8Range: kind == .lexicalRange
                    ? (prompt.utf8.count - "Recall cobaltfixture café κ.".utf8.count)..<prompt.utf8.count : nil,
                clock: clock, runner: runner,
                onStage: { [self] stage, preparation in
                    if stage == .preparing && kind == .cancelPreparing { coordinator?.cancel() }
                    if stage == .answering {
                        answerWorkID = preparation?.answerWorkID
                        if kind == .cancelBeforeDispatch { coordinator?.cancel() }
                        if kind == .busyAfterPreparation { runner.isRunning = true }
                    }
                }, onText: { [self] chunk in receive(chunk) }, onComplete: { [self] report, answer in finish(report, answer: answer) })
            coordinator = operation
            runner.onDispatch = { [self] in
                if kind == .cancelAfterDispatch || kind == .delayedCancel { operation.cancel() }
                if kind == .deadlineAfterDispatch { clock.expire() }
                if kind == .delayedBusyCancel {
                    operation.cancel()
                    checks[prefix + "_no_completion_before_delayed_busy_refusal"] = completionCount == 0 && runner.isRunning
                    checks[prefix + "_stop_does_not_cancel_unrelated_runner"] = runner.cancels == 0
                }
                if kind == .stopBeforeHandoff {
                    operation.cancel()
                    checks[prefix + "_waits_for_owned_inactive_callback"] = completionCount == 0 && runner.isRunning && runner.cancels == 0
                }
            }
            runner.onCancellationPending = { [self] in
                checks[prefix + "_no_host_completion_while_runner_drains"] = completionCount == 0 && runner.isRunning
                checks[prefix + "_allowance_closed_before_drain"] = (try? store.episodeReceipt(
                    id: operation.identifiers.episodeID, clock: clock.now()).state) == .cancelled
                let next = AnswerAttemptCoordinator(store: store, conversationID: chat.id, projectID: chat.projectID,
                    prompt: "Public busy-runner follow-up.", settings: settings, clock: clock, runner: runner,
                    onText: { _ in }, onComplete: { _, _ in })
                do { _ = try next.accept(); checks[prefix + "_new_attempt_not_ready_during_drain"] = false; next.cancel() }
                catch { checks[prefix + "_new_attempt_not_ready_during_drain"] = true }
            }
            runner.onBeforeDrain = { [self] in clock.advance() }
            if kind == .concurrentAcceptanceStop { clock.onNextSample = { operation.cancel() } }
            do {
                let accepted = try operation.accept()
                checks[prefix + "_accepted_original_chat_scope"] = accepted.projectID == chat.projectID
                    && accepted.humanEventID == operation.identifiers.humanEventID && !accepted.origin.isLocalRead
                checks[prefix + "_selected_policy_frozen"] = accepted.limits.componentPolicy == .selectedQwen
                checks[prefix + "_complete_human_capture_before_preparation"] = try store.events(conversationID: chat.id)
                    .contains { $0.id == operation.identifiers.humanEventID && $0.text == prompt && $0.status == .complete }
                if kind == .concurrentAcceptanceStop {
                    checks[prefix + "_accept_returns_before_completion"] = completionCount == 0
                }
                if kind == .cancelBeforeStart { operation.cancel(); return }
                if kind == .hostSaveFailure { operation.terminate(reason: .failed, failure: "host_settings_failure"); return }
                if kind == .deadlineBeforeStart { clock.expire() }
                try operation.start()
                if kind == .doubleStart {
                    do { try operation.start(); checks[prefix + "_second_start_refused"] = false }
                    catch { checks[prefix + "_second_start_refused"] = true }
                }
            } catch {
                if [.wrongScope, .wrongProfile, .invalidEndpoint].contains(kind) {
                    checks[prefix + "_invalid_acceptance_refused"] = true
                    checks[prefix + "_no_new_human_or_transport"] = (try? store.eventCount(conversationID: chat.id)) == 1
                        && runner.starts == 0
                    finished = true; completion(checks)
                } else {
                    checks[prefix + "_unexpected_acceptance_failure"] = false
                    operation.cancel()
                    if completionCount == 0 { finished = true; completion(checks) }
                }
            }
        }

        private func receive(_ chunk: String) {
            deliveries += 1; text += chunk
            let invocation = try? store.invocation(id: coordinator!.identifiers.invocationID)
            checks[prefix + "_stream_commit_precedes_delivery_\(deliveries)"] = invocation?.chunkCount == deliveries
                && invocation?.observedBytes == text.utf8.count && invocation?.finalStatus == nil
            checks[prefix + "_main_queue_delivery"] = AnswerAttemptCoordinator.isOnMainQueue
            if kind == .cancelAfterChunk { coordinator?.cancel() }
        }

        private func finish(_ report: AnswerAttemptCompletion, answer: String) {
            completionCount += 1
            guard !finished else { return }
            finished = true
            checks[prefix + "_main_queue_completion"] = AnswerAttemptCoordinator.isOnMainQueue
            checks[prefix + "_transient_text_matches_committed_delivery"] = answer == text
                && report.responseBytes == text.utf8.count && report.responseDigest == EndpointRequest.digest(Data(text.utf8))
            checks[prefix + "_authoritative_receipt_terminal"] = report.episode?.state != nil && report.episode?.state != .active
                && report.episode?.id == coordinator?.identifiers.episodeID && report.accountingHealthy
            checks[prefix + "_original_lease_all_model_work"] = runner.seenEpisodeID == nil
                || runner.seenEpisodeID == coordinator?.identifiers.episodeID
            checks[prefix + "_completion_timing_present"] = report.timing.fullCompletionMilliseconds != nil
            do {
                let assistant = try store.events(conversationID: chat.id).first { $0.id == report.identifiers.assistantEventID }
                checks[prefix + "_durable_assistant_matches_terminal"] = assistant?.text == answer
                    && assistant?.status == report.captureStatus
                if let preparation = report.preparation {
                    let invocation = try store.invocation(id: report.identifiers.invocationID)
                    checks[prefix + "_invocation_bound_to_original_episode"] = invocation?.episodeID == report.identifiers.episodeID
                        && invocation?.episodeWorkID == preparation.answerWorkID
                        && invocation?.requestDigest == preparation.requestDigest && invocation?.finalStatus == report.captureStatus
                        && invocation?.admissionJSON == preparation.admissionAuditJSON
                    checks[prefix + "_source_selection_and_count_proof_retained"] = preparation.sourceSelectionWorkID != nil
                        && preparation.admission.componentProof != nil && preparation.admission.episodeID == report.identifiers.episodeID
                    if runner.starts > 0 {
                        checks[prefix + "_stale_settings_discarded_and_exact_body"] = runner.bodyMatches && runner.containsAcceptedPrompt
                    }
                    if kind == .lexicalRange {
                        let audit = try JSONSerialization.jsonObject(with: preparation.contextAudit) as! [String: Any]
                        let retrieval = audit["retrieval"] as! [String: Any]
                        let trace = retrieval["selection_trace"] as! [String: Any]
                        checks[prefix + "_exact_accepted_query_range_and_full_prompt_provenance"] =
                            trace["lexical_input_sha256"] as? String == EndpointRequest.digest(Data("Recall cobaltfixture café κ.".utf8))
                            && trace["accepted_prompt_sha256"] as? String == EndpointRequest.digest(Data(prompt.utf8))
                            && trace["lexical_input_bytes"] as? Int == "Recall cobaltfixture café κ.".utf8.count
                            && trace["lexical_input_offset"] as? Int == prompt.utf8.count - "Recall cobaltfixture café κ.".utf8.count
                        checks[prefix + "_historical_needle_delivered_without_metadata_terms"] =
                            (audit["historical_sources"] as? [[String: Any]])?.contains { $0["event_id"] as? String == "range-archive-event" } == true
                    }
                }
                switch kind {
                case .success, .lexicalRange, .wrongAnswer, .duplicateCallbacks, .doubleStart:
                    checks[prefix + "_operational_success_independent_of_score"] = report.episode?.state == .completed
                        && report.captureStatus == .complete && report.generation.failure == nil && report.captureHealthy
                    checks[prefix + "_observed_answer_usage_settled"] = report.episode?.held.outputTokens == 0
                        && report.generation.providerUsage?.completionTokens == 2 && (report.episode?.charged.modelCalls ?? 0) > 1
                case .unknownUsage:
                    checks[prefix + "_missing_usage_keeps_output_hold"] = report.episode?.state == .completed
                        && report.captureStatus == .complete && report.episode?.held.outputTokens == 64
                        && report.generation.providerUsage == nil
                case .partialFailure, .sanitizedFailure:
                    checks[prefix + "_transport_failure_preserves_partial_and_hold"] = report.episode?.state == .failed
                        && report.captureStatus == .partial && report.episode?.held.outputTokens == 64
                    if kind == .sanitizedFailure { checks[prefix + "_untrusted_error_text_removed"] = report.generation.failure == "process_failed" }
                case .emptyAnswer:
                    checks[prefix + "_empty_answer_is_operational_failure"] = report.episode?.state == .failed
                        && report.captureStatus == .failed && report.generation.failure != nil && deliveries == 0
                case .cancelBeforeStart, .cancelPreparing, .concurrentAcceptanceStop:
                    checks[prefix + "_stop_before_preparation_has_no_work"] = report.episode?.state == .cancelled
                        && report.captureStatus == .cancelled && !report.invocationStarted
                        && report.episode?.charged == .zero && report.episode?.held == .zero && runner.starts == 0
                case .hostSaveFailure:
                    checks[prefix + "_host_save_failure_terminalizes_accepted_request"] = report.episode?.state == .failed
                        && report.captureStatus == .failed && !report.invocationStarted && runner.starts == 0
                        && report.generation.failure == "host_settings_failure" && report.episode?.charged == .zero
                case .cancelBeforeDispatch:
                    let work = try store.episodeWork(episodeID: report.identifiers.episodeID, operationID: answerWorkID ?? "")
                    checks[prefix + "_prepared_answer_refunded_without_transport"] = report.episode?.state == .cancelled
                        && runner.starts == 0 && work?.state == .cancelledBeforeDispatch && work?.charged == .zero && work?.held == .zero
                case .cancelAfterDispatch, .cancelAfterChunk, .delayedCancel:
                    let work = try store.episodeWork(episodeID: report.identifiers.episodeID, operationID: answerWorkID ?? "")
                    checks[prefix + "_stop_retains_original_uncertain_bound"] = report.episode?.state == .cancelled
                        && report.generation.stopped && report.episode?.held.outputTokens == 64
                        && work?.state == .outcomeUnknown && work?.charged.inputTokens == work?.request.resources.inputTokens
                        && work?.charged.modelCalls == 1 && work?.charged.httpAttempts == 1
                    checks[prefix + "_stop_suppresses_late_chunks"] = deliveries == (kind == .cancelAfterChunk ? 1 : 0)
                    if kind == .delayedCancel {
                        checks[prefix + "_completion_after_drain_includes_cleanup_time"] = !runner.isRunning
                            && (report.timing.fullCompletionMilliseconds ?? 0) >= 50
                    }
                case .deadlineBeforeStart, .deadlineAfterDispatch:
                    checks[prefix + "_original_continuous_deadline_enforced"] = report.episode?.state == .deadlineExceeded
                        && report.generation.failure == "episode_deadline_exceeded" && deliveries == 0
                    if kind == .deadlineAfterDispatch {
                        checks[prefix + "_deadline_retains_uncertain_hold"] = report.episode?.held.outputTokens == 64
                    } else { checks[prefix + "_expired_preparation_has_no_transport"] = runner.starts == 0 }
                case .captureFailure:
                    checks[prefix + "_failed_chunk_never_delivered"] = deliveries == 1 && !report.captureHealthy
                        && report.captureStatus == .partial && report.generation.failure == "capture_failure"
                        && report.episode?.state == .failed && report.episode?.held.outputTokens == 64
                case .adapterViolation:
                    checks[prefix + "_usage_violation_cannot_complete"] = report.episode?.state == .failed
                        && report.captureStatus == .partial && report.generation.failure == "episode_adapter_violation"
                    let episodeID = UUID().uuidString
                    var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
                    _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: UUID().uuidString,
                        humanEventID: UUID().uuidString, episodeID: episodeID, text: "Public quarantine follow-up.",
                        limits: limits, clock: clock.now())
                    let nextLease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
                    do {
                        _ = try nextLease.prepare(kind: .answer, resources: EpisodeResources(modelCalls: 1),
                            adapterIdentity: report.preparation?.admission.answerAdapterIdentity ?? "missing-preparation-proof")
                        checks[prefix + "_adapter_remains_quarantined"] = false
                    } catch EpisodeBudgetError.adapterViolation { checks[prefix + "_adapter_remains_quarantined"] = true }
                    _ = try nextLease.finish(reason: .cancelled)
                case .wrongScope, .wrongProfile, .invalidEndpoint: checks[prefix + "_unexpected_completion"] = false
                case .busyAfterPreparation, .busyOnStart:
                    let work = try store.episodeWork(episodeID: report.identifiers.episodeID, operationID: answerWorkID ?? "")
                    checks[prefix + "_busy_refusal_does_not_own_other_runner"] = report.generation.failure == "busy"
                        && report.episode?.state == .failed && report.captureStatus == .failed
                        && runner.isRunning && runner.cancels == 0 && deliveries == 0
                    checks[prefix + "_busy_refusal_releases_prepared_answer"] = work?.state == .cancelledBeforeDispatch
                        && work?.charged == .zero && work?.held == .zero
                case .delayedBusyCancel:
                    let work = try store.episodeWork(episodeID: report.identifiers.episodeID, operationID: answerWorkID ?? "")
                    checks[prefix + "_delayed_busy_completes_original_stop"] = report.episode?.state == .cancelled
                        && report.generation.stopped && report.captureStatus == .cancelled && deliveries == 0
                        && runner.isRunning && runner.cancels == 0
                    checks[prefix + "_never_dispatched_answer_remains_refunded"] = work?.state == .cancelledBeforeDispatch
                        && work?.charged == .zero && work?.held == .zero
                case .stopBeforeHandoff:
                    let work = try store.episodeWork(episodeID: report.identifiers.episodeID, operationID: answerWorkID ?? "")
                    checks[prefix + "_original_fence_suppresses_owned_future_handoff"] = report.episode?.state == .cancelled
                        && report.generation.stopped && report.captureStatus == .cancelled && deliveries == 0
                        && !runner.isRunning && runner.cancels == 0
                        && work?.state == .cancelledBeforeDispatch && work?.charged == .zero && work?.held == .zero
                }
            } catch { checks[prefix + "_terminal_fixture_inspection"] = false }
            // Let the fake transport inject duplicate terminal/late callbacks
            // before asserting the host completed exactly once.
            DispatchQueue.main.async { [self] in
                checks[prefix + "_exactly_one_completion"] = completionCount == 1
                coordinator = nil; completion(checks)
            }
        }
    }

    private final class FakeRunner: AnswerAttemptRunning {
        let kind: Case
        var starts = 0
        var cancels = 0
        var isRunning = false
        var onDispatch: (() -> Void)?
        var onCancellationPending: (() -> Void)?
        var onBeforeDrain: (() -> Void)?
        var seenEpisodeID: String?
        var bodyMatches = false
        var containsAcceptedPrompt = false
        private var lease: EpisodeLease?
        private var work: EpisodeWorkRecord?
        private var admission: EndpointAdmissionReceipt?
        private var onText: ((String) -> Void)?
        private var onComplete: ((GenerationResult) -> Void)?
        private var settled = false

        init(kind: Case) { self.kind = kind }
        func start(prompt: String, settings: GenerationSettings, conversation: Conversation,
                   onText: @escaping (String) -> Void, onComplete: @escaping (GenerationResult) -> Void) {
            starts += 1; isRunning = true; self.onText = onText; self.onComplete = onComplete
            lease = settings.episodeLease; admission = settings.endpointAdmission; seenEpisodeID = lease?.episodeID
            bodyMatches = (try? EndpointRequest.build(prompt: prompt, settings: settings, conversation: conversation)) == settings.preparedEndpointBody
            containsAcceptedPrompt = settings.messagesOverride?.last?["content"] == prompt
                && settings.messagesOverride?.contains { $0["content"] == "Stale synthetic override must disappear." } == false
            if kind == .busyOnStart {
                onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: "busy", stopped: false)); clear(); return
            }
            if kind == .delayedBusyCancel {
                onDispatch?()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
                    onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: "busy", stopped: false)); clear()
                }
                return
            }
            if kind == .stopBeforeHandoff { onDispatch?() }
            do {
                guard let lease, let prepared = settings.preparedAnswerWork else { throw EpisodeBudgetError.invalid }
                work = try lease.dispatch(prepared, start: {})
            } catch {
                isRunning = false; onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil,
                    failure: ProviderAdmissionError.budget(error).failureCode, stopped: false)); return
            }
            onDispatch?()
            if kind == .delayedCancel { onText("Late synthetic delta while drain waits."); return }
            if kind != .emptyAnswer {
                onText(kind == .wrongAnswer ? "A deliberately incorrect public fixture answer." : "Public answer café ")
                if kind == .captureFailure { onText(String(repeating: "x", count: MemoryStore.maximumPayloadBytes + 1)) }
                else if kind == .success || kind == .duplicateCallbacks || kind == .doubleStart { onText("κ.") }
            }
            if [.cancelAfterDispatch, .cancelAfterChunk, .deadlineAfterDispatch, .captureFailure].contains(kind) {
                // Deliberately broken late transport delivery must stay hidden.
                onText("Late synthetic delta must not be visible.")
                onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: nil, stopped: false))
                clear(); return
            }
            var usage: ProviderUsage?
            var failure: String? = kind == .partialFailure ? "io_failed"
                : kind == .sanitizedFailure ? "Untrusted public fixture error text must not enter metadata." : nil
            do {
                if [.unknownUsage, .partialFailure, .sanitizedFailure].contains(kind) { try settleUnknown() }
                else if let lease, let work, let admission {
                    let input = admission.promptTokens + (kind == .adapterViolation ? 1 : 0)
                    let output = kind == .emptyAnswer ? 0 : 2
                    usage = ProviderUsage(promptTokens: input, completionTokens: output, totalTokens: input + output,
                        cachedTokens: nil, reasoningTokens: nil)
                    settled = true
                    _ = try lease.settle(work, outcome: .completed,
                        observed: EpisodeResources(inputTokens: input, outputTokens: output, modelCalls: 1, httpAttempts: 1),
                        evidence: JSONEncoder().encode(usage!))
                }
            } catch { failure = ProviderAdmissionError.budget(error).failureCode }
            isRunning = false
            let result = GenerationResult(elapsed: 0.1, tokensPerSecond: nil, failure: failure, stopped: false,
                providerUsage: usage, providerAdmission: admission)
            onComplete(result)
            if kind == .duplicateCallbacks { onText("Late synthetic duplicate."); onComplete(result) }
            clear()
        }
        func cancel() {
            cancels += 1
            if kind == .delayedCancel, isRunning {
                try? settleUnknown()
                onCancellationPending?()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                    isRunning = false; onBeforeDrain?()
                    onComplete?(GenerationResult(elapsed: 0.05, tokensPerSecond: nil, failure: nil, stopped: true))
                    clear()
                }
                return
            }
            isRunning = false
            try? settleUnknown()
            onComplete?(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: nil, stopped: true))
        }
        private func settleUnknown() throws {
            guard !settled, let lease, let work else { return }
            settled = true
            _ = try lease.settle(work, outcome: .outcomeUnknown)
        }
        private func clear() { onText = nil; onComplete = nil; onDispatch = nil; onCancellationPending = nil; onBeforeDrain = nil }
    }
}
