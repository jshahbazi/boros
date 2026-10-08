import Foundation

/// Offline selected-Qwen delivery harness for the P1 retrieval measurement.
///
/// Each attempt runs the shared AnswerAttemptCoordinator, the same lifecycle as
/// ordinary GUI Send, against a supervisor-owned loopback tokenizer endpoint.
/// The harness stops the attempt when the coordinator reaches the answering
/// stage, which is the GUI Stop path, so no answer request is ever dispatched.
/// The injected runner refuses as a second fence. Output is content-free:
/// identifiers, byte ranges, counts and timings only.
///
/// Usage: DeliveryHarness (select|control) ABS_INPUT_JSON NEW_ABS_OUTPUT_JSON
/// `select` runs the declared strategies without any annotation input.
/// `control` delivers the declared source IDs through the existing
/// declared-source path to decide budget feasibility; it never ranks.
@main
enum DeliveryHarness {
    static let ingestionVersion = "delivery-harness-ingest-v1"

    struct Event: Decodable {
        let id: String
        let project_id: String
        let conversation_key: String
        let role: String
        let status: CaptureStatus
        let text: String
        let source_time: EventSourceTime?
    }
    struct Question: Decodable {
        let project_id: String
        let conversation_key: String
        let prompt: String
        let question_time: EventSourceTime?
    }
    struct Configuration: Decodable {
        let endpoint: String
        let model: String
        let system: String
        let temperature: Double
        let seed: Int
        let thinking: Bool
        let maximum_output: Int
        let context_limit: Int
        let safety_tokens: Int
        var settings: GenerationSettings {
            var value = GenerationSettings()
            value.profile = .customLocal; value.endpointURL = endpoint; value.endpointModel = model
            value.system = system; value.temperature = temperature; value.seed = seed
            value.thinkingEnabled = thinking; value.maximumOutput = maximum_output
            value.endpointContextLimit = context_limit; value.endpointSafetyTokens = safety_tokens
            return value
        }
    }
    struct Input: Decodable {
        let version: Int
        let cache_directory: String
        let work_directory: String
        let events: [Event]
        let question: Question
        let arms: [String]
        let declared_source_ids: [String]?
        let configuration: Configuration
    }
    enum Failure: Error { case arguments, invalid }

    /// Same question framing as the answer-evaluation command (version >= 5):
    /// the dated prompt is answered, the question text alone is queried.
    static func effectivePrompt(_ question: Question) -> String {
        guard let time = question.question_time else { return question.prompt }
        return "Question Date: " + time.originalValue + "\nQuestion: " + question.prompt
    }
    static func queryRange(_ question: Question) -> Range<Int>? {
        guard question.question_time != nil else { return nil }
        let end = effectivePrompt(question).utf8.count
        return (end - question.prompt.utf8.count)..<end
    }
    static func project(_ id: String) -> String { "retrieval-harness:" + id }
    /// P2 arms: explicit experimental exchange policies, no semantic index.
    static func exchangeLimits(_ arm: String) -> EpisodeLimits? {
        var limits = EpisodeLimits()
        switch arm {
        case "exchange_lexical": limits.componentPolicy = .selectedQwenExchange
        case "exchange_adjacent": limits.componentPolicy = .selectedQwenExchangeAdjacent
        default: return nil
        }
        return limits
    }
    static func key(_ project: String, _ conversation: String) -> String { project + "|" + conversation }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, ["select", "control"].contains(args[0]),
              args[1].hasPrefix("/"), args[2].hasPrefix("/"),
              !FileManager.default.fileExists(atPath: args[2]) else {
            fputs("Usage: DeliveryHarness (select|control) ABS_INPUT NEW_ABS_OUTPUT\n", stderr); exit(2)
        }
        let input: Input
        do {
            input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            guard input.version == 1 else { throw Failure.invalid }
            if args[0] == "select" {
                guard input.declared_source_ids == nil, !input.arms.isEmpty,
                      input.arms.allSatisfy({ ["recent_only", "lexical", "hybrid"].contains($0) || exchangeLimits($0) != nil }) else { throw Failure.invalid }
            } else {
                guard let ids = input.declared_source_ids, !ids.isEmpty, input.arms == ["declared_sources"] else { throw Failure.invalid }
            }
        } catch {
            fputs("Delivery harness input failed validation.\n", stderr); exit(1)
        }
        let run = Run(input: input, output: URL(fileURLWithPath: args[2]))
        DispatchQueue.global(qos: .userInitiated).async { run.begin() }
        dispatchMain()
    }

    /// Refuses every dispatch. Reaching it is a harness defect, reported as such.
    final class RefusingRunner: AnswerAttemptRunning {
        private(set) var started = false
        var isRunning: Bool { false }
        func start(prompt: String, settings: GenerationSettings, conversation: Conversation,
                   onText: @escaping (String) -> Void, onComplete: @escaping (GenerationResult) -> Void) {
            started = true
            DispatchQueue.main.async {
                onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: "harness_refused_dispatch", stopped: false))
            }
        }
        func cancel() {}
    }

    final class Run {
        let input: Input
        let output: URL
        var conversations: [String: String] = [:]
        var results: [[String: Any]] = []
        var cache: [String: Any] = [:]
        var armIndex = 0
        var coordinator: AnswerAttemptCoordinator?
        let started = DispatchTime.now().uptimeNanoseconds

        init(input: Input, output: URL) { self.input = input; self.output = output }

        var cacheURL: URL { URL(fileURLWithPath: input.cache_directory, isDirectory: true) }
        var baselineURL: URL { cacheURL.appendingPathComponent("baseline", isDirectory: true) }

        func begin() {
            do {
                try ensureCache()
                advance()
            } catch { fail("cache_failed") }
        }

        /// The baseline store, its conversation map and the semantic sidecar
        /// are built once and reused. Every attempt runs on a private copy.
        func ensureCache() throws {
            let manager = FileManager.default
            let ready = cacheURL.appendingPathComponent("ready.json")
            if manager.fileExists(atPath: ready.path) {
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any],
                      object["ingestion_version"] as? String == ingestionVersion,
                      let map = object["conversations"] as? [String: String] else { throw Failure.invalid }
                conversations = map
                cache = object; cache.removeValue(forKey: "conversations"); cache["reused"] = true
                return
            }
            let building = cacheURL.deletingLastPathComponent()
                .appendingPathComponent(".building-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: building, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let ingestStart = DispatchTime.now().uptimeNanoseconds
            var record: [String: Any] = ["ingestion_version": ingestionVersion]
            do {
                let owner = try MemoryStore(directory: building.appendingPathComponent("baseline", isDirectory: true))
                var map: [String: String] = [:]
                for event in input.events {
                    let mapping = key(event.project_id, event.conversation_key)
                    if map[mapping] == nil {
                        map[mapping] = try owner.createConversation(projectID: project(event.project_id), title: "Retrieval harness corpus").id
                    }
                    _ = try owner.append(conversationID: map[mapping]!, role: event.role == "user" ? .human : .assistant,
                        text: event.text, status: event.status, turnID: "harness-turn:" + event.id, eventID: event.id,
                        sourceTime: event.source_time)
                }
                record["ingest_milliseconds"] = milliseconds(since: ingestStart)
                record["events"] = input.events.count
                let semanticStart = DispatchTime.now().uptimeNanoseconds
                var semantic: [String: Any] = ["performed": false]
                if input.arms.contains("hybrid") || input.declared_source_ids != nil {
                    // Same bounded construction loop as the answer-evaluation
                    // command; a paused or failed slice ends construction.
                    do {
                        let index = try SemanticIndex(store: owner)
                        var slices = 0, published = 0, failed = 0, scheduled = 0
                        while true {
                            let receipt = try index.process(projectID: project(input.question.project_id))
                            slices += 1; published += receipt.publishedChunks; failed += receipt.failedChunks
                            scheduled += receipt.scheduledSources
                            if receipt.budgetPauseReason != nil
                                || (receipt.scheduledSources == 0 && receipt.publishedChunks == 0 && receipt.failedChunks == 0) { break }
                        }
                        semantic = ["performed": true, "slices": slices, "published_chunks": published,
                            "failed_chunks": failed, "scheduled_sources": scheduled,
                            "pause_reason": index.backgroundPauseReason as Any? ?? NSNull(),
                            "index_fingerprint": index.indexFingerprint, "encoder_fingerprint": index.encoderFingerprint]
                    } catch {
                        semantic = ["performed": true, "failure": "index_construction_failed"]
                    }
                }
                semantic["milliseconds"] = milliseconds(since: semanticStart)
                record["semantic"] = semantic
                record["conversations"] = map
                conversations = map
            }
            // The store is closed here; its files can be copied and renamed.
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: building.appendingPathComponent("ready.json"))
            if manager.fileExists(atPath: cacheURL.path) {
                // A concurrent builder won; use its complete cache instead.
                try? manager.removeItem(at: building)
                try ensureCache(); return
            }
            try manager.moveItem(at: building, to: cacheURL)
            cache = record; cache.removeValue(forKey: "conversations"); cache["reused"] = false
        }

        func advance() {
            guard armIndex < input.arms.count else { finish(); return }
            let arm = input.arms[armIndex]
            let attempt = URL(fileURLWithPath: input.work_directory, isDirectory: true)
                .appendingPathComponent(String(format: "attempt-%02d", armIndex), isDirectory: true)
            let armStart = DispatchTime.now().uptimeNanoseconds
            do {
                try FileManager.default.createDirectory(at: attempt.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: baselineURL, to: attempt)
                let owner = try MemoryStore(directory: attempt)
                let semantic: SemanticIndex? = arm == "hybrid" ? try SemanticIndex(store: owner) : nil
                DispatchQueue.main.async { self.attempt(arm: arm, owner: owner, semantic: semantic, directory: attempt, started: armStart) }
            } catch {
                results.append(["arm": arm, "failure_stage": "setup", "failure": "attempt_setup_failed"])
                try? FileManager.default.removeItem(at: attempt)
                armIndex += 1; advance()
            }
        }

        func attempt(arm: String, owner: MemoryStore, semantic: SemanticIndex?, directory: URL, started: UInt64) {
            let question = input.question
            let runner = RefusingRunner()
            var captured: AnswerAttemptPreparation?
            var item: [String: Any] = ["arm": arm]
            let conversationID = conversations[key(question.project_id, question.conversation_key)]!
            var coordinatorRef: AnswerAttemptCoordinator?
            let value = AnswerAttemptCoordinator(store: owner, conversationID: conversationID,
                projectID: project(question.project_id), prompt: effectivePrompt(question),
                settings: input.configuration.settings, semanticIndex: semantic,
                retrievalStrategy: arm == "recent_only" ? .recentOnly : .hybrid, limits: exchangeLimits(arm),
                lexicalQueryUTF8Range: queryRange(question), semanticQueryUTF8Range: queryRange(question),
                evidenceSourceIDs: arm == "declared_sources" ? input.declared_source_ids : nil,
                runner: runner,
                onStage: { stage, preparation in
                    // Stop at the answering boundary: the GUI Stop path. The
                    // coordinator checks its state again before dispatch.
                    if stage == .answering { captured = preparation; coordinatorRef?.cancel() }
                },
                onText: { _ in },
                onComplete: { completion, _ in
                    do {
                        item["runner_started"] = runner.started
                        item["preparation_completed"] = captured != nil
                        item["failure"] = captured == nil ? (completion.generation.failure as Any? ?? NSNull()) : NSNull()
                        item["failure_stage"] = captured == nil ? "preparation" : "none"
                        item["episode_state"] = completion.episode?.state.rawValue as Any? ?? NSNull()
                        item["preparation_milliseconds"] = completion.timing.preparationMilliseconds as Any? ?? NSNull()
                        if let preparation = captured {
                            try self.describe(preparation, episodeID: completion.identifiers.episodeID, owner: owner, into: &item)
                        }
                    } catch { item["failure"] = "harness_metadata_failed"; item["failure_stage"] = "metadata" }
                    item["attempt_milliseconds"] = milliseconds(since: started)
                    self.results.append(item)
                    self.coordinator = nil
                    DispatchQueue.main.async {
                        DispatchQueue.global(qos: .userInitiated).async {
                            try? FileManager.default.removeItem(at: directory)
                            self.armIndex += 1; self.advance()
                        }
                    }
                })
            coordinatorRef = value
            coordinator = value
            do { try value.accept(); try value.start() }
            catch {
                if (try? value.lease.checkActive(projectID: project(question.project_id))) != nil {
                    value.terminate(reason: .failed); return
                }
                item["failure"] = "acceptance_failed"; item["failure_stage"] = "acceptance"
                item["attempt_milliseconds"] = milliseconds(since: started)
                results.append(item); coordinator = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    try? FileManager.default.removeItem(at: directory)
                    self.armIndex += 1; self.advance()
                }
            }
        }

        /// Content-free delivery description: recent IDs, evidence byte
        /// ranges, the traced ranked candidates and component token counts.
        func describe(_ preparation: AnswerAttemptPreparation, episodeID: String, owner: MemoryStore,
                      into item: inout [String: Any]) throws {
            guard let audit = try JSONSerialization.jsonObject(with: preparation.contextAudit) as? [String: Any] else { throw Failure.invalid }
            item["prompt_tokens"] = preparation.admission.promptTokens
            item["evidence"] = try (audit["historical_sources"] as? [[String: Any]] ?? []).map { source -> [String: Any] in
                guard let id = source["event_id"], let offset = source["excerpt_offset"], let length = source["excerpt_bytes"],
                      let total = source["source_bytes"] else { throw Failure.invalid }
                return ["event_id": id, "offset": offset, "bytes": length, "source_bytes": total]
            }
            var recent: [String] = []
            if let workID = preparation.sourceSelectionWorkID,
               let snapshot = try owner.episodeWork(episodeID: episodeID, operationID: workID)?.request.snapshot,
               let selection = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] {
                recent = selection["recent_source_ids"] as? [String] ?? []
            } else { throw Failure.invalid }
            item["recent_source_ids"] = recent
            item["omitted_recent_count"] = audit["omitted_recent_count"] ?? NSNull()
            if let selection = audit["selection"] { item["selection"] = selection }
            if let components = audit["components"] as? [String: Any] {
                var tokens: [String: Any] = [:]
                for name in ["recent", "evidence", "wholePrompt"] {
                    tokens[name + "_tokens"] = (components[name] as? [String: Any])?["tokens"] ?? NSNull()
                }
                for name in ["recentCap", "evidenceCap", "effectiveContextLimit", "policyVersion", "reductionVersion"] {
                    tokens[name] = components[name] ?? NSNull()
                }
                item["components"] = tokens
            }
            let retrieval = audit["retrieval"] as? [String: Any] ?? [:]
            var summary: [String: Any] = [:]
            for name in ["mode", "semantic_available", "failure", "coverage_complete", "inspected_sources", "complete_sources",
                         "pending_sources", "unsupported_sources", "failed_sources", "candidate_window_full",
                         "candidate_window_complete", "continuation_available", "query_disposition"] {
                if let value = retrieval[name] { summary[name] = value }
            }
            item["retrieval"] = summary
            if let exchange = retrieval["exchange_query"] { item["exchange"] = exchange }
            if let trace = retrieval["selection_trace"] as? [String: Any] {
                item["candidate_count"] = trace["candidate_count"] ?? NSNull()
                item["trace_truncated"] = trace["trace_truncated"] ?? NSNull()
                item["candidates"] = (trace["candidates"] as? [[String: Any]] ?? []).map {
                    ["event_id": $0["event_id"] ?? NSNull(), "rank": $0["rank"] ?? NSNull(),
                     "offset": $0["offset"] ?? NSNull(), "bytes": $0["byte_length"] ?? NSNull()]
                }
                item["assembly"] = (trace["assembly"] as? [[String: Any]] ?? []).map {
                    ["event_id": $0["event_id"] ?? NSNull(), "rank": $0["rank"] ?? NSNull(), "disposition": $0["disposition"] ?? NSNull()]
                }
            } else if retrieval["selection_trace_omitted"] != nil {
                item["trace_omitted"] = true
            }
        }

        func finish() {
            let document: [String: Any] = ["harness_version": 1, "ingestion_version": ingestionVersion,
                "cache": cache, "attempts": results, "process_milliseconds": milliseconds(since: started)]
            do {
                let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                FileManager.default.createFile(atPath: output.path, contents: data, attributes: [.posixPermissions: 0o600])
                exit(0)
            } catch { fail("output_failed") }
        }

        func fail(_ code: String) {
            fputs("Delivery harness failed: " + code + ".\n", stderr)
            exit(1)
        }
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
