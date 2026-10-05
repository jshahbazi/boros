# Boros project status

Updated October 4, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`. Verified implementation checkpoint: `1f8e0a6`, pushed to GitHub. The preceding implementation checkpoint is `22c3402`. The complete [plan](../tracechat-plan.md) remains in progress.

The native prototype now combines durable text capture, exact selected-provider admission, hybrid source retrieval, shared answering/read accounting and verified backup/restore. The current whole-app integration passed **1,016 checks**. These checks establish the tested contracts. Installed hybrid answer quality, production latency and comparative economics remain unmeasured. No completion percentages or delivery dates are assigned.

## Work status

| Workstream | Status | Available now | Remaining work |
|---|---|---|---|
| Project setup and design | Foundation complete | Migrated to Boros; retained original plan, adversarial reviews and provenance; GitHub branch established | Keep contracts, evidence and status aligned |
| Native chat GUI | Implemented; automated lifecycle verified | Chats, drafts, restored transcripts, streaming, cancellation, source browser and backup/restore menu | Final visual recheck awaits an unlocked Mac |
| Local model connection | Implemented; live integration recorded | OpenAI-compatible mlx-serve at `http://localhost:11234/v1/`; selected Qwen model; structured messages and optional thinking control | Broader compatibility and reliability evaluation |
| Transport and credentials | Implemented | Loopback endpoints, redirect rejection, bounded SSE, explicit failures and optional Keychain credentials | Remote providers need their processing and disclosure contracts |
| Durable text capture | Implemented for accepted text | Complete bounded UTF-8 payloads; typed events, exact IDs/digests/status; chunks committed before display; invocation snapshots; exclusive owner and schema 1–3 migration | Released-version migrations, attachments, external payload protocol and aggregate ingestion quotas |
| Original-source retrieval | Metered baseline verified | Scoped metadata-first lexical search, bounded literal traversal, exact pages and hybrid retrieval; central scope assertion before inspection | Larger-archive scaling, external continuation versioning and measured hybrid quality |
| Standalone read episodes | Implemented and verified | Schema-4 chat/read origins; immutable scope and descriptor; indexed initiation replay; shared allowance, continuous deadline and recovery | Future read CLI/MCP adapters need explicit ownership and disclosure contracts |
| Source-browser accounting | Implemented and verified | Search plus initial page share a lease; explicit paging is bounded; worker queue, Stop/supersession/close/deadline fences and incomplete results | Visual verification; explicit continuation UX only after its compatibility contract |
| Evaluation accounting | Implemented; contracts verified | Isolated read episode per fixture/protocol; authoritative charges/holds/time/outcome; capped attempts retained in denominators; structured coverage | New registered development amendment after component-budget freeze |
| Context assembly | Partial; provider admission verified | Complete mandatory request, bounded recent/evidence context, exact Qwen whole-prompt counts and immutable request bytes | [Exact recent/evidence token allocations](CONTEXT-COMPONENTS.md), more verified adapters |
| Episode accounting | Answering and foreground reads verified | Durable reservations/receipts, shared deadline, unknown outcomes retained, migration and kill/reopen checks | Daily background-index budgets; opaque Apple/native token usage remains explicit |
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

Counts overlap across scripts and must not be added together. Current results refer to the schema-4 source checkpoint; older measurements retain their original source pins.

| Check | Recorded result | Evidence boundary |
|---|---|---|
| Whole-app integration, `scripts/check.py` | **1,016 passed** | 156 episode, 56 local-read, 51 conversation/profile, 89 GUI, 9 native parser, 100 memory, 49 endpoint/admission, 96 context, 76 semantic, 145 backup/CLI, 189 HTTP |
| Ledger, `scripts/test_episode.py` | **209 passed** | Durable origins, reservations/receipts, exact identity, initiation conflicts, migration rollback and actual SIGKILL/reopen |
| Local reads, `scripts/test_local_read.py` | **77 passed** | Async lifecycle and delivery, bounded search/page, limited-coverage stop before reread/encoder; also included in app suites |
| Backup, `scripts/test_backup.py` | **162 passed** | Legacy 1–4 recognition, exact origin inventory, refreshed-hash corruption rejection, preserved unknowns and actual SIGKILL/reopen |
| Evaluation, `scripts/test_evaluation.py` | **49 passed** | Immutable v4 refusal, current-source unregistered execution, per-protocol receipts, zero-budget denominators, unknown timings and structured coverage |
| Development app signature | Strict deep verification passed | Rebuilt current `.build/boros/Boros.app` |
| Current live mlx-serve CLI | Two synthetic arithmetic turns passed | Final turn completed: 218 input tokens, 3 output tokens, zero held output, 2 model calls, 7 HTTP attempts, 94 logical raw-work bytes, zero unknown inputs; counters are not two-turn totals |
| Final visual GUI check | Pending; Mac locked at last attempt | Requires an unlocked desktop and an isolated synthetic store |
| Previous schema-3 integration | 793 passed at `22c3402` | Historical answering/core-retrieval checkpoint |
| Earlier hybrid/backup integration | 478 passed at `38675c5` | Historical pre-episode checkpoint |
| Historical lexical-only development v4 | 224/224 eligible probes; 256 required spans; 32 synthetic histories | Frozen `semanticIndex:nil` helper; warm helper p95 59.70 ms and raw probe p95 4.72 ms; no answerer |

The live smoke establishes dispatch and history forwarding only. The historical v4 result establishes synthetic source coverage for its pinned lexical branch. Neither establishes current hybrid answer quality, the 100k-event latency gate, general model competence or a cost improvement. Held-out cases remain unrun. See [IMPLEMENTATION.md](IMPLEMENTATION.md), [READ-EPISODES.md](READ-EPISODES.md) and [EVALUATION.md](EVALUATION.md).

## Next checkpoint

The next implementation work is exact recent/evidence token allocation and durable daily background-index budgets. These can proceed in parallel against separate contracts. Freeze a new development measurement amendment only after those implementations and their shared baseline stabilize. Apple encoder input tokens remain opaque; development mode records the uncertainty and strict known-input mode skips the encoder.

| Next work | Status | Completion evidence |
|---|---|---|
| Exact recent/evidence token allocations | Contract recorded; implementation pending | Attributed selected-model component counts and final request snapshots agree; mandatory content remains intact |
| Background indexing budgets | Not started | Durable daily limits, preflight, unknown outcomes and recovery verified |
| Hybrid answering quality and economics | Unmeasured | Frozen development protocol, representative workloads, answerer and comparative results before held-out confirmation |
| External continuation compatibility | Partial internal contract | Explicit ranking/scanner identities and resume policy before client ingestion |
| Final GUI visual recheck | Pending Mac unlock | Inspect rebuilt app using isolated synthetic data |

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
