# Boros project status

Updated October 4, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`. Application changes are pushed through `7528e82`; the current implementation wave remains uncommitted.

The native chat prototype and bounded lexical recall are implemented. Capture and provider admission passed an integration checkpoint. Semantic retrieval, backup/restore and evaluation corrections need final integration and verification. The complete architecture in the [plan](../tracechat-plan.md) remains in progress. This table reports behavior and recorded verification; it does not estimate completion percentages or delivery dates.

| Workstream | Status | Available now | Remaining work |
|---|---|---|---|
| Project setup and design | Foundation complete | Migrated to Boros, retained planning history and adversarial review, committed and pushed the native foundation | Keep contracts and implementation status aligned as scope grows |
| Native chat GUI | Implemented | Chat picker, new chats, drafts, transcript restoration, streaming, cancellation, source browser | Final visual recheck after the last UI-control correction |
| Local model connection | Implemented | OpenAI-compatible mlx-serve connection at `http://localhost:11234/v1/`, selected Qwen model, structured role messages, optional thinking control | Broader compatibility and reliability evaluation |
| Transport and credentials | Implemented | Loopback-only endpoints, redirect rejection, bounded SSE parsing, explicit failure states, optional credentials in macOS Keychain | Any remote-provider support needs its own processing and disclosure contracts |
| Durable text history | Implemented for accepted text | Complete bounded UTF-8 payloads, typed events, stable IDs, digests, capture statuses, SQLite transactions and exclusive owner lock | Released-version migrations, attachments, and external payload protocol |
| Capture during generation | Implemented; checkpoint verified | Each visible chunk commits before display; exact invocation snapshots; interrupted attempts recover partial/failed; schema v1 migration | Verify latest shared-source changes; durable accounting before/during admission; retention/purge must include snapshots and chunks |
| Original-source retrieval | Implemented lexical baseline | Project-scoped literal/FTS5 search, exact source paging; ordinary Send includes bounded any-term lexical excerpts | Semantic fusion, coverage reporting, query-quality evaluation and larger-archive scaling |
| Context assembly | Partial; exact selected-model admission verified | Complete current request, bounded recent/history evidence, exact Qwen rendered token counts, output/safety reservation, immutable request body, actual usage checks | Total episode budget enforcement, durable preflight accounting, more verified provider adapters |
| Semantic retrieval | Component implementation in progress | Real installed Apple English encoder; durable jobs, coverage holes, source checks and replay manifests; 55 component checks and 6 SIGKILL/reopen checks reported | Frozen-frontier continuation API, GUI integration and combined verification |
| Service, MCP, and imports | Deferred | Single-process native app owns the store | Multi-client memory service when justified, read-only MCP interface, authenticated imports and adapters |
| Policy and task lifecycle | Not started | Original authorship and capture status are retained | Authenticated lifecycle changes, expiry/reopen rules, separate read/disclosure/processing grants, transitive dependencies |
| Revocation and deletion controls | Not started | No deletion or policy mutation feature is enabled | Durable control epoch, handoff/delivery gate, late-output fencing, safe physical purge |
| External actions | Optional; deferred | No external tool actions are enabled | Durable action journal, explicit unknown outcomes, reconciliation and recovery |
| Retention and recovery | Backup/restore component ready for integration | Consistent online SQLite snapshot, verified inventory, private no-clobber restore, interrupted recovery and rebuilt lexical index; 43 isolated checks reported | CLI/GUI wiring and combined verification; deletion-ledger application, retention and purge remain pending |
| Summary tree | Optional; gated | No tree or model-generated archive summaries | Implement only after the raw-retrieval baseline passes its checkpoint; test incremental updates and reproducible frontiers |
| Quality and economics evaluation | Harness implemented; corrections in progress | Frozen synthetic fixtures, source-coverage protocols, statistical helpers and 29 initial contract tests | Reviewed contract/timing corrections, current-GUI protocol amendment and development rerun; comparative answer quality/economics remain pending |
| Local release | Development build only | Buildable, ad hoc signed app bundle | Complete release gates, packaging, user documentation and recovery validation |

## Active implementation wave

Work started October 4, 2026. Independent agents have separate file ownership; integration and status updates remain with the coordinating agent. Rows remain in progress until integrated verification passes.

| Assignment | Owned surface | Current state | Integration gate |
|---|---|---|---|
| Durable invocation agent | Store schema, invocation/chunk persistence, memory checks | Complete; integrated at checkpoint | Latest shared-contract suite passes |
| Provider admission agent | Endpoint request builder, tokenizer/admission adapter, HTTP fixtures | Complete; integrated at checkpoint | Exact count, snapshot and dispatch remain consistent in final build |
| Evaluation agent | Harness, synthetic fixtures, evaluation specification | Active correction pass | Independent recheck and development-only rerun |
| Coordinating agent | Native integration, shared contracts, build/test entry points, documentation | Active | Combined checks, code commit/push and accurate milestone table |
| Semantic retrieval agent | Sidecar, pinned English encoder, jobs, replay manifests | Component tests passed; awaiting shared API | Scoped continuations, exact source fidelity, explicit holes and app integration |
| Backup/restore agent | Archive/verification/restore component and synthetic checks | Sources frozen; 43 checks passed | CLI/GUI wiring and integrated verification |

Evaluation review identified timing contamination from oracle scoring, incomplete category validation, malformed evidence accepted by gates, an overbroad power interpretation, and a probe/span denominator label. These corrections and the current-GUI protocol amendment are in progress; original frozen results are retained as historical evidence.

Independent integration review found a partial-output cancellation status mismatch and a native request/snapshot mismatch. Both were corrected before the capture/admission checkpoint. The semantic component uses a pinned revision, runtime fingerprint and explicit coverage holes; it has not yet been integrated into the GUI.

The initial development evaluation exercises source coverage rather than answer quality. Its evaluated snapshot used recent context; the current GUI now includes bounded any-term lexical recall from commit `7528e82`. Complete-question AND-lexical retrieval and explicit targeted queries are distinct diagnostic protocols. The evaluation is being refreshed to represent the current GUI path. See [EVALUATION.md](EVALUATION.md) for frozen fixtures, evidence and limitations. Held-out cases remain unrun.

## Verification

Results describe their recorded source snapshots. The latest working tree has not passed a combined suite after all new component and shared-contract edits. Counts overlap and must not be added together.

| Check | Recorded result | What it establishes |
|---|---|---|
| Foundation automated suite | 183 checks passed | Historical foundation at `2574b3b` |
| Capture/admission integration checkpoint | 324 checks passed | GUI, memory, native parser, context, provider and HTTP fixtures; before latest semantic/backup/shared-contract changes |
| Standalone memory suite | 96 checks passed at latest recorded run | Owner exclusion and real SIGKILL/reopen; newer source-reference checks await rerun |
| Provider renderer oracle | 30 cases passed | Independent template comparison, including rejected inputs |
| Live provider token counts | 24 comparisons passed | Selected model/server/template, both thinking modes |
| Live mlx-serve CLI | Two arithmetic turns passed with exact admission | Basic dispatch and history forwarding |
| Semantic component | 55 component checks and 6 SIGKILL/reopen checks passed, agent reported | Real installed-encoder smoke, source integrity, protocol/failure checks and process recovery; shared API/app integration pending |
| Backup/restore component | 43 checks passed, agent reported | Corruption, concurrent writes, restore/reopen, no-clobber and real SIGKILL; app wiring pending |
| Evaluation contracts | 29 initial tests passed | Corrections and current-path development rerun pending |
| Development bundle signature | Strict deep verification passed | Recorded integration build; rebuild after final integration |
| Final visual recheck | Pending | Last UI-control correction passed automated checks but has not been visually rechecked |

These checks do not establish general model competence, long-history recall, latency reliability, or cost improvements. The historical development evaluation's 224 eligible probes require all gold spans; they contain 256 individual spans. Previously recorded retrieval timings include scoring work and await correction. Full details and limitations are in [IMPLEMENTATION.md](IMPLEMENTATION.md) and [EVALUATION.md](EVALUATION.md).

## Next checkpoint

Finish semantic/backup integration and evaluation corrections, freeze sources, run combined verification, then commit and push the implementation wave. The remaining baseline contracts include total episode budgets, durable preflight accounting and scoped disclosure. Policy mutation, deletion, external actions and the optional tree require their own contracts and verification gates. The phase mapping below follows the plan's milestones.

| Plan phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Freeze contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External-blob ingest/recovery, quotas beyond the per-payload limit, epoch suppression, deletion fencing and verified backup/restore |
| 2 — Read-only baseline | Partial | Semantic adapter, coverage fallback, CLI/MCP disclosure grants, provider admission, Arm B recall/latency and pilot cost report |
| 3 — Policy/task and optional actions | Not started | Lifecycle and scoped harness tests; action recovery tests if actions are enabled |
| 4 — Optional tree | Gated | Accepted baseline checkpoint before implementation; lineage, frontier and fence verification afterward |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations, frozen baseline/tree comparison and held-out quality/economics gates |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, verified restore and publication of applicable release invariants |
