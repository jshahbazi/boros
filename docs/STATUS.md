# Boros project status

Updated October 5, 2026. Repository: `/Users/johnshahbazian/development/boros`. Branch: `codex/boros-foundation`.

The current implementation checkpoint is **`b006b6a`**, committed and pushed. It integrates schema-5 background-index accounting with the native app and archives. Final verification passed **1,673 whole-app checks**, **455 background/full-source/process checks**, **183 backup checks**, **225 episode checks**, strict signature verification and two public live Qwen turns. Counts overlap. The complete [plan](../tracechat-plan.md) remains unfinished; current answer quality and economics remain unmeasured.

## Work status

“Implemented” describes available behavior within the stated boundary. It does not establish production readiness or measured answer quality. Evidence distinguishes the pushed baseline from the current working tree.

| Workstream | Status | Evidence and available behavior | Next required work |
|---|---|---|---|
| Project setup and design | Complete foundation | Boros repository and GitHub branch established; original plan, reviews and provenance retained | Keep implementation and evidence aligned with the plan |
| Native chat GUI | Implemented; visual check pending | Pushed baseline: chats, drafts, restored transcripts, streaming, cancellation, source browser and archive menus; 89 automated GUI checks | Final visual inspection of the background-status menu and chat flow; Mac locked at last attempt |
| Local model connection | Implemented; current live smoke passed | mlx-serve at `http://localhost:11234/v1/`; selected Qwen model; two public arithmetic turns passed at `b006b6a` | Evaluate broader reliability and model compatibility |
| Transport and credentials | Implemented for local endpoints | Loopback restriction, redirect refusal, bounded SSE, explicit errors and optional Keychain credentials | Processing and disclosure contracts before enabling remote providers |
| Durable text capture | Implemented and verified | Complete bounded UTF-8 sources, exact IDs/digests, capture status, durable streaming and exclusive ownership; current schema 5; genuine schemas 1–4 migrate | External payload protocol, aggregate ingestion quotas and released-version migrations |
| Original-source retrieval | Implemented baseline | Scoped lexical search, bounded literal traversal, exact source pages and hybrid retrieval; scope checked before inspection | Representative archive scaling and measured hybrid quality |
| Standalone read episodes | Implemented; current migration/recovery verified | Immutable read origins, shared allowances, deadline, indexed retry identity and crash recovery; 225 current standalone checks | Ownership and disclosure contracts for external adapters |
| Source-browser accounting | Implemented baseline | Shared search/initial-page allowance; explicit paging; queue, Stop, supersession, close and deadline fences; incomplete results retained | Final visual verification and external continuation compatibility |
| Context assembly | Implemented and pushed | Mandatory input/output reserve preserved; independent recent/evidence counts, bounded reductions and durable proofs; 143 context and 97 coordinator checks included in the current app pass | Registered measurement amendment and additional verified adapters |
| Answering and read accounting | Implemented and pushed | Durable reservations, conservative unknown outcomes, continuous deadlines and provider-family quarantine | Opaque Apple/native input-token usage remains explicit; broader adapter verification |
| Background budget contract | Implemented and pushed | 167 pure checks; six global resource caps across anchored, nonoverlapping 24-hour windows; checked arithmetic and clock/recovery rules | Measure representative workloads and resource-cap suitability |
| Background owner ledger | Implemented and pushed | Schema-5 windows/work, preflight, bounded source reader, recovery and atomic publication gate; 108 owner checks, included in 455 background/full-source/process checks | Measure representative workloads and resource-cap suitability |
| Background indexing worker | Implemented and pushed | Metered startup probes, scheduling, seals, chunks and publication; exhaustion preserves pending work; 80 short checks plus seven full 4 MiB checks | Installed-encoder quality and corpus coverage |
| Semantic retrieval | Core protocol implemented | Installed Apple English encoder, derived sidecar, resumable jobs, coverage holes and replayable manifests; durable background budgets integrated | Whole-corpus coverage, installed-encoder quality and stronger validation against temporary source corruption |
| Backup and restore | Schemas 1–5 verified and pushed | Frozen schemas 1–4; schema-5 inventory retains charges/unknowns and releases prepared holds on restore; 183 final standalone checks pass | Deletion-aware restore and retention/purge |
| Evaluation accounting | Implemented; quality protocol pending | Isolated per-protocol read episodes, authoritative totals/time/outcome, structured coverage and capped attempts retained in denominators | Freeze a new development protocol after integration; run comparative answering measurements |
| Service, MCP and imports | Deferred | Native app owns the store in one process | Multi-client boundary when justified, read-only MCP and authenticated imports |
| Policy and task lifecycle | Not started | Authorship and capture status retained | Authenticated lifecycle changes, expiry/reopen, grants and dependencies |
| Revocation and deletion | Not started | Policy mutation and deletion features unavailable | Control epoch, output fencing, suppression, purge and deletion-aware restore |
| External actions | Optional; deferred | External tool execution unavailable | Action journal, reconciliation and unknown-outcome recovery if enabled |
| Summary tree | Optional; gated | No generated summary tree | Accept measured raw-retrieval baseline, then implement lineage/frontier/fence contracts |
| Quality and economics | Unmeasured for current app | Historical lexical-only synthetic coverage and current contract checks | Representative hybrid/answering comparison, latency/cost evidence, power design and held-out confirmation |
| Local release | Development build only | Rebuilt current app passes strict deep ad hoc signature verification | Packaging, diagnostics, release recovery gates and visual verification |

## Current parallel assignments

Agents share the checkout and own distinct implementation surfaces. Component counts overlap with combined checks and must not be added to them.

| Owner | Owned surface | Current state | Evidence |
|---|---|---|---|
| Budget contract agent | Pure resource/window rules and checks; peer review of other owners | Implementation and peer review finished | 167 pure checks; publication, reboot and forged-anchor rechecks |
| Ledger agent | Main-store schema, background journal and owner checks; historical fixtures | Integrated; answering-evaluation path report complete | 108 owner checks, 172 episode component checks and process recovery controls |
| Worker agent | Semantic-index integration, worker, fixtures and component docs | Integrated and documented | 80 short checks; seven full 4 MiB checks across two windows |
| Coordinating agent | Archives, wrappers, GUI integration, combined checks and status | Integrated and pushed | 1,673 app, 455 background/full-source/process, 225 episode and 183 backup checks; strict signature and live smoke |

Peer review reproduced publication after a concurrent quarantine and a runtime/archive inconsistency in original window clock-anchor validation. The integrated fixes serialize the short sidecar publication commit with the owner eligibility gate and share intrinsic anchor validation. Actual contention checks prove concurrent owner mutation remains blocked through commit. Historical schema-1/2/3 fixtures were corrected to remove empty schema-5 tables before constructing older schemas; store validation remains strict. No material open defect remains in the reviewed paths.

Temporary source corruption followed by restoration remains a known limitation: initial and final whole-source hashes do not prove every intervening embedding used the original bytes. Exact excerpt digests still gate delivery. Schema-5 restore preserves archived accounting, with no merge of post-backup charges or external budget antirollback authority. Global limits cover work in one owner store. The full 4 MiB fixture uses a deterministic test encoder and establishes scheduling/accounting behavior; it does not measure Apple's encoder quality.

## Verification record

Results apply to their stated checkpoint or source capture. Older evaluation source pins and held-out artifacts remain unchanged.

| Check | Recorded result | Evidence boundary |
|---|---|---|
| Current integrated app at `b006b6a` | **1,673 passed** | 167 pure background, 108 owner, 80 worker, 172 episode, 56 local-read, 51 conversation/profile, 89 GUI, nine native parser, 100 memory, 105 admission, 143 context, 76 semantic, 166 backup, 254 HTTP and 97 coordinator checks |
| Previous app at `9cf4d11` | **1,297 passed** | Historical schema-4 context-component checkpoint |
| Frozen schema-4 archive recognition | **147 passed** | Isolated `9cf4d11` closure, genuine 30-object schema recreation and sidecar-free WAL controls; compatibility fix pushed at `0284ee0` |
| Current background pure contract | **167 passed** | Arithmetic, exact bindings, bounded recipes, clock anchors and recovery decisions |
| Current background owner ledger | **108 passed** | Authoritative totals, admission, live/offline corruption refusal and publication contention |
| Current background worker | **80 passed** | Actual short worker fixtures, quota pause/resume and publication fencing |
| Current complete 4 MiB worker fixture | **7 passed** | All 4,096 ranges completed across two windows; probes and resumed seals charged; deterministic encoder |
| Current background/full-source/process wrapper | **455 passed** | Final source capture; actual SIGKILL at ledger and four worker barriers, repeated reopen and worker resume |
| Current standalone episodes | **225 passed** | 172 component plus 53 migration/process/recovery checks; corrected historical fixtures |
| Current schema-5 backup wrapper | **183 passed** | Final source capture; archived charges, unknowns and prepared releases, frozen legacy recognition and process recovery |
| Current local-read wrapper | **77 passed** | Browser lifecycle, metered source access and coverage guards |
| Current evaluation contracts | **49 passed** | Frozen-baseline refusal, current-source diagnostics, receipts and coverage denominators |
| Qwen rendering oracle | **30 passed** | Independent Jinja comparison: 24 renderings and six rejection cases |
| Provider continuity review | **19 rechecks passed** | Supported metadata binding and quarantine regressions; instance continuity unobservable |
| Current memory recovery wrapper | **108 passed** | 100 component plus process/reopen checks |
| Current semantic recovery wrapper | **6 passed on each of two reopens** | Actual SIGKILL, cursor/source integrity, completion and frozen replay |
| Current development app signature | Passed | Strict deep verification of rebuilt development bundle |
| Current live mlx-serve | Two public turns passed | Thinking off; final foreground turn completed with 218 input tokens, three output tokens, zero held output, two model calls, 12 HTTP attempts, 208 logical raw bytes and zero unknown input operations; counters are not two-turn totals |
| Final GUI visual check | Pending | Mac locked at last attempt; use isolated synthetic data |
| Historical lexical-only development v4 | 224/224 eligible probes | Frozen synthetic lexical helper; no answerer or current hybrid quality evidence |

Integration initially exposed synthetic migration fixtures that retained schema-5 tables after being relabeled as older schemas, and a semantic wrapper missing its new worker dependency. Corrected fixtures verify background tables are empty before dropping them; production historical-inventory guards remain strict. Final standalone and combined checks pass on the committed sources.

Apple/native input-token counts and provider load-instance continuity remain unobservable. Tests establish the stated accounting, recovery and compatibility contracts. Answer quality, a cost improvement, the 100k-event latency gate and production readiness remain unestablished. See [IMPLEMENTATION.md](IMPLEMENTATION.md), [BACKGROUND-INDEX-BUDGET.md](BACKGROUND-INDEX-BUDGET.md) and [EVALUATION.md](EVALUATION.md).

## Next work

| Priority | Work | Owner | Completion evidence |
|---|---|---|---|
| Complete | Schema-5 background-indexing checkpoint | Contract, ledger, worker and coordinating agents | Verified and pushed at `b006b6a`; explicit token, restore and source-integrity limits retained |
| 1 | Implement and freeze hybrid-answering development protocol | Evaluation implementation and review agents; path contract reviewed | Registered protocol, representative workload and comparative quality/resource results; held-out confirmation afterward |
| Before external clients | Tighten continuation and client ownership contracts | Retrieval/service agents | Ranking/scanner versioning, resume policy and disclosure grants |
| Before release | Verify native GUI visually | Coordinating agent | Unlocked desktop; rebuilt app with isolated synthetic data |
| Later phases | Implement policy/task, deletion and release contracts | Assign after baseline acceptance | Phase-specific exit criteria below |

## Plan phases

| Phase | Status | Outstanding exit criteria |
|---|---|---|
| 0 — Contracts and evaluation | Partial | Executable policy/task/gate contracts, failure schedules, experiment split and power design |
| 1 — Evidence foundation | Partial | External payload recovery, aggregate ingestion quotas, epoch suppression, deletion fencing and deletion-aware restore |
| 2 — Read-only baseline | Partial | Registered component/answering measurement, CLI/MCP grants and recall/latency/cost evidence |
| 3 — Policy/task and optional actions | Not started | Lifecycle, scoped harness checks and action recovery if enabled |
| 4 — Optional summary tree | Gated | Accept measured baseline; then verify lineage, frontiers and fences |
| 5 — Compare and confirm | Not started | Arms A–E, validation ablations and held-out quality/economics |
| 6 — Local release | Not ready | Hardened import, resumable purge, diagnostics, deletion-aware restore, packaging and final visual verification |
