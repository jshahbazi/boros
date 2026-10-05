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

This does not yet implement the plan's external-blob protocol, import adapters, retention, purge, migrations across released versions, or global control epoch. Control mutations and external actions remain unavailable in this slice. The [backup/restore component](BACKUP-RESTORE.md) now supplies consistent online SQLite snapshots, complete-source/journal verification, private no-clobber publication and restore recovery. File-menu and CLI entry points expose it. Settings are captured independently after the database snapshot; the semantic sidecar is derived and rebuilds after restore. Current deletion authority accepts only stores without deletion controls; enabling deletion requires external-ledger application before restored content can be published.

The invocation journal commits each received visible-text chunk before the GUI displays it. Finalization atomically publishes the assistant event and lexical index. Exclusive-owner startup recovers unfinished attempts as partial or failed, retaining committed chunks. Schema version 2 upgrades existing version 1 stores. Exact request bytes, provider identity, admission/accounting metadata and final usage are retained as private invocation evidence. Chunk and terminal retries are idempotent; conflicting or late writes are rejected. Combined checks and real process-kill recovery passed; the historical foundation results below predate this work.

Human input commits before admission or dispatch. Network bytes that were never delivered, callbacks that did not reach their durable commit, and a failed commit cannot be recovered. Filesystem permissions protect ordinary local access; the database is not encrypted. Invocation snapshots duplicate some source content, so future deletion, retention and backup work must include these records and stream chunks.

## Retrieval and context boundary

Literal and FTS5 lexical search identify original events and expose exact source reads. A private [semantic sidecar](SEMANTIC-RETRIEVAL.md) now adds a pinned installed Apple English sentence encoder, resumable jobs, complete-source SHA-256 sealing, explicit coverage holes and replayable manifests. The optional summary tree remains gated by measured comparisons.

Ordinary Send selects up to eight unique alphanumeric terms after removing common English filler words, then combines scoped any-term lexical matches with eligible semantic chunks. Recent/current sources are excluded in SQL before candidate limits. Query and indexing support are conservative English heuristics; unsupported, unavailable or failed semantic paths retain lexical retrieval. The complete current request remains intact. Automatic Send skips full-archive literal scanning; manual search retains literal and all-term lexical modes. Query selection can miss distinctive terms late in a long request or choose irrelevant sources; general long-chat memory quality remains unproven.

Recent context and historical evidence have separate bounds. Historical excerpts are marked as evidence and remain user-content material. A stored assistant reply has assistant authorship; it does not become human authority. Partial responses retain their capture status.

The assembler still bounds serialized message bytes. The selected-Qwen admission adapter counts the exact provider-rendered prompt separately and reserves response tokens plus a safety margin against the configured and observed server limits. Optional evidence and recent history can be removed and re-counted when token admission fails; mandatory host instructions and the complete current request remain intact. A canonical request builder supplies the same credential-free body for admission, journaling and HTTP dispatch. Completed preflight attempts retain calibration usage and unknown outcomes. Total episode budget enforcement and durable accounting across termination during preflight remain subsequent work.

The GUI answer path supplies recent history and hybrid archive excerpts through `ChatContextPreparation`. Exact source metadata and bytes are revalidated before framing excerpts as quoted user content. Token reduction preserves the complete mandatory request and audits only actually delivered historical ranges. The authoritative invocation journal retains a bounded content-free retrieval/delivery audit, ordered recent-source ID digest/count, manifest ID, frontiers and configuration fingerprints. The full search manifest remains in the derived sidecar; its replay ID is unavailable after a backup restore that excludes that sidecar. Exact dispatched request bytes and delivered historical references survive restore.

Archive search is also available through the source browser. The [evaluation specification](EVALUATION.md) distinguishes historical recent-only/AND-query diagnostics, targeted queries, original-source probes and the lexical-only helper branch (`semanticIndex:nil`). The installed-index hybrid GUI path remains unmeasured. Lexical excerpt selection currently loads whole matching payloads; candidate count and final excerpt bounds do not establish a raw-byte episode budget. Manual literal scans and daily background indexing work also lack total-work accounting.

## Model boundary

The selected model is `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`, already running in mlx-serve. Its model card describes an MLX Serve-specific package; no conversion or download is required for connecting to the running server.

The user supplied `http://localhost:11234/v1/`. Its `/v1/models` response returned the requested model ID without authentication. The app defaults to that base address and ID; it can store optional server credentials in Keychain. Observed open ports alone are not configuration evidence. The client sends structured role messages and lets the server apply the model's chat template.

For the confirmed Qwen model, Request thinking forwards `enable_thinking`; it starts off. The API has no implemented thinking-budget control. Other served model IDs retain server defaults for reasoning. Temperature, seed, and output cap are sent; unsupported sampling and GGUF context controls are disabled for API mode.

HTTP transport accepts loopback destinations only, rejects redirects, handles SSE boundaries and terminal states, and supports client cancellation. Cancellation closes the client request; it does not establish that the external server immediately stops model computation. API keys belong in macOS Keychain, never the SQLite store or repository. The app performs no external tool actions.

The exact admission adapter is restricted to the verified Qwen text template and mlx-serve version. Unknown models/templates/versions fail explicitly. Final server usage must agree with the admitted prompt count. Compatibility with an arbitrary OpenAI-style endpoint is not established by this adapter. Native GGUF snapshots now share the actual structured request builder, or record the process arguments and stdin for Bonsai; native token admission and immutable model/runtime identity are still unverified.

## Deferred contracts

The complete [plan](../tracechat-plan.md) remains the target architecture. The following are not established by the initial native prototype:

- A standalone multi-client memory service, read-only MCP interface, and authenticated import API.
- Task lifecycle, scoped policy mutation, transitive processing grants, and deletion/revocation fencing.
- External-action execution and recovery journals.
- General semantic retrieval quality, complete-corpus interactive scan coverage, optional summary-tree construction and daily background budgets.
- Physical purge, retention management and deletion-aware restore.
- Model-quality, total-cost, latency, or comparative recall claims.

## Verification record

The first implementation wave passed `python3 scripts/check.py`: 324 checks (51 conversation/profile/message, 75 GUI, 9 native parser, 81 memory, 44 endpoint/provider admission, 19 context reduction/settings compatibility, 45 loopback HTTP integration). The standalone memory suite also passed its separate-process owner and real SIGKILL/reopen checks. The rebuilt development bundle passed strict deep signature verification. The live mlx-serve CLI passed both arithmetic turns after exact admission was enabled.

An independent integration review found and closed a partial-output cancellation status mismatch and a native request/snapshot mismatch. The current source uses matching generation IDs to fence stale callbacks. The provider renderer passed 30 independent oracle cases and 24 live count comparisons across both thinking modes, Unicode boundaries and literal template markup. See [provider admission](PROVIDER-ADMISSION.md) for the pinned source, license, calibration costs and compatibility limits.

The final frozen integration passed 478 combined checks: 51 conversation/profile, 78 GUI, 9 native parser, 95 memory, 44 endpoint/admission, 37 context, 60 semantic, 59 backup/CLI and 45 HTTP integration. Independent review reproduced and closed recent-source candidate starvation, unrelated SQLite source mutation during CLI backup and residual boolean coercion in evaluation helpers. The standalone memory suite passes 103 checks; backup/CLI passes 60 including real SIGKILL; semantic recovery passes six process-kill checks on two reopens. Evaluation contracts pass 41 tests and the v4 development source report is frozen. Counts overlap. The final bundle passed strict deep signature verification; live arithmetic dispatch also passed after integration. The latest visual GUI recheck remains pending.

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
