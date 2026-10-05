# Boros evaluation contracts and development evidence

Updated October 5, 2026. This is executable groundwork for the read-only baseline in [the plan](../tracechat-plan.md#13-evaluation-that-decides-the-design). Full Arm B, provider-answer evaluation, production economics, and held-out confirmation remain incomplete.

The next [production-path answering diagnostic](ANSWER-EVALUATION.md) is under implementation. Retrieval-strategy focused checks pass; shared coordinator review and app integration remain in progress. No answer-quality comparison has run.

## Available evaluation

`scripts/evaluate_retrieval.py` compiles a standalone Swift harness against copied store, context, semantic and episode dependencies. It writes public synthetic histories into isolated temporary stores, executes declared retrieval protocols, verifies original byte pages and gold spans, and removes those stores. Each protocol attempt creates a durable schema 5 `localRead` episode with a `syntheticEvaluation` binding and supplies its lease through context selection, search and paging. Attempts create no chat input or invocations. The JSON report contains source IDs, digests, terminal receipts, coverage and timings. It contains no prompts, answers, source text, credentials or private history. It contacts no model server.

Run from the repository root:

```sh
python3 scripts/test_evaluation.py
python3 scripts/evaluate_retrieval.py --contract-only --history-count 1 --profile warm --output .build/evaluation/new-contract-check.json
```

The registered/default route requires exact v4 source hashes. It currently refuses execution because episode and standalone-read integration changed those sources; historical v4 reports and amendments remain unchanged. A new measurement amendment requires the next configuration freeze. The explicit `--contract-only` route accepts only one or two development histories and no scaling override. It emits a distinct unregistered schema, sets `registeredProtocolApplied:false` and `comparisonUse:prohibited`, omits summary statistics and refuses an existing output path. It verifies current-source contracts without producing registered quality, latency or economic evidence. Final verification and contract-suite totals are recorded in [STATUS.md](STATUS.md).

Generated reports belong under ignored `.build/`; runtime memory and model weights remain outside Git. Compilation uses system Swift and SQLite and requires no Python packages. Source capture copies and hashes every required Swift dependency and the Python implementation files.

`--split held-out` is deliberately blocked. The protocol amendments apply only to development; validation execution needs a separately frozen protocol before its results are consumed. The confirmation route requires a complete baseline, provider admission and gold feasibility, a completed decision sheet, frozen configurations and a credible workload/power pilot. A new independent set is required if later changes are prompted by held-out results.

## Frozen inputs and protocols

The original [preregistration](../Tests/fixtures/evaluation/preregistration-v1.json) is preserved byte-for-byte. It fixes generator hash, dataset hashes, seeds, splits, original protocols, byte bounds, estimands and initial product gates. The [v2 development amendment](../Tests/fixtures/evaluation/development-protocol-amendment-v2.json) adds the actual lexical helper, separates oracle scoring from latency, and corrects future statistical/gate validation. The [v3 development amendment](../Tests/fixtures/evaluation/development-protocol-amendment-v3.json) chains that record, pins the integrated core and semantic compiler dependency, and names the tested branch `gui_lexical_anyterm` with `semanticIndex:nil`. The [v4 development amendment](../Tests/fixtures/evaluation/development-protocol-amendment-v4.json) preserves that snapshot, pins exclusions applied before lexical ranking/LIMIT, and rejects boolean coercion throughout numeric economics and power contracts. The [v4 manifest schema](../Tests/fixtures/evaluation/run-manifest-schema-v4.json) describes registered v4 reports. Original reports remain historical records. New source captures record the exact copied Swift-source hashes and Python implementation hashes; the initial v1 reports recorded Swift hashes only. The Git revision alone does not describe uncommitted source being evaluated.

| Split | Seed | Synthetic histories | Events | Original source bytes | Probes |
|---|---:|---:|---:|---:|---:|
| Development | 104202601 | 32 | 879 | 3,940,179 | 288 |
| Validation | 104202602 | 32 | 889 | 3,941,429 | 288 |
| Held-out, unrun | 104202603 | 200 | 5,510 | 24,628,150 | 1,800 |

History and source IDs are disjoint across splits. Histories are ingested in chronological fixture order without future questions. Gold source IDs, exact UTF-8 spans, byte offsets, lengths and SHA-256 hashes are scoring data. They do not influence query formulation, rank fusion or page selection. All questions inspect the same unchanged history snapshot; question and answer capture is disabled in the probe harness, with zero overlay ingestion. A future answering harness must measure its disposable per-episode capture overlay separately.

Each history has nine probes: rare archived fact, middle of a roughly 100 KiB source, punctuation/Unicode identifier, two-source evidence, dated update, quoted policy evidence, byte-infeasible whole record, absent evidence, and an exact recent follow-up. Same-term conflicting evidence in another project checks scope isolation. Values vary across histories; the template families remain narrow and public. Synthetic history clusters provide uncertainty about this generator distribution, rather than representative production conversations.

| Protocol | Implemented path | Interpretation |
|---|---|---|
| `recent_only` | Actual assembler with no historical query | Historical recent-only behavior; Arm A selection diagnostic |
| `current_prompt_lexical` | Actual assembler with the full natural-language question as its lexical query | All-term API diagnostic; separate from the GUI helper |
| `targeted_lexical` | Actual assembler with a frozen explicit search query | Human-specified query diagnostic; automated reformulation is absent |
| `gui_lexical_anyterm` | Actual ChatContextPreparation helper with no semantic index | Lexical branch of the GUI helper; installed-index hybrid behavior needs its own evaluation |
| `raw_source_probe` | Literal-first union of literal/lexical hits, then exact original pages | Source-discovery/read diagnostic; no final answering context is rendered |

The raw-source probe uses at most 16 hits per search mode, stable source-ID deduplication, at most 19 reads, 4,096-byte pages and 12,000 returned source bytes. Paging begins at each hit's excerpt offset and advances through consecutive pages. Gold spans never select pages. The query/read path uses at most 21 memory service calls. Assembler diagnostics use 65,536 serialized message bytes, 24,000 recent-context bytes and 12,000 historical-evidence bytes. These are prototype byte bounds; they do not substitute for the plan's provider-token caps.

These protocols do not implement the complete Arm B contract. Their current standalone read admission covers retrieval resource limits and deadlines; a complete comparison still needs the integrated semantic/hybrid path, metadata and neighbor retrieval, an answering loop, source-scope disclosure permissions and provider-token feasibility. The initial evaluated GUI snapshot used recent context. Commit `7528e82` introduced bounded any-term lexical retrieval through `ChatContextPreparation`; subsequent integration can pass an installed semantic index. The index-less helper protocol does not establish installed-index hybrid behavior. Current application behavior is recorded in [IMPLEMENTATION.md](IMPLEMENTATION.md).

## Scoring and accounting

A span is covered only when all required bytes occur in the actual assembled messages or are recovered through verified original-source page ranges. Multi-source success requires every sufficient gold span. Context presence uses exact span text; recent-message source IDs were unavailable in the initial snapshot and are now recorded explicitly by the current API. New reports check historical and recent source references for resolvability. No answerer runs, so model citation correctness, temporal-answer correctness, lifecycle behavior and task success are unknown.

Within each eligible category, average probe outcomes within a synthetic history, then histories equally. Macro-average categories with answerable, byte-feasible gold equally. The current eligible categories are exact facts, dated updates, recent follow-ups and quoted-policy evidence. The last measures retrieval of attributed text; it provides no policy-resolution or authority-mutation evidence. Absent sources receive a separate false-hit report. Correct model abstention remains unknown.

Development has 224 answerable byte-feasible probes, 32 byte-infeasible probes, and 32 absence probes. Byte-infeasible gold is reported separately. All provider-token feasibility labels remain unknown; retrieval probes therefore cannot satisfy the plan's within-admitted-token recall gate. A retrieval-selection, budget or deadline error scores zero and retains terminal latency and its failed attempt in every protocol denominator. A zero memory-operation cap fixture exercises this across all five protocols. Fatal harness failure prevents a successful report. Budget-infeasible cases also remain in the future overall task-score denominator; model-answer timeouts still require the future answering harness.

Current contract reports terminalize each read attempt before fixture-byte/hash verification and gold scoring, which remain separate oracle work. The authoritative receipt records charged and held resources, terminal reason, frozen limits and origin. `fullEpisodeMilliseconds` includes durable initiation, retrieval and terminalization under the original continuous clock. Selection/search/page path timings remain separate, and application integrity checks inside MemoryStore APIs stay inside that path. Initial v1 raw-source timing included interleaved oracle verification and scoring; it cannot be directly compared with assembler timings. These paths contain no planning, reranking, model rounds, useful answer or response streaming. Full submission-to-answer timing and the three required provider-cache profiles remain pending. Restart uses a fresh evaluation process with the retained index, while the operating-system disk cache remains uncontrolled. Only the first probe per history starts after store opening; subsequent probes are warm. The fixed protocol order also warms later queries. No provider cache is warmed or shared between arms here.

The report records `coverageLimited` and structured `coverageLimits` for resource, candidate, result, source, metadata and index boundaries. A retrieval notice alone does not imply incomplete coverage: the nil-index helper can disclose semantic unavailability after a complete lexical result. Read-only context/semantic selection stops on resource-limited raw coverage before implicit rereads or query encoding.

Known accounting includes original source bytes/events, ingestion time, store files including active SQLite sidecars, context serialization bytes, returned source bytes/calls and the authoritative receipt's conservative logical raw/vector/metadata work and memory-operation charges. These lexical-only protocols perform zero model calls. Legacy per-protocol accounting fields can remain null; `episodeAccounting.receipt` is the resource authority. Physical disk I/O, provider input tokens, answering latency, billed cost and any hidden computation remain unknown. Model feasibility and billed cost are explicitly null in each read-attempt record. Unknown usage is never written as zero. Warm store size includes active WAL/SHM; restart size can shrink after SQLite checkpointing and is not a storage-growth comparison.

## Historical v1 development result

The initial historical full development run completed on October 4, 2026, using the hashes in `.build/evaluation/development-v1.json`. It ran 32 public synthetic histories at concurrency one on the local Apple silicon Mac. The core continued changing during parallel implementation; the 100k scaling run below records different core hashes. These numbers and the frozen v3/v4 results below describe historical source snapshots, before the current standalone-read accounting contract.

| Historical protocol | Eligible probes with every required span | Macro source coverage | Warm recorded path p95 | Restart recorded path p95 |
|---|---:|---:|---:|---:|
| Recent context only | 32/224 | 25% | 0.18 ms | 0.15 ms |
| Full question as AND-lexical query | 32/224 | 25% | 0.26 ms | 0.23 ms |
| Explicit targeted lexical query | 224/224 | 100% | 3.92 ms | 3.72 ms |
| Literal/lexical original-source probe | 224/224 | 100% | 4.96 ms | 4.89 ms |

The 224 eligible probes require 256 distinct gold spans; targeted lexical and raw-source protocols covered all 256. All returned read bytes matched original source bytes and digests. No scope violation, selection failure or false hit for the absent queries was observed. Warm endpoint p95 was 3.74 ms lexical and 0.97 ms literal. Every history had the same category-level outcome pattern, so the preregistered 10,000-resample clustered percentile intervals degenerate to the corresponding point estimates. They do not imply production reliability.

The one-history scaling diagnostic ingested exactly 100,000 events and 13,197,425 source bytes, including the same source families plus short distractors. It measured nine frozen query probes at concurrency one. Ingestion took 26.17 seconds; historical raw-source path p95 including oracle work was 43.01 ms, lexical endpoint p95 2.13 ms, and literal endpoint p95 41.36 ms. Seven eligible probes recovered all required spans. The small query sample, narrow source distribution, one build and warmed operating-system cache do not establish the production p95 gate.

The historical improvement signal is explicit: feeding a natural-language question into that snapshot's AND-term search missed old evidence that a targeted query found. Bounded query formulation, exact-identifier routing, semantic fallback and integrated lexical/hybrid behavior need development/validation comparison. Recent source IDs now permit explicit provenance checks; answer citation scoring remains pending. No model-quality or tree-benefit conclusion follows from this run.

The prior correction suite passed 41 tests covering frozen fixtures and spans, split separation, history/category weighting, deterministic bootstrap, paired-cluster handling, missing categories/costs, zero-success economics, power floors, conjunctive gates, held-out refusal, actual Swift retrieval/restart, scope, exact pages, byte bounds, absence handling, immutable query history and content-free manifests. Current checks also cover dependency-copy/hash capture, registered source-pin refusal, bounded unregistered execution, authoritative read receipts, failure denominators and structured coverage. Final totals are recorded in [STATUS.md](STATUS.md). These are contract checks, not a new registered development run.

## Historical integrated-source v3 development result

The v3 amendment was frozen before running its full development protocol against unchanged copies of `MemoryStore`, `ContextAssembler`, `ChatContextPreparation` and `SemanticIndex`. The 35 correction tests passed for that historical snapshot. The metadata-only record is `.build/evaluation/development-v3.json`; its amendment SHA-256 is `a6199631eb33619907982c52ddb7499eab6881a2ca81ad412f436dd9aac42e0d`. Core and evaluation implementation hashes match the pinned amendment. The original preregistration, fixture set, v1 reports and v2 amendment remain preserved.

| Protocol | Eligible probes with every required span | Covered required spans | Macro source coverage | Warm memory-path p95 | Restart memory-path p95 |
|---|---:|---:|---:|---:|---:|
| Recent context only | 32/224 | 32/256 | 25% | 0.20 ms | 0.21 ms |
| Full question as AND-lexical query | 32/224 | 32/256 | 25% | 0.28 ms | 0.26 ms |
| Explicit targeted lexical query | 224/224 | 256/256 | 100% | 4.00 ms | 3.93 ms |
| GUI helper, lexical only (`semanticIndex:nil`) | 224/224 | 256/256 | 100% | 60.08 ms | 59.56 ms |
| Literal/lexical original-source probe | 224/224 | 256/256 | 100% | 4.73 ms | 4.72 ms |

Oracle scoring is now outside every memory-path timer. Its raw-source p95 was 0.096 ms in both profiles. The recorded warm endpoint p95 was 3.71 ms lexical and 0.97 ms literal. All original pages verified byte-for-byte; no observed scope violation, selection failure or false hit for the absent raw-source queries occurred. Category/history source-coverage intervals remain degenerate for this narrow generator, as described above.

The bounded any-term helper finds these sources from the natural-language prompts without supplied targeted queries. It spends more local work selecting and validating broad candidate evidence than the explicit targeted-query diagnostic in this corpus. The helper was tested with a nil semantic index and an absent excluded current-event ID, preserving the unchanged historical snapshot; human capture cost remains unmeasured here. An installed-index automatic hybrid path is a separate protocol awaiting a new preregistered development run. These results do not establish answer accuracy, general recall, citation correctness, product p95, or tree benefit.

## Frozen-source v4 development result

V4 is a historical source snapshot retained unchanged after episode integration. It retains the original fixture set and preserves all prior amendments/reports. It pins the application's correction that excludes recent/current sources before ranking and `LIMIT`. The evaluation helpers reject boolean values in numeric weights, costs, success-rate proportions, standard deviations, power inputs, counts, seeds and percentile inputs. Positive integer counts and finite/ranged numeric contracts are checked explicitly, including when pilot evidence is absent. A validated boolean retrieval outcome is deliberately converted to numeric 0/1 before aggregation; malformed numeric or textual coverage flags are rejected.

The full 41-test suite passed, including individual malformed fields, an all-boolean zero-cost fixture, unknown-pilot boolean minima, fractional/invalid counts and non-finite inputs. The separately frozen v4 experiment then ran the unchanged 32-development-history corpus in warm and fresh-process profiles against identical pinned sources. Report: `.build/evaluation/development-v4.json`. Amendment SHA-256: `1ad0b1d25c28055f04237deb217069c425855c7c164da9542f04fbb0118da809`.

| Protocol | Eligible probes with every required span | Covered required spans | Macro source coverage | Warm memory-path p95 | Restart memory-path p95 |
|---|---:|---:|---:|---:|---:|
| Recent context only | 32/224 | 32/256 | 25% | 0.20 ms | 0.18 ms |
| Full question as AND-lexical query | 32/224 | 32/256 | 25% | 0.28 ms | 0.28 ms |
| Explicit targeted lexical query | 224/224 | 256/256 | 100% | 3.88 ms | 3.89 ms |
| GUI helper, lexical only (`semanticIndex:nil`) | 224/224 | 256/256 | 100% | 59.70 ms | 58.46 ms |
| Literal/lexical original-source probe | 224/224 | 256/256 | 100% | 4.72 ms | 4.72 ms |

Original byte pages verified exactly; no observed scope violations, selection failures or absent-query false hits occurred. Raw-source oracle scoring p95 was 0.095 ms warm and 0.093 ms after restart and is excluded from memory-path latency. Warm endpoint p95 was 3.71 ms lexical and 0.95 ms literal. The same narrow generator and nil-index limitations apply. This corpus does not exercise the 120-recent-match crowd-out schedule; the application's separate regression tests cover that correction. Installed-index hybrid quality, model answers and complete episode/economic gates remain pending.

## Product comparison and decision sheet

The [v2 decision-sheet template](../Tests/fixtures/evaluation/decision-sheet-template-v2.json) remains incomplete. Freeze one B/D pair after development/validation, before held-out answers. Match models, prompts, reasoning settings, authority checks, evidence/recent caps and the complete episode budget. Isolate the answerer from direct store/filesystem access so another tool cannot bypass an arm's memory capabilities.

Keep five task categories equally weighted: exact facts, cross-session/temporal updates, immediate exact follow-ups, scoped instruction/lifecycle behavior, and appropriate abstention. Freeze the judge version/rubric and original gold spans before memory construction. Budget feasibility requires the selected provider's exact admitted tokens for mandatory input and sufficient evidence. Wrong refusal, unjustified abstention, timeout, crash or terminal error on an answerable case scores zero; correct abstention scores one. Preserve official public-benchmark scores separately.

Use at least three answering replicates and three independent summary builds for tree arms. Average the paired grid within a history before uncertainty analysis; builds and answering replicates do not add independent histories. Require at least 200 independent histories overall and 50 per critical category. Estimate development-pilot paired per-history variance. `minimum_power_histories` approximates one lower-confidence-bound test, using alternative-minus-null separation and a two-sided 95% bound. For a nondegenerate sampling distribution at a true quality improvement of exactly 0.05, the point-estimate gate of at least 0.05 has roughly 50% pass probability; significance-only sample size does not imply 90% power for the joint primary gate. `quality_joint_power_histories` requires a declared alternative above 0.05 and uses a conservative normal union-bound allocation for the point and significance conditions. Use gap 0.02 for an individual critical-category lower-bound noninferiority test at true difference zero. Retain sample floors and simulate the complete paired cluster decision, including every conjunctive gate, before claiming adequate power. Pilot variance and that simulation remain pending; narrow synthetic templates cannot settle the product power design.

`evaluation_statistics.py` implements 10,000 paired history resamples with fixed seed 104202604, category-level percentile intervals and macro task differences. The future task-score helper requires the fixed five-category set. An entirely absent category leaves the overall point estimate and interval undefined; it never renormalizes the remaining categories. Input category scores are finite proportions and cannot be boolean-like values. Missing categories in a resample remain inconclusive. The future cost-ratio bootstrap reapplies the frozen category mix and one shared production build charge on every resample. It retains infinite cost for zero-success outcomes and undefined ratios as inconclusive; research-replicate spend is separate. The executable `tree_gate_decision` helper checks all gates below, with missing evidence producing an inconclusive result. It rejects boolean-like strings/numbers, malformed proportions, negative latency endpoints/ratios, non-finite score evidence and unknown fields; positive infinite cost bounds are retained as failures. A signed added-memory-path delta may be negative when D is faster.

| Conjunctive gate | Frozen decision contract |
|---|---|
| Invariants | Every applicable durability, scope/disclosure, fence, restart, deletion-serving, token/episode and human lifecycle invariant passes |
| Finite-suite recall | At least 95% retrieving every required span on provider-budget-feasible answerable cases in each replicate/build combination; report clustered uncertainty separately |
| Endpoint | Warm local retrieval p95 below 1 second at 100k declared text events, with corpus bytes/chunks and concurrency |
| Primary mode | Quality-first: D−B point score at least +5 percentage points and lower 95% bound above zero |
| Cost-first alternative | Only if frozen before held-out: task-score lower bound above −2 points and target cost-per-success ratio upper 95% bound at most 0.80 |
| Critical regressions | Lower paired category bound above −2 points for exact follow-ups, scoped lifecycle, and abstention; enough independent histories in each |
| Cost envelope | Target-trajectory D/B cost-per-success upper 95% bound at most 1.25 |
| Interaction envelope | In warm, cold-restart and paused profiles, worst replicate p95 adds at most 500 ms complete memory-path delay and at most 10% full episode delay |

The default primary mode is quality-first. A result must satisfy every gate. Inconclusive evidence keeps the tree experimental.

## Complete episodes and economic trajectory

Freeze the current initial caps before held-out execution: 1,000,000 input tokens across all model calls including repeated/cached prefixes; 16,000 generated tokens including reported billed reasoning; 12 model calls; 24 memory service calls; 256 MiB raw scan work; and a 120-second deadline. B, D and E share 12,000 raw-evidence tokens and a frozen recent-context cap. Per-request admission still applies. Search planning/reformulation, reranking, reads, zoom, checkpoints and answering consume the same episode. An exceeded cap scores failure. Hidden computation that cannot be counted is reported as unknown.

The application's [episode implementation](EPISODE-BUDGET.md) durably enforces its development limits across GUI/CLI answering, standalone browser reads, synthetic protocol attempts and metered core retrieval. Schema-5 background-index budgets and selected-Qwen recent/evidence allocations are integrated at `b006b6a`. A new registered protocol is required before comparison; Apple/native input-token usage remains opaque and must be reported as unknown. Evaluation ledger adoption establishes the current read contracts; it does not establish registered retrieval quality, model-episode feasibility or economics.

Freeze warm, process-restart/cold-cache and paused-beyond-short-TTL schedules for each adapter. Measure complete memory-path latency, first useful answer and full episode completion in addition to search latency. Provider TTL and provider-answer runs remain pending here.

The primary economic workload is a 90-day retained-history trajectory with pilot-derived initial imports, incremental capture rate, queries per 1,000 events, category mix, pauses, control changes, correction/rebuild frequency, concurrency and storage/hosting allocation. No credible target profile has been measured. Compare sensitivities at 1, 10 and 100 answer episodes per 1,000 newly captured events, and report 1-, 30- and 90-day horizons. Statistical replicate counts cannot substitute for user query frequency.

Charge initial ingestion and one production build once, incremental processing, retries/invalidations, measured corrections/rebuilds, query calls and allocated storage/hosting. Record raw normalized usage and dated prices for uncached input, cache reads/writes, output, separately billed reasoning, embeddings, reranking and background summaries. Each arm uses its own cold/warm/paused cache schedule. Report actual experimental spend separately from amortized production cost. Total cost per attempted and successful episode, marginal query cost and break-even sensitivity are all required. Zero successful episodes fails a cost claim; missing usage leaves cost unknown.

Historical synthetic probes provide retrieval measurements for their frozen snapshots. Current unregistered probes establish executable read-accounting contracts. Remaining evidence includes a complete semantic/raw baseline, representative development workload, exact provider feasibility and answering-episode accounting, model answers, scoped lifecycle enforcement, benchmark protocol adapters, power simulation, production costs/cache profiles, and independent held-out confirmation.
