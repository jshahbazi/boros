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
        checks.merge(runComponentSessionChecks(baseURL: baseURL)) { _, replacement in replacement }
        checks.merge(runObservedIdentityHTTPChecks(baseURL: baseURL)) { _, replacement in replacement }
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
        checks.merge(runComponentRendererChecks()) { _, replacement in replacement }
        checks.merge(runObservedIdentityChecks()) { _, replacement in replacement }
        checks.merge(runQuarantineFamilyChecks()) { _, replacement in replacement }
        return checks
    }

    private static func runQuarantineFamilyChecks() -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let endpoint = "http://localhost:11234/v1/chat/completions"
        let legacy = ProviderAdmission.adapterIdentity(endpoint: endpoint, modelEpoch: 1, thinking: false)
        let legacyNext = ProviderAdmission.adapterIdentity(endpoint: endpoint, modelEpoch: 2, thinking: false)
        let observed = ProviderObservedModelIdentity.adapterIdentity(endpoint: endpoint, metadataDigest: String(repeating: "a", count: 64), thinking: false)
        let otherObservation = ProviderObservedModelIdentity.adapterIdentity(endpoint: endpoint, metadataDigest: String(repeating: "b", count: 64), thinking: false)
        guard let family = ProviderAdapterQuarantineFamily.recognize(legacy), let observedFamily = ProviderAdapterQuarantineFamily.recognize(observed) else {
            return ["quarantine_family_generated_formats_recognized": false]
        }
        checks["quarantine_family_generated_formats_recognized"] = true
        checks["quarantine_family_epoch_change_cannot_reset"] = family.contains(legacyNext)
        checks["quarantine_family_legacy_to_observed_preserves_denial"] = family == observedFamily && family.contains(observed)
        checks["quarantine_family_observation_change_cannot_reset"] = family.contains(otherObservation)
        checks["quarantine_family_has_two_exact_binary_prefix_ranges"] = family.prefixRanges.count == 2 && family.prefixRanges.allSatisfy { range in
            range.lowerInclusive.hasSuffix("|") && range.upperExclusive == String(range.lowerInclusive.dropLast()) + "}"
                && [legacy, observed].filter { $0.utf8.starts(with: range.lowerInclusive.utf8) }.allSatisfy {
                    !($0.utf8.lexicographicallyPrecedes(range.lowerInclusive.utf8)) && $0.utf8.lexicographicallyPrecedes(range.upperExclusive.utf8)
                }
        }
        checks["quarantine_family_exact_false_suffix"] = family.thinkingSuffix == "|thinking=false"
        let thinking = ProviderObservedModelIdentity.adapterIdentity(endpoint: endpoint, metadataDigest: String(repeating: "a", count: 64), thinking: true)
        checks["quarantine_family_thinking_modes_separate"] = !family.contains(thinking)
            && ProviderAdapterQuarantineFamily.recognize(thinking)?.thinkingSuffix == "|thinking=true"
        let otherEndpoint = ProviderObservedModelIdentity.adapterIdentity(endpoint: "http://localhost:11235/v1/chat/completions", metadataDigest: String(repeating: "a", count: 64), thinking: false)
        checks["quarantine_family_endpoint_port_separate"] = !family.contains(otherEndpoint)
        let uppercaseHost = ProviderObservedModelIdentity.adapterIdentity(endpoint: "http://LOCALHOST:11234/v1/chat/completions", metadataDigest: String(repeating: "a", count: 64), thinking: false)
        checks["quarantine_family_endpoint_utf8_identity_separate"] = ProviderAdapterQuarantineFamily.recognize(uppercaseHost) != nil && !family.contains(uppercaseHost)
        let ipv6 = ProviderObservedModelIdentity.adapterIdentity(endpoint: "http://[::1]:11234/v1/chat/completions", metadataDigest: String(repeating: "a", count: 64), thinking: false)
        checks["quarantine_family_canonical_ipv6_recognized"] = ProviderAdapterQuarantineFamily.recognize(ipv6) != nil && !family.contains(ipv6)
        for (name, identity) in [
            ("model", observed.replacingOccurrences(of: Qwen38TextRendering.modelID, with: "other-model")),
            ("server", observed.replacingOccurrences(of: "|" + Qwen38TextRendering.serverVersion + "|", with: "|unknown-version|")),
            ("template", observed.replacingOccurrences(of: Qwen38TextRendering.templateDigest, with: String(repeating: "c", count: 64))),
            ("negative_epoch", legacy.replacingOccurrences(of: "|1|thinking=", with: "|-1|thinking=")),
            ("noncanonical_epoch", legacy.replacingOccurrences(of: "|1|thinking=", with: "|01|thinking=")),
            ("overflow_epoch", legacy.replacingOccurrences(of: "|1|thinking=", with: "|18446744073709551615|thinking=")),
            ("bad_descriptor", observed.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "z", count: 64))),
            ("wrong_instance", observed.replacingOccurrences(of: "instance=unobservable", with: "instance=stable")),
            ("wrong_thinking", observed.replacingOccurrences(of: "thinking=false", with: "thinking=FALSE")),
            ("extra_field", observed + "|unexpected"),
            ("embedded_null", observed + "\0"),
            ("unencoded_separator", observed.replacingOccurrences(of: endpoint, with: "http://localhost:11234/v1/chat|completions")),
            ("noncanonical_route", observed.replacingOccurrences(of: endpoint, with: "http://localhost:11234/%76%31/chat/completions")),
            ("credentials", observed.replacingOccurrences(of: endpoint, with: "http://synthetic-user@localhost:11234/v1/chat/completions")),
            ("query", observed.replacingOccurrences(of: endpoint, with: endpoint + "?probe=%7C")),
            ("generic", "synthetic-generic-adapter")
        ] {
            checks["quarantine_family_" + name + "_uses_exact_fallback"] = ProviderAdapterQuarantineFamily.recognize(identity) == nil && !family.contains(identity)
        }
        return checks
    }

    private static func runObservedIdentityChecks() -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var model: [String: Any] = ["id": Qwen38TextRendering.modelID, "owned_by": "mlx-serve", "loaded": true,
            "state": "ready", "created": 1, "context_length": 32768, "max_model_len": 32768,
            "capabilities": ["streaming", "chat"], "input_modalities": ["text"],
            "meta": ["engine": "mlx", "architecture": "qwen4_exp"]]
        do {
            let first = try ProviderObservedModelIdentity.observe(model: model)
            model["created"] = 999999
            let next = try ProviderObservedModelIdentity.observe(model: model)
            checks["observed_identity_created_is_request_time_not_load_epoch"] = try first == next && first.canonicalData() == next.canonicalData()
            checks["observed_identity_explicit_instance_unknown"] = first.instanceIdentity == "unobservable"
                && first.version == ProviderObservedModelIdentity.versionValue
            let canonical = try first.canonicalData()
            checks["observed_identity_strict_canonical_roundtrip"] = try JSONDecoder().decode(ProviderObservedModelIdentity.self, from: canonical) == first
            let original = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
            for (name, key, value) in [("unknown_field", "futureIdentity", "x"), ("wrong_instance_mode", "instanceIdentity", "load-epoch"),
                ("wrong_runtime", "serverVersion", "unverified"), ("wrong_template", "templateDigest", "invalid") ] {
                var changed = original; changed[key] = value
                checks["observed_identity_" + name + "_rejected"] = (try? JSONDecoder().decode(ProviderObservedModelIdentity.self,
                    from: JSONSerialization.data(withJSONObject: changed))) == nil
            }
            var missing = original; missing.removeValue(forKey: "instanceIdentity")
            checks["observed_identity_missing_instance_mode_rejected"] = (try? JSONDecoder().decode(ProviderObservedModelIdentity.self,
                from: JSONSerialization.data(withJSONObject: missing))) == nil
            for (name, values) in [("unsorted", ["streaming", "chat"]), ("duplicate", ["chat", "chat", "streaming"]),
                ("non_ascii", ["chat", "streaming", "café"]), ("missing_stream", ["chat"])] {
                var changed = original; changed["capabilities"] = values
                checks["observed_identity_" + name + "_capabilities_rejected"] = (try? JSONDecoder().decode(ProviderObservedModelIdentity.self,
                    from: JSONSerialization.data(withJSONObject: changed))) == nil
            }
            for (name, value) in [("boolean", NSNumber(value: true)), ("fractional", NSNumber(value: 32768.5)),
                ("negative", NSNumber(value: -1)), ("overflow", NSNumber(value: UInt64.max))] {
                var changed = model; changed["context_length"] = value
                checks["observed_identity_" + name + "_context_rejected"] = (try? ProviderObservedModelIdentity.observe(model: changed)) == nil
            }
            var nonBoolean = model; nonBoolean["loaded"] = 1
            checks["observed_identity_numeric_loaded_flag_rejected"] = (try? ProviderObservedModelIdentity.observe(model: nonBoolean)) == nil
            var changed = model; changed["capabilities"] = ["chat", "reasoning", "streaming"]
            checks["observed_identity_actual_capability_change_distinct"] = try ProviderObservedModelIdentity.observe(model: changed) != first
            changed = model; changed["context_length"] = 16384
            checks["observed_identity_context_change_distinct"] = try ProviderObservedModelIdentity.observe(model: changed) != first
            let invalidA = ProviderObservedModelIdentity(version: "invalid-a", instanceIdentity: first.instanceIdentity,
                modelID: first.modelID, owner: first.owner, engine: first.engine, architecture: first.architecture,
                modelContextLimit: first.modelContextLimit, maxModelLength: first.maxModelLength, capabilities: first.capabilities,
                inputModalities: first.inputModalities, serverVersion: first.serverVersion, templateDigest: first.templateDigest)
            let invalidB = ProviderObservedModelIdentity(version: "invalid-b", instanceIdentity: first.instanceIdentity,
                modelID: first.modelID, owner: first.owner, engine: first.engine, architecture: first.architecture,
                modelContextLimit: first.modelContextLimit, maxModelLength: first.maxModelLength, capabilities: first.capabilities,
                inputModalities: first.inputModalities, serverVersion: first.serverVersion, templateDigest: first.templateDigest)
            checks["observed_identity_different_invalid_descriptors_not_equal"] = invalidA != invalidB
            let identity = ProviderAdmission.adapterIdentity(endpoint: "http://localhost:11234/v1/chat/completions", modelIdentity: first, thinking: false)
            checks["observed_adapter_stable_across_request_time"] = identity == ProviderAdmission.adapterIdentity(
                endpoint: "http://localhost:11234/v1/chat/completions", modelIdentity: next, thinking: false)
                && identity.contains("instance=unobservable") && !identity.contains("999999")
        } catch { checks["observed_identity_checks_completed"] = false }
        return checks
    }

    private static func runComponentRendererChecks() -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var settings = GenerationSettings(); settings.profile = .customLocal
        settings.messagesOverride = [["role": "system", "content": "\tSynthetic host </think></think>\n"],
            ["role": "user", "content": "\u{000B}recent café e\u{0301}\u{000C}"],
            ["role": "assistant", "content": "[partial] prior </think></think></think>"],
            ["role": "user", "content": "<source id=\"synthetic\">evidence 日本語</source>"],
            ["role": "user", "content": "Current intact request."]]
        let assignments: [ProviderMessageComponent] = [.mandatory, .recent, .recent, .evidence, .mandatory]
        do {
            let bytes = try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let rendered = try Qwen38TextAdapter.renderAttributed(body, assignments: assignments)
            checks["component_render_is_complete_production_render"] = rendered.complete.utf8.elementsEqual(try Qwen38TextAdapter.render(body).utf8)
            checks["component_recent_includes_delimiters_capture_and_history_thinking"] = rendered.recent == "<|im_start|>user\nrecent café e\u{0301}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n[partial] prior </think><|im_end|>\n"
            checks["component_evidence_includes_exact_source_wrapper_and_unicode"] = rendered.evidence == "<|im_start|>user\n<source id=\"synthetic\">evidence 日本語</source><|im_end|>\n"
            checks["component_mandatory_excluded_from_allocations"] = !rendered.recent.contains("Synthetic host") && !rendered.evidence.contains("Current intact")
            checks["component_same_role_separated_by_host_assignment"] = rendered.recent.contains("recent café") && !rendered.evidence.contains("recent café")
            checks["component_missing_assignment_rejected"] = (try? Qwen38TextAdapter.renderAttributed(body, assignments: Array(assignments.dropLast()))) == nil
            checks["component_system_cannot_be_optional"] = (try? Qwen38TextAdapter.renderAttributed(body, assignments: [.recent, .recent, .recent, .evidence, .mandatory])) == nil
            var empty = body; empty["messages"] = [["role": "system", "content": ""], ["role": "user", "content": ""], ["role": "user", "content": "present"]]
            let filtered = try Qwen38TextAdapter.renderAttributed(empty, assignments: [.mandatory, .recent, .mandatory])
            checks["component_provider_empty_messages_filtered_without_reassignment"] = filtered.recent.isEmpty && filtered.evidence.isEmpty && filtered.complete.contains("present")
            settings.thinkingEnabled = true
            let onBody = try JSONSerialization.jsonObject(with: EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())) as! [String: Any]
            let on = try Qwen38TextAdapter.renderAttributed(onBody, assignments: assignments)
            checks["component_thinking_changes_only_full_mandatory_generation"] = on.complete != rendered.complete && on.recent == rendered.recent && on.evidence == rendered.evidence
        } catch { checks["component_renderer_fixture_completed"] = false }
        return checks
    }

    private static func runComponentSessionChecks(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func wait<T>(_ operation: () -> Void, result: () -> T?) -> T? {
            operation(); let deadline = Date().addingTimeInterval(8)
            while result() == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            return result()
        }
        func request(_ messages: [[String: String]], thinking: Bool = false) throws -> Data {
            var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.messagesOverride = messages; settings.thinkingEnabled = thinking; settings.maximumOutput = 512
            return try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
        }
        let mandatory = [["role": "system", "content": "Synthetic component host."], ["role": "user", "content": "Synthetic intact current request."]]
        do {
            let body = try request(mandatory)
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
            let ledger = ProviderEpisodeFixtureLedger(limits: limits), lease: EpisodeLease
            lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
            let policyDigest = EndpointRequest.digest(try ContextComponentPolicy.selectedQwen.canonicalData())
            let sourceDigest = EndpointRequest.digest(Data("synthetic-component-sources-v1".utf8))
            var startResult: Result<ProviderComponentSession, ProviderAdmissionError>?
            let session = ProviderAdmission.beginComponentSession(mandatoryBody: body, address: baseURL, apiKey: "synthetic-key",
                contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { startResult = $0 }
            defer { session.close() }
            _ = wait({}, result: { startResult })
            guard case .success = startResult else { return ["component_session_verified": false] }
            checks["component_session_verified"] = true
            let initialHTTP = session.accounting.httpRequestCount
            var emptyRecent: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
            _ = wait({ session.countComponent(requestBody: body, assignments: [.mandatory, .mandatory], component: .recent) { emptyRecent = $0 } }, result: { emptyRecent })
            var emptyEvidence: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
            _ = wait({ session.countComponent(requestBody: body, assignments: [.mandatory, .mandatory], component: .evidence) { emptyEvidence = $0 } }, result: { emptyEvidence })
            guard case .success(let emptyR) = emptyRecent, case .success(let emptyE) = emptyEvidence else { return ["component_empty_receipts_created": false] }
            checks["component_empty_zero_has_no_tokenizer_work_or_http"] = emptyR.tokens == 0 && emptyR.tokenizerWorkID == nil && emptyE.tokens == 0
                && emptyE.tokenizerWorkID == nil && session.accounting.httpRequestCount == initialHTTP
            let sampleMessage = ["role": "user", "content": "x"]
            let sample = try JSONSerialization.jsonObject(with: request([mandatory[0], sampleMessage, mandatory[1]])) as! [String: Any]
            let wrapperBytes = try Qwen38TextAdapter.renderAttributed(sample, assignments: [.mandatory, .recent, .mandatory]).recent.utf8.count - 1
            let recentMessage = ["role": "user", "content": String(repeating: "r", count: ProviderComponentProof.recentTokenLimit - wrapperBytes)]
            let evidenceMessage = ["role": "user", "content": String(repeating: "e", count: ProviderComponentProof.evidenceTokenLimit - wrapperBytes)]
            let candidate = try request([mandatory[0], recentMessage, evidenceMessage, mandatory[1]])
            let assignments: [ProviderMessageComponent] = [.mandatory, .recent, .evidence, .mandatory]
            var recentResult: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
            _ = wait({ session.countComponent(requestBody: candidate, assignments: assignments, component: .recent) { recentResult = $0 } }, result: { recentResult })
            var evidenceResult: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
            _ = wait({ session.countComponent(requestBody: candidate, assignments: assignments, component: .evidence) { evidenceResult = $0 } }, result: { evidenceResult })
            guard case .success(let recent) = recentResult, case .success(let evidence) = evidenceResult else { return ["component_exact_counts_received": false] }
            checks["component_exact_8000_12000_boundary_counts"] = recent.tokens == 8000 && evidence.tokens == 12000
                && recent.tokenizerWorkID != nil && evidence.tokenizerWorkID != nil
            var final: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
            _ = wait({ session.admit(requestBody: candidate, assignments: assignments, sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest,
                recentReceipt: recent, evidenceReceipt: evidence) { final = $0 } }, result: { final })
            guard case .success(let receipt) = final, let proof = receipt.componentProof else { return ["component_full_candidate_admitted": false] }
            checks["component_full_candidate_admitted"] = receipt.accepts(body: candidate, address: baseURL)
                && proof.accepts(body: candidate, assignments: assignments, sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            checks["component_whole_prompt_counted_independently"] = receipt.promptTokens > recent.tokens + evidence.tokens
                && proof.wholePrompt.tokens == receipt.promptTokens && proof.wholePrompt.tokenizerWorkID != recent.tokenizerWorkID
            checks["component_counts_charge_http_not_generative_input"] = ledger.records.filter { $0.request.kind == .tokenizer }.allSatisfy {
                $0.request.resources.inputTokens == 0 && $0.request.resources.modelCalls == 0 && $0.request.resources.httpAttempts == 1
            }
            checks["component_tokenizer_count_evidence_committed_before_receipt"] = [recent, evidence, proof.wholePrompt].allSatisfy { count in
                guard let workID = count.tokenizerWorkID, let bytes = ledger.evidence(for: workID),
                      let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return false }
                return value["version"] as? String == "provider-tokenizer-count-v1" && value["token_count"] as? Int == count.tokens
                    && value["rendered_sha256"] as? String == count.renderedDigest && value["tokenizer_work_id"] as? String == workID
                    && value["adapter_identity"] as? String == count.adapterIdentity
            }
            checks["component_verification_reused_calibration_not_repeated"] = session.accounting.calibrationRequestCount == 1
                && ledger.records.filter { $0.request.kind == .providerDiscovery }.count == 6
            checks["component_observed_identity_explicit_and_legacy_epoch_unused"] = receipt.loadedModelEpoch == 0
                && proof.modelEpoch == 0 && receipt.modelIdentity == proof.modelIdentity
                && proof.modelIdentity.instanceIdentity == "unobservable"
            var missingOuterIdentity = receipt; missingOuterIdentity.modelIdentity = nil
            checks["component_receipt_cannot_omit_proof_identity"] = !missingOuterIdentity.accepts(body: candidate, address: baseURL)
            var identityMismatch = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
            var identityObject = identityMismatch["modelIdentity"] as! [String: Any]
            identityObject["capabilities"] = ["chat", "reasoning", "streaming"]
            identityMismatch["modelIdentity"] = identityObject
            let mismatchedReceipt = try JSONDecoder().decode(EndpointAdmissionReceipt.self, from: JSONSerialization.data(withJSONObject: identityMismatch))
            checks["component_receipt_rejects_observation_proof_mismatch"] = !mismatchedReceipt.accepts(body: candidate, address: baseURL)
            checks["component_proof_rejects_changed_source_selection"] = !proof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: EndpointRequest.digest(Data("changed".utf8)), policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            checks["component_proof_rejects_changed_policy"] = !proof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: sourceDigest, episodeLease: lease, address: baseURL)
            checks["component_proof_rejects_changed_assignment"] = !proof.accepts(body: candidate, assignments: [.mandatory, .evidence, .recent, .mandatory],
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            let changed = try request([mandatory[0], ["role": "user", "content": recentMessage["content"]! + "x"], evidenceMessage, mandatory[1]])
            checks["component_proof_rejects_changed_body"] = !proof.accepts(body: changed, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            let thinking = try request([mandatory[0], recentMessage, evidenceMessage, mandatory[1]], thinking: true)
            checks["component_proof_rejects_changed_thinking"] = !proof.accepts(body: thinking, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            var changedEpoch = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as! [String: Any]
            changedEpoch["modelEpoch"] = proof.modelEpoch + 1
            let epochProof = try JSONDecoder().decode(ProviderComponentProof.self, from: JSONSerialization.data(withJSONObject: changedEpoch))
            checks["component_proof_rejects_changed_unused_legacy_epoch"] = !epochProof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            var changedRenderer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as! [String: Any]
            changedRenderer["renderingVersion"] = "unverified-renderer"
            let rendererProof = try JSONDecoder().decode(ProviderComponentProof.self, from: JSONSerialization.data(withJSONObject: changedRenderer))
            checks["component_proof_rejects_changed_renderer"] = !rendererProof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            let otherLedger = ProviderEpisodeFixtureLedger(limits: limits), otherLease = EpisodeLease(ledger: otherLedger, episodeID: otherLedger.id)
            checks["component_proof_rejects_changed_episode_scope"] = !proof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: otherLease, address: baseURL)
            checks["component_proof_rejects_expired_binding"] = !proof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL, maximumAge: -1)
            let stamp = proof.wholePrompt.verifiedNanoseconds, domain = proof.wholePrompt.clockDomain
            let exactClock = EpisodeClockSnapshot(domain: domain, continuousNanoseconds: stamp + 30_000_000_000,
                utc: proof.wholePrompt.verifiedAt.addingTimeInterval(-86400))
            let expiredClock = EpisodeClockSnapshot(domain: domain, continuousNanoseconds: stamp + 30_000_000_001,
                utc: proof.wholePrompt.verifiedAt.addingTimeInterval(-86400))
            checks["component_binding_continuous_exact_age_boundary"] = proof.isFresh(clock: exactClock)
            checks["component_wall_clock_rollback_cannot_extend_binding"] = !proof.isFresh(clock: expiredClock)
            checks["component_binding_cannot_cross_boot_clock_domain"] = !proof.isFresh(clock: EpisodeClockSnapshot(domain: "other-boot",
                continuousNanoseconds: stamp, utc: Date()))
            checks["component_all_counts_retain_original_verification_clock"] = recent.verifiedNanoseconds == evidence.verifiedNanoseconds
                && recent.verifiedNanoseconds == proof.wholePrompt.verifiedNanoseconds && recent.clockDomain == proof.wholePrompt.clockDomain
            let encoded = try JSONEncoder().encode(receipt)
            let decoded = try JSONDecoder().decode(EndpointAdmissionReceipt.self, from: encoded)
            checks["component_proof_persistable_content_free_metadata"] = decoded.componentProof?.recent.tokens == 8000 && receipt.metadata["context_components"] != nil
                && !String(decoding: encoded, as: UTF8.self).contains("Synthetic intact")
            var over: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
            _ = wait({ session.countComponent(requestBody: changed, assignments: assignments, component: .recent) { over = $0 } }, result: { over })
            if case .success(let overReceipt) = over {
                let before = session.accounting.httpRequestCount
                var rejected: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                _ = wait({ session.admit(requestBody: changed, assignments: assignments, sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest,
                    recentReceipt: overReceipt, evidenceReceipt: evidence) { rejected = $0 } }, result: { rejected })
                if case .failure(let error) = rejected {
                    checks["component_one_over_rejected_without_whole_request_http"] = overReceipt.tokens == 8001 && error == .contextOverflow && session.accounting.httpRequestCount == before
                } else { checks["component_one_over_rejected_without_whole_request_http"] = false }
            } else { checks["component_one_over_rejected_without_whole_request_http"] = false }
            var stale: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
            let beforeStale = session.accounting.httpRequestCount
            _ = wait({ session.admit(requestBody: changed, assignments: assignments, sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest,
                recentReceipt: recent, evidenceReceipt: evidence) { stale = $0 } }, result: { stale })
            if case .failure = stale { checks["component_changed_text_cannot_reuse_old_count"] = session.accounting.httpRequestCount == beforeStale }
            else { checks["component_changed_text_cannot_reuse_old_count"] = false }
            let evidenceOver = try request([mandatory[0], recentMessage, ["role": "user", "content": evidenceMessage["content"]! + "x"], mandatory[1]])
            var evidenceOverResult: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
            _ = wait({ session.countComponent(requestBody: evidenceOver, assignments: assignments, component: .evidence) { evidenceOverResult = $0 } }, result: { evidenceOverResult })
            if case .success(let overReceipt) = evidenceOverResult {
                var rejected: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                let before = session.accounting.httpRequestCount
                _ = wait({ session.admit(requestBody: evidenceOver, assignments: assignments, sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest,
                    recentReceipt: recent, evidenceReceipt: overReceipt) { rejected = $0 } }, result: { rejected })
                if case .failure(let error) = rejected {
                    checks["component_evidence_one_over_rejected_without_whole_http"] = overReceipt.tokens == 12001 && error == .contextOverflow && session.accounting.httpRequestCount == before
                } else { checks["component_evidence_one_over_rejected_without_whole_http"] = false }
            } else { checks["component_evidence_one_over_rejected_without_whole_http"] = false }
            _ = try lease.finish(reason: .cancelled)
            checks["component_terminal_episode_rejects_immutable_proof"] = !proof.accepts(body: candidate, assignments: assignments,
                sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest, episodeLease: lease, address: baseURL)
            session.close()
            var closed: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?, closedCompletions = 0
            _ = wait({ session.countComponent(requestBody: body, assignments: [.mandatory, .mandatory], component: .recent) { closed = $0; closedCompletions += 1 } }, result: { closed })
            if case .failure(let error) = closed { checks["component_closed_session_completes_future_call_once"] = error == .cancelled && closedCompletions == 1 }
            else { checks["component_closed_session_completes_future_call_once"] = false }
        } catch { checks["component_session_fixture_completed"] = false }
        for mode in ["mandatory-overflow", "http-exhausted", "deadline", "stop", "calibration-missing", "calibration-wrong-model-missing"] {
            do {
                var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
                if mode == "http-exhausted" { limits.resources.httpAttempts = 3 }
                if mode == "deadline" { limits.deadlineMilliseconds = 60 }
                let ledger = ProviderEpisodeFixtureLedger(limits: limits), lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
                if mode == "stop" { _ = try lease.finish(reason: .cancelled) }
                var result: Result<ProviderComponentSession, ProviderAdmissionError>?, completions = 0
                let session = ProviderAdmission.beginComponentSession(mandatoryBody: try request(mandatory), address: baseURL,
                    apiKey: mode == "deadline" ? "synthetic-admission-cancel" : mode.hasPrefix("calibration-") ? "synthetic-" + mode : "synthetic-key",
                    contextLimit: mode == "mandatory-overflow" ? 800 : 32768, safetyTokens: 256, episodeLease: lease) { result = $0; completions += 1 }
                _ = wait({}, result: { result }); defer { session.close() }
                let expected: ProviderAdmissionError
                switch mode {
                case "mandatory-overflow": expected = .contextOverflow
                case "http-exhausted": expected = .episodeBudgetExceeded
                case "deadline": expected = .episodeDeadlineExceeded
                case "calibration-missing": expected = .countMismatch
                case "calibration-wrong-model-missing": expected = .episodeAdapterViolation
                default: expected = .episodeInactive
                }
                if case .failure(let error) = result { checks["component_" + mode + "_early_failure_once"] = error == expected && completions == 1 }
                else { checks["component_" + mode + "_early_failure_once"] = false }
                checks["component_" + mode + "_original_allowance_retained"] = ledger.records.allSatisfy { $0.episodeID == ledger.id }
                    && (mode != "http-exhausted" || session.accounting.httpRequestCount == 3)
                if mode.hasPrefix("calibration-") {
                    checks["component_" + mode + "_unknown_calibration_bound_retained"] = ledger.records.contains {
                        $0.request.kind == .calibration && $0.state == .outcomeUnknown && $0.held.outputTokens == 1 && $0.observed == nil
                    } && session.accounting.unknownCalibrationOutcome
                }
            } catch { checks["component_" + mode + "_fixture_completed"] = false }
        }
        do {
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen; limits.deadlineMilliseconds = 1000
            let ledger = ProviderEpisodeFixtureLedger(limits: limits), lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
            let mandatoryBody = try request(mandatory)
            var begun: Result<ProviderComponentSession, ProviderAdmissionError>?
            let session = ProviderAdmission.beginComponentSession(mandatoryBody: mandatoryBody, address: baseURL,
                apiKey: "synthetic-key", contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { begun = $0 }
            defer { session.close() }
            _ = wait({}, result: { begun })
            if case .success = begun {
                let initialHTTP = session.accounting.httpRequestCount
                var count: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?, completions = 0
                session.countComponent(requestBody: mandatoryBody, assignments: [.mandatory, .mandatory], component: .recent) {
                    count = $0; completions += 1
                }
                // Hold actual callback delivery while the provider worker and
                // continuous deadline continue. This is a synthetic GUI queue.
                Thread.sleep(forTimeInterval: 1.15)
                _ = wait({}, result: { count })
                if case .failure(let error) = count {
                    checks["component_deadline_crossing_queued_publication_suppressed"] = error == .episodeDeadlineExceeded && completions == 1
                } else { checks["component_deadline_crossing_queued_publication_suppressed"] = false }
                let terminal = try ledger.episodeReceipt(id: ledger.id, clock: SystemEpisodeClock().now())
                checks["component_queued_publication_does_not_renew_http_allowance"] = session.accounting.httpRequestCount == initialHTTP && terminal.state == .deadlineExceeded
            } else { checks["component_queued_publication_fixture_started"] = false }
        } catch { checks["component_queued_publication_fixture_completed"] = false }
        return checks
    }

    private static func runObservedIdentityHTTPChecks(baseURL: String) -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func awaitResult<T>(_ read: () -> T?) -> T? {
            let deadline = Date().addingTimeInterval(8)
            while read() == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            return read()
        }
        var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
        settings.messagesOverride = [["role": "system", "content": "Synthetic observed identity host."],
            ["role": "user", "content": "Synthetic current request."]]
        settings.maximumOutput = 512
        do {
            let body = try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
            let policy = EndpointRequest.digest(try ContextComponentPolicy.selectedQwen.canonicalData())
            let source = EndpointRequest.digest(Data("synthetic-observation-snapshot".utf8))
            var identities: [String] = []
            for mode in ["success-first", "success-second", "component-model-drift", "component-capability-drift", "component-template-drift", "component-version-drift"] {
                let ledger = ProviderEpisodeFixtureLedger(limits: limits), lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
                var started: Result<ProviderComponentSession, ProviderAdmissionError>?
                let session = ProviderAdmission.beginComponentSession(mandatoryBody: body, address: baseURL,
                    apiKey: mode.hasPrefix("success") ? "synthetic-key" : "synthetic-" + mode,
                    contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { started = $0 }
                defer { session.close() }
                _ = awaitResult({ started })
                guard case .success = started else { checks["observed_" + mode + "_session_began"] = false; continue }
                var recent: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
                session.countComponent(requestBody: body, assignments: [.mandatory, .mandatory], component: .recent) { recent = $0 }
                _ = awaitResult({ recent })
                var evidence: Result<ProviderComponentCountReceipt, ProviderAdmissionError>?
                session.countComponent(requestBody: body, assignments: [.mandatory, .mandatory], component: .evidence) { evidence = $0 }
                _ = awaitResult({ evidence })
                guard case .success(let r) = recent, case .success(let e) = evidence else { checks["observed_" + mode + "_empty_counts"] = false; continue }
                var admitted: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                session.admit(requestBody: body, assignments: [.mandatory, .mandatory], sourceSnapshotDigest: source,
                    policyDigest: policy, recentReceipt: r, evidenceReceipt: e) { admitted = $0 }
                _ = awaitResult({ admitted })
                if mode.hasPrefix("success") {
                    if case .success(let receipt) = admitted, let proof = receipt.componentProof {
                        checks["observed_" + mode + "_dynamic_created_admitted"] = receipt.accepts(body: body, address: baseURL)
                            && proof.accepts(body: body, assignments: [.mandatory, .mandatory], sourceSnapshotDigest: source,
                                policyDigest: policy, episodeLease: lease, address: baseURL)
                        identities.append(receipt.answerAdapterIdentity)
                    } else { checks["observed_" + mode + "_dynamic_created_admitted"] = false }
                } else {
                    if case .failure(let error) = admitted {
                        checks["observed_" + mode + "_final_identity_rejected"] = error == (mode == "component-template-drift" ? .templateMismatch : .unverifiedAdapter)
                    } else { checks["observed_" + mode + "_final_identity_rejected"] = false }
                }
                checks["observed_" + mode + "_fresh_calibration_retained"] = session.accounting.calibrationRequestCount == 1
                    && ledger.records.filter { $0.request.kind == .calibration }.count == 1
                    && ledger.records.filter { $0.request.kind == .calibration }.allSatisfy { $0.charged.inputTokens > 0 && $0.charged.modelCalls == 1 }
                checks["observed_" + mode + "_no_answering_dispatch"] = !ledger.records.contains { $0.request.kind == .answer }
                session.close()
            }
            checks["observed_adapter_quarantine_identity_stable_across_independent_sessions"] = identities.count == 2 && identities[0] == identities[1]
        } catch { checks["observed_identity_http_fixture_completed"] = false }
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
            // Exercise explicit thinking within the original episode allowance.
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-readmission-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            var limits = EpisodeLimits(); limits.resources.httpAttempts = 11
            let store = try MemoryStore(directory: directory), clock = SystemEpisodeClock()
            let conversation = try store.createConversation(projectID: "synthetic-readmission", title: "Synthetic repeated admission")
            let episodeID = UUID().uuidString
            let original = try store.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: UUID().uuidString,
                humanEventID: UUID().uuidString, episodeID: episodeID, text: "Synthetic repeated admission.", limits: limits, clock: clock.now())
            let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
            var settings = GenerationSettings(); settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.messagesOverride = [["role": "user", "content": "Synthetic repeated admission."]]
            let body = try EndpointRequest.build(prompt: "", settings: settings, conversation: Conversation())
            var outcomes: [Bool] = [], attempts: [Int] = [], calibrationInputs: [Int] = [], calibrationOutputs: [Int] = [], calibrations: [Int] = []
            for iteration in 0..<2 {
                var result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>?
                let operation = ProviderAdmission.prepare(requestBody: body, address: baseURL, apiKey: "synthetic-key",
                    contextLimit: 32768, safetyTokens: 256, episodeLease: lease) { result = $0 }
                let deadline = Date().addingTimeInterval(5)
                while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
                let accounting = operation.accounting
                attempts.append(accounting.httpRequestCount); calibrations.append(accounting.calibrationRequestCount)
                if let usage = accounting.calibrationUsage {
                    calibrationInputs.append(usage.promptTokens); calibrationOutputs.append(usage.completionTokens)
                }
                switch result {
                case .success(let receipt): outcomes.append(iteration == 0 && receipt.episodeID == episodeID)
                case .failure(let error): outcomes.append(iteration == 1 && error == .episodeBudgetExceeded)
                case .none: operation.cancel(); outcomes.append(false)
                }
            }
            let workIDs = try episodeWorkIDs(directory: directory, episodeID: episodeID)
            let records = try workIDs.compactMap { try store.episodeWork(episodeID: episodeID, operationID: $0) }
            let terminal = try store.episodeReceipt(id: episodeID, clock: clock.now())
            let calibrationWork = records.filter { $0.request.kind == .calibration }
            let expected = EpisodeResources(inputTokens: calibrationInputs.reduce(0, +), outputTokens: 2, modelCalls: 2, httpAttempts: 11)
            // Both operations calibrate. The second retains those charges and
            // fails before candidate tokenization could reserve HTTP attempt12.
            checks["automatic_readmission_does_not_reset_episode_allowance"] = outcomes == [true, true]
                && attempts == [6, 5] && calibrations == [1, 1] && calibrationInputs.count == 2
                && calibrationInputs.allSatisfy { $0 > 0 } && calibrationOutputs == [1, 1]
                && records.count == 11 && records.allSatisfy { episodeIdentifierEqual($0.episodeID, episodeID) }
                && calibrationWork.count == 2 && calibrationWork.allSatisfy { work in
                    work.state == .completed && work.request.inputTokensKnown && work.request.resources.modelCalls == 1
                        && work.request.resources.outputTokens == 1 && work.request.resources.inputTokens > 0
                        && work.observed?.inputTokens == work.request.resources.inputTokens && work.observed?.outputTokens == 1
                        && work.observed?.modelCalls == 1 && work.held == .zero
                }
                && !records.contains { $0.request.kind == .answer }
                && terminal.state == .budgetExceeded && terminal.origin == original.origin && terminal.limits == limits
                && episodeIdentifierEqual(terminal.id, original.id) && terminal.charged == expected && terminal.held == .zero
        } catch { checks["automatic_readmission_does_not_reset_episode_allowance"] = false }
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

    private static func episodeWorkIDs(directory: URL, episodeID: String) throws -> [String] {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw EpisodeBudgetError.invalid }
        defer { sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, "SELECT id FROM episode_work WHERE episode_id=? ORDER BY id", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw EpisodeBudgetError.invalid }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, episodeID, -1, transient) == SQLITE_OK else { throw EpisodeBudgetError.invalid }
        var ids: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return ids }
            guard step == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else { throw EpisodeBudgetError.invalid }
            ids.append(String(cString: pointer))
        }
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
    private var workEvidence: [String: Data] = [:]
    private var charged = EpisodeResources.zero
    private var held = EpisodeResources.zero
    var records: [EpisodeWorkRecord] { lock.lock(); defer { lock.unlock() }; return Array(work.values) }
    func evidence(for workID: String) -> Data? { lock.lock(); defer { lock.unlock() }; return workEvidence[workID] }
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
        if let evidence = settlement.evidence { workEvidence[operationID] = evidence }
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
