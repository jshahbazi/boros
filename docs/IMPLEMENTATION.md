# Boros implementation status

Status: native foundation and shared episode accounting implemented and verified, October 4, 2026. The product name is Boros; TraceChat remains the name of the historical design documents. The complete architecture remains in progress.

## First working slice

The current working slice provides a native chat interface that connects to the user's running MLX server, preserves accepted history across restart, assembles bounded context, searches original sources, and opens exact source content. The existing AppKit GUI makes Swift plus system SQLite a suitable initial implementation. A separate Python memory daemon is deferred until additional clients justify a service boundary.

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

The invocation journal commits each received visible-text chunk before the GUI displays it. Finalization atomically publishes the assistant event and lexical index. Exclusive-owner startup recovers unfinished attempts as partial or failed, retaining committed chunks. Main-store schema 3 migrates prototype schemas 1 and 2 and adds durable episodes, resource totals, work records and deduplicated credential-free request snapshots. Existing schema 2 invocations retain nullable episode linkage and remain unmetered historical records. Exact request bytes, provider identity, admission/accounting metadata and final usage remain private invocation evidence. Chunk and terminal retries are idempotent; conflicting or late writes are rejected. A linked complete invocation requires a completed episode; backup verification enforces that relationship too.

Human input commits before admission or dispatch. Network bytes that were never delivered, callbacks that did not reach their durable commit, and a failed commit cannot be recovered. Filesystem permissions protect ordinary local access; the database is not encrypted. Invocation snapshots duplicate some source content, so future deletion, retention and backup work must include these records and stream chunks.

## Episode and coordinator boundary

Ordinary Send and the synthetic CLI smoke workflow commit the accepted human event and a frozen [episode allowance](EPISODE-BUDGET.md) together before context preparation. One `EpisodeLease` spans recent-source reads, evidence preparation, foreground retrieval, provider discovery, tokenization, calibration, admission retries and answering. Aggregate resources include known model input tokens, output reservations, model calls, HTTP attempts, memory operations and declared source/vector/metadata work. Repeated and cached prompt input still counts; calibration and answering consume the same allowance. A boot-scoped continuous Mach clock enforces the shared deadline across queueing, sleep, preparation and generation.

Work reserves capacity durably before dispatch. Arming charges declared non-output work and holds output headroom before a short serialized handoff starts the operation. Expensive reads, model execution and network waits run outside that handoff's owner lock and transaction. Stop fences new reservations and handoffs; SQLite VM progress callbacks consult an independent clock and local cancellation signal without reentering the owner. Prepared work can release its unused reservation. Armed or submitted work with unknown usage retains its charges and output hold across cancellation, process death, reopen and restore. Late authoritative usage can settle a hold without reopening the episode. Separately established model or usage violations quarantine the stable adapter identity even when token usage is unavailable.

The coordinator resolves capture status from the authoritative finish receipt. Deadline or budget exhaustion during finalization preserves committed output as partial. During native Stop, Send remains disabled until the owned process and pipe readers finish. Native pipe reads publish short flushed prefixes through bounded `Darwin.read` calls. Delayed timeout and kill closures hold weak references so finished jobs do not keep the store owner alive.

Apple query embeddings and native GGUF/Bonsai input tokens remain unobservable. Development mode records unknown input operations while charging model calls and encoder input bytes where applicable; strict known-input mode skips an uncountable query encoder or rejects native inference. Native output lacks an authoritative token receipt and keeps its reserved output bound held. This work does not establish complete token enforcement for those adapters or exact native admission. Manual source-browser actions, daily background indexing budgets and matched evaluation adoption remain pending. Recent and evidence component limits still use byte bounds; their proposed token caps are not frozen or enforced.

## Retrieval and context boundary

Literal and FTS5 lexical search identify original events and expose exact source reads. A private [semantic sidecar](SEMANTIC-RETRIEVAL.md) now adds a pinned installed Apple English sentence encoder, resumable jobs, complete-source SHA-256 sealing, explicit coverage holes and replayable manifests. The optional summary tree remains gated by measured comparisons.

Ordinary Send selects up to eight unique alphanumeric terms after removing common English filler words, then combines scoped any-term lexical matches with eligible semantic chunks. Recent/current sources are excluded in SQL before candidate limits. Query and indexing support are conservative English heuristics; unsupported, unavailable or failed semantic paths retain lexical retrieval. The complete current request remains intact. Automatic Send skips full-archive literal scanning; manual search retains literal and all-term lexical modes. Query selection can miss distinctive terms late in a long request or choose irrelevant sources; general long-chat memory quality remains unproven.

Recent context and historical evidence have separate bounds. Historical excerpts are marked as evidence and remain user-content material. A stored assistant reply has assistant authorship; it does not become human authority. Partial responses retain their capture status.

The assembler still bounds serialized message bytes. The selected-Qwen admission adapter counts the exact provider-rendered prompt separately and reserves response tokens plus a safety margin against the configured and observed server limits. Optional evidence and recent history can be removed and re-counted when token admission fails; mandatory host instructions and the complete current request remain intact. A canonical request builder supplies the same credential-free body for admission, journaling and HTTP dispatch. Each retry uses the same episode allowance. Durable work and snapshots retain preflight charges, calibration usage and unknown outcomes across termination.

The GUI answer path supplies recent history and hybrid archive excerpts through `ChatContextPreparation`. Exact source metadata and bytes are revalidated before framing excerpts as quoted user content. Token reduction preserves the complete mandatory request and audits only actually delivered historical ranges. The authoritative invocation journal retains a bounded content-free retrieval/delivery audit, ordered recent-source ID digest/count, manifest ID, frontiers and configuration fingerprints. The full search manifest remains in the derived sidecar; its replay ID is unavailable after a backup restore that excludes that sidecar. Exact dispatched request bytes and delivered historical references survive restore.

The metered foreground path fetches scoped lexical metadata before loading matching payloads, reserves conservative load/digest/matching passes and reads one complete candidate at a time. Its literal adapter uses bounded UTF-8 page traversal and byte matching. Source validation, recent history, semantic query inference, vector/metadata inspection and manifest replay accept the same lease. Raw-work charges describe conservative logical source passes; they do not measure physical disk I/O or internal Foundation comparison work. Continuations preserve their frontier and candidate ordering, and metered raw continuations are bound to the originating episode. Ranking/scanner version contracts still require tightening before continuations can be accepted from external clients.

Archive search remains available through the source browser, whose current UI does not supply an episode lease. Daily background indexing also has no aggregate budget. The [evaluation specification](EVALUATION.md) distinguishes historical recent-only/AND-query diagnostics, targeted queries, original-source probes and the lexical-only helper branch (`semanticIndex:nil`). That harness still runs without an episode lease; installed-index hybrid quality remains unmeasured. Current-source diagnostic mode is unregistered, and default evaluation refuses drift from the immutable v4 baseline.

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
- Episode adoption by manual source browsing and matched evaluation, frozen recent/evidence token caps, and complete native/encoder token observability.
- External-client continuation contracts, including explicit ranking/scanner version compatibility.
- Physical purge, retention management and deletion-aware restore.
- Model-quality, total-cost, latency, or comparative recall claims.

## Verification record

The integrated episode wave passed `python3 scripts/check.py`: **793 checks** comprising 67 episode, 51 conversation/profile, 89 GUI, 9 native parser, 100 memory, 49 endpoint/admission, 64 context, 76 semantic, 99 backup/CLI and 189 HTTP integration checks. The standalone episode suite passed 86 checks including real SIGKILL recovery; standalone memory passed 100 main checks plus eight recovery checks; standalone backup passed 110 checks. Semantic recovery passed six separate-process checks, and evaluation contracts passed 45 tests. Counts overlap across suites. The rebuilt development bundle passed strict deep signature verification.

Independent review reproduced and closed missing-usage calibration quarantine, premature complete publication, deadline finalization, native Stop/restart lifetime retention, short native pipe-prefix buffering and recovered-cancellation backup compatibility. Fixtures exercise actual coordinator capture, an owned synthetic child that ignores SIGTERM, SQLite VM interruption while the owner mutex is held, private identity proof followed by late usage, recovered empty/partial cancellations, and corruption with refreshed archive hashes. These results establish the tested prototype contracts; the deferred architecture and workload-quality gates remain open.

The current built bundle also passed two synthetic arithmetic turns against the running mlx-serve instance. The final turn reported a completed episode, 218 charged input tokens, three charged output tokens, zero held output tokens, two model calls, seven HTTP attempts, 94 bytes of logical raw-source work and zero unknown input operations. These are the final turn's counters, not two-turn totals. The CLI used and cleaned a temporary synthetic store and printed no prompt or response text. This establishes basic local integration. The latest visual GUI recheck and model-quality evaluation remain pending.

### Historical checkpoints

The first implementation wave passed `python3 scripts/check.py`: 324 checks (51 conversation/profile/message, 75 GUI, 9 native parser, 81 memory, 44 endpoint/provider admission, 19 context reduction/settings compatibility, 45 loopback HTTP integration). The standalone memory suite also passed its separate-process owner and real SIGKILL/reopen checks. The rebuilt development bundle passed strict deep signature verification. The live mlx-serve CLI passed both arithmetic turns after exact admission was enabled.

An independent integration review found and closed a partial-output cancellation status mismatch and a native request/snapshot mismatch. The current source uses matching generation IDs to fence stale callbacks. The provider renderer passed 30 independent oracle cases and 24 live count comparisons across both thinking modes, Unicode boundaries and literal template markup. See [provider admission](PROVIDER-ADMISSION.md) for the pinned source, license, calibration costs and compatibility limits.

The earlier durable capture/retrieval/backup checkpoint passed 478 combined checks: 51 conversation/profile, 78 GUI, 9 native parser, 95 memory, 44 endpoint/admission, 37 context, 60 semantic, 59 backup/CLI and 45 HTTP integration. Independent review reproduced and closed recent-source candidate starvation, unrelated SQLite source mutation during CLI backup and residual boolean coercion in evaluation helpers. At that checkpoint, standalone memory passed 103 checks, backup/CLI passed 60 including real SIGKILL, semantic recovery passed six process-kill checks on two reopens, and evaluation contracts passed 41 tests. The v4 development source report remains frozen. Counts overlap. That bundle passed strict deep signature verification and live arithmetic dispatch.

The initial native foundation had the following results before the later integration waves:

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
