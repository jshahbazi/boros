import Foundation

/// Shared builders keep durable native invocation evidence equal to dispatched
/// bytes and arguments. They never include the private server authentication token.
enum NativeRequest {
    static func reasoningBody(prompt: String, settings: GenerationSettings, conversation: Conversation) throws -> Data {
        let thinking = settings.effectiveThinkingEnabled
        let sampler = settings.profile.sampling(preset: settings.samplingPreset, thinking: thinking)
        var body: [String: Any] = [
            "messages": settings.messages(prompt, conversation: conversation),
            "stream": true, "stream_options": ["include_usage": true], "max_tokens": settings.maximumOutput,
            "temperature": settings.temperature, "top_k": sampler.topK, "top_p": sampler.topP, "min_p": sampler.minP,
            "presence_penalty": sampler.presencePenalty, "repeat_penalty": sampler.repetitionPenalty,
            "seed": settings.seed, "cache_prompt": false
        ]
        if settings.profile.supportsThinking {
            body["reasoning_format"] = "deepseek"
            body["reasoning_budget_tokens"] = settings.effectiveThinkingBudget
            body["chat_template_kwargs"] = ["enable_thinking": thinking]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func completionArguments(settings: GenerationSettings) -> [String] {
        ["-m", (settings.model as NSString).expandingTildeInPath, "-f", "/dev/stdin", "-c", String(settings.context),
         "-n", String(settings.maximumOutput), "-ngl", "99", "-fa", "on", "-t", "6",
         "--no-conversation", "--no-jinja", "--no-display-prompt", "--simple-io", "--no-context-shift", "--no-escape",
         "--color", "off", "--seed", String(settings.seed), "--temp", String(settings.temperature),
         "--top-k", "40", "--top-p", "0.95", "--min-p", "0.0"] + settings.profile.runtimeArguments
    }

    static func completionEvidence(prompt: String, settings: GenerationSettings, conversation: Conversation) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "transport": "process-stdin", "executable": (settings.runtime as NSString).expandingTildeInPath,
            "arguments": completionArguments(settings: settings), "stdin": settings.render(prompt, conversation: conversation)
        ], options: [.sortedKeys])
    }

    static func configuration(settings: GenerationSettings) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "adapter": settings.profile == .bonsai ? "llama-completion-stdin" : "owned-llama-server-unix",
            "profile": settings.profile.rawValue, "model_path": (settings.model as NSString).expandingTildeInPath,
            "runtime_path": (settings.runtime as NSString).expandingTildeInPath, "context": settings.context,
            "exact_token_admission": false
        ], options: [.sortedKeys])
    }
}
