import Foundation
import CSQLite

enum EndpointChecks {
    static func runIntegration(baseURL: String) -> [String: Bool] {
        var checks = ProviderAdmissionChecks.runIntegration(baseURL: baseURL)
        for (index, mode) in ["good", "http-error", "sse-error", "unfinished", "length", "redirect", "malformed", "cancel", "usage-missing", "usage-mismatch", "stream-model-mismatch"].enumerated() {
            let runner = EndpointRunner()
            var settings = GenerationSettings()
            settings.profile = .customLocal
            settings.endpointURL = baseURL
            settings.endpointModel = Qwen38TextAdapter.modelID
            settings.seed = 100 + index
            settings.endpointAPIKey = "synthetic-key"
            settings.messagesOverride = [
                ["role": "system", "content": "Synthetic test instruction."],
                ["role": "user", "content": "Remember 17."],
                ["role": "assistant", "content": "Stored 17."],
                ["role": "user", "content": "What value?"],
            ]
            var answer = ""
            var result: GenerationResult?
            var completions = 0
            runner.start(prompt: "unused draft", settings: settings, conversation: Conversation(), onText: { chunk in
                answer += chunk
                if mode == "cancel" { runner.cancel() }
            }, onComplete: { value in result = value; completions += 1 })
            let deadline = Date().addingTimeInterval(8)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            if result == nil { runner.cancel() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            checks[mode + "_completes_once"] = completions == 1
            switch mode {
            case "good":
                checks["auth_and_full_role_history"] = result?.failure == nil && answer == "17日"
                checks["exact_admission_and_usage_carried"] = result?.providerAdmission?.promptTokens == result?.providerUsage?.promptTokens
                    && result?.providerUsage?.completionTokens == 2 && result?.providerUsage?.cachedTokens == 1
            case "http-error": checks["http_error_visible"] = result?.failure == "http_failed" && answer.isEmpty
            case "sse-error": checks["stream_error_visible"] = result?.failure == "process_failed"
            case "unfinished": checks["partial_eof_not_success"] = result?.failure == "invalid_stream" && answer == "partial"
            case "length": checks["truncated_output_not_success"] = result?.failure == "incomplete_result" && answer == "partial"
            case "redirect": checks["redirect_not_followed"] = result?.failure == "redirect_rejected"
            case "malformed": checks["malformed_stream_visible"] = result?.failure == "invalid_stream"
            case "cancel": checks["cancel_returns_partial_once"] = result?.stopped == true && answer == "partial"
            case "usage-missing", "usage-mismatch", "stream-model-mismatch":
                checks[mode + "_fails_explicit"] = result?.failure == "provider_count_mismatch" && answer == "17日"
            default: break
            }
        }
        checks.merge(runEpisodeIntegration(baseURL: baseURL)) { _, replacement in replacement }
        checks.merge(runRealStoreUnknownViolationChecks(baseURL: baseURL)) { _, replacement in replacement }
        return checks
    }

    private static func runEpisodeIntegration(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for (mode, seed) in [("good", 100), ("cancel", 107), ("usage-missing", 108), ("usage-mismatch", 109),
                             ("wrong-model", 110), ("no-output", 100), ("no-model", 100), ("stop-before-answer", 100),
                             ("prepared-good", 100), ("prepared-tamper", 100), ("wrong-model-no-usage", 111),
                             ("wrong-model-invalid-usage", 112), ("invalid-usage", 113), ("stop-after-answer-arm", 100)] {
            var limits = EpisodeLimits()
            if mode == "no-output" { limits.resources.outputTokens = 1 }
            if mode == "no-model" { limits.resources.modelCalls = 0 }
            let ledger = ProviderEpisodeFixtureLedger(limits: limits)
            ledger.stopBeforeAnswerHandoff = mode == "stop-before-answer"
            let lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
            if mode == "stop-after-answer-arm" { ledger.afterAnswerArm = { [weak lease] in _ = try? lease?.finish(reason: .cancelled) } }
            let runner = EndpointRunner()
            var settings = GenerationSettings(); settings.profile = .customLocal
            settings.endpointURL = baseURL; settings.endpointAPIKey = "synthetic-key"; settings.seed = seed
            settings.episodeLease = lease
            settings.messagesOverride = [["role": "system", "content": "Synthetic test instruction."],
                ["role": "user", "content": "Remember 17."], ["role": "assistant", "content": "Stored 17."],
                ["role": "user", "content": "What value?"]]
            if mode.hasPrefix("prepared-") {
                do {
                    let body = try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
                    var admissionResult: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                    let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: "synthetic-key",
                        contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { admissionResult = $0 }
                    let deadline = Date().addingTimeInterval(5)
                    while admissionResult == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                    guard case .success(let receipt) = admissionResult else {
                        operation.cancel(); checks[mode + "_fixture_admitted"] = false; continue
                    }
                    settings.preparedEndpointBody = body; settings.endpointAdmission = receipt
                    settings.preparedAnswerWork = try lease.prepare(kind: .answer,
                        resources: EpisodeResources(inputTokens: receipt.promptTokens, outputTokens: receipt.outputReserve, modelCalls: 1, httpAttempts: 1),
                        adapterIdentity: receipt.answerAdapterIdentity, snapshot: mode == "prepared-tamper" ? Data("{}".utf8) : body)
                } catch { checks[mode + "_fixture_reserved"] = false; continue }
            }
            var answer = "", completions = 0
            var result: GenerationResult?
            runner.start(prompt: "", settings: settings, conversation: Conversation(), onText: {
                answer += $0
                if mode == "cancel" { _ = try? lease.finish(reason: .cancelled); runner.cancel() }
            }, onComplete: { result = $0; completions += 1 })
            let deadline = Date().addingTimeInterval(5)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            if result == nil { runner.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            let records = ledger.records
            let answering = records.first { $0.request.kind == .answer }
            checks["answer_" + mode + "_episode_completes_once"] = completions == 1
            switch mode {
            case "good", "prepared-good":
                checks["answer_" + mode + "_valid_usage_settles_exact_known_input_and_output"] = result?.failure == nil && answer == "17日"
                    && answering?.observed?.inputTokens == result?.providerAdmission?.promptTokens
                    && answering?.observed?.outputTokens == 2 && answering?.observed?.modelCalls == 1
                    && answering?.observed?.httpAttempts == 1 && answering?.held == .zero
            case "cancel", "usage-missing":
                checks["answer_" + mode + "_unknown_output_reservation_retained"] = answering?.state == .outcomeUnknown
                    && answering?.observed == nil && answering?.held.outputTokens == settings.maximumOutput
                    && answering?.charged.modelCalls == 1
                checks["answer_" + mode + "_terminal_result"] = mode == "cancel" ? result?.stopped == true : result?.failure == "provider_count_mismatch"
            case "usage-mismatch", "wrong-model":
                checks["answer_" + mode + "_receipt_persisted_before_adapter_failure"] = result?.failure == "episode_adapter_violation"
                    && answering?.observed != nil && answering?.state == .completed
            case "wrong-model-no-usage", "wrong-model-invalid-usage", "invalid-usage":
                checks["answer_" + mode + "_unknown_receipt_quarantines_adapter"] = result?.failure == "episode_adapter_violation"
                    && answering?.observed == nil && answering?.state == .outcomeUnknown
                    && answering?.held.outputTokens == settings.maximumOutput && answering?.charged.modelCalls == 1
            case "no-model", "no-output":
                checks["answer_" + mode + "_denied_before_inference"] = result?.failure == "episode_budget_exceeded"
                    && answer.isEmpty && answering == nil
            case "stop-before-answer":
                checks["answer_stop_fences_prepared_handoff"] = result?.failure == "episode_inactive"
                    && answer.isEmpty && answering?.state == .cancelledBeforeDispatch
            case "stop-after-answer-arm":
                checks["answer_armed_suppressed_handoff_retains_bound_and_stop_failure"] = result?.failure == "episode_inactive"
                    && answer.isEmpty && answering?.state == .outcomeUnknown && answering?.observed == nil
                    && answering?.held.outputTokens == settings.maximumOutput && answering?.charged.modelCalls == 1
            case "prepared-tamper":
                checks["answer_prepared_snapshot_conflict_denies_handoff"] = result?.failure == "episode_accounting_failed"
                    && answer.isEmpty && answering?.state == .prepared
            default: break
            }
            checks["answer_" + mode + "_request_snapshot_exact_and_credential_free"] = mode == "prepared-tamper" || (answering.map {
                $0.request.snapshot.map { data in
                    data == (try? EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation()))
                        && !String(decoding: data, as: UTF8.self).contains("synthetic-key")
                } ?? false
            } ?? ["no-model", "no-output"].contains(mode))
        }
        return checks
    }

    private static func runRealStoreUnknownViolationChecks(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for (mode, seed) in [("wrong-model-no-usage", 111), ("wrong-model-invalid-usage", 112), ("invalid-usage", 113),
                             ("late-wrong-model", 107)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-provider-quarantine-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let store = try MemoryStore(directory: directory)
                let conversation = try store.createConversation(projectID: "synthetic-provider", title: "Synthetic provider identity")
                let episodeID = UUID().uuidString
                let clock = SystemEpisodeClock()
                _ = try store.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: UUID().uuidString,
                    humanEventID: UUID().uuidString, episodeID: episodeID, text: "What value?", limits: EpisodeLimits(), clock: clock.now())
                let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
                var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
                settings.endpointAPIKey = "synthetic-key"; settings.seed = seed; settings.episodeLease = lease
                settings.messagesOverride = [["role": "system", "content": "Synthetic test instruction."],
                    ["role": "user", "content": "Remember 17."], ["role": "assistant", "content": "Stored 17."],
                    ["role": "user", "content": "What value?"]]
                let body = try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
                var admissionResult: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: "synthetic-key",
                    contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { admissionResult = $0 }
                let admissionDeadline = Date().addingTimeInterval(5)
                while admissionResult == nil && Date() < admissionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                guard case .success(let admission) = admissionResult else {
                    operation.cancel(); checks[mode + "_real_store_admission"] = false; continue
                }
                let work = try lease.prepare(kind: .answer,
                    resources: EpisodeResources(inputTokens: admission.promptTokens, outputTokens: admission.outputReserve, modelCalls: 1, httpAttempts: 1),
                    adapterIdentity: admission.answerAdapterIdentity, snapshot: body)
                settings.preparedEndpointBody = body; settings.endpointAdmission = admission; settings.preparedAnswerWork = work
                let runner = EndpointRunner()
                var result: GenerationResult?, completions = 0
                runner.start(prompt: "", settings: settings, conversation: Conversation(), onText: { _ in
                    if mode == "late-wrong-model" { _ = try? lease.finish(reason: .cancelled); runner.cancel() }
                }, onComplete: {
                    result = $0; completions += 1
                })
                let generationDeadline = Date().addingTimeInterval(5)
                while result == nil && Date() < generationDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                if result == nil { runner.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                let recorded = try store.episodeWork(episodeID: episodeID, operationID: work.id)
                let terminal = try store.episodeReceipt(id: episodeID, clock: clock.now())
                checks[mode + "_real_store_unknown_bound_and_failure"] = completions == 1
                    && (mode == "late-wrong-model" ? result?.stopped == true : result?.failure == "episode_adapter_violation")
                    && recorded?.state == .outcomeUnknown && recorded?.observed == nil
                    && recorded?.held.outputTokens == settings.maximumOutput && recorded?.charged.modelCalls == 1
                    && terminal.state == (mode == "late-wrong-model" ? .cancelled : .failed)
                if mode == "late-wrong-model" {
                    // Deterministically deliver already-received delegate bytes
                    // after the real streaming Stop. No new task is resumed.
                    let lateSession = URLSession(configuration: .ephemeral)
                    defer { lateSession.invalidateAndCancel() }
                    let unusedTask = lateSession.dataTask(with: LocalEndpoint.chatURL(baseURL)!)
                    let proof = "data: {\"model\":\"wrong-model\",\"choices\":[]}\n\n"
                    runner.urlSession(lateSession, dataTask: unusedTask, didReceive: Data(proof.utf8))
                    let proofDeadline = Date().addingTimeInterval(5)
                    while (try? violationEvidenceIsPrivate(directory: directory, workID: work.id)) != true && Date() < proofDeadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                    }
                    let lateUnknown = try store.episodeWork(episodeID: episodeID, operationID: work.id)
                    checks["late_identity_proof_retains_unknown_usage_and_full_output_hold"] = lateUnknown?.state == .outcomeUnknown
                        && lateUnknown?.observed == nil && lateUnknown?.held.outputTokens == settings.maximumOutput
                    let usage: [String: Any] = ["model": Qwen38TextAdapter.modelID, "choices": [],
                        "usage": ["prompt_tokens": admission.promptTokens, "completion_tokens": 2, "total_tokens": admission.promptTokens + 2]]
                    var bytes = Data("data: ".utf8); bytes.append(try JSONSerialization.data(withJSONObject: usage)); bytes.append(Data("\n\n".utf8))
                    runner.urlSession(lateSession, dataTask: unusedTask, didReceive: bytes)
                    let usageDeadline = Date().addingTimeInterval(5)
                    while (try store.episodeWork(episodeID: episodeID, operationID: work.id))?.state != .completed && Date() < usageDeadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                    }
                    let lateUsage = try store.episodeWork(episodeID: episodeID, operationID: work.id)
                    let receipts = try storedSettlementReceipts(directory: directory, workID: work.id).receipts
                    checks["late_identity_then_authoritative_usage_preserves_three_receipts"] = receipts.count == 3
                        && receipts[0].outcome == .outcomeUnknown && !receipts[0].adapterViolation && receipts[0].observed == nil
                        && receipts[1].outcome == .outcomeUnknown && receipts[1].adapterViolation && receipts[1].observed == nil
                        && receipts[2].outcome == .completed && receipts[2].adapterViolation
                        && lateUsage?.observed?.outputTokens == 2 && lateUsage?.held.outputTokens == 0
                    checks["late_identity_receipts_leave_episode_cancelled"] = try store.episodeReceipt(id: episodeID, clock: clock.now()).state == .cancelled
                }
                checks[mode + "_real_store_private_violation_evidence"] = try violationEvidenceIsPrivate(directory: directory, workID: work.id)
                let nextID = UUID().uuidString
                _ = try store.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: UUID().uuidString,
                    humanEventID: UUID().uuidString, episodeID: nextID, text: "Different synthetic request.", limits: EpisodeLimits(), clock: clock.now())
                let nextLease = EpisodeLease(ledger: store, episodeID: nextID, clock: clock)
                var changed = settings; changed.messagesOverride = [["role": "user", "content": "Different synthetic request."]]
                let changedBody = try EndpointRequest.build(prompt: "", settings: changed, conversation: Conversation())
                var denied = false
                do {
                    _ = try nextLease.prepare(kind: .answer,
                        resources: EpisodeResources(inputTokens: admission.promptTokens, outputTokens: admission.outputReserve, modelCalls: 1, httpAttempts: 1),
                        adapterIdentity: admission.answerAdapterIdentity, snapshot: changedBody)
                } catch EpisodeBudgetError.adapterViolation { denied = true }
                let next = try store.episodeReceipt(id: nextID, clock: clock.now())
                checks[mode + "_real_store_changed_prompt_adapter_stays_quarantined"] = denied && changedBody != body
                    && next.charged.modelCalls == 0 && next.held.modelCalls == 0
            } catch { checks[mode + "_real_store_fixture_completed"] = false }
        }
        return checks
    }

    private static func violationEvidenceIsPrivate(directory: URL, workID: String) throws -> Bool {
        let stored = try storedSettlementReceipts(directory: directory, workID: workID)
        guard stored.violation,
              let receipt = stored.receipts.first(where: { $0.adapterViolation && $0.observed == nil }), let evidence = receipt.evidence,
              let object = try JSONSerialization.jsonObject(with: evidence) as? [String: Any] else { return false }
        return object["usage_observed"] as? Bool == false
            && (object["model_identity_mismatch"] as? Bool == true || object["protocol_count_mismatch"] as? Bool == true)
            && !String(decoding: evidence, as: UTF8.self).contains("synthetic-key")
    }

    static func storedSettlementReceipts(directory: URL, workID: String) throws -> (violation: Bool, receipts: [EpisodeWorkSettlement]) {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw EpisodeBudgetError.invalid }
        defer { sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, "SELECT adapter_violation,receipt_json FROM episode_work WHERE id=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw EpisodeBudgetError.invalid }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, workID, -1, transient) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return (false, []) }
        let violation = sqlite3_column_int(statement, 0) == 1
        let count = Int(sqlite3_column_bytes(statement, 1))
        guard count > 0, let pointer = sqlite3_column_blob(statement, 1) else { return (violation, []) }
        let data = Data(bytes: pointer, count: count)
        let receipts = try JSONDecoder().decode([EpisodeWorkSettlement].self, from: data)
        return (violation, receipts)
    }

    static func run() -> [String: Bool] {
        var checks = ProviderAdmissionChecks.run()
        checks["local_custom_port_base"] = LocalEndpoint.chatURL("http://localhost:11234/v1/")?.path == "/v1/chat/completions"
        checks["local_ipv6"] = LocalEndpoint.chatURL("http://[::1]:11234/v1") != nil
        checks["full_endpoint_accepted"] = LocalEndpoint.chatURL("http://127.0.0.1:11234/v1/chat/completions") != nil
        checks["remote_destination_rejected"] = LocalEndpoint.chatURL("https://example.com/v1") == nil
        checks["userinfo_rejected"] = LocalEndpoint.chatURL("http://key@localhost:11234/v1") == nil
        checks["query_secret_rejected"] = LocalEndpoint.chatURL("http://localhost:11234/v1?key=test") == nil
        checks["misleading_host_rejected"] = LocalEndpoint.chatURL("http://localhost.example.com/v1") == nil

        let event = "data: {\"choices\":[{\"delta\":{\"content\":\"日\"},\"finish_reason\":null}]}\r\n\r\n"
        var decoder = EndpointEventDecoder()
        var decoded: [String] = []
        for byte in Data(event.utf8) { decoded += decoder.consume(Data([byte])) }
        var state = EndpointResponseState()
        let text = decoded.compactMap { state.consume($0) }.joined()
        checks["fragmented_utf8_crlf"] = text == "日" && !decoder.failed && !decoder.hasUnfinishedEvent
        checks["eof_without_terminal_rejected"] = state.completedFailure == "invalid_stream"
        _ = state.consume("{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        checks["explicit_finish_accepts_eof"] = state.completedFailure == nil
        _ = state.consume("[DONE]")
        checks["done_marks_terminal"] = state.done && state.completedFailure == nil

        var reasoning = EndpointResponseState()
        let reasoningChunk = reasoning.consume("{\"choices\":[{\"delta\":{\"reasoning_content\":\"synthetic hidden reasoning\"},\"finish_reason\":null}]}")
        _ = reasoning.consume("[DONE]")
        checks["reasoning_is_not_visible_answer"] = reasoningChunk == nil && reasoning.completedFailure == "empty_result"
        var length = EndpointResponseState()
        _ = length.consume("{\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}")
        _ = length.consume("[DONE]")
        checks["length_is_incomplete"] = length.completedFailure == "incomplete_result"
        var malformed = EndpointResponseState()
        _ = malformed.consume("not json")
        checks["malformed_json_fails"] = malformed.failure == "invalid_stream"
        var error = EndpointResponseState()
        _ = error.consume("{\"error\":{\"message\":\"synthetic\"}}")
        checks["error_event_fails"] = error.failure != nil
        var tool = EndpointResponseState()
        _ = tool.consume("{\"choices\":[{\"delta\":{\"tool_calls\":[{}]},\"finish_reason\":null}]}")
        checks["tool_execution_unavailable"] = tool.failure != nil
        var invalidUTF8 = EndpointEventDecoder()
        _ = invalidUTF8.consume(Data([100, 97, 116, 97, 58, 32, 255, 10, 10]))
        checks["invalid_utf8_fails"] = invalidUTF8.failed
        var oversized = EndpointEventDecoder()
        _ = oversized.consume(Data(repeating: 65, count: 1_048_577))
        checks["unbounded_event_rejected"] = oversized.failed
        var multiline = EndpointEventDecoder()
        let multi = multiline.consume(Data("data: first\ndata: second\n\n".utf8))
        checks["multiline_sse_data"] = multi == ["first\nsecond"]
        return checks
    }
}
