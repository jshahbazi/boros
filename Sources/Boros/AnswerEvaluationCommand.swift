import Foundation
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
    private enum Failure: Error { case arguments, invalid, io }
    private struct Event: Decodable {
        let id: String
        let project_id: String
        let conversation_key: String
        let role: String
        let status: CaptureStatus
        let text: String
    }
    private struct Attempt: Decodable {
        let probe_id: String
        let project_id: String
        let conversation_key: String
        let prompt: String
        let strategy: ContextRetrievalStrategy
        let replicate: Int
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
        var settings: GenerationSettings {
            var value = GenerationSettings()
            value.profile = .customLocal; value.endpointURL = endpoint; value.endpointModel = model
            value.system = system; value.temperature = temperature; value.seed = seed
            value.thinkingEnabled = thinking; value.maximumOutput = maximum_output
            value.endpointContextLimit = context_limit; value.endpointSafetyTokens = safety_tokens
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
            let session = try Session(document: document, inputDigest: digest(bytes), output: output)
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

    private static func decode(_ bytes: Data) throws -> Document {
        var scanner = UniqueKeyScanner(bytes: Array(bytes)); try scanner.scan()
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == ["version", "split", "history_id", "events", "attempts", "configuration"],
              let events = root["events"] as? [[String: Any]],
              events.allSatisfy({ Set($0.keys) == ["id", "project_id", "conversation_key", "role", "status", "text"] }),
              let attempts = root["attempts"] as? [[String: Any]],
              attempts.allSatisfy({ Set($0.keys) == ["probe_id", "project_id", "conversation_key", "prompt", "strategy", "replicate"] }),
              let configuration = root["configuration"] as? [String: Any],
              Set(configuration.keys) == ["endpoint", "model", "system", "temperature", "seed", "thinking", "maximum_output", "context_limit", "safety_tokens"] else { throw Failure.invalid }
        var publicProjection = root
        publicProjection.removeValue(forKey: "configuration")
        guard digest(try JSONSerialization.data(withJSONObject: publicProjection,
            options: [.sortedKeys, .withoutEscapingSlashes])) == publicCorpusProjectionSHA256 else { throw Failure.invalid }
        let value = try JSONDecoder().decode(Document.self, from: bytes)
        guard value.version == 1, value.split == "development", identifier(value.history_id),
              !value.events.isEmpty, value.events.count <= 100_000,
              !value.attempts.isEmpty, value.attempts.count <= 1000,
              Set(value.events.map(\.id)).count == value.events.count else { throw Failure.invalid }
        var conversations = Set<String>(), attemptsSeen = Set<String>()
        for event in value.events {
            guard identifier(event.id), identifier(event.project_id), identifier(event.conversation_key),
                  ["user", "assistant"].contains(event.role), event.text.utf8.count <= MemoryStore.maximumPayloadBytes else { throw Failure.invalid }
            conversations.insert(key(event.project_id, event.conversation_key))
        }
        for attempt in value.attempts {
            guard identifier(attempt.probe_id), identifier(attempt.project_id), identifier(attempt.conversation_key),
                  conversations.contains(key(attempt.project_id, attempt.conversation_key)),
                  !attempt.prompt.isEmpty, attempt.prompt.utf8.count <= MemoryStore.maximumPayloadBytes,
                  (0...100).contains(attempt.replicate),
                  attemptsSeen.insert("\(attempt.probe_id)|\(attempt.strategy.rawValue)|\(attempt.replicate)").inserted else { throw Failure.invalid }
        }
        let c = value.configuration
        guard LocalEndpoint.chatURL(c.endpoint) != nil, c.model == Qwen38TextRendering.modelID,
              !c.system.isEmpty, c.system.utf8.count <= 8192, c.temperature.isFinite, (0...2).contains(c.temperature),
              (0...Int(Int32.max)).contains(c.seed), (1...8192).contains(c.maximum_output),
              (1024...131072).contains(c.context_limit), (0...8192).contains(c.safety_tokens),
              c.maximum_output + c.safety_tokens < c.context_limit else { throw Failure.invalid }
        _ = try EndpointRequest.build(prompt: value.attempts[0].prompt, settings: c.settings, conversation: Conversation())
        return value
    }

    private final class Session {
        let document: Document
        let inputDigest: String
        let output: URL
        let runtime: URL
        let archive: URL
        var conversations: [String: String] = [:]
        var report: [[String: Any]] = []
        var baseline: [String: Any] = [:]
        var ordinal = 0
        var coordinator: AnswerAttemptCoordinator?
        init(document: Document, inputDigest: String, output: URL) throws {
            self.document = document; self.inputDigest = inputDigest; self.output = output
            // Foundation can normalize /private/var back to the /var symlink.
            // The native realpath witness preserves the physical ancestors
            // required by the no-symlink diagnostic destination contract.
            guard let temporaryPath = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.io }
            defer { free(temporaryPath) }
            runtime = URL(fileURLWithPath: String(cString: temporaryPath), isDirectory: true)
                .appendingPathComponent("boros-answer-evaluation-" + UUID().uuidString, isDirectory: true)
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
            for event in document.events {
                let mapping = key(event.project_id, event.conversation_key)
                if conversations[mapping] == nil {
                    conversations[mapping] = try owner.createConversation(projectID: project(event.project_id), title: "Public diagnostic corpus").id
                }
                _ = try owner.append(conversationID: conversations[mapping]!, role: event.role == "user" ? .human : .assistant,
                    text: event.text, status: event.status, turnID: "public-turn:" + event.id, eventID: event.id)
            }
            let manifest = try BackupArchive.create(from: owner, at: archive)
            baseline = ["events": manifest.inventory.events, "source_bytes": manifest.inventory.sourceBytes,
                "conversations": manifest.inventory.conversations, "archive_id": manifest.archiveID,
                "database_schema": manifest.databaseSchema,
                "archive_sha256": digest(try canonical(manifest)),
                "timestamps": "ingestion_frozen_in_checkpoint", "derived_sidecar_in_checkpoint": false]
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
                projectID: project(attempt.project_id), prompt: attempt.prompt,
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
            report.append(item)
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
                    report.append(item)
                }
                report.sort { ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) }
                guard var configuration = try object(EpisodeLimits()) as? [String: Any] else { throw Failure.invalid }
                configuration["componentPolicy"] = try object(ContextComponentPolicy.selectedQwen)
                let c = document.configuration
                let value: [String: Any] = ["version": 1, "diagnostic": "production-answer-development-v1",
                    "split": "development", "history_id": document.history_id, "input_sha256": inputDigest,
                    "public_projection_sha256": publicCorpusProjectionSHA256,
                    "fatal_failure": fatal as Any? ?? NSNull(), "declared_attempts": document.attempts.count,
                    "completed_attempts": report.filter { $0["terminalized"] as? Bool == true }.count, "baseline": baseline, "attempts": report,
                    "configuration": ["endpoint": c.endpoint, "model": c.model,
                        "instruction_sha256": digest(Data(c.system.utf8)), "temperature": c.temperature,
                        "seed": c.seed, "thinking": c.thinking, "maximum_output": c.maximum_output,
                        "context_limit": c.context_limit, "safety_tokens": c.safety_tokens,
                        "episode_limits": configuration, "background_limits": try object(BackgroundIndexLimits.development)],
                    "unknowns": ["apple_input_tokens", "local_billed_cost", "first_useful_answer"]]
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
