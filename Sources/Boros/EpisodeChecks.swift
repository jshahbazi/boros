import Foundation
import Darwin
import CSQLite

/// Synthetic fixtures exercise the durable lifecycle and accounting, without
/// reading or printing captured user content or request snapshots.
enum EpisodeChecks {
    private final class Clock: EpisodeClockSource, @unchecked Sendable {
        var ticks: UInt64 = 1_000_000_000
        var domain = "synthetic-continuous-clock"
        var utc = Date(timeIntervalSince1970: 1_700_000_000)
        func now() throws -> EpisodeClockSnapshot { EpisodeClockSnapshot(domain: domain, continuousNanoseconds: ticks, utc: utc) }
    }
    private final class RaceCounts: @unchecked Sendable {
        let lock = NSLock(); var accepted = 0; var rejected = 0
        func record(_ success: Bool) { lock.lock(); defer { lock.unlock() }; if success { accepted += 1 } else { rejected += 1 } }
    }
    private static func rejected(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func rejected(_ expected: EpisodeBudgetError, _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch let error as EpisodeBudgetError { return error.failureCode == expected.failureCode } catch { return false }
    }
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-episode-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store: MemoryStore? = try MemoryStore(directory: directory)
        let chat = try store!.createConversation(projectID: "synthetic-episode-project", title: "Synthetic episode lifecycle")
        let other = try store!.createConversation(projectID: "synthetic-other-project", title: "Separate scope")
        let clock = Clock(), body = Data("{\"messages\":[{\"role\":\"user\",\"content\":\"synthetic question\"}],\"max_tokens\":20}".utf8)
        var checks: [String: Bool] = [:]
        func begin(_ id: String, limits: EpisodeLimits = .init()) throws -> EpisodeLease {
            _ = try store!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "turn-" + id, humanEventID: "human-" + id, episodeID: id, text: "Synthetic accepted request " + id, limits: limits, clock: clock.now())
            return EpisodeLease(ledger: store!, episodeID: id, clock: clock)
        }
        let accepted = try begin("accepted")
        let original = try accepted.checkActive()
        checks["episode_human_and_budget_atomic"] = try original.humanEventID == "human-accepted" && store!.events(conversationID: chat.id).count == 1 && original.charged == .zero && original.held == .zero
        let replay = try store!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "turn-accepted", humanEventID: "human-accepted", episodeID: "accepted", text: "Synthetic accepted request accepted", limits: .init(), clock: clock.now())
        checks["episode_accept_replay_idempotent"] = original == replay
        checks["episode_accept_changed_input_conflicts"] = rejected(.conflict) { _ = try store!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "turn-accepted", humanEventID: "human-accepted", episodeID: "accepted", text: "Changed fixture", limits: .init(), clock: clock.now()) }
        checks["episode_accept_cross_scope_conflicts"] = rejected { _ = try store!.acceptRequestAndBeginEpisode(conversationID: other.id, turnID: "turn-accepted", humanEventID: "human-accepted", episodeID: "accepted", text: "Synthetic accepted request accepted", limits: .init(), clock: clock.now()) }
        var invalidLimits = EpisodeLimits(); invalidLimits.resources.inputTokens = -1
        checks["episode_negative_limits_rejected_before_capture"] = rejected { _ = try begin("invalid", limits: invalidLimits) }
        checks["episode_rejected_accept_leaves_no_source"] = try !store!.events(conversationID: chat.id).contains { $0.id == "human-invalid" }
        checks["episode_overflow_resource_vector_rejected"] = rejected { _ = try EpisodeResources(inputTokens: Int.max).adding(EpisodeResources(inputTokens: 1)) }
        checks["episode_resource_underflow_rejected"] = rejected { _ = try EpisodeResources.zero.subtracting(EpisodeResources(modelCalls: 1)) }
        let request = try accepted.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 12, outputTokens: 20, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-provider", snapshot: body, operationID: "answer-work")
        checks["episode_prepared_capacity_held"] = try request.state == .prepared && accepted.checkActive().held == request.request.resources && accepted.checkActive().charged == .zero
        checks["episode_prepare_replay_idempotent"] = try accepted.prepare(kind: .answer, resources: request.request.resources, adapterIdentity: "synthetic-provider", snapshot: body, operationID: request.id) == request
        checks["episode_prepare_changed_identity_conflicts"] = rejected(.conflict) { _ = try accepted.prepare(kind: .answer, resources: request.request.resources, adapterIdentity: "changed-provider", snapshot: body, operationID: request.id) }
        checks["episode_snapshot_credentials_rejected"] = rejected { _ = try accepted.prepare(kind: .answer, resources: EpisodeResources(modelCalls: 1), adapterIdentity: "synthetic-provider", snapshot: Data("{\"Authorization\":\"synthetic\"}".utf8)) }
        let invocation = try store!.beginInvocation(invocationID: "linked-invocation", conversationID: chat.id, turnID: "turn-accepted", humanEventID: "human-accepted", assistantEventID: "linked-assistant", providerIdentity: "http://localhost:11234/v1/", requestBody: body, episodeID: accepted.episodeID, episodeWorkID: request.id)
        checks["episode_invocation_exact_linkage"] = invocation.episodeID == accepted.episodeID && invocation.episodeWorkID == request.id
        checks["episode_invocation_cross_scope_denied"] = rejected { _ = try store!.beginInvocation(invocationID: "bad-linked-invocation", conversationID: other.id, turnID: "turn-accepted", humanEventID: "human-accepted", assistantEventID: "bad-linked-assistant", providerIdentity: "http://localhost:11234/v1/", requestBody: body, episodeID: accepted.episodeID, episodeWorkID: request.id) }
        checks["episode_invocation_unpaired_link_denied"] = rejected { _ = try store!.beginInvocation(invocationID: "missing-work-invocation", conversationID: chat.id, turnID: "turn-accepted", humanEventID: "human-accepted", assistantEventID: "missing-work-assistant", providerIdentity: "http://localhost:11234/v1/", requestBody: body, episodeID: accepted.episodeID) }
        let armed = try accepted.arm(request)
        checks["episode_armed_inputs_calls_charged_output_held"] = armed.charged == EpisodeResources(inputTokens: 12, modelCalls: 1, httpAttempts: 1) && armed.held == EpisodeResources(outputTokens: 20)
        var handoffs = 0
        let submitted = try accepted.dispatch(armed) { handoffs += 1 }
        checks["episode_handoff_started_once_after_arm"] = handoffs == 1 && submitted.state == .submitted
        checks["episode_handoff_replay_cannot_start_twice"] = rejected { _ = try accepted.dispatch(submitted) { handoffs += 1 } } && handoffs == 1
        _ = try store!.appendInvocationChunk(invocationID: invocation.id, sequence: 0, text: "Synthetic durable partial")
        checks["episode_active_cannot_publish_complete_capture"] = rejected(.inactive) {
            _ = try store!.finalizeInvocation(invocationID: invocation.id, status: .complete, reason: .completed)
        }
        checks["episode_rejected_complete_keeps_invocation_unfinalized"] = try store!.invocation(id: invocation.id)?.finalStatus == nil
        let unknown = try accepted.settle(submitted, outcome: .outcomeUnknown, receiptID: "unknown-receipt")
        checks["episode_missing_usage_retains_output_bound"] = unknown.observed == nil && unknown.held.outputTokens == 20 && unknown.charged.inputTokens == 12
        _ = try accepted.finish(reason: .cancelled)
        checks["episode_stop_fences_new_work"] = rejected(.inactive) { _ = try accepted.prepare(kind: .tokenizer, resources: EpisodeResources(httpAttempts: 1), adapterIdentity: "synthetic-provider") }
        checks["episode_stop_fences_new_content"] = rejected(.inactive) { _ = try store!.appendInvocationChunk(invocationID: invocation.id, sequence: 1, text: "Late callback") }
        let partial = try store!.finalizeInvocation(invocationID: invocation.id, status: .partial, reason: .cancelled)
        checks["episode_stop_preserves_committed_partial"] = partial.status == .partial && partial.byteCount > 0
        let observed = EpisodeResources(inputTokens: 12, outputTokens: 7, modelCalls: 1, httpAttempts: 1)
        let late = try accepted.settle(unknown, outcome: .completed, observed: observed, receiptID: "late-usage")
        let terminal = try store!.episodeReceipt(id: accepted.episodeID, clock: clock.now())
        checks["episode_late_usage_settles_without_reopening"] = late.observed == observed && late.held.outputTokens == 0 && terminal.state == .cancelled && terminal.charged.outputTokens == 7
        checks["episode_late_usage_replay_does_not_double_charge"] = try accepted.settle(late, outcome: .completed, observed: observed, receiptID: "late-usage") == late && store!.episodeReceipt(id: accepted.episodeID, clock: clock.now()).charged.outputTokens == 7
        checks["episode_changed_usage_receipt_conflicts"] = rejected(.conflict) { _ = try accepted.settle(late, outcome: .completed, observed: EpisodeResources(inputTokens: 12, outputTokens: 8, modelCalls: 1, httpAttempts: 1), receiptID: "late-usage") }
        checks["episode_conflict_preserves_usage"] = try store!.episodeWork(episodeID: accepted.episodeID, operationID: late.id)?.observed == observed
        let completedLease = try begin("complete-publication")
        let completedWork = try completedLease.prepare(kind: .answer,
            resources: EpisodeResources(inputTokens: 4, outputTokens: 4, modelCalls: 1),
            adapterIdentity: "synthetic-complete-publication", snapshot: body)
        _ = try store!.beginInvocation(invocationID: "complete-publication-invocation", conversationID: chat.id,
            turnID: "turn-complete-publication", humanEventID: "human-complete-publication", assistantEventID: "complete-publication-assistant",
            providerIdentity: "native:synthetic", requestBody: body, episodeID: completedLease.episodeID, episodeWorkID: completedWork.id)
        let completedSubmitted = try completedLease.dispatch(completedWork) {}
        _ = try store!.appendInvocationChunk(invocationID: "complete-publication-invocation", sequence: 0, text: "Synthetic completed answer")
        _ = try completedLease.settle(completedSubmitted, outcome: .completed,
            observed: EpisodeResources(inputTokens: 4, outputTokens: 1, modelCalls: 1))
        _ = try completedLease.finish(reason: .completed)
        let completeEvent = try store!.finalizeInvocation(invocationID: "complete-publication-invocation", status: .complete, reason: .completed)
        checks["episode_completed_allows_complete_publication"] = completeEvent.status == .complete
        let completeReplay = try store!.finalizeInvocation(invocationID: "complete-publication-invocation", status: .complete, reason: .completed)
        checks["episode_completed_capture_replay_idempotent"] = completeReplay.id == completeEvent.id
            && completeReplay.digest == completeEvent.digest && completeReplay.createdAt == completeEvent.createdAt
        let preflight = try begin("preflight-stop")
        let prepared = try preflight.prepare(kind: .calibration, resources: EpisodeResources(inputTokens: 10, outputTokens: 1, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-calibration", snapshot: body)
        _ = try preflight.finish(reason: .cancelled)
        let unarmed = try store!.episodeWork(episodeID: preflight.episodeID, operationID: prepared.id)
        checks["episode_unarmed_stop_releases_proven_nonuse"] = unarmed?.state == .cancelledBeforeDispatch && unarmed?.held == .zero && unarmed?.charged == .zero
        checks["episode_stale_lease_cannot_handoff_after_stop"] = rejected { _ = try preflight.dispatch(prepared) { handoffs += 1 } } && handoffs == 1
        let violationLease = try begin("violation")
        let violationWork = try violationLease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 20, outputTokens: 5, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-violating-provider", snapshot: body)
        let violatingSubmitted = try violationLease.dispatch(violationWork) {}
        checks["episode_usage_violation_reported"] = rejected(.adapterViolation) { _ = try violationLease.settle(violatingSubmitted, outcome: .completed, observed: EpisodeResources(inputTokens: 21, outputTokens: 9, modelCalls: 1, httpAttempts: 1), evidence: Data("{\"fixture\":\"observed-invalid-usage\"}".utf8), receiptID: "violating-usage") }
        let violationReceipt = try store!.episodeReceipt(id: violationLease.episodeID, clock: clock.now())
        let recordedViolation = try store!.episodeWork(episodeID: violationLease.episodeID, operationID: violationWork.id)
        checks["episode_violation_evidence_survives_throw"] = violationReceipt.state == .failed && violationReceipt.charged.inputTokens == 21 && violationReceipt.charged.outputTokens == 9 && recordedViolation?.receiptID == "violating-usage"
        let quarantine = try begin("quarantine")
        checks["episode_adapter_violation_blocks_later_episode"] = rejected(.adapterViolation) { _ = try quarantine.prepare(kind: .answer, resources: EpisodeResources(modelCalls: 1), adapterIdentity: "synthetic-violating-provider") }
        let flagLease = try begin("identity-violation")
        let flagWork = try flagLease.dispatch(flagLease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1), adapterIdentity: "synthetic-wrong-model")) {}
        checks["episode_identity_violation_persisted_with_valid_usage"] = rejected(.adapterViolation) { _ = try flagLease.settle(flagWork, outcome: .completed, observed: EpisodeResources(inputTokens: 3, outputTokens: 2, modelCalls: 1), receiptID: "wrong-model-receipt", adapterViolation: true) }
        checks["episode_identity_violation_usage_retained"] = try store!.episodeWork(episodeID: flagLease.episodeID, operationID: flagWork.id)?.observed?.outputTokens == 2
        var strictLimits = EpisodeLimits(); strictLimits.requireKnownModelInput = true
        let strict = try begin("strict", limits: strictLimits)
        checks["episode_strict_opaque_model_rejected"] = rejected(.unobservableInput) { _ = try strict.prepare(kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1, encoderInputBytes: 16), adapterIdentity: "synthetic-opaque-encoder", inputTokensKnown: false) }
        checks["episode_strict_rejection_preserves_lexical_fallback_capacity"] = try strict.checkActive().charged == .zero && strict.checkActive().held == .zero
        let opaque = try begin("opaque")
        let opaqueWork = try opaque.dispatch(opaque.prepare(kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1, encoderInputBytes: 16), adapterIdentity: "synthetic-opaque-encoder", inputTokensKnown: false)) {}
        _ = try opaque.settle(opaqueWork, outcome: .completed)
        checks["episode_opaque_input_is_unknown_not_byte_estimate"] = try opaque.checkActive().unknownInputOperations == 1 && opaque.checkActive().charged.inputTokens == 0 && opaque.checkActive().charged.encoderInputBytes == 16
        let deadline = try begin("deadline")
        let deadlineWork = try deadline.prepare(kind: .calibration, resources: EpisodeResources(inputTokens: 10, outputTokens: 1, modelCalls: 1), adapterIdentity: "synthetic-deadline-provider")
        clock.ticks += 120_000_000_000
        checks["episode_continuous_deadline_terminalizes"] = rejected(.deadlineExceeded) { _ = try deadline.arm(deadlineWork) }
        checks["episode_deadline_release_unarmed_only"] = try store!.episodeReceipt(id: deadline.episodeID, clock: clock.now()).state == .deadlineExceeded && store!.episodeWork(episodeID: deadline.episodeID, operationID: deadlineWork.id)?.held == .zero
        let rollback = try begin("rollback")
        clock.ticks -= 1
        checks["episode_monotonic_rollback_fails_closed"] = rejected { _ = try rollback.checkActive() }
        checks["episode_rollback_does_not_reset_deadline"] = try store!.episodeReceipt(id: rollback.episodeID, clock: clock.now()).state == .interrupted
        clock.ticks += 2
        let wall = try begin("wall-clock")
        clock.utc = Date(timeIntervalSince1970: 100); clock.ticks += 1
        checks["episode_utc_rollback_has_no_budget_effect"] = try wall.checkActive().state == .active && wall.remainingSeconds() > 119
        let domain = try begin("domain-change")
        clock.domain = "synthetic-other-boot"
        checks["episode_clock_domain_change_fails_closed"] = rejected { _ = try domain.checkActive() }
        clock.domain = "synthetic-continuous-clock"
        var raceLimits = EpisodeLimits(); raceLimits.resources.modelCalls = 1
        let race = try begin("race", limits: raceLimits), counts = RaceCounts()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do { _ = try race.prepare(kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1), adapterIdentity: "synthetic-race-encoder", operationID: "race-\(index)"); counts.record(true) }
            catch { counts.record(false) }
        }
        checks["episode_concurrent_last_slot_atomic"] = counts.accepted == 1 && counts.rejected == 15
        let raceReceipt = try store!.episodeReceipt(id: race.episodeID, clock: clock.now())
        checks["episode_race_no_partial_or_negative_totals"] = raceReceipt.state == .budgetExceeded && raceReceipt.charged == .zero && raceReceipt.held == .zero
        let realClock = SystemEpisodeClock()
        let realFirst = try realClock.now(); Thread.sleep(forTimeInterval: 0.005); let realSecond = try realClock.now()
        checks["episode_system_clock_verified_continuous_boot_domain"] = realFirst.domain.hasPrefix("mach-continuous-v1:") && realFirst.domain == realSecond.domain && realSecond.continuousNanoseconds > realFirst.continuousNanoseconds
        let recoverPrepared = try begin("recover-prepared")
        let preparedRecovery = try recoverPrepared.prepare(kind: .tokenizer, resources: EpisodeResources(httpAttempts: 1), adapterIdentity: "synthetic-recovery-provider", snapshot: body)
        let recoverArmed = try begin("recover-armed")
        let armedRecovery = try recoverArmed.arm(recoverArmed.prepare(kind: .calibration, resources: EpisodeResources(inputTokens: 7, outputTokens: 1, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-recovery-calibration", snapshot: body))
        // Drop leases before releasing exclusive ownership.
        checks["episode_read_only_archive_validator_accepts_active_and_terminal"] = try validate(directory)
        // A separately scoped fixture can release all leases for reopen.
        checks.merge(try recoveryChecks()) { _, new in new }
        checks.merge(try migrationChecks()) { _, new in new }
        checks.merge(try snapshotChecks()) { _, new in new }
        checks["episode_recovery_work_ids_available"] = preparedRecovery.state == .prepared && armedRecovery.state == .dispatchArmed
        checks["episode_parent_cross_scope_rejected"] = rejected { _ = try recoverPrepared.prepare(kind: .sourceRead, resources: EpisodeResources(rawSourceBytes: 1), adapterIdentity: "synthetic-source", parentID: armedRecovery.id) }
        return checks
    }
    private static func validate(_ directory: URL) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle = database else { throw MemoryError.database("could not inspect episode fixture") }
        defer { sqlite3_close(handle) }
        try MemoryStore.validateEpisodeJournal(database: handle)
        return true
    }
    private static func recoveryChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-episode-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        var store: MemoryStore? = try MemoryStore(directory: directory)
        let chat = try store!.createConversation(projectID: "synthetic-recovery", title: "Synthetic recovery")
        for id in ["prepared-recovery", "armed-recovery", "answer-recovery"] {
            _ = try store!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: id, humanEventID: "human-" + id, episodeID: id, text: "Synthetic recovery request", limits: .init(), clock: clock.now())
        }
        let body = Data("{\"messages\":[]}".utf8)
        let prepared = try store!.reserveEpisodeWork(episodeID: "prepared-recovery", request: EpisodeWorkRequest(id: "prepared-work", parentID: nil, kind: .tokenizer, resources: EpisodeResources(httpAttempts: 1), adapterIdentity: "synthetic-recovery", snapshot: body, inputTokensKnown: true), clock: clock.now())
        let armed = try store!.reserveEpisodeWork(episodeID: "armed-recovery", request: EpisodeWorkRequest(id: "armed-work", parentID: nil, kind: .calibration, resources: EpisodeResources(inputTokens: 9, outputTokens: 1, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-recovery", snapshot: body, inputTokensKnown: true), clock: clock.now())
        _ = try store!.armEpisodeWork(episodeID: armed.episodeID, operationID: armed.id, expectedRevision: armed.revision, clock: clock.now())
        let answer = try store!.reserveEpisodeWork(episodeID: "answer-recovery", request: EpisodeWorkRequest(id: "answer-work", parentID: nil, kind: .answer, resources: EpisodeResources(inputTokens: 11, outputTokens: 10, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-recovery", snapshot: body, inputTokensKnown: true), clock: clock.now())
        _ = try store!.beginInvocation(invocationID: "recover-invocation", conversationID: chat.id, turnID: "answer-recovery", humanEventID: "human-answer-recovery", assistantEventID: "recover-assistant", providerIdentity: "http://localhost:11234/v1/", requestBody: body, episodeID: answer.episodeID, episodeWorkID: answer.id)
        _ = try store!.performEpisodeHandoff(episodeID: answer.episodeID, operationID: answer.id, expectedRevision: answer.revision, clock: clock.now()) {}
        _ = try store!.appendInvocationChunk(invocationID: "recover-invocation", sequence: 0, text: "Synthetic committed recovery fragment")
        store = nil; store = try MemoryStore(directory: directory)
        let preparedAfter = try store!.episodeWork(episodeID: prepared.episodeID, operationID: prepared.id)
        let armedAfter = try store!.episodeWork(episodeID: armed.episodeID, operationID: armed.id)
        let answerAfter = try store!.episodeWork(episodeID: answer.episodeID, operationID: answer.id)
        let initialReceipt = try store!.episodeReceipt(id: answer.episodeID, clock: clock.now())
        var result = [
            "episode_restart_unarmed_cancelled_no_charge": preparedAfter?.state == .cancelledBeforeDispatch && preparedAfter?.charged == .zero && preparedAfter?.held == .zero,
            "episode_restart_armed_unknown_charge_and_bound": armedAfter?.state == .outcomeUnknown && armedAfter?.charged.inputTokens == 9 && armedAfter?.charged.modelCalls == 1 && armedAfter?.held.outputTokens == 1,
            "episode_restart_answer_unknown_and_partial_agree": try answerAfter?.state == .outcomeUnknown && initialReceipt.state == .interrupted && store!.invocation(id: "recover-invocation")?.finalStatus == .partial,
            "episode_restart_no_observed_usage_invented": armedAfter?.observed == nil && answerAfter?.observed == nil,
            "episode_restart_new_dispatch_fenced": rejected { _ = try store!.performEpisodeHandoff(episodeID: answer.episodeID, operationID: answer.id, expectedRevision: answer.revision, clock: clock.now()) {} },
            "episode_restart_archive_validator_passes": try validate(directory)
        ]
        store = nil; store = try MemoryStore(directory: directory)
        result["episode_repeated_restart_accounting_stable"] = try store!.episodeReceipt(id: answer.episodeID, clock: clock.now()) == initialReceipt && store!.events(conversationID: chat.id).filter { $0.id == "recover-assistant" }.count == 1
        let late = EpisodeWorkSettlement(receiptID: "recovery-late", outcome: .completed, observed: EpisodeResources(inputTokens: 11, outputTokens: 4, modelCalls: 1, httpAttempts: 1), evidence: nil)
        _ = try store!.settleEpisodeWork(episodeID: answer.episodeID, operationID: answer.id, settlement: late, clock: clock.now())
        result["episode_recovered_unknown_accepts_late_authoritative_usage"] = try store!.episodeReceipt(id: answer.episodeID, clock: clock.now()).held.outputTokens == 0 && store!.episodeReceipt(id: answer.episodeID, clock: clock.now()).state == .interrupted
        return result
    }
    private static func migrationChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-episode-v2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MemoryStore? = try MemoryStore(directory: directory)
        let chat = try store!.createConversation(projectID: "synthetic-v2", title: "Legacy unmetered history")
        _ = try store!.append(conversationID: chat.id, role: .human, text: "Synthetic legacy input", status: .complete, turnID: "legacy-turn", eventID: "legacy-human")
        _ = try store!.beginInvocation(invocationID: "legacy-invocation", conversationID: chat.id, turnID: "legacy-turn", humanEventID: "legacy-human", assistantEventID: "legacy-assistant", providerIdentity: "http://localhost:11234/v1/", requestBody: Data("{\"messages\":[]}".utf8))
        _ = try store!.appendInvocationChunk(invocationID: "legacy-invocation", sequence: 0, text: "Synthetic committed legacy fragment")
        store = nil
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("memory.sqlite3").path, &database) == SQLITE_OK, let handle = database else { throw MemoryError.database("could not prepare schema two fixture") }
        let sql = "ALTER TABLE invocations DROP COLUMN episode_work_id; ALTER TABLE invocations DROP COLUMN episode_id; DROP TABLE episode_resource_totals; DROP TABLE episode_work; DROP TABLE episode_request_snapshots; DROP TABLE episodes; PRAGMA user_version=2;"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(handle); throw MemoryError.database("could not construct schema two fixture") }
        sqlite3_close(handle)
        store = try MemoryStore(directory: directory)
        let invocation = try store!.invocation(id: "legacy-invocation")
        return [
            "episode_schema_two_migrates_legacy_as_unmetered": invocation?.episodeID == nil && invocation?.episodeWorkID == nil && invocation?.requestBody == Data("{\"messages\":[]}".utf8),
            "episode_schema_two_legacy_stream_recovers_partial": invocation?.finalStatus == .partial && invocation?.terminalReason == .interrupted && invocation?.recovered == true,
            "episode_schema_two_migration_archive_validator_passes": try validate(directory)
        ]
    }
    private static func snapshotChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-episode-snapshot-bound-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), clock = Clock()
        let chat = try store.createConversation(projectID: "synthetic-snapshot-bound", title: "Private snapshot allowance")
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "snapshot-turn", humanEventID: "snapshot-human", episodeID: "snapshot-episode", text: "Synthetic snapshot accounting request", limits: .init(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: "snapshot-episode", clock: clock)
        let padding = String(repeating: "a", count: MemoryStore.maximumPayloadBytes - 128)
        var first: EpisodeWorkRecord?
        for index in 0..<16 {
            let snapshot = Data(("{\"fixture\":\"" + padding + "\",\"index\":" + String(index) + "}").utf8)
            let work = try lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-snapshot-fixture", snapshot: snapshot, operationID: "snapshot-work-" + String(index))
            if index == 0 { first = work }
            _ = try lease.settle(lease.dispatch(work) {}, outcome: .completed)
        }
        let firstWork = first!
        let replay = try lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: firstWork.request.adapterIdentity, snapshot: firstWork.request.snapshot, operationID: firstWork.id)
        let shared = try lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-snapshot-fixture", snapshot: firstWork.request.snapshot, operationID: "shared-snapshot-work")
        _ = try lease.settle(lease.dispatch(shared) {}, outcome: .completed)
        let rejectedNew = rejected(.exhausted) { _ = try lease.prepare(kind: .retrieval, resources: .zero, adapterIdentity: "synthetic-snapshot-fixture", snapshot: Data(("{\"fixture\":\"" + padding + "\",\"index\":17}").utf8), operationID: "overflow-snapshot-work") }
        return [
            "episode_snapshot_identical_replay_consumes_no_extra_capacity": replay.id == firstWork.id && replay.state == .completed,
            "episode_snapshot_shared_body_reuses_capacity": shared.state == .prepared,
            "episode_snapshot_distinct_aggregate_bound_enforced": try rejectedNew && store.episodeReceipt(id: "snapshot-episode", clock: clock.now()).state == .budgetExceeded,
            "episode_snapshot_archive_validator_accepts_bound_state": try validate(directory)
        ]
    }

}
