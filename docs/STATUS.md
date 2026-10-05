# Boros project status

Updated October 5, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`.

The latest pushed code checkpoint is **`0284ee0`**, which freezes genuine schema-4 archive compatibility. The preceding integrated feature checkpoint, **`9cf4d11`**, passed 1,297 whole-app checks. The current schema-5 background-indexing changes are in the working tree. Final component, crash-recovery, migration and archive checks pass. The rebuilt app's combined run passes through GUI/native checks, then fails because a synthetic memory migration fixture retains schema-5 tables when labeled as schema 1. Fixture correction and implementation publication remain pending. The complete [plan](../tracechat-plan.md) remains unfinished.

## Work status

“Implemented” describes available behavior within the stated boundary. It does not establish production readiness or measured answer quality. Evidence distinguishes the pushed baseline from the current working tree.

| Workstream | Status | Evidence and available behavior | Next required work |
|---|---|---|---|
| Project setup and design | Complete foundation | Boros repository and GitHub branch established; original plan, reviews and provenance retained | Keep implementation and evidence aligned with the plan |
| Native chat GUI | Implemented; visual check pending | Pushed baseline: chats, drafts, restored transcripts, streaming, cancellation, source browser and archive menus; 89 automated GUI checks | Verify new background-status menu in rebuilt app; final visual inspection awaits an unlocked Mac |
| Local model connection | Implemented; baseline live smoke passed | mlx-serve at `http://localhost:11234/v1/`; selected Qwen model; two public arithmetic turns passed at `9cf4d11` | Rerun live smoke for the new checkpoint; evaluate broader reliability |
| Transport and credentials | Implemented for local endpoints | Loopback restriction, redirect refusal, bounded SSE, explicit errors and optional Keychain credentials | Processing and disclosure contracts before enabling remote providers |
| Durable text capture | Implemented; schema-5 integration underway | Complete bounded UTF-8 sources, exact IDs/digests, capture status, durable streaming and exclusive ownership; pushed schema 4, current working-tree schema 5 | Complete schema-5 integration; external payload protocol, aggregate ingestion quotas and released-version migrations |
| Original-source retrieval | Implemented baseline | Scoped lexical search, bounded literal traversal, exact source pages and hybrid retrieval; scope checked before inspection | Representative archive scaling and measured hybrid quality |
| Standalone read episodes | Implemented; current migration/recovery verified | Immutable read origins, shared allowances, deadline, indexed retry identity and crash recovery; 225 current standalone checks | Ownership and disclosure contracts for external adapters |
| Source-browser accounting | Implemented baseline | Shared search/initial-page allowance; explicit paging; queue, Stop, supersession, close and deadline fences; incomplete results retained | Final visual verification and external continuation compatibility |
| Context assembly | Implemented and pushed | Mandatory input/output reserve preserved; independent recent/evidence counts, bounded reductions and durable proofs; 143 context and 97 coordinator checks at `9cf4d11` | Registered measurement amendment and additional verified adapters |
| Answering and read accounting | Implemented and pushed | Durable reservations, conservative unknown outcomes, continuous deadlines and provider-family quarantine | Opaque Apple/native input-token usage remains explicit; broader adapter verification |
| Background budget contract | Implemented; component verified | 167 pure checks; six global resource caps across anchored, nonoverlapping 24-hour windows; checked arithmetic and clock/recovery rules | Resolve memory self-test failure; complete combined verification and implementation commit/push |
| Background owner ledger | Implemented; component and process verified | Schema-5 windows/work, preflight, bounded source reader, recovery and atomic publication gate; 108 owner checks, included in 448 combined background/process checks | Resolve memory self-test failure; complete combined verification and implementation commit/push |
| Background indexing worker | Implemented; component and process verified | Metered startup probes, scheduling, seals, chunks and publication; exhaustion preserves pending work; 80 short checks plus seven full 4 MiB checks | Final combined app verification; installed-encoder quality and corpus coverage |
| Semantic retrieval | Core protocol implemented | Installed Apple English encoder, derived sidecar, resumable jobs, coverage holes and replayable manifests; background budgets in current working tree | Whole-corpus coverage, installed-encoder quality and stronger validation against temporary source corruption |
| Backup and restore | Schema-4 compatibility pushed; schema-5 targeted verification passed | Frozen schemas 1–4; schema-5 inventory retains charges/unknowns and releases prepared holds on restore; 182 final standalone checks pass | Resolve combined verification failure; deletion-aware restore and retention/purge |
| Evaluation accounting | Implemented; quality protocol pending | Isolated per-protocol read episodes, authoritative totals/time/outcome, structured coverage and capped attempts retained in denominators | Freeze a new development protocol after integration; run comparative answering measurements |
| Service, MCP and imports | Deferred | Native app owns the store in one process | Multi-client boundary when justified, read-only MCP and authenticated imports |
| Policy and task lifecycle | Not started | Authorship and capture status retained | Authenticated lifecycle changes, expiry/reopen, grants and dependencies |
| Revocation and deletion | Not started | Policy mutation and deletion features unavailable | Control epoch, output fencing, suppression, purge and deletion-aware restore |
| External actions | Optional; deferred | External tool execution unavailable | Action journal, reconciliation and unknown-outcome recovery if enabled |
| Summary tree | Optional; gated | No generated summary tree | Accept measured raw-retrieval baseline, then implement lineage/frontier/fence contracts |
| Quality and economics | Unmeasured for current app | Historical lexical-only synthetic coverage and current contract checks | Representative hybrid/answering comparison, latency/cost evidence, power design and held-out confirmation |
| Local release | Development build only | Rebuilt current app passes strict deep ad hoc signature verification | Final combined checks, packaging, diagnostics, recovery gates and visual verification |

## Current parallel assignments

Agents share the checkout and own distinct implementation surfaces. Component counts overlap with combined checks and must not be added to them.

| Owner | Owned surface | Current state | Evidence |
|---|---|---|---|
| Budget contract agent | Pure resource/window rules and checks; peer review of other owners | Implementation and peer review finished | 167 pure checks; publication, reboot and forged-anchor rechecks |
| Ledger agent | Main-store schema, background journal and owner checks; historical episode fixtures | Implementation frozen | 108 owner checks, 172 episode component checks and process recovery controls |
| Worker agent | Semantic-index integration, worker and fixtures | Implementation frozen | 80 short checks; seven full 4 MiB checks across two windows |
| Coordinating agent | Archives, wrappers, GUI integration, combined checks and status | Integration in progress | 448 final background/process checks, 225 standalone episode checks, 182 final backup checks and strict signature; memory migration fixture correction pending |

Peer review reproduced publication after a concurrent quarantine and a runtime/archive inconsistency in original window clock-anchor validation. The integrated fixes serialize the short sidecar publication commit with the owner eligibility gate and share intrinsic anchor validation. Actual contention checks prove concurrent owner mutation remains blocked through commit. Historical schema-2/3 fixtures were corrected to remove empty schema-5 tables before constructing older schemas; store validation remains strict. No material open defect remains in the reviewed paths.

Temporary source corruption followed by restoration remains a known limitation: initial and final whole-source hashes do not prove every intervening embedding used the original bytes. Exact excerpt digests still gate delivery. The full 4 MiB fixture uses a deterministic test encoder and establishes scheduling/accounting behavior; it does not measure Apple's encoder quality.

## Verification record

Results apply to their stated checkpoint or source capture. Older evaluation source pins and held-out artifacts remain unchanged.

| Check | Recorded result | Evidence boundary |
|---|---|---|
| Integrated app at `9cf4d11` | **1,297 passed** | Pushed schema-4 component checkpoint; current schema-5 app run stops at memory self-test |
| Frozen schema-4 archive recognition | **147 passed** | Isolated `9cf4d11` closure, genuine 30-object schema recreation and sidecar-free WAL controls; compatibility fix pushed at `0284ee0` |
| Current background pure contract | **167 passed** | Arithmetic, exact bindings, bounded recipes, clock anchors and recovery decisions |
| Current background owner ledger | **108 passed** | Authoritative totals, admission, live/offline corruption refusal and publication contention |
| Current background worker | **80 passed** | Actual short worker fixtures, quota pause/resume and publication fencing |
| Current complete 4 MiB worker fixture | **7 passed** | All 4,096 ranges completed across two windows; probes and resumed seals charged; deterministic encoder |
| Current background/process wrapper | **448 passed** | Final source capture; actual SIGKILL at ledger and four worker barriers, repeated reopen and worker resume |
| Current standalone episodes | **225 passed** | 172 component plus 53 migration/process/recovery checks; corrected historical fixtures |
| Current schema-5 backup wrapper | **182 passed** | Final source capture; archived charges, unknowns and prepared releases, frozen legacy recognition and process recovery |
| Local reads at `9cf4d11` | **77 passed** | Browser lifecycle, metered source access and coverage guards |
| Evaluation contracts at `9cf4d11` | **49 passed** | Frozen-baseline refusal, current-source diagnostics, receipts and coverage denominators |
| Qwen rendering oracle | **30 passed** | Independent Jinja comparison: 24 renderings and six rejection cases |
| Provider continuity review | **19 rechecks passed** | Supported metadata binding and quarantine regressions; instance continuity unobservable |
| Current development app signature | Passed | Strict deep verification of rebuilt development bundle |
| Live mlx-serve at `9cf4d11` | Two public turns passed | Synthetic arithmetic through context preparation; current schema-5 live smoke pending |
| Final GUI visual check | Pending | Mac locked at last attempt; use isolated synthetic data |
| Historical lexical-only development v4 | 224/224 eligible probes | Frozen synthetic lexical helper; no answerer or current hybrid quality evidence |

The first schema-5 combined run stopped on legacy fixtures that retained schema-5 tables after being relabeled as older schemas. Those fixtures are corrected, and the final 225-check episode suite passes. The next combined run passes the corrected episode suite and GUI/native checks, then stops at the memory self-test. An isolated reproduction confirms another synthetic fixture mismatch: `MemoryChecks.swift` relabels a fresh store as schema 1 without removing empty background tables. Correct that fixture while preserving the production legacy-inventory guard. A complete combined pass is required before calling the new wave integrated.

Apple/native input-token counts and provider load-instance continuity remain unobservable. Tests establish the stated accounting, recovery and compatibility contracts. Answer quality, a cost improvement, the 100k-event latency gate and production readiness remain unestablished. See [IMPLEMENTATION.md](IMPLEMENTATION.md), [BACKGROUND-INDEX-BUDGET.md](BACKGROUND-INDEX-BUDGET.md) and [EVALUATION.md](EVALUATION.md).

## Next work

| Priority | Work | Owner | Completion evidence |
|---|---|---|---|
| 1 | Correct the schema-1 memory fixture and finish schema-5 integration | Coordinating agent with ledger/worker owners | Complete full-app pass, live smoke, accurate docs and implementation commit/push |
| 2 | Freeze and run hybrid-answering development protocol | Evaluation implementation and review agents | Registered protocol, representative workload and comparative quality/resource results; held-out confirmation afterward |
| Before external clients | Tighten continuation and client ownership contracts | Retrieval/service agents | Ranking/scanner versioning, resume policy and disclosure grants |
| Before release | Verify native GUI visually | Coordinating agent | Unlocked desktop; rebuilt app with isolated synthetic data |
| Later phases | Implement policy/task, deletion and release contracts | Assign after baseline acceptance | Phase-specific exit criteria below |

## Plan phases

| Phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External payload recovery, aggregate ingestion quotas, epoch suppression, deletion fencing and deletion-aware restore |
| 2 — Read-only baseline | Partial | Final background-budget integration, registered component/answering measurement, CLI/MCP grants and recall/latency/cost evidence |
| 3 — Policy/task and optional actions | Not started | Lifecycle, scoped harness checks and action recovery if enabled |
| 4 — Optional summary tree | Gated | Accept measured baseline; then verify lineage, frontiers and fences |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations and held-out quality/economics |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, deletion-aware restore, packaging and final visual verification |
