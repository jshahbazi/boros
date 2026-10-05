import Foundation

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
        return checks
    }
}
