import Foundation
import CSQLite
import Darwin

/// Exercises the actual coordinator against a declared synthetic tokenizer.
/// The fixture controls count completion with barriers, never real model data.
enum ComponentPreparationChecks {
    static func run(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        let suite = Suite(baseURL: baseURL, completion: completion)
        suite.next()
    }

    private enum Case: String, CaseIterable {
        case mandatory, scope, boundary, pipeline, envelope, httpLimit, cancel, deadline
        case identityModel, identityTemplate, identityRuntime
    }
    private final class Clock: EpisodeClockSource {
        private let lock = NSLock()
        private var ticks: UInt64 = 1_000_000_000
        func expire() { lock.lock(); ticks = 200_000_000_000; lock.unlock() }
        func now() throws -> EpisodeClockSnapshot {
            lock.lock(); defer { lock.unlock() }
            return EpisodeClockSnapshot(domain: "synthetic-component-preparation-clock", continuousNanoseconds: ticks, utc: Date())
        }
    }
    private final class Suite {
        let baseURL: String
        let completion: ([String: Bool]) -> Void
        var cases = Array(Case.allCases)
        var checks: [String: Bool] = [:]
        var current: Attempt?
        init(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.completion = completion
        }
        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try Attempt(kind: kind, baseURL: baseURL) { [self] result in
                    checks.merge(result) { _, latest in latest }
                    current = nil
                    next()
                }
                current = attempt
                attempt.start()
            } catch {
                checks["component_preparation_\(kind.rawValue)_fixture_started"] = false
                next()
            }
        }
    }
    private final class Attempt {
        let kind: Case
        let baseURL: String
        let directory: URL
        let store: MemoryStore
        let chat: StoredConversation
        let clock = Clock()
        let lease: EpisodeLease
        let currentID: String
        let prompt: String
        let completion: ([String: Bool]) -> Void
        var settings = GenerationSettings()
        var operation: ComponentContextPreparationOperation?
        var completed = false
        private var failureStage = "preparation_audit"
        let droppedSourceID: String

        init(kind: Case, baseURL: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.baseURL = baseURL; self.completion = completion
            guard let resolvedTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw MemoryError.database("synthetic fixture temporary path resolution failed")
            }
            let temporaryPath = String(cString: resolvedTemporary)
            free(resolvedTemporary)
            directory = URL(fileURLWithPath: temporaryPath, isDirectory: true)
                .appendingPathComponent("boros-preparation-" + UUID().uuidString, isDirectory: true)
            store = try MemoryStore(directory: directory)
            chat = try store.createConversation(projectID: "synthetic-preparation", title: "Synthetic component preparation")
            currentID = "fixture-current-" + kind.rawValue
            droppedSourceID = "fixture-" + kind.rawValue + "-recent-0"
            let marker: String
            switch kind {
            case .mandatory: marker = "fixtureMandatory"
            case .boundary: marker = "fixtureBoundary"
            case .cancel: marker = "fixtureBarrierCancel"
            case .deadline: marker = "fixtureBarrierDeadline"
            case .identityModel: marker = "fixtureIdentityModel"
            case .identityTemplate: marker = "fixtureIdentityTemplate"
            case .identityRuntime: marker = "fixtureIdentityRuntime"
            default: marker = "fixturePipeline"
            }
            prompt = marker + " Where is pipelinekey?"
            if kind == .pipeline || kind == .envelope || kind == .boundary || kind == .httpLimit {
                let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic original spans")
                for index in 0..<(kind == .boundary ? 3 : 5) {
                    let prefix = "pipelinekey archived source \(index) "
                    let text = prefix + String(repeating: " filler", count: (4096 - prefix.utf8.count) / 7)
                    _ = try store.append(conversationID: archive.id, role: .human, text: text, status: .complete,
                        turnID: "fixture-archive-turn-\(index)", eventID: "fixture-\(kind.rawValue)-archive-\(index)")
                }
            }
            let count = kind == .boundary ? 2 : (kind == .cancel || kind == .deadline
                || kind == .identityModel || kind == .identityTemplate || kind == .identityRuntime) ? 1 : 7
            for index in 0..<count {
                let text = kind == .cancel || kind == .deadline ? marker + " recent source"
                    : index == 0 ? "pipelinekey original recent decision" : "Synthetic recent source \(index)"
                _ = try store.append(conversationID: chat.id, role: index % 2 == 0 ? .human : .assistant,
                    text: text, status: index == 3 ? .partial : .complete,
                    turnID: "fixture-recent-turn-\(index)", eventID: "fixture-\(kind.rawValue)-recent-\(index)")
            }
            let episodeID = UUID().uuidString
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
            if kind == .httpLimit { limits.resources.httpAttempts = 4 }
            _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "fixture-current-turn",
                humanEventID: currentID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
            settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.endpointModel = Qwen38TextAdapter.modelID; settings.maximumOutput = 64
            settings.endpointSafetyTokens = 256; settings.endpointContextLimit = kind == .envelope ? 9000 : 32768
            settings.temperature = 0; settings.episodeLease = lease
            switch kind {
            case .identityModel: settings.endpointAPIKey = "synthetic-component-model-drift"
            case .identityTemplate: settings.endpointAPIKey = "synthetic-component-template-drift"
            case .identityRuntime: settings.endpointAPIKey = "synthetic-component-version-drift"
            default: break
            }
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func start() {
            let preparation = ComponentContextPreparationOperation(store: store, conversationID: chat.id,
                projectID: chat.projectID, humanEventID: kind == .scope ? "fixture-foreign-human" : currentID,
                prompt: prompt, settings: settings,
                conversation: Conversation(), semanticIndex: nil, episodeLease: lease) { [self] outcome in finish(outcome) }
            operation = preparation
            if kind == .cancel || kind == .deadline { installBarrierObserver() }
            preparation.start()
        }
        private func installBarrierObserver() {
            guard let base = LocalEndpoint.chatURL(baseURL), var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
            parts.path = "/fixture-wait"; parts.queryItems = [URLQueryItem(name: "case", value: kind.rawValue)]
            guard let url = parts.url else { return }
            var request = URLRequest(url: url); request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { [self] data, response, error in
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      object["ready"] as? Bool == true else {
                    operation?.cancel(); return
                }
                if kind == .cancel { operation?.cancel() }
                else { clock.expire() }
                var releaseParts = parts
                releaseParts.path = "/fixture-release"
                guard let releaseURL = releaseParts.url else { operation?.cancel(); return }
                var releaseRequest = URLRequest(url: releaseURL); releaseRequest.httpMethod = "POST"
                releaseRequest.timeoutInterval = 10
                URLSession.shared.dataTask(with: releaseRequest) { _, _, _ in }.resume()
            }.resume()
        }
        private func journalInventory() throws -> (episodes: Int, invocations: Int, answerWork: Int, tokenizerWork: Int, generativeTokenizerWork: Int) {
            var database: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database,
                SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { throw MemoryError.database("synthetic ledger inventory failed") }
            defer { sqlite3_close(database) }
            func count(_ sql: String) throws -> Int {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw MemoryError.database("synthetic inventory query failed") }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("synthetic inventory read failed") }
                return Int(sqlite3_column_int64(statement, 0))
            }
            return (try count("SELECT count(*) FROM episodes"), try count("SELECT count(*) FROM invocations"),
                try count("SELECT count(*) FROM episode_work WHERE kind='answer'"),
                try count("SELECT count(*) FROM episode_work WHERE kind='tokenizer'"),
                try count("SELECT count(*) FROM episode_work WHERE kind='tokenizer' AND (json_extract(charged_json,'$.inputTokens')!=0 OR json_extract(charged_json,'$.outputTokens')!=0 OR json_extract(charged_json,'$.modelCalls')!=0 OR json_extract(request_json,'$.resources.inputTokens')!=0 OR json_extract(request_json,'$.resources.outputTokens')!=0 OR json_extract(request_json,'$.resources.modelCalls')!=0)"))
        }
        private struct AdmissionAudit: Codable {
            let version: Int
            let receipt: EndpointAdmissionReceipt
            let attempts: [ProviderAdmissionAccounting]
            let context: Data
        }
        private func validateJournal() throws {
            var raw: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw,
                SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = raw else {
                if let raw { sqlite3_close(raw) }
                throw MemoryError.database("synthetic journal preflight open failed")
            }
            defer { sqlite3_close(database) }
            try MemoryStore.validateEpisodeJournal(database: database)
        }
        private func capturePrepared(_ prepared: PreparedComponentContext) throws {
            failureStage = "answer_reservation"
            let work = try lease.prepare(kind: .answer,
                resources: EpisodeResources(inputTokens: prepared.receipt.promptTokens, outputTokens: prepared.receipt.outputReserve,
                    modelCalls: 1, httpAttempts: 1), adapterIdentity: prepared.receipt.answerAdapterIdentity, snapshot: prepared.body)
            failureStage = "admission_encoding"
            let admission = try JSONEncoder().encode(AdmissionAudit(version: 2, receipt: prepared.receipt,
                attempts: prepared.receipt.accounting.map { [$0] } ?? [], context: prepared.snapshot.deliveryAudit()))
            failureStage = "invocation_admission"
            _ = try store.beginInvocation(invocationID: "fixture-invocation", conversationID: chat.id, turnID: "fixture-current-turn",
                humanEventID: currentID, assistantEventID: "fixture-assistant", providerIdentity: prepared.receipt.endpoint,
                requestBody: prepared.body, admissionJSON: admission, episodeID: lease.episodeID, episodeWorkID: work.id)
            failureStage = "episode_terminalization"
            _ = try lease.finish(reason: .cancelled)
            failureStage = "invocation_terminalization"
            _ = try store.finalizeInvocation(invocationID: "fixture-invocation", status: .cancelled, reason: .cancelled)
        }
        private func finish(_ outcome: Result<PreparedComponentContext, Error>) {
            guard !completed else { return }
            completed = true
            var checks: [String: Bool] = [:]
            let prefix = "component_preparation_" + kind.rawValue
            do {
                let state = try store.episodeReceipt(id: lease.episodeID, clock: clock.now())
                switch outcome {
                case .success(let prepared):
                    guard let proof = prepared.receipt.componentProof else { throw ProviderAdmissionError.countMismatch }
                    let sourceDigest = try prepared.snapshot.selectionDigest()
                    checks[prefix + "_one_original_episode"] = proof.episodeID == lease.episodeID
                        && prepared.settings.episodeLease?.episodeID == lease.episodeID
                    checks[prefix + "_mandatory_output_safety_intact"] = prepared.snapshot.messages.last?.content == prompt
                        && prepared.settings.maximumOutput == 64 && prepared.receipt.outputReserve == 64
                        && prepared.settings.endpointSafetyTokens == 256 && prepared.receipt.safetyTokens == 256
                    checks[prefix + "_counted_source_body_policy_proof"] = prepared.settings.preparedEndpointBody == prepared.body
                        && prepared.settings.preparedContextComponents?.accepts(receipt: prepared.receipt,
                            body: prepared.body, settings: prepared.settings) == true
                        && prepared.settings.preparedContextComponents?.sourceSnapshotDigest == sourceDigest
                    checks[prefix + "_component_caps_independent_of_whole"] = proof.recent.tokens <= 8000
                        && proof.evidence.tokens <= 12000 && prepared.receipt.promptTokens == proof.wholePrompt.tokens
                    let countInventory = try journalInventory()
                    checks[prefix + "_tokenizer_counts_charge_no_generative_input"] = countInventory.tokenizerWork > 0
                        && countInventory.generativeTokenizerWork == 0 && state.charged.httpAttempts > 4
                    if let accounting = prepared.receipt.accounting, let usage = accounting.calibrationUsage {
                        checks[prefix + "_independent_session_calibration_is_fully_charged"] = accounting.calibrationRequestCount == 1
                            && state.charged.modelCalls == 1 && state.charged.inputTokens == usage.promptTokens
                            && state.charged.outputTokens == usage.completionTokens && usage.completionTokens == 1
                            && state.held.outputTokens == 0
                    } else { checks[prefix + "_independent_session_calibration_is_fully_charged"] = false }
                    checks[prefix + "_provider_instance_identity_is_explicitly_unknown"] = proof.modelIdentity.instanceIdentity == "unobservable"
                        && prepared.receipt.modelIdentity?.instanceIdentity == "unobservable"
                        && proof.modelEpoch == 0 && prepared.receipt.loadedModelEpoch == 0
                    let audit = try JSONSerialization.jsonObject(with: prepared.snapshot.deliveryAudit()) as! [String: Any]
                    checks[prefix + "_durable_component_audit_attached"] = audit["components"] is [String: Any]
                        && audit["source_snapshot_sha256"] as? String == sourceDigest
                    switch kind {
                    case .boundary:
                        checks[prefix + "_exact_cap_boundaries_retained"] = proof.recent.tokens == 8000 && proof.evidence.tokens == 12000
                            && prepared.snapshot.includedRecentCount == 2 && prepared.snapshot.evidence.count == 3
                    case .pipeline:
                        checks[prefix + "_token_reduced_recent_source_eligible"] = prepared.snapshot.recentSourceIDs == ["fixture-pipeline-recent-6"]
                            && prepared.snapshot.evidence.map(\.eventID) == [droppedSourceID]
                            && prepared.snapshot.selectionAudit?.recentTokenExcludedCount == 6
                            && prepared.snapshot.selectionAudit?.evidenceTokenExcludedCount == 5
                        checks[prefix + "_geometric_underfilled_caps_declared"] = proof.recent.tokens == 4000 && proof.evidence.tokens == 5000
                            && proof.wholePrompt.tokens == 9100
                    case .envelope:
                        checks[prefix + "_whole_overflow_reduces_evidence_before_recent"] = prepared.snapshot.evidence.isEmpty
                            && prepared.snapshot.recentSourceIDs == ["fixture-envelope-recent-6"]
                            && prepared.snapshot.selectionAudit?.evidenceEnvelopeExcludedCount == 1
                            && prepared.snapshot.selectionAudit?.recentEnvelopeExcludedCount == 0
                        checks[prefix + "_whole_recount_not_component_sum"] = proof.wholePrompt.tokens == 4100
                            && proof.evidence.tokens == 0 && proof.evidence.tokenizerWorkID == nil
                    default: checks[prefix + "_expected_failure"] = false
                    }
                    try capturePrepared(prepared)
                    checks[prefix + "_prepared_proof_accepts_durable_invocation"] = true
                    let archive = directory.appendingPathComponent("verified-component-archive")
                    failureStage = "journal_preflight"
                    try validateJournal()
                    failureStage = "archive_creation"
                    let manifest = try BackupArchive.create(from: store, at: archive)
                    failureStage = "archive_verification"
                    let verified = try BackupArchive.verify(at: archive)
                    checks[prefix + "_archive_validates_component_proof_linkage"] = verified == manifest
                        && manifest.inventory.invocations == 1 && manifest.inventory.episodes == 1
                    let restoredDirectory = directory.appendingPathComponent("restored-component-store")
                    failureStage = "archive_restore"
                    _ = try BackupArchive.restore(from: archive, to: restoredDirectory, authority: .unmanagedNoDeletion)
                    let restored = try MemoryStore(directory: restoredDirectory)
                    let invocation = try restored.invocation(id: "fixture-invocation")
                    let restoredReceipt = try restored.episodeReceipt(id: lease.episodeID, clock: clock.now())
                    let originalReceipt = try store.episodeReceipt(id: lease.episodeID, clock: clock.now())
                    let originalAdmission = try store.invocation(id: "fixture-invocation")?.admissionJSON
                    checks[prefix + "_restore_preserves_exact_component_body_and_charges"] = invocation?.requestBody == prepared.body
                        && invocation?.finalStatus == .cancelled && restoredReceipt.charged == originalReceipt.charged
                        && restoredReceipt.held == originalReceipt.held
                        && invocation?.admissionJSON == originalAdmission
                    if kind == .pipeline {
                        checks.merge(JournalCorruptionChecks.run(archive: archive, directory: directory)) { _, latest in latest }
                    }
                case .failure(let error):
                    let code = ComponentContextPreparationOperation.failureCode(error)
                    let failureInventory = try journalInventory()
                    switch kind {
                    case .identityModel, .identityTemplate, .identityRuntime:
                        let expected = kind == .identityTemplate ? ProviderAdmissionError.templateMismatch.failureCode
                            : ProviderAdmissionError.unverifiedAdapter.failureCode
                        checks[prefix + "_actual_metadata_drift_rejects_prepared_result"] = code == expected
                        let countInventory = try journalInventory()
                        checks[prefix + "_drift_retains_counts_and_calibration_before_answer"] = state.charged.httpAttempts >= 7
                            && state.charged.modelCalls == 1 && state.charged.inputTokens > 0 && state.charged.outputTokens == 1
                            && countInventory.tokenizerWork > 1 && countInventory.generativeTokenizerWork == 0
                            && countInventory.answerWork == 0 && countInventory.invocations == 0
                            && settings.maximumOutput == 64 && settings.endpointSafetyTokens == 256
                    case .scope:
                        checks[prefix + "_foreign_accepted_origin_rejected_before_work"] = code == "episode_scope_mismatch"
                            && state.charged.httpAttempts == 0 && state.charged.rawSourceBytes == 0
                            && state.charged.metadataRows == 0 && state.charged.memoryOperations == 0
                            && state.charged.modelCalls == 0 && state.held == .zero
                    case .mandatory:
                        checks[prefix + "_overflow_before_source_access"] = code == "context_full"
                            && state.charged.rawSourceBytes == 0 && state.charged.metadataRows == 0
                            && state.charged.memoryOperations == 0
                        checks[prefix + "_accepted_request_preserved"] = try store.events(conversationID: chat.id).last?.text == prompt
                            && settings.maximumOutput == 64 && settings.endpointSafetyTokens == 256
                    case .httpLimit:
                        checks[prefix + "_shared_http_allowance_exhausted_without_reset"] = code == "episode_budget_exceeded"
                            && state.state == .budgetExceeded && state.charged.httpAttempts == 4
                            && state.limits.resources.httpAttempts == 4 && state.charged.modelCalls == 0
                    case .cancel:
                        checks[prefix + "_stop_while_count_waits_no_prepared_result"] = code == "cancelled" || code == "episode_inactive"
                        checks[prefix + "_performed_http_charges_retained"] = state.charged.httpAttempts >= 5
                            && state.charged.inputTokens > 0 && state.charged.modelCalls == 1 && state.charged.outputTokens == 1
                            && failureInventory.generativeTokenizerWork == 0
                    case .deadline:
                        checks[prefix + "_continuous_deadline_while_count_waits"] = code == "episode_deadline_exceeded"
                            && state.state == .deadlineExceeded
                        checks[prefix + "_deadline_keeps_prior_http_work"] = state.charged.httpAttempts >= 5
                            && state.charged.inputTokens > 0 && state.charged.modelCalls == 1 && state.charged.outputTokens == 1
                            && failureInventory.generativeTokenizerWork == 0
                    default: checks[prefix + "_successful_preparation"] = false
                    }
                    _ = try lease.finish(reason: kind == .cancel ? .cancelled : .failed)
                }
                let terminal = try store.episodeReceipt(id: lease.episodeID, clock: clock.now())
                let inventory = try journalInventory()
                let admitted: Bool
                if case .success = outcome { admitted = true } else { admitted = false }
                checks[prefix + "_terminal_journal_links_original_episode"] = terminal.state != .active && inventory.episodes == 1
                    && inventory.invocations == (admitted ? 1 : 0) && inventory.answerWork == (admitted ? 1 : 0)
            } catch {
                checks[prefix + "_completed_contract_checks"] = false
                checks[prefix + "_failed_at_" + failureStage + "_" + sanitizedFailure(error)] = false
            }
            operation = nil
            completion(checks)
        }
        private func sanitizedFailure(_ error: Error) -> String {
            if let error = error as? BackupError {
                switch error {
                case .invalid(let reason):
                    let known: Set<String> = ["SQLite integrity or foreign-key check failed", "admission or usage receipt digest mismatch",
                        "archive changed during restore", "archive contains missing or unlisted files",
                        "archive files must be private regular files without hard links", "archive metadata exceeds its size limit",
                        "archive must be a private real directory owned by this user", "copied database inventory mismatch",
                        "credential fields are excluded from archive configuration", "database inventory differs from manifest",
                        "database is not a standalone SQLite snapshot", "destination already exists",
                        "destination must be an absolute local path", "destination parent is missing or contains a symbolic link",
                        "destination path cannot contain dot components", "episode journal failed integrity verification",
                        "episode origin inventory mismatch", "file length or checksum mismatch", "invalid JSON metadata",
                        "invalid destination name", "invalid draft or stored setting", "invalid event scope or capture state",
                        "invalid invocation terminal state", "invalid loopback provider identity", "invalid native provider identity",
                        "invalid recovered cancellation state", "invalid recovered state", "invocation chunk failed integrity verification",
                        "invocation chunk manifest mismatch", "invocation lacks its matching human source", "invocation request digest mismatch",
                        "legacy restore introduced episode records", "local read episode cannot own an invocation",
                        "missing or malformed archive manifest", "noncontiguous or oversized invocation stream",
                        "online snapshot exceeded its deadline", "required regular file is missing or symbolic",
                        "restored episode recovery inventory mismatch", "restored exact read failed source checksum",
                        "restored exact read failed to advance", "restored exact-read metadata mismatch",
                        "restored startup recovery inventory mismatch", "source database has an unsupported schema",
                        "source payload failed digest, length or UTF-8 verification",
                        "source table, column, index or constraint contract is not a recognized Boros schema",
                        "table, column, index or constraint contract is not a recognized Boros schema",
                        "terminal invocation disagrees with assistant source", "unfinished invocation has a published result",
                        "unknown episode resource", "unsupported archive format, schema, or control metadata",
                        "unsupported database object inventory", "unsupported database schema", "unsupported historical schema",
                        "unsupported or duplicate file inventory", "unsupported table contract"]
                    return known.contains(reason) ? "backup_invalid_" + reason.replacingOccurrences(of: " ", with: "_") : "backup_invalid"
                case .io(let reason):
                    let known: Set<String> = ["archive copy read failed", "atomic publication refused an existing or invalid destination",
                        "cannot create private file", "cannot create private staging directory", "cannot create restored file",
                        "cannot inspect source item", "cannot open filesystem root", "cannot open staging directory for sync",
                        "destination parent changed", "file hash read failed", "file sync failed", "file write failed",
                        "file write made no progress", "metadata read failed", "restored file sync failed", "staging directory sync failed"]
                    return known.contains(reason) ? "backup_io_" + reason.replacingOccurrences(of: " ", with: "_") : "backup_io"
                case .database: return "backup_database"
                case .publicationDurabilityUnknown: return "backup_publication_durability_unknown"
                case .cancelled: return "backup_cancelled"
                case .authorityUnavailable: return "backup_authority_unavailable"
                }
            }
            if case MemoryError.database(let reason) = error {
                let journalReasons: Set<String> = ["proof binding mismatch", "source audit mismatch", "selection snapshot missing",
                    "selection work mismatch", "selection charge linkage mismatch", "selection provenance mismatch",
                    "selection work resource mismatch", "selection limits mismatch", "recent source mismatch",
                    "recent source bytes mismatch", "source metadata mismatch", "source metadata missing",
                    "accepted request mismatch", "accepted request missing", "evidence framing mismatch",
                    "historical source mismatch", "excerpt bytes missing", "excerpt digest mismatch",
                    "excerpt source range mismatch", "excerpt source range missing", "extra evidence bytes",
                    "provenance digest mismatch", "adapter binding mismatch", "count receipt mismatch",
                    "tokenizer work missing", "count work scope mismatch", "count precedes verification",
                    "count work resource mismatch", "counted text differs from dispatch", "count evidence missing",
                    "provider count evidence mismatch", "count work not unique", "component allowance mismatch",
                    "answer count linkage mismatch", "frozen policy lacks proof", "proof has no frozen policy",
                    "unsupported model observation", "model observation linkage mismatch"]
                let journalPrefix = "component journal "
                if reason.hasPrefix(journalPrefix) {
                    let suffix = String(reason.dropFirst(journalPrefix.count))
                    if journalReasons.contains(suffix) { return "component_journal_" + suffix.replacingOccurrences(of: " ", with: "_") }
                }
                let episodeReasons: Set<String> = ["duplicate episode archive receipt ID", "duplicate episode archive snapshots",
                    "episode archive HTTP attempt mismatch", "episode archive adapter violation flag missing",
                    "episode archive budget exceeded without adapter violation", "episode archive chat origin linkage failure",
                    "episode archive contains forbidden credential metadata", "episode archive integrity failure",
                    "episode archive invocation linkage mismatch", "episode archive lost armed charge",
                    "episode archive lost unknown output bound", "episode archive model call mismatch",
                    "episode archive origin integrity failure", "episode archive origin is not canonical",
                    "episode archive output settlement inconsistent", "episode archive parent scope mismatch",
                    "episode archive query failed", "episode archive read origin linkage failure",
                    "episode archive receipt exceeds bound", "episode archive receipt integrity failure",
                    "episode archive receipt linkage mismatch", "episode archive receipt transition mismatch",
                    "episode archive recovery state mismatch", "episode archive repeated unknown receipt",
                    "episode archive resource totals incomplete", "episode archive retrieval call mismatch",
                    "episode archive scope mismatch", "episode archive snapshot bound exceeded",
                    "episode archive snapshot integrity failure", "episode archive snapshot missing",
                    "episode archive terminal receipt missing", "episode archive terminal receipt replay mismatch",
                    "episode archive terminal state disagrees with receipt", "episode archive tokens lack model call",
                    "episode archive totals disagree with work", "episode archive unfinished work has terminal clock",
                    "episode archive unknown receipt has no new identity evidence", "episode archive work clock mismatch",
                    "episode archive work exceeds reservation", "episode archive work never armed",
                    "episode archive work row bound exceeded", "episode work archive integrity failure",
                    "invalid armed episode archive work", "invalid episode archive JSON", "invalid episode archive identifier",
                    "invalid episode archive lifecycle", "invalid episode archive metadata", "invalid episode archive metadata bounds",
                    "invalid episode archive schema", "invalid episode archive work linkage", "invalid prepared episode archive work",
                    "invalid unarmed terminal episode archive work", "local read episode archive contains generative work",
                    "unknown episode archive resource", "unsupported episode archive schema"]
                if episodeReasons.contains(reason) { return "episode_journal_" + reason.replacingOccurrences(of: " ", with: "_") }
                return "database"
            }
            if let error = error as? EpisodeBudgetError { return error.failureCode }
            if let error = error as? ProviderAdmissionError { return error.failureCode }
            return "contract_error"
        }
    }

    /// Each mutation starts from the coordinator's verified synthetic archive.
    /// Ordinary hashes are refreshed so these test the source/count bindings.
    private enum JournalCorruptionChecks {
        private enum Mutation: String, CaseIterable {
            case copiedHistoricalScope, copiedHistoricalOffset, copiedHistoricalHash
            case sourceSnapshotDigest, sourceSnapshotWorkLink, receiptModel, receiptEpisode
            case receiptModelIdentity, modelIdentityVersion, modelIdentityInstance, modelIdentityEpoch, modelIdentityExtraKey
            case fractionalOriginalClock, foreignOriginalClock, nonuniformOriginalClock
            case tokenizerSnapshot, tokenizerCountEvidence, tokenizerRenderedEvidence
            case policyExtraKey, policyChangedCap
            case reboundHistoricalScope, reboundHistoricalOffset, reboundHistoricalHash
            case reboundRecentRole, reboundRecentStatus, reboundRecentHash, originalSourceRange
        }
        private enum FixtureError: Error { case malformed, database }
        private enum Binding { case text(String), bytes(Data), integer(Int) }

        private final class Database {
            let handle: OpaquePointer
            init(_ url: URL) throws {
                var raw: OpaquePointer?
                guard sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let raw else {
                    if let raw { sqlite3_close(raw) }
                    throw FixtureError.database
                }
                handle = raw
            }
            deinit { sqlite3_close(handle) }
            private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
                var raw: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else { throw FixtureError.database }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (offset, binding) in bindings.enumerated() {
                    let index = Int32(offset + 1)
                    let code: Int32
                    switch binding {
                    case .text(let text):
                        code = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
                    case .bytes(let bytes):
                        code = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(bytes.count), transient) }
                    case .integer(let value): code = sqlite3_bind_int64(statement, index, Int64(value))
                    }
                    guard code == SQLITE_OK else { sqlite3_finalize(statement); throw FixtureError.database }
                }
                return statement
            }
            func bytes(_ sql: String, _ bindings: [Binding] = []) throws -> Data {
                let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw FixtureError.database }
                return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            }
            func execute(_ sql: String, _ bindings: [Binding]) throws {
                let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else { throw FixtureError.database }
            }
            func replaceSnapshot(workID: String, payload: Data) throws {
                let digest = ContextSnapshot.digest(payload)
                try execute("INSERT INTO episode_request_snapshots (digest,byte_count,payload) VALUES (?,?,?)",
                    [.text(digest), .integer(payload.count), .bytes(payload)])
                try execute("UPDATE episode_work SET snapshot_digest=? WHERE id=?", [.text(digest), .text(workID)])
            }
        }
        private static func object(_ bytes: Data) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw FixtureError.malformed }
            return value
        }
        private static func encoded(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        private static func string(_ value: Any?) throws -> String {
            guard let value = value as? String, !value.isEmpty else { throw FixtureError.malformed }
            return value
        }
        private static func withCopy<T>(archive: URL, directory: URL, _ body: (Database) throws -> T) throws -> T {
            let copied = directory.appendingPathComponent("corruption-" + UUID().uuidString + ".sqlite3")
            try FileManager.default.copyItem(at: archive.appendingPathComponent("memory.sqlite3"), to: copied)
            defer {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copied.path + suffix) }
            }
            return try body(Database(copied))
        }
        static func run(archive: URL, directory: URL) -> [String: Bool] {
            var checks: [String: Bool] = [:]
            let prefix = "component_preparation_journal_"
            do {
                try withCopy(archive: archive, directory: directory) { try MemoryStore.validateEpisodeJournal(database: $0.handle) }
                checks[prefix + "valid_coordinator_control"] = true
            } catch { checks[prefix + "valid_coordinator_control"] = false }
            for mutation in Mutation.allCases {
                do {
                    checks[prefix + mutation.rawValue + "_rejected"] = try withCopy(archive: archive, directory: directory) { database in
                        try MemoryStore.validateEpisodeJournal(database: database.handle)
                        try apply(mutation, database: database)
                        do { try MemoryStore.validateEpisodeJournal(database: database.handle); return false }
                        catch MemoryError.database(let reason) {
                            if mutation == .policyExtraKey || mutation == .policyChangedCap { return reason == "invalid episode archive metadata" }
                            return reason.hasPrefix("component journal ")
                        }
                    }
                } catch { checks[prefix + mutation.rawValue + "_rejected"] = false }
            }
            do {
                var oldLimits = try object(JSONEncoder().encode(EpisodeLimits()))
                oldLimits.removeValue(forKey: "componentPolicy")
                let decoded = try JSONDecoder().decode(EpisodeLimits.self, from: encoded(oldLimits))
                checks[prefix + "legacy_missing_policy_decodes_nil"] = decoded.componentPolicy == nil
                    && decoded.resources == EpisodeResources.developmentCaps
            } catch { checks[prefix + "legacy_missing_policy_decodes_nil"] = false }
            return checks
        }
        private static func apply(_ mutation: Mutation, database: Database) throws {
            var admission = try object(database.bytes("SELECT admission_json FROM invocations WHERE id='fixture-invocation'"))
            guard var receipt = admission["receipt"] as? [String: Any], var proof = receipt["componentProof"] as? [String: Any],
                  let contextData = Data(base64Encoded: try string(admission["context"])) else { throw FixtureError.malformed }
            var context = try object(contextData)
            let selectionWorkID = try string(context["selection_work_id"])
            guard let recentCount = proof["recent"] as? [String: Any] else { throw FixtureError.malformed }
            let tokenizerWorkID = try string(recentCount["tokenizerWorkID"])
            let zeroDigest = String(repeating: "0", count: 64)
            switch mutation {
            case .copiedHistoricalScope, .copiedHistoricalOffset, .copiedHistoricalHash:
                guard var historical = context["historical_sources"] as? [[String: Any]], !historical.isEmpty else { throw FixtureError.malformed }
                if mutation == .copiedHistoricalScope { historical[0]["project_id"] = "foreign-synthetic-project" }
                if mutation == .copiedHistoricalOffset { historical[0]["excerpt_offset"] = 1 }
                if mutation == .copiedHistoricalHash { historical[0]["source_sha256"] = zeroDigest }
                context["historical_sources"] = historical
            case .sourceSnapshotDigest:
                context["source_snapshot_sha256"] = zeroDigest; proof["sourceSnapshotDigest"] = zeroDigest
            case .sourceSnapshotWorkLink: context["selection_work_id"] = tokenizerWorkID
            case .receiptModel: receipt["modelID"] = "foreign-synthetic-model"
            case .receiptEpisode: receipt["episodeID"] = "foreign-synthetic-episode"
            case .receiptModelIdentity:
                guard var identity = receipt["modelIdentity"] as? [String: Any] else { throw FixtureError.malformed }
                identity["modelID"] = "foreign-synthetic-model"
                receipt["modelIdentity"] = identity
            case .modelIdentityVersion, .modelIdentityInstance, .modelIdentityEpoch, .modelIdentityExtraKey:
                guard var identity = proof["modelIdentity"] as? [String: Any] else { throw FixtureError.malformed }
                if mutation == .modelIdentityVersion { identity["version"] = "unsupported-synthetic-observation" }
                if mutation == .modelIdentityInstance { identity["instanceIdentity"] = "fabricated-load-generation" }
                if mutation == .modelIdentityExtraKey { identity["unexpectedInstanceEpoch"] = 1 }
                if mutation == .modelIdentityEpoch { proof["modelEpoch"] = 1; receipt["loadedModelEpoch"] = 1 }
                proof["modelIdentity"] = identity; receipt["modelIdentity"] = identity
            case .fractionalOriginalClock, .foreignOriginalClock, .nonuniformOriginalClock:
                for key in ["recent", "evidence", "wholePrompt"] {
                    guard var count = proof[key] as? [String: Any] else { throw FixtureError.malformed }
                    if mutation == .fractionalOriginalClock { count["verifiedNanoseconds"] = 1_000_000_000.5 }
                    if mutation == .foreignOriginalClock { count["clockDomain"] = "foreign-synthetic-clock" }
                    if mutation == .nonuniformOriginalClock && key == "recent" {
                        guard let ticks = count["verifiedNanoseconds"] as? NSNumber else { throw FixtureError.malformed }
                        count["verifiedNanoseconds"] = ticks.uint64Value - 1
                    }
                    proof[key] = count
                }
            case .tokenizerSnapshot:
                let payload = try database.bytes("SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(tokenizerWorkID)])
                var snapshot = try object(payload)
                snapshot["content"] = try string(snapshot["content"]) + " synthetic mutation"
                try database.replaceSnapshot(workID: tokenizerWorkID, payload: encoded(snapshot))
            case .tokenizerCountEvidence, .tokenizerRenderedEvidence:
                let chainBytes = try database.bytes("SELECT receipt_json FROM episode_work WHERE id=?", [.text(tokenizerWorkID)])
                guard var chain = try JSONSerialization.jsonObject(with: chainBytes) as? [[String: Any]],
                      var last = chain.last, let evidence = Data(base64Encoded: try string(last["evidence"])) else { throw FixtureError.malformed }
                var evidenceObject = try object(evidence)
                if mutation == .tokenizerCountEvidence {
                    guard let tokens = evidenceObject["token_count"] as? NSNumber else { throw FixtureError.malformed }
                    evidenceObject["token_count"] = tokens.intValue + 1
                } else { evidenceObject["rendered_sha256"] = zeroDigest }
                last["evidence"] = try encoded(evidenceObject).base64EncodedString()
                chain[chain.count - 1] = last
                let refreshed = try encoded(chain)
                try database.execute("UPDATE episode_work SET receipt_json=?,receipt_digest=? WHERE id=?",
                    [.bytes(refreshed), .text(ContextSnapshot.digest(refreshed)), .text(tokenizerWorkID)])
            case .policyExtraKey, .policyChangedCap:
                var limits = try object(database.bytes("SELECT limits_json FROM episodes"))
                guard var policy = limits["componentPolicy"] as? [String: Any] else { throw FixtureError.malformed }
                if mutation == .policyExtraKey { policy["unexpectedCap"] = 8000 }
                else { policy["recentTokens"] = 8001 }
                limits["componentPolicy"] = policy
                let refreshed = try encoded(limits)
                try database.execute("UPDATE episodes SET limits_json=?,limits_digest=?",
                    [.bytes(refreshed), .text(ContextSnapshot.digest(refreshed))])
            case .reboundHistoricalScope, .reboundHistoricalOffset, .reboundHistoricalHash,
                 .reboundRecentRole, .reboundRecentStatus, .reboundRecentHash:
                let payload = try database.bytes("SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(selectionWorkID)])
                var selection = try object(payload)
                switch mutation {
                case .reboundHistoricalScope, .reboundHistoricalOffset, .reboundHistoricalHash:
                    guard var sources = selection["historical_sources"] as? [[String: Any]], !sources.isEmpty else { throw FixtureError.malformed }
                    if mutation == .reboundHistoricalScope { sources[0]["project_id"] = "foreign-synthetic-project" }
                    if mutation == .reboundHistoricalOffset { sources[0]["excerpt_offset"] = 1 }
                    if mutation == .reboundHistoricalHash { sources[0]["source_sha256"] = zeroDigest }
                    selection["historical_sources"] = sources; context["historical_sources"] = sources
                default:
                    guard var sources = selection["recent_sources"] as? [[String: Any]], !sources.isEmpty else { throw FixtureError.malformed }
                    if mutation == .reboundRecentRole { sources[0]["role"] = "assistant" }
                    if mutation == .reboundRecentStatus { sources[0]["status"] = "partial" }
                    if mutation == .reboundRecentHash { sources[0]["digest"] = zeroDigest }
                    selection["recent_sources"] = sources
                }
                let refreshed = try encoded(selection), digest = ContextSnapshot.digest(refreshed)
                try database.replaceSnapshot(workID: selectionWorkID, payload: refreshed)
                context["source_snapshot_sha256"] = digest; proof["sourceSnapshotDigest"] = digest
            case .originalSourceRange:
                guard let sources = context["historical_sources"] as? [[String: Any]], let source = sources.first else { throw FixtureError.malformed }
                let id = try string(source["event_id"])
                var payload = try database.bytes("SELECT payload FROM events WHERE id=?", [.text(id)])
                guard !payload.isEmpty else { throw FixtureError.malformed }
                payload[0] = payload[0] == 113 ? 112 : 113
                try database.execute("UPDATE events SET payload=? WHERE id=?", [.bytes(payload), .text(id)])
            }
            // Keep both copies of the component proof identical. Ordinary
            // integrity hashes pass even when the semantic binding is corrupt.
            receipt["componentProof"] = proof; context["components"] = proof
            admission["receipt"] = receipt; admission["context"] = try encoded(context).base64EncodedString()
            let refreshed = try encoded(admission)
            try database.execute("UPDATE invocations SET admission_json=?,admission_digest=? WHERE id='fixture-invocation'",
                [.bytes(refreshed), .text(ContextSnapshot.digest(refreshed))])
        }
    }
}
