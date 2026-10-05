# Boros project status

Updated October 4, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`. Verified implementation checkpoint: `22c3402`. The prior checkpoint is `38675c5`. The architectural backlog remains active.

The verified native chat prototype integrates durable stream capture, exact selected-provider admission, hybrid source retrieval, episode accounting and backup/restore. The current integration passed 793 combined checks; the prior checkpoint passed 478. Development evaluation establishes synthetic source coverage for the historical lexical branch; current installed hybrid answer quality remains unmeasured. The complete architecture in the [plan](../tracechat-plan.md) remains in progress. No completion percentages or delivery dates are assigned.

| Workstream | Status | Available now | Remaining work |
|---|---|---|---|
| Project setup and design | Foundation complete | Migrated to Boros, retained planning history and adversarial review, committed and pushed the native foundation | Keep contracts and implementation status aligned as scope grows |
| Native chat GUI | Implemented; lifecycle verified | Chat picker, drafts, restored transcripts, streaming, cancellation, source browser and backup/restore menu; Stop/deadline and owned native cleanup regressions pass | Visual recheck awaits an unlocked Mac |
| Local model connection | Implemented | OpenAI-compatible mlx-serve connection at `http://localhost:11234/v1/`, selected Qwen model, structured role messages, optional thinking control | Broader compatibility and reliability evaluation |
| Transport and credentials | Implemented | Loopback-only endpoints, redirect rejection, bounded SSE parsing, explicit failure states, optional credentials in macOS Keychain | Any remote-provider support needs its own processing and disclosure contracts |
| Durable text history | Implemented for accepted text | Complete bounded UTF-8 payloads, typed events, stable IDs, digests, capture statuses, SQLite transactions and exclusive owner lock | Released-version migrations, attachments, and external payload protocol |
| Capture during generation | Implemented and verified | Each visible chunk commits before display; exact linked invocation snapshots; interrupted attempts recover partial/failed; schema 1/2 migration; complete publication requires a completed episode | Retention/purge must include snapshots and chunks |
| Original-source retrieval | Metered core and hybrid baseline verified | Scoped metadata-first lexical candidates, bounded literal continuation, charged source reads and exact paging; Send excludes recent sources before candidate limits | Full hybrid quality evaluation, manual-browser read episodes, larger-archive scaling and external continuation versioning |
| Context assembly | Partial; selected-model admission and accounting verified | Complete current request, bounded recent/history evidence, exact Qwen rendered token counts, output/safety reservation, immutable request body and shared episode lease | [Exact component-token contract](CONTEXT-COMPONENTS.md), more verified provider adapters and evaluation adoption |
| Episode budgets and accounting | Answering/core retrieval integration verified | Schema-3 reservations and receipts; continuous deadline; durable preflight; metered provider/retrieval paths; unknown outcomes retained through recovery; GUI/CLI and kill/reopen checks pass | Manual-browser read episodes, evaluation adoption and background-index budgets; opaque encoder/native token usage remains explicit |
| Semantic retrieval | Core metering and protocol verified | Real installed Apple English encoder; sealed sources, durable jobs, coverage holes, frozen continuations and replay manifests; 76 component checks pass | Installed-encoder quality evaluation, whole-corpus coverage and daily background budgets |
| Service, MCP, and imports | Deferred | Single-process native app owns the store | Multi-client memory service when justified, read-only MCP interface, authenticated imports and adapters |
| Policy and task lifecycle | Not started | Original authorship and capture status are retained | Authenticated lifecycle changes, expiry/reopen rules, separate read/disclosure/processing grants, transitive dependencies |
| Revocation and deletion controls | Not started | No deletion or policy mutation feature is enabled | Durable control epoch, handoff/delivery gate, late-output fencing, safe physical purge |
| External actions | Optional; deferred | No external tool actions are enabled | Durable action journal, explicit unknown outcomes, reconciliation and recovery |
| Retention and recovery | Schema-3 backup/restore verified | Consistent SQLite snapshot, inventory verification, no-clobber restore, recovery and rebuilt lexical index; legacy compatibility, corruption and unknown reservations tested | Deletion-ledger application, retention, purge and a polished restored-store opening workflow |
| Summary tree | Optional; gated | No tree or model-generated archive summaries | Implement only after the raw-retrieval baseline passes its checkpoint; test incremental updates and reproducible frontiers |
| Quality and economics evaluation | Contracts verified; historical development source coverage retained | 45 contract tests; immutable v4 lexical helper report covers 224/224 eligible probes; current-source contract-only mode is explicitly unregistered | Shared ledger adoption and new development amendment, installed hybrid/answering evaluation, representative workload and comparative quality/economics |
| Local release | Development build only | Buildable, ad hoc signed app bundle | Complete release gates, packaging, user documentation and recovery validation |

## Implementation assignments

The current parallel wave integrated the [episode-budget contract](EPISODE-BUDGET.md) across answering and core retrieval with separate file ownership. Whole-app, isolated recovery, independent recheck, signature and live synthetic CLI gates passed. Remaining adoption work below belongs to the next contract, rather than an implied claim that the full budget architecture is complete.

| Assignment | Owned surface | Current state | Integration gate |
|---|---|---|---|
| Coordinating agent | Shared interfaces, GUI/CLI/native lifecycle, SQL interruption, kill fixtures, scripts and documentation | Integrated; 793-check app suite, signature and live synthetic CLI pass | Checkpoint verified; visual recheck awaits unlock |
| Episode ledger agent | Main schema 3, reservations, receipts, recovery, clock and lease | Integrated; 86 isolated checks pass, including real SIGKILL/reopen | Standalone read-episode initiator and compatibility contract next |
| Episode provider agent | Discovery/tokenizer/calibration/answer handoffs and fixtures | Integrated; 49 unit and 189 HTTP checks pass | Component-token allocations and future adapter verification |
| Metered retrieval agent | Metadata-first candidates, bounded literal continuation, recent/source/semantic accounting | Integrated; 64 context and 76 semantic checks pass, including large sources and real SQLite interruption | Manual-browser contract, evaluation adoption and background-index budgets |
| Episode backup agent | Schema-3 recognition, journal inventory and restore | Integrated; 110 isolated checks pass, including legacy compatibility, corruption and SIGKILL/reopen | Next schema compatibility and eventual deletion-aware restore |
| Independent review agent | Read-only adversarial review of lifecycle, provider receipts and ledger gates | Reproduced findings fixed; independent 189 HTTP checks pass; new publication/backup fixtures pass in root integration | No open material finding in reviewed scope; deferred contracts remain outside that evidence |
| Evaluation integration agent | Compiler dependency closure and source-pin preservation | 45 contract tests pass; current-source mode is bounded and explicitly unregistered | Adopt shared episode ledger before a new measurement amendment |

Evaluation review identified timing contamination, incomplete category validation, malformed gate/economic inputs, an overbroad power interpretation and a probe/span label. Corrections passed 41 tests and focused independent recheck. Original frozen reports are retained as historical evidence; v4 measures the lexical-only helper branch explicitly.

Independent review closed partial-cancellation and native-snapshot mismatches, recent-source candidate starvation, and CLI mutation of unrelated databases. Regression fixtures cover each trigger. The semantic component is integrated with a pinned revision, runtime fingerprint and explicit coverage holes.

The development evaluation measures source coverage without an answerer. V4's lexical-only helper (`semanticIndex:nil`) recovers all 256 required spans in 224/224 eligible probes across 32 synthetic histories; warm helper p95 is 59.70 ms and raw-source probe p95 is 4.72 ms, with oracle scoring timed separately. Installed-index hybrid GUI behavior, model quality and production latency remain unmeasured. See [EVALUATION.md](EVALUATION.md). Held-out cases remain unrun.

## Verification

Results describe their recorded source snapshots. The 478-check suite predates the current episode-budget integration. Counts overlap and must not be added together.

| Check | Recorded result | What it establishes |
|---|---|---|
| Foundation automated suite | 183 checks passed | Historical foundation at `2574b3b` |
| Capture/admission integration checkpoint | 324 checks passed | GUI, memory, native parser, context, provider and HTTP fixtures; before latest semantic/backup/shared-contract changes |
| Final hybrid/backup integration | 478 checks passed | 51 conversation/profile, 78 GUI, 9 native parser, 95 memory, 44 endpoint/admission, 37 context, 60 semantic, 59 backup/CLI, 45 HTTP integration |
| Standalone memory suite | 108 checks passed | 100 component checks plus 8 separate owner/process-recovery checks; exact-source/frontier checks and real SIGKILL/reopen |
| Provider renderer oracle | 30 cases passed | Independent template comparison, including rejected inputs |
| Live provider token counts | 24 comparisons passed | Selected model/server/template, both thinking modes |
| Live mlx-serve CLI | Two arithmetic turns passed with exact admission and the shared episode ledger | Basic dispatch, history forwarding and durable answering accounting |
| Semantic component and process recovery | 60 component checks; 6 SIGKILL/recovery checks repeated after another reopen | Installed-encoder smoke, source integrity, frozen continuations and recovery |
| Backup/restore and process recovery | 60 isolated checks passed | Corruption, foreign-source recognition, concurrent writes, restore/reopen, no-clobber and SIGKILL |
| Evaluation contracts | 45 tests passed | Validation/statistics, dependency capture, immutable v4 source refusal and bounded unregistered contract execution |
| Development bundle signature | Strict deep verification passed | Current integrated episode bundle |
| Current episode ledger and process recovery | 86 isolated checks passed | Reservations, receipts, accounting invariants, complete-publication fencing and actual SIGKILL/reopen |
| Current episode provider | 49 unit and 189 HTTP checks passed | Metered handoffs, conservative unknown outcomes, late usage, answering/calibration quarantine and suppressed dispatch |
| Current metered context and semantic retrieval | 64 context and 76 semantic checks passed | Shared allowances, explicit incomplete results, source sealing and SQLite deadline/Stop interruption |
| Current schema-3 backup and recovery | 110 isolated checks passed | Legacy compatibility, journal/capture corruption rejection, preserved unknown reservations and SIGKILL/reopen |
| Current episode whole-app integration | 793 checks passed | 67 episode, 51 conversation/profile, 89 GUI, 9 native parser, 100 memory, 49 endpoint/admission, 64 context, 76 semantic, 99 backup/CLI, 189 HTTP |
| Final visual recheck | Pending; Mac locked | Computer-use tool could not unlock; owned synthetic window was closed and its temporary store removed |

These checks do not establish general model competence, production long-history recall, latency reliability or cost improvements. Historical v1 retrieval timings included scoring work; v4 separates that measurement. Full details and limitations are in [IMPLEMENTATION.md](IMPLEMENTATION.md) and [EVALUATION.md](EVALUATION.md).

## Next checkpoint

Continue the [standalone read-episode contract](READ-EPISODES.md): extend metering to standalone source browsing and the evaluation harness. Implement the [recent/evidence token contract](CONTEXT-COMPONENTS.md) and add background-index budgets. The schema-4 origin and project-scope contract is recorded before implementation; it must not invent hidden chat turns or reset quotas through automatic fallbacks. Apple encoder input tokens remain opaque; development mode records that fact and strict known-input mode skips the encoder. Raw-source charges are conservative logical work bounds. Policy mutation, deletion, external actions and the optional tree require their own contracts and verification gates. The phase mapping below follows the plan's milestones.

| Plan phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Freeze contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External-blob ingest/recovery, aggregate quotas, epoch suppression, deletion fencing and deletion-aware backup/restore |
| 2 — Read-only baseline | Partial | Standalone-browser/evaluation budget adoption, background-index budgets, component-token allocations, CLI/MCP disclosure grants, Arm B recall/latency and pilot cost report |
| 3 — Policy/task and optional actions | Not started | Lifecycle and scoped harness tests; action recovery tests if actions are enabled |
| 4 — Optional tree | Gated | Accepted baseline checkpoint before implementation; lineage, frontier and fence verification afterward |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations, frozen baseline/tree comparison and held-out quality/economics gates |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, deletion-aware restore, packaging, final visual recheck and publication of applicable release invariants |
