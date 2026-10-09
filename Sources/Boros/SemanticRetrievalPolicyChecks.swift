import Foundation

/// Public synthetic fixtures only. Contracts for the October 8, 2026 user
/// decision (docs/P2-SEMANTIC-DECISION.md): ordinary Send withholds the
/// semantic index and records that it did so by policy; the application opens
/// no sidecar and schedules no background semantic work; lexical indexing,
/// explicit on-demand index builds and explicit fused evaluation still work.
/// Injected vectors test protocol mechanics, not retrieval quality.
enum SemanticRetrievalPolicyChecks {
    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-semantic-policy-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let project = "semantic-policy"
        let archive = try store.createConversation(projectID: project, title: "Synthetic policy archive")
        let needle = try store.append(conversationID: archive.id, role: .human,
            text: "The heliostat retry delay is seven seconds.", status: .complete,
            turnID: "policy-needle-turn", eventID: "policy-needle")
        for index in 0..<4 {
            _ = try store.append(conversationID: archive.id, role: index % 2 == 0 ? .assistant : .human,
                text: "Synthetic unrelated note \(index) about garden pebbles.", status: .complete,
                turnID: "policy-filler-turn-\(index)", eventID: "policy-filler-\(index)")
        }
        var checks: [String: Bool] = [:]
        let policy = SemanticRetrievalPolicy.ordinarySend
        checks["semantic_policy_ordinary_send_is_disabled_by_policy"] = policy == .disabledByPolicy
            && !policy.permitsBackgroundIndexing && policy.rawValue == "disabled_by_policy"
        let status = SemanticRetrievalPolicy.disabledStatus.lowercased()
        checks["semantic_policy_status_text_says_off_by_policy_not_failure"] = status.contains("off by policy")
            && !["unavailable", "failed", "paused", "stalled", "degraded"].contains { status.contains($0) }

        // The application host opens nothing under the policy: no sidecar
        // directory, no owner lock and no metered encoder probe.
        var opened = false
        let hostIndex = try ApplicationSemanticMaintenance.openIndex(store: store) { _ in
            opened = true; throw SemanticError.invalid
        }
        let sidecar = store.directory.appendingPathComponent("semantic", isDirectory: true)
        let windowBeforeBuild = try store.backgroundBudgetSnapshot().window
        checks["semantic_policy_application_opens_no_sidecar_and_runs_no_probe"] = hostIndex == nil && !opened
            && !FileManager.default.fileExists(atPath: sidecar.path) && windowBeforeBuild == nil
        var enabledOpened = false
        _ = try? ApplicationSemanticMaintenance.openIndex(store: store, policy: .enabled) { _ in
            enabledOpened = true; throw SemanticError.invalid
        }
        checks["semantic_policy_enabled_host_would_open_index"] = enabledOpened

        // Lexical indexing is synchronous with capture and is unaffected.
        let later = try store.append(conversationID: archive.id, role: .human,
            text: "The zephyrline gauge was recalibrated after capture.", status: .complete,
            turnID: "policy-later-turn", eventID: "policy-later")
        checks["semantic_policy_lexical_indexing_still_progresses"] = try store.search(query: "zephyrline", projectID: project)
            .contains { episodeIdentifierEqual($0.eventID, later.id) }

        // An explicitly constructed index is not scheduled by the host.
        let encoder = Encoder()
        let index = try SemanticIndex(store: store, encoder: encoder)
        let scheduled = ApplicationSemanticMaintenance.schedule(index, projectID: project)
        Thread.sleep(forTimeInterval: 0.2)
        let windowAfterSchedule = try store.backgroundBudgetSnapshot().window
        checks["semantic_policy_background_worker_schedules_no_semantic_work"] = !scheduled && encoder.calls == 0
            && windowAfterSchedule == nil

        // An explicit on-demand build still works under the policy.
        var published = 0
        while true {
            let receipt = try index.process(projectID: project)
            published += receipt.publishedChunks
            if receipt.scheduledSources == 0 && receipt.publishedChunks == 0 && receipt.failedChunks == 0 { break }
        }
        let windowAfterBuild = try store.backgroundBudgetSnapshot().window
        checks["semantic_policy_explicit_on_demand_build_still_works"] = published >= 6 && encoder.calls >= 6
            && windowAfterBuild != nil

        checks.merge(try preparationChecks(store: store, index: index, encoder: encoder, project: project, needle: needle)) { _, new in new }
        return checks
    }

    private static func preparationChecks(store: MemoryStore, index: SemanticIndex, encoder: Encoder, project: String,
                                          needle: MemoryEvent) throws -> [String: Bool] {
        let chat = try store.createConversation(projectID: project, title: "Synthetic policy request")
        let clock = Clock(), episodeID = UUID().uuidString, currentID = "policy-current"
        let prompt = "What is the heliostat retry delay?"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "policy-current-turn",
            humanEventID: currentID, episodeID: episodeID, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        defer { _ = try? lease.finish(reason: .cancelled) }
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, episodeLease: lease)
        func audit(_ snapshot: ContextSnapshot) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: snapshot.retrievalAuditJSON ?? Data("{}".utf8)) as? [String: Any] ?? [:]
        }
        func ranges(_ snapshot: ContextSnapshot) -> [String] {
            snapshot.evidence.map { "\($0.eventID):\($0.excerptOffset):\(ContextSnapshot.digest(Data($0.excerpt.utf8)))" }
        }
        var checks: [String: Bool] = [:]

        // Ordinary Send: the index is present but withheld by the policy.
        let callsBeforeOrdinary = encoder.calls
        let ordinary = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: currentID, semanticIndex: index, episodeLease: lease,
            semanticRetrieval: .ordinarySend)
        let ordinaryAudit = try audit(ordinary)
        checks["semantic_policy_ordinary_send_preparation_runs_no_semantic_search"] = encoder.calls == callsBeforeOrdinary
            && ordinary.retrievalManifestID == nil && ordinary.retrievalManifestJSON == nil
            && ordinaryAudit["mode"] as? String == "lexical" && ordinaryAudit["manifest_id"] == nil
        checks["semantic_policy_ordinary_send_audit_records_disabled_by_policy"] =
            ordinaryAudit[SemanticRetrievalPolicy.auditField] as? String == "disabled_by_policy"
                && ordinaryAudit["failure"] == nil
                && !(ordinary.retrievalNotice ?? "").lowercased().contains("unavailable")
                && !(ordinary.retrievalNotice ?? "").lowercased().contains("failed")
        checks["semantic_policy_ordinary_send_delivers_lexical_evidence"] =
            ordinary.evidence.contains { episodeIdentifierEqual($0.eventID, needle.id) }

        // The lexical harness arm: no index at all, default policy. Identical
        // selection; only the honest unavailability wording differs.
        let lexical = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: currentID, episodeLease: lease)
        let lexicalAudit = try audit(lexical)
        checks["semantic_policy_ordinary_send_selection_equals_lexical_arm"] = ranges(ordinary) == ranges(lexical)
            && ordinary.recentSourceIDs == lexical.recentSourceIDs && !ranges(ordinary).isEmpty
        checks["semantic_policy_missing_index_without_policy_still_reports_unavailable"] =
            lexicalAudit[SemanticRetrievalPolicy.auditField] == nil
                && (lexical.retrievalNotice ?? "").contains("unavailable")

        // Explicit evaluation hybrid keeps fused retrieval for comparisons.
        let callsBeforeHybrid = encoder.calls
        let hybrid = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: currentID, semanticIndex: index, episodeLease: lease)
        let hybridAudit = try audit(hybrid)
        checks["semantic_policy_explicit_evaluation_hybrid_still_uses_index"] = hybridAudit["mode"] as? String == "hybrid"
            && hybrid.retrievalManifestID != nil && encoder.calls == callsBeforeHybrid + 1
            && hybridAudit[SemanticRetrievalPolicy.auditField] == nil

        // Native-profile ordinary Send uses the single-stage preparation.
        let callsBeforeNative = encoder.calls
        let native = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, semanticIndex: index,
            semanticRetrieval: .ordinarySend)
        let nativeAudit = try audit(native)
        checks["semantic_policy_native_send_preparation_disabled_by_policy"] = encoder.calls == callsBeforeNative
            && nativeAudit["mode"] as? String == "lexical" && native.retrievalManifestID == nil
            && nativeAudit[SemanticRetrievalPolicy.auditField] as? String == "disabled_by_policy"
            && native.evidence.contains { episodeIdentifierEqual($0.eventID, needle.id) }

        // Coordinator boundary: GUI construction withholds the index; the
        // evaluation command's construction (default policy) passes it on.
        let runner = RefusingRunner()
        let ordinarySend = AnswerAttemptCoordinator(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, settings: GenerationSettings(), semanticIndex: index, semanticRetrieval: .ordinarySend,
            runner: runner, onText: { _ in }, onComplete: { _, _ in })
        let evaluation = AnswerAttemptCoordinator(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, settings: GenerationSettings(), semanticIndex: index, runner: runner,
            onText: { _ in }, onComplete: { _, _ in })
        checks["semantic_policy_ordinary_send_coordinator_receives_no_index"] = !ordinarySend.preparationReceivesSemanticIndex
        checks["semantic_policy_explicit_evaluation_coordinator_receives_index"] = evaluation.preparationReceivesSemanticIndex
        return checks
    }

    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-semantic-policy-clock", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }

    private final class RefusingRunner: AnswerAttemptRunning {
        var isRunning: Bool { false }
        func start(prompt: String, settings: GenerationSettings, conversation: Conversation,
                   onText: @escaping (String) -> Void, onComplete: @escaping (GenerationResult) -> Void) {
            onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: "synthetic_refused", stopped: false))
        }
        func cancel() {}
    }

    private final class Encoder: SemanticEmbeddingAdapter {
        let dimension = 3
        let metadata: [String: String] = ["provider": "synthetic-semantic-policy", "revision": "1"]
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func encode(_ text: String) throws -> SemanticEncoding {
            lock.lock(); count += 1; lock.unlock()
            if text.contains("heliostat") { return .vector([1, 0, 0]) }
            if text.contains("pebble") { return .vector([0, 1, 0]) }
            return .vector([0, 0, 1])
        }
    }
}
