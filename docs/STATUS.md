# Boros project status

Updated October 4, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`. Verified implementation checkpoint: `38675c5` (pushed). The architectural backlog remains active. An uncommitted episode-budget interface draft has not passed an integration checkpoint.

The native chat prototype now integrates durable stream capture, exact selected-provider admission, hybrid source retrieval and backup/restore. The final combined suite passed 478 checks. Development evaluation establishes synthetic source coverage for the lexical branch; installed hybrid answer quality remains unmeasured. The complete architecture in the [plan](../tracechat-plan.md) remains in progress. This table reports behavior and verification; it does not estimate completion percentages or delivery dates.

| Workstream | Status | Available now | Remaining work |
|---|---|---|---|
| Project setup and design | Foundation complete | Migrated to Boros, retained planning history and adversarial review, committed and pushed the native foundation | Keep contracts and implementation status aligned as scope grows |
| Native chat GUI | Implemented | Chat picker, drafts, restored transcripts, streaming, cancellation, source browser and backup/restore menu | Final visual recheck |
| Local model connection | Implemented | OpenAI-compatible mlx-serve connection at `http://localhost:11234/v1/`, selected Qwen model, structured role messages, optional thinking control | Broader compatibility and reliability evaluation |
| Transport and credentials | Implemented | Loopback-only endpoints, redirect rejection, bounded SSE parsing, explicit failure states, optional credentials in macOS Keychain | Any remote-provider support needs its own processing and disclosure contracts |
| Durable text history | Implemented for accepted text | Complete bounded UTF-8 payloads, typed events, stable IDs, digests, capture statuses, SQLite transactions and exclusive owner lock | Released-version migrations, attachments, and external payload protocol |
| Capture during generation | Implemented and verified | Each visible chunk commits before display; exact invocation snapshots; interrupted attempts recover partial/failed; schema v1 migration | Durable accounting before/during admission; retention/purge must include snapshots and chunks |
| Original-source retrieval | Implemented hybrid baseline | Scoped literal/FTS5 search, exact paging; Send fuses lexical/semantic results and excludes recent sources before candidate limits | Full hybrid quality evaluation, scan budgets and larger-archive scaling |
| Context assembly | Partial; exact selected-model admission verified | Complete current request, bounded recent/history evidence, exact Qwen rendered token counts, output/safety reservation, immutable request body, actual usage checks | Total episode budget enforcement, durable preflight accounting, more verified provider adapters |
| Episode budgets and accounting | Interface draft started; enforcement pending | Proposed resource/deadline contract and shared Swift types/protocol | Durable ledger and recovery, reservations before dispatch, metered retrieval, one GUI/CLI/evaluation lifecycle and failure fixtures |
| Semantic retrieval | Integrated; protocol verified | Real installed Apple English encoder; sealed sources, durable jobs, coverage holes, frozen continuations and replay manifests; 60 component checks plus SIGKILL recovery | Installed-encoder quality evaluation, whole-corpus coverage and daily background budgets |
| Service, MCP, and imports | Deferred | Single-process native app owns the store | Multi-client memory service when justified, read-only MCP interface, authenticated imports and adapters |
| Policy and task lifecycle | Not started | Original authorship and capture status are retained | Authenticated lifecycle changes, expiry/reopen rules, separate read/disclosure/processing grants, transitive dependencies |
| Revocation and deletion controls | Not started | No deletion or policy mutation feature is enabled | Durable control epoch, handoff/delivery gate, late-output fencing, safe physical purge |
| External actions | Optional; deferred | No external tool actions are enabled | Durable action journal, explicit unknown outcomes, reconciliation and recovery |
| Retention and recovery | Backup/restore integrated and verified | Consistent SQLite snapshot, inventory verification, no-clobber restore, recovery and rebuilt lexical index; CLI and File menu; 60 isolated checks | Deletion-ledger application, retention, purge and a polished restored-store opening workflow |
| Summary tree | Optional; gated | No tree or model-generated archive summaries | Implement only after the raw-retrieval baseline passes its checkpoint; test incremental updates and reproducible frontiers |
| Quality and economics evaluation | Contracts corrected; development source coverage verified | 41 contract tests; lexical helper recovers all spans in 224/224 eligible synthetic probes | Installed hybrid/answering evaluation, representative workload and comparative quality/economics |
| Local release | Development build only | Buildable, ad hoc signed app bundle | Complete release gates, packaging, user documentation and recovery validation |

## Implementation assignments

The prior parallel wave is integrated and verified. The next wave has a draft budget contract and shared interface types; its runtime implementation is pending. Concurrent implementation assignments will use separate file ownership after shared interfaces are frozen. Rows remain in progress until integrated verification passes.

| Assignment | Owned surface | Current state | Integration gate |
|---|---|---|---|
| Durable invocation agent | Store schema, invocation/chunk persistence, memory checks | Complete and integrated | Checkpoint passed |
| Provider admission agent | Request builder, tokenizer/admission adapter, HTTP fixtures | Complete and integrated | Checkpoint passed |
| Evaluation agent | Harness, synthetic fixtures, evaluation specification | Corrected; v4 development run passed | Future hybrid/answering evaluation |
| Coordinating agent | Integration, shared contracts, checks and documentation | Checkpoint verified; episode interfaces drafted | Freeze interfaces and integrate the next contract |
| Semantic retrieval agent | Sidecar, encoder, jobs and replay manifests | Complete and integrated | Protocol/recovery checks passed; quality evaluation pending |
| Backup/restore agent | Archive, verification, CLI and restore | Complete and integrated | Component, CLI and recovery checks passed |
| Episode-budget assignment | [Durable preflight and total-work accounting contract](EPISODE-BUDGET.md), shared budget types/protocol | Contract and interface drafts; no runtime enforcement | Ledger, provider/retrieval adoption, recovery and failure schedules |

Evaluation review identified timing contamination, incomplete category validation, malformed gate/economic inputs, an overbroad power interpretation and a probe/span label. Corrections passed 41 tests and focused independent recheck. Original frozen reports are retained as historical evidence; v4 measures the lexical-only helper branch explicitly.

Independent review closed partial-cancellation and native-snapshot mismatches, recent-source candidate starvation, and CLI mutation of unrelated databases. Regression fixtures cover each trigger. The semantic component is integrated with a pinned revision, runtime fingerprint and explicit coverage holes.

The development evaluation measures source coverage without an answerer. V4's lexical-only helper (`semanticIndex:nil`) recovers all 256 required spans in 224/224 eligible probes across 32 synthetic histories; warm helper p95 is 59.70 ms and raw-source probe p95 is 4.72 ms, with oracle scoring timed separately. Installed-index hybrid GUI behavior, model quality and production latency remain unmeasured. See [EVALUATION.md](EVALUATION.md). Held-out cases remain unrun.

## Verification

Results describe their recorded source snapshots. The current frozen integration passed the combined suite after review fixes. Counts overlap and must not be added together.

| Check | Recorded result | What it establishes |
|---|---|---|
| Foundation automated suite | 183 checks passed | Historical foundation at `2574b3b` |
| Capture/admission integration checkpoint | 324 checks passed | GUI, memory, native parser, context, provider and HTTP fixtures; before latest semantic/backup/shared-contract changes |
| Final hybrid/backup integration | 478 checks passed | 51 conversation/profile, 78 GUI, 9 native parser, 95 memory, 44 endpoint/admission, 37 context, 60 semantic, 59 backup/CLI, 45 HTTP integration |
| Standalone memory suite | 103 checks passed | Owner exclusion, exact-source/frontier checks and real SIGKILL/reopen; overlaps main suite |
| Provider renderer oracle | 30 cases passed | Independent template comparison, including rejected inputs |
| Live provider token counts | 24 comparisons passed | Selected model/server/template, both thinking modes |
| Live mlx-serve CLI | Two arithmetic turns passed with exact admission | Basic dispatch and history forwarding |
| Semantic component and process recovery | 60 component checks; 6 SIGKILL/recovery checks repeated after another reopen | Installed-encoder smoke, source integrity, frozen continuations and recovery |
| Backup/restore and process recovery | 60 isolated checks passed | Corruption, foreign-source recognition, concurrent writes, restore/reopen, no-clobber and SIGKILL |
| Evaluation contracts | 41 tests passed | Reviewed validation/statistics corrections and v4 development source snapshot |
| Development bundle signature | Strict deep verification passed | Final frozen integration bundle |
| Final visual recheck | Pending | Last UI-control correction passed automated checks but has not been visually rechecked |

These checks do not establish general model competence, production long-history recall, latency reliability or cost improvements. Historical v1 retrieval timings included scoring work; v4 separates that measurement. Full details and limitations are in [IMPLEMENTATION.md](IMPLEMENTATION.md) and [EVALUATION.md](EVALUATION.md).

## Next checkpoint

Continue with the [episode-budget contract](EPISODE-BUDGET.md), durable preflight accounting and scoped disclosure after the verified integration checkpoint. Opaque encoder token usage, raw work behind clipped excerpts and the matched recent-token cap remain explicit contract questions. Policy mutation, deletion, external actions and the optional tree require their own contracts and verification gates. The phase mapping below follows the plan's milestones.

| Plan phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Freeze contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External-blob ingest/recovery, aggregate quotas, epoch suppression, deletion fencing and deletion-aware backup/restore |
| 2 — Read-only baseline | Partial | Episode budgets and durable preflight, bounded coverage fallback and scan work, CLI/MCP disclosure grants, Arm B recall/latency and pilot cost report |
| 3 — Policy/task and optional actions | Not started | Lifecycle and scoped harness tests; action recovery tests if actions are enabled |
| 4 — Optional tree | Gated | Accepted baseline checkpoint before implementation; lineage, frontier and fence verification afterward |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations, frozen baseline/tree comparison and held-out quality/economics gates |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, deletion-aware restore, packaging, final visual recheck and publication of applicable release invariants |
