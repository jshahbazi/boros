# Exact admission for the local MLX provider

Implemented October 4, 2026. The supported adapter is text-only Chat Completions for `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` served by mlx-serve `26.10.1`. Unknown models, server versions, templates, or unsupported content fail explicitly. The adapter does not estimate tokens from characters or bytes.

## Request and admission contract

`EndpointRequest.build` is the single request-body builder. It serializes sorted JSON keys, preserves the ordered role-message content, measures the entire HTTP JSON body, and rejects envelopes above 2 MiB. The exact resulting bytes can be journaled and then handed to `EndpointRunner`. The transport rebuilds the expected body and rejects any prepared-body discrepancy. Authorization headers and API keys are excluded from the snapshot.

The byte limit covers the complete wire envelope, including generation parameters. The token limit covers the model input the server actually renders from that envelope, including its system preamble, history formatting, reasoning signatures, and assistant generation prefix. Model IDs, JSON framing, and sampling parameters consume wire bytes rather than prompt tokens.

Before dispatch, `ProviderAdmission.prepare`:

1. Confirms the exact model ID is loaded and ready under the local MLX engine.
2. Reads that model's configured context capacity and the server's current safe-memory capacity.
3. Fetches the live chat template and requires the pinned digest.
4. Renders the complete text request with the restricted verified renderer.
5. Counts the rendered prompt through the selected model's own `/tokenize` vocabulary.
6. Requires `prompt_tokens + max_tokens + safety_tokens <= effective_context_limit`.

The effective limit is the minimum of the configured Boros limit, model-list capacity, model-specific `/props` capacity, and reported safe-memory capacity. Boros defaults to a 32,768-token cap and a 256-token safety reserve. The observed server advertised 155,648 context tokens while its safe-memory capacity was lower; the checkpoint's 262,144 position limit does not establish current serving capacity.

The receipt binds the exact body SHA-256, endpoint, model ID, prompt count, output/safety reserves, envelope size, template digest, server version, loaded-model epoch, and admission time. Dispatch rejects receipts older than 30 seconds. The transport requests streamed usage, validates final model identity and prompt/output counts, and records provider usage. Missing or mismatched usage cannot produce a successful completion.

## Rendering evidence

The template is pinned to SHA-256:

```text
c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041
```

The live `/api/show` template was byte-identical to the checkpoint's [tokenizer configuration](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit/blob/7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3/tokenizer_config.json), which specifies no added BOS token. The checked-in [test template](../Tests/qwen38-chat-template.jinja) is this exact 8,952-byte source.

The renderer follows the provider's [chat preparation code](https://github.com/ddalcu/mlx-serve/blob/25e94c3381c7f8428c4b0e45e814d2554c4926be/src/chat.zig) and [request/tokenize handlers](https://github.com/ddalcu/mlx-serve/blob/25e94c3381c7f8428c4b0e45e814d2554c4926be/src/server.zig): empty plain-text messages are dropped, the template adds assistant-history reasoning signatures, and repeated adjacent closing think tags collapse after rendering. Plain assistant content is retained as content; this client sends no separate historical reasoning field.

The owning C++ Jinja engine's [trim implementation](https://github.com/ddalcu/mlx-serve/blob/25e94c3381c7f8428c4b0e45e814d2554c4926be/lib/jinja_cpp/jinja_string.cpp) uses bytewise C whitespace. Boros therefore strips ASCII space, tab, CR, LF, vertical tab, and form feed. Python Jinja's Unicode whitespace behavior would differ. Unicode boundary behavior was checked against the running provider.

The canonical body explicitly sets `enable_thinking`, `reasoning_effort` (`low` when enabled, `none` when disabled), and `preserve_thinking: true`. These match the verified renderer and remove template-affecting server-default ambiguity. Unsupported tool, media, continuation, or extra system-message envelopes are rejected.

The reviewed public source is identified above. The live server reports its version; Boros does not attest the running binary against that public commit.

## Calibration and incurred work

For a new endpoint/model-load/template/version/thinking identity, Boros performs one synthetic calibration request with a one-token output cap. It first counts the calibration prompt through `/tokenize`, then requires the provider's generated usage to report exactly that prompt count. The synthetic history exercises multilingual text, a previous assistant, literal template text, source markup, and repeated closing think tags. A process-local cache prevents repeating that generation probe for the same identity. Metadata and the entire actual prompt are still checked and counted for every candidate request.

`ProviderAdmissionAccounting` reports HTTP request count, tokenizer request count, calibration count, expected calibration prompt tokens, the one-token output reservation, observed usage, elapsed time, and an unknown-outcome flag. It remains readable after failure or cancellation, so a rejected candidate or an optional-evidence rebuild retains its incurred work. A calibration handed off without a usable response records an unknown outcome rather than invented zero usage. This accounting must be included in episode-level evaluation.

The admission operation rejects redirects, uses ephemeral sessions without cookies or caching, bounds each response to 4 MiB, and enforces a 45-second overall preflight deadline with shorter individual requests. Cancellation resolves once and cancels the client connection. The generation transport retains its existing 180-second deadline and bounded SSE/output behavior.

## Verification

The deterministic suites cover exact limit boundaries, overflow-safe arithmetic, wire-envelope overhead, credential exclusion, receipt/body/origin binding, thinking options, usage validation, and unsupported envelopes. HTTP fixtures cover calibration cost retention, template/version/model/tokenizer/count failures, authentication rejection, redirect rejection, cancellation, context overflow, and missing/mismatched streamed usage or model identity. The HTTP fixture uses a declared synthetic vocabulary; it does not establish real-model tokenizer correctness.

An independent Jinja2 oracle compared the production Swift renderer against the pinned template in 30 synthetic cases: 24 renderings and six explicit rejections. Cases cover both thinking modes, role history, multilingual and decomposed Unicode, Unicode/ASCII whitespace, empty content, literal think tags, source excerpts, and template-looking strings. All 24 valid cases also matched the running server's reported prompt count to its `/tokenize` result. These live checks incurred 866 input and 24 output provider tokens. No prompts or generated answers were logged.

The optional verification script is [provider_admission_oracle.py](../Tests/provider_admission_oracle.py). It requires Jinja2 3.1.6 in a temporary development environment and compiles a driver against the production renderer. It adds no application dependency. Pass `--live` to repeat the synthetic provider comparison against `localhost:11234`.

## Limits and remaining work

The preflight and dispatch are separate provider requests. A server restart, configuration mutation, unload/reload, or resource change after the receipt may invalidate the observation. Receipt age and final usage checks limit silent drift; they do not lock the external server configuration or prevent a later provider rejection. The process-local calibration cache relies on reported loaded-model identity. An atomic provider-side count-and-reserve contract would provide a stronger guarantee.

The supported input is complete text role messages with the verified options. No generic compatibility fallback, tool accounting, multimodal accounting, GGUF exact-token adapter, remote processor, or total episode-budget enforcement is established by this change. Provider usage and preflight accounting supply evidence for subsequent evaluation; they do not prove model quality, latency improvement, or lower total cost.

## Third-party template provenance

The test template originates from the [Qwen3.8 Flash Next MLX checkpoint](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit/tree/7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3), revision `7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3`, and is covered by the checkpoint's [Qwen Community License 1.0](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit/blob/7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3/LICENSE). Its copyright and permission notice are preserved in [qwen38-chat-template.LICENSE](../Tests/qwen38-chat-template.LICENSE), SHA-256 `a0dc422560841fd68e06d974907f8b4c709bca44a67daad2b528437bdf676c08`.

This is a conditional community license. It contains separate-license requirements for specified commercial model-service or AI work-assistant businesses and attribution conditions above stated scale thresholds. The current local internal-use prototype does not settle commercial distribution licensing. The copied template's license is separate from Boros-authored code and the imported GUI's provenance.
