# Boros project status

Updated October 5, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`. Verified implementation checkpoint: `1f8e0a6`, pushed to GitHub; the subsequent pushed documentation checkpoint is `d7856d2`. The preceding implementation checkpoint is `22c3402`. The complete [plan](../tracechat-plan.md) remains in progress. The component-token wave described below is uncommitted: its combined automated checks pass, but its latest live mlx-serve smoke fails provider identity verification.

The native prototype now combines durable text capture, exact selected-provider admission, hybrid source retrieval, shared answering/read accounting and verified backup/restore. The last pushed implementation passed **1,016 whole-app checks**. The current component working tree passed **1,190 whole-app checks**, including coordinator and durable-proof regressions. It is not ready for an implementation checkpoint until the live failure is resolved and the resulting artifact is verified. Installed hybrid answer quality, production latency and comparative economics remain unmeasured. No completion percentages or delivery dates are assigned.

## Work status

| Workstream | Status | Available now | Remaining work |
|---|---|---|---|
| Project setup and design | Foundation complete | Migrated to Boros; retained original plan, adversarial reviews and provenance; GitHub branch established | Keep contracts, evidence and status aligned |
| Native chat GUI | Implemented; automated lifecycle verified | Chats, drafts, restored transcripts, streaming, cancellation, source browser and backup/restore menu | Final visual recheck awaits an unlocked Mac |
| Local model connection | Pushed baseline verified; current live regression open | OpenAI-compatible mlx-serve at `http://localhost:11234/v1/`; selected Qwen model; structured messages and optional thinking control | Correct the model-load identity contract: live `/v1/models.created` changes between reads; then repeat live dispatch verification |
| Transport and credentials | Implemented | Loopback endpoints, redirect rejection, bounded SSE, explicit failures and optional Keychain credentials | Remote providers need their processing and disclosure contracts |
| Durable text capture | Implemented for accepted text | Complete bounded UTF-8 payloads; typed events, exact IDs/digests/status; chunks committed before display; invocation snapshots; exclusive owner and migration from schemas 1–3 to schema 4 | Released-version migrations, attachments, external payload protocol and aggregate ingestion quotas |
| Original-source retrieval | Metered baseline verified | Scoped metadata-first lexical search, bounded literal traversal, exact pages and hybrid retrieval; central scope assertion before inspection | Larger-archive scaling, external continuation versioning and measured hybrid quality |
| Standalone read episodes | Implemented and verified | Schema-4 chat/read origins; immutable scope and descriptor; indexed initiation replay; shared allowance, continuous deadline and recovery | Future read CLI/MCP adapters need explicit ownership and disclosure contracts |
| Source-browser accounting | Implemented and verified | Search plus initial page share a lease; explicit paging is bounded; worker queue, Stop/supersession/close/deadline fences and incomplete results | Visual verification; explicit continuation UX only after its compatibility contract |
| Evaluation accounting | Implemented; contracts verified | Isolated read episode per fixture/protocol; authoritative charges/holds/time/outcome; capped attempts retained in denominators; structured coverage | New registered development amendment after component-budget freeze |
| Context assembly | Automated integration passed; live verification open | Working tree preserves mandatory content and output reserve; independently counts recent/evidence tokens; applies bounded reductions; records and validates durable proofs | Resolve live provider identity failure, verify final build and push the [component-token checkpoint](CONTEXT-COMPONENTS.md); more verified adapters |
| Episode accounting | Answering and foreground reads verified | Durable reservations/receipts, shared deadline, unknown outcomes retained, migration and kill/reopen checks; component proof linkage verified in working tree | [Daily background-index ledger](BACKGROUND-INDEX-BUDGET.md) implementation; opaque Apple/native token usage remains explicit |
| Semantic retrieval | Core protocol verified | Installed Apple English encoder; sealed sources, durable jobs, coverage holes, frozen continuations and manifests | Whole-corpus coverage, installed-encoder quality and daily budget |
| Backup and restore | Schema-4 compatibility verified | Explicit schema 1–4 recognition; chat/read inventories, no-clobber restore, exact-byte identity and unknown-bound preservation | Deletion-aware restore, retention/purge and polished restored-store opening |
| Service, MCP and imports | Deferred | Single-process native app owns the store | Multi-client service when justified, read-only MCP interface and authenticated imports |
| Policy and task lifecycle | Not started | Authorship and capture status retained | Authenticated lifecycle changes, expiry/reopen, read/disclosure/processing grants and dependencies |
| Revocation and deletion | Not started | No policy mutation or deletion feature enabled | Durable control epoch, output fencing, suppression and safe purge |
| External actions | Optional; deferred | No external tool execution enabled | Durable action journal, unknown outcomes, reconciliation and recovery |
| Summary tree | Optional; gated | No generated archive summary tree | Accepted raw-retrieval baseline checkpoint, then lineage/frontier/fence checks |
| Quality and economics | Unmeasured for current app | Historical lexical-only v4 source coverage and current implementation contract tests | Representative workload, installed hybrid/answering comparison, power design and held-out confirmation |
| Local release | Development build only | Buildable app with verified ad hoc signature | Release gates, packaging, diagnostics, recovery validation and user documentation |

## Parallel implementation assignments

The component wave is in the working tree. The verified checkpoint above remains the standalone-read source pin until current live verification passes and the implementation is committed and pushed.

| Owner | Surface | State and evidence |
|---|---|---|
| Context agent | Attributed recent/evidence preparation, geometric reductions and exact-byte source exclusions | Production and coordinator fixtures integrated; 143 context checks and 75 coordinator/proof checks passed in the combined app. Daily worker adoption requirements investigated |
| Provider agent | Verified counting session, attributed renderer, immutable count proof and continuous-clock freshness | Integrated: 58 pure and 232 HTTP checks passed; independent rendering oracle passed 30 checks. Live failure diagnosed: `created` is an observation timestamp on this server, unsuitable as a stable model-load epoch |
| Coordinating agent | Frozen component policy, GUI/CLI handoff and durable proof validation | Combined build and 1,190 checks passed; independent journal review findings closed. Latest live smoke failed before answer dispatch; resolution and final artifact verification remain |
| Provider agent draft; integration unassigned | Daily background-index ledger | Contract recorded; isolated pure-type draft compiles outside tracked sources. Draft boundary tests, schema migration, worker adoption, recovery and archive verification remain |

The combined results above were observed by the coordinating agent. Targeted suites overlap and must not be added to the whole-app count. The context review reproduced Unicode source-ID collapse that could hide older evidence behind recent candidates; the integrated fix preserves exact UTF-8 identities through selection, metering and semantic replay. Component journal review findings concerning source linkage, clock stamps, receipt scope and clock failure handling were reproduced and closed; the latest live provider failure remains open.

Read-only diagnosis of the live failure found that `/v1/models.created` changes on successive reads while the model ID, loaded state, engine, architecture, context limit, server version and template digest remain unchanged. The current implementation incorrectly binds `created` as a stable load epoch. The next fix needs an observable stable identity or an explicit contract for that unobservable dimension, followed by a regression fixture and live verification.

The standalone-read wave is integrated. Source owners are frozen after verification; no implementation assignment below remains active.

| Owner | Completed surface | Evidence |
|---|---|---|
| Ledger agent | Origin types, schema 4, indexed replay, lifecycle, atomic migration and exact identity | 209 standalone checks: 156 component and 53 process/recovery |
| Browser agent | Asynchronous read coordinator, shared search/page allowance and delivery fencing | 77 standalone checks: 56 local-read, 20 coverage and one harness encoder assertion |
| Backup agent | Frozen legacy recognition, read inventory, corruption rejection and recovery | Final root integration: 162 standalone checks, including 17 process/recovery |
| Coordinating agent | Central scope guards, partial-read handling, evaluation adoption and whole-app integration | 1,016 whole-app checks; 49 evaluation contracts; strict signature verification |
| Independent review agent | Reproductions, fix recheck and archive identity regressions | Reviewed findings closed; ten Unicode scope/archive checks merged into backup suite |

Independent review reproduced three material issues: canonical-equivalent Unicode IDs could cross a binary SQLite scope boundary, local-read preparation could reread excerpts after resource-limited coverage, and evaluation could infer limited coverage from an informational notice. Exact UTF-8 identity, early local-read coverage guards and structured coverage flags close those findings. No open material finding remains in that reviewed scope. This is not evidence that the full deferred architecture is complete.

## Verification

Counts overlap across scripts and must not be added together. The first two rows distinguish the current working tree from the pushed schema-4 checkpoint. Older measurements retain their original source pins.

| Check | Recorded result | Evidence boundary |
|---|---|---|
| Current working-tree whole-app integration, `scripts/check.py --app .build/boros/Boros.app` | **1,190 passed** | 156 episode, 56 local-read, 51 conversation/profile, 89 GUI, 9 native parser, 100 memory, 58 endpoint/admission, 143 context, 76 semantic, 145 backup/CLI, 232 HTTP, 75 component preparation/proof checks; implementation uncommitted |
| Pushed whole-app integration at `1f8e0a6` | **1,016 passed** | 156 episode, 56 local-read, 51 conversation/profile, 89 GUI, 9 native parser, 100 memory, 49 endpoint/admission, 96 context, 76 semantic, 145 backup/CLI, 189 HTTP |
| Component preparation/proof fixtures | **75 passed** | Actual coordinator limits, scope rejection, cancellation, deadline, durable invocation, backup/restore and journal corruption checks; included in 1,190 |
| Independent Qwen rendering oracle | **30 passed** | 24 template renderings and six rejection cases; shared renderer verified against Jinja |
| Ledger, `scripts/test_episode.py` | **209 passed** | Durable origins, reservations/receipts, exact identity, initiation conflicts, migration rollback and actual SIGKILL/reopen |
| Local reads, `scripts/test_local_read.py` | **77 passed** | Async lifecycle and delivery, bounded search/page, limited-coverage stop before reread/encoder; also included in app suites |
| Backup, `scripts/test_backup.py` | **162 passed** | Legacy 1–4 recognition, exact origin inventory, refreshed-hash corruption rejection, preserved unknowns and actual SIGKILL/reopen |
| Evaluation, `scripts/test_evaluation.py` | **49 passed** | Immutable v4 refusal, current-source unregistered execution, per-protocol receipts, zero-budget denominators, unknown timings and structured coverage |
| Development app signature | Previous artifact passed; final rebuilt artifact pending | Strict deep verification must be repeated after the live failure is fixed and the final build is frozen |
| Current working-tree live mlx-serve CLI | **Failed: `provider_adapter_unverified`** | First synthetic arithmetic turn failed before answer dispatch; 74 charged input tokens, one charged output token, zero held output, one calibration model call and seven HTTP attempts |
| Pushed schema-4 live mlx-serve CLI | Two synthetic arithmetic turns passed | Historical baseline: final turn completed with 218 input tokens, 3 output tokens, zero held output, 2 model calls, 7 HTTP attempts, 94 logical raw-work bytes, zero unknown inputs; counters are not two-turn totals |
| Final visual GUI check | Pending; Mac locked at last attempt | Requires an unlocked desktop and an isolated synthetic store |
| Previous schema-3 integration | 793 passed at `22c3402` | Historical answering/core-retrieval checkpoint |
| Earlier hybrid/backup integration | 478 passed at `38675c5` | Historical pre-episode checkpoint |
| Historical lexical-only development v4 | 224/224 eligible probes; 256 required spans; 32 synthetic histories | Frozen `semanticIndex:nil` helper; warm helper p95 59.70 ms and raw probe p95 4.72 ms; no answerer |

The passing historical live smoke establishes dispatch and history forwarding for its source checkpoint only. The current failed attempt does not establish component-wave live dispatch. The historical v4 result establishes synthetic source coverage for its pinned lexical branch. These results do not establish current hybrid answer quality, the 100k-event latency gate, general model competence or a cost improvement. Held-out cases remain unrun. See [IMPLEMENTATION.md](IMPLEMENTATION.md), [READ-EPISODES.md](READ-EPISODES.md) and [EVALUATION.md](EVALUATION.md).

## Next checkpoint

Finish the component-token checkpoint first. The combined application and durable proofs pass automated verification; the current live identity failure requires diagnosis and a verified fix before committing the implementation. The daily background-index ledger follows that checkpoint; its contract and isolated draft work are underway. Freeze a new development measurement amendment only after both implementations and their shared baseline stabilize. Apple encoder input tokens remain opaque; development mode records the uncertainty and strict known-input mode skips the encoder.

| Priority | Next work | Status | Required completion evidence |
|---|---|---|---|
| 1 | Exact recent/evidence token allocations | Automated checks pass; live identity failure open; implementation uncommitted | Resolve failure, rerun affected checks and live smoke, verify final signature, then commit and push |
| 2 | Background indexing budgets | [Contract recorded](BACKGROUND-INDEX-BUDGET.md); isolated draft underway; runtime enforcement absent | Durable global daily limits, preflight, unknown outcomes, migration, backup/restore and crash recovery verified |
| 3 | Hybrid answering quality and economics | Unmeasured | Frozen development protocol, representative workloads, answerer and comparative results before held-out confirmation |
| Before external clients | External continuation compatibility | Partial internal contract | Explicit ranking/scanner identities and resume policy before client ingestion |
| Before release | Final GUI visual recheck | Pending Mac unlock | Inspect rebuilt app using isolated synthetic data |

## Plan phases

| Plan phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Freeze contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External payload recovery, aggregate quotas, epoch suppression, deletion fencing and deletion-aware restore |
| 2 — Read-only baseline | Partial | Background-index budgets, component-token allocations, CLI/MCP disclosure grants, Arm B recall/latency and pilot cost report |
| 3 — Policy/task and optional actions | Not started | Lifecycle and scoped harness tests; action recovery if enabled |
| 4 — Optional tree | Gated | Accepted baseline before implementation; lineage, frontier and fence verification afterward |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations, frozen baseline/tree comparison and held-out quality/economics |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, deletion-aware restore, packaging and final visual verification |
