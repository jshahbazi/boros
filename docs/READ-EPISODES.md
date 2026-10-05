# Standalone read episodes

Status: implemented and independently reviewed, October 4, 2026, with subsequent integration recorded in [STATUS.md](STATUS.md). The original schema-4 wave extended the schema-3 answering checkpoint (`22c3402`) to explicit read operations and bound metered entry points to the episode's project. Those origin contracts remain in schema 5, and the browser and current-source evaluation harness supply read leases. Daily background budgets and exact selected-Qwen recent/evidence token allocations are now integrated; registered measurement adoption and opaque Apple/native token observability remain pending.

## Episode origin and schema

Schema 4 represents an episode origin as either a chat binding or a local read binding. Project ID, frozen resource limits, continuous deadline, resource totals, work states, snapshots and receipts remain mandatory. Read episodes create no conversation, human/assistant source event or model invocation.

| Origin | Immutable binding |
|---|---|
| Chat | Conversation ID, turn ID and accepted human event ID |
| Local read | Initiator, purpose, stable request ID and bounded versioned request-descriptor digest |

The local initiators are human browser, local read CLI and synthetic evaluation. Initial purposes are search with its initial page, explicit source page, context selection and retrieval probe. A descriptor binds the project, purpose and relevant query/mode, source/range or context-selection options. Large context inputs use their complete digest. Origin labels record provenance; they confer no disclosure permission. These constructors remain internal to the trusted local host and synthetic harness.

`beginLocalReadEpisode(episodeID, projectID, binding, limits, clock)` atomically persists that operation before queueing or reading. Identical initiation replay returns the original receipt and deadline, including a terminal result. Changed scope, descriptor, origin or limits is a conflict. Automatic fallback and internal paging retain the initiating lease.

The pair of trusted initiator and request ID is globally unique for local reads. Reusing that pair under a different episode ID is a conflict, including after termination or a scope change. An indexed uniqueness constraint prevents an internal retry from acquiring another allowance.

Persist canonical, strictly decoded origin JSON. Its scope-bound digest is SHA-256 over the UTF-8 prefix `boros-episode-origin-v1`, a NUL, the project ID, another NUL and the canonical origin bytes. Origin and project changes require a new digest and still must satisfy the source/work/linkage invariants. This is an integrity binding within the local owner; it is not a credential or disclosure grant.

Read origins permit retrieval, source-read and query-embedding work. They cannot start answering invocations, calibration or native generative inference. Future answering evaluation needs an explicit origin/capture contract.

Migration rebuilds the episode parent table with mandatory origin JSON/digest and nullable chat columns. Chat origins require all three chat references; read origins require all three null. Schema-3 rows migrate to chat origins without changing accepted bytes, work IDs, snapshots, receipts or accounting. Foreign-key replacement occurs within the atomic migration boundary, and fresh and migrated schemas have identical canonical contracts. Exception and actual SIGKILL/reopen fixtures verify a complete old or new schema.

## Scope and delivery

The central `EpisodeLease.checkActive(projectID:)` assertion precedes source metadata, encoder inference and payload access in lexical/literal search, paging, context preparation, semantic search and replay. Context preparation also proves that its conversation belongs to the requested project. A genuine source ID in project B cannot be read with a project-A lease.

All identifiers use exact UTF-8 byte identity, matching SQLite's binary text comparison. Composed and decomposed Unicode project or request IDs remain distinct. Scope guards, immutable-origin replay, linkage and archive uniqueness checks must use that same identity; Swift's ordinary canonically equivalent string comparison is unsuitable here.

Carry the expected source digest and byte count through source paging. Check the source identity before returning bytes. Reconcile the authoritative terminal receipt before publishing a successful result. Budget-limited partial hits need an explicit partial-result status and no subsequent implicit reads; they cannot flow through the unrestricted-success path.

Resolve the reference's actual scoped metadata before payload access. A caller-provided project label with another project's genuine event ID and digest cannot authorize a read. Paging compares the immutable source identity, including its sequence when a complete reference is available.

For a local read origin, resource-limited raw search stops context or semantic preparation before implicit excerpt rereads, another search branch or query embedding. Such preparation fails with an explicit budget result. Browser search can publish limited hits with no automatic page. The existing answering path retains its separately declared partial-coverage behavior under the original allowance.

This scope binding implements the episode contract. Authenticated clients, separate read/disclosure/processing grants, control epochs and deletion remain subsequent contracts.

## Browser boundaries

| Human action | Read episode |
|---|---|
| Search button or Return | Search and automatically selected first page share one lease |
| Select another source | One explicit source-page episode |
| Next or Previous page | One explicit source-page episode |
| Automatic fallback, validation or internal paging | Continue the original lease |

Start the clock at the action before queueing. Move work off the main thread; assign a request generation ID, cancel superseded work and cancel on window close. Fence stale completions. A window's reading lifetime is not the operation deadline. Display incomplete coverage separately from no matches and require an explicit action to continue. Search continuations retain their original episode and need versioned ranking/scanner identity before external ingestion.

Keep the episode and deadline timer active while a result waits for its delivery queue. The final short ledger transaction runs at the delivery gate after generation validation; source work stays on the worker queue. Check generation and the continuous deadline again before the callback. A deadline crossed after durable completion suppresses source delivery without rewriting the terminal journal receipt. This publication gate can briefly wait for the store owner on the delivery queue.

The origin API reserves a local-read CLI initiator, but this wave adds no standalone read command. A future read CLI must obtain normal store ownership. Simultaneous multi-client access requires the later service boundary; a direct SQLite path cannot bypass the owner.

## Evaluation adoption

Begin one isolated read episode per fixture/protocol attempt. Pass it through context selection, both search branches and every source page. Keep gold verification and scoring outside the retrieval timer. Question/answer source capture remains disabled; only ledger metadata changes.

Record authoritative charged/held vectors, unknown input operations, terminal reason, total episode time, memory-path time and coverage limits. Every budget, deadline or terminal failure stays in its denominator. No hidden retry gets another episode. Distinguish resource-limited coverage from a fixed candidate window or semantic hole. Model feasibility, answering quality, billed cost and answer latency remain unknown without an answerer.

Coverage fields derive from structured scan, window and resource evidence. An informational notice that semantic recall is unavailable does not establish limited lexical coverage. Missing endpoint timings stay unknown when a budget prevents those endpoints from running.

Freeze a new development amendment and exact source hashes after implementation and the component-token contract stabilize. Preserve v4 reports, amendments and the original preregistration. Current unregistered contract checks supply implementation evidence only.

## Backup compatibility and fixtures

Backup recognition must preserve explicit schema 1–4 contracts. Validate origin digest/type, chat references, null read bindings, read-work restrictions and refusal of invocations linked to read origins. Report chat/read counts separately and verify their sum. Restore retains charges and unknown bounds, releases only prepared work, terminalizes interruption and performs no automatic read or inference replay. Legacy decoding must prove its absence of read episodes from the recognized schema.

Required fixtures cover unchanged source/conversation/invocation counts after reads; idempotent initiation without deadline renewal; cross-project rejection before inspection; generative-work refusal; actual SIGKILL around arming; Stop/supersession/close/deadline delivery fences; search plus first page sharing the last slot; altered source-identity rejection; cap failures retained in evaluation denominators; migration rollback/reopen; and malformed-origin/linkage archive rejection before publication.

| Owner | Surface |
|---|---|
| Ledger | Origin types, schema 4, lease scope assertion, durable lifecycle and kill fixtures |
| Backup | Explicit legacy recognition, origin inventory, integrity and restore |
| Browser | Local read coordinator, asynchronous browser actions and delivery tests |
| Retrieval integration | Scope assertions through search, context, semantic and replay entry points |
| Evaluation | Read leases, authoritative reports and contract fixtures; amendment after freeze |
| Coordinator | Shared interfaces, staged integration, status and verification |

Ledger, backup and browser implementation proceeded concurrently against the frozen origin and scope APIs; evaluation then adopted that ledger. Independent review reproduced Unicode scope aliasing, implicit rereads after limited coverage and notice-derived coverage flags. Exact byte comparisons, local-read coverage guards and structured evaluation flags close those findings; dedicated fixtures cover the triggers. Subsequent checkpoints integrated daily background-index budgets and exact selected-Qwen recent/evidence allocations. A new registered matched measurement configuration remains pending.
