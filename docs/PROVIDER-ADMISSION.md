# Exact admission for the local MLX provider

Implemented October 4, 2026; component/observation contract verified October 5. The supported adapter is text-only Chat Completions for `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` served by mlx-serve `26.10.1`. Unknown models, server versions, templates, or unsupported content fail explicitly. The adapter does not estimate tokens from characters or bytes.

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

The receipt binds the exact body SHA-256, endpoint, model ID, prompt count, output/safety reserves, envelope size, template digest, server version, validated model metadata observation, thinking mode and admission time. The observation explicitly records model-instance identity as unobservable. For metered requests the receipt also identifies the episode and calibration work. Dispatch rejects receipts older than 30 seconds. Component proofs additionally use the original lease's boot-scoped continuous clock. The transport requests streamed usage, validates final model identity and prompt/output counts, and records provider usage. Missing or mismatched usage cannot produce a successful completion.

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

## Optional JSON-object output

For the selected adapter, `endpointJSONOutput` requests the exact optional wire field `response_format: { "type": "json_object" }`. Its default is off. Absent fields preserve the previous body bytes and renderer/proof versions, including ordinary thinking requests and historical archives. Other formats, schemas and joint JSON/thinking requests are refused. Initial model discovery, component handoff and offline journal validation require the advertised `json_schema` capability for a JSON body.

The `mlx-serve-qwen38-json-object-v1` sub-contract follows [tagged v26.10.1 preprocessing](https://github.com/ddalcu/mlx-serve/blob/02bee553f48cd3bc7d82aba0f8073820bd924738/src/server.zig#L8684). Exactly empty plain messages are dropped first. The server appends its fixed 137-byte instruction to the first retained raw System message, or inserts a System message, before template trimming. The instruction's SHA-256 is `7291d7ca4c4f2045ce0f23a5ce750792eb630b6bb2541ca69759cd3811a4f14a`. It belongs to mandatory input. Recent and historical allocation strings remain unchanged; the whole transformed prompt is counted and charged under the original allowance. `/tokenize` consumes the already-rendered text and supplies no response-format preprocessing.

The server can rerender a JSON request with thinking off after resolving runtime reasoning protocol/budget state. That state is not fully exposed by current metadata. A live synthetic JSON/thinking request reported 54 prompt tokens against the requested-thinking render's 78; explicit thinking off matched 54/54. The restricted adapter therefore supports JSON only with thinking off. The GUI clears and disables thinking when JSON is selected. Unsupported joint requests fail before admission.

An independent pinned Jinja/Swift oracle passed **107 cases**: 45 exact full/attributed renders and 62 refusals. All **45 live synthetic requests** matched the provider's prompt counts, totaling 2,101 input and 45 output tokens with a one-token output cap. These direct probes are outside Boros runtime accounting and do not measure complete JSON or answer accuracy. Records: `.build/json-object-provider-oracle-final.log` and `.build/evaluation/json-thinking-preprocessing-20261006.json`.

Grammar initialization can fail and leave prompt-only enforcement. Complete output is always retained, with no JSON repair or rewriting. The GUI reports a complete non-object response after capture; the diagnostic independently validates JSON shape, exact answers and citations. See [the separate frozen amendment](EVIDENCE-CONTROL.md#provider-json-object-amendment).

## Calibration and incurred work

For each independent preparation operation or component session, Boros performs one synthetic calibration request with a one-token output cap. It first counts the calibration prompt through `/tokenize`, then requires the provider's generated usage to report exactly that prompt count. The synthetic history exercises multilingual text, a previous assistant, literal template text, source markup, and repeated closing think tags. Component counts and reductions share that session's calibration, original validity period and episode allowance. Calibration cannot be reused across independent sessions because the provider exposes no stable loaded-instance identifier. Metadata and the entire actual prompt are still checked and counted for every candidate request.

`ProviderAdmissionAccounting` reports HTTP request count, tokenizer request count, calibration count, expected calibration prompt tokens, the one-token output reservation, observed usage, elapsed time, and an unknown-outcome flag. It remains readable after failure or cancellation, so a rejected candidate or an optional-evidence rebuild retains its incurred work. A calibration handed off without a usable response records an unknown outcome rather than invented zero usage. This accounting must be included in episode-level evaluation.

Ordinary GUI Send and the synthetic CLI smoke workflow now pass one durable `EpisodeLease` through preparation, discovery, tokenization, calibration, admission retries and answering. Main-store schema 4 retains each credential-free candidate snapshot and work reservation before handoff. The exact prompt input for every calibration and answer is charged, including repeated and cached input. Output headroom is held before dispatch and settled from valid provider usage; reported reasoning tokens remain a subset of completion tokens. A retry cannot obtain a new allowance. Discovery and tokenizer calls consume HTTP attempts, while calibration and answering consume model calls too. The [episode contract](EPISODE-BUDGET.md) defines the frozen resource vector and shared continuous deadline.

The admission operation rejects redirects, uses ephemeral sessions without cookies or caching, bounds each response to 4 MiB, and retains its 45-second preflight bound with shorter individual requests. Answer transport retains its 180-second local upper bound, a 16 MiB cumulative wire bound and bounded SSE/visible-output parsing. With an episode lease, every request and timer also uses the remaining shared deadline. Stop closes the lease before client cancellation and further handoff. The admission and answer APIs retain an optional nil-lease path for legacy/component callers; those calls provide no durable episode allowance.

Arming durably charges input/call/HTTP work before a short owner-serialized resume. The owner lock and SQLite transaction are released before waiting for network completion. Cancellation after arming can suppress resume while leaving a conservative unknown record; it cannot release an armed reservation merely because the client observed no response. Recovery and restore retain unknown output headroom. Late authoritative usage can settle it without reopening the cancelled or interrupted episode.

Adapter identity is stable across prompt changes and independent sessions that observe identical metadata. It includes endpoint, the canonical model-observation digest, model, server/template version and thinking mode. The descriptor records the owner, engine, architecture, model context/position limits, advertised capabilities/modalities and `instanceIdentity: unobservable`. The request snapshot separately binds the exact body. A wrong model or malformed usage quarantines the exact endpoint/model/server/template/thinking family even when actual token counts remain unknown. That quarantine spans capacity/capability changes and historical epoch keys. Complete observation keys remain in the journal; no historical records are rewritten. Unsupported adapter names retain exact-key quarantine.

The owner checks quarantine at reservation and again before arming or handing off prepared/already-armed work. A violation reported by another episode can therefore suppress previously reserved work. Rejected prepared work releases unused holds; rejected armed work retains conservative charges and uncertain output headroom. There is no automatic quarantine reset based on metadata churn. Credential-free evidence records mismatch flags and hashed model identifiers. Late identity proof can extend an initial unknown receipt, followed by one authoritative usage receipt; this legitimate three-receipt chain preserves cancellation and quarantine. Late response parsing remains under its cumulative wire bound. Journal and backup validation enforce the receipt transitions and work/body linkage.

The pinned [model-list handler](https://github.com/ddalcu/mlx-serve/blob/25e94c3381c7f8428c4b0e45e814d2554c4926be/src/server.zig#L6243-L6248) generates `created` from the response-time clock. That field is excluded from the observation. New receipts retain zero in legacy epoch slots solely for format compatibility; zero supplies no instance identity. Historical receipts without a model descriptor keep their original decode and adapter representation. New component journals require the explicit validated descriptor and its receipt/proof/adapter linkage.

## Verification

The deterministic suites cover exact limit boundaries, overflow-safe arithmetic, wire-envelope overhead, credential exclusion, receipt/body/origin binding, thinking options, usage validation, and unsupported envelopes. HTTP fixtures cover calibration cost retention, template/version/model/tokenizer/count failures, authentication rejection, redirect rejection, cancellation, context overflow, and missing/mismatched streamed usage or model identity. The HTTP fixture uses a declared synthetic vocabulary; it does not establish real-model tokenizer correctness.

The component checkpoint passed 105 pure endpoint/admission and 254 HTTP checks in the 1,297-check combined app. Actual coordinator/proof fixtures passed 97 checks, including response-time timestamp changes, final model/template/runtime drift, fresh calibration charges, original scope/deadline and archive corruption. Independent identity review passed 19 rechecks after closing metadata/legacy-key quarantine bypass and prepared/armed handoff after a violation. The real-store retry fixture retained both calibrations under one 11-attempt allowance and ended budget-exceeded with zero holds. Strict app signature and two live Qwen turns passed. Provider load generation remains unobservable; these checks do not attest server binaries or model weights.

The integrated episode wave passed 49 endpoint/admission unit checks and 189 HTTP integration checks within the 793-check application suite. Real-store fixtures cover active and late calibration/answer identity violations with missing or invalid usage, preserved unknown output holds, changed-prompt adapter denial, Stop after durable arming but before resume, and late identity proof followed by authoritative usage. Independent review reproduced the calibration missing-usage gap, then reran all 189 HTTP checks successfully after its fix. Standalone episode recovery also passes real SIGKILL/reopen checks.

The current bundle passed two synthetic arithmetic turns against the running mlx-serve instance with durable episode accounting. Its final turn reported 218 charged input tokens, three charged output tokens and zero held output tokens. These counters cover that turn alone. The smoke test uses a temporary synthetic store and establishes basic provider integration; model quality and total-cost comparisons remain unmeasured.

An independent Jinja2 oracle compared the production Swift renderer against the pinned template in 30 synthetic cases: 24 renderings and six explicit rejections. Cases cover both thinking modes, role history, multilingual and decomposed Unicode, Unicode/ASCII whitespace, empty content, literal think tags, source excerpts, and template-looking strings. All 24 valid cases also matched the running server's reported prompt count to its `/tokenize` result. These live checks incurred 866 input and 24 output provider tokens. No prompts or generated answers were logged.

The optional verification script is [provider_admission_oracle.py](../Tests/provider_admission_oracle.py). It requires Jinja2 3.1.6 in a temporary development environment and compiles a driver against the production renderer. It adds no application dependency. Pass `--live` to repeat the synthetic provider comparison against `localhost:11234`.

## Limits and remaining work

The preflight and dispatch are separate provider requests. A server restart, configuration mutation, unload/reload, or resource change after the receipt may invalidate the observation. Final component admission rereads the model descriptor, server/template metadata and effective capacity under the same lease. Receipt age and terminal usage checks limit detected drift; they do not lock the external server configuration or attest model weights and the server binary. Reloads or replacements preserving all advertised metadata remain unobservable. The exact count contract depends on the verified rendering/tokenizer/calibration observations and terminal usage checks. An atomic provider-side count-and-reserve contract would provide a stronger guarantee.

The supported input is complete text role messages with the verified options. Generic compatibility fallback, tool/multimodal accounting, a GGUF exact-token adapter and remote processing remain unavailable. Episode enforcement covers the integrated Qwen answering path and its foreground preparation. Apple query-encoder and native input tokens remain unknown in development mode; strict known-input mode skips or rejects those operations. Native output without an authoritative token receipt keeps its output reservation held. Exact native admission and immutable native model/runtime identity remain unverified. Manual source browsing and current-source retrieval evaluation use separate scoped read episodes. Daily background indexing awaits its aggregate ledger; retrieval-only evaluation has no answering-token feasibility claim. Provider usage supplies evidence for subsequent evaluation; model quality, latency improvement and lower total cost remain unproven.

## Third-party template provenance

The test template originates from the [Qwen3.8 Flash Next MLX checkpoint](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit/tree/7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3), revision `7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3`, and is covered by the checkpoint's [Qwen Community License 1.0](https://huggingface.co/ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit/blob/7eaef0fa82b4c3bf5c64cec60ace4bf48fd271e3/LICENSE). Its copyright and permission notice are preserved in [qwen38-chat-template.LICENSE](../Tests/qwen38-chat-template.LICENSE), SHA-256 `a0dc422560841fd68e06d974907f8b4c709bca44a67daad2b528437bdf676c08`.

This is a conditional community license. It contains separate-license requirements for specified commercial model-service or AI work-assistant businesses and attribution conditions above stated scale thresholds. The current local internal-use prototype does not settle commercial distribution licensing. The copied template's license is separate from Boros-authored code and the imported GUI's provenance.
