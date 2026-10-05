import Foundation
import CSQLite

enum ProviderAdmissionChecks {
    static func runIntegration(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var settings = GenerationSettings(); settings.profile = .customLocal
        settings.endpointURL = baseURL; settings.endpointAPIKey = "synthetic-key"
        settings.messagesOverride = [["role": "user", "content": "Synthetic admission fixture." ]]
        guard let body = try? EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation()) else {
            return ["admission_fixture_prepared": false]
        }
        for mode in ["success", "template-mismatch", "version-mismatch", "model-mismatch", "count-mismatch", "bad-tokenizer", "admission-redirect", "admission-cancel", "auth-failed", "overflow"] {
            var result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
            var completions = 0
            let key = ["success", "overflow"].contains(mode) ? "synthetic-key" : "synthetic-" + mode
            let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: key,
                contextLimit: mode == "overflow" ? 10 : 32768, safetyTokens: 256) { value in result = value; completions += 1 }
            let start = Date(); let deadline = start.addingTimeInterval(5)
            while result == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                if mode == "admission-cancel" && Date().timeIntervalSince(start) > 0.05 { operation.cancel() }
            }
            if result == nil { operation.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            checks[mode + "_admission_completes_once"] = completions == 1
            switch result {
            case .success(let receipt):
                checks[mode + "_admission_result"] = mode == "success" && receipt.accepts(body: body, address: baseURL)
                    && receipt.promptTokens > 0 && receipt.envelopeBytes == body.count
                checks["admission_calibration_cost_recorded"] = operation.accounting.calibrationRequestCount == 1
                    && operation.accounting.calibrationUsage?.completionTokens == 1 && !operation.accounting.unknownCalibrationOutcome
            case .failure(let error):
                let expected: ProviderAdmissionError
                switch mode {
                case "template-mismatch": expected = .templateMismatch
                case "version-mismatch", "model-mismatch": expected = .unverifiedAdapter
                case "count-mismatch", "bad-tokenizer": expected = .countMismatch
                case "admission-cancel": expected = .cancelled
                case "overflow": expected = .contextOverflow
                default: expected = .unavailable
                }
                checks[mode + "_admission_result"] = error == expected
                if mode == "count-mismatch" {
                    checks["failed_calibration_cost_retained"] = operation.accounting.calibrationUsage != nil
                        && operation.accounting.calibrationRequestCount == 1
                }
            case .none: checks[mode + "_admission_result"] = false
            }
        }
        checks.merge(runEpisodeIntegration(baseURL: baseURL)) { _, replacement in replacement }
        checks.merge(runRealStoreCalibrationIdentityChecks(baseURL: baseURL)) { _, replacement in replacement }
        return checks
    }

    static func run() -> [String: Bool] {
        var checks: [String: Bool] = [:]
        checks["token_admission_exact_boundary"] = ProviderAdmission.fits(promptTokens: 768, outputReserve: 200, safetyTokens: 32, contextLimit: 1000)
        checks["token_admission_one_over_rejected"] = !ProviderAdmission.fits(promptTokens: 769, outputReserve: 200, safetyTokens: 32, contextLimit: 1000)
        checks["token_admission_integer_overflow_rejected"] = !ProviderAdmission.fits(promptTokens: Int.max, outputReserve: Int.max, safetyTokens: Int.max, contextLimit: 1000)
        checks["token_admission_output_and_safety_reserved"] = !ProviderAdmission.fits(promptTokens: 1, outputReserve: 999, safetyTokens: 1, contextLimit: 1000)
        checks["token_admission_negative_rejected"] = !ProviderAdmission.fits(promptTokens: -1, outputReserve: 1, safetyTokens: 1, contextLimit: 1000)
        var settings = GenerationSettings(); settings.profile = .customLocal
        settings.endpointAPIKey = "synthetic-secret-never-snapshotted"
        settings.messagesOverride = [["role": "system", "content": " Synthetic. "], ["role": "user", "content": " 日本語 {{tools}} "],
            ["role": "assistant", "content": "A</think></think>"], ["role": "user", "content": "next"]]
        do {
            let bytes = try EndpointRequest.build(prompt: "ignored", settings: settings, conversation: Conversation())
            let replay = try EndpointRequest.build(prompt: "ignored", settings: settings, conversation: Conversation())
            let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let rendered = try Qwen38TextAdapter.render(object)
            checks["request_canonical_replay_exact"] = bytes == replay
            checks["request_full_envelope_measured"] = bytes.count > (try JSONSerialization.data(withJSONObject: object["messages"]!)).count
            checks["request_snapshot_excludes_credentials"] = !String(decoding: bytes, as: UTF8.self).contains(settings.endpointAPIKey)
            checks["request_thinking_and_template_options_explicit"] = object["enable_thinking"] as? Bool == false
                && object["reasoning_effort"] as? String == "none" && object["stream_options"] as? [String: Bool] == ["include_usage": true]
            checks["exact_template_off_includes_generation_prefix"] = rendered.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n")
            checks["exact_template_preserves_multilingual_literal_template_text"] = rendered.contains("日本語 {{tools}}")
            checks["exact_template_server_close_normalization"] = rendered.contains("A</think><|im_end|>") && !rendered.contains("</think></think>")
            checks["exact_template_assistant_history_reasoning_signature"] = rendered.contains("<|im_start|>assistant\n<think>\n\n</think>\n\nA")
            checks["exact_template_ascii_trim_matches_server"] = Qwen38TextAdapter.trim("\u{000B} text \u{000C}") == "text"
                && Qwen38TextAdapter.trim("\u{00A0}text\u{00A0}") == "\u{00A0}text\u{00A0}"
            settings.thinkingEnabled = true
            let onBody = try EndpointRequest.build(prompt: "ignored", settings: settings, conversation: Conversation())
            let onObject = try JSONSerialization.jsonObject(with: onBody) as! [String: Any]
            let on = try Qwen38TextAdapter.render(onObject)
            checks["exact_template_on_low_preamble_and_open_generation"] = on.contains(Qwen38TextAdapter.lowInstructions)
                && on.hasSuffix("<|im_start|>assistant\n<think>\n") && onBody != bytes
            var unsupported = object; unsupported["model"] = "unverified-local-model"
            checks["unverified_model_renderer_rejected"] = (try? Qwen38TextAdapter.render(unsupported)) == nil
            var altered = object; altered["chat_template_kwargs"] = ["preserve_thinking": false]
            checks["unverified_template_options_rejected"] = (try? Qwen38TextAdapter.render(altered)) == nil
            var tool = object; tool["tools"] = [["type": "function"]]
            checks["unverified_tools_envelope_rejected"] = (try? Qwen38TextAdapter.render(tool)) == nil
            let receipt = EndpointAdmissionReceipt(bodyDigest: EndpointRequest.digest(bytes), endpoint: LocalEndpoint.chatURL(settings.endpointURL)!.absoluteString,
                modelID: Qwen38TextAdapter.modelID, promptTokens: 200, outputReserve: 512, safetyTokens: 256,
                effectiveContextLimit: 32768, envelopeBytes: bytes.count, templateDigest: Qwen38TextAdapter.templateDigest,
                serverVersion: Qwen38TextAdapter.serverVersion, loadedModelEpoch: 1, calibrationUsage: nil, admittedAt: Date())
            checks["receipt_binds_exact_body_and_origin"] = receipt.accepts(body: bytes, address: settings.endpointURL)
                && !receipt.accepts(body: onBody, address: settings.endpointURL)
                && !receipt.accepts(body: bytes, address: "http://localhost:11235/v1")
            let encoded = try JSONEncoder().encode(receipt)
            checks["receipt_codable_and_secret_free"] = try JSONDecoder().decode(EndpointAdmissionReceipt.self, from: encoded).bodyDigest == receipt.bodyDigest
                && !String(decoding: encoded, as: UTF8.self).contains(settings.endpointAPIKey)
            settings.messagesOverride = [["role": "user", "content": String(repeating: "x", count: EndpointRequest.maximumEnvelopeBytes)]]
            checks["full_envelope_limit_includes_wrapper"] = (try? EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())) == nil
        } catch { checks["provider_request_checks_completed"] = false }
        checks["provider_usage_counts_validated"] = ProviderUsage.parse(["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12])?.totalTokens == 12
        checks["provider_usage_sum_mismatch_rejected"] = ProviderUsage.parse(["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 99]) == nil
        checks["provider_usage_boolean_rejected"] = ProviderUsage.parse(["prompt_tokens": true, "completion_tokens": 2, "total_tokens": 3]) == nil
        checks["provider_usage_fractional_rejected"] = ProviderUsage.parse(["prompt_tokens": 1.2, "completion_tokens": 2, "total_tokens": 3.2]) == nil
        checks["provider_usage_zero_is_observed"] = ProviderUsage.parse(["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0])?.completionTokens == 0
        checks["provider_usage_negative_is_not_zero"] = ProviderUsage.parse(["prompt_tokens": 10, "completion_tokens": -1, "total_tokens": 9]) == nil
        checks["provider_usage_invalid_cached_detail_rejected"] = ProviderUsage.parse(["prompt_tokens": 10, "completion_tokens": 2,
            "total_tokens": 12, "prompt_tokens_details": ["cached_tokens": true]]) == nil
        checks["provider_usage_invalid_reasoning_detail_rejected"] = ProviderUsage.parse(["prompt_tokens": 10, "completion_tokens": 2,
            "total_tokens": 12, "completion_tokens_details": ["reasoning_tokens": -1]]) == nil
        checks["provider_usage_reasoning_is_output_subset"] = ProviderUsage.parse(["prompt_tokens": 10, "completion_tokens": 2,
            "total_tokens": 12, "completion_tokens_details": ["reasoning_tokens": 2]])?.completionTokens == 2
        return checks
    }

    private static func runEpisodeIntegration(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for mode in ["no-http", "negative-cap", "http-exhausted", "no-model", "no-input", "no-output",
                     "stop-before-handoff", "shared-deadline", "calibration-stop", "calibration-zero",
                     "calibration-negative", "calibration-missing", "calibration-excess", "calibration-arm-stop"] {
            var limits = EpisodeLimits()
            switch mode {
            case "no-http": limits.resources.httpAttempts = 0
            case "negative-cap": limits.resources.httpAttempts = -1
            case "http-exhausted": limits.resources.httpAttempts = 3
            case "no-model": limits.resources.modelCalls = 0
            case "no-input": limits.resources.inputTokens = 0
            case "no-output": limits.resources.outputTokens = 0
            case "shared-deadline": limits.deadlineMilliseconds = 60
            default: break
            }
            let ledger = ProviderEpisodeFixtureLedger(limits: limits)
            if mode == "stop-before-handoff" { ledger.stopBeforeHandoff = true }
            let lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
            if mode == "calibration-arm-stop" {
                ledger.afterCalibrationArm = { [weak lease] in _ = try? lease?.finish(reason: .cancelled) }
            }
            var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.messagesOverride = [["role": "user", "content": "Synthetic bounded provider fixture."]]
            // The true thinking identity has a separate calibration cache key.
            settings.thinkingEnabled = true
            let key: String
            switch mode {
            case "shared-deadline": key = "synthetic-admission-cancel"
            case "calibration-arm-stop": key = "synthetic-calibration-stop"
            case "calibration-stop", "calibration-zero", "calibration-negative", "calibration-missing", "calibration-excess": key = "synthetic-" + mode
            default: key = "synthetic-key"
            }
            guard let body = try? EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation()) else {
                checks[mode + "_episode_fixture_prepared"] = false; continue
            }
            var result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
            var completions = 0
            let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: key,
                contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { result = $0; completions += 1 }
            let deadline = Date().addingTimeInterval(5)
            var cancelled = false
            while result == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                if mode == "calibration-stop", !cancelled, operation.accounting.calibrationRequestCount == 1 {
                    cancelled = true; _ = try? lease.finish(reason: .cancelled); operation.cancel()
                }
            }
            if result == nil { operation.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            checks[mode + "_episode_completes_once"] = completions == 1
            let accounting = operation.accounting
            let records = ledger.records
            let inference = records.first { $0.request.kind == .calibration }
            let expected: ProviderAdmissionError?
            switch mode {
            case "negative-cap": expected = .episodeAccountingFailed
            case "stop-before-handoff", "calibration-arm-stop": expected = .episodeInactive
            case "shared-deadline": expected = .episodeDeadlineExceeded
            case "calibration-stop": expected = .cancelled
            case "calibration-missing": expected = .countMismatch
            case "calibration-negative": expected = .episodeAdapterViolation
            case "calibration-excess": expected = .episodeAdapterViolation
            case "calibration-zero": expected = nil
            default: expected = .episodeBudgetExceeded
            }
            switch result {
            case .success(let receipt): checks[mode + "_episode_result"] = expected == nil && receipt.episodeID == ledger.id
            case .failure(let error): checks[mode + "_episode_result"] = error == expected
            case .none: checks[mode + "_episode_result"] = false
            }
            checks[mode + "_durable_handoff_precedes_http"] = records.filter { $0.state != .cancelledBeforeDispatch }.count
                == accounting.httpRequestCount + (mode == "calibration-arm-stop" ? 1 : 0)
            checks[mode + "_snapshots_exclude_authentication"] = records.allSatisfy {
                !$0.request.adapterIdentity.contains(key) && !String(decoding: $0.request.snapshot ?? Data(), as: UTF8.self).contains(key)
            }
            if ["no-http", "negative-cap", "stop-before-handoff"].contains(mode) {
                checks[mode + "_does_not_resume_http"] = accounting.httpRequestCount == 0
            }
            if mode == "http-exhausted" { checks["repeated_preflight_uses_remaining_http_cap"] = accounting.httpRequestCount == 3 && inference == nil }
            if ["no-model", "no-input", "no-output"].contains(mode) {
                checks[mode + "_does_not_submit_inference"] = accounting.calibrationRequestCount == 0 && inference == nil
            }
            if mode == "calibration-zero" {
                checks["zero_calibration_usage_releases_only_output_hold"] = inference?.observed?.outputTokens == 0
                    && inference?.request.resources.modelCalls == 1 && inference?.request.resources.inputTokens ?? 0 > 0
            }
            if ["calibration-stop", "calibration-negative", "calibration-missing"].contains(mode) {
                checks[mode + "_retains_unknown_bound"] = inference?.state == .outcomeUnknown && inference?.observed == nil
                    && inference?.held.outputTokens == 1 && accounting.unknownCalibrationOutcome
            }
            if mode == "calibration-excess" {
                checks["calibration_excess_receipt_persisted_before_failure"] = inference?.observed?.outputTokens == 2
                    && accounting.calibrationUsage?.completionTokens == 2
            }
            if mode == "calibration-arm-stop" {
                checks["calibration_armed_suppressed_handoff_retains_bound_and_stop_failure"] = inference?.state == .outcomeUnknown
                    && inference?.observed == nil && inference?.held.outputTokens == 1 && inference?.charged.modelCalls == 1
                    && accounting.calibrationRequestCount == 0 && accounting.unknownCalibrationOutcome
                    && accounting.calibrationOutputReserve == 1
            }
        }
        var limits = EpisodeLimits(); limits.resources.httpAttempts = 6
        let ledger = ProviderEpisodeFixtureLedger(limits: limits)
        let lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
        var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
        settings.messagesOverride = [["role": "user", "content": "Synthetic repeated admission."]]
        if let body = try? EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation()) {
            var outcomes: [Bool] = [], attempts: [Int] = []
            for iteration in 0..<2 {
                var result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: "synthetic-key",
                    contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { result = $0 }
                let deadline = Date().addingTimeInterval(5)
                while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                attempts.append(operation.accounting.httpRequestCount)
                switch result {
                case .success: outcomes.append(iteration == 0)
                case .failure(let error): outcomes.append(iteration == 1 && error == .episodeBudgetExceeded)
                case .none: operation.cancel(); outcomes.append(false)
                }
            }
            checks["automatic_readmission_does_not_reset_episode_allowance"] = outcomes == [true, true]
                && attempts == [4, 2] && ledger.records.count == 6
        } else { checks["automatic_readmission_does_not_reset_episode_allowance"] = false }
        return checks
    }

    private static func runRealStoreCalibrationIdentityChecks(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for mode in ["calibration-wrong-model-missing", "calibration-wrong-model-invalid", "calibration-late-identity"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-calibration-quarantine-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let store = try MemoryStore(directory: directory), clock = SystemEpisodeClock()
                let conversation = try store.createConversation(projectID: "synthetic-calibration", title: "Synthetic calibration identity")
                let episodeID = UUID().uuidString
                _ = try store.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: UUID().uuidString,
                    humanEventID: UUID().uuidString, episodeID: episodeID, text: "Synthetic calibration request.", limits: EpisodeLimits(), clock: clock.now())
                let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
                var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
                settings.thinkingEnabled = true; settings.messagesOverride = [["role": "user", "content": "Synthetic calibration request."]]
                let body = try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
                let key = mode == "calibration-late-identity" ? "synthetic-calibration-stop" : "synthetic-" + mode
                var result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?, completions = 0
                let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: key,
                    contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { result = $0; completions += 1 }
                var stopped = false
                let deadline = Date().addingTimeInterval(5)
                while result == nil && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                    if mode == "calibration-late-identity", !stopped, operation.accounting.calibrationRequestCount == 1 {
                        stopped = true; _ = try lease.finish(reason: .cancelled); operation.cancel()
                    }
                }
                if result == nil { operation.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                let workID = try calibrationWorkID(directory: directory, episodeID: episodeID)
                let initial = try store.episodeWork(episodeID: episodeID, operationID: workID)
                let expected: ProviderAdmissionError = mode == "calibration-late-identity" ? .cancelled : .episodeAdapterViolation
                if case .failure(let error) = result {
                    checks[mode + "_real_store_terminal_result"] = error == expected && completions == 1
                } else { checks[mode + "_real_store_terminal_result"] = false }
                checks[mode + "_real_store_unknown_one_token_bound"] = initial?.state == .outcomeUnknown
                    && initial?.observed == nil && initial?.held.outputTokens == 1 && initial?.charged.modelCalls == 1
                if mode == "calibration-late-identity" {
                    let lateSession = URLSession(configuration: .ephemeral)
                    defer { lateSession.invalidateAndCancel() }
                    let unusedTask = lateSession.dataTask(with: LocalEndpoint.chatURL(baseURL)!)
                    let proof = Data("{\"model\":\"wrong-model\"}".utf8)
                    operation.urlSession(lateSession, dataTask: unusedTask, didReceive: proof)
                    operation.urlSession(lateSession, task: unusedTask, didCompleteWithError: nil)
                    let proofDeadline = Date().addingTimeInterval(5)
                    while !(try EndpointChecks.storedSettlementReceipts(directory: directory, workID: workID).violation) && Date() < proofDeadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                    }
                    let lateUnknown = try store.episodeWork(episodeID: episodeID, operationID: workID)
                    checks["late_calibration_identity_proof_keeps_unknown_output"] = lateUnknown?.state == .outcomeUnknown
                        && lateUnknown?.observed == nil && lateUnknown?.held.outputTokens == 1
                    let input = initial!.request.resources.inputTokens
                    let usage: [String: Any] = ["model": Qwen38TextAdapter.modelID,
                        "usage": ["prompt_tokens": input, "completion_tokens": 1, "total_tokens": input + 1]]
                    operation.urlSession(lateSession, dataTask: unusedTask, didReceive: try JSONSerialization.data(withJSONObject: usage))
                    operation.urlSession(lateSession, task: unusedTask, didCompleteWithError: nil)
                    let usageDeadline = Date().addingTimeInterval(5)
                    while (try store.episodeWork(episodeID: episodeID, operationID: workID))?.state != .completed && Date() < usageDeadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                    }
                    let settled = try store.episodeWork(episodeID: episodeID, operationID: workID)
                    let receipts = try EndpointChecks.storedSettlementReceipts(directory: directory, workID: workID).receipts
                    checks["late_calibration_identity_then_usage_keeps_three_receipts"] = receipts.count == 3
                        && receipts[0].outcome == .outcomeUnknown && receipts[0].observed == nil && !receipts[0].adapterViolation
                        && receipts[1].outcome == .outcomeUnknown && receipts[1].observed == nil && receipts[1].adapterViolation
                        && receipts[2].outcome == .completed && receipts[2].adapterViolation
                        && settled?.observed?.outputTokens == 1 && settled?.held.outputTokens == 0
                    checks["late_calibration_receipts_keep_episode_cancelled"] = try store.episodeReceipt(id: episodeID, clock: clock.now()).state == .cancelled
                }
                let stored = try EndpointChecks.storedSettlementReceipts(directory: directory, workID: workID)
                checks[mode + "_real_store_hashed_private_identity_evidence"] = stored.violation && stored.receipts.contains { receipt in
                    guard receipt.adapterViolation, receipt.observed == nil, let evidence = receipt.evidence,
                          let object = (try? JSONSerialization.jsonObject(with: evidence)) as? [String: Any] else { return false }
                    return object["usage_observed"] as? Bool == false && object["model_identity_mismatch"] as? Bool == true
                        && !String(decoding: evidence, as: UTF8.self).contains(key)
                }
                let nextID = UUID().uuidString
                _ = try store.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: UUID().uuidString,
                    humanEventID: UUID().uuidString, episodeID: nextID, text: "Changed synthetic request.", limits: EpisodeLimits(), clock: clock.now())
                let nextLease = EpisodeLease(ledger: store, episodeID: nextID, clock: clock)
                var changed = settings; changed.messagesOverride = [["role": "user", "content": "Changed synthetic request."]]
                let changedBody = try EndpointRequest.build(prompt: "", settings: changed, conversation: Conversation())
                var denied = false
                do {
                    _ = try nextLease.prepare(kind: .answer, resources: initial!.request.resources,
                        adapterIdentity: initial!.request.adapterIdentity, snapshot: changedBody)
                } catch EpisodeBudgetError.adapterViolation { denied = true }
                let next = try store.episodeReceipt(id: nextID, clock: clock.now())
                checks[mode + "_real_store_answer_adapter_stays_quarantined"] = denied && changedBody != body
                    && next.charged.modelCalls == 0 && next.held.modelCalls == 0
            } catch { checks[mode + "_real_store_fixture_completed"] = false }
        }
        return checks
    }

    private static func calibrationWorkID(directory: URL, episodeID: String) throws -> String {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw EpisodeBudgetError.invalid }
        defer { sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, "SELECT id FROM episode_work WHERE episode_id=? AND kind='calibration'", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw EpisodeBudgetError.invalid }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, episodeID, -1, transient) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else { throw EpisodeBudgetError.invalid }
        return String(cString: pointer)
    }
}

/// A transport-boundary recording fixture, separate from the real store's
/// durability/recovery suite. It makes premature network handoff observable.
final class ProviderEpisodeFixtureLedger: EpisodeLedger {
    let id = UUID().uuidString
    var stopBeforeHandoff = false
    var stopBeforeAnswerHandoff = false
    var afterAnswerArm: (() -> Void)?
    var afterCalibrationArm: (() -> Void)?
    private let limits: EpisodeLimits
    private let origin: EpisodeClockSnapshot
    private let lock = NSRecursiveLock()
    private var state = EpisodeState.active
    private var revision = 0
    private var work: [String: EpisodeWorkRecord] = [:]
    private var charged = EpisodeResources.zero
    private var held = EpisodeResources.zero
    var records: [EpisodeWorkRecord] { lock.lock(); defer { lock.unlock() }; return Array(work.values) }
    init(limits: EpisodeLimits) { self.limits = limits; origin = try! SystemEpisodeClock().now() }
    private func receipt() -> EpisodeReceipt {
        EpisodeReceipt(id: id, conversationID: "fixture", projectID: "fixture", turnID: "fixture", humanEventID: "fixture",
            limits: limits, state: state, revision: revision, clockDomain: origin.domain,
            deadlineNanoseconds: origin.continuousNanoseconds + UInt64(limits.deadlineMilliseconds) * 1_000_000,
            createdAt: origin.utc, charged: charged, held: held, unknownInputOperations: 0)
    }
    private func active(_ clock: EpisodeClockSnapshot) throws {
        if clock.domain != origin.domain || clock.continuousNanoseconds >= receipt().deadlineNanoseconds {
            state = .deadlineExceeded; throw EpisodeBudgetError.deadlineExceeded
        }
        guard state == .active else { throw EpisodeBudgetError.inactive }
    }
    func acceptRequestAndBeginEpisode(conversationID: String, turnID: String, humanEventID: String, episodeID: String,
        text: String, limits: EpisodeLimits, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt { throw EpisodeBudgetError.invalid }
    func reserveEpisodeWork(episodeID: String, request: EpisodeWorkRequest, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        lock.lock(); defer { lock.unlock() }; try active(clock)
        _ = try limits.resources.validated(); _ = try request.resources.validated()
        guard try charged.adding(held).adding(request.resources).fits(within: limits.resources) else { throw EpisodeBudgetError.exhausted }
        held = try held.adding(request.resources); revision += 1
        let record = EpisodeWorkRecord(id: request.id, episodeID: id, request: request, revision: revision, state: .prepared,
            charged: .zero, held: request.resources, observed: nil, receiptID: nil, recovered: false)
        work[record.id] = record; return record
    }
    func armEpisodeWork(episodeID: String, operationID: String, expectedRevision: Int, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        lock.lock(); defer { lock.unlock() }; try active(clock)
        guard let old = work[operationID], old.state == .prepared, old.revision == expectedRevision else { throw EpisodeBudgetError.staleRevision }
        var charge = old.request.resources; charge.outputTokens = 0
        var hold = EpisodeResources.zero; hold.outputTokens = old.request.resources.outputTokens
        held = try held.subtracting(old.held).adding(hold); charged = try charged.adding(charge); revision += 1
        let record = EpisodeWorkRecord(id: old.id, episodeID: id, request: old.request, revision: revision, state: .dispatchArmed,
            charged: charge, held: hold, observed: nil, receiptID: nil, recovered: false)
        work[operationID] = record; return record
    }
    func performEpisodeHandoff(episodeID: String, operationID: String, expectedRevision: Int,
        clock: EpisodeClockSnapshot, start: () -> Void) throws -> EpisodeWorkRecord {
        lock.lock(); defer { lock.unlock() }
        if stopBeforeHandoff || (stopBeforeAnswerHandoff && work[operationID]?.request.kind == .answer) {
            state = .cancelled; throw EpisodeBudgetError.inactive
        }
        let record = try armEpisodeWork(episodeID: episodeID, operationID: operationID, expectedRevision: expectedRevision, clock: clock)
        if record.request.kind == .answer { afterAnswerArm?() }
        if record.request.kind == .calibration { afterCalibrationArm?() }
        start(); return record
    }
    func settleEpisodeWork(episodeID: String, operationID: String, settlement: EpisodeWorkSettlement,
        clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord {
        lock.lock(); defer { lock.unlock() }
        guard let old = work[operationID] else { throw EpisodeBudgetError.invalid }
        if settlement.outcome == .cancelledBeforeDispatch, ![.prepared, .cancelledBeforeDispatch].contains(old.state) {
            throw EpisodeBudgetError.conflict
        }
        var charge = old.charged, hold = old.held
        let next: EpisodeWorkState
        switch settlement.outcome {
        case .cancelledBeforeDispatch: next = .cancelledBeforeDispatch; charge = .zero; hold = .zero
        case .outcomeUnknown: next = .outcomeUnknown
        case .failedConfirmed: next = .failedConfirmed; hold = .zero
        case .completed:
            next = .completed
            if let observed = settlement.observed { charge = observed; hold = .zero }
        }
        charged = try charged.subtracting(old.charged).adding(charge); held = try held.subtracting(old.held).adding(hold); revision += 1
        let record = EpisodeWorkRecord(id: old.id, episodeID: id, request: old.request, revision: revision, state: next,
            charged: charge, held: hold, observed: settlement.observed, receiptID: settlement.receiptID, recovered: false)
        work[operationID] = record
        if settlement.adapterViolation || (settlement.observed.map {
            [.calibration, .answer].contains(old.request.kind)
                && ($0.inputTokens != old.request.resources.inputTokens || $0.outputTokens > old.request.resources.outputTokens)
        } ?? false) { throw EpisodeBudgetError.adapterViolation }
        return record
    }
    func finishEpisode(episodeID: String, reason: EpisodeState, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt {
        lock.lock(); defer { lock.unlock() }; state = reason; revision += 1; return receipt()
    }
    func episodeReceipt(id: String, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt {
        lock.lock(); defer { lock.unlock() }
        if clock.continuousNanoseconds >= receipt().deadlineNanoseconds { state = .deadlineExceeded }
        return receipt()
    }
}
