# Boros implementation status

Status: native foundation implemented and verified, October 4, 2026. The product name is Boros; TraceChat remains the name of the historical design documents.

## First working slice

Build a native chat interface that can connect to the user's running MLX server, preserve accepted history across restart, assemble bounded context, search original sources, and open exact source content. The existing AppKit GUI makes Swift plus system SQLite a suitable initial implementation. A separate Python memory daemon is deferred until additional clients justify a service boundary.

Independent work proceeds concurrently under explicit file ownership:

| Work | Contract | Integration dependency |
|---|---|---|
| Evidence store | Typed events, scopes, full UTF-8 payloads, digest, capture status, stable IDs, SQLite transactions and exclusive owner lock | Shared Swift API |
| Context assembly | Preserve current request and host instructions, reserve recent messages, add bounded source excerpts with IDs | Evidence-store API |
| Chat GUI and transport | Persist accepted input before dispatch, stream local model output, recover conversations and drafts, authenticate without storing keys in history | Store and context contracts |
| Verification and documentation | Synthetic failure fixtures, restart checks, source provenance, accurate release boundary | Built integrated app |

Parallel work does not remove shared-state constraints. Database ownership and the local model's request capacity remain serialized where required.

## Storage boundary

The first store accepts bounded text payloads, retained completely as SQLite BLOBs with SHA-256 digests. A payload above the explicit acceptance limit is rejected. This avoids introducing separate database/file commit recovery before the text-only prototype needs external payload files. Preview and prompt budgets do not truncate the stored source.

SQLite uses WAL and synchronous FULL on a local filesystem. The process holds an exclusive owner lock. The store and runtime state live outside the checkout with private filesystem permissions. Tests must cover reopen, idempotency, scope filtering, full payload recovery, UTF-8 paging, and refusal of a second owner.

This does not yet implement the plan's external-blob protocol, import adapters, backup/restore workflow, retention, purge, migrations across released versions, or global control epoch. Control mutations and external actions remain unavailable in this slice.

Human input commits before model dispatch. Assistant output commits on completion, cancellation, or a reported transport failure with the appropriate capture status. Abrupt process termination before that callback can lose in-flight assistant fragments; streamed text is not yet journaled incrementally. Filesystem permissions protect ordinary local access; the database is not encrypted.

## Retrieval and context boundary

Start with literal and FTS5 lexical search over accepted text. Search results identify original events and expose exact source reads. Semantic indexing and the optional summary tree require subsequent implementation and measured comparisons.

Recent context and historical evidence have separate bounds. Historical excerpts are marked as evidence and remain user-content material. A stored assistant reply has assistant authorship; it does not become human authority. Partial responses retain their capture status.

The initial assembler measures serialized message bytes. This is an operational bound, not the plan's provider-token admission contract. Exact tokenizer admission, full request-envelope accounting, durable invocation snapshots, and evaluation budgets are subsequent work. Provider context errors must remain visible.

## Model boundary

The selected model is `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`, already running in mlx-serve. Its model card describes an MLX Serve-specific package; no conversion or download is required for connecting to the running server.

The user supplied `http://localhost:11234/v1/`. Its `/v1/models` response returned the requested model ID without authentication. The app defaults to that base address and ID; it can store optional server credentials in Keychain. Observed open ports alone are not configuration evidence. The client sends structured role messages and lets the server apply the model's chat template.

For the confirmed Qwen model, Request thinking forwards `enable_thinking`; it starts off. The API has no implemented thinking-budget control. Other served model IDs retain server defaults for reasoning. Temperature, seed, and output cap are sent; unsupported sampling and GGUF context controls are disabled for API mode.

HTTP transport accepts loopback destinations only, rejects redirects, handles SSE boundaries and terminal states, and supports client cancellation. Cancellation closes the client request; it does not establish that the external server immediately stops model computation. API keys belong in macOS Keychain, never the SQLite store or repository. The app performs no external tool actions.

## Deferred contracts

The complete [plan](../tracechat-plan.md) remains the target architecture. The following are not established by the initial native prototype:

- A standalone multi-client memory service, read-only MCP interface, and authenticated import API.
- Task lifecycle, scoped policy mutation, transitive processing grants, and deletion/revocation fencing.
- External-action execution and recovery journals.
- Semantic retrieval, asynchronous indexing coverage, optional summary-tree construction, and reproducible frontiers.
- Physical purge, safe backup/restore, and retention management.
- Model-quality, total-cost, latency, or comparative recall claims.

## Verification record

The following checks passed against the final native foundation:

| Check | Verified result |
|---|---|
| `python3 scripts/check.py` | 183 checks: 51 conversation/profile/message, 57 GUI, 9 inherited native parser, 31 memory, 19 endpoint parser, 16 loopback HTTP integration |
| `python3 scripts/test_memory.py` | 32 checks, including the additional separate-process store-lock test |
| `codesign --verify --strict --deep .build/boros/Boros.app` | Development bundle signature valid |
| Live Qwen CLI arithmetic | Two turns passed: `17 + 25` produced `42`; adding one to the prior answer produced `43` |
| Live Qwen GUI flow | `2 + 2` produced `4`; the follow-up asking to add two produced `6`; all four human/assistant events were committed complete in the same conversation |

Synthetic HTTP fixtures exercise authenticated exact role-message transmission, split UTF-8/CRLF records, HTTP rejection, SSE errors, incomplete EOF, output length termination, redirect refusal, malformed JSON, and cancellation. UI fixtures exercise source paging, draft validation recovery, distinct incomplete-response capture, and actual store/delegate reopen restoration.

The live CLI smoke command was:

```sh
.build/boros/Boros.app/Contents/MacOS/Boros --smoke-test --profile custom-local --api-address http://localhost:11234/v1/ --served-model ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit --max-response 64
```

An initial standalone 30-second synthetic HTTP request timed out before response headers. Later integrated CLI and GUI requests succeeded. No server restart or model download was performed. These arithmetic checks establish basic integration and history forwarding, not general model competence, archive recall, or latency reliability.

The app was opened and visually inspected. The Mac locked during the follow-up visual observation; its complete result was verified through a read-only check restricted to the synthetic conversation created for this test. No private chats were imported or examined. A subsequent UI-control correction was verified by the rebuilt automated suite; its final visual recheck remains pending.

Independent review identified an oversized-draft validation path that permanently disabled Send. The implementation now recovers when the draft is shortened, and the GUI suite covers the input-notification path. No additional material first-slice issues were reported in the reviewed scope, persistence, evidence-role, redirect, cancellation, or stream-terminal paths. This review does not establish the deferred architecture contracts.
