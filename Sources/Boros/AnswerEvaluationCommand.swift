import Foundation
import CoreFoundation
import Darwin
import CSQLite

/// Unregistered public-development diagnostic. Oracle fields and existing
/// stores are deliberately absent from this interface. Answers leave the
/// runner only in private, separately named transient scorer IPC files.
enum AnswerEvaluationCommand {
    /// Exact oracle-free projection of evaluation_fixtures.generate(
    /// "development", history_count=1) through evaluate_answers.runner_input.
    /// Updating this pin requires an explicit diagnostic source amendment.
    static let publicCorpusProjectionSHA256 = "6ca035c6bb87f23b75c59c8529a0181667e8ece0cc838056139d009f0c501bb4"
    /// N3 source amendment: three exact oracle-free DevGPT projections. This
    /// remains an allowlist, never a general arbitrary-history interface.
    static let developerCorpusProjectionSHA256: Set<String> = [
        "3ce6a107744a380f2b1f047bbfcacae380bb396cc14cc23c8108d8c240d1d091",
        "9d2a765385191a91562e52312ad906338aba99c7cf46aa144497e7b7047fff41",
        "0ac2f9963c690db4365792fbd2f0f82dfc0929baf15df535caa41f29bef9bd38"
    ]
    /// Separately frozen full-exchange witness projections. Version one never
    /// accepts these packs or supplies witness selection to retrieval arms.
    static let witnessCorpusProjectionSHA256: Set<String> = [
        "ae74877c63469436c0e8e17c16f9f4098eeee06e34f5a52f68ddaf8ae0f32aee",
        "5dd12260c9eaedf39965285cdb1d0cd821bde4d8a3ce53d67546854dc06b950a",
        "f9846f813421e252690662e0e0f2c937d129b2d92725c4f8d0557448b2aee207",
        "6f3c01af22d0069091fffb571686fb2acea7ed25475fe1dcf3fdd94808f3567d",
        "01918c47e143c6c21288dc3302fc2d36cb3a98064625aa2b659eb8d23f39953d",
        "5c6002a0f86505e7c9b3d0aaef421c450bea49febf6ee3822c7d3f88662ad67f",
        "f3c2b62c221401c941fedd72aa288cd22868c3a259136bf45965b3670a49e787",
        "7a324ac5081b76309a2ba1667fd38a234ad55011382f6afe5cc335f4f7db96c4",
        "5ee1706bcc661fa306758e546a24c0c894f616ca5d07972ddb5e5f4ba0a7d0e1"
    ]
    // Foundation's canonical numeric zero is 0; the Python source pin retains
    // 0.0. Both representations describe the same frozen configuration.
    static let witnessConfigurationSHA256 = "73729124226e2a729d052ea49d6f03ecced31b2b93e3beea63064ab046fa0013"
    /// Separate system-only development amendment; original settings and
    /// projection pins remain accepted exactly as declared.
    static let formatInstructionConfigurationSHA256 = "f13e87eb29ce2ecf88746293d3f01d74841394dc0a0aca3d2e9d5747dda53361"
    static let jsonObjectConfigurationSHA256 = "8aef45d2a8c7d20b8ee669606df5094f9d4ec960f82496841e8680dd433167cd"
    static let jsonObjectCorpusProjectionSHA256: Set<String> = [
        "7eaa4b959959b0afcb5f9895634e552eae1bac062e3100ab1f0d2d8d2653bdcb",
        "ab841b6f5611ed3df034b384ec440a23c46e9968ffecf61482eea572dce97ade",
        "52150ae4979989ebf12a9628a6ad0aecd2960150f5b15e897c85c0ba2d02c32e",
        "42cdff1f9aa72c7b2c7ce8724d26c6397038b9288e354cb5f1346b5d80e2f790",
        "fa40c8a36239be193de2f88bc80b10ef54a1eb1b476b9d8fad58ff8d2d9fb2b7",
        "eaa7aa2b33c5c51acbb42f805e82709ff7409a72acaa36702cdcc5c66770a835",
        "5238c51f6ec58ad3908a3654ae0fbe1f0a373dd13bec9ff040338459cb138218",
        "09316ffa9fc3f26d2dc81acad2eb7ede0c1c1c9b12dd678e6c80d38ed9c8230c",
        "eedf2f3ca33017e90b1ad449be99ef50bddba4f792b5f9635f44001151cbccdb"
    ]
    /// Separately declared LongMemEval S development projections; no oracle labels.
    static let longMemoryCorpusProjectionSHA256: Set<String> = [
        "87dcca85d2aaf4c1e5db21efbf466bed20b3673477698ff8a2e9b8adbdc9c32c",
        "5015ce3363b4f540b1eb2e7ec2ce398366e5a5d8253a6da40e63e10cd200c908",
        "9ee0a2ee042f99e87cdd82e5313c1a033c0880ad1d98bcbc1175ee05001f5dbd",
        "6bc8af5c9058844422d2a43b4640b85c50d43d470d33ea86a90f40ae7c7458a1",
        "cc2fbe2a44c6a0db7431044e67af686f80af7ec4fa8a7820cb2075711eb963e1",
        "d0a768245614fcf955266240969c66038f6d132b332ad24661413755982babb1",
        "1b1416dee0c4e8bb4508d6d5e4d9af10896d5ca68f8656b5a1a45888768f432f"
    ]
    static let longMemoryConfigurationSHA256 = "c23bf5d0bb63e7a348adfc4f673c9c01a1217d89e4c9e51c61f9bf80a300cf21"
    static let witnessMode = "sufficient-exchange-pack-v1"
    private enum Failure: Error { case arguments, invalid, io }
    private struct Event: Decodable {
        let id: String
        let project_id: String
        let conversation_key: String
        let role: String
        let status: CaptureStatus
        let text: String
        let source_time: EventSourceTime?
    }
    private struct Attempt: Decodable {
        let probe_id: String
        let project_id: String
        let conversation_key: String
        let prompt: String
        let strategy: ContextRetrievalStrategy
        let replicate: Int
        let question_time: EventSourceTime?
        var effectivePrompt: String {
            guard let time = question_time else { return prompt }
            return "Question Date: " + time.originalValue + "\nQuestion: " + prompt
        }
    }
    private struct Configuration: Decodable {
        let endpoint: String
        let model: String
        let system: String
        let temperature: Double
        let seed: Int
        let thinking: Bool
        let maximum_output: Int
        let context_limit: Int
        let safety_tokens: Int
        let response_format: String?
        var settings: GenerationSettings {
            var value = GenerationSettings()
            value.profile = .customLocal; value.endpointURL = endpoint; value.endpointModel = model
            value.system = system; value.temperature = temperature; value.seed = seed
            value.thinkingEnabled = thinking; value.maximumOutput = maximum_output
            value.endpointContextLimit = context_limit; value.endpointSafetyTokens = safety_tokens
            value.endpointJSONOutput = response_format == "json_object"
            return value
        }
    }
    private struct Document: Decodable {
        let version: Int
        let split: String
        let history_id: String
        let events: [Event]
        let attempts: [Attempt]
        let configuration: Configuration
    }

    /// Like the application smoke driver, a recognized valid command owns the
    /// main dispatch loop until all attempts terminalize. Invalid commands
    /// return a status so the ordinary application entry point can exit.
    static func run(arguments: [String]) -> Int32? {
        var args = arguments
        if let first = args.first, !first.hasPrefix("--") { args.removeFirst() }
        guard args.contains("--answer-evaluation") else { return nil }
        do {
            guard args.count == 4, args[0] == "--answer-evaluation", args[2] == "--output-directory" else {
                throw Failure.arguments
            }
            let input = try checkedPath(args[1]), output = try checkedPath(args[3])
            let bytes = try readPrivateInput(input)
            let document = try decode(bytes)
            try createNewDirectory(output)
            let session = try Session(document: document, inputDigest: digest(bytes),
                projectionDigest: projectionSHA256(bytes), output: output)
            DispatchQueue.global(qos: .userInitiated).async { session.begin() }
            dispatchMain()
        } catch Failure.arguments {
            fputs("Usage: --answer-evaluation ABS_JSON --output-directory NEW_ABS.\n", stderr)
            return 2
        } catch {
            fputs("Answer evaluation input or destination failed validation.\n", stderr)
            return 1
        }
    }

    private struct InputPins {
        let ordinary: Set<String>, witness: Set<String>, witnessConfiguration: String
        var formatConfiguration: String? = nil
        var jsonWitness: Set<String> = []
        var jsonConfiguration: String? = nil
        var longMemory: Set<String> = []
        var longMemoryConfiguration: String? = nil
        static var production: InputPins {
            InputPins(ordinary: developerCorpusProjectionSHA256.union([publicCorpusProjectionSHA256]),
                witness: witnessCorpusProjectionSHA256, witnessConfiguration: witnessConfigurationSHA256,
                formatConfiguration: formatInstructionConfigurationSHA256,
                jsonWitness: jsonObjectCorpusProjectionSHA256, jsonConfiguration: jsonObjectConfigurationSHA256,
                longMemory: longMemoryCorpusProjectionSHA256, longMemoryConfiguration: longMemoryConfigurationSHA256)
        }
    }
    private static func decode(_ bytes: Data, pins: InputPins = .production) throws -> Document {
        var scanner = UniqueKeyScanner(bytes: Array(bytes)); try scanner.scan()
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == ["version", "split", "history_id", "events", "attempts", "configuration"],
              let events = root["events"] as? [[String: Any]],
              let attempts = root["attempts"] as? [[String: Any]],
              let configuration = root["configuration"] as? [String: Any] else { throw Failure.invalid }
        var publicProjection = root
        publicProjection.removeValue(forKey: "configuration")
        let projectionDigest = digest(try JSONSerialization.data(withJSONObject: publicProjection,
            options: [.sortedKeys, .withoutEscapingSlashes]))
        guard let mode = root["version"] as? NSNumber, CFGetTypeID(mode) != CFBooleanGetTypeID(),
              mode.doubleValue == Double(mode.intValue), (1...4).contains(mode.intValue) else { throw Failure.invalid }
        let eventKeys: Set<String> = ["id", "project_id", "conversation_key", "role", "status", "text"]
        let attemptKeys: Set<String> = ["probe_id", "project_id", "conversation_key", "prompt", "strategy", "replicate"]
        guard events.allSatisfy({ Set($0.keys) == (mode.intValue == 4 ? eventKeys.union(["source_time"]) : eventKeys) }),
              attempts.allSatisfy({ Set($0.keys) == (mode.intValue == 4 ? attemptKeys.union(["question_time"]) : attemptKeys) }) else { throw Failure.invalid }
        let baseKeys: Set<String> = ["endpoint", "model", "system", "temperature", "seed", "thinking", "maximum_output", "context_limit", "safety_tokens"]
        guard Set(configuration.keys) == (mode.intValue == 3 ? baseKeys.union(["response_format"]) : baseKeys),
              mode.intValue != 3 || configuration["response_format"] as? String == "json_object" else { throw Failure.invalid }
        if mode.intValue == 1 {
            guard pins.ordinary.contains(projectionDigest) else { throw Failure.invalid }
        } else if mode.intValue == 2 {
            let configurationDigest = digest(try JSONSerialization.data(withJSONObject: configuration,
                options: [.sortedKeys, .withoutEscapingSlashes]))
            guard pins.witness.contains(projectionDigest),
                  configurationDigest == pins.witnessConfiguration
                    || configurationDigest == pins.formatConfiguration else { throw Failure.invalid }
        } else if mode.intValue == 3 {
            guard pins.jsonWitness.contains(projectionDigest),
                  digest(try JSONSerialization.data(withJSONObject: configuration,
                    options: [.sortedKeys, .withoutEscapingSlashes])) == pins.jsonConfiguration else { throw Failure.invalid }
        } else {
            guard pins.longMemory.contains(projectionDigest),
                  digest(try JSONSerialization.data(withJSONObject: configuration,
                    options: [.sortedKeys, .withoutEscapingSlashes])) == pins.longMemoryConfiguration else { throw Failure.invalid }
        }
        let value = try JSONDecoder().decode(Document.self, from: bytes)
        guard value.split == "development", identifier(value.history_id),
              !value.events.isEmpty, value.events.count <= 100_000,
              !value.attempts.isEmpty, value.attempts.count <= 1000,
              Set(value.events.map(\.id)).count == value.events.count else { throw Failure.invalid }
        var conversations = Set<String>(), attemptsSeen = Set<String>()
        for event in value.events {
            guard identifier(event.id), identifier(event.project_id), identifier(event.conversation_key),
                  ["user", "assistant"].contains(event.role), event.text.utf8.count <= MemoryStore.maximumPayloadBytes else { throw Failure.invalid }
            if value.version == 4 {
                guard let sourceTime = event.source_time else { throw Failure.invalid }
                _ = try sourceTime.validated()
            }
            conversations.insert(key(event.project_id, event.conversation_key))
        }
        for attempt in value.attempts {
            guard identifier(attempt.probe_id), identifier(attempt.project_id), identifier(attempt.conversation_key),
                  conversations.contains(key(attempt.project_id, attempt.conversation_key)),
                  !attempt.prompt.isEmpty, attempt.effectivePrompt.utf8.count <= MemoryStore.maximumPayloadBytes,
                  (0...100).contains(attempt.replicate),
                  attemptsSeen.insert("\(attempt.probe_id)|\(attempt.strategy.rawValue)|\(attempt.replicate)").inserted else { throw Failure.invalid }
        }
        if value.version == 4 {
            guard value.attempts.count == 2, value.attempts.map(\.strategy) == [.recentOnly, .hybrid],
                  value.attempts.allSatisfy({ $0.replicate == 0 && $0.question_time != nil }),
                  value.events.allSatisfy({ $0.status == .complete }),
                  Set(value.events.map(\.project_id)).count == 1 else { throw Failure.invalid }
            for attempt in value.attempts { _ = try attempt.question_time!.validated() }
        }
        if (2...3).contains(value.version) {
            guard value.attempts.count == 1, let attempt = value.attempts.first,
                  attempt.strategy == .recentOnly, attempt.replicate == 0,
                  value.events.count == 2 || value.events.count == 4,
                  value.events.enumerated().allSatisfy({ index, event in
                      episodeIdentifierEqual(event.project_id, attempt.project_id)
                        && episodeIdentifierEqual(event.conversation_key, attempt.conversation_key)
                        && event.role == (index % 2 == 0 ? "user" : "assistant")
                        && event.status == .complete && !event.text.isEmpty
                  }) else { throw Failure.invalid }
        }
        let c = value.configuration
        guard LocalEndpoint.chatURL(c.endpoint) != nil, c.model == Qwen38TextRendering.modelID,
              !c.system.isEmpty, c.system.utf8.count <= 8192, c.temperature.isFinite, (0...2).contains(c.temperature),
              (0...Int(Int32.max)).contains(c.seed), (1...8192).contains(c.maximum_output),
              (1024...131072).contains(c.context_limit), (0...8192).contains(c.safety_tokens),
              c.maximum_output + c.safety_tokens < c.context_limit else { throw Failure.invalid }
        _ = try EndpointRequest.build(prompt: value.attempts[0].effectivePrompt, settings: c.settings, conversation: Conversation())
        return value
    }

    private static func projectionSHA256(_ bytes: Data) throws -> String {
        guard var projection = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalid }
        projection.removeValue(forKey: "configuration")
        return digest(try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private static func ingestEvents(_ document: Document, into owner: MemoryStore) throws -> [String: String] {
        var conversations: [String: String] = [:]
        for event in document.events {
            let mapping = key(event.project_id, event.conversation_key)
            if conversations[mapping] == nil {
                conversations[mapping] = try owner.createConversation(projectID: project(event.project_id), title: "Public diagnostic corpus").id
            }
            _ = try owner.append(conversationID: conversations[mapping]!, role: event.role == "user" ? .human : .assistant,
                text: event.text, status: event.status, turnID: "public-turn:" + event.id, eventID: event.id, sourceTime: event.source_time)
        }
        return conversations
    }

    private final class Session {
        let document: Document
        let inputDigest: String
        let projectionDigest: String
        let output: URL
        let runtime: URL
        let archive: URL
        var conversations: [String: String] = [:]
        var report: [[String: Any]] = []
        var baseline: [String: Any] = [:]
        var ordinal = 0
        var coordinator: AnswerAttemptCoordinator?
        init(document: Document, inputDigest: String, projectionDigest: String, output: URL) throws {
            self.document = document; self.inputDigest = inputDigest; self.projectionDigest = projectionDigest; self.output = output
            // Keep every store inside the checked private output owner. The
            // Python supervisor can remove this subtree even if this process
            // dies before native finalization. Direct CLI owners retain it on
            // death until they remove their explicitly chosen output directory.
            runtime = output.appendingPathComponent(".runtime-" + UUID().uuidString, isDirectory: true)
            archive = runtime.appendingPathComponent("checkpoint", isDirectory: true)
            try createNewDirectory(runtime)
        }
        func begin() {
            do {
                try ingestCheckpoint()
                advance()
            } catch { finish(fatal: "checkpoint_failed") }
        }
        private func ingestCheckpoint() throws {
            let owner = try MemoryStore(directory: runtime.appendingPathComponent("baseline", isDirectory: true))
            conversations = try ingestEvents(document, into: owner)
            let manifest = try BackupArchive.create(from: owner, at: archive)
            baseline = ["events": manifest.inventory.events, "source_bytes": manifest.inventory.sourceBytes,
                "conversations": manifest.inventory.conversations, "archive_id": manifest.archiveID,
                "database_schema": manifest.databaseSchema,
                "archive_sha256": digest(try canonical(manifest)),
                "timestamps": document.version == 4 ? "original_session_dates_preserved_ingestion_frozen" : "ingestion_frozen_in_checkpoint", "derived_sidecar_in_checkpoint": false]
        }
        private func advance() {
            guard ordinal < document.attempts.count else { finish(fatal: nil); return }
            let index = ordinal, attempt = document.attempts[index]
            let started = continuousSample()
            let restored = runtime.appendingPathComponent(String(format: "attempt-%04d", index), isDirectory: true)
            do {
                _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
                let owner = try MemoryStore(directory: restored)
                var semantic: SemanticIndex?
                var construction: [String: Any] = ["schedule": "per_hybrid_attempt_before_acceptance", "performed": false]
                let before = try owner.backgroundBudgetSnapshot()
                let constructionStart = continuousSample()
                if attempt.strategy == .hybrid {
                    do {
                        let index = try SemanticIndex(store: owner)
                        semantic = index
                        var slices = 0, published = 0, failed = 0, scheduled = 0, lastFrontier = 0
                        // No renewal, fresh clock or store is manufactured here.
                        // A stopped/paused slice ends construction for this attempt.
                        while true {
                            let receipt = try index.process(projectID: project(attempt.project_id))
                            slices += 1; published += receipt.publishedChunks; failed += receipt.failedChunks
                            scheduled += receipt.scheduledSources; lastFrontier = receipt.schedulingFrontier
                            if receipt.budgetPauseReason != nil || (receipt.scheduledSources == 0 && receipt.publishedChunks == 0 && receipt.failedChunks == 0) { break }
                        }
                        construction = ["schedule": "per_hybrid_attempt_before_acceptance", "performed": true,
                            "slices": slices, "published_chunks": published, "failed_chunks": failed,
                            "scheduled_sources": scheduled, "frontier": lastFrontier,
                            "pause_reason": index.backgroundPauseReason as Any? ?? NSNull(),
                            "index_fingerprint": index.indexFingerprint, "encoder_fingerprint": index.encoderFingerprint,
                            "ranking_fingerprint": index.rankingFingerprint,
                            "configuration": try object(index.configuration),
                            "inventory": try sidecarInventory(index.directory)]
                    } catch {
                        construction = ["schedule": "per_hybrid_attempt_before_acceptance", "performed": true,
                            "failure": "index_construction_failed", "partial_coverage": true]
                    }
                }
                construction["milliseconds"] = milliseconds(constructionStart)
                construction["budget_before"] = try object(before)
                construction["budget_after"] = try object(owner.backgroundBudgetSnapshot())
                construction["quiescent_during_answer"] = true
                let frozenConstruction = construction, frozenSemantic = semantic
                DispatchQueue.main.async {
                    self.answer(attempt, ordinal: index, owner: owner, semantic: frozenSemantic,
                        construction: frozenConstruction, restored: restored, started: started)
                }
            } catch {
                do {
                    var item = attemptMetadata(attempt, ordinal: index)
                    item["terminalized"] = true; item["failure_stage"] = "restore_or_setup"
                    item["failure"] = "attempt_setup_failed"; item["answer_bytes"] = 0
                    item["answer_sha256"] = digest(Data()); item["episode_state"] = NSNull()
                    item["invocation_status"] = NSNull(); item["delivered_ranges"] = []
                    item["delivered_recent_source_ids"] = []; item["full_host_milliseconds"] = milliseconds(started)
                    try publish(item, text: "", ordinal: index)
                    try? FileManager.default.removeItem(at: restored)
                    ordinal += 1; advance()
                } catch { finish(fatal: "ipc_publication_failed") }
            }
        }
        private func answer(_ attempt: Attempt, ordinal: Int, owner: MemoryStore, semantic: SemanticIndex?,
                            construction: [String: Any], restored: URL, started: UInt64?) {
            let value = AnswerAttemptCoordinator(store: owner,
                conversationID: conversations[key(attempt.project_id, attempt.conversation_key)]!,
                projectID: project(attempt.project_id), prompt: attempt.effectivePrompt,
                settings: document.configuration.settings, semanticIndex: semantic, retrievalStrategy: attempt.strategy,
                onText: { _ in }, onComplete: { completion, text in
                    do {
                        var item = attemptMetadata(attempt, ordinal: ordinal)
                        item["terminalized"] = true; item["background"] = construction
                        item["identifiers"] = try object(completion.identifiers)
                        item["episode"] = try completion.episode.map { try object($0) } ?? NSNull()
                        item["episode_state"] = completion.episode?.state.rawValue as Any? ?? NSNull()
                        item["invocation_status"] = completion.captureStatus?.rawValue as Any? ?? NSNull()
                        item["terminal_reason"] = completion.terminalReason?.rawValue as Any? ?? NSNull()
                        item["capture_healthy"] = completion.captureHealthy; item["accounting_healthy"] = completion.accountingHealthy
                        item["invocation_started"] = completion.invocationStarted
                        item["failure"] = completion.generation.failure as Any? ?? NSNull()
                        item["failure_stage"] = completion.preparation == nil ? "preparation" : completion.generation.failure == nil ? "none" : "answer_or_finalization"
                        item["provider_usage"] = try completion.generation.providerUsage.map { try object($0) } ?? NSNull()
                        item["provider_milliseconds"] = completion.generation.elapsed * 1000
                        item["timing"] = try object(completion.timing)
                        item["answer_bytes"] = completion.responseBytes; item["answer_sha256"] = completion.responseDigest
                        let inventory = try sourceInventory(restored)
                        item["overlay_events"] = inventory.events - self.document.events.count
                        item["overlay_bytes"] = inventory.bytes - self.document.events.reduce(0) { $0 + $1.text.utf8.count }
                        item["delivered_ranges"] = []; item["delivered_recent_source_ids"] = []
                        if let preparation = completion.preparation {
                            guard let audit = try JSONSerialization.jsonObject(with: preparation.contextAudit) as? [String: Any] else { throw Failure.invalid }
                            item["preparation"] = ["request_sha256": preparation.requestDigest,
                                "selection_sha256": preparation.sourceSelectionDigest,
                                "selection_work_id": preparation.sourceSelectionWorkID as Any? ?? NSNull(),
                                "answer_work_id": preparation.answerWorkID,
                                "admission": try object(preparation.admission), "context_audit": audit]
                            if self.document.version == 4 {
                                var metadata = item["preparation"] as! [String: Any]
                                metadata["admission_audit"] = try JSONSerialization.jsonObject(with: preparation.admissionAuditJSON)
                                item["preparation"] = metadata
                            }
                            var ranges = try (audit["historical_sources"] as? [[String: Any]] ?? []).map { source -> [String: Any] in
                                guard let id = source["event_id"], let offset = source["excerpt_offset"],
                                      let length = source["excerpt_bytes"], let hash = source["excerpt_sha256"] else { throw Failure.invalid }
                                return ["event_id": id, "offset": offset, "byte_length": length, "sha256": hash]
                            }
                            if let workID = preparation.sourceSelectionWorkID,
                               let snapshot = try owner.episodeWork(episodeID: completion.identifiers.episodeID, operationID: workID)?.request.snapshot,
                               let selection = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] {
                                item["delivered_recent_source_ids"] = selection["recent_source_ids"] ?? []
                                for source in selection["recent_sources"] as? [[String: Any]] ?? [] {
                                    guard let id = source["eventID"], let length = source["byteCount"], let hash = source["digest"] else { throw Failure.invalid }
                                    ranges.append(["event_id": id, "offset": 0, "byte_length": length, "sha256": hash])
                                }
                            }
                            item["delivered_ranges"] = ranges
                        }
                        if (2...3).contains(self.document.version) {
                            item["witness_validation"] = validateWitness(document: self.document, completion: completion,
                                directory: restored, conversationID: self.conversations[key(attempt.project_id, attempt.conversation_key)]!)
                        }
                        item["background_budget_at_completion"] = try object(owner.backgroundBudgetSnapshot())
                        item["full_host_milliseconds"] = milliseconds(started)
                        try self.publish(item, text: text, ordinal: ordinal)
                        self.coordinator = nil
                        // Move teardown off the callback stack, releasing both
                        // owners before removing their disposable directory.
                        DispatchQueue.main.async {
                            DispatchQueue.global(qos: .userInitiated).async {
                                try? FileManager.default.removeItem(at: restored)
                                self.ordinal += 1; self.advance()
                            }
                        }
                    } catch { self.finish(fatal: "attempt_metadata_failed") }
                })
            coordinator = value
            do { try value.accept(); try value.start() }
            catch {
                // A failed acceptance has no durable episode. Still retain the
                // declared attempt; start failures terminalize an accepted one.
                if (try? value.lease.checkActive(projectID: project(attempt.project_id))) != nil {
                    value.terminate(reason: .failed); return
                }
                do {
                    var item = attemptMetadata(attempt, ordinal: ordinal)
                    item["terminalized"] = true; item["background"] = construction
                    item["failure_stage"] = "acceptance"; item["failure"] = "acceptance_failed"
                    item["episode_state"] = NSNull(); item["invocation_status"] = NSNull()
                    item["answer_bytes"] = 0; item["answer_sha256"] = digest(Data())
                    item["delivered_ranges"] = []; item["delivered_recent_source_ids"] = []
                    item["full_host_milliseconds"] = milliseconds(started)
                    try publish(item, text: "", ordinal: ordinal)
                    coordinator = nil
                    DispatchQueue.main.async {
                        DispatchQueue.global(qos: .userInitiated).async {
                            try? FileManager.default.removeItem(at: restored)
                            self.ordinal += 1; self.advance()
                        }
                    }
                } catch { finish(fatal: "ipc_publication_failed") }
            }
        }
        private func publish(_ item: [String: Any], text: String, ordinal: Int) throws {
            try writePrivate(Data(text.utf8), output.appendingPathComponent(String(format: "answer-%04d.txt", ordinal)))
            report.append(witnessMetadata(item))
        }
        private func witnessMetadata(_ item: [String: Any]) -> [String: Any] {
            guard (2...3).contains(document.version) else { return item }
            var result = item
            result["witness_mode"] = witnessMode
            if result["witness_validation"] == nil {
                result["witness_validation"] = witnessOutcome(events: document.events, failure: "witness_outcome_unavailable")
            }
            return result
        }
        private func finish(fatal: String?) {
            do {
                // Setup/publication failures never shrink the announced
                // denominator. Missing operational outcomes stay explicit;
                // these records cannot be mistaken for completed answers.
                let retained = Set(report.compactMap { $0["ordinal"] as? Int })
                for index in document.attempts.indices where !retained.contains(index) {
                    var item = attemptMetadata(document.attempts[index], ordinal: index)
                    item["terminalized"] = false; item["failure_stage"] = "runner"
                    item["failure"] = fatal ?? "runner_outcome_unavailable"
                    item["episode_state"] = NSNull(); item["invocation_status"] = NSNull()
                    item["answer_bytes"] = NSNull(); item["answer_sha256"] = NSNull()
                    item["delivered_ranges"] = []; item["delivered_recent_source_ids"] = []
                    report.append(witnessMetadata(item))
                }
                report.sort { ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) }
                guard var configuration = try object(EpisodeLimits()) as? [String: Any] else { throw Failure.invalid }
                configuration["componentPolicy"] = try object(ContextComponentPolicy.selectedQwen)
                let c = document.configuration
                var value: [String: Any] = ["version": 1, "diagnostic": "production-answer-development-v1",
                    "split": "development", "history_id": document.history_id, "input_sha256": inputDigest,
                    "public_projection_sha256": projectionDigest,
                    "fatal_failure": fatal as Any? ?? NSNull(), "declared_attempts": document.attempts.count,
                    "completed_attempts": report.filter { $0["terminalized"] as? Bool == true }.count, "baseline": baseline, "attempts": report,
                    "configuration": ["endpoint": c.endpoint, "model": c.model,
                        "instruction_sha256": digest(Data(c.system.utf8)), "temperature": c.temperature,
                        "seed": c.seed, "thinking": c.thinking, "maximum_output": c.maximum_output,
                        "context_limit": c.context_limit, "safety_tokens": c.safety_tokens,
                        "episode_limits": configuration, "background_limits": try object(BackgroundIndexLimits.development)],
                    "unknowns": ["apple_input_tokens", "local_billed_cost", "first_useful_answer"]]
                if document.version >= 2 {
                    if (2...3).contains(document.version) { value["witness_mode"] = witnessMode }
                    var frozenConfiguration: [String: Any] = ["endpoint": c.endpoint, "model": c.model,
                        "system": c.system, "temperature": c.temperature, "seed": c.seed, "thinking": c.thinking,
                        "maximum_output": c.maximum_output, "context_limit": c.context_limit, "safety_tokens": c.safety_tokens]
                    if let format = c.response_format { frozenConfiguration["response_format"] = format }
                    value["native_configuration_sha256"] = digest(try JSONSerialization.data(withJSONObject: frozenConfiguration,
                        options: [.sortedKeys, .withoutEscapingSlashes]))
                }
                try writePrivate(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), output.appendingPathComponent("report.json"))
                try FileManager.default.removeItem(at: runtime)
                FileHandle.standardOutput.write(Data("{\"status\":\"terminalized\",\"attempts\":\(report.count)}\n".utf8))
                Darwin.exit(fatal == nil ? 0 : 1)
            } catch {
                try? FileManager.default.removeItem(at: runtime)
                fputs("Answer evaluation report publication failed.\n", stderr); Darwin.exit(1)
            }
        }
    }

    private static func witnessOutcome(events: [Event], delivered: Int? = nil, complete: Bool? = nil,
        revalidated: Bool? = nil, proofVersion: Int? = nil, failure: String?, validationMilliseconds: Any = NSNull()) -> [String: Any] {
        ["version": "sufficient-exchange-pack-validation-v1", "declared_source_count": events.count,
         "declared_source_bytes": events.reduce(0) { $0 + $1.text.utf8.count },
         "delivered_source_count": delivered as Any? ?? NSNull(), "complete_pack_delivered": complete as Any? ?? NSNull(),
         "source_body_count_revalidated": revalidated as Any? ?? NSNull(), "input_proof_version": proofVersion as Any? ?? NSNull(),
         "failure_code": failure as Any? ?? NSNull(), "validation_milliseconds": validationMilliseconds]
    }

    /// A separate offline integrity result. Failed validation never overwrites
    /// the operational completion, original debits or private answer IPC.
    private static func validateWitness(document: Document, completion: AnswerAttemptCompletion,
        directory: URL, conversationID: String) -> [String: Any] {
        guard completion.invocationStarted else {
            return witnessOutcome(events: document.events, failure: "witness_outcome_unavailable")
        }
        let validationStarted = continuousSample()
        do {
            guard let preparation = completion.preparation, let selectionID = preparation.sourceSelectionWorkID else { throw Failure.invalid }
            let delivered = try withReadOnlySnapshot(directory: directory) { database in
                let rows = try AuthorityStateKernel.rows(database,
                    "SELECT request_body,request_digest,admission_json,episode_id,project_id,conversation_id,human_event_id,episode_work_id FROM invocations WHERE id=?",
                    [.text(completion.identifiers.invocationID)])
                guard rows.count == 1, let body = rows[0][0].bytes, let admission = rows[0][2].bytes,
                      digest(body) == preparation.requestDigest, episodeIdentifierEqual(rows[0][1].string, preparation.requestDigest),
                      episodeIdentifierEqual(rows[0][3].string, completion.identifiers.episodeID),
                      episodeIdentifierEqual(rows[0][4].string, project(document.attempts[0].project_id)),
                      episodeIdentifierEqual(rows[0][5].string, conversationID),
                      episodeIdentifierEqual(rows[0][6].string, completion.identifiers.humanEventID),
                      episodeIdentifierEqual(rows[0][7].string, preparation.answerWorkID),
                      let audit = try JSONSerialization.jsonObject(with: admission) as? [String: Any],
                      audit["version"] as? Int == 3, let contextText = audit["context"] as? String,
                      let context = Data(base64Encoded: contextText), context == preparation.contextAudit,
                      let storedReceipt = audit["receipt"],
                      let contextObject = try JSONSerialization.jsonObject(with: context) as? [String: Any],
                      episodeIdentifierEqual(contextObject["selection_work_id"] as? String, selectionID),
                      episodeIdentifierEqual(contextObject["source_snapshot_sha256"] as? String, preparation.sourceSelectionDigest) else { throw Failure.invalid }
                guard let bodyObject = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let messages = bodyObject["messages"] as? [[String: String]], messages.count >= 2 else { throw Failure.invalid }
                let mandatory = ContextAssembler.mandatoryMessages(prompt: document.attempts[0].prompt,
                    system: document.configuration.system)
                guard messages.first?["role"] == mandatory[0].role, messages.last?["role"] == mandatory[1].role,
                      Data((messages.first?["content"] ?? "").utf8) == Data(mandatory[0].content.utf8),
                      Data((messages.last?["content"] ?? "").utf8) == Data(mandatory[1].content.utf8) else { throw Failure.invalid }
                var expectedSettings = document.configuration.settings
                expectedSettings.messagesOverride = messages
                guard try EndpointRequest.build(prompt: document.attempts[0].prompt,
                    settings: expectedSettings, conversation: Conversation()) == body else { throw Failure.invalid }
                let expectedReceipt = try object(preparation.admission)
                guard try JSONSerialization.data(withJSONObject: storedReceipt, options: [.sortedKeys, .withoutEscapingSlashes])
                    == JSONSerialization.data(withJSONObject: expectedReceipt, options: [.sortedKeys, .withoutEscapingSlashes]) else { throw Failure.invalid }
                try ContextComponentJournal.validate(database: database, invocationID: completion.identifiers.invocationID, verifySourceRanges: true)
                let selectionRows = try AuthorityStateKernel.rows(database,
                    "SELECT w.state,w.kind,w.adapter_identity,s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=? AND w.episode_id=?",
                    [.text(selectionID), .text(completion.identifiers.episodeID)])
                guard selectionRows.count == 1, selectionRows[0][0].string == "completed", selectionRows[0][1].string == "sourceRead",
                      let selection = selectionRows[0][3].bytes, digest(selection) == preparation.sourceSelectionDigest,
                      let selected = try JSONSerialization.jsonObject(with: selection) as? [String: Any],
                      let recentSources = selected["recent_sources"] as? [[String: Any]],
                      let historicalSources = selected["historical_sources"] as? [[String: Any]], historicalSources.isEmpty,
                      let recentIDs = selected["recent_source_ids"] as? [String], recentIDs.count == recentSources.count,
                      ExactSourceIDs(recentIDs).count == recentIDs.count else { throw Failure.invalid }
                // Validate every original witness source, including ones lost
                // by a legitimate reduction. Gold IDs never enter this check.
                for event in document.events {
                    let source = try AuthorityStateKernel.rows(database,
                        "SELECT project_id,conversation_id,role,status,digest,byte_count,payload FROM events WHERE id=?", [.text(event.id)])
                    let bytes = Data(event.text.utf8)
                    guard source.count == 1, episodeIdentifierEqual(source[0][0].string, project(event.project_id)),
                          episodeIdentifierEqual(source[0][1].string, conversationID), source[0][2].string == (event.role == "user" ? "human" : "assistant"),
                          source[0][3].string == event.status.rawValue, source[0][4].string == digest(bytes),
                          source[0][5].integer == bytes.count, source[0][6].bytes == bytes else { throw Failure.invalid }
                }
                let originals = ExactSourceIDs(document.events.map(\.id))
                guard recentIDs.allSatisfy({ originals.contains($0) }) else { throw Failure.invalid }
                for (index, source) in recentSources.enumerated() {
                    guard let id = source["eventID"] as? String, episodeIdentifierEqual(id, recentIDs[index]),
                          let event = document.events.first(where: { episodeIdentifierEqual($0.id, id) }),
                          source["digest"] as? String == digest(Data(event.text.utf8)),
                          source["byteCount"] as? Int == event.text.utf8.count else { throw Failure.invalid }
                }
                return recentIDs.count
            }
            let complete = delivered == document.events.count
            return witnessOutcome(events: document.events, delivered: delivered, complete: complete,
                revalidated: true, proofVersion: 3, failure: complete ? nil : "witness_pack_not_delivered",
                validationMilliseconds: milliseconds(validationStarted))
        } catch {
            return witnessOutcome(events: document.events, revalidated: false, failure: "witness_source_body_count_invalid",
                validationMilliseconds: milliseconds(validationStarted))
        }
    }

    private static func withReadOnlySnapshot<T>(directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = raw else { if let raw { sqlite3_close(raw) }; throw Failure.io }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw Failure.io }
        defer { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        return try body(database)
    }

    private static func attemptMetadata(_ attempt: Attempt, ordinal: Int) -> [String: Any] {
        ["ordinal": ordinal, "probe_id": attempt.probe_id, "strategy": attempt.strategy.rawValue,
         "replicate": attempt.replicate, "answer_file": String(format: "answer-%04d.txt", ordinal)]
    }
    private static func key(_ project: String, _ conversation: String) -> String { project + "|" + conversation }
    private static func project(_ publicID: String) -> String { "answer-evaluation-public:" + publicID }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
    private static func digest(_ data: Data) -> String { EndpointRequest.digest(data) }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: canonical(value)) }
    private static func continuousSample() -> UInt64? {
        try? SystemEpisodeClock().now().continuousNanoseconds
    }
    private static func milliseconds(_ start: UInt64?) -> Any {
        guard let start, let now = continuousSample(), now >= start else { return NSNull() }
        return Double(now - start) / 1_000_000
    }
    private static func checkedPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("."),
              !path.split(separator: "/").contains("..") else { throw Failure.arguments }
        let url = URL(fileURLWithPath: path)
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" {
            var info = stat()
            guard lstat(cursor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalid }
            cursor.deleteLastPathComponent()
        }
        return url
    }
    private static func createNewDirectory(_ url: URL) throws {
        _ = try checkedPath(url.path)
        guard mkdir(url.path, 0o700) == 0 else { throw Failure.io }
    }
    private static func readPrivateInput(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 128 * 1024 * 1024 else { throw Failure.invalid }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return bytes }
            if count < 0 { if errno == EINTR { continue }; throw Failure.io }
            guard bytes.count <= 128 * 1024 * 1024 - count else { throw Failure.invalid }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func writePrivate(_ bytes: Data, _ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        try bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let count = write(fd, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.io }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
    /// Inspect only derived metadata after a synchronous worker drain. No
    /// source payload or query embedding is read for this construction report.
    private static func sidecarInventory(_ directory: URL) throws -> [String: Any] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT state,count(*),coalesce(sum(indexed_bytes),0),coalesce(sum(indexed_chunks),0),coalesce(sum(unsupported_chunks),0),coalesce(sum(next_offset),0) FROM jobs GROUP BY state", -1, &statement, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_finalize(statement) }
        var states: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let state = sqlite3_column_text(statement, 0) else { throw Failure.io }
            states.append(["state": String(cString: state), "sources": sqlite3_column_int64(statement, 1),
                "indexed_bytes": sqlite3_column_int64(statement, 2), "indexed_chunks": sqlite3_column_int64(statement, 3),
                "unsupported_chunks": sqlite3_column_int64(statement, 4), "offset_total": sqlite3_column_int64(statement, 5)])
        }
        return ["states": states]
    }

    private static func sourceInventory(_ directory: URL) throws -> (events: Int, bytes: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*),coalesce(sum(byte_count),0) FROM events", -1, &statement, nil) == SQLITE_OK else { throw Failure.io }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.io }
        return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
    }

    /// Foundation accepts repeated JSON keys. This scanner rejects them at
    /// every object level before Decodable or unknown-field validation runs.
    private struct UniqueKeyScanner {
        let bytes: [UInt8]
        var offset = 0
        mutating func scan() throws { try value(depth: 0); whitespace(); guard offset == bytes.count else { throw Failure.invalid } }
        mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func value(depth: Int) throws {
            guard depth < 64 else { throw Failure.invalid }; whitespace()
            guard offset < bytes.count else { throw Failure.invalid }
            switch bytes[offset] {
            case 123:
                offset += 1; whitespace(); var keys = Set<String>()
                if consume(125) { return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw Failure.invalid }
                    whitespace(); guard consume(58) else { throw Failure.invalid }; try value(depth: depth + 1); whitespace()
                    if consume(125) { return }; guard consume(44) else { throw Failure.invalid }; whitespace()
                }
            case 91:
                offset += 1; whitespace(); if consume(93) { return }
                while true { try value(depth: depth + 1); whitespace(); if consume(93) { return }; guard consume(44) else { throw Failure.invalid } }
            case 34: _ = try string()
            default:
                let start = offset
                while offset < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[offset]) { offset += 1 }
                guard offset > start else { throw Failure.invalid }
            }
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            if offset < bytes.count && bytes[offset] == byte { offset += 1; return true }; return false
        }
        mutating func string() throws -> String {
            let start = offset; guard consume(34) else { throw Failure.invalid }
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 {
                    let wrapped = Data([91] + Array(bytes[start..<offset]) + [93])
                    guard let strings = try JSONSerialization.jsonObject(with: wrapped) as? [String], strings.count == 1 else { throw Failure.invalid }
                    return strings[0]
                }
                if byte == 92 { guard offset < bytes.count else { throw Failure.invalid }; offset += 1 }
            }
            throw Failure.invalid
        }
    }
}

// The only synthetic entry builds its own fixed sources. It cannot accept a
// caller-supplied projection, configuration pin, history or expected answer.
extension AnswerEvaluationCommand {
    static func runWitnessChecks(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        guard LocalEndpoint.chatURL(baseURL) != nil else {
            completion(["witness_fixture_loopback_required": false]); return
        }
        do { WitnessCheckSuite(baseURL: baseURL, checks: try witnessDecodeChecks(baseURL: baseURL).merging(longMemoryDecodeChecks(baseURL: baseURL)) { _, newer in newer }, completion: completion).next() }
        catch { completion(["witness_contract_fixture_started": false]) }
    }

    private static func witnessFixture(baseURL: String, large: Bool = false, json: Bool = false) -> [String: Any] {
        let texts = large ? (0..<4).map { "Public synthetic source \($0) " + String(repeating: "x", count: 5000) }
            : ["Public synthetic decision café e\u{301}.", "Public synthetic assistant decision κ.\r\n"]
        var root: [String: Any] = ["version": 2, "split": "development", "history_id": "synthetic-witness-evidence-control",
            "events": texts.enumerated().map { index, text in
                ["id": "synthetic-witness-source-\(index)", "project_id": "synthetic-witness-project",
                 "conversation_key": "synthetic-witness-chat", "role": index % 2 == 0 ? "user" : "assistant",
                 "status": "complete", "text": text]
            }, "attempts": [["probe_id": "synthetic-witness-probe", "project_id": "synthetic-witness-project",
                "conversation_key": "synthetic-witness-chat", "prompt": "Identify the public synthetic decision.",
                "strategy": "recent_only", "replicate": 0]],
            "configuration": ["endpoint": baseURL, "model": Qwen38TextRendering.modelID,
                "system": "Use complete public synthetic sources and exact citations.", "temperature": 0,
                "seed": 42, "thinking": false, "maximum_output": 64, "context_limit": 32768, "safety_tokens": 256]]
        if json {
            root["version"] = 3
            var configuration = root["configuration"] as! [String: Any]
            configuration["response_format"] = "json_object"
            root["configuration"] = configuration
        }
        return root
    }
    private static func witnessFixtureBytes(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func witnessFixturePins(_ root: [String: Any], ordinary: Set<String> = []) throws -> InputPins {
        let projection = try projectionSHA256(witnessFixtureBytes(root))
        let configuration = digest(try witnessFixtureBytes(root["configuration"] as! [String: Any]))
        if root["version"] as? Int == 3 {
            return InputPins(ordinary: ordinary, witness: [], witnessConfiguration: witnessConfigurationSHA256,
                jsonWitness: [projection], jsonConfiguration: configuration)
        }
        return InputPins(ordinary: ordinary, witness: [projection], witnessConfiguration: configuration)
    }
    private static func witnessDecodeChecks(baseURL: String) throws -> [String: Bool] {
        let root = witnessFixture(baseURL: baseURL), bytes = try witnessFixtureBytes(root), pins = try witnessFixturePins(root)
        var checks: [String: Bool] = [
            "witness_contract_fixed_complete_pack_accepted": try decode(bytes, pins: pins).events.count == 2,
            "witness_contract_production_pins_disjoint": witnessCorpusProjectionSHA256.count == 9
                && witnessCorpusProjectionSHA256.isDisjoint(with: InputPins.production.ordinary),
            "witness_contract_native_configuration_pin_exact": witnessConfigurationSHA256 == "73729124226e2a729d052ea49d6f03ecced31b2b93e3beea63064ab046fa0013"
        ]
        func refused(_ value: [String: Any], using selected: InputPins) -> Bool {
            do { _ = try decode(witnessFixtureBytes(value), pins: selected); return false } catch { return true }
        }
        checks["witness_contract_synthetic_pack_not_production_authority"] = refused(root, using: .production)
        let jsonRoot = witnessFixture(baseURL: baseURL, json: true)
        let jsonPins = try witnessFixturePins(jsonRoot)
        checks["witness_contract_json_object_version_three_accepted"] = try decode(witnessFixtureBytes(jsonRoot), pins: jsonPins).configuration.settings.endpointJSONOutput
        checks["witness_contract_json_object_original_pins_reject"] = refused(jsonRoot, using: pins)
        for (name, value) in [("schema", "json_schema" as Any), ("unknown", "other" as Any),
                               ("null", NSNull() as Any), ("boolean", true as Any)] {
            var invalidRoot = jsonRoot; var invalidConfiguration = jsonRoot["configuration"] as! [String: Any]
            invalidConfiguration["response_format"] = value; invalidRoot["configuration"] = invalidConfiguration
            checks["witness_contract_json_object_invalid_format_\(name)_rejected"] = refused(invalidRoot, using: try witnessFixturePins(invalidRoot))
        }
        var legacyFormat = jsonRoot; legacyFormat["version"] = 2
        checks["witness_contract_json_object_field_rejected_in_version_two"] = refused(legacyFormat, using: try witnessFixturePins(legacyFormat))
        var unformattedV3 = root; unformattedV3["version"] = 3
        checks["witness_contract_version_three_requires_format"] = refused(unformattedV3, using: try witnessFixturePins(unformattedV3))
        var formatRoot = root
        var formatConfiguration = root["configuration"] as! [String: Any]
        formatConfiguration["system"] = "Follow the public synthetic requested JSON structure."
        formatRoot["configuration"] = formatConfiguration
        var formatPins = pins
        formatPins.formatConfiguration = digest(try witnessFixtureBytes(formatConfiguration))
        checks["witness_contract_separate_format_configuration_accepted"] = try decode(witnessFixtureBytes(formatRoot), pins: formatPins).version == 2
        checks["witness_contract_format_configuration_requires_separate_pin"] = refused(formatRoot, using: pins)
        checks["witness_contract_original_configuration_preserved_with_amendment"] = try decode(bytes, pins: formatPins).version == 2
        var changedFormat = formatConfiguration
        changedFormat["maximum_output"] = 65
        var changedFormatRoot = formatRoot; changedFormatRoot["configuration"] = changedFormat
        checks["witness_contract_format_configuration_other_settings_rejected"] = refused(changedFormatRoot, using: formatPins)
        var source = root; var events = source["events"] as! [[String: Any]]
        events[0]["text"] = "Changed public synthetic original."; source["events"] = events
        checks["witness_contract_changed_original_rejected"] = refused(source, using: pins)
        var prompt = root; var attempts = prompt["attempts"] as! [[String: Any]]
        attempts[0]["prompt"] = "Changed public synthetic probe."; prompt["attempts"] = attempts
        checks["witness_contract_changed_probe_rejected"] = refused(prompt, using: pins)
        for (name, value) in [("maximum_output", 65 as Any), ("system", "Changed synthetic host." as Any),
                              ("seed", 43 as Any), ("temperature", 0.1 as Any), ("thinking", true as Any),
                              ("context_limit", 16384 as Any), ("safety_tokens", 257 as Any),
                              ("endpoint", "http://localhost:11235/v1" as Any), ("model", "synthetic-other-model" as Any)] {
            var changed = root; var configuration = changed["configuration"] as! [String: Any]
            configuration[name] = value; changed["configuration"] = configuration
            checks["witness_contract_configuration_\(name)_change_rejected"] = refused(changed, using: pins)
        }
        // Repin only these fixed negative fixtures to exercise the independent
        // grammar, rather than obtaining rejection solely from the digest.
        for name in ["boolean_version", "unsupported_version", "hybrid", "replicate", "extra_attempt", "odd_pack", "wrong_role", "partial", "foreign_scope", "oracle"] {
            var changed = root
            var rows = changed["events"] as! [[String: Any]], tries = changed["attempts"] as! [[String: Any]]
            switch name {
            case "boolean_version": changed["version"] = true
            case "unsupported_version": changed["version"] = 4
            case "hybrid": tries[0]["strategy"] = "hybrid"
            case "replicate": tries[0]["replicate"] = 1
            case "extra_attempt": var extra = tries[0]; extra["probe_id"] = "synthetic-other-probe"; tries.append(extra)
            case "odd_pack": rows.removeLast()
            case "wrong_role": rows[1]["role"] = "user"
            case "partial": rows[1]["status"] = "partial"
            case "foreign_scope": rows[1]["project_id"] = "synthetic-other-project"
            default: changed["expected"] = "Synthetic oracle must never enter native input."
            }
            changed["events"] = rows; changed["attempts"] = tries
            checks["witness_contract_\(name)_rejected"] = refused(changed, using: try witnessFixturePins(changed))
        }
        var old = root; old["version"] = 1
        let oldProjection = try projectionSHA256(witnessFixtureBytes(old))
        let oldPins = InputPins(ordinary: [oldProjection], witness: pins.witness, witnessConfiguration: pins.witnessConfiguration)
        checks["witness_contract_version_one_preserved"] = try decode(witnessFixtureBytes(old), pins: oldPins).version == 1
        var oldConfiguration = old["configuration"] as! [String: Any]; oldConfiguration["maximum_output"] = 65
        old["configuration"] = oldConfiguration
        checks["witness_contract_version_one_configuration_allowance_preserved"] = try decode(witnessFixtureBytes(old), pins: oldPins).configuration.maximum_output == 65
        checks["witness_contract_witness_projection_rejected_by_version_one"] = refused(old, using: pins)
        let duplicate = Data(("{\"version\":2," + String(decoding: bytes.dropFirst(), as: UTF8.self)).utf8)
        do { _ = try decode(duplicate, pins: pins); checks["witness_contract_duplicate_keys_rejected"] = false }
        catch { checks["witness_contract_duplicate_keys_rejected"] = true }
        return checks
    }

    private static func longMemoryDecodeChecks(baseURL: String) throws -> [String: Bool] {
        var root = witnessFixture(baseURL: baseURL)
        root["version"] = 4
        let time = EventSourceTime(value: "2023-07-27T18:00", precision: "minute", timezone: "unspecified",
            sourceSHA256: String(repeating: "a", count: 64), locator: "/0/haystack_dates/0", originalValue: "2023/07/27 (Thu) 18:00")
        var events = root["events"] as! [[String: Any]]
        events[0]["source_time"] = time.object; events[1]["source_time"] = time.object
        events[1]["conversation_key"] = "synthetic-other-session"
        root["events"] = events
        var attempt = (root["attempts"] as! [[String: Any]])[0]
        let questionTime = EventSourceTime(value: "2023-07-28T18:00", precision: "minute", timezone: "unspecified",
            sourceSHA256: time.sourceSHA256, locator: "/0/question_date", originalValue: "2023/07/28 (Fri) 18:00")
        attempt["question_time"] = questionTime.object
        var hybrid = attempt; hybrid["strategy"] = "hybrid"
        root["attempts"] = [attempt, hybrid]
        let bytes = try witnessFixtureBytes(root)
        var pins = InputPins(ordinary: [], witness: [], witnessConfiguration: witnessConfigurationSHA256)
        pins.longMemory = [try projectionSHA256(bytes)]
        pins.longMemoryConfiguration = digest(try witnessFixtureBytes(root["configuration"] as! [String: Any]))
        let document = try decode(bytes, pins: pins)
        var checks: [String: Bool] = [
            "longmem_v4_paired_dates_decode": document.events.count == 2 && document.attempts.count == 2,
            "longmem_v4_question_date_separate": document.attempts[0].prompt == attempt["prompt"] as? String
                && document.attempts[0].effectivePrompt == "Question Date: " + questionTime.originalValue + "\nQuestion: " + document.attempts[0].prompt,
            "longmem_v4_timezone_remains_unknown": document.events[0].source_time?.timezone == "unspecified",
            "longmem_v4_production_disjoint": longMemoryCorpusProjectionSHA256.count == 7
                && longMemoryCorpusProjectionSHA256.isDisjoint(with: InputPins.production.ordinary)
                && longMemoryCorpusProjectionSHA256.isDisjoint(with: witnessCorpusProjectionSHA256)
        ]
        func refused(_ changed: [String: Any], using selected: InputPins) -> Bool {
            do { _ = try decode(witnessFixtureBytes(changed), pins: selected); return false } catch { return true }
        }
        checks["longmem_synthetic_not_production_authority"] = refused(root, using: .production)
        for kind in ["event_date_null", "question_date_null", "oracle", "changed_source", "changed_question", "legacy", "configuration"] {
            var changed = root
            switch kind {
            case "event_date_null": var rows = events; rows[0]["source_time"] = NSNull(); changed["events"] = rows
            case "question_date_null": var rows = [attempt, hybrid]; rows[0]["question_time"] = NSNull(); changed["attempts"] = rows
            case "oracle": changed["answer"] = "Synthetic scorer only"
            case "changed_source": var rows = events; rows[0]["text"] = "Changed synthetic source"; changed["events"] = rows
            case "changed_question": var rows = [attempt, hybrid]; rows[0]["prompt"] = "Changed synthetic question"; changed["attempts"] = rows
            case "legacy": changed["version"] = 1
            default: var c = root["configuration"] as! [String: Any]; c["maximum_output"] = 129; changed["configuration"] = c
            }
            checks["longmem_v4_" + kind + "_refused"] = refused(changed, using: pins)
        }
        // Re-pin a malformed synthetic projection to test grammar separately from its checksum.
        var malformed = root; var badEvents = events; var invalidTime = time.object
        invalidTime["original_value"] = "2023/02/30 (Thu) 18:00"; badEvents[0]["source_time"] = invalidTime; malformed["events"] = badEvents
        var malformedPins = pins; malformedPins.longMemory = [try projectionSHA256(witnessFixtureBytes(malformed))]
        checks["longmem_v4_invalid_date_grammar_refused"] = refused(malformed, using: malformedPins)
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.io }
        let temporaryRoot = String(cString: resolved); free(resolved)
        let directory = URL(fileURLWithPath: temporaryRoot, isDirectory: true).appendingPathComponent("boros-longmem-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try MemoryStore(directory: directory.appendingPathComponent("store"))
        let conversations = try ingestEvents(document, into: owner)
        checks["longmem_v4_original_session_boundaries_preserved"] = conversations.count == 2
        checks["longmem_v4_exact_dates_and_text_ingested"] = try document.events.allSatisfy { event in
            let chat = conversations[key(event.project_id, event.conversation_key)]!
            return try owner.events(conversationID: chat).contains { stored in
                stored.id == event.id && Data(stored.text.utf8) == Data(event.text.utf8) && stored.sourceTime == event.source_time
            }
        }
        let archive = directory.appendingPathComponent("archive"), restored = directory.appendingPathComponent("restored")
        _ = try BackupArchive.create(from: owner, at: archive)
        _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
        let reopened = try MemoryStore(directory: restored)
        checks["longmem_v4_dates_survive_attempt_checkpoint"] = try document.events.allSatisfy { event in
            try reopened.sourceReference(eventID: event.id, projectID: project(event.project_id))?.sourceTime == event.source_time
        }
        return checks
    }

    private final class WitnessCheckSuite {
        let baseURL: String, completion: ([String: Bool]) -> Void
        var checks: [String: Bool], cases = ["complete", "reduced", "stopped", "json_complete"]
        var current: WitnessCheckAttempt?
        init(baseURL: String, checks: [String: Bool], completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.checks = checks; self.completion = completion
        }
        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try WitnessCheckAttempt(baseURL: baseURL, kind: kind) { [self] result in
                    checks.merge(result) { _, latest in latest }; current = nil
                    // Let the attempt callback return and release its private
                    // fixture before the final completion can exit the CLI.
                    DispatchQueue.main.async { [self] in next() }
                }
                current = attempt; attempt.start()
            } catch { checks["witness_\(kind)_fixture_started"] = false; next() }
        }
    }
    private final class WitnessCheckAttempt {
        let document: Document, kind: String, directory: URL, store: MemoryStore, conversationID: String
        let completion: ([String: Bool]) -> Void
        var coordinator: AnswerAttemptCoordinator?
        init(baseURL: String, kind: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.completion = completion
            let root = witnessFixture(baseURL: baseURL, large: kind == "reduced", json: kind == "json_complete")
            document = try decode(witnessFixtureBytes(root), pins: witnessFixturePins(root))
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.io }
            let path = String(cString: resolved); free(resolved)
            directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("boros-witness-check-" + UUID().uuidString)
            let baseline = try MemoryStore(directory: directory.appendingPathComponent("baseline"))
            conversationID = try baseline.createConversation(projectID: project(document.attempts[0].project_id), title: "Synthetic witness fixture").id
            for event in document.events {
                _ = try baseline.append(conversationID: conversationID, role: event.role == "user" ? .human : .assistant,
                    text: event.text, status: event.status, turnID: "synthetic-turn:" + event.id, eventID: event.id)
            }
            let archive = directory.appendingPathComponent("archive"), restored = directory.appendingPathComponent("restored")
            _ = try BackupArchive.create(from: baseline, at: archive)
            _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
            store = try MemoryStore(directory: restored)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func start() {
            let operation = AnswerAttemptCoordinator(store: store, conversationID: conversationID,
                projectID: project(document.attempts[0].project_id), prompt: document.attempts[0].prompt,
                settings: document.configuration.settings, retrievalStrategy: .recentOnly,
                onStage: { [self] stage, _ in if kind == "stopped" && stage == .answering { coordinator?.cancel() } },
                onText: { _ in }, onComplete: { [self] result, _ in finish(result) })
            coordinator = operation
            do { _ = try operation.accept(); try operation.start() }
            catch { completion(["witness_\(kind)_coordinator_started": false]) }
        }
        private func finish(_ result: AnswerAttemptCompletion) {
            let prefix = "witness_" + kind + "_", restored = directory.appendingPathComponent("restored")
            var checks: [String: Bool] = [:]
            let validated = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
            checks[prefix + "actual_v3_source_body_count_revalidated"] = validated["source_body_count_revalidated"] as? Bool == true
                && validated["input_proof_version"] as? Int == 3 && result.invocationStarted
            checks[prefix + "original_pack_outcome_explicit"] = validated["complete_pack_delivered"] as? Bool == (kind != "reduced")
                && validated["declared_source_count"] as? Int == document.events.count
                && validated["declared_source_bytes"] as? Int == document.events.reduce(0, { $0 + $1.text.utf8.count })
            checks[prefix + "fixed_failure_code"] = kind == "reduced" ? validated["failure_code"] as? String == "witness_pack_not_delivered"
                : validated["failure_code"] is NSNull
            checks[prefix + "post_terminal_inspection_timed"] = (validated["validation_milliseconds"] as? Double).map { $0.isFinite && $0 >= 0 } == true
            checks[prefix + "terminal_capture_preserved"] = result.captureHealthy && result.accountingHealthy
                && (kind == "stopped" ? result.captureStatus == .cancelled : result.captureStatus == .complete)
            do {
                let originalCharge = try store.episodeReceipt(id: result.identifiers.episodeID, clock: SystemEpisodeClock().now()).charged
                if kind == "json_complete" {
                    guard let original = try store.invocation(id: result.identifiers.invocationID),
                          let request = try JSONSerialization.jsonObject(with: original.requestBody) as? [String: Any] else { throw Failure.invalid }
                    checks[prefix + "actual_frozen_request_mode"] = (request["response_format"] as? [String: String]) == ["type": "json_object"]
                    let savedArchive = directory.appendingPathComponent("captured-archive")
                    let savedRestore = directory.appendingPathComponent("captured-restore")
                    _ = try BackupArchive.create(from: store, at: savedArchive)
                    _ = try BackupArchive.restore(from: savedArchive, to: savedRestore, authority: .unmanagedNoDeletion)
                    let reopened = try MemoryStore(directory: savedRestore)
                    let restoredInvocation = try reopened.invocation(id: result.identifiers.invocationID)
                    let restoredCharge = try reopened.episodeReceipt(id: result.identifiers.episodeID, clock: SystemEpisodeClock().now()).charged
                    checks[prefix + "captured_receipt_archive_restore_preserved"] = restoredInvocation?.requestBody == original.requestBody
                        && restoredInvocation?.admissionJSON == original.admissionJSON
                        && restoredInvocation?.finalStatus == original.finalStatus
                        && restoredCharge == originalCharge
                }
                _ = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "verification_does_not_change_original_debits"] = try store.episodeReceipt(id: result.identifiers.episodeID,
                    clock: SystemEpisodeClock().now()).charged == originalCharge
                var changedRoot = witnessFixture(baseURL: document.configuration.endpoint, large: kind == "reduced", json: kind == "json_complete")
                var configuration = changedRoot["configuration"] as! [String: Any]; configuration["system"] = "Changed public synthetic host."
                changedRoot["configuration"] = configuration
                let changed = try decode(witnessFixtureBytes(changedRoot), pins: witnessFixturePins(changedRoot))
                let host = validateWitness(document: changed, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "host_mismatch_cannot_claim_proof"] = host["source_body_count_revalidated"] as? Bool == false
                    && host["complete_pack_delivered"] is NSNull
                var raw: OpaquePointer?
                guard sqlite3_open_v2(restored.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                      let database = raw else { if let raw { sqlite3_close(raw) }; throw Failure.io }
                defer { sqlite3_close(database) }
                let invocation = try AuthorityStateKernel.rows(database,
                    "SELECT request_body,admission_json FROM invocations WHERE id=?", [.text(result.identifiers.invocationID)])
                guard invocation.count == 1, let body = invocation[0][0].bytes, let admission = invocation[0][1].bytes,
                      var audit = try JSONSerialization.jsonObject(with: admission) as? [String: Any] else { throw Failure.invalid }
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET request_body=? WHERE id=?",
                    [.bytes(Data("{}".utf8)), .text(result.identifiers.invocationID)])
                let wrongBody = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "actual_body_mismatch_rejected"] = wrongBody["source_body_count_revalidated"] as? Bool == false
                    && wrongBody["complete_pack_delivered"] is NSNull
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET request_body=? WHERE id=?",
                    [.bytes(body), .text(result.identifiers.invocationID)])
                audit["version"] = 2; audit.removeValue(forKey: "inputProofWorkID"); audit.removeValue(forKey: "inputProofSHA256")
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET admission_json=? WHERE id=?",
                    [.bytes(try witnessFixtureBytes(audit)), .text(result.identifiers.invocationID)])
                let oldProof = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "version_two_cannot_claim_complete_proof"] = oldProof["source_body_count_revalidated"] as? Bool == false
                    && oldProof["complete_pack_delivered"] is NSNull
                try AuthorityStateKernel.execute(database, "UPDATE invocations SET admission_json=? WHERE id=?",
                    [.bytes(admission), .text(result.identifiers.invocationID)])
                // First source is deliberately geometrically omitted in the
                // reduced fixture. All-original validation must still fail.
                try AuthorityStateKernel.execute(database, "UPDATE events SET status='partial' WHERE id=?", [.text(document.events[0].id)])
                let tampered = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "entire_original_union_tamper_rejected"] = tampered["source_body_count_revalidated"] as? Bool == false
                    && tampered["complete_pack_delivered"] is NSNull && tampered["failure_code"] as? String == "witness_source_body_count_invalid"
                try AuthorityStateKernel.execute(database, "UPDATE events SET status='complete' WHERE id=?", [.text(document.events[0].id)])
                try AuthorityStateKernel.execute(database, "DELETE FROM invocations WHERE id=?", [.text(result.identifiers.invocationID)])
                let missing = validateWitness(document: document, completion: result, directory: restored, conversationID: conversationID)
                checks[prefix + "missing_invocation_cannot_claim_proof"] = missing["source_body_count_revalidated"] as? Bool == false
                    && missing["complete_pack_delivered"] is NSNull
                let unknown = witnessOutcome(events: document.events, failure: "witness_outcome_unavailable")
                checks[prefix + "unavailable_preserves_declared_counts"] = unknown["declared_source_count"] as? Int == document.events.count
                    && unknown["declared_source_bytes"] as? Int == document.events.reduce(0, { $0 + $1.text.utf8.count })
                    && unknown["complete_pack_delivered"] is NSNull && unknown["source_body_count_revalidated"] is NSNull
                    && unknown["validation_milliseconds"] is NSNull
            } catch { checks[prefix + "integrity_fixture_completed"] = false }
            completion(checks)
        }
    }
}
