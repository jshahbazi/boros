import Foundation
import CSQLite
import Darwin

/// Public synthetic source-access fixtures. Provider checks use the existing
/// loopback tokenizer/calibration fixture; no real model inference is needed.
enum RetrievalStrategyChecks {
    static func run() throws -> [String: Bool] {
        let directory = try fixtureDirectory(prefix: "boros-retrieval-strategy-")
        defer { try? FileManager.default.removeItem(at: directory) }
        var corruptEventID: String?, corruptByteCount = 0
        let store = try MemoryStore(directory: directory, episodeAccountingCheckpoint: { phase, database in
            if phase == "before-accounting-lookup", let eventID = corruptEventID {
                corruptEventID = nil
                try corruptPayload(database: database, eventID: eventID, byteCount: corruptByteCount)
            }
        })
        let project = "synthetic-strategy-project", prompt = "Where is strategyneedle? 日本語 e\u{301}"
        let chat = try store.createConversation(projectID: project, title: "Synthetic strategy recent")
        let archive = try store.createConversation(projectID: project, title: "Synthetic strategy archive")
        let old = try append(store, archive.id, "strategy-archive", "strategyneedle archived original value")
        let recentEvents = try ["strategy-recent-é", "strategy-recent-e\u{301}"].enumerated().map {
            try append(store, chat.id, $0.element, "Synthetic recent source \($0.offset) café e\u{301}",
                role: $0.offset == 0 ? .human : .assistant, status: $0.offset == 0 ? .complete : .partial)
        }
        let encoder = Encoder(), index = try SemanticIndex(store: store, encoder: encoder)
        _ = try index.process(projectID: project, maximumChunks: 32)
        let callsAfterBuild = encoder.calls
        let clock = Clock(), episodeID = UUID().uuidString, currentID = "strategy-current"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "strategy-current-turn",
            humanEventID: currentID, episodeID: episodeID, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, episodeLease: lease)
        let before = try lease.checkActive()
        let selected = try ChatContextPreparation.prepareEvidence(recent: recent, store: store,
            conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID,
            semanticIndex: index, retrievalStrategy: .recentOnly, episodeLease: lease)
        let after = try lease.checkActive()
        var checks: [String: Bool] = [
            "strategy_public_values_are_frozen": ContextRetrievalStrategy.allCases.map(\.rawValue) == ["hybrid", "recent_only"],
            "strategy_roundtrip_exact_choice": try JSONDecoder().decode(ContextRetrievalStrategy.self,
                from: JSONEncoder().encode(ContextRetrievalStrategy.recentOnly)) == .recentOnly,
            "strategy_recent_source_preparation_is_actual_and_charged": before.charged.rawSourceBytes
                == 2 * (prompt.utf8.count + recentEvents.reduce(0) { $0 + $1.byteCount })
                && before.charged.memoryOperations == 1 && before.charged.metadataRows > 0,
            "strategy_recent_only_no_historical_payload_metadata_vector_encoder_work": sourceWorkEqual(before.charged, after.charged)
                && encoder.calls == callsAfterBuild,
            "strategy_recent_only_uses_original_lease_and_one_selection_operation": after.id == episodeID
                && after.charged.memoryOperations == before.charged.memoryOperations + 1,
            "strategy_recent_only_preserves_mandatory_recent_bytes_and_provenance": try selected.serializedMessages() == recent.serializedMessages()
                && selected.selectionDigest() == recent.selectionDigest() && selected.evidence.isEmpty
                && selected.messages.last!.content.utf8.elementsEqual(prompt.utf8),
            "strategy_recent_only_preserves_distinct_utf8_source_ids": ExactSourceIDs(selected.recentSourceIDs).count == 2
                && selected.recentSourceIDs.map { Data($0.utf8) } == recentEvents.map { Data($0.id.utf8) },
            "strategy_recent_only_reports_actual_omission_without_manifest": try mode(selected) == "recent_only"
                && selected.retrievalManifestID == nil && selected.retrievalManifestJSON == nil && selected.retrievalNotice == nil
        ]
        let hybrid = try ChatContextPreparation.prepareEvidence(recent: recent, store: store,
            conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID,
            semanticIndex: index, episodeLease: lease)
        let hybridReceipt = try lease.checkActive()
        checks["strategy_default_hybrid_executes_historical_reads_and_query_embedding"] = encoder.calls == callsAfterBuild + 1
            && hybridReceipt.charged.rawSourceBytes > after.charged.rawSourceBytes
            && hybridReceipt.charged.vectorBytes > after.charged.vectorBytes
            && hybridReceipt.charged.encoderInputBytes == after.charged.encoderInputBytes + prompt.utf8.count
            && hybridReceipt.charged.modelCalls == after.charged.modelCalls + 1
        checks["strategy_default_hybrid_delivers_scoped_original_archive"] = try mode(hybrid) == "hybrid"
            && hybrid.evidence.contains { episodeIdentifierEqual($0.eventID, old.id) }
            && hybrid.recentSourceIDs.map { Data($0.utf8) } == selected.recentSourceIDs.map { Data($0.utf8) }
        let nilIndex = try ChatContextPreparation.prepareEvidence(recent: recent, store: store,
            conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID, episodeLease: lease)
        checks["strategy_nil_index_still_means_hybrid_lexical_selection"] = try mode(nilIndex) == "lexical"
            && nilIndex.evidence.contains { episodeIdentifierEqual($0.eventID, old.id) }
        let originals = recentEvents + [old]
        checks["strategy_hybrid_trace_has_exact_query_hash_ordinals_and_original_candidates"] = try validTrace(hybrid,
            query: "strategyneedle 日本語 e\u{301}", indices: [2, 3, 4], originals: originals)
        checks["strategy_nil_index_trace_has_exact_query_hash_ordinals_and_original_candidates"] = try validTrace(nilIndex,
            query: "strategyneedle 日本語 e\u{301}", indices: [2, 3, 4], originals: originals)
        checks["strategy_recent_only_has_no_historical_selection_trace"] = try object(selected.retrievalAuditJSON!)["selection_trace"] == nil
            && object(selected.retrievalAuditJSON!).count == 1
        let reduced = try recent.reducedRecentForComponentCap()!, beforeReductionSelection = try lease.checkActive()
        let reducedSelection = try ChatContextPreparation.prepareEvidence(recent: reduced, store: store,
            conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID,
            semanticIndex: index, retrievalStrategy: .recentOnly, episodeLease: lease)
        checks["strategy_recent_only_keeps_reduced_suffix_and_same_frozen_selection_contract"] = try reducedSelection.includedRecentCount == 1
            && reducedSelection.selectionAudit?.recentTokenExcludedCount == 1
            && reducedSelection.selectionBinding?.version == ContextSourceFraming.currentSelectionVersion
            && (try reducedSelection.componentAssignments()) == [.mandatory, .recent, .mandatory]
            && sourceWorkEqual(beforeReductionSelection.charged, try lease.checkActive().charged)
        var stale = recent
        stale.retrievalManifestID = hybrid.retrievalManifestID; stale.retrievalManifestJSON = hybrid.retrievalManifestJSON
        stale.retrievalAuditJSON = hybrid.retrievalAuditJSON; stale.retrievalNotice = "Synthetic earlier fallback"
        let clean = try ChatContextPreparation.prepareEvidence(recent: stale, store: store,
            conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID,
            retrievalStrategy: .recentOnly, episodeLease: lease)
        checks["strategy_recent_only_clears_stale_historical_manifest_and_fallback_audit"] = try mode(clean) == "recent_only"
            && clean.retrievalManifestJSON == nil && clean.retrievalManifestID == nil && clean.retrievalNotice == nil
            && (try object(clean.retrievalAuditJSON!)).count == 1
        let beforeWrong = try lease.checkActive()
        do {
            _ = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
                projectID: project, prompt: "Changed synthetic request", excludingEventID: currentID,
                semanticIndex: index, retrievalStrategy: .recentOnly, episodeLease: lease)
            checks["strategy_recent_only_still_rejects_changed_accepted_bytes"] = false
        } catch {
            checks["strategy_recent_only_still_rejects_changed_accepted_bytes"] = try error is ContextError
                && sourceWorkEqual(beforeWrong.charged, try lease.checkActive().charged) && encoder.calls == callsAfterBuild + 1
        }
        // Deliberate same-connection source corruption leaves accounting rows
        // untouched. An external commit would instead invalidate all funding
        // confidence, preventing this source-access isolation measurement.
        corruptEventID = old.id; corruptByteCount = old.byteCount
        let beforeCorruptSelection = try lease.checkActive(), callsBeforeCorrupt = encoder.calls
        _ = try ChatContextPreparation.prepareEvidence(recent: recent, store: store,
            conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID,
            semanticIndex: index, retrievalStrategy: .recentOnly, episodeLease: lease)
        checks["strategy_recent_only_leaves_corrupted_historical_source_unread"] = sourceWorkEqual(beforeCorruptSelection.charged,
            try lease.checkActive().charged) && encoder.calls == callsBeforeCorrupt
        do {
            _ = try ChatContextPreparation.prepareEvidence(recent: recent, store: store,
                conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID, episodeLease: lease)
            checks["strategy_archive_access_control_reaches_corruption_in_hybrid"] = false
        } catch {
            checks["strategy_archive_access_control_reaches_corruption_in_hybrid"] = error is MemoryError || error is MeteredRetrievalError || error is ContextError
        }
        let beforeLegacy = try lease.checkActive()
        let legacy = try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, semanticIndex: index,
            retrievalStrategy: .recentOnly, episodeLease: lease)
        let afterLegacy = try lease.checkActive()
        checks["strategy_legacy_prepare_recent_only_reads_only_actual_recent_sources"] = try mode(legacy) == "recent_only"
            && legacy.evidence.isEmpty && encoder.calls == callsBeforeCorrupt
            && afterLegacy.charged.rawSourceBytes - beforeLegacy.charged.rawSourceBytes == 2 * recentEvents.reduce(0) { $0 + $1.byteCount }
        _ = try lease.finish(reason: .cancelled)
        let terminal = try store.episodeReceipt(id: episodeID, clock: clock.now())
        do {
            _ = try ChatContextPreparation.prepareEvidence(recent: recent, store: store,
                conversationID: chat.id, projectID: project, prompt: prompt, excludingEventID: currentID,
                retrievalStrategy: .recentOnly, episodeLease: lease)
            checks["strategy_recent_only_terminal_lease_cannot_renew_preparation"] = false
        } catch {
            let untouched = try store.episodeReceipt(id: episodeID, clock: clock.now())
            checks["strategy_recent_only_terminal_lease_cannot_renew_preparation"] = error is EpisodeBudgetError
                && untouched.charged == terminal.charged && untouched.held == terminal.held
        }
        checks.merge(HistoricalQueryChecks.run()) { _, latest in latest }
        checks.merge(try anchorSelectionChecks()) { _, latest in latest }
        checks.merge(try directTraceChecks()) { _, latest in latest }
        checks.merge(try semanticRangeChecks()) { _, latest in latest }
        checks.merge(try precedingHumanChecks()) { _, latest in latest }
        checks.merge(try declaredSourceChecks()) { _, latest in latest }
        return checks
    }

    /// Runs the actual asynchronous selected-Qwen preparation and validates its
    /// unchanged invocation and archive contracts, using synthetic HTTP only.
    static func runIntegration(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        let suite = IntegrationSuite(baseURL: baseURL, completion: completion)
        suite.next()
    }

    private enum FixtureCase: String, CaseIterable {
        case hybridDefault, hybridExplicit, recentOnly, recentOnlyWithoutIndex, recentOnlyEnvelope, precedingHuman
        var strategy: ContextRetrievalStrategy { self == .hybridDefault || self == .hybridExplicit || self == .precedingHuman ? .hybrid : .recentOnly }
    }
    private final class IntegrationSuite {
        let baseURL: String, completion: ([String: Bool]) -> Void
        var cases = Array(FixtureCase.allCases), checks: [String: Bool] = [:]
        var current: IntegrationAttempt?
        init(baseURL: String, completion: @escaping ([String: Bool]) -> Void) { self.baseURL = baseURL; self.completion = completion }
        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try IntegrationAttempt(kind: kind, baseURL: baseURL) { [self] result in
                    checks.merge(result) { _, latest in latest }; current = nil; next()
                }
                current = attempt; attempt.start()
            } catch { checks["strategy_component_" + kind.rawValue + "_fixture_started"] = false; next() }
        }
    }
    private final class IntegrationAttempt {
        let kind: FixtureCase, directory: URL, store: MemoryStore, chat: StoredConversation
        let clock = Clock(), encoder = Encoder(), lease: EpisodeLease
        let index: SemanticIndex, recentSources: [MemoryEvent], archivedSource: MemoryEvent, archivedHuman: MemoryEvent?, callsAfterBuild: Int
        let prompt = "fixturePipeline Where is strategyneedle? 日本語 e\u{301}"
        let currentID = "strategy-component-current", completion: ([String: Bool]) -> Void
        var settings = GenerationSettings(), operation: ComponentContextPreparationOperation?
        init(kind: FixtureCase, baseURL: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.completion = completion
            directory = try fixtureDirectory(prefix: "boros-strategy-components-")
            store = try MemoryStore(directory: directory)
            chat = try store.createConversation(projectID: "synthetic-strategy-components", title: "Synthetic strategy preparation")
            let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic strategy evidence")
            archivedHuman = kind == .precedingHuman ? try append(store, archive.id, "strategy-component-human", "Synthetic original human anchor café\0", status: .partial) : nil
            archivedSource = try append(store, archive.id, "strategy-component-archive", "strategyneedle archived original source",
                role: kind == .precedingHuman ? .assistant : .human)
            var recent: [MemoryEvent] = []
            for sourceID in ["strategy-component-old-0", "strategy-component-old-1", "strategy-component-é", "strategy-component-e\u{301}"] {
                recent.append(try append(store, chat.id, sourceID, "Synthetic recent source " + String(repeating: "r", count: 2500),
                    role: recent.count % 2 == 0 ? .human : .assistant, status: recent.count == 3 ? .partial : .complete))
            }
            recentSources = recent
            index = try SemanticIndex(store: store, encoder: encoder)
            _ = try index.process(projectID: chat.projectID, maximumChunks: 32)
            callsAfterBuild = encoder.calls
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
            let episodeID = UUID().uuidString
            _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "strategy-component-turn",
                humanEventID: currentID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
            settings.profile = .customLocal; settings.endpointURL = baseURL; settings.endpointAPIKey = "synthetic-key"
            settings.endpointModel = Qwen38TextAdapter.modelID; settings.maximumOutput = 64; settings.temperature = 0
            settings.endpointContextLimit = kind == .recentOnlyEnvelope ? 3200 : 32768
            settings.endpointSafetyTokens = 256; settings.episodeLease = lease
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func start() {
            if kind == .hybridDefault {
                operation = ComponentContextPreparationOperation(store: store, conversationID: chat.id, projectID: chat.projectID,
                    humanEventID: currentID, prompt: prompt, settings: settings, conversation: Conversation(), semanticIndex: index,
                    episodeLease: lease) { [self] outcome in finish(outcome) }
            } else {
                operation = ComponentContextPreparationOperation(store: store, conversationID: chat.id, projectID: chat.projectID,
                    humanEventID: currentID, prompt: prompt, settings: settings, conversation: Conversation(),
                    semanticIndex: kind == .recentOnlyWithoutIndex ? nil : index, retrievalStrategy: kind.strategy,
                    episodeLease: lease) { [self] outcome in finish(outcome) }
            }
            operation?.start()
        }
        private struct AdmissionAudit: Codable {
            let version: Int, receipt: EndpointAdmissionReceipt, attempts: [ProviderAdmissionAccounting], context: Data
        }
        private func finish(_ outcome: Result<PreparedComponentContext, Error>) {
            var checks: [String: Bool] = [:], stage = "preparation"
            let prefix = "strategy_component_" + kind.rawValue
            do {
                let prepared = try outcome.get(), state = try lease.checkActive()
                guard let proof = prepared.receipt.componentProof else { throw ProviderAdmissionError.countMismatch }
                checks[prefix + "_same_original_lease_and_policy"] = try proof.episodeID == lease.episodeID
                    && prepared.settings.episodeLease === lease && state.limits.componentPolicy == .selectedQwen
                    && proof.policyDigest == EndpointRequest.digest(try ContextComponentPolicy.selectedQwen.canonicalData())
                checks[prefix + "_mandatory_bytes_output_reserve_and_safety_preserved"] = prepared.snapshot.messages.last!.content.utf8.elementsEqual(prompt.utf8)
                    && prepared.snapshot.messages.first!.content.utf8.elementsEqual(ContextAssembler.mandatoryMessages(prompt: prompt, system: settings.system)[0].content.utf8)
                    && prepared.receipt.outputReserve == 64 && prepared.receipt.safetyTokens == 256
                checks[prefix + "_real_recent_selection_and_reduction"] = prepared.snapshot.selectionAudit!.recentTokenExcludedCount > 0
                    && proof.recent.tokens <= 8000 && proof.evidence.tokens <= 12000
                    && prepared.snapshot.includedRecentCount < recentSources.count
                checks[prefix + "_exact_body_selection_and_count_proof"] = try prepared.settings.preparedEndpointBody == prepared.body
                    && prepared.settings.preparedContextComponents?.accepts(receipt: prepared.receipt, body: prepared.body, settings: prepared.settings) == true
                    && proof.sourceSnapshotDigest == (try prepared.snapshot.selectionDigest())
                    && proof.wholePrompt.tokens == prepared.receipt.promptTokens
                checks[prefix + "_recent_utf8_ids_remain_distinct"] = prepared.snapshot.recentSourceIDs.isEmpty
                    || (ExactSourceIDs(prepared.snapshot.recentSourceIDs).count == prepared.snapshot.recentSourceIDs.count
                        && prepared.snapshot.recentSourceIDs.map { Data($0.utf8) } == Array(recentSources.suffix(prepared.snapshot.includedRecentCount)).map { Data($0.id.utf8) })
                let expectedRecentBytes = 2 * (prompt.utf8.count + recentSources.reduce(0) { $0 + $1.byteCount })
                if kind.strategy == .recentOnly {
                    checks[prefix + "_zero_historical_source_query_encoder_and_vector_work"] = try state.charged.rawSourceBytes == expectedRecentBytes
                        && state.charged.encoderInputBytes == 0 && state.charged.vectorBytes == 0 && encoder.calls == callsAfterBuild
                        && (try count(store, "SELECT count(*) FROM episode_work WHERE kind='queryEmbedding'")) == 0
                    checks[prefix + "_zero_evidence_receipt_has_no_tokenizer_work"] = try prepared.snapshot.evidence.isEmpty
                        && proof.evidence.tokens == 0 && proof.evidence.tokenizerWorkID == nil
                        && (try mode(prepared.snapshot)) == "recent_only" && prepared.snapshot.retrievalManifestID == nil
                    checks[prefix + "_no_historical_trace_after_actual_reduction"] = try object(prepared.snapshot.retrievalAuditJSON!)["selection_trace"] == nil
                        && object(prepared.snapshot.retrievalAuditJSON!).count == 1
                    if kind == .recentOnlyEnvelope {
                        checks[prefix + "_whole_request_reduction_uses_same_lease"] = prepared.snapshot.selectionAudit!.recentEnvelopeExcludedCount > 0
                            && state.limits.componentPolicy!.recentTokens == 8000 && state.limits.componentPolicy!.evidenceTokens == 12000
                    }
                } else {
                    checks[prefix + "_real_index_historical_reads_and_query_work"] = try state.charged.rawSourceBytes > expectedRecentBytes
                        && state.charged.encoderInputBytes == prompt.utf8.count && state.charged.vectorBytes > 0
                        && encoder.calls == callsAfterBuild + 1 && !prepared.snapshot.evidence.isEmpty
                        && (try count(store, "SELECT count(*) FROM episode_work WHERE kind='queryEmbedding'")) == 1
                        && (try mode(prepared.snapshot)) == "hybrid"
                    checks[prefix + "_trace_retains_original_query_and_candidates_after_actual_reduction"] = try validTrace(prepared.snapshot,
                        query: "fixturepipeline strategyneedle 日本語 e\u{301}", indices: [0, 3, 4, 5], originals: recentSources + [archivedSource] + (archivedHuman.map { [$0] } ?? []))
                    if let archivedHuman {
                        checks[prefix + "_counted_preceding_human_and_assistant_both_delivered"] = prepared.snapshot.evidence.contains { $0.eventID == archivedSource.id }
                            && prepared.snapshot.evidence.contains { $0.eventID == archivedHuman.id && $0.excerpt.utf8.elementsEqual(archivedHuman.text.utf8)
                                && $0.status == .partial } && proof.evidence.tokens > 0
                        let expansion = try object(prepared.snapshot.retrievalAuditJSON!)["exchange_expansion"] as? [String: Any]
                        checks[prefix + "_counted_expansion_direction_remains_in_admission_audit"] = expansion?["version"] as? String == MeteredExchangeExpansion.adjacentVersion
                            && (expansion?["decisions"] as? [[String: Any]])?.contains { $0["direction"] as? String == "preceding_human" } == true
                    }
                    let delivered = try object(prepared.snapshot.deliveryAudit())["retrieval"] as? [String: Any]
                    checks[prefix + "_delivered_trace_matches_final_snapshot_audit"] = try canonical(delivered?["selection_trace"] ?? NSNull())
                        == canonical(trace(prepared.snapshot))
                }
                stage = "invocation"
                let work = try lease.prepare(kind: .answer,
                    resources: EpisodeResources(inputTokens: prepared.receipt.promptTokens, outputTokens: prepared.receipt.outputReserve,
                        modelCalls: 1, httpAttempts: 1), adapterIdentity: prepared.receipt.answerAdapterIdentity, snapshot: prepared.body)
                let admission = try JSONEncoder().encode(AdmissionAudit(version: 2, receipt: prepared.receipt,
                    attempts: prepared.receipt.accounting.map { [$0] } ?? [], context: prepared.snapshot.deliveryAudit()))
                _ = try store.beginInvocation(invocationID: "strategy-invocation", conversationID: chat.id, turnID: "strategy-component-turn",
                    humanEventID: currentID, assistantEventID: "strategy-component-assistant", providerIdentity: prepared.receipt.endpoint,
                    requestBody: prepared.body, admissionJSON: admission, episodeID: lease.episodeID, episodeWorkID: work.id)
                _ = try lease.finish(reason: .cancelled)
                _ = try store.finalizeInvocation(invocationID: "strategy-invocation", status: .cancelled, reason: .cancelled)
                checks[prefix + "_unchanged_invocation_validator_accepts_proof_and_audit"] = true
                stage = "archive_creation"
                let archived = directory.appendingPathComponent("strategy-verified-archive")
                let manifest = try BackupArchive.create(from: store, at: archived)
                stage = "archive_verification"
                let verified = try BackupArchive.verify(at: archived)
                checks[prefix + "_unchanged_archive_validator_accepts_strategy"] = manifest == verified && manifest.inventory.invocations == 1
                let restoredDirectory = directory.appendingPathComponent("strategy-restored-store")
                stage = "archive_restore"
                _ = try BackupArchive.restore(from: archived, to: restoredDirectory, authority: .unmanagedNoDeletion)
                let restored = try MemoryStore(directory: restoredDirectory)
                checks[prefix + "_restore_preserves_exact_body_and_existing_proof_bytes"] = try restored.invocation(id: "strategy-invocation")?.requestBody == prepared.body
                    && restored.invocation(id: "strategy-invocation")?.admissionJSON == admission
                    && restored.episodeReceipt(id: lease.episodeID, clock: clock.now()).charged == store.episodeReceipt(id: lease.episodeID, clock: clock.now()).charged
            } catch {
                checks[prefix + "_" + stage + "_completed"] = false
                checks[prefix + "_failure_" + failureCode(error)] = false
            }
            operation = nil; completion(checks)
        }
    }

    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-retrieval-strategy-clock", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }
    private final class Encoder: SemanticEmbeddingAdapter {
        let dimension = 3, metadata = ["provider": "synthetic-retrieval-strategy", "version": "1"]
        private(set) var calls = 0
        private(set) var lastInput: Data?
        var willEncode: (() throws -> Void)?
        func encode(_ text: String) throws -> SemanticEncoding {
            calls += 1; lastInput = Data(text.utf8); try willEncode?(); return .vector([1, 0, 0])
        }
    }
    private static func declaredSourceChecks() throws -> [String: Bool] {
        let directory = try fixtureDirectory(prefix: "boros-declared-sources-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-declared-project"
        let archive = try store.createConversation(projectID: project, title: "Synthetic original sources")
        let chat = try store.createConversation(projectID: project, title: "Synthetic control request")
        let foreignChat = try store.createConversation(projectID: "synthetic-foreign-project", title: "Synthetic foreign")
        let date = EventSourceTime(value: "2023-05-30", precision: "day", timezone: "unspecified",
            sourceSHA256: String(repeating: "c", count: 64), locator: "/synthetic/date", originalValue: "2023-05-30")
        let human = try store.append(conversationID: archive.id, role: .human, text: "Original café e\u{301}\0 source",
            status: .partial, turnID: "declared-human-turn", eventID: "declared-human", sourceTime: date)
        let assistant = try append(store, archive.id, "declared-assistant", "Original synthetic assistant reply", role: .assistant)
        let recentEvent = try append(store, chat.id, "declared-recent", "Original retained recent text")
        let empty = try append(store, archive.id, "declared-empty", "")
        let large = try append(store, archive.id, "declared-large", String(repeating: "x", count: 4097))
        let foreign = try append(store, foreignChat.id, "declared-foreign", "Foreign source must not be read")
        let distinctIDs = try ["declared-é", "declared-e\u{301}"].enumerated().map {
            try append(store, archive.id, $0.element, "Distinct original source \($0.offset)")
        }
        let prompt = "Synthetic source-control question", current = "declared-current", episode = UUID().uuidString, clock = Clock()
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "declared-current-turn",
            humanEventID: current, episodeID: episode, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episode, clock: clock)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: current, episodeLease: lease)
        func select(_ ids: [String], strategy: ContextRetrievalStrategy = .hybrid, funded: Bool = true) throws -> ContextSnapshot {
            try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
                projectID: project, prompt: prompt, excludingEventID: current, retrievalStrategy: strategy,
                episodeLease: funded ? lease : nil, evidenceSourceIDs: ids)
        }
        let before = try lease.checkActive(), selected = try select([assistant.id, recentEvent.id, human.id])
        let after = try lease.checkActive(), audit = try object(selected.retrievalAuditJSON!)
        var checks: [String: Bool] = [
            "declared_sources_preserve_declared_historical_order_without_neighbor_expansion": selected.evidence.map(\.eventID) == [assistant.id, human.id],
            "declared_sources_preserve_complete_original_utf8_role_status_and_date": selected.evidence.last?.excerpt.utf8.elementsEqual(human.text.utf8) == true
                && selected.evidence.last?.role == .human && selected.evidence.last?.status == .partial && selected.evidence.last?.sourceTime == date,
            "declared_sources_retain_recent_union_without_duplicate_evidence": selected.recentSourceIDs == [recentEvent.id]
                && selected.evidence.allSatisfy { $0.eventID != recentEvent.id },
            "declared_sources_keep_complete_mandatory_prompt_and_binding": selected.messages.last?.content == prompt
                && selected.selectionBinding?.mandatoryMessagesSHA256 == recent.selectionBinding?.mandatoryMessagesSHA256,
            "declared_sources_are_paid_under_original_lease_and_caps": after.id == before.id && after.limits == before.limits
                && after.charged.memoryOperations == before.charged.memoryOperations + 1
                && after.charged.rawSourceBytes >= before.charged.rawSourceBytes + 4 * (human.byteCount + assistant.byteCount)
                && after.charged.metadataRows > before.charged.metadataRows,
            "declared_sources_perform_no_encoder_vector_or_inference_work": after.charged.encoderInputBytes == before.charged.encoderInputBytes
                && after.charged.vectorBytes == before.charged.vectorBytes && after.charged.modelCalls == before.charged.modelCalls,
            "declared_sources_report_control_identity_and_original_inventory": audit["mode"] as? String == "declared_original_sources"
                && audit["version"] as? String == "declared-original-sources-v1" && audit["declared_source_count"] as? Int == 3
                && audit["declared_source_bytes"] as? Int == human.byteCount + assistant.byteCount + recentEvent.byteCount
                && selected.retrievalManifestJSON == nil && selected.retrievalManifestID == nil
        ]
        let invalid: [(String, [String])] = [("empty", []), ("duplicate", [human.id, human.id]),
            ("request", [current]), ("nul_id", ["bad\0id"]), ("long_id", [String(repeating: "x", count: 257)]),
            ("candidate_cap", (0..<17).map { "synthetic-id-\($0)" }), ("missing", [human.id, "declared-missing"]),
            ("foreign", [human.id, foreign.id]), ("empty_source", [human.id, empty.id]), ("page_cap", [human.id, large.id])]
        for (name, ids) in invalid {
            let before = try lease.checkActive()
            do { _ = try select(ids); checks["declared_sources_refuse_\(name)_before_payload"] = false }
            catch { checks["declared_sources_refuse_\(name)_before_payload"] = try lease.checkActive().charged.rawSourceBytes == before.charged.rawSourceBytes }
        }
        for (name, strategy, funded) in [("recent_only", ContextRetrievalStrategy.recentOnly, true), ("unfunded", .hybrid, false)] {
            let before = try lease.checkActive()
            do { _ = try select([human.id], strategy: strategy, funded: funded); checks["declared_sources_refuse_\(name)"] = false }
            catch {
                let after = try lease.checkActive()
                checks["declared_sources_refuse_\(name)"] = error is MeteredRetrievalError
                    && after.charged.rawSourceBytes == before.charged.rawSourceBytes
            }
        }
        let distinct = try select(distinctIDs.map(\.id))
        checks["declared_sources_keep_byte_distinct_unicode_identifiers"] = distinct.evidence.map { Data($0.eventID.utf8) }
            == distinctIDs.map { Data($0.id.utf8) }
        let limitedChat = try store.createConversation(projectID: project, title: "Synthetic exhausted source control")
        var limits = EpisodeLimits(); limits.resources.rawSourceBytes = 2 * prompt.utf8.count
        let limitedID = UUID().uuidString, limitedHuman = "declared-limited-human"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: limitedChat.id, turnID: "declared-limited-turn",
            humanEventID: limitedHuman, episodeID: limitedID, text: prompt, limits: limits, clock: clock.now())
        let limitedLease = EpisodeLease(ledger: store, episodeID: limitedID, clock: clock)
        let limitedRecent = try ContextAssembler.prepareRecent(store: store, conversationID: limitedChat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: limitedHuman, episodeLease: limitedLease)
        let limitedBefore = try limitedLease.checkActive()
        do {
            _ = try ChatContextPreparation.prepareEvidence(recent: limitedRecent, store: store, conversationID: limitedChat.id,
                projectID: project, prompt: prompt, excludingEventID: limitedHuman, episodeLease: limitedLease,
                evidenceSourceIDs: [human.id])
            checks["declared_sources_exhausted_raw_allowance_prevents_payload"] = false
        } catch {
            let state = try store.episodeReceipt(id: limitedID, clock: clock.now())
            checks["declared_sources_exhausted_raw_allowance_prevents_payload"] = error is EpisodeBudgetError
                && state.state == .budgetExceeded
                && state.charged.rawSourceBytes == limitedBefore.charged.rawSourceBytes && state.limits == limits
                && state.held.rawSourceBytes == 0
        }
        _ = try limitedLease.finish(reason: .cancelled)
        _ = try lease.finish(reason: .cancelled)
        let terminal = try store.episodeReceipt(id: episode, clock: clock.now())
        do { _ = try select([human.id]); checks["declared_sources_terminal_cannot_renew_reads"] = false }
        catch { checks["declared_sources_terminal_cannot_renew_reads"] = try error is EpisodeBudgetError
            && store.episodeReceipt(id: episode, clock: clock.now()).charged == terminal.charged }
        return checks
    }

    private static func precedingHumanChecks() throws -> [String: Bool] {
        let directory = try fixtureDirectory(prefix: "boros-preceding-strategy-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-preceding-strategy"
        let archive = try store.createConversation(projectID: project, title: "Synthetic archived exchange")
        let chat = try store.createConversation(projectID: project, title: "Synthetic current request")
        let date = EventSourceTime(value: "2023-05-30", precision: "day", timezone: "unspecified",
            sourceSHA256: String(repeating: "b", count: 64), locator: "/synthetic/session/date", originalValue: "2023-05-30")
        let human = try store.append(conversationID: archive.id, role: .human, text: "Synthetic original human café e\u{301}\0",
            status: .partial, turnID: "preceding-original-human-turn", eventID: "preceding-original-human", sourceTime: date)
        let assistant = try append(store, archive.id, "preceding-selected-assistant", "adjacencyneedle synthetic assistant reply", role: .assistant)
        let prompt = "adjacencyneedle", current = "preceding-current", episode = UUID().uuidString, clock = Clock()
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "preceding-current-turn",
            humanEventID: current, episodeID: episode, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episode, clock: clock)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: current, episodeLease: lease)
        let before = try lease.checkActive()
        let recalled = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: current, episodeLease: lease)
        let after = try lease.checkActive()
        let audit = try object(recalled.retrievalAuditJSON!), expansion = audit["exchange_expansion"] as? [String: Any]
        let beforeRecentOnly = try lease.checkActive()
        let onlyRecent = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: current, retrievalStrategy: .recentOnly, episodeLease: lease)
        let afterRecentOnly = try lease.checkActive()
        _ = try lease.finish(reason: .cancelled)
        return [
            "strategy_shared_lexical_fallback_recovers_preceding_human_without_query_match": recalled.evidence.map(\.eventID) == [assistant.id, human.id],
            "strategy_preceding_human_preserves_exact_bytes_status_time_and_mandatory_prompt": recalled.evidence.last?.excerpt.utf8.elementsEqual(human.text.utf8) == true
                && recalled.evidence.last?.sourceTime == date && recalled.evidence.last?.status == .partial
                && recalled.messages.last?.content == prompt
                && recalled.selectionBinding?.projectID == recent.selectionBinding?.projectID
                && recalled.selectionBinding?.conversationID == recent.selectionBinding?.conversationID
                && recalled.selectionBinding?.acceptedHumanEventID == current
                && recalled.selectionBinding?.mandatoryMessagesSHA256 == recent.selectionBinding?.mandatoryMessagesSHA256
                && recalled.selectionBinding?.version == recent.selectionBinding?.version,
            "strategy_adjacent_expansion_is_audited_and_funded_under_original_lease": expansion?["version"] as? String == MeteredExchangeExpansion.adjacentVersion
                && expansion?["added_neighbor_count"] as? Int == 1 && after.id == before.id && after.limits == before.limits
                && after.charged.rawSourceBytes >= before.charged.rawSourceBytes + 2 * (human.byteCount + 1),
            "strategy_recent_only_still_avoids_preceding_human_source_work": onlyRecent.evidence.isEmpty
                && sourceWorkEqual(beforeRecentOnly.charged, afterRecentOnly.charged)
        ]
    }

    private static func semanticRangeChecks() throws -> [String: Bool] {
        let directory = try fixtureDirectory(prefix: "boros-semantic-range-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-semantic-range"
        let archive = try store.createConversation(projectID: project, title: "Synthetic semantic sources")
        let chat = try store.createConversation(projectID: project, title: "Synthetic semantic query")
        _ = try append(store, archive.id, "semantic-range-source", "semanticneedle original source")
        let encoder = Encoder(), index = try SemanticIndex(store: store, encoder: encoder)
        _ = try index.process(projectID: project, maximumChunks: 8)
        let semanticText = "Return synthetic café κ\u{0}", lexicalText = "semanticneedle"
        let prompt = "Question Date: 2023/05/23 (Tue) 11:23\nLexical: " + lexicalText + "\nQuestion: " + semanticText
        let lexicalStart = "Question Date: 2023/05/23 (Tue) 11:23\nLexical: ".utf8.count
        let lexicalRange = lexicalStart..<(lexicalStart + lexicalText.utf8.count)
        let semanticRange = (prompt.utf8.count - semanticText.utf8.count)..<prompt.utf8.count
        let clock = Clock(), id = UUID().uuidString, currentID = "semantic-range-request"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "semantic-range-turn", humanEventID: currentID,
            episodeID: id, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: id, clock: clock)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, episodeLease: lease)
        func prepare(_ range: Range<Int>?, lexical: Range<Int>? = nil, strategy: ContextRetrievalStrategy = .hybrid,
            hasIndex: Bool = true) throws -> ContextSnapshot {
            try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
                projectID: project, prompt: prompt, excludingEventID: currentID, semanticIndex: hasIndex ? index : nil,
                retrievalStrategy: strategy, episodeLease: lease, lexicalQueryUTF8Range: lexical, semanticQueryUTF8Range: range)
        }
        let before = try lease.checkActive(), initialCalls = encoder.calls
        var prepaid = false
        encoder.willEncode = {
            let atEncoding = try lease.checkActive()
            prepaid = atEncoding.id == before.id && atEncoding.limits == before.limits
                && atEncoding.charged.modelCalls == before.charged.modelCalls + 1
                && atEncoding.charged.encoderInputBytes == before.charged.encoderInputBytes + semanticText.utf8.count
        }
        let selected = try prepare(semanticRange, lexical: lexicalRange)
        encoder.willEncode = nil
        let after = try lease.checkActive(), audit = try object(selected.retrievalAuditJSON!)
        let trace = audit["selection_trace"] as! [String: Any], manifest = try object(selected.retrievalManifestJSON!)
        let semanticSHA = ContextSnapshot.digest(Data(semanticText.utf8))
        var checks: [String: Bool] = [
            "semantic_range_exact_unicode_nul_slice_reaches_encoder_after_funding": prepaid && encoder.calls == initialCalls + 1
                && encoder.lastInput == Data(semanticText.utf8) && after.charged.encoderInputBytes == before.charged.encoderInputBytes + semanticText.utf8.count,
            "semantic_range_preserves_full_accepted_mandatory_prompt": Data(selected.messages.last!.content.utf8) == Data(prompt.utf8)
                && selected.selectionBinding?.acceptedHumanEventID == currentID,
            "semantic_range_trace_binds_selected_hash_offsets_to_manifest_and_full_prompt": trace["semantic_input_sha256"] as? String == semanticSHA
                && audit["query_sha256"] as? String == semanticSHA && manifest["queryDigest"] as? String == semanticSHA
                && trace["semantic_input_version"] as? String == "accepted-prompt-utf8-range-v1"
                && trace["semantic_input_offset"] as? Int == semanticRange.lowerBound && trace["semantic_input_bytes"] as? Int == semanticRange.count
                && trace["accepted_prompt_sha256"] as? String == ContextSnapshot.digest(Data(prompt.utf8)),
            "semantic_range_is_independent_of_lexical_range": trace["lexical_input_sha256"] as? String == ContextSnapshot.digest(Data(lexicalText.utf8))
                && trace["lexical_query_sha256"] as? String == ContextSnapshot.digest(Data(lexicalText.utf8))
        ]
        let semanticOnly = try prepare(semanticRange), onlyTrace = try object(semanticOnly.retrievalAuditJSON!)["selection_trace"] as! [String: Any]
        checks["semantic_range_only_leaves_full_prompt_lexical_default"] = onlyTrace["lexical_input_sha256"] == nil
            && onlyTrace["lexical_query_sha256"] as? String == ContextSnapshot.digest(Data((HistoricalQueryFormulation.formulate(prompt).query ?? "").utf8))
        _ = try prepare(nil)
        checks["semantic_range_nil_preserves_full_prompt_embedding_default"] = encoder.lastInput == Data(prompt.utf8)
        let skipBefore = try lease.checkActive(), skipCalls = encoder.calls
        let skipped = try prepare(semanticRange, lexical: lexicalRange, strategy: .recentOnly)
        checks["semantic_range_recent_only_skips_historical_and_encoder_work"] = try encoder.calls == skipCalls
            && sourceWorkEqual(skipBefore.charged, lease.checkActive().charged) && object(skipped.retrievalAuditJSON!).count == 1
        let nilIndex = try prepare(semanticRange, lexical: lexicalRange, hasIndex: false)
        checks["semantic_range_missing_index_keeps_input_trace_without_encoding"] = try encoder.calls == skipCalls
            && (object(nilIndex.retrievalAuditJSON!)["selection_trace"] as! [String: Any])["semantic_input_sha256"] as? String == semanticSHA
        let split = Data(prompt.utf8).range(of: Data("é".utf8))!.lowerBound + 1
        for (name, invalid) in [("negative", -1..<1), ("empty", 0..<0), ("overflow", 0..<(prompt.utf8.count + 1)), ("split_scalar", split..<(split + 1))] {
            let prior = try lease.checkActive(), calls = encoder.calls
            do { _ = try prepare(invalid); checks["semantic_range_refuses_" + name + "_before_encoding"] = false }
            catch {
                checks["semantic_range_refuses_" + name + "_before_encoding"] = try (error as? HistoricalQueryFormulation.InputError) == .invalidRange
                    && encoder.calls == calls && sourceWorkEqual(prior.charged, lease.checkActive().charged)
            }
        }
        return checks
    }

    private static func sourceWorkEqual(_ left: EpisodeResources, _ right: EpisodeResources) -> Bool {
        left.rawSourceBytes == right.rawSourceBytes && left.metadataRows == right.metadataRows
            && left.vectorBytes == right.vectorBytes && left.encoderInputBytes == right.encoderInputBytes
            && left.modelCalls == right.modelCalls && left.inputTokens == right.inputTokens
    }
    private static func directTraceChecks() throws -> [String: Bool] {
        let directory = try fixtureDirectory(prefix: "boros-selection-trace-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-selection-trace"
        let chat = try store.createConversation(projectID: project, title: "Synthetic trace recent")
        let archive = try store.createConversation(projectID: project, title: "Synthetic trace history")
        let recentSource = try append(store, chat.id, "trace-recent", "Synthetic retained recent source")
        let prompt = "Synthetic accepted trace request"
        let current = try append(store, chat.id, "trace-current", prompt)
        let oversized = try append(store, archive.id, "trace-oversized", String(repeating: "x", count: 4097))
        let small = try append(store, archive.id, "trace-small", "Synthetic tiny historical source é e\u{301}")
        let other = try append(store, archive.id, "trace-other", "Synthetic second historical source")
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic trace host", excludingEventID: current.id)
        let candidates = [recentSource, current, oversized, small, other].map(hit)
        func attach(_ base: ContextSnapshot, _ hits: [MemoryHit], bytes: Int = ContextAssembler.componentMaximumEvidenceBytes,
            spans: Int = 1) throws -> ContextSnapshot {
            try ContextAssembler.addEvidence(to: base, store: store, conversationID: chat.id, projectID: project,
                excludingEventID: current.id, historicalHits: hits, maximumEvidenceBytes: bytes, maximumEvidenceSpans: spans)
        }
        let selected = try attach(recent, candidates), selectedTrace = try trace(selected)
        let expectedReasons = ["excluded_recent_or_request", "excluded_recent_or_request", "invalid_span_size", "included", "span_limit"]
        var checks: [String: Bool] = [
            "strategy_trace_distinguishes_recent_request_oversize_inclusion_and_span_cap": try dispositions(selected) == expectedReasons
                && selected.evidence.map(\.eventID) == [small.id] && selected.selectionAudit?.evidenceByteExcludedCount == 1
                && selected.selectionAudit?.evidenceRowExcludedCount == 1,
            "strategy_trace_records_exact_original_utf8_spans_and_zero_based_ranks": try canonical(selectedTrace["candidates"] ?? NSNull())
                == canonical(candidates.enumerated().map { rank, candidate in
                    ["event_id": candidate.eventID, "source_sha256": candidate.digest, "offset": 0,
                     "byte_length": candidate.excerpt.utf8.count, "rank": rank] as [String: Any]
                }) && (selectedTrace["candidate_count"] as? Int) == 5 && (selectedTrace["trace_truncated"] as? Bool) == false
        ]
        let byteLimited = try attach(recent, [hit(small)], bytes: 0)
        checks["strategy_trace_distinguishes_evidence_byte_cap_without_changing_recent_body"] = try dispositions(byteLimited) == ["evidence_byte_limit"]
            && byteLimited.evidence.isEmpty && byteLimited.serializedMessages() == recent.serializedMessages()
        var tightEnvelope = recent
        tightEnvelope.selectionAudit?.maximumSerializedBytes = recent.serializedBytes
        let envelopeLimited = try attach(tightEnvelope, [hit(small)])
        checks["strategy_trace_distinguishes_whole_envelope_cap_without_changing_body"] = try dispositions(envelopeLimited) == ["envelope_byte_limit"]
            && envelopeLimited.evidence.isEmpty && envelopeLimited.serializedMessages() == recent.serializedMessages()
        let bounded = try attach(recent, Array(repeating: hit(small), count: 17)), boundedTrace = try trace(bounded)
        let boundedCandidates = boundedTrace["candidates"] as? [[String: Any]] ?? []
        checks["strategy_trace_caps_metadata_at_sixteen_and_reports_returned_candidate_count"] = try (boundedTrace["candidate_count"] as? Int) == 17
            && (boundedTrace["trace_truncated"] as? Bool) == true && boundedCandidates.count == 16
            && boundedCandidates.compactMap { $0["rank"] as? Int } == Array(0..<16)
            && (try dispositions(bounded)) == ["included"] + Array(repeating: "span_limit", count: 15)
            && bounded.evidence.count == 1
        let evidenceReduced = try selected.reducedEvidenceForComponentCap()!
        let envelopeReduced = try selected.reducedForTokenAdmission()!
        let recentReduced = try selected.reducedRecentForComponentCap()!
        let recentEnvelopeReduced = try envelopeReduced.reducedForTokenAdmission()!
        checks["strategy_trace_survives_evidence_component_and_envelope_reductions"] = try canonical(trace(evidenceReduced)) == canonical(selectedTrace)
            && canonical(trace(envelopeReduced)) == canonical(selectedTrace) && evidenceReduced.evidence.isEmpty && envelopeReduced.evidence.isEmpty
            && evidenceReduced.selectionAudit?.evidenceTokenExcludedCount == 1 && envelopeReduced.selectionAudit?.evidenceEnvelopeExcludedCount == 1
        checks["strategy_trace_survives_recent_component_and_envelope_reductions"] = try canonical(trace(recentReduced)) == canonical(selectedTrace)
            && canonical(trace(recentEnvelopeReduced)) == canonical(selectedTrace) && recentReduced.includedRecentCount == 0
            && recentEnvelopeReduced.includedRecentCount == 0 && recentReduced.evidence.map(\.eventID) == [small.id]
            && recentReduced.selectionAudit?.recentTokenExcludedCount == 1 && recentEnvelopeReduced.selectionAudit?.recentEnvelopeExcludedCount == 1
        let baseline = try object(selected.deliveryAudit())
        var expanded = selected, expandedRetrieval = try object(selected.retrievalAuditJSON!), expandedTrace = selectedTrace
        expandedTrace["synthetic_padding"] = String(repeating: "x", count: 33000)
        expandedRetrieval["selection_trace"] = expandedTrace
        expanded.retrievalAuditJSON = try canonical(expandedRetrieval)
        let trimmedBytes = try expanded.deliveryAudit(), trimmed = try object(trimmedBytes)
        let trimmedRetrieval = trimmed["retrieval"] as? [String: Any] ?? [:]
        checks["strategy_trace_overflow_omits_only_auxiliary_metadata_with_explicit_reason"] = trimmedBytes.count <= 32768
            && trimmedRetrieval["selection_trace"] == nil && (trimmedRetrieval["selection_trace_omitted"] as? String) == "metadata_limit"
            && (baseline["retrieval"] as? [String: Any])?["selection_trace"] != nil
        var baselineCore = baseline, trimmedCore = trimmed
        baselineCore.removeValue(forKey: "retrieval"); trimmedCore.removeValue(forKey: "retrieval")
        checks["strategy_trace_overflow_preserves_original_selection_body_and_core_admission_audit"] = try canonical(baselineCore) == canonical(trimmedCore)
            && expanded.selectionDigest() == selected.selectionDigest() && expanded.serializedMessages() == selected.serializedMessages()
        expandedRetrieval["exchange_expansion"] = ["synthetic_padding": String(repeating: "y", count: 33000)]
        expanded.retrievalAuditJSON = try canonical(expandedRetrieval)
        let exchangeTrimmed = try object(expanded.deliveryAudit())
        let exchangeRetrieval = exchangeTrimmed["retrieval"] as? [String: Any] ?? [:]
        var exchangeCore = exchangeTrimmed; exchangeCore.removeValue(forKey: "retrieval")
        checks["strategy_exchange_trace_overflow_preserves_core_with_explicit_omission"] = try exchangeRetrieval["exchange_expansion"] == nil
            && exchangeRetrieval["exchange_expansion_omitted"] as? String == "metadata_limit"
            && canonical(exchangeCore) == canonical(baselineCore)
        let traceBytes = try canonical(selectedTrace)
        checks["strategy_trace_contains_metadata_without_query_or_source_text"] = traceBytes.range(of: Data(prompt.utf8)) == nil
            && traceBytes.range(of: Data(small.text.utf8)) == nil && traceBytes.range(of: Data(recentSource.text.utf8)) == nil
        return checks
    }
    private static func anchorSelectionChecks() throws -> [String: Bool] {
        let directory = try fixtureDirectory(prefix: "boros-anchor-selection-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory), project = "synthetic-anchor-selection"
        let chat = try store.createConversation(projectID: project, title: "Synthetic current")
        let archive = try store.createConversation(projectID: project, title: "Synthetic archive")
        let first = try append(store, archive.id, "anchor-first-human", "rivet lattice requested configuration")
        let reply = try append(store, archive.id, "anchor-first-assistant", "The archived setting is copper.", role: .assistant)
        let second = try append(store, archive.id, "anchor-second-human", "cobalt thimble requested configuration")
        let secondReply = try append(store, archive.id, "anchor-second-assistant", "The other archived setting is spruce.", role: .assistant, status: .partial)
        let prompt = "Quote exactly first nonempty line trim whitespace of reply to \"rivet lattice\" and \"cobalt thimble\" return JSON answer citations"
        let clock = Clock(), episodeID = UUID().uuidString, currentID = "anchor-current"
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "anchor-current-turn",
            humanEventID: currentID, episodeID: episodeID, text: prompt, limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id, projectID: project,
            prompt: prompt, system: "Synthetic host", excludingEventID: currentID, episodeLease: lease)
        let before = try lease.checkActive()
        let selected = try ChatContextPreparation.prepareEvidence(recent: recent, store: store, conversationID: chat.id,
            projectID: project, prompt: prompt, excludingEventID: currentID, episodeLease: lease)
        let after = try lease.checkActive(), audit = try object(selected.retrievalAuditJSON!)
        let expanded = audit["exchange_expansion"] as? [String: Any] ?? [:]
        let ids = ExactSourceIDs(selected.evidence.map(\.eventID))
        let checks: [String: Bool] = [
            "strategy_quoted_anchors_recover_both_original_replies_through_shared_selection": ids.count == 4
                && [first, reply, second, secondReply].allSatisfy { ids.contains($0.id) },
            "strategy_adjacent_reply_retains_exact_bytes_role_status_and_range": selected.evidence.contains {
                $0.eventID == secondReply.id && $0.role == .assistant && $0.status == .partial && $0.excerptOffset == 0
                    && $0.digest == secondReply.digest && $0.excerpt.utf8.elementsEqual(secondReply.text.utf8)
            },
            "strategy_anchor_and_neighbor_work_charged_to_original_episode": after.id == episodeID
                && after.charged.memoryOperations == before.charged.memoryOperations + 1
                && after.charged.rawSourceBytes > before.charged.rawSourceBytes && after.charged.metadataRows > before.charged.metadataRows,
            "strategy_adjacent_selection_audit_reports_two_bounded_additions": expanded["version"] as? String == MeteredExchangeExpansion.adjacentVersion
                && expanded["added_neighbor_count"] as? Int == 2 && expanded["dropped_primary_count"] as? Int == 0,
            "strategy_quoted_query_trace_binds_selected_originals": try validTrace(selected,
                query: "rivet cobalt lattice thimble quote exactly first nonempty", indices: [10, 13, 11, 14, 0, 1, 2, 3],
                originals: [first, reply, second, secondReply])
        ]
        _ = try lease.finish(reason: .cancelled)
        return checks
    }
    private static func hit(_ source: MemoryEvent) -> MemoryHit {
        MemoryHit(eventID: source.id, conversationID: source.conversationID, projectID: source.projectID,
            role: source.role, status: source.status, createdAt: source.createdAt, digest: source.digest,
            totalBytes: source.byteCount, excerptOffset: 0, excerpt: source.text)
    }
    private static func trace(_ snapshot: ContextSnapshot) throws -> [String: Any] {
        guard let audit = snapshot.retrievalAuditJSON, let trace = try object(audit)["selection_trace"] as? [String: Any] else {
            throw ContextError.sourceMismatch
        }
        return trace
    }
    private static func dispositions(_ snapshot: ContextSnapshot) throws -> [String] {
        guard let decisions = try trace(snapshot)["assembly"] as? [[String: Any]] else { throw ContextError.sourceMismatch }
        return decisions.compactMap { $0["disposition"] as? String }
    }
    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }
    private static func validTrace(_ snapshot: ContextSnapshot, query: String, indices: [Int], originals: [MemoryEvent]) throws -> Bool {
        let value = try trace(snapshot)
        guard value["version"] as? String == "historical-selection-trace-v1",
              value["lexical_query_version"] as? String == HistoricalQueryFormulation.version,
              value["lexical_query_sha256"] as? String == ContextSnapshot.digest(Data(query.utf8)),
              value["lexical_term_count"] as? Int == indices.count, value["lexical_selected_token_indices"] as? [Int] == indices,
              let count = value["candidate_count"] as? Int, let candidates = value["candidates"] as? [[String: Any]],
              let decisions = value["assembly"] as? [[String: Any]], candidates.count == min(count, 16), decisions.count == candidates.count,
              value["trace_truncated"] as? Bool == (count > 16) else { return false }
        let allowed = Set(["excluded_recent_or_request", "span_limit", "invalid_span_size", "evidence_byte_limit", "envelope_byte_limit", "included"])
        for (rank, candidate) in candidates.enumerated() {
            guard Set(candidate.keys) == Set(["event_id", "source_sha256", "offset", "byte_length", "rank"]),
                  let id = candidate["event_id"] as? String, let original = originals.first(where: { episodeIdentifierEqual($0.id, id) }),
                  candidate["source_sha256"] as? String == original.digest, candidate["rank"] as? Int == rank,
                  let offset = candidate["offset"] as? Int, let length = candidate["byte_length"] as? Int,
                  offset >= 0, length > 0, offset <= original.byteCount, length <= original.byteCount - offset,
                  Set(decisions[rank].keys) == Set(["event_id", "rank", "disposition"]),
                  decisions[rank]["event_id"] as? String == id, decisions[rank]["rank"] as? Int == rank,
                  let disposition = decisions[rank]["disposition"] as? String, allowed.contains(disposition) else { return false }
        }
        return snapshot.evidence.allSatisfy { hit in
            decisions.contains { ($0["event_id"] as? String).map { episodeIdentifierEqual($0, hit.eventID) } == true
                && $0["disposition"] as? String == "included" }
        }
    }
    private static func fixtureDirectory(prefix: String) throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ContextError.invalidBudget }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    }
    private static func failureCode(_ error: Error) -> String {
        // Only fixed host error codes enter the content-free fixture report.
        if let error = error as? EpisodeBudgetError { return error.failureCode }
        if let error = error as? ProviderAdmissionError { return error.failureCode }
        if case BackupError.invalid(let reason) = error {
            switch reason {
            case "episode journal failed integrity verification": return "backup_episode_journal"
            case "source payload failed digest, length or UTF-8 verification": return "backup_source_integrity"
            case "source table, column, index or constraint contract is not a recognized Boros schema",
                 "table, column, index or constraint contract is not a recognized Boros schema": return "backup_schema_contract"
            case "destination parent is missing or contains a symbolic link": return "backup_destination_parent"
            case "invalid loopback provider identity": return "backup_provider_identity"
            case "archive must be a private real directory owned by this user": return "backup_directory"
            case "admission or usage receipt digest mismatch": return "backup_receipt_digest"
            default: return "backup_invalid"
            }
        }
        if case MemoryError.database(let reason) = error {
            switch reason {
            case "episode archive scope mismatch": return "journal_scope"
            case "episode archive clock mismatch": return "journal_clock"
            case "component journal selection provenance mismatch": return "journal_selection"
            default: return "journal_database"
            }
        }
        return "fixture_failed"
    }
    private static func append(_ store: MemoryStore, _ conversationID: String, _ eventID: String, _ text: String,
        role: MemoryRole = .human, status: CaptureStatus = .complete) throws -> MemoryEvent {
        try store.append(conversationID: conversationID, role: role, text: text, status: status, turnID: "synthetic-turn-" + eventID, eventID: eventID)
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ContextError.invalidBudget }
        return result
    }
    private static func mode(_ snapshot: ContextSnapshot) throws -> String? {
        try snapshot.retrievalAuditJSON.map { try object($0)["mode"] as? String } ?? nil
    }
    private static func count(_ store: MemoryStore, _ sql: String) throws -> Int {
        try database(store, readonly: true) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ContextError.invalidBudget }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ContextError.invalidBudget }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
    private static func corruptPayload(database: OpaquePointer, eventID: String, byteCount: Int) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "UPDATE events SET payload=zeroblob(?) WHERE id=?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw ContextError.invalidBudget }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(byteCount))
            _ = eventID.withCString { sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else { throw ContextError.invalidBudget }
    }
    private static func database<T>(_ store: MemoryStore, readonly: Bool, operation: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(store.directory.appendingPathComponent("memory.sqlite3").path, &raw,
            readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = raw else {
            if let raw { sqlite3_close(raw) }; throw ContextError.invalidBudget
        }
        defer { sqlite3_close(database) }
        return try operation(database)
    }
}
