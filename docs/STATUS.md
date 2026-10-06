# Boros status and roadmap

Updated October 6, 2026. Branch: `codex/boros-foundation`.

This is the planning index for Boros: available features, implementation gaps, recorded evidence, remaining design, and dependencies between next steps. Detailed contracts remain in the linked documents. TraceChat is the historical name of the original design and review.

Start with [next work](#6-dependency-ordered-next-work) and [open decisions](#8-decisions-before-selecting-work). Use [the feature inventory](#2-feature-inventory) and [recorded evidence](#4-recorded-evidence) to check the basis for a choice.

## 1. Current position

Boros provides a native macOS chat application, durable accepted text, bounded recent context and historical evidence, source search and paging, local model integration, resource accounting, semantic maintenance, backup/restore, and public-chat ingestion. The System editor now supports explicit saved instructions across restart. Reliable answering across long histories, representative performance, and total economics remain unproven.

The design goal is evidence-backed continuity within bounded context and resource allowances. The summary tree is optional and must earn its place through comparison with the source-retrieval baseline. See [the product decision](../tracechat-plan.md#1-product-decision).

| Snapshot | Status |
|---|---|
| Latest verified code wave | Schema-10 original dates preserved through import, retrieval, v3 context, input receipts, restart and archive recovery; temporal answer accuracy remains unmeasured |
| Latest preceding evidence documentation | `9ea5c90`: traced failures and controlled long-chat results |
| Underlying integrated foundation | `b006b6a`: schema-5 background accounting, on top of selected-Qwen context and read-episode work |
| Latest recorded application verification | 3,368 checks passed against the optimized matching-source app, including 35 date, 55 framing, 610 component-preparation, 81 retrieval-strategy, 113 UI, 150 context/settings, 233 backup, 261 endpoint integration, 23 answering, 19 import and 12 offline diagnostic checks; 11 separate genuine schema-9 writer checks passed; suite counts overlap |
| Latest imported-chat result | Lexical, hybrid, and exact-page paths each recovered 12/12 selected answerable probes in warm and process-restart profiles |
| Answering model | JSON-object complete-exchange amendment: 9/9 operational, fully delivered and conditionally eligible; 9/9 valid objects, 6/9 tasks passed; original/instruction-only controls each 5/9; preceding paired range-aware diagnostic hybrid 7/12, recent-only 6/12; older failure and unknown hold retained |
| Running GUI/build freshness | `.build/boros-source-time-delivery/Boros.app` built from matching frozen inputs; controlled ordinary GUI Send/Stop and valid/invalid JSON passed with saved instructions, capture and original receipt/accounting validation. The user's existing GUI process and final visual release walkthrough remain unverified |
| Shared answering work | Integrated and verified across ordinary GUI Send, explicit strategies and the public driver; paired live Qwen diagnostic completed |
| Release state | Development application with local ad hoc signing; no production-readiness claim |

**Completed first milestone:** shared answering path, controlled verification and a paired production-path diagnostic. The latest separate JSON-object control delivered and validated all nine complete packs; all nine responses were valid objects, and Qwen passed 6/9 tasks. Three answer mismatches remain, including two citation failures. The original and generic instruction-only controls each passed 5/9. These reused one-replicate development probes establish no representative quality claim. Original-time preservation is verified through import, context delivery, restart and archives; temporal answering is unmeasured. Next work is independently frozen larger histories, natural questions, corrections, temporal answering and scaling measurements. Further scoped-policy work is queued after this recall-quality work; the full architecture, service interfaces, data lifecycle and release remain unfinished.

### Status labels

| Label | Meaning |
|---|---|
| Available | Implemented in committed application code or developer tooling, within the stated limits |
| Partial | Some required behavior exists; the row names what remains |
| Working tree | Source exists outside the verified committed checkpoint; integration and correctness are not assumed |
| Planned | Specified by the design; implemented behavior is not established |
| Gated | Requires prior contracts or measured evidence before enablement |
| Unmeasured | Needs workload evidence; passing contract checks does not establish it |

## 2. Feature inventory

### Application and model access

| Feature | Status | Available behavior | Remaining work or boundary |
|---|---|---|---|
| Native chat interface | Available | AppKit transcript/editor, conversation picker, new chats, drafts, keyboard controls, undo/redo, streaming and Stop | Final visual recheck pending; automated UI evidence recorded separately |
| Conversation continuity | Available | Stored conversations and drafts reopen after restart | GUI uses the `default` project; full project/task management UI unfinished |
| Instruction/generation settings | Available | Editable instructions/settings, explicit Save instructions with restart restoration, and profile-specific controls | Saved System text applies to future requests across chats/profiles in the local store; scoped standing-policy lifecycle remains unfinished |
| Selected local HTTP model | Available | Configured Qwen through mlx-serve; structured role messages and explicit errors | Answering needs a running server; exact admission restricted to the verified combination below |
| HTTP transport | Available | Loopback destinations, redirect refusal, bounded SSE, cancellation and incomplete-result handling | Client cancellation cannot establish immediate server compute cancellation; remote processing unavailable |
| Credentials | Available | Optional API credentials in macOS Keychain | Excluded from history and archives |
| Qwen thinking/sampling | Available | Thinking toggle, temperature, seed and output cap | JSON mode requires thinking off; no thinking-budget control; unsupported controls disabled |
| Qwen JSON-object output | Available | Optional counted format request, saved setting, complete capture and invalid-object warning; verified through shared Send and archive/reopen | Defaults off; exact selected provider only; schema/joint-thinking modes refused; valid JSON does not establish correct answers |
| Native GGUF/Bonsai paths | Partial | Existing native process execution and runtime controls | Exact input admission, authoritative output usage and immutable runtime identity unverified |
| Source browser | Available | Search Memory, source selection, exact UTF-8 pages, cancellation and incomplete coverage | No tree navigation, complete timeline API or deletion controls |
| Maintenance visibility | Available | Background Indexing Status shows allowance and pause reasons | Cap suitability and final visual inspection open |
| Distribution | Partial | Apple silicon/macOS 14+ development build; Swift/Python build scripts; no bundled weights | Release packaging, operational guide and release gates unfinished |

The verified HTTP adapter targets `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` with mlx-serve `26.10.1`. Unsupported model/template/server combinations fail explicitly. Historical arithmetic turns establish integration only. See [provider admission](PROVIDER-ADMISSION.md) and [GUI provenance](GUI-ORIGIN.md).

### Evidence, ingestion and recovery

| Feature | Status | Available behavior | Remaining work or boundary |
|---|---|---|---|
| Complete accepted text | Available | Bounded human/assistant UTF-8 payloads, stable IDs, SHA-256 digests, scope, order and capture status | Rich attachments and external-blob protocol unfinished |
| Durable input/output capture | Available | Human input commits before dispatch; received visible chunks commit before display; atomic final event/index publication | Bytes never received/committed cannot be recovered; hidden reasoning outside capture promise |
| Crash/restart behavior | Available | Exclusive owner, WAL/FULL durability, idempotent receipts, interrupted capture and episode recovery | No automatic inference replay; released-version migration policy unfinished |
| Store schema | Available | Main schema 10 adds canonical optional original-date metadata and civil-day index; prototype schemas 1–9 retain original evidence and unknown dates on migration | Prototype compatibility checks do not establish released-version support |
| Tool/subagent capture | Planned | Distinct event types/authorship specified | No complete tool/subagent capture adapter or agent tool loop; public importer accepts text user/assistant roles only |
| Public chat import | Available | BEAM, DevGPT, ShareGPT and role-message JSON/JSONL; selection, prefixes, provenance and readback into a fresh private store | No existing-store merge, account-export branches, Parquet, tool/system/developer roles or multimodal input |
| Imported chronology | Partial | Explicit OpenAI message timestamps retain verified original literal, precision, timezone status, artifact hash and pointer; indexed civil-day reads and v3 context delivery; [contract](SOURCE-TIME.md) | Capture time remains separate; unknown dates stay unknown; batch/share adapters, natural-language date filtering, universal UTC ordering and temporal answer accuracy remain |
| Import publication | Available | Strict validation, private staging, exclusive atomic publication and refused overwrite | Death can leave unpublished staging; importer sidecars need separate preservation |
| Attachments/extraction | Planned | Complete binary bytes and versioned extractors specified | No attachment/extractor pipeline or searchable-content guarantee |
| Aggregate ingestion quotas | Planned | Per-event/import limits exist | Store-wide quotas, streaming intake and external-blob recovery unfinished |
| Backup/verify/restore | Available | Consistent SQLite snapshots, source/journal checks, private no-clobber restore to a new folder; GUI/CLI | Settings captured separately; credentials, semantic sidecar and importer sidecars excluded |
| Derived rebuild after restore | Available | Semantic rebuild uses archived background accounting | Point-in-time ledger; later charges not merged; external antirollback absent |
| Encryption/sync/scheduled backup | Planned/later | Private filesystem permissions | Encryption/key management, remote sync and scheduled backups unavailable |

Intake limits include 4 MiB per event, 100,000 messages per selected imported chat and 128 MiB per original/canonical import document. These are storage limits, not provider token guarantees. See [chat import](CHAT-IMPORT.md), [backup/restore](BACKUP-RESTORE.md) and [storage boundary](IMPLEMENTATION.md#storage-boundary).

### Retrieval and context

| Feature | Status | Available behavior | Remaining work or boundary |
|---|---|---|---|
| Literal retrieval | Available | Exact matching independent of FTS/semantic tokenization; metered UTF-8 traversal and page-boundary matching | Archive traversal can be expensive and allowance-limited; ordinary Send does not automatically run it |
| Lexical retrieval | Available | Scoped FTS5 candidates; manual all-term and automatic any-term selection | Natural-question recall, scaling and candidate-cap suitability unmeasured |
| Automatic query selection | Available | Up to eight distinct alphanumeric terms; bounded quoted spans share priority before prose fallback | Natural questions, unquoted late anchors and paraphrases remain unmeasured |
| Lexical excerpt selection | Available | Shared selector favors clustered terms and preserves exact offsets; 4,096-byte cap | Considers first occurrences; repeated-occurrence ranking remains limited |
| Exact source paging | Available | Digest-bound, scalar-safe original-source reads | External continuation/scanner/ranking compatibility unfinished |
| Scope/source validation | Available | Exact UTF-8 identity; scope checked before payload access; range/digest validation; recent exclusions before candidate limits | External client authorization/disclosure unavailable |
| Semantic/hybrid retrieval | Partial | Installed Apple English encoder, chunks, lexical fallback, coverage holes and manifests | Conservative code/multilingual/ambiguous-input support; broad usefulness unmeasured |
| Metadata/timeline/neighbors | Partial | Scoped metadata plus one immediate following-assistant prefix per selected human source | Complete timeline/neighbor APIs and authoritative reply relationships unfinished; adjacency heuristic and candidate cap can miss evidence |
| Recent verbatim context | Available | Independent allocation, whole original messages and v2 host source-ID/role/status labels | Labels consume the existing cap; representative exact-follow-up tests and retrieval recovery remain |
| Historical evidence assembly | Available | Bounded excerpts, source IDs, authorship/status; complete current request preserved | Selection can miss evidence; provenance does not prove answer correctness |
| Selected-Qwen component caps | Available | Independently counted 8,000 recent and 12,000 evidence tokens; whole rendered prompt counted separately | New registered comparison has not adopted settings; native/Apple counts opaque |
| Context reductions/output reserve | Available | Whole optional messages/spans removed under original lease; mandatory input and response reserve preserved | New provider adapters need renderer/count verification |
| Private selection/delivery audit | Available | Durable bodies, count/reduction proofs and delivered source ranges | No complete “inspect this turn” UI; full semantic replay manifests absent after sidecar-free restore |
| Model-driven memory-tool loop | Planned | Bounded planning, reads, neighbors and zoom specified | Current answer path selects evidence in the host; no autonomous historical-search loop |
| Summary orientation/tree zoom | Gated | Versioned chronological trees and reproducible frontiers specified | No generated tree, model zoom tool or tree-backed whole-history view |

See [context components](CONTEXT-COMPONENTS.md), [semantic retrieval](SEMANTIC-RETRIEVAL.md) and [retrieval/context boundary](IMPLEMENTATION.md#retrieval-and-context-boundary).

### Resource accounting and maintenance

| Feature | Status | Available behavior | Remaining work or boundary |
|---|---|---|---|
| Answering episode allowance | Available | One lease covers capture, preparation, retrieval, discovery, counts, calibration and answering | Complete token enforcement limited to observable adapters |
| Standalone read episodes | Available | Durable browser/evaluation origins, retry identity, shared search/initial-page allowance and deadlines | External ownership/disclosure planned |
| Indexed episode setup | Available | Atomic totals, snapshot membership, settlement ownership and normalized quarantine projections; complete startup/archive reconstruction | Physical performance and complete input/dependency metering remain unmeasured/unfinished |
| Terminal cleanup | Available | Terminal fence commits before 32-row metadata-only batches; finite prepaid attempts and separate startup admin counters; holds retained while pending | Complete managed consumer gates and human/control maintenance sponsor remain unfinished |
| Reserve/arm/settle | Available | Reserve before work; armed unknown charges/holds survive Stop, death, reopen and restore | Conservative charges are not actual billing |
| Continuous deadline/Stop | Available | Deadline includes queueing/sleep; stale deliveries/handoffs fenced | Budget revision is not policy/deletion control epoch |
| Provider quarantine | Available | Violations fence provider family across metadata changes and later handoffs | Same-metadata reload, weight/binary attestation and atomic provider lease unobservable |
| Metered foreground reads | Available | Metadata-first lexical selection; charged validation/matching, pages and bounded vector/metadata work | Logical-work counters do not measure physical disk I/O or every internal comparison |
| Background allowance | Available | Six shared caps across projects/fingerprints/retries/rebuilds; anchored 24-hour windows in one store | Machine-wide accounting/external antirollback absent; cap suitability unmeasured |
| Background worker/recovery | Available | Charged probes/seals/chunks, cursors, quota pause and publication gate; incomplete prefixes cannot rank | Deterministic 4 MiB fixture measures mechanics, not Apple quality |
| Semantic source integrity | Partial | Full-source seals and delivered excerpt digests gate publication/delivery | Temporary corruption then restoration can evade proof that every embedding used original bytes |
| Coverage reporting | Available | Unsupported/pending/failed ranges and resource frontiers explicit; lexical fallback | Coverage limits can exist even when a selected gold span is recovered |

Foreground development caps include 1,000,000 aggregate input tokens, 16,000 output tokens, 12 model calls, 24 memory operations, 256 MiB logical source work and a 120-second deadline. Auxiliary HTTP/vector/metadata/encoder/journal guards are in [episode budgets](EPISODE-BUDGET.md).

Background defaults are 512 MiB logical source work, 4,096 encoder calls, 16 MiB encoder input, 32 MiB vector publication, 100,000 metadata rows and 4,096 new source jobs per window. Apple tokenizer/input usage remains unknown. See [background budgets](BACKGROUND-INDEX-BUDGET.md).

### Interfaces, authority and data lifecycle

| Feature | Status | Available behavior | Remaining work or boundary |
|---|---|---|---|
| Developer CLI | Available/partial | Build, diagnostics, import, backup/verify/restore and smoke entry points | No general authenticated memory-service CLI for all planned operations |
| Multi-client service | Planned | Native process owns its store exclusively | Service/IPC ownership, concurrency and capture integration |
| Read-only MCP | Planned | No exposed memory MCP server | Scope/disclosure grants, authentication and continuation compatibility |
| Authenticated live ingestion | Planned | Offline fresh-store importer exists | Capture authentication, idempotency and role/completeness contracts |
| Provenance/authority separation | Partial | Historical assistant/imported content remains attributed evidence; no imported authority activation | Policy/task capabilities and adversarial action tests unfinished |
| Standing policies | Partial | Internal explicit human operations, source links, scopes/conflicts, expiry, supersession and revocation | Unexposed; bounded funded renderer implemented; counted integration, shared runtime enforcement and operational journal contract pending |
| Standing-policy rendering | Internal preparation | Paid validated policy state, complete selected records/source spans and lower-only mandatory message bounds | No consumer permission; counted actual-body proof and shared gates remain unfinished |
| Task lifecycle | Partial | Internal human-owned new/select/suspend/resume/complete/cancel/reopen | Internal atomic managed acceptance and immutable bindings implemented; interface and runtime gates pending; expired/revoked exceptions remain inactive on reopen |
| Remote managed processing | Gated | Local/loopback transport | Destination intersection across transitive input lineage, routing revisions and dispatch gates |
| External disclosure/export | Gated | Explicit local archives and import provenance exist | Separate unmanaged-client/export grants; no all-history HTML export |
| Control epoch/revocation | Partial | Separate durable authority epoch advances on startup, task/policy mutation and temporal changes | Shared source/route dependency, dispatch, page, output and publication gates unfinished |
| Retention/suppression | Planned | Accepted content retained; deletion controls unavailable | Retention policy, resumable suppression and serving fences |
| Purge/deletion-aware restore | Planned | Restore supports stores without deletion controls | Inventory payloads, FTS/WAL, journals, snapshots, derivatives and backups; external deletion ledger before old restore serving |
| External actions | Gated/optional | No external tool execution | Capabilities, durable intent, adapter idempotency/outcome lookup and unknown-outcome reconciliation |

These are separate contracts. Local storage, provenance and retrieval journals do not establish deletion safety, policy enforcement, action recovery or downstream control over an unmanaged client. See [plan sections 3, 6, 7, 10 and 12](../tracechat-plan.md).

## 3. Shared answering implementation

Ordinary selected-Qwen Send and the diagnostic use `AnswerAttemptCoordinator`. Atomic acceptance, source preparation, provider counts/calibration, invocation linkage, commit-before-visible streaming, Stop, transport drain and durable finalization share one original lease. Host preference-save failures close accepted episodes without dispatch. Native profiles retain their existing lifecycle.

| Surface | Verified behavior | Boundary |
|---|---|---|
| `ContextRetrievalStrategy` and preparation | Explicit recent-only avoids historical payload, metadata/vector and query-encoder work; hybrid retains the current scoped selector | Recent-only still reads bounded recent messages; nil semantic index remains lexical retrieval |
| Shared coordinator and GUI | Controlled success, incomplete/cancelled output, stale callbacks, runner ownership, post-acceptance host-save failure and Stop after the first durable visible chunk | Client cancellation cannot prove immediate server compute cancellation |
| `AnswerEvaluationCommand` and Python scorer | Original 18-attempt pilot plus three fixed public DevGPT projections; restored overlays, per-hybrid Apple construction, quiescent measurement, oracle separation and content-free reports | Range-aware repeat passed hybrid 7/12 and recent-only 6/12; hybrid delivered all gold; five evidence-present failures and representative gates remain |
| Separate sufficient-evidence control | Nine frozen complete-exchange packs, distinct version-2 native pins and original-input/count/source validation; 9/9 complete, fully delivered and validated; 5/9 task successes; [contract and results](EVIDENCE-CONTROL.md) | Curated reproduction/citation on reused development questions; three response-format failures and one answer mismatch; representative quality and general over-cap feasibility remain separate |

The contract and invocation are in [ANSWER-EVALUATION.md](ANSWER-EVALUATION.md). The first paired Qwen diagnostic completed; controlled transport is verified. A wrong task answer remains an operationally complete captured invocation. Fatal/missing/timeout attempts retain their declared denominators with explicit unknown accounting.

## 4. Recorded evidence

### Verification checkpoints

The latest answering-control wave was rebuilt and tested on October 6, 2026. Older results retain their original boundaries. Counts overlap and must not be summed.

| Surface | Recorded result | Evidence boundary |
|---|---|---|
| Original source-date amendment | **3,368 application checks passed**; strict deep signature verification; 11 genuine schema-9 writer checks passed | Frozen 135-file capture; canonical original date proof, counted v3 framing, migration/archive preservation and legacy request validation; temporal answer quality unmeasured |
| JSON-object answering amendment | **3,264 application checks passed**; strict deep signature verification; all nine live packs delivered and validated, 9/9 valid objects, 6/9 task success | Frozen 131-file capture; 90/90 live source hashes matched; original System/packs/questions/rubrics/caps unchanged; 107 oracle cases and 45 live prompt-count checks passed; reused one-replicate diagnostic |
| Format-instruction answering repeat | **3,219 application checks passed**, including 23 answering and 24 control checks; strict deep signature verification; all nine live packs delivered and validated, 5/9 task success | Frozen 131-file source capture; source/questions/scoring/caps unchanged; no improvement; app defaults unchanged |
| Complete-exchange answering control | **3,214 application checks passed**, including 23 answering and 19 control checks; strict deep signature verification; all nine live packs delivered and validated, 5/9 task success | Frozen 131-file source capture; 90/90 live implementation hashes matched; reused curated questions, one replicate; representative quality remains unestablished |
| Saved System instructions | 3,109 application checks passed; 100 UI, 150 context/settings and 229 backup checks include migration, exact UTF-8, clearing, bounds and failed-save preservation; real Send endpoint received restored instructions on success and Stop | Frozen 123 Sources/scripts/Tests files; actual counted request linkage and private backup restoration; no scoped instruction or model-following claim |
| Bounded prepaid terminal cleanup | 3,012 application checks; 75 cleanup/process checks, 245 backup/process checks, nine genuine schema-8 writer checks and six full-schema freeze checks passed | Frozen 102-file Sources/scripts verification capture; bounded transaction work and durable failed-attempt charges; no representative performance or managed live-consumer claim |
| Funded standing-policy preparation | 3,094 application checks, including 82 renderer/owner contracts; 105 focused checks include 23 genuine SIGKILL/two-restart checks | Frozen 105-file Sources/scripts capture; no token, complete input-proof, rebuild-anchor or live-consumer permission claim |
| Indexed episode accounting (historical schema-8 checkpoint) | **2,932 application checks passed**; 141 focused accounting/process checks, 217 backup/process checks, seven genuine schema-7 writer checks and five full-schema checks; strict deep signature verification | Frozen 98-file Sources/scripts capture; atomic writes, complete reconstruction, confidence fencing and constant VM costs in tested inventories; terminal cleanup was unfinished at that checkpoint; schema 9 now implements it; live consumers remain unfinished |
| Paid authority cache/session checks | **2,779 application checks passed**, including 105 cache/session contracts; strict deep signature verification | Frozen 94-file Sources/scripts capture; original allowance and lease, bounded warm checks, write/time/Stop fences and retained failed charges; setup scan metering and live consumers unfinished |
| Dormant managed authority bindings | **2,674 application checks passed**; strict deep signature verification; 157 binding contracts, 32 controlled public checks and 35 actual old-writer checks | Frozen 90-file Sources/scripts capture; complete legacy migration, atomic task acceptance and conservative funded diagnostic; live gates remain unfinished |
| Bounded clock checkpoints | **2,508 application checks passed**; strict deep signature verification; 70 clock contracts plus 18 real SIGKILL checks | Frozen 84-file Sources/scripts snapshot; 9,000 ticks retain one checkpoint; exact quota boundaries untested; runtime gates unfinished |
| Dormant authority-state foundation | **2,420 application checks passed**; strict deep signature verification; 132 authority checks | Frozen Sources/scripts match the worktree; genuine schema-5 old-writer archive accepted through seven separate checks; policy mutations unexposed and runtime gates unfinished |
| Shared answering source wave | **2,162 application checks passed**; strict deep signature verification | Preceding answering-wave source snapshot; includes 517 preparation/strategy/coordinator checks, 93 GUI self-checks and 20 answering contracts |
| Recent-source framing amendment | **2,287 application checks passed**; strict deep signature verification; five additional native checks | Frozen source matches that recorded wave; 39 framing checks, 544 component/strategy/coordinator checks, 32 rubric checks and genuine v1 count/admission/archive/restore; separate 32-check public suite overlaps 27 default checks |
| Public developer-history amendment | **2,218 application checks passed**; strict deep signature verification; five additional native checks | Copied Swift source matches amendment; 29 rubric and 27 developer contracts included; separate 32-check public suite overlaps those 27, runs all 24 native attempts against controlled Qwen and verifies killed-child cleanup ownership |
| Earlier intended import/retrieval source snapshot | **1,700 application checks passed**; strict deep signature verification | Tracked-source closure plus intended changes; unrelated answering edits excluded |
| Public-chat importer | **12 focused tests passed**, no skips | Strict formats, bytes/roles/statuses, provenance, refused replacement and staging SIGKILL |
| Imported-chat runner after fixes | **10 focused tests passed**, no skips | Source-bound scoring, isolation, budgets, restart and excerpt/page regression fixtures |
| Schema-5 `b006b6a` | **1,673 application checks passed** | Foundation before importer/diagnostic additions |
| Background/full-source/process wrapper | **455 checks passed** at schema-5 checkpoint | Maintenance, contention, SIGKILL/reopen/resume and deterministic full-source traversal |
| Schema-5 backup / episodes / local reads | **183 / 225 / 77 checks passed** at recorded checkpoints | Overlapping archive, lifecycle, migration and read recovery checks |
| Independent Qwen rendering oracle | **30 checks passed** | Selected template parity/rejection cases |
| Historical live Qwen smoke | Two public arithmetic turns passed at `b006b6a` | Connectivity, admission, capture/accounting; no long-history quality evidence |
| Frozen retrieval v4 | 224/224 eligible probes covered by lexical helper | Narrow synthetic development corpus, pinned old source, nil semantic index and no answerer |

Latest verification record: `.build/evaluation/source-time-verification-20261006.json`. Verified bundle: `.build/boros-source-time-delivery/Boros.app`. Preceding JSON-object verification: `.build/evaluation/json-object-verification-20261006.json`. Preceding instruction repeat: `.build/evaluation/format-instructions-verification-20261006.json`. Preceding complete-exchange verification: `.build/evaluation/evidence-control-final-verification-20261006.json`. Preceding retrieval verification: `.build/evaluation/query-neighbor-v2-verification-20261006.json`. Preceding selection trace record: `.build/evaluation/selection-trace-verification-20261006.json`. Preceding original-input record: `.build/evaluation/original-input-verification-20261006.json`. Preceding instructions record: `.build/evaluation/saved-instructions-verification-20261006.json`. Preceding policy record: `.build/evaluation/policy-render-wave-verification-20261005.json`. Preceding cleanup record: `.build/evaluation/terminal-cleanup-wave-verification-20261005.json`. Preceding accounting record: `.build/evaluation/episode-accounting-wave-verification-20261005.json`. Preceding cache record: `.build/evaluation/authority-cache-wave-verification-20261005.json`. Preceding binding record: `.build/evaluation/authority-bindings-wave-verification-20261005.json`. Preceding clock record: `.build/evaluation/clock-checkpoint-wave-verification-20261005.json`. Preceding authority record: `.build/evaluation/authority-state-wave-verification-20261005.json`. Preceding framing record: `.build/evaluation/recent-framing-wave-verification-20261005.json`. Previous developer verification: `.build/evaluation/devgpt-wave-verification-20261005.json`. Prior answering record: `.build/evaluation/answer-wave-verification-20261005.json`. Earlier retrieval log: `.build/evaluation/retrieval-fixes-clean-checks-final-20261005.log`. These are ignored local artifacts. Detailed older records are preserved in [the historical schema-5 status](STATUS-SCHEMA5-20261005.md), [IMPLEMENTATION.md](IMPLEMENTATION.md) and component documents.

### Original source-date amendment

The current amendment preserves explicit OpenAI message timestamps independently of ingestion. Schema 10 stores canonical optional calendar metadata; native import v2 verifies original artifact hashes and exact date literals at JSON pointers before publication. Recent and historical selection v3 deliver precision, timezone status and original provenance under counted input/source receipts. Lexical, semantic and following-assistant hits retain dates. Indexed civil-day reads exclude unknown dates and preserve publication order. V1/v2 request bodies and validation projections remain supported.

The offline diagnostic now retains dates through its read-only snapshot, disposable reingestion, restart and v2 ordered-message hash. Its source-recovery protocol supplies no temporal answering score. BEAM anchors, DevGPT share dates and cross-session benchmark adaptation remain unfinished. Original importer artifacts remain separate from application archives.

The optimized `.build/boros-source-time-delivery/Boros.app` passed **3,368 application checks**, with matching frozen 135-file capture `.build/source-time-delivery-source-20261006` and strict deep signature verification. A genuine schema-9 archive produced by the retained previous writer passed **11** verify/restore/roundtrip checks against this app, preserving payload identity, capture times and unknown original dates. Earlier integrated checks exposed a stale backup manifest schema label, a stale version assertion, an invalid FTS trigger fixture and recent/incomplete-message fixture limits after v3 framing. These were corrected without changing runtime caps. The independent delivery audit found an older standalone retrieval compile list missing the new schema dependencies. The corrected harness compiled successfully with 39 matching source hashes. The final delivery app is byte-identical to the preceding verified app and independently passed the complete suite again. Records: `.build/source-time-delivery-checks.jsonl` and `.build/evaluation/source-time-verification-20261006.json`. No real-model calls or temporal accuracy claims were made in this amendment.

### Counted JSON-object answering result

The optional format request is integrated through the original shared answering path. Server-added instruction bytes belong to mandatory input and its full token count; original recent/evidence caps remain. Exact request/source/count evidence, complete capture and original charges survive reopen and archive restore. Capability denial occurs before tokenizer/calibration work and also applies to proof/journal replay. Joint JSON/thinking is refused because the server can change effective thinking using runtime state absent from current metadata; ordinary thinking remains supported with JSON off. The GUI preserves invalid output and reports it after capture.

All **9/9** declared live attempts completed with full original packs delivered and version-3 source/body/count evidence revalidated. Every response passed the strict JSON-object structure: **9/9**, compared with 6/9 in the original and instruction-only controls. Overall and conditional exact task success were **6/9**: single quotes **5/6**, cross-message tasks **1/3**. The h00 historical quote was an answer mismatch with a correct citation; h01 and h02 cross-message answers failed both answer and citation correctness. The h02 historical quote now passed. No output was repaired or rewritten. These changed outcomes on reused questions, one replicate and uncontrolled caches do not establish representative improvement.

Original System, pack annotations, source/oracle pins, questions, strict scoring, ordering and caps match the initial control. Only the separately frozen JSON format setting and version-3 projections changed. The declaration was observed before compilation or input creation: SHA-256 `aa8b3b0e9a22e8b903aeb0748377ccd2b8644e092bb9b8053c861c68befec3e8`. All 90 live runner source hashes match the verified 131-file capture. The matching app passed **3,264 checks** and strict deep signature verification. The independent renderer oracle passed **107** cases and **45** live exact prompt-count comparisons. Counts overlap and direct oracle probes are outside Boros episode accounting.

Report: `.build/evaluation/devgpt-json-object-20261006.json`, **309,521 bytes**, SHA-256 `3d2eee4a32edb5b9850b5a912c9e9ea85a4eba7a35fd8e3b1f7eca421a2153a3`. Verification: `.build/evaluation/json-object-verification-20261006.json`; app: `.build/boros-json-object/Boros.app`. Runtime stores and answer IPC were discarded. Old reports and default instructions remain unchanged; JSON defaults off. Original-time preservation subsequently landed; next is independent natural-question/correction histories, with broader feasibility and release work retained. See [the amendment](EVIDENCE-CONTROL.md#provider-json-object-amendment) and [provider contract](PROVIDER-ADMISSION.md#optional-json-object-output).

### Durable authority-state foundation

N6 now has internal explicit human-operation receipts, task/policy revisions, a separate global control epoch, canonical source spans, conflict resolution, supersession and irreversible terminal expiry. Startup advances the epoch before recovery exposure. Authorized due expiry commits even when the following mutation fails CAS; nonhuman origins cannot change authority or advance the mutation clock. Reopen leaves expired/revoked/superseded exceptions inactive, while an explicitly permanent task preference can remain eligible. No external-action grant exists.

The schema-6 journal validates exact DDL/implicit indexes, canonical state/request/receipt bytes, sequential replay and all materialized rows. Rehashed archive corruption and extra authority tables/triggers/indexes/changed constraints are rejected. A synthetic archive produced by the retained verified schema-5 binary passed the current verifier and restore; exact source bytes and the original archive remained intact. This is newly generated old-writer compatibility evidence, not a retained pre-upgrade production archive.

The final bundle `.build/boros-n6-verified/Boros.app` passed **2,420 application checks**, including **132 authority checks**, strict deep signature verification and the 32-check controlled native public suite (27 overlap the default suite). Seven additional old-writer compatibility checks passed. Focused suites passed 225 episode/process, 184 backup/process, 113 memory/process, 77 local-read, 455 background/full-source/process and 49 evaluation contracts; semantic process recovery passed six checks. Counts overlap. The content-free source-hash record is `.build/evaluation/authority-state-wave-verification-20261005.json`.

The bounded-clock wave passed **2,508 application checks**, including **70 clock contracts** and **18 real SIGKILL process checks**. A separately compiled 16-source harness passed the same 88 clock checks, and the 32-check controlled native public suite passed (27 overlap the default suite); counts overlap. Repeated observations preserve checkpoint identity and anchor; mutation, startup, activation and expiry freeze earlier receipts. Corruption, rejected CAS, rollback, archive/restore and exact human retry contracts passed. The SIGKILL barrier is after both checkpoint SQL writes and before commit; it does not establish crashes between writes or power-loss durability.

A separately compiled writer using the retained `b149877` schema-6 core produced a synthetic version-1 archive with pure-time receipts, task/conversation binding, source-backed policy and the formerly allowed `authority-clock:` human request ID. The current verifier/restore/retry harness passed **22 checks**, preserving source inventory, task/policy/binding records and old receipt bytes. Later startup and new version-2 checkpoints did not change the original human retry receipt. Record: `.build/clock-legacy-writer-contracts.json`, with source and binary hashes. This is newly generated old-writer compatibility evidence, not a retained production archive.

The state kernel remains unexposed. Existing dispatch, pages, visible chunks and derived publication do not yet consult it. Repeated no-effect clock observations now coalesce the final version-2 checkpoint; human, startup, temporal-transition and legacy version-1 receipts remain immutable. Offline/startup and human-operation paths retain complete source-bound replay. Schema 7 funds conservative cold replay on its dormant managed diagnostic; paid warm sessions use the verified current proof and trusted clock writer. Schema-8 accounting replaces ordinary bootstrap scans with indexed projections; schema-9 prepaid cleanup now closes the terminal enumeration gap. Exact journal-cap boundaries and power-loss durability remain unmeasured. Complete rendered input/dependency proof, counted policy integration, source/route grants, serialized delivery/dispatch/publication gates, deletion-aware restore, service interfaces and release remain unfinished. See [authority state](AUTHORITY-STATE.md).

### Dormant schema-7 bindings and funded validation

The internal managed acceptance path commits complete human text, original allowance, task creation/selection and an immutable authority binding atomically. Exact retries retain their original binding and allowance even after startup or an epoch change makes that binding stale. Managed local reads create no chat event or task. Work/invocation bindings retain exact parent/request/body linkage and declared local routes/source dependencies; nonempty artifact lineage is refused. Historical schemas 1–6 migrate original records to explicit `legacyUnbound` classifications without inventing authorization. Archives preserve the complete binding inventory.

The conservative diagnostic funds four phases under the original episode: bounded metadata, journal descriptors, source metadata, then full replay/clock/current eligibility. Its bounded accounting/binding point reads are a bootstrap exception. Charges survive failure; exhaustion prevents unfunded original-source reads. Immediate transactions and external SQLite `data_version` witnesses fence changed sizing, and the receipt hashes the exact validated binding. Its receipt supplies no live boundary permission. Ordinary consumers remain legacy, managed public dispatch is blocked, and human task/policy commands remain unexposed.

The frozen 90-file source/script capture passed **2,674 application checks**, strict deep signature verification and **32 controlled native public checks** (27 overlapping). The focused binding suite passed **157 checks**, including two external replacement/growth schedules and Unicode TEXT-affinity corruption. Episode/process, memory/process, backup/process and evaluation suites passed **225 / 113 / 193 / 49 checks**; counts overlap the application suite where applicable. Nine new backup checks use the complete independently frozen 47-object schema-6 DDL contract. Separately, an actual writer compiled from the retained `0db83bc` schema-6 production sources generated a populated synthetic archive. Its schema-7 verifier/migration/restore harness passed **35 checks**, preserving original sources, snapshots, chunks, authority receipts and conservative accounting; all three episodes, five work records and two invocations remain legacy, with zero invented managed records. This is newly generated old-writer compatibility evidence, not a retained production archive. Record: `.build/schema7-old-writer-harness/verification.json`.

Full replay at each visible chunk would exhaust the current allowance. The internal paid cache/session recipe and audited owner-write invalidation are now verified. Schema-9 cleanup closes the enumeration/funding prerequisite. The bounded renderer prepares a funded mandatory artifact. Counted integration and a proof of the actual complete input/dependency set remain prerequisites for shared live gates. Background work also needs authority bindings and an explicit maintenance scope; exhausted expiry maintenance must deny content until an explicit funded sponsor can commit it. Route declarations do not attest a running processor, and optional renderer digests do not establish semantic sufficiency or complete token enforcement. See [authority bindings](AUTHORITY-BINDINGS.md) and [remaining authority gates](AUTHORITY-GATES.md).

### Paid authority cache/session checks

The internal cache retains one paid current-state proof and immutable anchor, with external SQLite and audited owner-write invalidation. Up to four sessions prepay at most 256 attempts each under the original allowance; denied and throwing attempts consume counters, and retries/restart cannot replenish permission. Canonical evidence is capped at 16 MiB and 4,096 source-proof descriptors. Warm checks use indexed lifecycle and fixed-point clock probes, with no original source payload statement or full replay. Pure-clock proof publication follows successful commit; due maintenance settles after the actual transaction. A policy boundary reached late in acceptance refuses unfunded maintenance and content.

The frozen 94-file capture passed **2,779 application checks**, including **105 cache/session contracts**, strict deep signature verification, **32 controlled native public checks** (27 overlapping) and **225 / 113 / 193 episode, memory and backup process checks** (overlapping). The cache checks cover 256 paid hits, stale writes, external source replacement/growth/edit-revert, clock equivalence, temporal and late-boundary denial, failed maintenance receipts, callback rollback, reentry, Stop/deadline/busy-lock interruption, quotas and restart refusal. These establish bounded warm eligibility checks, not production latency or whole-pipeline cost savings.

**Historical prerequisite after schema 8, now closed by schema 9:** ordinary setup uses validated indexed projections. Terminal cleanup now uses the separately prepaid, bounded contract below. Cold replay still holds the owner mutex. Complete actual input/dependency proof, counted policy integration, background bindings and consumer acceptance/delivery remain unfinished. See [cache/session contract](AUTHORITY-VALIDATION-CACHE.md).

### Saved System instructions

Show settings → System → Save instructions retains exact text for future ordinary requests in every chat/profile in the local store. Old settings keep the historical default; an explicit empty value removes custom instructions while the host's history framing remains. Unrelated preference saves retain the last explicitly saved value. Failed writes and oversized input leave the previous saved preference intact. The save ceilings are 128 KiB UTF-8 text and 1 MiB complete encoded settings, matching the archive file limit. Private staging receives `0600` permissions before atomic replacement.

This closes the editor's restart-persistence gap. Scoped project/task instruction commands remain unfinished. Their next usable milestone must connect saved scoped instructions to ordinary answering, including request preparation, dispatch, visible output and cancellation; another standalone preparation artifact does not establish that integration.

The matching optimized app passed **3,109 checks**, including **100 UI**, **150 context/settings** and **229 backup** checks. The controlled answering runner also passed its real GUI Send/Stop test: startup restored a saved exact instruction value, both durable counted request bodies matched the complete system text, and the endpoint received it on both actual answer requests. This proves transport integration; model obedience and scoped instruction enforcement remain unestablished. The **123-file Sources/scripts/Tests** capture matched the final source. Strict deep signature verification passed. Evidence: `.build/instructions-final-checks.jsonl` and `.build/evaluation/saved-instructions-verification-20261006.json`.

### Recorded inputs for ordinary Send

Selected-Qwen Send now records the exact frozen System instructions and counted request body, plus the complete source union: accepted human text, retained recent messages and every delivered historical range. Existing immutable selection records retain the original identifiers, roles, capture statuses, scope, digests and range evidence. Inspection is prepaid under the original episode allowance. A mismatch stops preparation while retaining its charge.

New invocation admission audits use version 3 and link the completed inspection work and receipt checksum. Capture, reopen and archive verification reconstruct the receipt from original records and count evidence. Historical audit versions remain supported. Schema 9 and existing development limits are unchanged. This receipt describes supported original text inputs in ordinary legacy answering; scoped-policy input closure, current authority after policy changes and shared runtime gates remain unfinished.

The matching optimized app passed **3,122 checks**, including **557 component-preparation** checks. Controlled ordinary GUI Send and Stop both retained completed version-3 input receipts and passed full source-range revalidation in a read-only snapshot. The component fixture independently reconstructed the accepted/recent/historical union, checked exact funding and failure charges, and restored the linked receipt from an archive. The **124-file Sources/scripts/Tests** capture matched the final worktree; strict deep signature verification passed. These are synthetic contract checks. Model answer quality and representative performance remain unestablished by this wave. Evidence: `.build/input-proof-final-checks.jsonl` and `.build/evaluation/original-input-verification-20261006.json`.

### Funded standing-policy preparation

The internal owner path renders every selected policy record without truncation from its paid current-state proof. It preserves exact scope, policy IDs/revisions, UTF-8 values and all selected source spans, including cross-project evidence for a global policy. It rejects conflicts, stale task/authority bindings and mandatory overflow. Lower-only ceilings bound complete system text and selected JSON to 128 KiB each, selected policies to 256 and unique spans to 512. Supplied host instruction hashes record consistency; they do not authenticate a host or grant permission.

A separate original-episode render charge commits before the funded session callback. The recipe uses scalar counts from paid private state and reuses one policy resolution. Eligibility denial and rollback retain charges and consumed attempts; lost cache/session confidence requires fresh paid validation under the same allowance. Warm preparation does not reread original source payload. The artifact still needs complete actual-body/dependency proof, supported token counts, current prepared-work authority for policy-change rebuilding and shared runtime gates.

The frozen **105-file Sources/scripts capture** and **18 test-support files** matched the final worktree. Its optimized bundle passed **3,094 application checks**, including **82 policy-renderer/owner**, **114 cache/session** and **166 binding** checks, plus strict deep signature verification. The focused policy runner passed **105 checks**, including **23 genuine render-funding SIGKILL/two-restart checks**. It verified preservation of accepted evidence, original limits, charged work and conservative unknown outcomes. Native controlled public-source checks passed **32** (27 overlapping); backup/process passed **245**. Counts overlap. Evidence: `.build/authority-policy-process-final-7ao40b9r/verification.json` and the latest verification record above. These checks establish preparation/accounting contracts; complete architecture and release remain unfinished. See [standing-policy rendering](AUTHORITY-POLICY-RENDERING.md).

### Schema-9 bounded prepaid terminal cleanup

The fixed-size terminal fence commits before cleanup. Each new episode freezes a separate cleanup allowance in its original limits: at most 100,000 work slots, lower-only, with two automatic attempt units per slot. Funding commits before each batch and survives rollback or process death. A transaction cleans at most 32 indexed pending rows without loading request snapshots or source payloads. Prepared holds release only after proving no arming; armed/submitted charges and unknown output holds remain conservative. The serial queue releases the owner between batches. Pending receipts expose incomplete cleanup, and exhausted attempts preserve Stop and holds. Mandatory startup recovery records separate administrative units without refunding automatic attempts. All original work and accepted content remain stored.

**75 focused cleanup/process checks passed**, including three actual SIGKILL prefixes, two reopens per prefix, failed-attempt exhaustion, automatic queue progress, late usage, exact retries, rollback, corruption rejection and external confidence loss. The measured 32-row cleanup used **1,070 statements**, **zero full-scan steps** and **zero snapshot statements** with both zero and 4,096 unrelated work records; VM steps were **30,208 and 30,243**. These are controlled measurements, not representative latency, physical-memory or I/O claims. Report: `.build/cleanup-final-contracts.json`.

The backup/process suite passed **245 checks**, including stopped-but-pending snapshots, prior cleanup receipt invariance, failed automatic-attempt debits and exact administrative restore deltas. A producer compiled from retained verified `ea6ae1ea` sources and its actual optimized native bundle created a populated schema-8 archive; **nine compatibility checks passed** against final schema 9. All 62 historical objects reproduce exactly, and schema 9 has 67 objects. Six independent full-schema freeze checks passed. Generated archives and source captures remain ignored local evidence.

At the cleanup checkpoint, the frozen **102-file Sources/scripts capture** and **18 test-support files** matched its final worktree. Its optimized app passed **3,012 application checks**, including **50 cleanup**, **113 accounting**, **114 cache/session** and **166 binding** checks, plus strict deep signature verification. The controlled native public-source suite passed **32 checks**, with 27 overlapping the application suite. Focused process suites passed **141 accounting**, **225 episode** and **113 memory** checks; these also overlap application checks. Full architecture work remains active. Managed live consumers, complete input/dependency proofs, counted policy integration, authority-bound background work, authenticated service, deletion/retention and release gates remain unfinished. See [terminal cleanup](EPISODE-CLEANUP.md), [authority gates](AUTHORITY-GATES.md) and [backup/restore](BACKUP-RESTORE.md).

### Schema-8 indexed episode accounting

Four durable projections replace ordinary work/snapshot/unknown-input aggregates, cross-work receipt enumeration and global adapter-quarantine scans. Exact retries retain original counters and receipts; primary rows and projections commit together. Current-schema startup rejects corruption before recovery, then reconstructs the complete inventory. Same-owner unknown accounting writes, including rolled-back writes, and external commits invalidate private confidence until explicit reopening and full validation. These facts supply no consumer permission. Legacy handoff still lacks a SQLite external-write fence through its actual callback; that remains shared consumer-gate work.

The final optimized bundle passed **2,932 application checks**, including **113 accounting contracts**, **112 cache/session contracts** and **166 binding contracts**. All 98 captured Sources/scripts files match the verified source; 18 test-support files are recorded separately. Strict deep signature verification and **32 controlled native public checks** passed (27 overlap default checks). Record: `.build/evaluation/episode-accounting-wave-verification-20261005.json`. Separately compiled background/process recovery passed **448 checks**, and semantic process recovery passed **six checks**. Counts overlap. Source-corruption access fixtures preserve their intended tests through private source-only hooks or isolated owners; component corruption checks independently validate their target contract as well as the complete schema-8 journal.

The focused accounting suite passed **141 checks**, including real SIGKILL between primary and projection writes, two recovery reopens per schedule, all three receipt ordinals and late adapter violation/final usage. With 4,096 additional valid historical work records, tested lookup VM steps/full-scan steps/profiled statements were unchanged: receipt **278/0/14**, reserve **1,158/0/48**, settlement **997/0/37**, duplicate receipt **209/0/11**. This measures the synthetic schedules; no representative latency or physical I/O claim follows. Report: `.build/episode-accounting-focused-contracts.json`.

The separately frozen schema-7 contract reproduces all 53 SQLite objects. Seven compatibility checks use an actual producer compiled from retained `27cdc4c` sources and the retained native bundle; complete accepted source, original charges, uncertain output hold and immutable old archive bytes survive current migration/restore. Five independent complete-schema checks passed. The backup/process suite passed **217 checks**; episode/process and memory/process passed **225 and 113**. Counts overlap application checks. See [episode accounting](EPISODE-ACCOUNTING.md) and [backup/restore](BACKUP-RESTORE.md).

### Quoted anchors and following-assistant evidence

Ordinary Send now uses `quoted-anchor-round-robin-v1`: complete bounded double/curly/backtick quotations receive priority across the existing eight-term allowance before prose fills any remaining slots. With multiple quotations, terms alternate across anchors. This addresses formatting instructions consuming the query before the source anchor. It retains the existing term/query bounds and operator-as-data behavior. Unquoted late anchors, paraphrases and general question understanding remain unresolved.

`following-assistant-prefix-v2` supplements a selected human source with the immediate next published assistant source in that same conversation, within the search's original frontier. One metadata row is inspected; exclusions apply before payload access. The scalar-safe first 4,096 UTF-8 bytes retain original IDs, digests, offsets, role, total length and capture status. Complete sources remain stored. Rank interleaving stays within 16 final candidates and can displace lower-ranked primary hits; counts/decisions record it. Distinct primary spans survive. A short primary excerpt cannot suppress the complete prefix. A complete existing primary span is promoted beside its human anchor, preserving it within the candidate limit without another payload read. Only an actually retained span covering the prefix suppresses that read. Adjacency is a heuristic, and late publication can make it an inappropriate reply assumption. No full-exchange or answer-sufficiency claim follows. See [the contract](CONTEXT-COMPONENTS.md#bounded-following-assistant-evidence).

The first matching optimized app passed **3,187 checks**, including **74 retrieval-strategy** and **565 component-preparation** checks. Scoped exact-byte selection, two anchored sources, exclusions, UTF-8 prefixes, frontiers, duplicate spans, funded reads, exhaustion, token reductions, source receipts, archive verification and controlled ordinary GUI Send/Stop are covered. The **128-file Sources/scripts/Tests** capture matches the app wave and strict deep signature verification passed. Records: `.build/query-neighbor-final3-checks.jsonl` and `.build/evaluation/query-neighbor-verification-20261006.json`. Two preliminary suite runs retained obsolete single-source/six-excerpt fixture expectations; updated checks assert the exact added source and seven-to-three-to-one reductions under the original caps. Their records remain retained.

The declared `quoted-anchor-following-assistant-v1` Qwen repeat completed **24/24 operationally**, with both arms still **6/12**. All-gold delivery remains **7/9** per arm. Hybrid delivers **10/12 required spans**, versus **9/12** recent-only. Questions, model configuration, source projections and scorer-only oracle pins match the preceding run; all twelve hybrid traces remain. Report: `.build/evaluation/devgpt-query-neighbor-20261006.json`, **1,033,542 bytes**, SHA-256 `cfab16b2628342c98ff2dc21dfd080fdd327c5c7139ccc880ffba580554548cc`. Runtime stores and answer IPC were discarded. No answer-quality improvement is established.

The old human anchor now ranks first in both previously missing probes. Its assistant source is selected, but only range `[0,560)` of a required 1,894-byte line reaches the request. Source-ID-only deduplication suppresses the complete neighbor prefix. All 16 candidates were assembled without evidence byte/row/token/envelope exclusions; the remaining failure is span coverage. The cross-message probe recovers the other complete 1,899-byte required line. Independent reconstruction matches all nine answerable query digests. The v2 correction makes deduplication depend on retained prefix range coverage and promotes a complete existing primary span when available. Its separately declared repeat retains the original source, question, oracle and configuration pins. Independent larger histories, natural questions/corrections, sufficient-evidence provider-fit witnesses and N5/N6 remain unfinished.

The range-aware v2 app passed **3,193 checks**, including **80 retrieval-strategy** and **565 component-preparation** checks. Its 128-file source capture matches the worktree, and strict deep signature verification passed. Records: `.build/query-neighbor-v2-checks.jsonl` and `.build/evaluation/query-neighbor-v2-verification-20261006.json`. The separately declared `quoted-anchor-following-assistant-v2` repeat completed **24/24 operationally**. Hybrid passed **7/12** tasks, recent-only **6/12**. Hybrid delivered **12/12 required spans** and all gold for **9/9 answerable probes**, versus recent-only **9/12 spans** and **7/9 probes**. The recovered historical quote now passes. All five remaining hybrid failures received their required evidence: three cross-message response-format failures (two top-level-shape, one JSON syntax) and two later-source answer mismatches. No evidence reduction occurred for the two corrected h00 probes. Source/configuration/system/projection/oracle pins match v1; all 87 runner implementation hashes match the 128-file capture. Report: `.build/evaluation/devgpt-query-neighbor-v2-20261006.json`, **1,035,025 bytes**, SHA-256 `72a3753b19b0542b5f635284faabd705bac91c1e9bc1cd4c9120538ea8bca9d9`. Runtime stores and answer IPC were discarded. This is a reused development result with one replicate and uncontrolled caches; representative quality and sufficient-evidence provider feasibility remain unestablished.

### Complete-exchange answering control

The separate `sufficient-exchange-pack-v1` control freezes nine complete original human/assistant packs, unchanged questions and scorer-only oracles before provider work. The pre-execution declaration was observed before driver compilation or input creation. Its SHA-256 is `99ae1124ae3bc7b5da6625bf86abd07503b65673395993c7dcd617f684d3779c`. Version-2 native pins isolate these packs from version-1 paired retrieval inputs. The shared recent-only coordinator retains the original configuration, limits, 2,048-token output reserve and durable lifecycle. See [the control contract](EVIDENCE-CONTROL.md).

The matching optimized app passed **3,214 checks**, including **23 answering** and **19 evidence-control** checks. Its **131-file Sources/scripts/Tests** capture matches the final source and strict deep signature verification passed. Controlled checks cover complete and reduced packs, Stop, altered source/body/count provenance and missing invocation. A preliminary successful suite left its last synthetic fixture at CLI exit; deferring the next fixture until callback release corrected cleanup. The final suite asserts cleanup and left zero fixture directories. Records: `.build/evidence-control-final-checks.jsonl` and `.build/evaluation/evidence-control-final-verification-20261006.json`; the preliminary record remains retained.

The live Qwen control completed **9/9 operationally**. All nine entire packs reached the counted request, and their actual version-3 source/body/count proofs passed revalidation. All nine were conditionally eligible; both overall verified-control and conditional task success were **5/9**. Single quotes passed **5/6**; cross-message tasks passed **0/3**. All three cross-message failures have `response_top_level`, meaning the parsed JSON root was not an object; its exact type was not retained. The h02 historical quote failed exact-answer scoring. No evidence reduction or conditional exclusion explains these four failures. Source, original projection/oracle, configuration and system pins match the preceding diagnostic; all **90** runner implementation hashes match the final capture.

Report: `.build/evaluation/devgpt-evidence-control-20261006.json`, **307,748 bytes**, SHA-256 `7d9352a85048b9a5e2e7fef0ce2efa5904660c409127ab4519daebc70295676c`. Declaration and pack annotations match the pre-execution freeze. Runtime stores and answer IPC were discarded. Witness validation and scoring are post-terminal diagnostic work outside runtime episode charges. This one-replicate reused development control establishes measured delivery of these curated packs; independent quality, broader over-cap feasibility, latency and total economics remain unestablished.

### Format instruction repeat and provider capability

The separately declared `json-output-instructions-v1` repeat changes only the System instruction. All nine questions, complete packs, projection/oracle pins, scoring and resource limits remain frozen. The matching app passed **3,219 checks**, including 23 answering and 24 evidence-control checks, with matching 131-file capture and strict deep signature verification. Native version-2 inputs accept only the exact original or amended configuration; conditional scoring checks the actual native configuration digest.

All **9/9** live attempts completed, fully delivered their packs and passed source/body/count proof validation. Task success remained **5/9**, including **5/6** single quotes and **0/3** cross-message tasks. Two cross-message responses failed the JSON-object requirement and one failed JSON syntax; the h02 historical quote remained incorrect. No instruction benefit is established. App defaults and saved instructions remain unchanged. The pre-execution declaration SHA-256 is `15f092be1f3d55fc3da6f402fcc29cec3622ae05b27715e0630bc980ea330913`; all pack annotations and 90 implementation hashes match. Report: `.build/evaluation/devgpt-format-instructions-20261006.json`, **307,987 bytes**, SHA-256 `4e91abb620a10e83b3c4db7fb18f7bfcdbcd5e2fb813013e5f73abb0abe7fdbd`. Verification: `.build/evaluation/format-instructions-verification-20261006.json`. Runtime stores and answer IPC were discarded.

The running server advertises JSON-schema support. Direct synthetic nonstreaming probes accepted JSON-object and schema requests and produced matching constrained shapes. Identical messages reported 23 prompt tokens ordinarily, 60 in JSON-object mode and 84 in schema mode; the active template remains byte-identical to the existing pin. The [pinned server implementation](https://github.com/ddalcu/mlx-serve/blob/02bee553f48cd3bc7d82aba0f8073820bd924738/src/server.zig#L8684) adds a format instruction after dropping empty messages and before template trimming. Boros must mirror and count that transformation before shared-path enablement. Initial fixed JSON-object support can keep arbitrary schema serialization separate; server grammar failure can fall back to prompt-only behavior, so output validity remains measured. These probes run outside Boros episode accounting and do not establish production support. Record: `.build/evaluation/provider-response-format-probe-20261006.json`. See [the contract and capability boundary](EVIDENCE-CONTROL.md#provider-response-format-capability-probe).

### Historical source-selection trace

The shared selected-Qwen preparation path now records query digests and selected token positions, at most 16 returned candidate IDs/ranges, and fixed assembly inclusion/exclusion reasons. Token and envelope reductions retain that trace; final delivered ranges and existing reduction counters show the later result. Query terms, source excerpts and answer text are excluded. Auxiliary trace overflow is omitted under the existing 32 KiB audit ceiling. This is diagnostic metadata for returned results, with explicit truncation; it does not enumerate every pre-ranking candidate or establish answer sufficiency. Query formulation and selection behavior are unchanged in this wave.

The matching optimized app passed **3,143 checks**, including **31 retrieval-strategy** and **564 component-preparation** checks. The **124-file Sources/scripts/Tests** capture matches the verified build, and strict deep signature verification passed. Evidence: `.build/selection-trace-final-checks.jsonl` and `.build/evaluation/selection-trace-verification-20261006.json`.

Read-only reconstruction of the retained N4 report matches all **nine answerable lexical query digests** and its original `ChatContextPreparation.swift` source hash. The selected eight tokens belong to the question's formatting instructions before its source anchor. Both h00 missing-evidence probes inspected **zero lexical candidates and zero vector candidates**, with semantic disposition `codeLike`. Their failure precedes assembly and evidence-token reduction. Record: `.build/evaluation/devgpt-retained-query-attribution-20261006.json`; the original report and source/oracle pins remain unchanged. The next retrieval fix must target meaningful question content and exchange relationships, then measure delivered evidence and answers on a separately declared repeat. The sufficient-evidence witness, independent histories, representative scaling and full N6 remain unfinished.

The fresh copied-source Qwen run completed **23/24 attempts**: recent-only **11/12**, hybrid **12/12**. Both arms scored **6/12**, with complete gold delivery in **7/9** answerable probes per arm. All twelve hybrid traces were retained. The two h00 target probes returned zero candidates, zero assembly decisions and the same first-eight token ordinals; semantic disposition remained `codeLike`. Hybrid again delivered 16 historical excerpts only for h00 absence. This confirms the selection defect through the instrumented ordinary path and establishes no answer-quality improvement.

The first recent-only historical attempt ended with `provider_admission_unavailable` after 15.2 seconds, before recent/historical source work. Its calibration charge remains, with **one output token held** as unknown usage. The underlying provider/transport cause is unestablished. No retry replaces the failed declared attempt. The source/configuration/projection/oracle hashes match their frozen inputs; all old reports are preserved. Report: `.build/evaluation/devgpt-selection-trace-20261006.json`, **943,536 bytes**, SHA-256 `4ba2c0de689bf584c8a0b041466fdf891cde5ac75f502b831b79812e46efbb00`. Runtime stores and answer IPC were discarded after scoring. These remain reused development probes, one replicate, fixed order and uncontrolled caches.

### Recent-source framing development repeat

Commit `d9c3e20` exposes host source IDs in new recent context and preserves v1 journal/archive validation. The frozen response diagnostic adds structural codes without changing the original scoring decisions. All 2,287 application checks and five additional native checks passed before this repeat. The original source projections, questions, oracles, output reserve and strategy order are unchanged. These are reused development probes, with one replicate and uncontrolled caches.

All 24 attempts completed. The same three single quotes that previously reproduced the correct text now also carry correct citations. Each arm passes 6/12 overall: three single quotes and three absence cases. Five of six single quotes have correct citations; two of those still quote the wrong text. Cross-message responses fail with two JSON-syntax errors and one invalid top-level shape per arm. The discarded answers support these fixed codes, but no more detailed classification.

| Repeat result | Recent-only | Hybrid |
|---|---:|---:|
| Operational completions | 12/12 | 12/12 |
| Full task successes | 6/12 | 6/12 |
| Exact single-quote text correct | 3/6 | 3/6 |
| Single-quote citations correct | 5/6 | 5/6 |
| Corpus-verified absence successes | 3/3 | 3/3 |
| Answerable probes with every gold span delivered | 7/9 | 7/9 |
| Cross-message schema failures | 3/3 | 3/3 |
| Known charged input tokens, including calibration | 70,894 | 75,878 |
| Charged output tokens, including calibration | 2,112 | 2,112 |
| Foreground model calls | 24 | 36 |
| Historical excerpts delivered across all attempts | 0 | 16 |

Framing consumes the existing recent cap. History h00 now retains events 34–67, a 34-event suffix, after geometric token reduction from 68 events. Its historical quote needs event 1, and its cross-message quote needs events 1 and 33; neither probe receives historical excerpts in hybrid. History h01 retains 42 events and h02 retains 28. The sole historical-evidence delivery is 16 excerpts in h00's hybrid absence attempt. Eleven paired request digests match; all twelve paired answer digests match. This establishes no historical-retrieval advantage and exposes a source-selection boundary requiring a controlled trace; it does not identify the query/ranking/assembly cause.

All input/output holds are zero. Hybrid's twelve extra foreground calls remain opaque query encodings, with twelve background constructions reported separately. Exact implementation hashes match the worktree at recording. Report: `.build/evaluation/devgpt-recent-framing-20261005.json`, 1,121,512 bytes, SHA-256 `285e435a21bcb484c0dfdb0df3173b6a19b2599a074bd6d0d50c07dfb5c7bf49`. Transient stores and answers were discarded. The original report below remains unchanged.

The next provider witness must freeze enough question context to identify the requested exchange, including its human anchor, alongside answer spans and visible IDs. Counting isolated answer lines would establish a pack's token fit without establishing semantic sufficiency. A separate measurement API is needed to retain whole-render counts for over-cap packs; ordinary admission must keep its existing rejection rules. Standalone witness evidence also needs explicit source/body/count journal validation before claiming durable attestation.

### Public developer-history amendment

Three source-pinned DevGPT PR-linked histories contain 138 serialized events and 75,221 text bytes. The native allowlist accepts their exact oracle-free projections; scorer oracles have separate frozen hashes. Duplicate messages and sharing identities are rejected. Original generation completion, code-block reconstruction and original timestamp indexing remain unknown/unsupported. Distinct sharing identities do not establish independent authors or representative histories.

Each history declares historical, ordered cross-message and later-line reproduction plus a corpus-verified absent identifier, paired across both strategies: 24 attempts. The frozen exact JSON rubric separates answer, citation and abstention correctness, and requires validated delivered gold ranges for citation support. Correction scoring passes synthetic contracts; no public correction cases are frozen. Source-derived anchors and constrained reproduction questions do not establish natural developer reasoning.

All 24 native attempts completed against controlled Qwen transport with intentionally incorrect output and zero task credit. Overlays remained isolated, actual projection digests matched, per-hybrid background construction and foreground accounting were retained, and reports contained no chat text. The amendment reserves 2,048 output tokens before model results; its spend/latency must not be pooled with the 128-token pilot. See [the source amendment](DEVELOPER-ANSWER-EVALUATION.md) and [rubric contract](ANSWER-RUBRICS.md).

The live run at `987441e` completed all 24 attempts. Every original event fit the 8,000-token recent component: 68, 42 and 28 recent sources by history, with zero historical evidence excerpts. All 12 paired request digests and answer digests were identical. This is a source-reproduction/citation diagnostic; it establishes no hybrid retrieval benefit.

| Live result | Recent-only | Hybrid |
|---|---:|---:|
| Operational completions | 12/12 | 12/12 |
| Full task successes, including citations | 3/12 | 3/12 |
| Corpus-verified absence successes | 3/3 | 3/3 |
| Exact single-quote text correct | 3/6 | 3/6 |
| Answerable probes with every gold span delivered | 9/9 | 9/9 |
| Cross-message responses rejected by strict schema | 3/3 | 3/3 |
| Known charged input tokens, including calibration | 68,434 | 68,434 |
| Charged output tokens, including calibration | 2,267 | 2,267 |
| Foreground model calls | 24 | 36 |

All nine source-answer tasks per arm failed overall. Three exact single-quote answers lacked required citation support, three single quotes differed from the frozen text, and three cross-message responses failed strict response validation. The discarded answers cannot support a more specific JSON-failure explanation. At this checkpoint, recent messages exposed no stable event IDs to the model; the snapshot/journal retained their IDs privately. The subsequent N4 amendment uses explicit v1/v2 dispatch to retain old unlabelled body/archive validation.

Both arms retained zero input/output holds. Hybrid's twelve additional foreground calls are opaque query encodings; twelve real per-attempt background builds are reported separately. The complete admitted prompts contained every required answer-text span. A separate sufficient-evidence witness including model-visible citation identity remains pending. No representative quality, tree, latency or economics claim follows.

Report: `.build/evaluation/devgpt-answer-pilot-20261005.json`, 1,207,595 bytes, SHA-256 `c1ff20c833bb9af27174a68aadba94e838895031523d122d17eaac0d28528d72`. Captured implementation hashes matched the worktree at recording; transient stores/answers were removed after scoring. Source payload remains a private ignored local file.

### First paired production answering diagnostic

The pinned public development corpus contains one history, 31 events, 123,572 source bytes and nine probes. Both strategies ran every probe through the shared coordinator in separate restored overlays. Hybrid rebuilt the real Apple index nine times before answering. Fixed order, one replicate and uncontrolled caches limit interpretation.

| Observed result | Recent-only | Hybrid |
|---|---|---|
| Declared attempts | 9 | 9 |
| Operational completions | 7 | 8 |
| Literal factual-marker successes | 1/6 | 6/6 |
| All required spans delivered for scored probes | 1/6 | 6/6 |
| Unscored probes | 3 | 3 |
| Charged known input tokens, including calibration | 2,090 | 18,959 |
| Charged output tokens, including calibration | 412 | 573 |
| Foreground model calls, including opaque query encoding | 17 | 27 |

The first recent-only rare-fact attempt failed during admission with `provider_admission_unavailable`, after five HTTP attempts and one charged calibration call. Its one-token output hold remains unknown. No historical source work occurred. This report establishes the host failure code; it does not determine whether startup, load or transport caused the admission failure. The hybrid whole-record probe and recent-only absence probe ended with `incomplete_result` and durable partial output; each reached the 128-token generation cap. These unscored dimensions remain in the nine-attempt operational denominators.

Literal scoring requires exact expected markers with identifier boundaries. It does not judge prose negation, complete-record reproduction, citation correctness, quoted-policy attribution or abstention. Delivered coverage does not prove that sufficient evidence fits the provider budget. The five-category quality gate remains **inconclusive**; no tree-benefit, representative accuracy, latency or economics claim follows.

Report: `.build/evaluation/public-answer-pilot-20261005.json`, SHA-256 `84302b2bd8e1b44050d072c1d9aac743206a39db1b23921c3e58253315039b1a`. It retains all 18 attempts and exact copied source/compiler/binary, generator, corpus and configuration hashes. Its captured implementation hashes matched the worktree when recorded. Runtime answers/stores were discarded after scoring; the report is content-free.

Next work follows the identified limits: N3 independent developer histories and explicit rubrics, N4 admission failure attribution and baseline fixes from independent cases, and N5 scaling/cap evidence. Increasing an output cap to obtain a better score is not a feasibility test. Keep the pinned pilot and old registered protocols unchanged; declare amendments before future comparisons.

### Imported long-chat diagnostic

The BEAM sample has 796 messages, evenly split between user and assistant, and 1,861,956 exact message-text bytes. Its dataset label is nominally 500K tokens; no provider token count was measured. It is generated and mixed-domain, not a verified human coding-only history.

The controlled repeat retained the same 12 source-derived answerable probes and one absence probe used to trace failures. Lexical code changed; the page diagnostic also changed candidate-window scheduling. These are reused development probes, not an independent confirmation set.

The offline report captures exact copied working-tree dependency hashes, including strategy-aware preparation dependencies present at the time. That source capture differs from the separate clean application-verification snapshot; its default context behavior was the path evaluated.

| Protocol | Original warm/restart coverage | Corrected warm/restart coverage | Corrected full-read-episode p95, warm / restart |
|---|---|---|---|
| Recent-only | 1/12 | 1/12 | 0.159 / 0.307 seconds |
| Lexical context | 8/12 | 12/12 | 0.949 / 1.740 seconds |
| Hybrid context | 8/12 | 12/12 | 6.915 / 11.111 seconds |
| Exact pages | 10/12 | 12/12 | 13.270 / 21.845 seconds |

All 104 read attempts completed within frozen allowances in the controlled repeat. Original sources verified before/after both profiles. HTTP attempts were zero. The raw absence probe returned no hits. Pages stayed within 12,000 returned bytes and 19 calls. Coverage limits still existed on some attempts; success does not establish exhaustive scanning.

Timers include diagnostic work, use fixed protocol order and do not control OS cache/system load. They do not measure endpoint latency, generation, first useful answer or product p95. The run used process-scoped `caffeinate -i`. A separate sleep-interrupted report retains one warm hybrid deadline failure and a warm hybrid score of 11/12.

Semantic processing recorded 51 complete and 745 unsupported sources, with 118 supported and 2,117 unsupported chunks. Code-like/ambiguous/non-English guards limit the adapter. Hybrid improvement follows lexical excerpt fixes; it does not demonstrate semantic recall improvement.

Controlled report: `.build/evaluation/beam-retrieval-fixes-awake-20261005.json`. Interrupted report: `.build/evaluation/beam-retrieval-fixes-20261005.json`. See [failure traces and boundaries](IMPORTED-CHAT-EVALUATION.md).

### Claims still unsupported

- Reliable natural-question recall, multi-source reasoning, corrections, citations and appropriate abstention.
- Provider-budget feasibility or answer quality on the imported conversation.
- Representative Apple encoder quality, code/multilingual support or semantic benefit over lexical retrieval.
- Subsecond warm endpoint retrieval at 100,000 events, production latency or cap suitability.
- Lower total cost, credible retained-history reuse economics or whole-pipeline cache savings.
- Tree benefit, complete policy/task authority, deletion/action safety or production readiness.

## 5. How Boros addresses the inspiration's gaps

The [design mapping](../tracechat-plan.md#2-how-the-original-plan-and-review-inform-this-design) is the intended contract, not a claim that every remedy has shipped.

| Gap | Boros remedy | Disposition |
|---|---|---|
| Summaries erase retrieval clues | Independent raw retrieval | Available; general recall unmeasured |
| Truncated results lose middle content | Complete accepted bytes and paging | Available for text; tool/attachment capture planned |
| Summary-only recent context loses exact follow-ups | Separate recent verbatim allocation | Available; representative answer accuracy unmeasured |
| Failed summarization blocks turns | Compaction outside turn dependency path | Baseline has no summary dependency; tree guarantees gated |
| “Latest wins”/quoted reports create false authority | Authorship plus scoped policy/task lifecycle | Internal state verified; runtime enforcement pending |
| Bytes fail context admission | Selected-provider token counts | Available for verified Qwen; opaque adapters limited |
| Fresh requests/cache reuse are treated as quality/cost proof | Matched answering/resource/economic evaluation | Tooling/contracts partial; product claims unmeasured |
| Summary errors/frontiers/deletion persist unnoticed | Versioned lineage/frontiers, invalidation and restore-safe deletion | Tree/control/deletion contracts planned |

## 6. Dependency-ordered next work

The user authorized completion of the full planned architecture on October 5, 2026, keeping optional features gated by evidence. Work follows this dependency order. N1–N2 reached their first diagnostic acceptance milestone; current implementation prioritizes N3–N5 recall quality, chronology and workload evidence before further N6 enforcement. Subsequent architecture and release packages remain unfinished. Dates depend on verified dependencies and acceptance criteria.

| Order | Work package | Dependencies and purpose | Completion evidence |
|---|---|---|---|
| N1 | Shared Qwen coordinator and retrieval strategies integrated | Prerequisite for production-path comparison implemented | 2,162 passing checks and rebuilt matching-source app; original lease, controlled GUI/runner parity, durable delivery, Stop/late callbacks and ownership verified |
| N2 | First paired answering driver/scorer implemented and executed | N1 verified; all 18 attempts from the pinned public development history | 15/18 operational completions; hybrid 6/6 and recent-only 1/6 literal factual successes; every failure retained; complete quality gate inconclusive |
| N3 | Add independent developer-history/imported-chat answering cases — partial | Three pinned DevGPT histories executed; strict reproduction/citation/absence rubrics; separate complete-exchange control delivered and validated 9/9 packs, passed 5/9 tasks | Larger/cross-session histories, independent authors, natural questions, corrections, immediate follow-ups, chronology and broader sufficient-evidence feasibility remain |
| N4 | Improve baseline where N2/N3 expose failures — partial | V2 framing/legacy compatibility and source traces verified; quoted-anchor selection, bounded range-aware following-assistant prefixes, optional counted JSON-object output and original-date delivery verified through 3,368 checks | First declared repeat completed 24/24, both 6/12; v2 range correction verified; 24/24 complete, hybrid 7/12 with all gold delivered; separate control and instruction-only repeat each passed 5/9 with all packs delivered; JSON-object amendment now 9/9 valid objects and 6/9 tasks with all packs delivered; independently frozen confirmation/larger histories and broader feasibility remain; preserve metering and old pins |
| N5 | Measure scaling and practical caps | Parallel once workload defined; diagnostic timing does not establish endpoint target | Declared 1k/10k/100k corpora, bytes/chunks/concurrency, warm/restart/paused schedules; endpoint/full-path latency, backlog and work |
| N6 | Complete scoped saved instructions and task lifecycle | Queued after the next independent recall-quality work; required for scoped-instruction category | Durable state, bounded clock checkpoints, dormant managed bindings and paid warm cache/session checks verified; indexed setup and bounded prepaid cleanup now implemented; funded bounded policy preparation and ordinary original-text input receipts now implemented; managed standing-policy input closure, counted integration and shared dispatch/output/page/publication gates; retain charged/unknown work and legacy evidence |
| N7 | Freeze/execute representative baseline evaluation | Pilot workload/variance from N2–N5; full five-category claim also needs N6 | New source/config amendment, independent splits, feasibility, failure scoring, power, usage and trajectory accounting; preserve old pins |
| N8 | Decide whether to build optional tree | Accepted baseline/workload first | Explicit decision; then source/child/context lineage, ready queues, frontiers, nonblocking failures, correction/rebuild and pagination |
| N9 | Compare tree-enabled and baseline paths | Tree and all comparison prerequisites | Frozen B/D pair, one primary mode; independent held-out quality/category/cost/latency gates |
| Before external clients | Service/MCP/authenticated intake | Ownership, continuation and disclosure contracts | Scope-bound grants, ranking/pagination compatibility, concurrent ownership and no unauthorized disclosure |
| Before deletion or local release | Suppression/purge/deletion-aware restore | Cover duplicated request/chunk evidence and all managed copies | Control-gate races, resumable inventory/cleanup and external deletion ledger applied before old restore serving |
| Before actions/remote processing | Implement each host contract | Capabilities expand current boundary | Action reconciliation/idempotency, or transitive destination intersection and disclosure/routing fences, with adversarial checks |
| Before local release | Visual/operational release checks | Apply to chosen shipping capabilities | Fresh intended bundle, synthetic GUI walkthrough, packaging/guide/diagnostics, restore and applicable invariants |

The first diagnostic contract is [ANSWER-EVALUATION.md](ANSWER-EVALUATION.md). Its initial runner refuses arbitrary user-store paths and validation/held-out execution. Imported-history answering is separate work; the offline imported-chat runner is not an answering driver.

N7 also includes the supplemental LongMemEval and LongMemEval-V2 adapters named in [plan section 13](../tracechat-plan.md#13-evaluation-that-decides-the-design). These adapters remain unimplemented. Pin dataset revisions and follow published protocols; keep official benchmark scores separate from Boros's product decision score.

### First milestone acceptance checklist

- [x] Finish coordinator/strategy review and integrate the same Qwen lifecycle into GUI and diagnostic.
- [x] Establish actual absence of historical reads/encoding in recent-only; empty evidence is insufficient.
- [x] Implement isolated attempts, runner/oracle separation and content-free reporting.
- [x] Complete controlled-transport contract checks before real-model calls.
- [x] Run/retain the paired public development diagnostic when Qwen is available.
- [x] Attribute failures and choose subsequent fixes from the report. A one-history pilot cannot pass the product-quality gate.

## 7. Remaining plan and evaluation gates

### Delivery phases

| Phase | Status | Outstanding exit conditions |
|---|---|---|
| 0 — Contracts/evaluation | Partial | Templates/statistics helpers exist; policy/task/gate execution, workload splits, feasibility and power incomplete |
| 1 — Evidence foundation | Partial | Text durability/backup exist; external payload recovery, aggregate quotas, suppression/purge and deletion-aware restore remain |
| 2 — Read-only baseline | Partial | Native retrieval/context/accounting and offline tooling exist; full interfaces and representative answering/recall/latency/cost remain |
| 3 — Policy/task/optional actions | Partial | Internal durable state verified; human interfaces, shared gates and scoped policy enforcement; action recovery only if enabled |
| 4 — Optional tree | Gated | Accepted baseline first; lineage/versioning/jobs/frontiers/browsing/invalidation |
| 5 — Compare/confirm | Planned | Full comparison, validation ablations, frozen B/D pair, workload/cache profiles and independent held-out result |
| 6 — Local release | Partial/not ready | Development build exists; product invariants, guide/packaging, visual check and required lifecycle/deletion contracts remain |

The first useful read-only prototype ends at phase 2. Its service/API and measurement requirements are broader than the working native app. See [delivery plan](../tracechat-plan.md#14-delivery-plan).

### Comparison contract

| Arm | Planned purpose | Execution status |
|---|---|---|
| A | Recent exact context only | First public paired production diagnostic executed; representative evaluation pending |
| B | Recent plus raw hybrid retrieval | First public paired production diagnostic executed; full permitted operations and representative evaluation incomplete |
| C | Tree/zoom, raw search disabled | Tree/answering arm unimplemented |
| D | B plus tree/zoom | Tree/answering arm unimplemented |
| E | Sufficient gold evidence supplied directly | Separate curated complete-exchange control: 9/9 fully delivered and validated, 5/9 task success; broader feasibility arm remains pending |

Tree comparisons retain separate C-local/C-full summarizer-context variants and an approximately 64k-token original orientation sensitivity when the selected model admits it. These are labeled development comparisons, not extra held-out winner-selection opportunities.

Five equally weighted categories: exact facts, cross-session/temporal updates, immediate exact follow-ups, scoped instruction/lifecycle and appropriate abstention. Missing categories leave the result inconclusive. Budget-infeasible cases remain in overall task-success denominators and are reported separately from feasible source-recall diagnostics.

| Proposed gate | Evidence required |
|---|---|
| Invariants | All applicable durability, scope/disclosure, lifecycle, fences, restart, deletion-serving and admission checks pass |
| Feasible source recall | At least 95% recovering every required span in each frozen replicate/build combination; clustered uncertainty reported |
| Endpoint scaling | Warm retrieval p95 below one second at declared 100k text events |
| Tree quality-first | D−B estimate at least +5 percentage points and positive lower 95% confidence bound |
| Optional cost-first | Chosen before held-out: task lower bound above −2 points and cost-per-success upper ratio at most 0.80 |
| Regression/cost envelope | Critical category lower bounds above −2 points; cost upper ratio at most 1.25; authority invariants remain blockers |
| Full interaction envelope | Warm/cold-restart/paused: at most 500 ms added p95 memory delay and 10% added p95 episode delay |
| Independence/power | At least three answering replicates, three tree builds, 200 independent histories overall and 50 per critical category; larger counts where pilot power requires |
| Economics | Pilot retained-history/reuse trajectory; construction, retries, rebuilds, queries/storage/unknown usage counted; research replication separate |

These are proposed targets and executable helper contracts, not achieved product results. Default is one preregistered quality-first decision; inconclusive results keep the tree experimental. See [EVALUATION.md](EVALUATION.md).

All confidence bounds above are the specified 95% bounds. Replicates and tree builds do not increase the independent-history count. A pilot-based power design and simulation of the complete conjunctive decision remain required.

## 8. Decisions before selecting work

| Decision | Current position | Needed choice/evidence |
|---|---|---|
| Immediate milestone | N1–N2 first diagnostic complete; N3 public pilot executed; N4 framing/query/range corrections and optional JSON output verified; latest control 9/9 valid objects, 6/9 tasks with full validated delivery | Freeze independent larger histories, natural questions, corrections and temporal answering; retain broader feasibility, N6, service, data-lifecycle and release work |
| Answering runtime | Configured Qwen executed paired diagnostics; latest range-aware run completed 24/24, hybrid 7/12 and recent-only 6/12; earlier admission failure retained | Retain every admission failure and unknown output hold; establish startup/warm reliability before representative measurements |
| Representative histories | Generated mixed-domain import, synthetic fixtures and three source-pinned DevGPT sharing histories; N4 labels trimmed h00; range-aware hybrid now recovers all required spans on the reused development probes | Independent authors, natural questions, original times in representative histories, larger/cross-session histories and representative workload unestablished |
| LongMemEval adaptation | Official cleaned conversational protocol reviewed as a supplemental candidate; complete dataset bytes and file hashes have not been fetched or verified | Preserve source session/question dates separately from ingestion clocks, complete original sessions and scorer-only annotations; freeze subset IDs before results; a subset cannot establish the official full score or independent human histories |
| Rubrics | Literal factual pilot and frozen strict exact-answer/cross-message/citation/abstention contracts; synthetic correction checks | Actual public correction cases, semantic reasoning and scoped lifecycle remain unmeasured/unimplemented |
| Semantic direction | Narrow Apple support on import | Measure code/paraphrase needs before choosing new encoder, lexical chunks or reranker |
| Caps/machine envelope | Development defaults exist | Archive/capture/query frequency, backlog, contention and hardware measurements |
| Client/authority scope | One native owner; dormant authority bindings, paid warm session checks, indexed accounting and schema-9 prepaid cleanup | Shared gates required before mutation exposure; authenticated service ownership remains planned |
| Tree go/no-go | Optional/gated | Accept measured baseline before tree implementation |
| Completion scope | Full planned architecture authorized; current bundle remains development-only | Complete required phases and release gates; optional tree/actions remain evidence-gated |

Hidden reasoning capture, unrestricted orchestration, universal exactly-once actions, automatic policy activation from prose and guaranteed secure SSD erasure are outside the current promise. Richer hosting, all-history export, natural-language policy suggestions, semantic secret discovery, advanced vector selection and alternate tree shapes are later options with their own evidence/contracts.

The [official LongMemEval protocol](https://github.com/xiaowu0162/LongMemEval/tree/9e0b455f4ef0e2ab8f2e582289761153549043fc) and [cleaned dataset release](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/tree/98d7416c24c778c2fee6e6f3006e7a073259d48f) supply natural-language extraction, preference, multi-session, update and temporal questions. Their curated histories do not establish independent real users. The official QA judge and retrieval denominators differ from the current exact JSON/citation diagnostic. An adapter must preserve those grading semantics, contain source-bearing grader IPC privately and account for judge work separately. Original-time provenance is a prerequisite for temporal claims; current capture timestamps cannot substitute. No dataset download or judge call was made in this protocol review.

## 9. Document map

| Document | Role |
|---|---|
| [README](../README.md) | Build/usage/tool entry points |
| [Implementation](IMPLEMENTATION.md) | Detailed available boundaries and older verification |
| [Plan](../tracechat-plan.md) | Full architecture, dependencies and gates |
| [Design review](../tracechat-adversarial-review.md) | Immutable revision-1 review; revision-2 disposition in plan section 16 |
| [Historical schema-5 status](STATUS-SCHEMA5-20261005.md) | Previous checkpoint totals and working snapshot |
| [Original source time](SOURCE-TIME.md) | Calendar provenance, precision, timezone status, v3 delivery and archive limits |
| [Chat import](CHAT-IMPORT.md) | Formats, publication/provenance and limits |
| [Imported-chat evaluation](IMPORTED-CHAT-EVALUATION.md) | Offline protocol, traces and results |
| [Answering diagnostic](ANSWER-EVALUATION.md) | Shared path, isolated pilot and runner/scorer contract |
| [Developer answering amendment](DEVELOPER-ANSWER-EVALUATION.md) | Pinned public histories, exact quotes/citations/absence and remaining N3 limits |
| [Sufficient-evidence control](EVIDENCE-CONTROL.md) | Separate complete-exchange packs, whole-pack/source/body/count validation and conditional scoring |
| [Exact-answer rubrics](ANSWER-RUBRICS.md) | Strict response, source/citation support and correction/abstention scoring contracts |
| [Evaluation](EVALUATION.md) | Pins/statistics and remaining quality/economics |
| [Context components](CONTEXT-COMPONENTS.md) | Qwen caps/reductions/proofs |
| [Provider admission](PROVIDER-ADMISSION.md) | Compatibility/rendering/counts |
| [Episode budgets](EPISODE-BUDGET.md) | Foreground resources/deadlines/unknowns |
| [Episode accounting](EPISODE-ACCOUNTING.md) | Schema-8 indexed projections, atomic writes, complete reconstruction and confidence fencing |
| [Read episodes](READ-EPISODES.md) | Browser/evaluation origins and lifecycle |
| [Background budgets](BACKGROUND-INDEX-BUDGET.md) | Maintenance/publication/recovery/integrity |
| [Semantic retrieval](SEMANTIC-RETRIEVAL.md) | Encoder/coverage/manifests/jobs/fallback |
| [Authority state](AUTHORITY-STATE.md) | Internal task/policy journal, bounded clock checkpoints and unexposed enforcement boundary |
| [Authority bindings](AUTHORITY-BINDINGS.md) | Internal acceptance/provenance and funded validation; no boundary permission |
| [Authority cache](AUTHORITY-VALIDATION-CACHE.md) | Paid bounded sessions, original lease/allowance and time/write fences |
| [Authority gates](AUTHORITY-GATES.md) | Funded preparation versus remaining counted policy/input proof and shared dispatch/delivery/publication contract |
| [Standing-policy rendering](AUTHORITY-POLICY-RENDERING.md) | Complete selected policy bytes, source references, encoded bounds and separately committed render funding |
| [Backup/restore](BACKUP-RESTORE.md) | Contents/compatibility/verification/exclusions |
| [GUI provenance](GUI-ORIGIN.md) | Interface origin/development boundary |

Update this page when a capability lands, verification is recorded or a measured decision changes. Keep checkpoint/source-capture boundaries explicit. Runtime histories, report payloads, credentials, weights and generated bundles stay outside Git. Documentation/diagnostics must not include prompts, responses or private chat text.
