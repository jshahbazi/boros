# Durable episode budgets and preflight accounting

Status: GUI/CLI answering, standalone source browsing, synthetic evaluation reads, metered core retrieval, selected-Qwen component limits and schema-6 backup integration are implemented, verified October 5, 2026. Evidence is recorded in [STATUS.md](STATUS.md). Separate [background-index budgets](BACKGROUND-INDEX-BUDGET.md) were introduced in schema 5 and retained in schema 6. The complete phase 0/2 contract remains partial: exact opaque-adapter token accounting and a registered matched measurement configuration remain pending. Service, policy mutation, deletion, external actions and the optional summary tree remain separate work.

## Gaps motivating this wave

At checkpoint `38675c5`, the selected Qwen adapter admitted an exact request against its provider context limit. Its completed-attempt counters, calibration usage and unknown-calibration flag remained in process memory until the GUI journaled the answering invocation. A process death during preflight could leave accepted human input without a durable preflight attempt or usage reservation.

Context overflow could initiate another admission operation with another 45-second preflight bound; the answer transport had its own timeout. Those attempts lacked a shared durable deadline and aggregate work allowance. Stop could cancel the client transport without proving that an already submitted calibration or answer stopped computing on the server.

The current answering implementation persists one episode per accepted top-level request, containing preflight, retrieval and answering work. Standalone browser actions and each declared synthetic evaluation protocol attempt create read episodes without accepting chat input. Both origins reserve capacity before execution and durably arm handoffs. Restart preserves spent and uncertain capacity, terminalizes interrupted episodes and never resumes requests automatically. GUI and CLI answering, the source browser and evaluation reads share this counter model.

## Development resource contract

An answering episode begins at human submission, before context preparation or model discovery, and ends at a final answer, terminal error, Stop, interruption or its deadline. A browser read begins at the human action, before durable initiation and worker queue wait, and ends at its delivery gate or terminal outcome. An evaluation read begins before its protocol attempt and ends before oracle scoring. Automatic context reductions, reformulations, fallbacks and retries retain the same episode ID. An explicit new human action creates a new episode; an implementation must not disguise an automatic retry as a fresh episode to replenish quotas.

The plan and `preregistration-v1.json` already propose these aggregate limits:

| Resource | Initial episode cap | Charge definition |
|---|---:|---|
| Model input | 1,000,000 tokens | The full provider-rendered input for every model attempt, including repeated/cached prefixes and calibration. A cached prefix remains input work. |
| Model output | 16,000 tokens | All reported generated output, including reported reasoning. Reserve a supported upper bound before dispatch. |
| Model calls | 12 | Every inference attempt, including calibration, planning, reranking and query embedding; no successful-answer-only counter. |
| Memory operations | 24 | Host-facing search, source paging, neighbor lookup, context reconstruction and other logical retrieval operations. |
| Raw source work | 256 MiB | Payload bytes loaded or examined, including unsuccessful candidates, validation and repeated reads; define the accounting version below. |
| Wall time | 120 seconds | Submission through terminal outcome, including capture, queueing, retrieval, preflight, answering and finalization. |

The implementation also caps provider HTTP attempts at 64, vector work at 64 MiB, metadata rows at 100,000 and encoder input bytes at 49,152. Discovery and tokenization consume HTTP attempts. Existing per-request body/response limits still apply. These auxiliary limits and `raw_work_v1` need a development protocol amendment before registered measurement; do not rewrite the original preregistration. The Swift limit version is `development-episode-v1`.

The implementation also bounds authoritative journal growth to 100,000 work records and 64 MiB of distinct request-snapshot bytes referenced by one episode. Identical idempotent retries add no rows or snapshot charge. These are fixed auxiliary guards, independent of source-read work; shared identical snapshots are stored once. They require inclusion in the next frozen development configuration.

Per-request admission remains mandatory. The current provider limit, safety margin and response reserve must fit together even when ample episode budget remains. Output headroom must not be silently reduced to make an episode pass. If an explicit smaller output request is supported, create and admit a new canonical body within the same episode and retain the previous attempt's accounting.

The recent-context token cap remains null in the original frozen decision sheet. The implemented `selected-model-context-components-v1` policy independently counts at most 8,000 recent tokens and 12,000 evidence tokens with the pinned answering tokenizer over actual role/capture/source framing. Whole-request admission counts the complete provider rendering separately. These component limits preserve all provider-envelope checks; registered comparison adoption needs a new development amendment. Independent selected-Qwen materialization guards are 180,000 recent bytes, 131,072 framed evidence bytes, 256 recent candidates, 16 spans and 4,096 bytes per span. They bound allocation and do not estimate tokens. See [CONTEXT-COMPONENTS.md](CONTEXT-COMPONENTS.md) for reduction, receipt and journal contracts.

### Observable and unsupported usage

`ProviderUsage.completionTokens` already contains any `reasoningTokens` reported as its subset. Do not add the reasoning field again. An adapter whose output cap excludes hidden reasoning must supply a verified bound for that extra generation before the output reservation can be treated as complete. Unknown output is not zero, and visible UTF-8 bytes are not a substitute for billed tokens.

The Apple sentence encoder performs inference but does not currently expose its model tokenizer or token usage. Count each query encoding as a model call, record its exact input byte count and encoder identity, and mark its model input tokens unknown. The native GGUF/Bonsai paths also lack verified exact input admission. Neither path can be included in a claim that all model input tokens satisfy the plan's aggregate cap until it has a supported count or a documented adapter-specific conservative bound. The strict token-budget path must fail closed or use lexical retrieval when an uncountable query encoder is required. A separately labeled observable-budget mode can retain that encoder, but must not claim complete token accounting. Choosing a common normalization tokenizer for otherwise opaque encoders would change the resource estimand and needs an explicit frozen contract; it is not actual encoder usage.

Background index construction is a maintenance job with its own limits and cost record. It is not free. Charge construction to the production trajectory once under the evaluation's amortization rules. If an episode explicitly waits for index construction, charges that job as a synchronous retrieval repair, or performs a query embedding, the attributable interactive work and elapsed time also belong to that episode. Do not launch unmetered synchronous indexing under a background label.

## Persisted schema and API

The owner-controlled SQLite database now uses schema 6, retaining the schema-5 background inventory and adding a dormant authority-state foundation independent of episode revisions. Canonical chat/local-read origins were introduced in schema 4. Migration preserves exact stored chat identifiers and existing journal bytes, charges and holds; genuine prototype schemas 1–5 upgrade without invented historical episodes or background charges. The journal is private runtime evidence and belongs in verified archives. [Backup recognition and restore](BACKUP-RESTORE.md) use separate historical schema contracts and validate current read origins and background accounting.

| Record | Required fields and constraints |
|---|---|
| `episodes` | Stable ID, project ID, canonical `origin_json` plus project-bound `origin_digest`, creation time, deadline clock domain and ticks, display-only UTC creation time, frozen limit JSON plus digest/version, state, terminal reason, budget revision. Chat origins retain conversation/turn/human-event IDs; read origins require all three links to be null. Stored states: `active`, `completed`, `failed`, `cancelled`, `interrupted`, `deadlineExceeded`, `budgetExceeded`. |
| `episode_work` | Stable operation ID, episode FK, parent operation ID, kind, adapter identity, request JSON plus digest, request-snapshot reference, frozen reservation, charged/held resource vectors, nullable observed usage, receipt ID/JSON/digest, lifecycle revision, start/end/arming ticks and recovery/adapter-violation flags. Unique stable IDs make identical replay safe and changed replay a conflict. |
| `episode_resource_totals` | Episode/resource key, charged units, held units and cap. Integers are nonnegative and checked for overflow. A transaction updates every requested resource together; no partial reservation. |
| `episode_request_snapshots` | Canonical credential-free candidate/calibration body, SHA-256, renderer version and bytes. Reuse one snapshot for repeated counts of the identical body. Tokenizer attempts can reference that body/render digest rather than duplicate the rendered prompt. |
| Invocation linkage | `episode_id` and answering-work ID link chat invocations. Read origins cannot link invocations. Old schema 2 records remain explicitly unmetered historical invocations. |

`EpisodeOrigin` distinguishes versioned chat and `localRead` origins. A read binding contains the initiator (`humanBrowser`, `localReadCLI` or `syntheticEvaluation`), purpose, stable request ID, descriptor version and descriptor SHA-256. Strict decoding rejects unknown keys, kinds, versions and malformed bindings; canonical re-encoding rejects duplicate keys and altered byte representation. Equality preserves exact UTF-8 identifiers, including Unicode normalization distinctions. An indexed unique initiator/request-ID pair identifies one allowance across projects and episode IDs. Identical replay of an existing episode returns its receipt; changed scope, binding or limits conflicts. Read episodes admit only retrieval, source reads and query embedding with zero output reservation, and create no conversations, events or invocations.

Do not pack the complete episode journal into every invocation's bounded admission JSON. Store compact episode/work/snapshot references and the admitted request receipt there. Keep complete accounting in the episode tables. Request bodies remain private evidence; credentials and HTTP authorization headers remain outside SQLite.

The owner implements these typed ledger interfaces; `EpisodeLease` wraps them for adapters:

```swift
acceptRequestAndBeginEpisode(conversationID, turnID, humanEventID, episodeID, text, limits, clock) -> EpisodeReceipt
beginLocalReadEpisode(episodeID, projectID, binding, limits, clock) -> EpisodeReceipt
reserveEpisodeWork(episodeID, request, clock) -> EpisodeWorkRecord
armEpisodeWork(episodeID, operationID, expectedRevision, clock) -> EpisodeWorkRecord
performEpisodeHandoff(episodeID, operationID, expectedRevision, clock, start) -> EpisodeWorkRecord
settleEpisodeWork(episodeID, operationID, settlement, clock) -> EpisodeWorkRecord
finishEpisode(episodeID, reason, clock) -> EpisodeReceipt
episodeReceipt(id, clock) -> EpisodeReceipt
```

`acceptRequestAndBeginEpisode` commits complete accepted human content and the episode together before context preparation. A mandatory context overflow retains that input and terminalizes the episode. The storage limit remains a separate explicit acceptance limit. Every resource mutation runs under the existing serialized owner transaction. An idempotent receipt does not charge twice; a conflicting receipt or operation replay fails.

The coordinator supplies an `EpisodeLease` to all provider/retrieval adapters. It exposes reservation and cancellation/deadline checks, rather than permitting an adapter to reset its own counter. A budget revision fences late work callbacks. This revision is solely a budget lifecycle mechanism and provides no policy/deletion authority or control-epoch guarantee.

## Reservations, dispatch and unknown outcomes

Use the following work transitions:

| State | Reservation and recovery rule |
|---|---|
| `prepared` | Intent and capacity are committed; handoff has not been armed. Capacity can be released after cancellation or restart establishes this state never dispatched. |
| `dispatch_armed` | Durable before network handoff or inference start. A crash can fall on either side of handoff. Recover as unknown, retain the call charge and uncertain capacity. |
| `submitted` | Client transport acknowledged submission. This still does not establish server computation or final usage. |
| `completed` | A valid terminal receipt settles held output/other capacity using observed usage. |
| `failed_confirmed` | Preserve attempts and work already incurred. Release only capacity whose nonuse the adapter actually establishes. |
| `outcome_unknown` | Observed usage stays null. Keep the supported reservation upper bound charged/held for admission; show unknown actual cost. |
| `cancelled_before_dispatch` | Host established no handoff; release unused held capacity. Source capture and prior operations remain recorded. |

Admission checks `charged + held + newReservation <= cap` for every resource in one transaction. Arming commits the model-call slot and known prompt-input charge; output headroom remains held until a valid terminal usage receipt. Reports distinguish observed usage, conservative budget charges and unresolved reservation bounds. An unknown reservation is not evidence that those tokens were generated or billed.

Before a calibration generation, the adapter has already counted its exact synthetic prompt. Persist that count, one model-call reservation and its one-token output reserve before arming the POST. Before the final answer, reserve the exact admitted prompt and the full output cap in the same way. Discovery/tokenizer requests reserve their HTTP attempt and existing bounded response capacity before `resume()`, even though they are not generative model calls. Their failure or cancellation records incurred HTTP/tokenization work; they do not erase preceding calibration costs.

Context reductions produce new body digests and new tokenizer attempts under the same episode. The selected mlx-serve adapter calibrates once per independent preparation operation or component session. Reductions reuse that session's verification within its original validity period and retain every performed calibration charge. Receipts bind endpoint, the validated model-observation descriptor, template/server and thinking mode; model-instance identity is explicitly unobservable. Response-time `created` values do not identify a model load. Legacy epoch fields remain compatibility data. A restart does not interpret a previously prepared probe as a completed calibration. Receipt expiry or observed identity changes require fresh admission and consume the same remaining allowance.

Detected model/count violations quarantine the exact endpoint/model/server/template/thinking family across observation capacity/capability changes and historical epoch keys. Full adapter observation keys remain in work records. Reservation and the owner-serialized arming/handoff gate both check quarantine, including work reserved before another episode reported a violation. Denied prepared work releases unused capacity; denied armed work retains incurred conservative charges and uncertain output headroom. Generic adapter names retain exact-key quarantine. Metadata churn does not reset a quarantine.

Default generative calibration retries should be zero. A transport error without an authoritative usage receipt is unknown; output reserve remains held. Metadata/tokenizer reads may retry under a declared bounded retry policy and remaining HTTP/deadline allowance. If a future calibration retry is enabled, freeze its limit, allocate a new attempt ID, charge the new call/input/output, and retain the unknown prior attempt. A count/template mismatch is a terminal adapter failure, never a reason to spend more calls until the mismatch disappears.

## Raw source work and bounded retrieval

The legacy unmetered candidate count is not a byte budget. `MemoryStore.search` selects complete payload BLOBs, decodes and verifies each event, and only then computes a clipped `MemoryHit`. A 100-candidate branch can materialize 400 MiB at the 4 MiB/event limit. The current lease-aware assembler, semantic search, source browser and evaluation harness use the metadata-first path below. Legacy nil-lease APIs remain available and cannot support an episode-budget claim.

Legacy `literalSearch` uses SQLite `instr(payload, ...)`; its hit limit does not bound inspected nonmatching rows or bytes. The metered literal API instead uses bounded host reads and a byte matcher. Recent preparation, full-source sealing, query-time validation, continuation replay and source paging are charged when a lease is supplied, including repeated passes.

Freeze `raw_work_v1` as a conservative logical work measure, not physical disk I/O:

- Charge bytes returned/materialized from authoritative BLOB reads, including look-behind/look-ahead bytes, full candidate loads and repeated reads from cache.
- Charge bytes examined by a raw-content matcher or full-source digest-validation pass, including candidates and rows that produce no result. If a primitive cannot observe its actual examined bytes, reserve its declared worst-case bound and report a conservative charge.
- Count distinct passes again. Returning a small excerpt does not undo loading, matching or validation work. Do not count Swift allocation copies as independently known disk reads; record peak/materialized bytes and derived-vector work separately.
- Keep metadata-only lookups and FTS index scoring outside the raw-payload byte metric, but bound their rows/candidates and interrupt their SQL work at cancellation/deadline checks. Their latency stays inside the episode.

The metered lexical candidate API returns scoped IDs, rank, sequence, byte count and source digest without selecting `payload`. It inspects at most the frozen candidate limit and processes candidates individually after reserving enough raw work for the full load, integrity validation and declared preview-matching passes. It retains bounded excerpts and metadata, then discards the full payload before the next candidate. The preview bound depends on the actual term count and algorithm. Page reads resolve the authoritative scoped source metadata before any payload access, including when a supplied reference has another project's correct digest.

Do not call the old BLOB-selecting search from a budgeted episode. If remaining work cannot inspect another candidate, return an explicit incomplete result and a continuation tied to query digest, source frontier, scope, ranking version and episode ID. Do not skip an unaffordable highest-ranked candidate silently and claim exhaustive recall. Chunk-level lexical indexing or a streaming Unicode matcher can improve the conservative bound later; they are not prerequisites for enforcing it.

Metered interactive literal search uses a host-controlled source sequence walk. It reserves each bounded read/match chunk before access, retains matching state across page boundaries, preserves exact UTF-8 byte offsets and charges overlapping work each time. It returns the searched scope/frontier, conservative raw work, incomplete status and a stable continuation when a bound is reached. A matching source's returned evidence also needs its supported integrity check under its own reservation. An explicitly larger manual search is a new human action; it cannot automatically reset a search allowance.

Semantic search uses the metadata-first lexical path, reserves query-encoder inference, bounds vector bytes/rows including its look-ahead row, and charges every raw page it verifies or returns. A semantic failure's lexical fallback uses the remaining episode budget. Metadata validation failures remain integrity errors, and budget/deadline errors propagate. Read-only context or semantic selection stops at resource-limited raw coverage before implicit validation rereads or query encoding. Browser search may deliver explicitly limited hits under a terminal budget receipt; it suppresses the implicit first page at that boundary. Candidate/result/source windows remain explicit coverage limits.

Memory-operation slots are defined at the host boundary: one composite context preparation, search or retrieval replay consumes a slot, and every host-requested page read/neighbor expansion consumes its own slot. Internal source-reference checks belong to their parent operation while all underlying bytes/work remain charged. The current read and evaluation paths use `memory_operations_v1`; a future external client contract must preserve that definition and the scanner/ranking version identities.

## Prepaid terminal cleanup

Schema 9 freezes a separate cleanup allowance in each new episode's original limits. Work admission atomically allocates one slot with two automatic attempt units. A fixed terminal fence commits before metadata-only cleanup batches of at most 32 rows. Attempt debits commit separately and survive failed batches or process death; exhausted cleanup attempts retain the terminal fence and pending holds. Startup administrative units are explicit and never refund automatic permission. Historical schemas 1–8 acquire no invented prepayment. [EPISODE-CLEANUP.md](EPISODE-CLEANUP.md) defines the fee ceilings, pending-state invariant, late usage and archive delta. The nine content caps above retain their original meanings.

## Deadline, Stop and restart

Start a continuous monotonic deadline before capture/context preparation, including queue wait. Use a verified clock backend that advances during sleep; persist its boot/clock identity and deadline ticks. UTC is display metadata. Wall-clock changes cannot replenish time. On process restart, all active episodes become terminal interrupted or deadline-exceeded; no automatic continuation is admitted. If the prior clock domain cannot be compared, elapsed time remains unknown instead of resetting to zero.

Move context/retrieval preparation onto the episode coordinator so the main thread can request Stop while work is running. Stop closes further reservations and transport handoffs, increments the budget revision, cancels active transport/SQL work, and terminalizes the episode. Do not hold a SQLite transaction across network calls or slow source scanning. Use short reservations and bounded primitives; a SQL progress callback checks a cancellation token without recursively entering the owner database lock.

`LocalReadCoordinator` performs source-browser search and paging on a serial worker queue. Search and its implicit first page share one lease; selecting a hit or requesting Next is a new explicit human action. A descriptor digest freezes the query or selected source identity and range. Supersession, mode changes, Stop, window close and store replacement signal local interruption immediately, then queue durable cancellation independently. Queued delivery checks the current generation and original continuous deadline before exposing content; failed, cancelled or expired delivery exposes no source bytes. Queue and finalization time stay inside the read deadline. [READ-EPISODES.md](READ-EPISODES.md) describes the integration in detail.

Durably received visible chunks remain available as partial evidence. Late content callbacks cannot append or display new chunks through a terminal episode's lease. A later authoritative usage receipt may settle accounting by its original work ID without reopening the episode or publishing late answer content. Cancellation cannot establish that the server immediately stopped; unknown output reserves stay retained. A provider receipt exceeding its output reservation or disagreeing with exact prompt admission is an explicit adapter violation, preserving the receipt and blocking new work through that adapter until reverified.

Startup recovery inspects every pending original work record in bounded metadata batches before new episode admission. Prepared-but-unarmed records cancel without handoff; armed/submitted records recover unknown; valid terminal receipts are replayed idempotently. The invocation journal independently recovers committed answer fragments. Episode and invocation terminal states must agree on interruption/Stop/error attribution. A process-kill fixture must distinguish preflight-only episodes from answer invocations; preflight should no longer disappear merely because the answer invocation had not started.

## Implementation ownership

| Workstream | Minimal deliverable | Integration dependency |
|---|---|---|
| Ledger | Schema 4, atomic accepted-input/episode creation, standalone-read origins, reservations, receipts, recovery and content-free diagnostics | Frozen resource/counter semantics |
| Provider bridge | Lease-aware discovery/tokenization/calibration/answer dispatch, snapshot IDs and durable arming before every network start | Ledger APIs; preserve exact canonical body |
| Retrieval primitives | Metadata-first lexical candidates, bounded literal continuation, charged recent/source reads, semantic/fallback lease propagation | Ledger APIs and raw-work definition |
| Coordinator and evaluation | Shared submission/read deadlines, browser delivery fencing, GUI/CLI adoption and per-protocol synthetic read receipts | Explicit unsupported-token paths; a new amendment before registered measurement |

These responsibilities share the owner-controlled ledger, lease and frozen counter semantics. The integrated answering and read paths use the same allowance through automatic reductions and fallback. Background maintenance still needs its own daily contract, and external read clients need a frozen continuation compatibility contract.

## Required failure fixtures and completion evidence

| Fixture | Required evidence |
|---|---|
| SIGKILL before first preflight call | Accepted human event and episode survive; unarmed work has no alleged usage and no replayed request. |
| SIGKILL after arming calibration, before/after HTTP handoff | Durable unknown calibration attempt survives; model/input charge and output bound remain; no automatic resend. |
| Lost calibration response or Stop during calibration | Fixed bounded outcome, observed usage unknown, held capacity retained, next callback cannot dispatch an answer. |
| Many individually admissible reductions | One shared HTTP/token/model/deadline allowance applies; prior attempts remain charged. |
| Repeated/cached prompt prefixes | Exact full input charged for each inference attempt; economic cache fields reported separately. |
| Usage replay/conflict | Identical receipt settles once; changed usage/identity/body receipt fails without freeing capacity. |
| Reported reasoning and missing usage | Reasoning subset is not double-counted; missing output stays unknown, never inferred from visible bytes. |
| Concurrent reservations racing the last slot | Exactly one fits; no negative, overflowed or partially committed resource vector. |
| One hundred 4 MiB lexical candidates | Metadata selection stays bounded; no unreserved full BLOB loads; quota exhaustion is explicit before another candidate. |
| Literal miss across a large project | Every inspected chunk is charged; stable continuation and incomplete coverage return instead of an unmetered SQL scan. |
| Literal crossing a page or UTF-8 boundary | Exact source span survives bounded overlapping reads; overlap work is charged. |
| Semantic failure after raw candidates | Lexical fallback uses the remaining allowance and preserves spent work; exhaustion is not caught as an ordinary semantic outage. |
| Recent, replay and validation rereads | Charged totals include real repeated payload work, not only the final evidence bytes. |
| Deadline during lookup/answer; clock rollback; sleep | New work/output is fenced, durable partial output remains, elapsed time cannot reset; unknown remote computation is stated. |
| Crash followed by repeated application restart | Episodes remain terminal; call/input/unknown-output charges are stable and recovery publishes no duplicate answer. |
| Schema 1–3 to 4 and backup/restore | Exact source/chat identity bytes and historical accounting survive migration; read origins and unknown outcomes survive restore; unsupported source schemas fail before original mutation. |
| Standalone-read crash and invalid origin | No chat capture or invocation is invented; unarmed work releases, armed encoder work retains unknown input, malformed origin/linkage/work fails. |
| Partial raw coverage and delayed browser delivery | Read context/semantic paths stop before extra rereads/encoding; browser limited hits omit an implicit page; superseded or expired callbacks expose no content. |
| Evaluation cap/deadline exhaustion | Episode scores failure at the recorded terminal/deadline; the arm gets no hidden retry, extra time, or omitted denominator entry. |

The integration exercises shared GUI/CLI/browser/evaluation accounting, real kill/reopen boundaries, provider-fixture reservation/usage and retrieval stress behind small excerpts. Evaluation records authoritative charged and held vectors, the terminal reason, structured coverage limits and full read-episode time before oracle scoring. Budget failures remain failed attempts in every protocol denominator. These contracts provide no new registered quality or cost measurement. Missing exact encoder usage and production cost remain explicit limits.

## Recorded integration evidence

Final verification and suite totals are recorded in [STATUS.md](STATUS.md); component and process suites overlap. The checks include exact Unicode identity replay, indexed read-request uniqueness, schema migration rollback under SIGKILL, read-origin archive corruption, scoped metadata before payload, partial coverage before rereads/encoding, and browser cancellation/deadline delivery. Independent review also closed missing-usage calibration quarantine and complete-capture/episode-state disagreement. Recovered empty/partial Stop cancellations remain backable and recognizable by the CLI; inconsistent cancellation archives are rejected.

GUI fixtures exercise Stop during preparation, deadline expiry during final publication, a short live native pipe prefix and native cleanup that ignores SIGTERM until the owned SIGKILL fallback. The built bundle passed strict deep signature verification. The running mlx-serve passed two synthetic arithmetic turns through the shared CLI episode path. These results establish integration and failure handling, not general retrieval quality or model competence.

Development mode records opaque encoder/native input tokens as unknown; strict known-input mode rejects or skips those inference paths. The still-null matched recent-context token allocation, exact evidence-token enforcement and daily background allowance must be frozen before claiming a complete phase 0 budget contract or running a matched held-out comparison. Current synthetic evaluation adoption is an unregistered contract check; the next measurement needs a new development amendment. The proposed component defaults above are starting configuration choices, not measured optimal settings. External continuation ingestion also needs explicit ranking/scanner version identities; the current continuations are internal to this executable.
