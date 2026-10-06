import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Isolated fixed synthetic authority checks. Results contain names and booleans
/// only; private source text, policy values and operation payloads are never logged.
enum AuthorityStateChecks {
    static func run() throws -> [String: Bool] {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CheckError.invalid }
        let temporaryRoot = String(cString: resolved); free(resolved)
        let scratch = URL(fileURLWithPath: temporaryRoot, isDirectory: true).appendingPathComponent("boros-authority-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var checks: [String: Bool] = [:]
        var stage = "initial_state"
        do {
        let fixture = try Fixture(directory: scratch.appendingPathComponent("lifecycle"))
        let initial = try fixture.snapshot()
        checks["authority_new_store_has_nonempty_owner_and_store_identity"] = !initial.ownerID.isEmpty && !initial.storeID.isEmpty
        checks["authority_new_store_has_no_tasks_policies_or_bindings"] = initial.tasks.isEmpty && initial.policies.isEmpty && initial.bindings.isEmpty
        checks["authority_startup_advances_control_epoch"] = initial.controlEpoch > 0

        for origin in [AuthorityOrigin.imported, .model, .quoted, .document, .subagent] {
            let before = try fixture.snapshotBytes()
            checks["authority_" + origin.rawValue + "_cannot_create_task"] = rejects {
                _ = try fixture.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-denied-" + origin.rawValue,
                    expectedRevision: initial.revision, operation: .taskNew, taskID: "synthetic-denied-task",
                    projectID: fixture.project, conversationID: fixture.chat.id),
                    authority: AuthorityContext(ownerID: initial.ownerID, origin: origin), now: 0)
            }
            checks["authority_" + origin.rawValue + "_rejection_changes_no_state"] = try fixture.snapshotBytes() == before
        }
        checks["authority_wrong_owner_cannot_create_task"] = rejects {
            _ = try fixture.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-wrong-owner",
                expectedRevision: initial.revision, operation: .taskNew, taskID: "synthetic-wrong-owner-task", projectID: fixture.project),
                authority: AuthorityContext(ownerID: "synthetic-other-owner", origin: .humanHost), now: 0)
        }

        let request = AuthorityOperationRequest(requestID: "synthetic-new-task", expectedRevision: initial.revision,
            operation: .taskNew, taskID: "synthetic-task-a", projectID: fixture.project, conversationID: fixture.chat.id)
        let firstReceipt = try fixture.store!.applyAuthorityOperation(request: request, authority: fixture.authority(), now: 100)
        let afterFirst = try fixture.snapshot()
        checks["authority_human_new_task_persists_task_and_binding"] = afterFirst.tasks.count == 1 && afterFirst.bindings.count == 1
        checks["authority_task_mutation_advances_revision_and_epoch"] = afterFirst.revision > initial.revision && afterFirst.controlEpoch > initial.controlEpoch
        let replay = try fixture.store!.applyAuthorityOperation(request: request, authority: fixture.authority(), now: 999)
        checks["authority_exact_request_retry_returns_original_receipt"] = try canonical(firstReceipt) == canonical(replay)
        let afterReplay = try fixture.snapshot()
        checks["authority_exact_request_retry_advances_clock_without_revising_authority"] = afterReplay.timeHighWater == 999
            && afterReplay.revision == afterFirst.revision && afterReplay.controlEpoch == afterFirst.controlEpoch
        checks["authority_exact_request_retry_preserves_records"] = try canonical(afterReplay.tasks) == canonical(afterFirst.tasks)
            && canonical(afterReplay.bindings) == canonical(afterFirst.bindings)
        checks["authority_reused_request_id_different_operation_refused"] = rejects {
            _ = try fixture.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: request.requestID,
                expectedRevision: initial.revision, operation: .taskNew, taskID: "synthetic-task-b", projectID: fixture.project),
                authority: fixture.authority(), now: 100)
        }
        checks["authority_stale_revision_refused"] = rejects {
            _ = try fixture.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-stale-revision",
                expectedRevision: initial.revision, operation: .taskNew, taskID: "synthetic-task-b", projectID: fixture.project),
                authority: fixture.authority(), now: 100)
        }
        checks["authority_failed_retry_and_stale_cas_are_atomic"] = try fixture.snapshotBytes() == canonical(afterReplay)
        var encodedRequest = try JSONSerialization.jsonObject(with: canonical(request)) as! [String: Any]
        encodedRequest["origin"] = "humanHost"
        let forgedOriginBytes = try JSONSerialization.data(withJSONObject: encodedRequest, options: [.sortedKeys, .withoutEscapingSlashes])
        checks["authority_request_json_cannot_supply_human_origin"] = rejects {
            _ = try JSONDecoder().decode(AuthorityOperationRequest.self, from: forgedOriginBytes)
        }
        encodedRequest.removeValue(forKey: "origin"); encodedRequest["ownerID"] = initial.ownerID
        let forgedOwnerBytes = try JSONSerialization.data(withJSONObject: encodedRequest, options: [.sortedKeys, .withoutEscapingSlashes])
        checks["authority_request_json_cannot_supply_owner_capability"] = rejects {
            _ = try JSONDecoder().decode(AuthorityOperationRequest.self, from: forgedOwnerBytes)
        }

        stage = "policy_cases"; try policyChecks(fixture, checks: &checks)
        stage = "lifecycle_cases"; try lifecycleChecks(fixture, checks: &checks)
        stage = "independent_cases"; try independentChecks(scratch: scratch, checks: &checks)
        checks["authority_state_run_completed"] = true
        return checks
        } catch {
            checks["authority_state_run_completed"] = false
            checks["authority_failure_stage_" + stage] = false
            if let detail = error as? CheckError {
                switch detail {
                case .invalid: checks["authority_failure_test_fixture"] = false
                case .operation(let operation, let serial, let code):
                    checks["authority_failure_operation_" + operation.rawValue + "_" + String(serial) + "_" + code] = false
                }
            } else if let detail = error as? AuthorityStateError { checks["authority_failure_kernel_" + detail.failureCode] = false }
            else { checks["authority_failure_other_fixed_code"] = false }
            return checks
        }
    }

    private final class Fixture {
        let directory: URL
        let project = "synthetic-authority-project"
        let chat: StoredConversation
        let source: MemoryEvent
        var store: MemoryStore?
        private var serial = 0
        init(directory: URL) throws {
            self.directory = directory
            let owner = try MemoryStore(directory: directory)
            store = owner
            chat = try owner.createConversation(projectID: project, title: "Synthetic authority")
            source = try owner.append(conversationID: chat.id, role: .human,
                text: "Synthetic source café e\u{301} 日本語 retained exactly", status: .complete,
                turnID: "synthetic-source-turn", eventID: "synthetic-authority-source")
        }
        func snapshot() throws -> AuthorityStateSnapshot { try store!.authorityStateSnapshot() }
        func snapshotBytes() throws -> Data { try canonical(snapshot()) }
        func authority(_ origin: AuthorityOrigin = .humanHost) throws -> AuthorityContext {
            AuthorityContext(ownerID: try snapshot().ownerID, origin: origin)
        }
        @discardableResult func apply(_ operation: AuthorityOperation, task: String? = nil,
            conversation: String? = nil, policyID: String? = nil, policy: AuthorityPolicyDefinition? = nil,
            supersedes: [String] = [], taskRevision: Int? = nil, policyRevision: Int? = nil, now: Int64 = 1000) throws -> AuthorityOperationReceipt {
            serial += 1
            let state = try snapshot()
            let currentTaskRevision = taskRevision ?? state.tasks.first { record in task.map { episodeIdentifierEqual($0, record.id) } ?? false }?.revision
            let currentPolicyRevision = policyRevision ?? state.policies.first { record in policyID.map { episodeIdentifierEqual($0, record.id) } ?? false }?.revision
            do { return try store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-operation-\(serial)",
                expectedRevision: state.revision, operation: operation, taskID: task,
                projectID: project, conversationID: conversation, policyID: policyID,
                expectedTaskRevision: currentTaskRevision, expectedPolicyRevision: currentPolicyRevision,
                policy: policy, supersedesPolicyIDs: supersedes), authority: authority(), now: now)
            } catch {
                let code = (error as? AuthorityStateError)?.failureCode ?? "other"
                throw CheckError.operation(operation, serial, code)
            }
        }
    }

    private static func policyChecks(_ fixture: Fixture, checks: inout [String: Bool]) throws {
        let global = AuthorityPolicyScope(kind: .global)
        let project = AuthorityPolicyScope(kind: .project, projectID: fixture.project)
        let task = AuthorityPolicyScope(kind: .task, projectID: fixture.project, taskID: "synthetic-task-a")
        let source = AuthoritySourceSpan(eventID: fixture.source.id, projectID: fixture.project,
            conversationID: fixture.chat.id, offset: 0, byteLength: fixture.source.byteCount,
            sourceSHA256: fixture.source.digest, excerptSHA256: fixture.source.digest)
        func definition(_ scope: AuthorityPolicyScope, _ value: String, until: Bool = false,
            effective: Int64 = 0, expiry: Int64? = nil, sources: [AuthoritySourceSpan] = []) -> AuthorityPolicyDefinition {
            AuthorityPolicyDefinition(scope: scope, rule: "synthetic-language", value: value,
                effectiveFrom: effective, expiresAt: expiry, untilTaskComplete: until, sources: sources)
        }
        for origin in [AuthorityOrigin.imported, .model, .quoted, .document, .subagent] {
            let state = try fixture.snapshot(), old = try fixture.snapshotBytes()
            checks["authority_" + origin.rawValue + "_cannot_activate_policy"] = rejects {
                _ = try fixture.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-policy-denied-" + origin.rawValue,
                    expectedRevision: state.revision, operation: .policySet, policyID: "synthetic-policy-denied-" + origin.rawValue,
                    policy: definition(global, "Synthetic denied policy")), authority: fixture.authority(origin), now: 1000)
            }
            checks["authority_" + origin.rawValue + "_policy_rejection_changes_no_state"] = try fixture.snapshotBytes() == old
        }
        _ = try fixture.apply(.policyPropose, policyID: "synthetic-proposal", policy: definition(global, "Synthetic proposal", sources: [source]))
        checks["authority_proposed_policy_is_persisted_without_activation"] = try policy(fixture, "synthetic-proposal").state == .proposed
            && fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.isEmpty
        _ = try fixture.apply(.policyActivate, policyID: "synthetic-proposal")
        checks["authority_explicit_human_activation_selects_proposed_policy"] = try policy(fixture, "synthetic-proposal").state == .active
            && fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.count == 1
        _ = try fixture.apply(.policySet, policyID: "synthetic-project-policy", policy: definition(project, "Synthetic project value"))
        checks["authority_project_policy_precedes_global_default"] = try fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.first.map { episodeIdentifierEqual($0.id, "synthetic-project-policy") } == true
        _ = try fixture.apply(.policySet, policyID: "synthetic-task-exception", policy: definition(task, "Synthetic task value", until: true))
        checks["authority_task_policy_precedes_project_and_global"] = try fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.first.map { episodeIdentifierEqual($0.id, "synthetic-task-exception") } == true
        checks["authority_task_exception_preserves_project_and_global_records"] = try policy(fixture, "synthetic-proposal").state == .active && policy(fixture, "synthetic-project-policy").state == .active
        _ = try fixture.apply(.policySet, policyID: "synthetic-permanent-task-preference",
            policy: AuthorityPolicyDefinition(scope: task, rule: "synthetic-style-preference", value: "Synthetic permanent preference"))
        _ = try fixture.apply(.policySet, policyID: "synthetic-task-conflict", policy: definition(task, "Synthetic conflicting task value", until: true))
        let conflict = try fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a")
        checks["authority_same_scope_conflict_blocks_resolution"] = conflict.blocked && !conflict.conflicts.isEmpty
        _ = try fixture.apply(.policyRevoke, policyID: "synthetic-task-conflict")
        checks["authority_explicit_revoke_resolves_conflict"] = try !fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").blocked
            && policy(fixture, "synthetic-task-conflict").state == .revoked
        _ = try fixture.apply(.policySupersede, policyID: "synthetic-project-replacement",
            policy: definition(project, "Synthetic replacement project value"), supersedes: ["synthetic-project-policy"])
        checks["authority_explicit_supersession_retires_only_same_scope_rule"] = try policy(fixture, "synthetic-project-policy").state == .superseded
            && policy(fixture, "synthetic-project-replacement").state == .active && policy(fixture, "synthetic-proposal").state == .active
        let before = try fixture.snapshotBytes()
        checks["authority_cross_scope_supersession_refused"] = rejects {
            _ = try fixture.apply(.policySupersede, policyID: "synthetic-cross-scope-replacement", policy: definition(global, "Synthetic rejected value"), supersedes: ["synthetic-project-replacement"])
        }
        checks["authority_cross_scope_supersession_is_atomic"] = try fixture.snapshotBytes() == before
        checks["authority_terminal_revoked_policy_cannot_reactivate"] = rejects { _ = try fixture.apply(.policyActivate, policyID: "synthetic-task-conflict") }
        checks["authority_terminal_superseded_policy_cannot_reactivate"] = rejects { _ = try fixture.apply(.policyActivate, policyID: "synthetic-project-policy") }
        let invalidDefinitions = [
            ("empty_rule", AuthorityPolicyDefinition(scope: global, rule: "", value: "Synthetic value")),
            ("oversize_value", AuthorityPolicyDefinition(scope: global, rule: "synthetic-limit-rule", value: String(repeating: "x", count: 8193))),
            ("negative_effective_time", AuthorityPolicyDefinition(scope: global, rule: "synthetic-limit-rule", value: "Synthetic value", effectiveFrom: -1)),
            ("already_expired", AuthorityPolicyDefinition(scope: global, rule: "synthetic-limit-rule", value: "Synthetic value", expiresAt: 999)),
            ("global_until_task_complete", AuthorityPolicyDefinition(scope: global, rule: "synthetic-limit-rule", value: "Synthetic value", untilTaskComplete: true)),
            ("missing_task", AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .task, projectID: fixture.project, taskID: "synthetic-missing-task"), rule: "synthetic-limit-rule", value: "Synthetic value"))
        ]
        for (name, invalid) in invalidDefinitions {
            let old = try fixture.snapshotBytes()
            checks["authority_invalid_policy_" + name + "_refused"] = rejects { _ = try fixture.apply(.policySet, policyID: "synthetic-invalid-policy-" + name, policy: invalid) }
            checks["authority_invalid_policy_" + name + "_is_atomic"] = try fixture.snapshotBytes() == old
        }

        var invalidSources: [(String, AuthoritySourceSpan)] = []
        invalidSources.append(("digest", AuthoritySourceSpan(eventID: source.eventID, projectID: source.projectID, conversationID: source.conversationID,
            offset: 0, byteLength: source.byteLength, sourceSHA256: String(repeating: "0", count: 64), excerptSHA256: source.excerptSHA256)))
        invalidSources.append(("excerpt_digest", AuthoritySourceSpan(eventID: source.eventID, projectID: source.projectID, conversationID: source.conversationID,
            offset: 0, byteLength: source.byteLength, sourceSHA256: source.sourceSHA256, excerptSHA256: String(repeating: "0", count: 64))))
        invalidSources.append(("project", AuthoritySourceSpan(eventID: source.eventID, projectID: "synthetic-other-project", conversationID: source.conversationID,
            offset: 0, byteLength: source.byteLength, sourceSHA256: source.sourceSHA256, excerptSHA256: source.excerptSHA256)))
        invalidSources.append(("conversation", AuthoritySourceSpan(eventID: source.eventID, projectID: source.projectID, conversationID: "synthetic-other-chat",
            offset: 0, byteLength: source.byteLength, sourceSHA256: source.sourceSHA256, excerptSHA256: source.excerptSHA256)))
        invalidSources.append(("bounds", AuthoritySourceSpan(eventID: source.eventID, projectID: source.projectID, conversationID: source.conversationID,
            offset: 0, byteLength: source.byteLength + 1, sourceSHA256: source.sourceSHA256, excerptSHA256: source.excerptSHA256)))
        let bytes = Data(fixture.source.text.utf8)
        let continuation = bytes.indices.first { bytes[$0] & 0xC0 == 0x80 }!
        let split = Data(bytes[continuation...])
        invalidSources.append(("utf8_boundary", AuthoritySourceSpan(eventID: source.eventID, projectID: source.projectID, conversationID: source.conversationID,
            offset: continuation, byteLength: split.count, sourceSHA256: source.sourceSHA256, excerptSHA256: ContextSnapshot.digest(split))))
        for (name, invalid) in invalidSources {
            let old = try fixture.snapshotBytes()
            checks["authority_source_" + name + "_mismatch_refused"] = rejects {
                _ = try fixture.apply(.policySet, policyID: "synthetic-invalid-source-" + name, policy: definition(project, "Synthetic rejected value", sources: [invalid]))
            }
            checks["authority_source_" + name + "_rejection_is_atomic"] = try fixture.snapshotBytes() == old
        }
        let excerpt = Data(bytes[10..<19])
        let selectedSpan = AuthoritySourceSpan(eventID: source.eventID, projectID: source.projectID, conversationID: source.conversationID,
            offset: 10, byteLength: excerpt.count, sourceSHA256: source.sourceSHA256, excerptSHA256: ContextSnapshot.digest(excerpt))
        let annotated = AuthorityPolicyDefinition(scope: project, rule: "synthetic-annotated-rule", value: "Synthetic referenced value", sources: [selectedSpan])
        _ = try fixture.apply(.policySet, policyID: "synthetic-valid-subspan", policy: annotated)
        checks["authority_valid_nonzero_source_span_is_retained_exactly"] = try canonical(policy(fixture, "synthetic-valid-subspan").definition.sources) == canonical([selectedSpan])
        checks["authority_policy_operations_preserve_original_source_bytes"] = try fixture.store!.events(conversationID: fixture.chat.id).first.map {
            $0.text.utf8.elementsEqual(fixture.source.text.utf8) && $0.digest == fixture.source.digest
        } == true
    }
    private static func lifecycleChecks(_ fixture: Fixture, checks: inout [String: Bool]) throws {
        _ = try fixture.apply(.taskSuspend, task: "synthetic-task-a")
        checks["authority_suspend_marks_task_suspended"] = try task(fixture, "synthetic-task-a").state == .suspended
        checks["authority_suspend_keeps_until_complete_exception_dormant"] = try policy(fixture, "synthetic-task-exception").state == .active
            && !fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.contains { episodeIdentifierEqual($0.id, "synthetic-task-exception") }
        checks["authority_suspended_task_cannot_be_selected_for_dispatch"] = rejects { _ = try fixture.apply(.taskSelect, task: "synthetic-task-a", conversation: fixture.chat.id) }
        _ = try fixture.apply(.taskResume, task: "synthetic-task-a")
        checks["authority_resume_reactivates_task_and_dormant_policy"] = try task(fixture, "synthetic-task-a").state == .active
            && fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.contains { episodeIdentifierEqual($0.id, "synthetic-task-exception") }
        _ = try fixture.apply(.taskComplete, task: "synthetic-task-a")
        checks["authority_complete_closes_task_and_expires_until_complete_exception"] = try task(fixture, "synthetic-task-a").state == .completed
            && policy(fixture, "synthetic-task-exception").state == .expired
        checks["authority_completed_task_cannot_resume_or_select"] = rejects { _ = try fixture.apply(.taskResume, task: "synthetic-task-a") }
            && rejects { _ = try fixture.apply(.taskSelect, task: "synthetic-task-a", conversation: fixture.chat.id) }
        _ = try fixture.apply(.taskReopen, task: "synthetic-task-a")
        checks["authority_reopen_returns_task_to_active_without_expired_approval"] = try task(fixture, "synthetic-task-a").state == .active
            && policy(fixture, "synthetic-task-exception").state == .expired
            && !fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.contains { episodeIdentifierEqual($0.id, "synthetic-task-exception") }
        checks["authority_reopen_preserves_explicit_permanent_task_preference"] = try policy(fixture, "synthetic-permanent-task-preference").state == .active
            && fixture.snapshot().resolvedPolicies(projectID: fixture.project, taskID: "synthetic-task-a").selected.contains { episodeIdentifierEqual($0.id, "synthetic-permanent-task-preference") }
        checks["authority_expired_exception_cannot_reactivate_with_old_id"] = rejects { _ = try fixture.apply(.policyActivate, policyID: "synthetic-task-exception") }
        _ = try fixture.apply(.taskNew, task: "synthetic-task-b")
        _ = try fixture.apply(.taskSelect, task: "synthetic-task-b", conversation: fixture.chat.id)
        checks["authority_select_binds_existing_active_task"] = try fixture.snapshot().bindings.count == 1
        let otherChat = try fixture.store!.createConversation(projectID: "synthetic-other-project", title: "Synthetic other scope")
        checks["authority_task_selection_cannot_cross_project_binding"] = rejects {
            _ = try fixture.apply(.taskSelect, task: "synthetic-task-b", conversation: otherChat.id)
        }
        checks["authority_task_transition_requires_exact_record_revision"] = rejects {
            _ = try fixture.apply(.taskSuspend, task: "synthetic-task-b", taskRevision: 99)
        }
        let temporary = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .task, projectID: fixture.project, taskID: "synthetic-task-b"),
            rule: "synthetic-temporary", value: "Synthetic temporary approval", untilTaskComplete: true)
        _ = try fixture.apply(.policySet, policyID: "synthetic-cancel-exception", policy: temporary)
        _ = try fixture.apply(.taskCancel, task: "synthetic-task-b")
        checks["authority_cancel_closes_task_and_expires_approval"] = try task(fixture, "synthetic-task-b").state == .cancelled
            && policy(fixture, "synthetic-cancel-exception").state == .expired
        _ = try fixture.apply(.taskReopen, task: "synthetic-task-b")
        checks["authority_reopened_cancelled_task_does_not_restore_exception"] = try task(fixture, "synthetic-task-b").state == .active
            && policy(fixture, "synthetic-cancel-exception").state == .expired

        let dateDefinition = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .global), rule: "synthetic-date-rule",
            value: "Synthetic dated value", effectiveFrom: 1100, expiresAt: 1200)
        _ = try fixture.apply(.policySet, policyID: "synthetic-dated-policy", policy: dateDefinition, now: 1000)
        checks["authority_future_effective_policy_is_scheduled"] = try policy(fixture, "synthetic-dated-policy").state == .scheduled
        let beforeActivation = try fixture.snapshot()
        let active = try fixture.store!.authorityStateSnapshot(now: 1100)
        checks["authority_due_activation_advances_revision_epoch"] = try active.controlEpoch > beforeActivation.controlEpoch
            && active.revision > beforeActivation.revision && policy(fixture, "synthetic-dated-policy").state == .active
        let beforeExpiry = try fixture.snapshot()
        let staleRequest = AuthorityOperationRequest(requestID: "synthetic-overdue-stale-request", expectedRevision: beforeExpiry.revision,
            operation: .taskNew, taskID: "synthetic-after-expiry-task", projectID: fixture.project)
        checks["authority_overdue_expiry_invalidates_old_cas_request"] = rejects {
            _ = try fixture.store!.applyAuthorityOperation(request: staleRequest, authority: fixture.authority(), now: 1200)
        }
        let expired = try fixture.snapshot()
        checks["authority_overdue_expiry_commits_despite_following_cas_rejection"] = try expired.controlEpoch > beforeExpiry.controlEpoch
            && expired.revision > beforeExpiry.revision && expired.timeHighWater == 1200 && policy(fixture, "synthetic-dated-policy").state == .expired
            && !expired.tasks.contains { episodeIdentifierEqual($0.id, "synthetic-after-expiry-task") }
        _ = try fixture.store!.authorityStateSnapshot(now: 1000)
        checks["authority_clock_rollback_does_not_reactivate_expired_policy"] = try fixture.snapshot().timeHighWater == 1200
            && policy(fixture, "synthetic-dated-policy").state == .expired
    }
    private static func independentChecks(scratch: URL, checks: inout [String: Bool]) throws {
        let legacy = scratch.appendingPathComponent("legacy-five")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let legacyDatabase = legacy.appendingPathComponent("memory.sqlite3")
        try sql(legacyDatabase, AuthoritySchemaFive.sql, create: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyDatabase.path)
        let migrated = try MemoryStore(directory: legacy)
        let migratedState = try migrated.authorityStateSnapshot()
        checks["authority_genuine_schema_five_migrates_empty_control_kernel"] = migratedState.tasks.isEmpty && migratedState.policies.isEmpty
            && migratedState.bindings.isEmpty && migratedState.controlEpoch == 1 && migratedState.revision == 1
        checks["authority_schema_five_migration_retains_no_invented_clock"] = migratedState.timeHighWater == 0
        let timer = try Fixture(directory: scratch.appendingPathComponent("retry-expiry"))
        let timerState = try timer.snapshot()
        let dated = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .global), rule: "synthetic-retry-expiry",
            value: "Synthetic dated policy", expiresAt: 200)
        let datedRequest = AuthorityOperationRequest(requestID: "synthetic-retry-dated-policy", expectedRevision: timerState.revision,
            operation: .policySet, policyID: "synthetic-retry-expiring-policy", policy: dated)
        let datedReceipt = try timer.store!.applyAuthorityOperation(request: datedRequest, authority: timer.authority(), now: 100)
        let expiryRetry = try timer.store!.applyAuthorityOperation(request: datedRequest, authority: timer.authority(), now: 200)
        checks["authority_retry_at_due_expiry_keeps_original_receipt"] = try canonical(datedReceipt) == canonical(expiryRetry)
        checks["authority_retry_at_due_expiry_cannot_extend_permission"] = try policy(timer, "synthetic-retry-expiring-policy").state == .expired
            && timer.snapshot().controlEpoch > datedReceipt.controlEpoch && timer.snapshot().timeHighWater == 200
        let beforeUnauthorized = try timer.snapshotBytes()
        checks["authority_unauthorized_retry_cannot_advance_clock"] = rejects {
            _ = try timer.store!.applyAuthorityOperation(request: datedRequest,
                authority: AuthorityContext(ownerID: timerState.ownerID, origin: .model), now: 9999)
        }
        checks["authority_unauthorized_retry_preserves_exact_state"] = try timer.snapshotBytes() == beforeUnauthorized
        let unicode = try Fixture(directory: scratch.appendingPathComponent("unicode"))
        let cliState = try unicode.snapshot()
        _ = try unicode.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-cli-new-task",
            expectedRevision: cliState.revision, operation: .taskNew, taskID: "synthetic-cli-task", projectID: unicode.project),
            authority: unicode.authority(.humanCLI), now: 1000)
        checks["authority_explicit_human_cli_operation_is_accepted"] = try task(unicode, "synthetic-cli-task").state == .active
        let nfc = "synthetic-task-é", nfd = "synthetic-task-e\u{301}"
        _ = try unicode.apply(.taskNew, task: nfc)
        _ = try unicode.apply(.taskNew, task: nfd)
        checks["authority_unicode_equivalent_task_ids_remain_distinct"] = try unicode.snapshot().tasks.count == 3
        let unicodePolicy = AuthorityPolicyDefinition(scope: AuthorityPolicyScope(kind: .global), rule: "synthetic-unicode-rule", value: "Synthetic shared value")
        _ = try unicode.apply(.policySet, policyID: "synthetic-policy-é", policy: unicodePolicy)
        _ = try unicode.apply(.policySet, policyID: "synthetic-policy-e\u{301}", policy: unicodePolicy)
        checks["authority_unicode_equivalent_policy_ids_remain_distinct"] = try unicode.snapshot().policies.count == 2
        _ = try unicode.apply(.policyRevoke, policyID: "synthetic-policy-é")
        checks["authority_unicode_policy_revocation_changes_only_exact_id"] = try policy(unicode, "synthetic-policy-é").state == .revoked
            && policy(unicode, "synthetic-policy-e\u{301}").state == .active
        let beforeInvalid = try unicode.snapshotBytes()
        checks["authority_duplicate_exact_task_id_refused"] = rejects { _ = try unicode.apply(.taskNew, task: nfc) }
        checks["authority_duplicate_task_rejection_leaves_exact_state"] = try unicode.snapshotBytes() == beforeInvalid
        for (name, id) in [("empty", ""), ("nul", "synthetic\0id"), ("oversize", String(repeating: "x", count: 257))] {
            checks["authority_invalid_" + name + "_task_id_refused"] = rejects { _ = try unicode.apply(.taskNew, task: id) }
        }
        let state = try unicode.snapshot()
        let race = AuthorityOperationRequest(requestID: "synthetic-cas-winner", expectedRevision: state.revision,
            operation: .taskNew, taskID: "synthetic-cas-task", projectID: unicode.project)
        _ = try unicode.store!.applyAuthorityOperation(request: race, authority: unicode.authority(), now: 100)
        let afterWinner = try unicode.snapshotBytes()
        checks["authority_two_requests_same_revision_only_first_commits"] = rejects {
            _ = try unicode.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-cas-loser",
                expectedRevision: state.revision, operation: .taskNew, taskID: "synthetic-cas-other-task", projectID: unicode.project),
                authority: unicode.authority(), now: 100)
        }
        checks["authority_cas_loser_cannot_change_winner_state"] = try unicode.snapshotBytes() == afterWinner

        let concurrentState = try unicode.snapshot()
        let outcomeLock = NSLock()
        var successes = 0, failures = 0
        let concurrentAuthority = try unicode.authority()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                _ = try unicode.store!.applyAuthorityOperation(request: AuthorityOperationRequest(requestID: "synthetic-concurrent-request-\(index)",
                    expectedRevision: concurrentState.revision, operation: .taskNew,
                    taskID: "synthetic-concurrent-task-\(index)", projectID: unicode.project), authority: concurrentAuthority, now: 1000)
                outcomeLock.lock(); successes += 1; outcomeLock.unlock()
            } catch { outcomeLock.lock(); failures += 1; outcomeLock.unlock() }
        }
        let afterConcurrent = try unicode.snapshot()
        checks["authority_real_concurrent_cas_race_has_one_winner"] = successes == 1 && failures == 1
            && afterConcurrent.tasks.count == concurrentState.tasks.count + 1
            && afterConcurrent.revision == concurrentState.revision + 1 && afterConcurrent.controlEpoch == concurrentState.controlEpoch + 1

        let durableBefore = try unicode.snapshot()
        unicode.store = nil
        unicode.store = try MemoryStore(directory: unicode.directory)
        let durableAfter = try unicode.snapshot()
        checks["authority_reopen_advances_epoch_once"] = durableAfter.controlEpoch == durableBefore.controlEpoch + 1
        checks["authority_reopen_retains_exact_tasks_policies_and_bindings"] = try canonical(durableAfter.tasks) == canonical(durableBefore.tasks)
            && canonical(durableAfter.policies) == canonical(durableBefore.policies)
            && canonical(durableAfter.bindings) == canonical(durableBefore.bindings)
        checks["authority_reopen_retains_owner_store_and_time_high_water"] = episodeIdentifierEqual(durableAfter.ownerID, durableBefore.ownerID)
            && episodeIdentifierEqual(durableAfter.storeID, durableBefore.storeID) && durableAfter.timeHighWater == durableBefore.timeHighWater
        let retryAfterStartup = try unicode.store!.applyAuthorityOperation(request: race, authority: unicode.authority(), now: 100)
        checks["authority_reopen_retry_returns_original_operation_epoch"] = retryAfterStartup.controlEpoch == concurrentState.controlEpoch

        let archive = scratch.appendingPathComponent("authority-archive")
        let manifest = try BackupArchive.create(from: unicode.store!, at: archive)
        checks["authority_archive_verifies_exact_manifest"] = try BackupArchive.verify(at: archive) == manifest
        let restored = scratch.appendingPathComponent("authority-restored")
        _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
        let restoredOwner = try MemoryStore(directory: restored)
        let restoredState = try restoredOwner.authorityStateSnapshot()
        checks["authority_archive_restore_and_owner_reopen_each_advance_epoch"] = restoredState.controlEpoch == durableAfter.controlEpoch + 2
            && restoredState.revision == durableAfter.revision + 2
        checks["authority_archive_restore_keeps_exact_authority_records"] = try canonical(restoredState.tasks) == canonical(durableAfter.tasks)
            && canonical(restoredState.policies) == canonical(durableAfter.policies) && canonical(restoredState.bindings) == canonical(durableAfter.bindings)
        try corruptionChecks(scratch: scratch, archive: archive, checks: &checks)
    }
    private static func corruptionChecks(scratch: URL, archive: URL, checks: inout [String: Bool]) throws {
        func corrupted(_ name: String, _ mutation: (URL) throws -> Void) throws -> URL {
            let directory = scratch.appendingPathComponent("corrupt-" + name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let database = directory.appendingPathComponent("memory.sqlite3")
            try FileManager.default.copyItem(at: archive.appendingPathComponent("memory.sqlite3"), to: database)
            try mutation(database)
            return directory
        }
        let mirror = try corrupted("mirror-policy") { database in
            try mutateBlob(database, select: "SELECT payload FROM authority_policies WHERE id='synthetic-policy-é'",
                update: "UPDATE authority_policies SET payload=?,digest=? WHERE id='synthetic-policy-é'") { value in
                var definition = value["definition"] as! [String: Any]; definition["value"] = "Synthetic altered value"; value["definition"] = definition
            }
        }
        checks["authority_mirror_policy_tamper_refused_after_digest_rebinding"] = rejects { _ = try MemoryStore(directory: mirror) }
        let receipt = try corrupted("receipt-origin") { database in
            try mutateBlob(database, select: "SELECT receipt_payload FROM authority_operations WHERE request_id='synthetic-cas-winner'",
                update: "UPDATE authority_operations SET receipt_payload=?,receipt_digest=? WHERE request_id='synthetic-cas-winner'") { $0["origin"] = "model" }
        }
        checks["authority_receipt_nonhuman_origin_refused_after_digest_rebinding"] = rejects { _ = try MemoryStore(directory: receipt) }
        let control = try corrupted("control-extra-key") { database in
            try mutateBlob(database, select: "SELECT payload FROM authority_control WHERE id=1",
                update: "UPDATE authority_control SET payload=?,digest=? WHERE id=1") { $0["fabricatedAuthority"] = true }
        }
        checks["authority_control_unknown_field_refused_after_digest_rebinding"] = rejects { _ = try MemoryStore(directory: control) }
        let missing = try corrupted("missing-table") { try sql($0, "DROP TABLE authority_operations") }
        checks["authority_schema_six_missing_required_table_refused"] = rejects { _ = try MemoryStore(directory: missing) }
        let historical = try corrupted("historical-inventory") { try sql($0, "PRAGMA user_version=5") }
        checks["authority_historical_schema_cannot_adopt_existing_authority_records"] = rejects { _ = try MemoryStore(directory: historical) }
        let sequence = try corrupted("missing-operation") { try sql($0, "DELETE FROM authority_operations WHERE request_id='synthetic-cas-winner'") }
        checks["authority_missing_operation_receipt_refused"] = rejects { _ = try MemoryStore(directory: sequence) }
        let epoch = try corrupted("epoch-rewind") { database in
            try mutateBlob(database, select: "SELECT payload FROM authority_control WHERE id=1",
                update: "UPDATE authority_control SET payload=?,digest=? WHERE id=1") { $0["controlEpoch"] = 0 }
        }
        checks["authority_control_epoch_rewind_refused_after_digest_rebinding"] = rejects { _ = try MemoryStore(directory: epoch) }
        let schemaMutations = [
            ("extra_table", "CREATE TABLE authority_fabricated(id TEXT PRIMARY KEY)"),
            ("extra_trigger", "CREATE TRIGGER synthetic_authority_hook AFTER UPDATE ON authority_control BEGIN SELECT 1; END"),
            ("extra_index", "CREATE INDEX synthetic_authority_index ON authority_tasks(digest)"),
            ("altered_constraint", "BEGIN IMMEDIATE; ALTER TABLE authority_control RENAME TO authority_control_original; CREATE TABLE authority_control(id INTEGER PRIMARY KEY CHECK(id>=1),payload BLOB NOT NULL,digest TEXT NOT NULL); INSERT INTO authority_control SELECT * FROM authority_control_original; DROP TABLE authority_control_original; COMMIT")
        ]
        for (name, statement) in schemaMutations {
            let copy = scratch.appendingPathComponent("authority-schema-" + name)
            try FileManager.default.copyItem(at: archive, to: copy)
            try sql(copy.appendingPathComponent("memory.sqlite3"), statement)
            try refreshDatabaseFileHash(copy)
            checks["authority_" + name + "_archive_schema_tamper_refused_with_matching_file_hash"] = rejects { _ = try BackupArchive.verify(at: copy) }
            checks["authority_" + name + "_owner_schema_tamper_refused"] = rejects { _ = try MemoryStore(directory: copy) }
        }
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func task(_ fixture: Fixture, _ id: String) throws -> AuthorityTaskRecord {
        guard let value = try fixture.snapshot().tasks.first(where: { episodeIdentifierEqual($0.id, id) }) else { throw CheckError.invalid }
        return value
    }
    private static func policy(_ fixture: Fixture, _ id: String) throws -> AuthorityPolicyRecord {
        guard let value = try fixture.snapshot().policies.first(where: { episodeIdentifierEqual($0.id, id) }) else { throw CheckError.invalid }
        return value
    }
    private enum CheckError: Error { case invalid, operation(AuthorityOperation, Int, String) }
    private static func rejects(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
    private static func sql(_ url: URL, _ statement: String, create: Bool = false) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0), nil) == SQLITE_OK,
            let database else { throw CheckError.invalid }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw CheckError.invalid }
    }
    private static func mutateBlob(_ url: URL, select: String, update: String, mutation: (inout [String: Any]) -> Void) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else { throw CheckError.invalid }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, select, -1, &statement, nil) == SQLITE_OK, let read = statement else { throw CheckError.invalid }
        defer { sqlite3_finalize(read) }
        guard sqlite3_step(read) == SQLITE_ROW, let pointer = sqlite3_column_blob(read, 0) else { throw CheckError.invalid }
        let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(read, 0)))
        var value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        mutation(&value)
        let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        var rawUpdate: OpaquePointer?
        guard sqlite3_prepare_v2(database, update, -1, &rawUpdate, nil) == SQLITE_OK, let write = rawUpdate else { throw CheckError.invalid }
        defer { sqlite3_finalize(write) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard changed.withUnsafeBytes({ sqlite3_bind_blob(write, 1, $0.baseAddress, Int32(changed.count), transient) }) == SQLITE_OK,
            ContextSnapshot.digest(changed).withCString({ sqlite3_bind_text(write, 2, $0, -1, transient) }) == SQLITE_OK,
            sqlite3_step(write) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw CheckError.invalid }
    }
    private static func refreshDatabaseFileHash(_ archive: URL) throws {
        let manifest = archive.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var files = object["files"] as! [[String: Any]]
        guard let index = files.firstIndex(where: { $0["name"] as? String == "memory.sqlite3" }) else { throw CheckError.invalid }
        let bytes = try Data(contentsOf: archive.appendingPathComponent("memory.sqlite3"))
        files[index]["bytes"] = bytes.count; files[index]["sha256"] = ContextSnapshot.digest(bytes); object["files"] = files
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
}
