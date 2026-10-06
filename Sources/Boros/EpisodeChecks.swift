import Foundation
import Darwin
import CSQLite
import CryptoKit

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
        var checks = try providerQuarantineChecks()
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
        checks.merge(try readEpisodeChecks()) { _, new in new }
        checks.merge(try schemaThreeMigrationChecks()) { _, new in new }
        checks.merge(try malformedStoredOriginChecks()) { _, new in new }
        checks.merge(try binaryIdentityChecks()) { _, new in new }
        checks.merge(try unicodeLegacyMigrationChecks()) { _, new in new }
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
        // This fixture starts in the current schema but represents a genuine
        // schema-2 store. It contains no optional-maintenance work.
        guard try scalar(handle, "SELECT count(*) FROM background_index_work") == "0",
              try scalar(handle, "SELECT count(*) FROM background_index_windows") == "0" else {
            sqlite3_close(handle); throw MemoryError.database("historical fixture contains background work")
        }
        let authorityDrops = (AuthorityBindingJournal.tableNames + AuthorityStateKernel.tableNames).map { "DROP TABLE " + $0 + ";" }.joined()
        let sql = authorityDrops + "DROP TABLE background_index_work; DROP TABLE background_index_windows; ALTER TABLE invocations DROP COLUMN episode_work_id; ALTER TABLE invocations DROP COLUMN episode_id; DROP TABLE episode_resource_totals; DROP TABLE episode_work; DROP TABLE episode_request_snapshots; DROP TABLE episodes; PRAGMA user_version=2;"
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
    private static func inspect<T>(_ directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("memory.sqlite3").path, &database) == SQLITE_OK, let handle = database else { throw MemoryError.database("could not inspect synthetic database") }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }
    private static func scalar(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MemoryError.database("could not prepare synthetic inspection") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("synthetic inspection has no result") }
        guard let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }
    private static func readEpisodeChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-read-episode-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try MemoryStore(directory: directory), clock = Clock()
        let binding = EpisodeLocalReadBinding(initiator: .humanBrowser, purpose: .searchInitialPage,
            requestID: "read-request", descriptorVersion: "browser-search-v1", descriptorSHA256: SHA256.hash(data: Data("synthetic query".utf8)).map { String(format: "%02x", $0) }.joined())
        let first = try owner.beginLocalReadEpisode(episodeID: "read", projectID: "project-a", binding: binding, limits: .init(), clock: clock.now())
        let lease = EpisodeLease(ledger: owner, episodeID: "read", clock: clock)
        clock.ticks += 1_000_000_000
        let replay = try owner.beginLocalReadEpisode(episodeID: "read", projectID: "project-a", binding: binding, limits: .init(), clock: clock.now())
        var checks: [String: Bool] = [
            "read_episode_no_chat_binding": first.conversationID == nil && first.turnID == nil && first.humanEventID == nil && first.origin == .localRead(binding),
            "read_episode_initiation_replay_retains_original_deadline": first == replay,
            "read_episode_wrong_project_explicitly_rejected": rejected(.scopeMismatch) { _ = try lease.checkActive(projectID: "project-b") },
            "read_episode_correct_project_active": try lease.checkActive(projectID: "project-a").state == .active,
            "read_episode_changed_project_conflicts": rejected(.conflict) { _ = try owner.beginLocalReadEpisode(episodeID: "read", projectID: "project-b", binding: binding, limits: .init(), clock: clock.now()) }
        ]
        let changed = EpisodeLocalReadBinding(initiator: .humanBrowser, purpose: .sourcePage, requestID: binding.requestID,
            descriptorVersion: binding.descriptorVersion, descriptorSHA256: binding.descriptorSHA256)
        checks["read_episode_changed_descriptor_purpose_conflicts"] = rejected(.conflict) { _ = try owner.beginLocalReadEpisode(episodeID: "read", projectID: "project-a", binding: changed, limits: .init(), clock: clock.now()) }
        var changedLimits = EpisodeLimits(); changedLimits.resources.memoryOperations -= 1
        checks["read_episode_changed_limits_conflict"] = rejected(.conflict) { _ = try owner.beginLocalReadEpisode(episodeID: "read", projectID: "project-a", binding: binding, limits: changedLimits, clock: clock.now()) }
        for kind: EpisodeWorkKind in [.answer, .calibration, .nativeInference, .providerDiscovery, .tokenizer] {
            let resources = [.answer, .calibration, .nativeInference].contains(kind) ? EpisodeResources(modelCalls: 1) : EpisodeResources(httpAttempts: 1)
            checks["read_episode_" + kind.rawValue + "_denied"] = rejected(.invalid) { _ = try lease.prepare(kind: kind, resources: resources, adapterIdentity: "synthetic-read-forbidden") }
        }
        checks["read_episode_encoder_output_budget_denied"] = rejected(.invalid) {
            _ = try lease.prepare(kind: .queryEmbedding, resources: EpisodeResources(outputTokens: 1, modelCalls: 1), adapterIdentity: "synthetic-disguised-generation")
        }
        checks["read_episode_forbidden_work_leaves_budget_untouched"] = try lease.checkActive().charged == .zero && lease.checkActive().held == .zero
        for kind: EpisodeWorkKind in [.retrieval, .sourceRead, .queryEmbedding] {
            let resources = kind == .queryEmbedding ? EpisodeResources(modelCalls: 1, encoderInputBytes: 4) : EpisodeResources(memoryOperations: 1, rawSourceBytes: 8)
            let work = try lease.prepare(kind: kind, resources: resources, adapterIdentity: "synthetic-read-allowed", inputTokensKnown: kind != .queryEmbedding)
            _ = try lease.settle(lease.dispatch(work) {}, outcome: .completed)
            checks["read_episode_" + kind.rawValue + "_allowed"] = try owner.episodeWork(episodeID: "read", operationID: work.id)?.state == .completed
        }
        checks["read_episode_opaque_encoder_reports_unknown"] = try lease.checkActive().unknownInputOperations == 1
        let terminal = try lease.finish(reason: .completed)
        clock.ticks += 120_000_000_000
        let terminalReplay = try owner.beginLocalReadEpisode(episodeID: "read", projectID: "project-a", binding: binding, limits: .init(), clock: clock.now())
        checks["read_episode_terminal_replay_does_not_renew"] = terminalReplay == terminal && terminalReplay.deadlineNanoseconds == first.deadlineNanoseconds
        checks["read_episode_stable_request_cannot_gain_second_allowance"] = rejected(.conflict) {
            _ = try owner.beginLocalReadEpisode(episodeID: "second-read", projectID: "project-a", binding: binding, limits: .init(), clock: clock.now())
        }
        checks["read_episode_stable_request_cannot_change_project_with_new_episode"] = rejected(.conflict) {
            _ = try owner.beginLocalReadEpisode(episodeID: "second-scope-read", projectID: "project-b", binding: binding, limits: .init(), clock: clock.now())
        }
        checks["read_episode_stable_request_cannot_change_descriptor_with_new_episode"] = rejected(.conflict) {
            _ = try owner.beginLocalReadEpisode(episodeID: "second-descriptor-read", projectID: "project-a", binding: changed, limits: .init(), clock: clock.now())
        }

        checks["read_episode_creates_no_source_conversation_or_invocation"] = try inspect(directory) {
            try scalar($0, "SELECT (SELECT count(*) FROM conversations)+(SELECT count(*) FROM events)+(SELECT count(*) FROM invocations)") == "0"
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(EpisodeOrigin.localRead(binding))
        checks["read_episode_origin_roundtrip"] = try JSONDecoder().decode(EpisodeOrigin.self, from: encoded) == .localRead(binding)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for mutation in ["unknownKey", "badVersion", "mixedChat", "missingBinding", "uppercaseDigest", "badDescriptorVersion", "badInitiator"] {
            var altered = object
            switch mutation {
            case "unknownKey": altered["extra"] = "unexpected"
            case "badVersion": altered["version"] = "future"
            case "mixedChat": altered["conversationID"] = "unexpected-chat"
            case "missingBinding": altered.removeValue(forKey: "binding")
            default:
                var nested = altered["binding"] as! [String: Any]
                if mutation == "uppercaseDigest" { nested["descriptorSHA256"] = String(repeating: "A", count: 64) }
                if mutation == "badDescriptorVersion" { nested["descriptorVersion"] = "invalid version" }
                if mutation == "badInitiator" { nested["initiator"] = "externalClient" }
                altered["binding"] = nested
            }
            let bytes = try JSONSerialization.data(withJSONObject: altered)
            checks["read_episode_origin_" + mutation + "_rejects"] = rejected { _ = try JSONDecoder().decode(EpisodeOrigin.self, from: bytes) }
        }
        checks["read_episode_archive_validator_accepts_null_chat_scope"] = try validate(directory)
        checks["read_episode_request_replay_uses_bounded_index"] = try inspect(directory) { database in
            var statement: OpaquePointer?
            let sql = "EXPLAIN QUERY PLAN SELECT id FROM episodes WHERE json_extract(origin_json,'$.kind')='localRead' AND json_extract(origin_json,'$.binding.initiator')='humanBrowser' AND json_extract(origin_json,'$.binding.requestID')='read-request'"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MemoryError.database("could not inspect local-read index plan") }
            defer { sqlite3_finalize(statement) }
            var usesIndex = false
            while sqlite3_step(statement) == SQLITE_ROW {
                if let detail = sqlite3_column_text(statement, 3) { usesIndex = usesIndex || String(cString: detail).contains("episode_local_read_request") }
            }
            return usesIndex
        }
        let requestRace = RaceCounts()
        let raceBinding = EpisodeLocalReadBinding(initiator: .humanBrowser, purpose: .searchInitialPage, requestID: "read-race-request",
            descriptorVersion: binding.descriptorVersion, descriptorSHA256: binding.descriptorSHA256)
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                _ = try owner.beginLocalReadEpisode(episodeID: "read-race-\(index)", projectID: "project-a", binding: raceBinding, limits: .init(), clock: clock.now())
                requestRace.record(true)
            } catch { requestRace.record(false) }
        }
        checks["read_episode_duplicate_request_race_admits_one_allowance"] = requestRace.accepted == 1 && requestRace.rejected == 15

        let cancelBinding = EpisodeLocalReadBinding(initiator: binding.initiator, purpose: binding.purpose, requestID: "cancel-request",
            descriptorVersion: binding.descriptorVersion, descriptorSHA256: binding.descriptorSHA256)
        let active = try owner.beginLocalReadEpisode(episodeID: "local-cancel", projectID: "project-a", binding: cancelBinding, limits: .init(), clock: clock.now())
        let locallyCancelled = EpisodeLease(ledger: owner, episodeID: active.id, clock: clock)
        let fence = try locallyCancelled.progressGuard()
        locallyCancelled.interruptLocally(reason: .cancelled)
        checks["read_episode_immediate_local_cancel_fences_work"] = rejected(.inactive) { _ = try locallyCancelled.checkActive() }
        checks["read_episode_immediate_local_cancel_interrupts_sql"] = fence.interruption()?.failureCode == EpisodeBudgetError.inactive.failureCode
        _ = try locallyCancelled.finish(reason: .cancelled)
        checks["read_episode_local_cancel_durably_terminalizes"] = try owner.episodeReceipt(id: active.id, clock: clock.now()).state == .cancelled
        let chat = try owner.createConversation(projectID: "project-a", title: "Explicit synthetic chat for link denial")
        _ = try owner.append(conversationID: chat.id, role: .human, text: "Synthetic chat input", status: .complete, turnID: "borrowed-turn", eventID: "borrowed-human")
        let linkBinding = EpisodeLocalReadBinding(initiator: binding.initiator, purpose: binding.purpose, requestID: "link-request",
            descriptorVersion: binding.descriptorVersion, descriptorSHA256: binding.descriptorSHA256)
        _ = try owner.beginLocalReadEpisode(episodeID: "read-link", projectID: "project-a", binding: linkBinding, limits: .init(), clock: clock.now())
        let readLease = EpisodeLease(ledger: owner, episodeID: "read-link", clock: clock)
        let readWork = try readLease.prepare(kind: .sourceRead, resources: EpisodeResources(rawSourceBytes: 4), adapterIdentity: "synthetic-read-link", snapshot: Data("{\"messages\":[]}".utf8))
        checks["read_episode_invocation_link_denied"] = rejected {
            _ = try owner.beginInvocation(invocationID: "forbidden-read-invocation", conversationID: chat.id,
                turnID: "borrowed-turn", humanEventID: "borrowed-human", assistantEventID: "forbidden-read-assistant",
                providerIdentity: "native:synthetic", requestBody: Data("{\"messages\":[]}".utf8), episodeID: "read-link", episodeWorkID: readWork.id)
        }
        checks["read_episode_denied_invocation_publishes_no_journal_or_source"] = try owner.invocation(id: "forbidden-read-invocation") == nil
            && owner.events(conversationID: chat.id).count == 1
        checks["read_episode_chat_origin_cannot_reuse_read_identity"] = rejected(.conflict) {
            _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "origin-change", humanEventID: "origin-change-human",
                episodeID: "read-link", text: "Synthetic refused chat capture", limits: .init(), clock: clock.now())
        }
        checks["read_episode_denied_chat_origin_does_not_capture"] = try owner.events(conversationID: chat.id).count == 1
        _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "chat-origin", humanEventID: "chat-origin-human",
            episodeID: "chat-origin", text: "Synthetic accepted chat capture", limits: .init(), clock: clock.now())
        checks["read_episode_read_origin_cannot_reuse_chat_identity"] = rejected(.conflict) {
            _ = try owner.beginLocalReadEpisode(episodeID: "chat-origin", projectID: "project-a", binding: binding, limits: .init(), clock: clock.now())
        }
        return checks
    }
    private static func binaryIdentityChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-binary-identities-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let clock = Clock(), composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
        var checks: [String: Bool] = [
            "episode_unicode_fixture_has_canonical_equivalence_distinct_bytes": composed == decomposed && !episodeIdentifierEqual(composed, decomposed),
            "episode_unicode_optional_identity_distinct_bytes": !episodeIdentifierEqual(Optional(composed), Optional(decomposed)) && episodeIdentifierEqual(nil, nil)
        ]
        let bindingA = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe,
            requestID: "request-" + composed, descriptorVersion: "unicode-identity-v1", descriptorSHA256: String(repeating: "a", count: 64))
        let bindingB = EpisodeLocalReadBinding(initiator: bindingA.initiator, purpose: bindingA.purpose,
            requestID: "request-" + decomposed, descriptorVersion: bindingA.descriptorVersion, descriptorSHA256: bindingA.descriptorSHA256)
        checks["episode_unicode_binding_and_origin_equality_preserves_bytes"] = bindingA != bindingB && EpisodeOrigin.localRead(bindingA) != .localRead(bindingB)
            && EpisodeOrigin.chat(conversationID: composed, turnID: "t", humanEventID: "h") != .chat(conversationID: decomposed, turnID: "t", humanEventID: "h")
        let episodeA = "read-" + composed, episodeB = "read-" + decomposed
        let receiptA = try owner!.beginLocalReadEpisode(episodeID: episodeA, projectID: composed, binding: bindingA, limits: .init(), clock: clock.now())
        let receiptB = try owner!.beginLocalReadEpisode(episodeID: episodeB, projectID: decomposed, binding: bindingB, limits: .init(), clock: clock.now())
        checks["episode_unicode_request_index_preserves_distinct_byte_ids"] = receiptA != receiptB
            && episodeIdentifierEqual(receiptA.id, episodeA) && episodeIdentifierEqual(receiptB.id, episodeB)
            && episodeIdentifierEqual(receiptA.projectID, composed) && episodeIdentifierEqual(receiptB.projectID, decomposed)
        checks["episode_unicode_exact_initiation_replay_idempotent"] = try owner!.beginLocalReadEpisode(episodeID: episodeA, projectID: composed, binding: bindingA, limits: .init(), clock: clock.now()) == receiptA
        checks["episode_unicode_changed_project_bytes_replay_conflicts"] = rejected(.conflict) {
            _ = try owner!.beginLocalReadEpisode(episodeID: episodeA, projectID: decomposed, binding: bindingA, limits: .init(), clock: clock.now())
        }
        checks["episode_unicode_changed_request_bytes_replay_conflicts"] = rejected(.conflict) {
            _ = try owner!.beginLocalReadEpisode(episodeID: episodeA, projectID: composed, binding: bindingB, limits: .init(), clock: clock.now())
        }
        var unicodeLimitsA = EpisodeLimits(); unicodeLimitsA.version = composed
        var unicodeLimitsB = EpisodeLimits(); unicodeLimitsB.version = decomposed
        let limitsBinding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe,
            requestID: "limits-request", descriptorVersion: "unicode-identity-v1", descriptorSHA256: String(repeating: "b", count: 64))
        _ = try owner!.beginLocalReadEpisode(episodeID: "unicode-limits", projectID: composed, binding: limitsBinding, limits: unicodeLimitsA, clock: clock.now())
        checks["episode_unicode_changed_limit_version_bytes_replay_conflicts"] = unicodeLimitsA != unicodeLimitsB && rejected(.conflict) {
            _ = try owner!.beginLocalReadEpisode(episodeID: "unicode-limits", projectID: composed, binding: limitsBinding, limits: unicodeLimitsB, clock: clock.now())
        }
        let workA = try owner!.reserveEpisodeWork(episodeID: episodeA, request: EpisodeWorkRequest(id: "work-" + composed, parentID: nil,
            kind: .retrieval, resources: EpisodeResources(memoryOperations: 1, rawSourceBytes: 8), adapterIdentity: composed, snapshot: nil, inputTokensKnown: true), clock: clock.now())
        let workB = try owner!.reserveEpisodeWork(episodeID: episodeB, request: EpisodeWorkRequest(id: "work-" + decomposed, parentID: nil,
            kind: .retrieval, resources: EpisodeResources(memoryOperations: 1, rawSourceBytes: 12), adapterIdentity: decomposed, snapshot: nil, inputTokensKnown: true), clock: clock.now())
        checks["episode_unicode_changed_adapter_bytes_work_replay_conflicts"] = rejected(.conflict) {
            _ = try owner!.reserveEpisodeWork(episodeID: episodeA, request: EpisodeWorkRequest(id: workA.id, parentID: nil,
                kind: .retrieval, resources: workA.request.resources, adapterIdentity: decomposed, snapshot: nil, inputTokensKnown: true), clock: clock.now())
        }
        checks["episode_unicode_cross_episode_reservation_replay_denied"] = rejected(.conflict) {
            _ = try owner!.reserveEpisodeWork(episodeID: episodeB, request: workA.request, clock: clock.now())
        }
        checks["episode_unicode_cross_episode_settlement_denied"] = rejected {
            _ = try owner!.settleEpisodeWork(episodeID: episodeB, operationID: workA.id,
                settlement: EpisodeWorkSettlement(receiptID: "cross-unicode-receipt", outcome: .cancelledBeforeDispatch, observed: nil, evidence: nil), clock: clock.now())
        }
        checks["episode_unicode_denied_linkage_preserves_separate_reservations"] = try owner!.episodeReceipt(id: episodeA, clock: clock.now()).held.rawSourceBytes == 8
            && owner!.episodeReceipt(id: episodeB, clock: clock.now()).held.rawSourceBytes == 12
        checks["episode_unicode_cross_episode_work_read_denied"] = rejected(.conflict) {
            _ = try owner!.episodeWork(episodeID: episodeB, operationID: workA.id)
        }
        checks["episode_unicode_cross_episode_work_arm_denied"] = rejected {
            _ = try owner!.armEpisodeWork(episodeID: episodeB, operationID: workA.id, expectedRevision: workA.revision, clock: clock.now())
        }
        checks["episode_unicode_cross_episode_parent_denied"] = rejected {
            _ = try owner!.reserveEpisodeWork(episodeID: episodeB, request: EpisodeWorkRequest(id: "bad-unicode-parent", parentID: workA.id,
                kind: .sourceRead, resources: .zero, adapterIdentity: "synthetic", snapshot: nil, inputTokensKnown: true), clock: clock.now())
        }
        var handoffs = 0
        checks["episode_unicode_cross_episode_handoff_denied_before_start"] = rejected {
            _ = try owner!.performEpisodeHandoff(episodeID: episodeB, operationID: workA.id, expectedRevision: workA.revision, clock: clock.now()) { handoffs += 1 }
        } && handoffs == 0
        for work in [workA, workB] {
            _ = try owner!.armEpisodeWork(episodeID: work.episodeID, operationID: work.id, expectedRevision: work.revision, clock: clock.now())
            _ = try owner!.settleEpisodeWork(episodeID: work.episodeID, operationID: work.id,
                settlement: EpisodeWorkSettlement(receiptID: "receipt-" + composed, outcome: .completed, observed: nil, evidence: nil), clock: clock.now())
        }
        let secondWork = try owner!.reserveEpisodeWork(episodeID: episodeA, request: EpisodeWorkRequest(id: "second-unicode-work", parentID: nil,
            kind: .retrieval, resources: EpisodeResources(memoryOperations: 1, rawSourceBytes: 3), adapterIdentity: "synthetic", snapshot: nil, inputTokensKnown: true), clock: clock.now())
        _ = try owner!.armEpisodeWork(episodeID: episodeA, operationID: secondWork.id, expectedRevision: secondWork.revision, clock: clock.now())
        _ = try owner!.settleEpisodeWork(episodeID: episodeA, operationID: secondWork.id,
            settlement: EpisodeWorkSettlement(receiptID: "receipt-" + decomposed, outcome: .completed, observed: nil, evidence: nil), clock: clock.now())
        checks["episode_unicode_receipt_ids_preserve_distinct_byte_identity"] = try episodeIdentifierEqual(owner!.episodeWork(episodeID: episodeA, operationID: workA.id)?.receiptID, "receipt-" + composed)
            && episodeIdentifierEqual(owner!.episodeWork(episodeID: episodeA, operationID: secondWork.id)?.receiptID, "receipt-" + decomposed)
        checks["episode_unicode_journal_totals_do_not_merge_equivalent_ids"] = try owner!.episodeReceipt(id: episodeA, clock: clock.now()).charged.rawSourceBytes == 11
            && owner!.episodeReceipt(id: episodeB, clock: clock.now()).charged.rawSourceBytes == 12
        checks["episode_unicode_constructed_read_journal_validates"] = try validate(directory)
        let chat = try owner!.createConversation(projectID: composed, title: "Synthetic binary chat identity")
        let humanTextA = "Synthetic " + composed, humanTextB = "Synthetic " + decomposed
        _ = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: composed, humanEventID: "human-" + composed,
            episodeID: "chat-unicode", text: humanTextA, limits: .init(), clock: clock.now())
        checks["episode_unicode_changed_chat_turn_bytes_replay_conflicts"] = rejected(.conflict) {
            _ = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: decomposed, humanEventID: "human-" + composed,
                episodeID: "chat-unicode", text: humanTextA, limits: .init(), clock: clock.now())
        }
        checks["episode_unicode_changed_accepted_payload_bytes_replay_conflicts"] = rejected(.conflict) {
            _ = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: composed, humanEventID: "human-" + composed,
                episodeID: "chat-unicode", text: humanTextB, limits: .init(), clock: clock.now())
        }
        checks["episode_unicode_unmetered_invocation_cannot_alias_human_turn"] = rejected {
            _ = try owner!.beginInvocation(invocationID: "unicode-bad-invocation", conversationID: chat.id, turnID: decomposed,
                humanEventID: "human-" + composed, assistantEventID: "bad-unicode-assistant", providerIdentity: "native:synthetic", requestBody: Data("{}".utf8))
        }
        checks["episode_unicode_denied_replays_preserve_single_capture"] = try owner!.events(conversationID: chat.id).count == 1
        owner = nil; owner = try MemoryStore(directory: directory)
        checks["episode_unicode_reopen_preserves_separate_accounting"] = try owner!.episodeReceipt(id: episodeA, clock: clock.now()).charged.rawSourceBytes == 11
            && owner!.episodeReceipt(id: episodeB, clock: clock.now()).charged.rawSourceBytes == 12
        checks["episode_unicode_recovered_journal_validates"] = try validate(directory)
        owner = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let alteredOrigin = try encoder.encode(EpisodeOrigin.chat(conversationID: chat.id, turnID: decomposed, humanEventID: "human-" + composed))
        let alteredDigest = try MemoryStore.episodeOriginDigest(projectID: composed, originJSON: alteredOrigin)
        try inspect(directory) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "UPDATE episodes SET origin_json=?,origin_digest=? WHERE id='chat-unicode'", -1, &statement, nil) == SQLITE_OK, let statement else { throw MemoryError.database("could not prepare synthetic Unicode origin corruption") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            alteredOrigin.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(alteredOrigin.count), transient) }
            _ = sqlite3_bind_text(statement, 2, alteredDigest, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw MemoryError.database("could not corrupt synthetic Unicode origin") }
        }
        checks["episode_unicode_chat_origin_column_alias_archive_rejected"] = rejected { _ = try validate(directory) }
        owner = try MemoryStore(directory: directory)
        checks["episode_unicode_chat_origin_column_alias_runtime_rejected"] = rejected { _ = try owner!.episodeReceipt(id: "chat-unicode", clock: clock.now()) }
        return checks
    }
    private static func unicodeLegacyMigrationChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-unicode-schema-three-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let clock = Clock(), identities = ["caf\u{00e9}", "cafe\u{0301}"]
        for (index, identity) in identities.enumerated() {
            let chat = try owner!.createConversation(projectID: identity, title: "Synthetic Unicode legacy migration")
            _ = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: identity, humanEventID: "human-" + identity,
                episodeID: identity, text: "Synthetic legacy " + identity, limits: .init(), clock: clock.now())
            let work = try owner!.reserveEpisodeWork(episodeID: identity, request: EpisodeWorkRequest(id: "work-" + identity, parentID: nil,
                kind: .answer, resources: EpisodeResources(inputTokens: 3 + index, outputTokens: 2 + index, modelCalls: 1),
                adapterIdentity: "synthetic-unicode-legacy", snapshot: Data("{}".utf8), inputTokensKnown: true), clock: clock.now())
            _ = try owner!.armEpisodeWork(episodeID: identity, operationID: work.id, expectedRevision: work.revision, clock: clock.now())
        }
        owner = nil
        try downgradeSyntheticChatParentToThree(directory)
        var checks = ["episode_unicode_schema_three_journal_validates_binary_ids": try validate(directory)]
        owner = try MemoryStore(directory: directory)
        let first = try owner!.episodeReceipt(id: identities[0], clock: clock.now()), second = try owner!.episodeReceipt(id: identities[1], clock: clock.now())
        checks["episode_unicode_schema_three_migration_preserves_exact_chat_origins"] = episodeIdentifierEqual(first.id, identities[0])
            && episodeIdentifierEqual(first.projectID, identities[0]) && episodeIdentifierEqual(first.turnID, identities[0])
            && episodeIdentifierEqual(first.humanEventID, "human-" + identities[0]) && episodeIdentifierEqual(second.id, identities[1])
            && episodeIdentifierEqual(second.projectID, identities[1]) && episodeIdentifierEqual(second.turnID, identities[1])
            && episodeIdentifierEqual(second.humanEventID, "human-" + identities[1])
        checks["episode_unicode_schema_three_migration_keeps_accounting_separate"] = first.charged.inputTokens == 3 && first.held.outputTokens == 2
            && second.charged.inputTokens == 4 && second.held.outputTokens == 3
        checks["episode_unicode_schema_four_migrated_journal_validates_binary_ids"] = try validate(directory)
        return checks
    }
    private static func malformedStoredOriginChecks() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for mutation in ["duplicateOriginVersion", "duplicateBindingVersion", "changedProject"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-origin-corruption-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var owner: MemoryStore? = try MemoryStore(directory: directory)
            let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe, requestID: "origin-fixture-request",
                descriptorVersion: "synthetic-origin-v1", descriptorSHA256: String(repeating: "0", count: 64))
            _ = try owner!.beginLocalReadEpisode(episodeID: "origin-fixture", projectID: "project-a", binding: binding,
                limits: .init(), clock: Clock().now())
            owner = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let originJSON = try encoder.encode(EpisodeOrigin.localRead(binding))
            var corrupted = String(decoding: originJSON, as: UTF8.self)
            if mutation == "duplicateOriginVersion" {
                corrupted = corrupted.replacingOccurrences(of: "\"version\":\"episode-origin-v1\"", with: "\"version\":\"episode-origin-v1\",\"version\":\"episode-origin-v1\"")
            }
            if mutation == "duplicateBindingVersion" {
                corrupted = corrupted.replacingOccurrences(of: "\"version\":\"local-read-v1\"", with: "\"version\":\"local-read-v1\",\"version\":\"local-read-v1\"")
            }
            let corruptedBytes = Data(corrupted.utf8)
            let digest = try MemoryStore.episodeOriginDigest(projectID: "project-a", originJSON: corruptedBytes)
            try inspect(directory) { database in
                if mutation == "changedProject" {
                    guard sqlite3_exec(database, "UPDATE episodes SET project_id='project-b' WHERE id='origin-fixture'", nil, nil, nil) == SQLITE_OK else { throw MemoryError.database("synthetic project corruption failed") }
                } else {
                    var statement: OpaquePointer?
                    guard sqlite3_prepare_v2(database, "UPDATE episodes SET origin_json=?,origin_digest=? WHERE id='origin-fixture'", -1, &statement, nil) == SQLITE_OK, let statement else { throw MemoryError.database("synthetic origin corruption preparation failed") }
                    defer { sqlite3_finalize(statement) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    corruptedBytes.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(corruptedBytes.count), transient) }
                    _ = sqlite3_bind_text(statement, 2, digest, -1, transient)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw MemoryError.database("synthetic origin corruption failed") }
                }
            }
            checks["read_episode_stored_origin_" + mutation + "_archive_rejects"] = rejected { _ = try validate(directory) }
            checks["read_episode_stored_origin_" + mutation + "_owner_rejects"] = rejected { _ = try MemoryStore(directory: directory) }
        }
        return checks
    }
    /// The schema-3 parent is deliberately frozen, independent of current SQL.
    static func downgradeSyntheticChatParentToThree(_ directory: URL) throws {
        try inspect(directory) { database in
            let background = try scalar(database, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='background_index_work'")
            if background == "1" {
                guard try scalar(database, "SELECT count(*) FROM background_index_work") == "0",
                      try scalar(database, "SELECT count(*) FROM background_index_windows") == "0" else {
                    throw MemoryError.database("historical fixture contains background work")
                }
            }
            let sql = """
                PRAGMA foreign_keys=OFF;
                BEGIN IMMEDIATE;
                \((AuthorityBindingJournal.tableNames + AuthorityStateKernel.tableNames).map { "DROP TABLE IF EXISTS " + $0 + ";" }.joined())
                DROP TABLE IF EXISTS background_index_work;
                DROP TABLE IF EXISTS background_index_windows;
                CREATE TABLE episodes_three (
                  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                  project_id TEXT NOT NULL, turn_id TEXT NOT NULL, human_event_id TEXT NOT NULL UNIQUE REFERENCES events(id),
                  limits_json BLOB NOT NULL CHECK(length(limits_json)>0 AND length(limits_json)<=65536),
                  limits_digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','completed','failed','cancelled','interrupted','deadlineExceeded','budgetExceeded')),
                  revision INTEGER NOT NULL CHECK(revision>=0), clock_domain TEXT NOT NULL,
                  created_ticks INTEGER NOT NULL CHECK(created_ticks>0), deadline_ticks INTEGER NOT NULL CHECK(deadline_ticks>created_ticks),
                  last_ticks INTEGER NOT NULL CHECK(last_ticks>=created_ticks), created_utc REAL NOT NULL,
                  terminal_reason TEXT NOT NULL DEFAULT '', CHECK((state='active' AND terminal_reason='') OR (state!='active' AND terminal_reason!=''))
                );
                INSERT INTO episodes_three SELECT id,conversation_id,project_id,turn_id,human_event_id,limits_json,limits_digest,state,revision,clock_domain,created_ticks,deadline_ticks,last_ticks,created_utc,terminal_reason FROM episodes;
                DROP TABLE episodes;
                ALTER TABLE episodes_three RENAME TO episodes;
                PRAGMA user_version=3;
                COMMIT;
                """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MemoryError.database("could not construct frozen schema-three parent") }
        }
    }
    private static func schemaThreeMigrationChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-episode-v3-" + UUID().uuidString)
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("boros-episode-v4-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: fresh) }
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let clock = Clock()
        let chat = try owner!.createConversation(projectID: "migration-project", title: "Synthetic schema-three migration")
        let accepted = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "migration-turn", humanEventID: "migration-human",
            episodeID: "migration-episode", text: "Synthetic accepted migration input", limits: .init(), clock: clock.now())
        let body = Data("{\"messages\":[],\"max_tokens\":5}".utf8)
        let work = try owner!.reserveEpisodeWork(episodeID: accepted.id, request: EpisodeWorkRequest(id: "migration-work", parentID: nil,
            kind: .answer, resources: EpisodeResources(inputTokens: 9, outputTokens: 5, modelCalls: 1, httpAttempts: 1),
            adapterIdentity: "synthetic-migration", snapshot: body, inputTokensKnown: true), clock: clock.now())
        _ = try owner!.beginInvocation(invocationID: "migration-invocation", conversationID: chat.id, turnID: "migration-turn", humanEventID: "migration-human",
            assistantEventID: "migration-assistant", providerIdentity: "native:synthetic", requestBody: body, episodeID: accepted.id, episodeWorkID: work.id)
        _ = try owner!.armEpisodeWork(episodeID: accepted.id, operationID: work.id, expectedRevision: work.revision, clock: clock.now())
        _ = try owner!.appendInvocationChunk(invocationID: "migration-invocation", sequence: 0, text: "Synthetic migration partial")
        owner = nil
        try downgradeSyntheticChatParentToThree(directory)
        var checks: [String: Bool] = ["episode_schema_three_archive_validator_remains_read_only": try validate(directory)]
        for stage in ["beforeParentReplacement", "afterParentReplacement", "beforeCommit"] {
            let failed = rejected { _ = try MemoryStore(directory: directory, episodeMigrationCheckpoint: { checkpoint in
                if checkpoint == stage { throw EpisodeBudgetError.invalid }
            }) }
            checks["episode_schema_three_" + stage + "_rollback_complete"] = try failed && inspect(directory) {
                try scalar($0, "PRAGMA user_version") == "3" && scalar($0, "SELECT count(*) FROM sqlite_master WHERE name='episodes_v4'") == "0"
                    && scalar($0, "SELECT count(*) FROM episodes WHERE id='migration-episode'") == "1"
                    && scalar($0, "SELECT count(*) FROM episode_work WHERE id='migration-work'") == "1"
            }
        }
        owner = try MemoryStore(directory: directory)
        let migrated = try owner!.episodeReceipt(id: accepted.id, clock: clock.now())
        let migratedWork = try owner!.episodeWork(episodeID: accepted.id, operationID: work.id)
        checks["episode_schema_three_chat_origin_preserves_binding_deadline"] = migrated.origin == accepted.origin && migrated.deadlineNanoseconds == accepted.deadlineNanoseconds
        checks["episode_schema_three_migration_preserves_armed_accounting_snapshot"] = migratedWork?.charged.inputTokens == 9 && migratedWork?.held.outputTokens == 5 && migratedWork?.request.snapshot == body && migratedWork?.state == .outcomeUnknown
        checks["episode_schema_three_migration_recovers_linked_partial"] = try owner!.invocation(id: "migration-invocation")?.finalStatus == .partial
            && owner!.events(conversationID: chat.id).last?.text == "Synthetic migration partial"
        let freshOwner = try MemoryStore(directory: fresh)
        checks["episode_schema_three_migration_fresh_canonical_parent_identical"] = try inspect(directory) { migratedDB in
            try inspect(fresh) { freshDB in try scalar(migratedDB, "SELECT sql FROM sqlite_master WHERE name='episodes'") == scalar(freshDB, "SELECT sql FROM sqlite_master WHERE name='episodes'") }
        }
        checks["episode_schema_three_migration_foreign_keys_intact"] = try inspect(directory) { try scalar($0, "SELECT count(*) FROM pragma_foreign_key_check") == "0" }
        checks["episode_schema_three_migration_archive_validator_accepts"] = try validate(directory)
        withExtendedLifetime(freshOwner) {}
        return checks
    }
    private static func providerQuarantineChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-provider-quarantine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(), endpoint = "http://localhost:11234/v1/chat/completions"
        let pinned = endpoint + "|" + Qwen38TextRendering.modelID + "|" + Qwen38TextRendering.serverVersion + "|" + Qwen38TextRendering.templateDigest
        let legacy = "mlx-serve-qwen38-text-v1|" + pinned + "|1700000000|thinking=false"
        func observed(cap: Int = 32768, capabilities: [String] = ["chat", "streaming"], thinking: Bool = false,
            address: String? = nil) throws -> String {
            let identity = ProviderObservedModelIdentity(version: ProviderObservedModelIdentity.versionValue,
                instanceIdentity: "unobservable", modelID: Qwen38TextRendering.modelID, owner: "mlx-serve", engine: "mlx",
                architecture: "qwen4_exp", modelContextLimit: cap, maxModelLength: 32768, capabilities: capabilities,
                inputModalities: ["text"], serverVersion: Qwen38TextRendering.serverVersion, templateDigest: Qwen38TextRendering.templateDigest)
            return ProviderObservedModelIdentity.adapterIdentity(endpoint: address ?? endpoint,
                metadataDigest: SHA256.hash(data: try identity.canonicalData()).map { String(format: "%02x", $0) }.joined(), thinking: thinking)
        }
        let original = try observed(), capacityChange = try observed(cap: 16384), capabilityChange = try observed(capabilities: ["chat", "reasoning", "streaming"])
        let resources = EpisodeResources(inputTokens: 9, outputTokens: 5, modelCalls: 1, httpAttempts: 1)
        var checks: [String: Bool] = [:]
        var conversationID = ""
        do {
            let store = try MemoryStore(directory: directory)
            let chat = try store.createConversation(projectID: "synthetic-quarantine-project", title: "Synthetic provider quarantine")
            conversationID = chat.id
            func begin(_ id: String) throws -> EpisodeLease {
                _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "turn-" + id, humanEventID: "human-" + id,
                    episodeID: id, text: "Synthetic quarantine request " + id, limits: .init(), clock: clock.now())
                return EpisodeLease(ledger: store, episodeID: id, clock: clock)
            }
            func violated(_ id: String, adapter: String) throws -> Bool {
                let lease = try begin(id), prepared = try lease.prepare(kind: .calibration, resources: resources, adapterIdentity: adapter)
                let submitted = try lease.dispatch(prepared) {}
                return rejected(.adapterViolation) {
                    _ = try lease.settle(submitted, outcome: .completed,
                        observed: EpisodeResources(inputTokens: 10, outputTokens: 1, modelCalls: 1, httpAttempts: 1))
                }
            }
            checks["episode_quarantine_generic_lookalike_records_violation"] = try violated("lookalike", adapter: "mlx-serve-qwen38-text-v1|" + pinned + "|01|thinking=false")
            let pendingArm = try begin("pending-arm"), pendingHandoff = try begin("pending-handoff"), armedHandoff = try begin("armed-handoff")
            let first = try pendingArm.prepare(kind: .calibration, resources: resources, adapterIdentity: original)
            let second = try pendingHandoff.prepare(kind: .calibration, resources: resources, adapterIdentity: capacityChange)
            let third = try armedHandoff.arm(armedHandoff.prepare(kind: .calibration, resources: resources, adapterIdentity: capabilityChange))
            checks["episode_quarantine_malformed_lookalike_does_not_block_family"] = first.state == .prepared && second.state == .prepared && third.state == .dispatchArmed
            checks["episode_quarantine_legacy_count_violation_recorded"] = try violated("legacy-violation", adapter: legacy)
            for (name, adapter) in [("same_observation", original), ("capacity_change", capacityChange), ("capability_change", capabilityChange),
                ("legacy_epoch_change", "mlx-serve-qwen38-text-v1|" + pinned + "|1700000001|thinking=false")] {
                let lease = try begin("blocked-" + name)
                checks["episode_quarantine_blocks_" + name] = rejected(.adapterViolation) {
                    _ = try lease.prepare(kind: .calibration, resources: resources, adapterIdentity: adapter)
                }
            }
            checks["episode_quarantine_rechecks_prepared_before_arm"] = rejected(.adapterViolation) { _ = try pendingArm.arm(first) }
            var starts = 0
            checks["episode_quarantine_rechecks_prepared_before_handoff"] = rejected(.adapterViolation) { _ = try pendingHandoff.dispatch(second) { starts += 1 } } && starts == 0
            checks["episode_quarantine_rechecks_armed_before_handoff"] = rejected(.adapterViolation) { _ = try armedHandoff.dispatch(third) { starts += 1 } } && starts == 0
            let preparedReceipt = try store.episodeReceipt(id: pendingArm.episodeID, clock: clock.now())
            let armedReceipt = try store.episodeReceipt(id: armedHandoff.episodeID, clock: clock.now())
            checks["episode_quarantine_denied_prepared_releases_only_unused_hold"] = preparedReceipt.state == .failed && preparedReceipt.charged == .zero && preparedReceipt.held == .zero
            checks["episode_quarantine_denied_armed_retains_conservative_charge"] = armedReceipt.state == .failed
                && armedReceipt.charged == EpisodeResources(inputTokens: 9, modelCalls: 1, httpAttempts: 1) && armedReceipt.held == EpisodeResources(outputTokens: 5)
            for (name, adapter) in [("other_thinking", try observed(thinking: true)), ("other_endpoint", try observed(address: "http://localhost:11235/v1/chat/completions"))] {
                let lease = try begin(name)
                checks["episode_quarantine_preserves_" + name + "_scope"] = try lease.prepare(kind: .calibration, resources: resources, adapterIdentity: adapter).state == .prepared
                _ = try lease.finish(reason: .cancelled)
            }
            checks["episode_quarantine_journal_preserves_full_historical_keys"] = try validate(directory)
        }
        let reopened = try MemoryStore(directory: directory)
        _ = try reopened.acceptRequestAndBeginEpisode(conversationID: conversationID, turnID: "reopen-turn", humanEventID: "reopen-human",
            episodeID: "reopen-episode", text: "Synthetic reopen quarantine request", limits: .init(), clock: clock.now())
        let lease = EpisodeLease(ledger: reopened, episodeID: "reopen-episode", clock: clock)
        checks["episode_quarantine_family_survives_reopen"] = rejected(.adapterViolation) {
            _ = try lease.prepare(kind: .calibration, resources: resources, adapterIdentity: capabilityChange)
        }
        return checks
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
