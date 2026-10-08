import Foundation
import CSQLite
import Darwin

/// Journal contract for the explicit P2 exchange policies. Each case runs the
/// actual component preparation against the declared synthetic tokenizer,
/// records the prepared request as a cancelled invocation, and validates it
/// with the unchanged `ContextComponentJournal.validate` and episode journal
/// validators. Only fixed synthetic sources enter the store.
enum ExchangeEpisodeChecks {
    static func runIntegration(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        let suite = Suite(baseURL: baseURL, completion: completion)
        suite.next()
    }

    private static let policies: [(String, ContextComponentPolicy)] = [
        ("exchange_lexical", .selectedQwenExchange), ("exchange_adjacent", .selectedQwenExchangeAdjacent),
        ("exchange_packed", .selectedQwenExchangePacked)]

    private final class Suite {
        let baseURL: String, completion: ([String: Bool]) -> Void
        var remaining = ExchangeEpisodeChecks.policies, checks: [String: Bool] = [:]
        var current: Attempt?
        init(baseURL: String, completion: @escaping ([String: Bool]) -> Void) { self.baseURL = baseURL; self.completion = completion }
        func next() {
            guard !remaining.isEmpty else { completion(checks); return }
            let (name, policy) = remaining.removeFirst()
            do {
                let attempt = try Attempt(name: name, policy: policy, baseURL: baseURL) { [self] result in
                    checks.merge(result) { _, latest in latest }; current = nil; next()
                }
                current = attempt; attempt.start()
            } catch { checks["exchange_episode_" + name + "_fixture_started"] = false; next() }
        }
    }

    private struct AdmissionAudit: Codable {
        let version: Int, receipt: EndpointAdmissionReceipt, attempts: [ProviderAdmissionAccounting], context: Data
    }

    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-exchange-episode-clock", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }

    private final class Attempt {
        let name: String, policy: ContextComponentPolicy, directory: URL, store: MemoryStore, chat: StoredConversation
        let clock = Clock(), lease: EpisodeLease, completion: ([String: Bool]) -> Void
        let prompt = "Where is the quokka habitat described?"
        let currentID = "exchange-episode-current"
        var settings = GenerationSettings(), operation: ComponentContextPreparationOperation?

        init(name: String, policy: ContextComponentPolicy, baseURL: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.name = name; self.policy = policy; self.completion = completion
            guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw MeteredRetrievalError.invalid }
            defer { free(path) }
            directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("boros-exchange-episode-" + UUID().uuidString)
            store = try MemoryStore(directory: directory)
            chat = try store.createConversation(projectID: "synthetic-exchange-episode", title: "Synthetic exchange episode")
            for block in 0..<4 {
                let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic exchange archive \(block)")
                let texts: [(MemoryRole, String)] = [(.assistant, "Synthetic opening note \(block)"),
                    (.human, "Synthetic question \(block) about the quokka habitat"),
                    (.assistant, "Synthetic reply \(block) on habitat details"), (.human, "Synthetic follow-up \(block)")]
                for (position, item) in texts.enumerated() {
                    _ = try store.append(conversationID: archive.id, role: item.0, text: item.1, status: .complete,
                        turnID: "exchange-episode-turn-\(block)-\(position)", eventID: "exchange-episode-\(block)-\(position)")
                }
            }
            var limits = EpisodeLimits(); limits.componentPolicy = policy
            let episodeID = UUID().uuidString
            _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "exchange-episode-turn",
                humanEventID: currentID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
            settings.profile = .customLocal; settings.endpointURL = baseURL; settings.endpointAPIKey = "synthetic-key"
            settings.endpointModel = Qwen38TextAdapter.modelID; settings.maximumOutput = 64; settings.temperature = 0
            settings.endpointContextLimit = 32768; settings.endpointSafetyTokens = 256; settings.episodeLease = lease
        }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func start() {
            operation = ComponentContextPreparationOperation(store: store, conversationID: chat.id, projectID: chat.projectID,
                humanEventID: currentID, prompt: prompt, settings: settings, conversation: Conversation(), semanticIndex: nil,
                retrievalStrategy: .hybrid, episodeLease: lease) { [self] outcome in finish(outcome) }
            operation?.start()
        }

        private func validate() throws {
            var raw: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database = raw else {
                if let raw { sqlite3_close(raw) }
                throw MemoryError.database("synthetic exchange journal open failed")
            }
            defer { sqlite3_close(database) }
            try ContextComponentJournal.validate(database: database, invocationID: "exchange-episode-invocation", verifySourceRanges: true)
            try ContextComponentJournal.validate(database: database)
            try MemoryStore.validateEpisodeJournal(database: database)
        }

        private func finish(_ outcome: Result<PreparedComponentContext, Error>) {
            var checks: [String: Bool] = [:], stage = "preparation"
            let prefix = "exchange_episode_" + name
            do {
                let prepared = try outcome.get(), state = try lease.checkActive()
                guard let proof = prepared.receipt.componentProof else { throw ProviderAdmissionError.countMismatch }
                let context = try JSONSerialization.jsonObject(with: prepared.snapshot.deliveryAudit()) as? [String: Any] ?? [:]
                let retrieval = context["retrieval"] as? [String: Any] ?? [:]
                checks[prefix + "_frozen_policy_counted_and_delivered"] = try state.limits.componentPolicy == policy
                    && proof.policyVersion == policy.version && proof.reductionVersion == policy.reductionVersion
                    && proof.policyDigest == EndpointRequest.digest(try policy.canonicalData())
                    && !prepared.snapshot.evidence.isEmpty && proof.evidence.tokens <= policy.evidenceTokens
                    && retrieval["exchange_query"] is [String: Any] && retrieval["mode"] as? String == name
                    && prepared.snapshot.selectionAudit?.version == "context-exchange-v1"
                // The synthetic tokenizer counts 5,000 tokens per historical
                // source, so the 12,000-token cap forces counted reductions.
                let reduced = prepared.snapshot.selectionAudit?.evidenceTokenExcludedCount ?? 0
                checks[prefix + "_counted_reduction_removes_single_spans"] = reduced > 0 && prepared.snapshot.evidence.count == 2
                if policy.packsExchangeValueDensity {
                    let receipts = (retrieval["exchange_query"] as? [String: Any])?["reduction_receipts"] as? [[Any]] ?? []
                    checks[prefix + "_every_counted_removal_has_a_receipt"] = receipts.count == reduced
                        && receipts.allSatisfy { $0.count == 3 && $0[2] as? String == "token" }
                        && retrieval["selection_trace"] == nil
                }
                stage = "invocation"
                let work = try lease.prepare(kind: .answer,
                    resources: EpisodeResources(inputTokens: prepared.receipt.promptTokens, outputTokens: prepared.receipt.outputReserve,
                        modelCalls: 1, httpAttempts: 1), adapterIdentity: prepared.receipt.answerAdapterIdentity, snapshot: prepared.body)
                let admission = try JSONEncoder().encode(AdmissionAudit(version: 2, receipt: prepared.receipt,
                    attempts: prepared.receipt.accounting.map { [$0] } ?? [], context: prepared.snapshot.deliveryAudit()))
                _ = try store.beginInvocation(invocationID: "exchange-episode-invocation", conversationID: chat.id,
                    turnID: "exchange-episode-turn", humanEventID: currentID, assistantEventID: "exchange-episode-assistant",
                    providerIdentity: prepared.receipt.endpoint, requestBody: prepared.body, admissionJSON: admission,
                    episodeID: lease.episodeID, episodeWorkID: work.id)
                _ = try lease.finish(reason: .cancelled)
                _ = try store.finalizeInvocation(invocationID: "exchange-episode-invocation", status: .cancelled, reason: .cancelled)
                stage = "journal_validation"
                try validate()
                checks[prefix + "_component_journal_validates_invocation"] = true
                stage = "archive"
                let archived = directory.appendingPathComponent("exchange-episode-archive")
                let manifest = try BackupArchive.create(from: store, at: archived)
                checks[prefix + "_archive_validator_accepts_episode"] = try BackupArchive.verify(at: archived) == manifest
                    && manifest.inventory.invocations == 1
            } catch {
                checks[prefix + "_" + stage + "_completed"] = false
            }
            operation = nil; completion(checks)
        }
    }
}
