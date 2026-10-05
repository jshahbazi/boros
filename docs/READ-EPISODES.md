# Standalone read episodes

Status: next implementation contract, October 4, 2026. The schema-3 answering checkpoint is `22c3402`. Manual source browsing and the retrieval evaluation harness still use nil-lease paths. This wave extends the existing ledger to explicit read operations and binds metered entry points to the episode's project.

## Episode origin and schema

Schema 4 will represent an episode origin as either a chat binding or a local read binding. Project ID, frozen resource limits, continuous deadline, resource totals, work states, snapshots and receipts remain mandatory. Read episodes create no conversation, human/assistant source event or model invocation.

| Origin | Immutable binding |
|---|---|
| Chat | Conversation ID, turn ID and accepted human event ID |
| Local read | Initiator, purpose, stable request ID and bounded versioned request-descriptor digest |

The local initiators are human browser, local read CLI and synthetic evaluation. Initial purposes are search with its initial page, explicit source page, context selection and retrieval probe. A descriptor binds the project, purpose and relevant query/mode, source/range or context-selection options. Large context inputs use their complete digest. Origin labels record provenance; they confer no disclosure permission. These constructors remain internal to the trusted local host and synthetic harness.

`beginLocalReadEpisode(episodeID, projectID, binding, limits, clock)` atomically persists that operation before queueing or reading. Identical initiation replay returns the original receipt and deadline, including a terminal result. Changed scope, descriptor, origin or limits is a conflict. Automatic fallback and internal paging retain the initiating lease.

Read origins permit retrieval, source-read and query-embedding work. They cannot start answering invocations, calibration or native generative inference. Future answering evaluation needs an explicit origin/capture contract.

Rebuild the episode parent table with mandatory origin JSON/digest and nullable chat columns. Chat origins require all three chat references; read origins require all three null. Migrate schema-3 rows to chat origins without changing accepted bytes, work IDs, snapshots, receipts or accounting. Handle SQLite foreign-key replacement deliberately; fresh and migrated schemas must have identical canonical contracts. Failure injection or kill/reopen must prove a complete old or new schema.

## Scope and delivery

Add a central `EpisodeLease.checkActive(projectID:)` assertion before source metadata, encoder inference or payload access. Adopt it in lexical/literal search, paging, context preparation, semantic search and replay. Context preparation still proves that its conversation belongs to the requested project. A genuine source ID in project B cannot be read with a project-A lease.

Carry the expected source digest and byte count through source paging. Check the source identity before returning bytes. Reconcile the authoritative terminal receipt before publishing a successful result. Budget-limited partial hits need an explicit partial-result status and no subsequent implicit reads; they cannot flow through the unrestricted-success path.

This scope binding implements the episode contract. Authenticated clients, separate read/disclosure/processing grants, control epochs and deletion remain subsequent contracts.

## Browser boundaries

| Human action | Read episode |
|---|---|
| Search button or Return | Search and automatically selected first page share one lease |
| Select another source | One explicit source-page episode |
| Next or Previous page | One explicit source-page episode |
| Automatic fallback, validation or internal paging | Continue the original lease |

Start the clock at the action before queueing. Move work off the main thread; assign a request generation ID, cancel superseded work and cancel on window close. Fence stale completions. A window's reading lifetime is not the operation deadline. Display incomplete coverage separately from no matches and require an explicit action to continue. Search continuations retain their original episode and need versioned ranking/scanner identity before external ingestion.

The read CLI must obtain normal store ownership. Simultaneous multi-client access requires the later service boundary; a direct SQLite path cannot bypass the owner.

## Evaluation adoption

Begin one isolated read episode per fixture/protocol attempt. Pass it through context selection, both search branches and every source page. Keep gold verification and scoring outside the retrieval timer. Question/answer source capture remains disabled; only ledger metadata changes.

Record authoritative charged/held vectors, unknown input operations, terminal reason, total episode time, memory-path time and coverage limits. Every budget, deadline or terminal failure stays in its denominator. No hidden retry gets another episode. Distinguish resource-limited coverage from a fixed candidate window or semantic hole. Model feasibility, answering quality, billed cost and answer latency remain unknown without an answerer.

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

Freeze origin and scope APIs first. Ledger, backup and browser work can then proceed concurrently; evaluation follows the ledger interface. Daily background-index budgets and matched recent/evidence token allocations remain active parallel contracts.
