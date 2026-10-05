import Foundation

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
        return checks
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
