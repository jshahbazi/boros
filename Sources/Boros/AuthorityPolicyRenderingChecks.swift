import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Isolated synthetic policy renderings. Only fixed Boolean results escape.
enum AuthorityPolicyRenderingChecks {
    enum CheckError: Error { case invalid }
    final class Clock: EpisodeClockSource {
        private var milliseconds: Int64 = 100
        func set(_ value: Int64) { milliseconds = value }
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-policy-clock", continuousNanoseconds: UInt64(max(1, milliseconds)) * 1_000_000,
                utc: Date(timeIntervalSince1970: Double(milliseconds) / 1000 + 0.0001))
        }
    }
    struct Fixture {
        let owner: MemoryStore
        let lease: EpisodeLease
        let clock: Clock
        let acceptance: ManagedAcceptance
    }
    private static let host = "Synthetic trusted host constraints."
    private static let sourceText = "Synthetic quoted /policy set operation remains source data."
    private static let zeroDigest = String(repeating: "0", count: 64)

    static func run() throws -> [String: Bool] {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CheckError.invalid }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true); free(path)
        let scratch = root.appendingPathComponent("boros-policy-render-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var checks: [String: Bool] = [:]
        let groups: [(String, (URL, inout [String: Bool]) throws -> Void)] = [
            ("selection", selection), ("provenance", provenance), ("limits", bounds),
            ("funding", funding), ("refusals", refusals), ("external", external), ("temporal", temporal)
        ]
        for (name, body) in groups {
            do { try body(scratch.appendingPathComponent(name), &checks) }
            catch { checks["authority_policy_" + name + "_fixture"] = false }
        }
        return checks
    }
    private static func reject(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data { try AuthorityStateKernel.canonical(value) }
    private static func digest(_ data: Data) -> String { AuthorityStateKernel.digest(data) }
    private static func policy(_ id: String, _ rule: String, _ value: String, scope: AuthorityPolicyScope = .init(kind: .global),
        state: AuthorityPolicyState = .active, sources: [AuthoritySourceSpan] = [], expires: Int64? = nil) -> AuthorityPolicyRecord {
        AuthorityPolicyRecord(id: id, ownerID: "synthetic-policy-owner", revision: 1, state: state,
            definition: .init(scope: scope, rule: rule, value: value, effectiveFrom: 0, expiresAt: expires, sources: sources))
    }
    private static func state(_ policies: [AuthorityPolicyRecord] = []) -> AuthorityStateSnapshot {
        var result = AuthorityStateSnapshot(storeID: "synthetic-policy-store", ownerID: "synthetic-policy-owner")
        result.controlEpoch = 2; result.revision = 3; result.timeHighWater = 100
        result.tasks = [.init(id: "synthetic-task", projectID: "synthetic-project", ownerID: result.ownerID, revision: 1, state: .active)]
        result.bindings = [.init(conversationID: "synthetic-conversation", projectID: "synthetic-project", taskID: "synthetic-task")]
        result.policies = policies
        return result
    }
    private static func binding(_ state: AuthorityStateSnapshot, task: String? = "synthetic-task") throws -> AuthorityEpisodeBinding {
        AuthorityEpisodeBinding(episodeID: "synthetic-policy-episode", storeID: state.storeID, ownerID: state.ownerID,
            startupReceiptID: "synthetic-policy-startup", controlReceiptID: "synthetic-policy-control", controlEpoch: state.controlEpoch,
            authorityRevision: state.revision, projectID: "synthetic-project", conversationID: task == nil ? nil : "synthetic-conversation",
            requestID: "synthetic-policy-request", authenticatedOrigin: .humanHost, taskID: task,
            taskRevision: task == nil ? nil : 1, policyReferences: try AuthorityBindings.policyReferences(state: state, projectID: "synthetic-project", taskID: task),
            resolutionSHA256: try AuthorityBindings.resolutionSHA256(state: state, projectID: "synthetic-project", taskID: task),
            originSHA256: zeroDigest, taskIntentSHA256: zeroDigest)
    }
    private static func render(_ state: AuthorityStateSnapshot, limits: AuthorityPolicyRenderLimits = .defaults,
        host: String = host) throws -> AuthorityRenderedPolicy {
        try AuthorityPolicyRenderer.render(state: state, binding: binding(state), hostInstructions: host, limits: limits)
    }
    private static func records(_ rendered: AuthorityRenderedPolicy) throws -> [AuthorityPolicyRecord] {
        try JSONDecoder().decode([AuthorityPolicyRecord].self, from: rendered.selectedPolicyRecords)
    }
    private static func selection(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let project = AuthorityPolicyScope(kind: .project, projectID: "synthetic-project")
        let task = AuthorityPolicyScope(kind: .task, projectID: "synthetic-project", taskID: "synthetic-task")
        var s = state([policy("global-language", "language", "Python"), policy("project-language", "language", "TypeScript", scope: project),
            policy("task-language", "language", "Swift", scope: task), policy("global-format", "format", "compact"),
            policy("other-project", "other", "unrelated", scope: .init(kind: .project, projectID: "other-project"))])
        let selected = try render(s), chosen = try records(selected)
        checks["authority_policy_task_override_and_global_independent_rule_selected"] = chosen.map(\.id) == ["global-format", "task-language"]
        checks["authority_policy_unselected_project_global_and_unrelated_records_absent"] = !selected.systemMessage.contains("TypeScript") && !selected.systemMessage.contains("Python") && !selected.systemMessage.contains("unrelated")
        let scoped = try AuthorityPolicyRenderer.render(state: s, binding: binding(s, task: nil), hostInstructions: host)
        checks["authority_policy_taskless_scope_retains_project_override"] = try records(scoped).map(\.id) == ["global-format", "project-language"]
        s.policies[2].state = .revoked
        checks["authority_policy_revoke_restores_project_default"] = try records(render(s)).map(\.id) == ["global-format", "project-language"]
        s.policies[1].state = .expired
        checks["authority_policy_expired_project_restores_global_default"] = try records(render(s)).map(\.id) == ["global-format", "global-language"]
        let duplicate = state([policy("first", "language", "Python"), policy("second", "language", "Python")])
        checks["authority_policy_same_value_keeps_every_identity_and_revision"] = try records(render(duplicate)).count == 2 && render(duplicate).manifest.policyReferences.count == 2
        let conflict = state([policy("first", "language", "Python"), policy("second", "language", "Rust")])
        checks["authority_policy_conflict_denies_render_without_latest_wins"] = reject { _ = try render(conflict) }
        let hiddenConflict = state([policy("first", "language", "Python"), policy("second", "language", "Rust"), policy("task", "language", "Swift", scope: task)])
        checks["authority_policy_lower_scope_conflict_is_not_hidden_by_override"] = reject { _ = try render(hiddenConflict) }
        for lifecycle in [AuthorityTaskState.suspended, .completed, .cancelled] {
            var closed = s; closed.tasks[0].state = lifecycle
            checks["authority_policy_" + lifecycle.rawValue + "_task_denied"] = reject { _ = try render(closed) }
        }
        var wrongTask = s; wrongTask.tasks[0].revision += 1
        checks["authority_policy_changed_task_revision_denied"] = reject { _ = try render(wrongTask) }
        var wrongConversation = s; wrongConversation.bindings = []
        checks["authority_policy_missing_conversation_selection_denied"] = reject { _ = try render(wrongConversation) }
        let original = try binding(s)
        var newer = s; newer.controlEpoch += 1
        checks["authority_policy_changed_epoch_denied"] = reject { _ = try AuthorityPolicyRenderer.render(state: newer, binding: original, hostInstructions: host) }
        newer = s; newer.revision += 1
        checks["authority_policy_changed_authority_revision_denied"] = reject { _ = try AuthorityPolicyRenderer.render(state: newer, binding: original, hostInstructions: host) }
        var bad = original; bad.policyReferences = []
        checks["authority_policy_missing_selected_reference_denied"] = reject { _ = try AuthorityPolicyRenderer.render(state: s, binding: bad, hostInstructions: host) }
        var altered = try JSONSerialization.jsonObject(with: canonical(original)) as! [String: Any]
        altered["resolutionSHA256"] = zeroDigest
        bad = try JSONDecoder().decode(AuthorityEpisodeBinding.self, from: JSONSerialization.data(withJSONObject: altered, options: [.sortedKeys]))
        checks["authority_policy_mismatched_resolution_digest_denied"] = reject { _ = try AuthorityPolicyRenderer.render(state: s, binding: bad, hostInstructions: host) }
        let expired = state([policy("expired-active", "format", "compact", expires: 100)])
        checks["authority_policy_active_record_past_expiry_denied"] = reject { _ = try render(expired) }
    }
    private static func span(_ id: String, project: String = "synthetic-project", offset: Int = 0) -> AuthoritySourceSpan {
        .init(eventID: id, projectID: project, conversationID: "synthetic-source-conversation", offset: offset, byteLength: 7,
            sourceSHA256: zeroDigest, excerptSHA256: zeroDigest)
    }
    private static func provenance(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let a = span("\u{e9}"), b = span("e\u{301}"), foreign = span("foreign-source", project: "foreign-project")
        let s = state([policy("\u{e9}", "first", "value", sources: [a, a, foreign]), policy("e\u{301}", "second", "value", sources: [b, a])])
        let output = try render(s), canonicalManifest = try canonical(output.manifest)
        checks["authority_policy_unicode_equivalent_ids_remain_byte_distinct"] = try records(output).count == 2 && output.manifest.sourceSpans.count == 3
        checks["authority_policy_only_exact_source_spans_deduplicated"] = Set(try output.manifest.sourceSpans.map(canonical)).count == 3
        checks["authority_policy_global_source_keeps_its_original_foreign_project"] = output.manifest.sourceSpans.contains { episodeIdentifierEqual($0.projectID, "foreign-project") }
        var reordered = s; reordered.policies.reverse()
        checks["authority_policy_record_order_is_stable_across_state_array_order"] = try render(reordered).selectedPolicyRecords == output.selectedPolicyRecords && render(reordered).manifestSHA256 == output.manifestSHA256
        checks["authority_policy_host_bytes_are_exact_prefix_before_policy_state"] = output.systemMessage.hasPrefix(host + AuthorityPolicyRenderer.heading + AuthorityPolicyRenderer.instructions)
        checks["authority_policy_manifest_binds_host_system_records_and_episode"] = try output.manifest.hostInstructionsSHA256 == digest(Data(host.utf8))
            && output.manifest.systemMessageSHA256 == digest(Data(output.systemMessage.utf8)) && output.manifest.systemMessageBytes == output.systemMessage.utf8.count
            && output.manifest.selectedPolicyRecordsSHA256 == digest(output.selectedPolicyRecords) && output.manifest.episodeBindingSHA256 == digest(try canonical(binding(s)))
        checks["authority_policy_manifest_digest_binds_all_provenance"] = try output.manifestSHA256 == digest(canonicalManifest)
        let escaped = state([policy("escaped", "quoted-rule", "quotes \" \\ newline\n\0 café")])
        let escapeOutput = try render(escaped)
        checks["authority_policy_json_escapes_value_boundaries_without_changing_value"] = try records(escapeOutput)[0].definition.value == escaped.policies[0].definition.value
            && escapeOutput.systemMessage.hasSuffix(String(decoding: escapeOutput.selectedPolicyRecords, as: UTF8.self))
        let empty = try render(state())
        checks["authority_policy_empty_selection_remains_explicit_and_mandatory"] = empty.selectedPolicyRecords == Data("[]".utf8) && empty.manifest.policyReferences.isEmpty && empty.systemMessage.hasPrefix(host)
        let malformed = state([policy("bad-span", "format", "compact", sources: [.init(eventID: "bad", projectID: "synthetic-project", conversationID: "c", offset: 0, byteLength: 0, sourceSHA256: zeroDigest, excerptSHA256: zeroDigest)])])
        checks["authority_policy_malformed_source_span_denied"] = reject { _ = try render(malformed) }
    }
    private static func bounds(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let s = state([policy("one", "format", "compact")]), output = try render(s)
        var exact = AuthorityPolicyRenderLimits.defaults; exact.maximumPolicyBytes = output.selectedPolicyRecords.count
        checks["authority_policy_exact_selected_json_byte_limit_accepted"] = !reject { _ = try render(s, limits: exact) }
        exact.maximumPolicyBytes -= 1
        checks["authority_policy_one_byte_short_selected_json_denied"] = reject { _ = try render(s, limits: exact) }
        exact = .defaults; exact.maximumSystemBytes = output.systemMessage.utf8.count
        checks["authority_policy_exact_complete_system_byte_limit_accepted"] = !reject { _ = try render(s, limits: exact) }
        exact.maximumSystemBytes -= 1
        checks["authority_policy_one_byte_short_mandatory_system_denied"] = reject { _ = try render(s, limits: exact) }
        checks["authority_policy_oversized_host_denied_without_truncation"] = reject { _ = try render(s, host: String(repeating: "x", count: 131_073)) }
        checks["authority_policy_host_that_fits_alone_cannot_hide_full_overflow"] = reject { _ = try render(s, host: String(repeating: "x", count: 131_072)) }
        var limits = AuthorityPolicyRenderLimits.defaults; limits.maximumPolicies = 1
        checks["authority_policy_lower_selected_count_limit_denied"] = reject { _ = try render(state([policy("a", "a", "x"), policy("b", "b", "x")]), limits: limits) }
        limits = .defaults; limits.maximumSourceSpans = 1
        checks["authority_policy_lower_source_span_limit_denied"] = reject { _ = try render(state([policy("a", "a", "x", sources: [span("a"), span("b")])]), limits: limits) }
        limits = .defaults; limits.maximumPolicyBytes = 1200
        checks["authority_policy_json_escape_amplification_counts_encoded_bytes"] = reject { _ = try render(state([policy("escape", "format", String(repeating: "\0", count: 400))]), limits: limits) }
        for field in 0..<4 {
            var larger = AuthorityPolicyRenderLimits.defaults
            switch field { case 0: larger.maximumSystemBytes += 1; case 1: larger.maximumPolicyBytes += 1; case 2: larger.maximumPolicies += 1; default: larger.maximumSourceSpans += 1 }
            checks["authority_policy_limit_" + String(field) + "_cannot_raise_frozen_ceiling"] = reject { _ = try larger.validated() }
        }
        limits = .defaults; limits.maximumPolicies = 0
        checks["authority_policy_zero_limit_cannot_disable_mandatory_policy_validation"] = reject { _ = try limits.validated() }
        let encoded = try canonical(AuthorityPolicyRenderLimits.defaults)
        checks["authority_policy_limit_record_canonical_roundtrip"] = try canonical(JSONDecoder().decode(AuthorityPolicyRenderLimits.self, from: encoded)) == encoded
        for kind in ["unknown-field", "wrong-version", "raised-limit", "missing-limit", "boolean-limit"] {
            var altered = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            switch kind {
            case "unknown-field": altered["unexpected"] = 1
            case "wrong-version": altered["version"] = "unsupported-policy-limits"
            case "raised-limit": altered["maximumSystemBytes"] = 131073
            case "missing-limit": altered.removeValue(forKey: "maximumPolicies")
            default: altered["maximumPolicies"] = true
            }
            let invalid = try JSONSerialization.data(withJSONObject: altered, options: [.sortedKeys])
            checks["authority_policy_limit_decode_" + kind + "_denied"] = reject { _ = try JSONDecoder().decode(AuthorityPolicyRenderLimits.self, from: invalid) }
        }
        checks["authority_policy_manifest_retains_frozen_renderer_limits"] = try canonical(output.manifest.limits) == encoded
    }
    private static func database<T>(_ directory: URL, writable: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &pointer, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let db = pointer else { throw CheckError.invalid }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }
    private static func durableCharged(_ directory: URL) throws -> EpisodeResources {
        try database(directory) { db in
            var result = EpisodeResources.zero
            for row in try AuthorityStateKernel.rows(db, "SELECT resource,charged FROM episode_resource_totals WHERE episode_id='policy-episode'") {
                guard let key = EpisodeResource(rawValue: row[0].string) else { throw CheckError.invalid }; result[key] = row[1].integer
            }
            return result
        }
    }
    private static func renderRows(_ directory: URL) throws -> [[AuthorityStateKernel.Value]] {
        try database(directory) { try AuthorityStateKernel.rows($0, "SELECT id,state,charged_json,held_json,receipt_json FROM episode_work WHERE adapter_identity=? ORDER BY id COLLATE BINARY", [.text("authority-validation-v1:" + AuthorityPolicyRenderer.version)]) }
    }
    private static func fixture(_ directory: URL, clock: Clock = Clock(), expires: Int64? = nil,
        checkpoint: ((String, OpaquePointer) throws -> Void)? = nil, validationCheckpoint: ((String) throws -> Void)? = nil) throws -> Fixture {
        let owner = try MemoryStore(directory: directory, authorityValidationCheckpoint: validationCheckpoint, authorityCacheCheckpoint: checkpoint)
        let conversation = try owner.createConversation(projectID: "policy-project", title: "Synthetic policy fixture")
        let source = try owner.append(conversationID: conversation.id, role: .human, text: sourceText, status: .complete, turnID: "policy-evidence-turn", eventID: "policy-evidence")
        let before = try owner.authorityStateSnapshot()
        let sourceSpan = AuthoritySourceSpan(eventID: source.id, projectID: source.projectID, conversationID: source.conversationID,
            offset: 0, byteLength: source.byteCount, sourceSHA256: source.digest, excerptSHA256: source.digest)
        _ = try owner.applyAuthorityOperation(request: .init(requestID: "policy-install", expectedRevision: before.revision, operation: .policySet,
            policyID: "standing-language", policy: .init(scope: .init(kind: .global), rule: "language", value: "Python", expiresAt: expires, sources: [sourceSpan])),
            authority: .init(ownerID: before.ownerID, origin: .humanHost), now: 100)
        let accepted = try owner.acceptManagedHumanRequest(conversationID: conversation.id, turnID: "policy-turn", humanEventID: "policy-human",
            episodeID: "policy-episode", requestID: "policy-request", text: "Synthetic complete policy request", limits: .init(),
            authority: .init(ownerID: before.ownerID, origin: .humanHost), clock: clock.now())
        return Fixture(owner: owner, lease: EpisodeLease(ledger: owner, episodeID: accepted.episode.id, clock: clock), clock: clock, acceptance: accepted)
    }
    private static func funding(_ directory: URL, _ checks: inout [String: Bool]) throws {
        var armedBeforeCallback = false
        let f = try fixture(directory, validationCheckpoint: { phase in
            if phase == AuthorityPolicyRenderer.version {
                armedBeforeCallback = try renderRows(directory).contains { $0[1].string == "dispatchArmed" && $0[4].bytes?.isEmpty == true }
            }
        })
        let session = try f.owner.beginAuthorityValidationSession(lease: f.lease, sessionID: "policy-session", maximumAttempts: 8)
        let before = try durableCharged(directory), cold = f.owner.authorityValidationCacheDiagnostics()
        let originalBinding = try canonical(f.acceptance.binding)
        let rendered = try f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host)
        let charged = try durableCharged(directory), rows = try renderRows(directory)
        checks["authority_policy_render_funding_commits_before_session_callback"] = armedBeforeCallback
        checks["authority_policy_render_has_separate_durable_charge_under_original_episode"] = try charged.subtracting(before) == rendered.charged && rendered.charged.memoryOperations == 1 && rendered.charged.metadataRows > 0 && rendered.charged.rawSourceBytes > 0
        checks["authority_policy_small_validated_state_has_bounded_cardinality_cost"] = rendered.charged.metadataRows < 1000
        checks["authority_policy_rendering_work_settles_only_after_success"] = try rows.count == 1 && rows[0][0].string == rendered.operationID && rows[0][1].string == "completed"
            && (try JSONDecoder().decode(EpisodeResources.self, from: rows[0][2].bytes!)) == rendered.charged
            && (try JSONDecoder().decode([EpisodeWorkSettlement].self, from: rows[0][4].bytes!)).last?.outcome == .completed
        let again = try f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host)
        let warm = f.owner.authorityValidationCacheDiagnostics()
        checks["authority_policy_identical_render_retries_do_not_replenish_work"] = try rendered.operationID != again.operationID && (try durableCharged(directory)) == (try charged.adding(again.charged))
        checks["authority_policy_identical_render_keeps_exact_manifest_and_bytes"] = try rendered.rendering.manifestSHA256 == again.rendering.manifestSHA256 && rendered.rendering.systemMessage == again.rendering.systemMessage
        checks["authority_policy_each_success_consumes_prepaid_session_attempt"] = try f.owner.authorityValidationSessionReceipt(sessionID: session.sessionID).attemptsUsed == 2
        checks["authority_policy_warm_render_reuses_paid_replay"] = warm.fullReplays == cold.fullReplays
        checks["authority_policy_warm_render_never_rereads_original_payload"] = warm.sourcePayloadStatements == cold.sourcePayloadStatements
        checks["authority_policy_policy_source_references_retained_without_excerpts"] = rendered.rendering.manifest.sourceSpans.count == 1 && !rendered.rendering.systemMessage.contains(sourceText)
        checks["authority_policy_quoted_source_command_cannot_activate_policy"] = try f.owner.authorityStateSnapshot().policies.count == 1
        checks["authority_policy_render_never_rewrites_accepted_binding"] = try canonical(f.owner.managedEpisodeBinding(id: f.acceptance.episode.id)!) == originalBinding
    }
    private static func refusals(_ directory: URL, _ checks: inout [String: Bool]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let location = directory.appendingPathComponent("overflow"), f = try fixture(location)
        let session = try f.owner.beginAuthorityValidationSession(lease: f.lease, sessionID: "policy-overflow", maximumAttempts: 4)
        let before = try durableCharged(location)
        var tiny = AuthorityPolicyRenderLimits.defaults; tiny.maximumSystemBytes = 400
        checks["authority_policy_mandatory_overflow_denies_funded_artifact"] = reject { _ = try f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host, limits: tiny) }
        let after = try durableCharged(location), rows = try renderRows(location), consumed = try f.owner.authorityValidationSessionReceipt(sessionID: session.sessionID)
        checks["authority_policy_overflow_preserves_render_charge_and_attempt"] = after.memoryOperations == before.memoryOperations + 1 && consumed.attemptsUsed == 1
        checks["authority_policy_overflow_has_durable_failed_work"] = rows.count == 1 && rows[0][1].string == "failedConfirmed" && rows[0][4].bytes?.isEmpty == false
        checks["authority_policy_repeated_denial_retains_monotonic_charge_and_attempt"] = try reject { _ = try f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host, limits: tiny) }
            && (try durableCharged(location)).memoryOperations >= after.memoryOperations
            && (try f.owner.authorityValidationSessionReceipt(sessionID: session.sessionID)).attemptsUsed >= consumed.attemptsUsed
        let fresh = try f.owner.beginAuthorityValidationSession(lease: f.lease, sessionID: "policy-overflow-fresh", maximumAttempts: 4)
        let freshCost = try durableCharged(location)
        checks["authority_policy_fresh_session_repeated_overflow_denied"] = reject { _ = try f.owner.renderManagedPolicy(sessionID: fresh.sessionID, lease: f.lease, hostInstructions: host, limits: tiny) }
        checks["authority_policy_fresh_attempt_commits_another_failed_render_debit"] = try durableCharged(location).memoryOperations == freshCost.memoryOperations + 1
            && renderRows(location).count == 2 && f.owner.authorityValidationSessionReceipt(sessionID: fresh.sessionID).attemptsUsed == 1
        let reentrant = try fixture(directory.appendingPathComponent("reentrant")), rs = try reentrant.owner.beginAuthorityValidationSession(lease: reentrant.lease, sessionID: "policy-reentrant", maximumAttempts: 4)
        var denied = false
        try reentrant.owner.withAuthorityValidationSession(sessionID: rs.sessionID, lease: reentrant.lease) {
            denied = reject { _ = try reentrant.owner.renderManagedPolicy(sessionID: rs.sessionID, lease: reentrant.lease, hostInstructions: host) }
        }
        checks["authority_policy_reentrant_renderer_denied_without_nested_funding"] = try denied && (try renderRows(reentrant.owner.directory)).isEmpty
        var stopLease: EpisodeLease?, stop = false
        let stopped = try fixture(directory.appendingPathComponent("stop"), checkpoint: { phase, _ in
            if stop && phase == "before-session-acceptance" { stopLease?.interruptLocally(reason: .cancelled) }
        })
        stopLease = stopped.lease
        let ss = try stopped.owner.beginAuthorityValidationSession(lease: stopped.lease, sessionID: "policy-stop", maximumAttempts: 4), stopCost = try durableCharged(stopped.owner.directory)
        stop = true
        checks["authority_policy_stop_after_funding_denies_artifact"] = reject { _ = try stopped.owner.renderManagedPolicy(sessionID: ss.sessionID, lease: stopped.lease, hostInstructions: host) }
        checks["authority_policy_stop_retains_charges_and_consumed_attempt"] = try durableCharged(stopped.owner.directory).memoryOperations == stopCost.memoryOperations + 1 && stopped.owner.authorityValidationSessionReceipt(sessionID: ss.sessionID).attemptsUsed == 1
        let stale = try fixture(directory.appendingPathComponent("stale")), staleSession = try stale.owner.beginAuthorityValidationSession(lease: stale.lease, sessionID: "policy-stale", maximumAttempts: 4)
        let old = try stale.owner.authorityStateSnapshot(), beforeStale = try durableCharged(stale.owner.directory)
        _ = try stale.owner.applyAuthorityOperation(request: .init(requestID: "policy-suspend", expectedRevision: old.revision, operation: .taskSuspend,
            taskID: stale.acceptance.binding.taskID, expectedTaskRevision: stale.acceptance.binding.taskRevision), authority: .init(ownerID: old.ownerID, origin: .humanHost), now: 100)
        checks["authority_policy_control_mutation_invalidates_render_session"] = reject { _ = try stale.owner.renderManagedPolicy(sessionID: staleSession.sessionID, lease: stale.lease, hostInstructions: host) }
        checks["authority_policy_stale_preflight_does_not_donate_funding"] = try durableCharged(stale.owner.directory) == beforeStale && renderRows(stale.owner.directory).isEmpty
    }
    private static func external(_ directory: URL, _ checks: inout [String: Bool]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let early = try fixture(directory.appendingPathComponent("early")), es = try early.owner.beginAuthorityValidationSession(lease: early.lease, sessionID: "policy-external-before", maximumAttempts: 4)
        let cost = try durableCharged(early.owner.directory), diagnostics = early.owner.authorityValidationCacheDiagnostics()
        try database(early.owner.directory, writable: true) { try AuthorityStateKernel.execute($0, "INSERT INTO settings(key,payload) VALUES('synthetic-policy-external',CAST('changed' AS BLOB))") }
        checks["authority_policy_external_commit_before_funding_denied"] = reject { _ = try early.owner.renderManagedPolicy(sessionID: es.sessionID, lease: early.lease, hostInstructions: host) }
        checks["authority_policy_external_commit_cannot_fund_or_read_sources"] = try durableCharged(early.owner.directory) == cost && renderRows(early.owner.directory).isEmpty
            && early.owner.authorityValidationCacheDiagnostics().sourcePayloadStatements == diagnostics.sourcePayloadStatements
        let location = directory.appendingPathComponent("during")
        var inject = false
        let during = try fixture(location, validationCheckpoint: { phase in
            if inject && phase == AuthorityPolicyRenderer.version {
                try database(location, writable: true) { try AuthorityStateKernel.execute($0, "INSERT INTO settings(key,payload) VALUES('synthetic-policy-external',CAST('changed' AS BLOB))") }
            }
        })
        let ds = try during.owner.beginAuthorityValidationSession(lease: during.lease, sessionID: "policy-external-during", maximumAttempts: 4), before = try durableCharged(location)
        inject = true
        checks["authority_policy_external_commit_after_arm_denies_artifact"] = reject { _ = try during.owner.renderManagedPolicy(sessionID: ds.sessionID, lease: during.lease, hostInstructions: host) }
        let rows = try renderRows(location)
        checks["authority_policy_external_commit_retains_unsettled_durable_charge"] = try rows.count == 1 && rows[0][1].string == "dispatchArmed" && rows[0][4].bytes?.isEmpty == true
            && (try durableCharged(location)).memoryOperations == before.memoryOperations + 1
        checks["authority_policy_external_fenced_denial_consumes_attempt"] = try during.owner.authorityValidationSessionReceipt(sessionID: ds.sessionID).attemptsUsed == 1
    }
    private static func temporal(_ directory: URL, _ checks: inout [String: Bool]) throws {
        let clock = Clock(), f = try fixture(directory, clock: clock, expires: 200)
        let session = try f.owner.beginAuthorityValidationSession(lease: f.lease, sessionID: "policy-expiry", maximumAttempts: 4)
        clock.set(199)
        checks["authority_policy_before_expiry_render_keeps_active_policy"] = try records(f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host).rendering).count == 1
        let before = try durableCharged(directory); clock.set(200)
        checks["authority_policy_due_expiry_denies_stale_render"] = reject { _ = try f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host) }
        let now = try f.owner.authorityStateSnapshot()
        checks["authority_policy_funded_expiry_commits_before_denial"] = now.policies.first?.state == .expired && now.controlEpoch > f.acceptance.binding.controlEpoch
        checks["authority_policy_expiry_retains_render_and_maintenance_charges"] = try durableCharged(directory).memoryOperations >= before.memoryOperations + 2
        checks["authority_policy_expiry_denial_consumes_original_session_attempt"] = try f.owner.authorityValidationSessionReceipt(sessionID: session.sessionID).attemptsUsed == 2
    }

    private struct ProcessBaseline: Codable {
        let charged: EpisodeResources
        let workID: String
        let workCharge: EpisodeResources
        let limitsSHA256: String
        let conversationID: String
        let sourceDigests: [String: String]
        let cleanup: EpisodeCleanupInventory
    }
    /// Harness-only crash prefix: after durable render arming, before rendering.
    static func interruptRenderingForProcessChecks(directory: URL) throws {
        let f = try fixture(directory, validationCheckpoint: { phase in
            guard phase == AuthorityPolicyRenderer.version else { return }
            let rows = try renderRows(directory)
            guard rows.count == 1, rows[0][1].string == "dispatchArmed", let charge = rows[0][2].bytes else { throw CheckError.invalid }
            let baseline = try database(directory) { db -> ProcessBaseline in
                let episode = try AuthorityStateKernel.rows(db, "SELECT limits_json,conversation_id FROM episodes WHERE id='policy-episode'")
                guard episode.count == 1, let limits = episode[0][0].bytes else { throw CheckError.invalid }
                var sources: [String: String] = [:]
                for source in try AuthorityStateKernel.rows(db, "SELECT id,payload FROM events ORDER BY sequence") {
                    guard let payload = source[1].bytes else { throw CheckError.invalid }
                    sources[source[0].string] = digest(payload)
                }
                return ProcessBaseline(charged: try durableCharged(directory), workID: rows[0][0].string,
                    workCharge: try JSONDecoder().decode(EpisodeResources.self, from: charge), limitsSHA256: digest(limits),
                    conversationID: episode[0][1].string, sourceDigests: sources,
                    cleanup: try EpisodeTerminalCleanupJournal.inventory(database: db))
            }
            let path = directory.appendingPathComponent("synthetic-render-baseline.json")
            try canonical(baseline).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            kill(getpid(), SIGKILL)
            throw CheckError.invalid
        })
        let session = try f.owner.beginAuthorityValidationSession(lease: f.lease, sessionID: "policy-process-session", maximumAttempts: 4)
        _ = try f.owner.renderManagedPolicy(sessionID: session.sessionID, lease: f.lease, hostInstructions: host)
        throw CheckError.invalid
    }
    static func recoverRenderingForProcessChecks(directory: URL) throws -> [String: Bool] {
        let baseline = try JSONDecoder().decode(ProcessBaseline.self, from: Data(contentsOf: directory.appendingPathComponent("synthetic-render-baseline.json")))
        let owner = try MemoryStore(directory: directory), clock = Clock()
        let episode = try owner.episodeReceipt(id: "policy-episode", clock: clock.now())
        let work = try owner.episodeWork(episodeID: episode.id, operationID: baseline.workID)
        let source = try owner.events(conversationID: baseline.conversationID)
        let cleanup = try database(directory) { try EpisodeTerminalCleanupJournal.inventory(database: $0) }
        let limits = try database(directory) { db -> Data in
            let rows = try AuthorityStateKernel.rows(db, "SELECT limits_json FROM episodes WHERE id='policy-episode'")
            guard rows.count == 1, let bytes = rows[0][0].bytes else { throw CheckError.invalid }; return bytes
        }
        let charge = try durableCharged(directory)
        let staleLease = EpisodeLease(ledger: owner, episodeID: episode.id, clock: clock)
        let refused = reject { _ = try owner.renderManagedPolicy(sessionID: "policy-process-session", lease: staleLease, hostInstructions: host) }
        return [
            "authority_policy_process_original_episode_charge_retained": charge == baseline.charged,
            "authority_policy_process_original_limits_retained": digest(limits) == baseline.limitsSHA256,
            "authority_policy_process_complete_source_evidence_retained": source.count == baseline.sourceDigests.count && source.allSatisfy {
                $0.role == .human && $0.status == .complete && digest(Data($0.text.utf8)) == baseline.sourceDigests[$0.id]
            },
            "authority_policy_process_episode_recovered_as_interrupted": episode.state == .interrupted,
            "authority_policy_process_armed_render_stays_unknown_without_receipt": work?.state == .outcomeUnknown && work?.observed == nil && work?.recovered == true,
            "authority_policy_process_render_charge_never_refunded": work?.charged == baseline.workCharge && work?.charged.memoryOperations == 1 && work?.held == .zero,
            "authority_policy_process_prepaid_slots_and_attempts_retained": cleanup.prepaidRows == baseline.cleanup.prepaidRows && cleanup.attemptedRows == baseline.cleanup.attemptedRows,
            "authority_policy_process_admin_cleanup_consumes_only_original_pending": cleanup.pendingRows == 0
                && cleanup.consumedRows == baseline.cleanup.consumedRows + baseline.cleanup.pendingRows
                && cleanup.administrativeRows == baseline.cleanup.administrativeRows + baseline.cleanup.pendingRows,
            "authority_policy_process_restart_cannot_recreate_render_session": refused,
            "authority_policy_process_denied_restart_never_replenishes_charge": (try durableCharged(directory)) == charge
        ]
    }
}
