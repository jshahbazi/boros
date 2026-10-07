import Foundation
import Darwin
import CSQLite

/// Actual native coordinator, counted HTTP stages and final capture against a
/// synthetic loopback fixture. All payloads are fixed public test data.
enum NativeInvestigationChecks {
    static func run(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        Suite(baseURL: baseURL, completion: completion).next()
    }

    private enum Case: String, CaseIterable {
        case success, pinRelease = "pin_release", defaultOff = "default_off", cancelPlanner = "cancel_planner", deadlinePlanner = "deadline_planner"
        case initialQueryReformulation = "initial_query_reformulation"
        case malformedPlan = "malformed_plan", invalidQuote = "invalid_quote", privateUsageMissing = "private_usage_missing"
        var interrupted: Bool { self == .cancelPlanner || self == .deadlinePlanner }
        var answers: Bool { [.success, .pinRelease, .initialQueryReformulation, .defaultOff].contains(self) }
    }
    private final class Clock: EpisodeClockSource {
        private let lock = NSLock()
        private var ticks: UInt64 = 1_000_000_000
        func expire() { lock.lock(); ticks = 400_000_000_000; lock.unlock() }
        func now() throws -> EpisodeClockSnapshot {
            lock.lock(); defer { lock.unlock() }
            return EpisodeClockSnapshot(domain: "synthetic-native-investigation-v1", continuousNanoseconds: ticks,
                utc: Date(timeIntervalSince1970: 1_770_000_000))
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
                let attempt = try Attempt(kind: kind, baseURL: baseURL) { [self] values in
                    checks.merge(values) { _, new in new }; current = nil; next()
                }
                current = attempt; attempt.start()
            } catch {
                checks["native_investigation_\(kind.rawValue)_fixture_created"] = false; next()
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
        let completion: ([String: Bool]) -> Void
        let prompt: String
        let correctedHuman = "navigationCompass replace Oslo with Lisbon."
        let correctedAssistant = "navigationCompass corrected route: Lisbon."
        var settings = GenerationSettings()
        var coordinator: AnswerAttemptCoordinator?
        var checks: [String: Bool] = [:]
        var response = ""
        var deliveries = 0
        var completions = 0
        var finished = false
        var fixtureReleaseSent = false
        var runner = ModelRunner()

        init(kind: Case, baseURL: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.baseURL = baseURL; self.completion = completion
            prompt = kind == .initialQueryReformulation
                ? (0..<257).map { "syntheticqueryterm\($0)" }.joined(separator: " ")
                : "What place was selected last?"
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw MemoryError.database("synthetic temporary directory unavailable")
            }
            let path = String(cString: resolved); free(resolved)
            directory = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("boros-native-investigation-" + UUID().uuidString, isDirectory: true)
            store = try MemoryStore(directory: directory)
            let old = try store.createConversation(projectID: "synthetic-native-investigation", title: "Synthetic earlier route")
            let correction = try store.createConversation(projectID: old.projectID, title: "Synthetic route correction")
            chat = try store.createConversation(projectID: old.projectID, title: "Synthetic active chat")
            func dated(_ literal: String) throws -> EventSourceTime {
                let normalized = try EventSourceTime.normalize(literal)
                return EventSourceTime(value: normalized.value, precision: normalized.precision,
                    timezone: normalized.timezone, sourceSHA256: EndpointRequest.digest(Data("public synthetic calendar".utf8)),
                    locator: "/synthetic/date", originalValue: literal)
            }
            _ = try store.append(conversationID: old.id, role: .human, text: "navigationCompass dispatch token: Oslo.",
                status: .complete, turnID: "native-original-old-turn", eventID: "native-original-old-human", sourceTime: dated("2026-09-29"))
            _ = try store.append(conversationID: old.id, role: .assistant, text: "navigationCompass acknowledgement: Oslo.",
                status: .complete, turnID: "native-original-old-turn", eventID: "native-original-old-assistant", sourceTime: dated("2026-09-29"))
            _ = try store.append(conversationID: correction.id, role: .human, text: correctedHuman,
                status: .complete, turnID: "native-original-correction-turn", eventID: "native-original-correction-human", sourceTime: dated("2026-10-01"))
            _ = try store.append(conversationID: correction.id, role: .assistant, text: correctedAssistant,
                status: .complete, turnID: "native-original-correction-turn", eventID: "native-original-correction-assistant", sourceTime: dated("2026-10-01"))
            _ = try store.append(conversationID: chat.id, role: .human, text: "Public synthetic continuity.",
                status: .complete, turnID: "native-original-prior-turn", eventID: "native-original-prior-human")
            if kind == .pinRelease {
                for index in 0..<8 {
                    let filler = try store.createConversation(projectID: chat.projectID, title: "Synthetic navigation filler")
                    _ = try store.append(conversationID: filler.id, role: .human,
                        text: "place filler channel \(index).", status: .complete,
                        turnID: "native-original-filler-\(index)", eventID: "native-original-filler-human-\(index)")
                    _ = try store.append(conversationID: filler.id, role: .assistant,
                        text: "place filler acknowledgement \(index).", status: .complete,
                        turnID: "native-original-filler-\(index)", eventID: "native-original-filler-assistant-\(index)")
                }
            }
            settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.endpointModel = Qwen38TextAdapter.modelID
            settings.endpointAPIKey = "synthetic-native-" + kind.rawValue
            settings.system = "Use the original public synthetic history and cite its sources."
            settings.maximumOutput = 256; settings.temperature = 0
            settings.investigateMemory = kind != .defaultOff
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var prefix: String { "native_investigation_" + kind.rawValue + "_" }

        func start() {
            let operation = AnswerAttemptCoordinator(store: store, conversationID: chat.id,
                projectID: chat.projectID, prompt: prompt, settings: settings, clock: clock, runner: runner,
                onText: { [self] chunk in
                    deliveries += 1; response += chunk
                    let invocation = try? store.invocation(id: coordinator!.identifiers.invocationID)
                    checks[prefix + "durable_capture_precedes_visible_delta"] = invocation?.chunkCount == deliveries
                        && invocation?.observedBytes == response.utf8.count
                    checks[prefix + "private_output_never_visible"] = !response.contains("\"action\"")
                        && !response.contains("Synthetic private claim") && !response.contains("\"facts\"")
                }, onComplete: { [self] report, answer in finish(report, answer: answer) })
            coordinator = operation
            do {
                let accepted = try operation.accept()
                checks[prefix + "one_accepted_original_episode"] = accepted.id == operation.identifiers.episodeID
                    && accepted.humanEventID == operation.identifiers.humanEventID
                if kind != .defaultOff {
                    checks[prefix + "investigation_limits_frozen_before_work"] = accepted.limits.deadlineMilliseconds == 300_000
                        && accepted.limits.resources.modelCalls >= 18 && accepted.limits.resources.httpAttempts >= 128
                        && accepted.limits.resources.memoryOperations >= 256 && accepted.limits.resources.outputTokens >= 16_384
                }
                try operation.start()
                if kind.interrupted { waitForPrivateDispatch() }
            } catch {
                checks[prefix + "accepted_and_started"] = false
                operation.cancel()
                if completions == 0 { finished = true; completion(checks) }
            }
        }

        private func controlURL(_ route: String) -> URL? {
            guard let base = LocalEndpoint.chatURL(baseURL), var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
            parts.path = route; parts.queryItems = [URLQueryItem(name: "mode", value: kind.rawValue)]
            return parts.url
        }
        private func waitForPrivateDispatch() {
            guard let url = controlURL("/native-fixture-wait") else { checks[prefix + "private_barrier_reached"] = false; coordinator?.cancel(); return }
            URLSession.shared.dataTask(with: url) { [self] data, _, _ in
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async { [self] in
                    checks[prefix + "private_barrier_reached"] = object?["ready"] as? Bool == true
                    if kind == .deadlinePlanner { clock.expire() }
                    else { coordinator?.cancel() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in releaseFixture() }
                }
            }.resume()
        }
        private func releaseFixture() {
            guard !fixtureReleaseSent, let url = controlURL("/native-fixture-release") else { return }
            fixtureReleaseSent = true
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }

        private func finish(_ report: AnswerAttemptCompletion, answer: String) {
            completions += 1
            guard !finished else { return }
            finished = true
            if kind.interrupted { releaseFixture() }
            checks[prefix + "completion_on_main_queue"] = AnswerAttemptCoordinator.isOnMainQueue
            checks[prefix + "visible_text_equals_durable_completion"] = answer == response
                && report.responseBytes == response.utf8.count && report.responseDigest == EndpointRequest.digest(Data(response.utf8))
            checks[prefix + "accounting_terminal_on_original_episode"] = report.accountingHealthy
                && report.episode?.id == coordinator?.identifiers.episodeID && report.episode?.state != .active
            if kind.answers && report.generation.failure != nil {
                let knownFailures = ["context_preparation_failed", "context_full", "provider_count_mismatch",
                    "episode_adapter_violation", "episode_budget_exceeded", "episode_deadline_exceeded",
                    "episode_accounting_failed", "provider_adapter_unverified", "provider_admission_unavailable",
                    "http_failed", "invalid_stream", "process_failed", "capture_failure", "episode_inactive"]
                let code = knownFailures.contains(report.generation.failure!) ? report.generation.failure! : "other_fixed_failure"
                checks[prefix + "unexpected_failure_" + code] = false
            }
            if kind.answers, let state = report.episode?.state, state != .completed {
                checks[prefix + "unexpected_terminal_" + state.rawValue] = false
            }
            if kind == .deadlinePlanner, report.generation.failure != "episode_deadline_exceeded" {
                let known = ["episode_inactive", "provider_count_mismatch", "context_preparation_failed",
                    "episode_adapter_violation", "provider_adapter_unverified", "http_failed"]
                let code = report.generation.failure.flatMap { known.contains($0) ? $0 : nil } ?? "other_fixed_failure"
                checks[prefix + "unexpected_deadline_failure_" + code] = false
            }
            do {
                let counts = try inventory()
                checks[prefix + "only_original_episode_exists"] = counts["episodes"] == 1 && counts["work_episodes"] == 1
                let events = try store.events(conversationID: chat.id)
                checks[prefix + "accepted_question_preserved_exactly"] = events.contains {
                    $0.id == report.identifiers.humanEventID && $0.text == prompt && $0.status == .complete
                }
                let invocation = try store.invocation(id: report.identifiers.invocationID)
                if kind.answers {
                    checks[prefix + "one_visible_final_invocation"] = counts["invocations"] == 1 && report.invocationStarted
                        && invocation?.episodeID == report.identifiers.episodeID
                    checks[prefix + "final_success_and_usage_settlement"] = report.episode?.state == .completed
                        && report.captureStatus == .complete && report.generation.failure == nil
                        && report.episode?.held.outputTokens == 0 && report.generation.providerUsage?.completionTokens == 2
                    checks[prefix + "only_final_response_delivered"] = answer == "Synthetic final Lisbon [native-original-correction-assistant]."
                        && deliveries == 1 && events.filter { $0.role == .assistant }.count == 1
                    if let preparation = report.preparation, let invocation,
                       let object = try JSONSerialization.jsonObject(with: invocation.requestBody) as? [String: Any],
                       let messages = object["messages"] as? [[String: String]],
                       let auditData = invocation.admissionJSON,
                       let audit = try JSONSerialization.jsonObject(with: auditData) as? [String: Any] {
                        checks[prefix + "final_original_prompt_and_count_proof"] = messages.last?["content"] == prompt
                            && invocation.requestDigest == preparation.requestDigest
                            && invocation.episodeWorkID == preparation.answerWorkID && preparation.admission.componentProof != nil
                            && audit["version"] as? Int == 3 && audit["inputProofWorkID"] as? String != nil
                        checks[prefix + "derived_notes_do_not_become_final_input"] = !messages.contains {
                            $0["content"]?.contains("Synthetic private claim") == true
                                || isPrivateStageText($0["content"] ?? "")
                        }
                        if kind != .defaultOff {
                            checks[prefix + "private_stages_accounted_on_same_lease"] = (counts["private_answers"] ?? 0) >= 2
                                && counts["answers"] == (counts["private_answers"] ?? 0) + 1
                                && (counts["calibrations"] ?? 0) >= (counts["answers"] ?? 0)
                            checks[prefix + "private_stage_sources_are_opaque"] = counts["private_bodies_with_original_ids"] == 0
                            checks[prefix + "private_extraction_output_retained"] = (counts["private_extraction_snapshots"] ?? 0) >= 1
                            let evidence = messages.compactMap { $0["content"] }.joined(separator: "\n")
                            checks[prefix + "complete_correcting_exchange_in_final_originals"] = evidence.contains(correctedHuman)
                                && evidence.contains(correctedAssistant)
                            checks[prefix + "original_calendar_evidence_retained"] = evidence.contains("2026-10-01")
                            if kind == .pinRelease {
                                checks[prefix + "released_pins_allow_repeated_search"] = (counts["private_answers"] ?? 0) >= 4
                            }
                            if kind == .initialQueryReformulation {
                                checks[prefix + "planner_reformulates_query_outside_initial_search_contract"] = (counts["private_answers"] ?? 0) >= 3
                            }
                        } else { checks[prefix + "default_off_uses_one_pass"] = counts["private_answers"] == 0 && counts["answers"] == 1 }
                        try verifyBackup(report: report, invocation: invocation)
                    } else { checks[prefix + "final_original_prompt_and_count_proof"] = false }
                } else {
                    checks[prefix + "no_visible_invocation_or_delta"] = counts["invocations"] == 0 && !report.invocationStarted
                        && invocation == nil && deliveries == 0 && answer.isEmpty
                    checks[prefix + "private_stage_was_dispatched"] = (counts["private_answers"] ?? 0) >= 1
                    checks[prefix + "no_final_answer_work"] = counts["answers"] == counts["private_answers"]
                    if kind == .cancelPlanner || kind == .deadlinePlanner {
                        checks[prefix + "original_unknown_output_hold_retained"] = (report.episode?.held.outputTokens ?? 0) >= 1024
                            && (counts["unknown_answers"] ?? 0) >= 1
                        checks[prefix + "requested_terminal_fence_retained"] = report.episode?.state == (kind == .cancelPlanner ? .cancelled : .deadlineExceeded)
                    } else {
                        checks[prefix + "invalid_or_unobserved_private_stage_fails"] = report.episode?.state == .failed
                            && report.generation.failure != nil
                    }
                    if kind == .privateUsageMissing {
                        checks[prefix + "missing_private_usage_remains_unknown"] = (report.episode?.held.outputTokens ?? 0) >= 1024
                            && (counts["unknown_answers"] ?? 0) >= 1
                    }
                }
            } catch { checks[prefix + "durable_inventory_and_backup_validated"] = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                checks[prefix + "completion_once_and_late_output_suppressed"] = completions == 1
                    && (kind.answers ? deliveries == 1 : deliveries == 0)
                checks[prefix + "owned_final_runner_drained"] = !runner.isRunning
                completion(checks)
            }
        }

        private func isPrivateStageText(_ value: String) -> Bool {
            value.contains("BOROS MEMORY PLANNER") || value.contains("BOROS MEMORY EXTRACTION")
        }
        private func verifyBackup(report: AnswerAttemptCompletion, invocation: StoredInvocation) throws {
            let archive = directory.appendingPathComponent("synthetic-archive")
            let restoredDirectory = directory.appendingPathComponent("synthetic-restored")
            _ = try BackupArchive.create(from: store, at: archive)
            _ = try BackupArchive.verify(at: archive)
            _ = try BackupArchive.restore(from: archive, to: restoredDirectory, authority: .unmanagedNoDeletion)
            let restored = try MemoryStore(directory: restoredDirectory)
            let reopened = try restored.invocation(id: report.identifiers.invocationID)
            let receipt = try restored.episodeReceipt(id: report.identifiers.episodeID, clock: clock.now())
            checks[prefix + "backup_restore_preserves_body_proof_and_charges"] = reopened?.requestBody == invocation.requestBody
                && reopened?.admissionJSON == invocation.admissionJSON && receipt.charged == report.episode?.charged
                && receipt.held == report.episode?.held
            checks[prefix + "backup_restore_preserves_complete_originals"] = try restored.events(conversationID: chat.id)
                .contains { $0.id == report.identifiers.humanEventID && $0.text == prompt }
        }
        private func inventory() throws -> [String: Int] {
            var raw: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database = raw else { if let raw { sqlite3_close(raw) }; throw MemoryError.database("synthetic inventory unavailable") }
            defer { sqlite3_close(database) }
            let queries: [String: String] = [
                "episodes": "SELECT count(*) FROM episodes",
                "work_episodes": "SELECT count(DISTINCT episode_id) FROM episode_work",
                "invocations": "SELECT count(*) FROM invocations",
                "answers": "SELECT count(*) FROM episode_work WHERE kind='answer'",
                "calibrations": "SELECT count(*) FROM episode_work WHERE kind='calibration'",
                "unknown_answers": "SELECT count(*) FROM episode_work WHERE kind='answer' AND state='outcomeUnknown'",
                "private_answers": "SELECT count(*) FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.kind='answer' AND (CAST(s.payload AS TEXT) LIKE '%BOROS MEMORY PLANNER%' OR CAST(s.payload AS TEXT) LIKE '%BOROS MEMORY EXTRACTION%')",
                "private_bodies_with_original_ids": "SELECT count(*) FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.kind='answer' AND (CAST(s.payload AS TEXT) LIKE '%BOROS MEMORY PLANNER%' OR CAST(s.payload AS TEXT) LIKE '%BOROS MEMORY EXTRACTION%') AND CAST(s.payload AS TEXT) LIKE '%native-original-%'",
                "private_extraction_snapshots": "SELECT count(*) FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.kind='retrieval' AND CAST(s.payload AS TEXT) LIKE '%Synthetic private claim navigationCompass destination is Lisbon.%'",
            ]
            var values: [String: Int] = [:]
            for (key, sql) in queries {
                var rawStatement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &rawStatement, nil) == SQLITE_OK, let statement = rawStatement else {
                    throw MemoryError.database("synthetic inventory query unavailable")
                }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("synthetic inventory query failed") }
                values[key] = Int(sqlite3_column_int64(statement, 0))
            }
            return values
        }
    }
}
