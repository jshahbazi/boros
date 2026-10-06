# Synthetic retrieval scaling diagnostic

The new `scripts/evaluate_scaling.py` measures the current standalone native retrieval harness at declared 1,000, 10,000 and 100,000 text events. It performs no provider calls. It preserves the historical preregistration, amendments and source pins. Current-source compilation has a separate dependency inventory; the registered runner keeps its original inventory and drift refusal. This is an unregistered development diagnostic. Its results do not complete N5 or authorize a summary tree.

Each size contains one generated history, nine fixed probes and five retrieval protocols, with one warm profile followed by one fresh-process restart profile. The existing deterministic development generator supplies complete source text and scorer-only spans. The larger corpora extend the same synthetic event prefix and query set; the three sizes are dependent workload instances. Concurrency is one. There is one attempt per size/profile and no retries.

The first recorded wave captured 40 dependencies: 36 native dependencies and four Python inputs, including the runner. The uncommitted working-tree current-source inventory adds the bounded-neighborhood helper, making 41 inputs; it does not change that retained wave's capture or measurements. Before compilation, the runner writes all source copies, corpus files, hashes, corpus summaries, configuration, compile flags, fixed attempt order and all six declared profile attempts to a fresh private directory. Writes are exclusive and flushed to disk. Caller symlinks, source-tree destinations and reuse of an existing output directory are refused. The standard macOS `/var` and `/tmp` aliases remain usable; the resolved destination must stay under this checkout's `.build` directory. Source copies and corpus files use `0600`; the fresh output root uses `0700`. Intermediate subdirectories inherit the caller's umask and may be `0755`; they remain inside that private output boundary.

Compilation uses `/usr/bin/swiftc`, `-O`, Swift language version 5, `-parse-as-library`, and target `arm64-apple-macos14.0`, matching the native development build's optimization and target. The standalone harness links NaturalLanguage and system SQLite. Apple silicon macOS is required for actual execution. Portable tests stub compilation and native execution. The default timeout is 900 seconds for compilation and for each profile, and profile timeout overrides must stay between 1 and 900 seconds.

Run all declared sizes using a fresh absolute destination:

```sh
python3 scripts/evaluate_scaling.py --execute \
  --output-directory /Users/johnshahbazian/development/boros/.build/evaluation/scaling-v1-20261006
```

For an explicitly smaller diagnostic, select sizes before execution:

```sh
python3 scripts/evaluate_scaling.py --execute \
  --scales 1000 10000 --timeout 900 \
  --output-directory /Users/johnshahbazian/development/boros/.build/evaluation/scaling-small-v1-20261006
```

Warm execution ingests the complete corpus and performs its lexical indexing in the same native process that runs the probes. Restart execution opens that retained store in a new process. It never repeats ingestion. If warm setup fails or times out, its restart attempt stays declared with `prerequisite_failed` status. A later size still executes when implementation identity remains intact. Compiler failure, profile failure, timeout and missing results remain in the full declared denominator. No failed profile is retried. A profile can complete while individual retrieval probes fail; selection failures remain visible separately.

The final metadata-only `report.json` links its durable declaration and binary digest. Each completed profile reports event count, original source UTF-8 bytes, ingestion time, store-open time, store bytes and harness elapsed time. Each protocol reports memory-path and full durable local-read episode p50/p95/maximum, declared probes, selection failures, scope violations, coverage-limit reasons, complete-span outcomes among byte-feasible answerable probes and actual charged episode resources. The raw-source protocol additionally reports literal/lexical endpoint timing, returned source bytes, page/service calls, absence probes with hits and exact-read verification. Context protocols expose their observed serialized context bytes. Missing observations remain unknown and never become zero work.

Current source bytes, copied source bytes, declaration, corpus files and compiled binary are checked before and after every profile and again before publication. Identity drift prevents further native calls and revokes completed measurement credit across the final report. Private native reports and incremental attempt files retain observations; the final report's `implementation_continuity` and attempt statuses determine credit. Those snapshots are not independent approvals. Compiler diagnostics and process output stay in private files. Console output contains only aggregate completion counts and continuity status.

These measurements cover the captured standalone harness. Its fixed protocol order warms later probes; operating-system disk cache is uncontrolled after process restart. Only the first probe starts immediately after reopening. The harness does not execute GUI Send, selected-Qwen token counting/admission, semantic indexing, a memory-service boundary or concurrent callers. Context coverage uses the existing harness's synthetic string-based checks, while the raw-source protocol separately verifies original returned bytes; neither measures answer correctness. Full local-read episode timing covers the durable retrieval episode, not a full model-answering episode.

Semantic chunk counts, semantic indexing backlog, process RSS, model feasibility, answer latency and billed cost remain unknown. Paused workloads, repeated or independent 100,000-event corpora, workload-derived caps, representative question distributions and whole-application interaction remain future work. An observed warm endpoint p95 below one second addresses only that declared diagnostic's endpoint timing; it supplies no broader N5, quality or tree-gate acceptance.

Current measured results and integration checks belong in [STATUS.md](STATUS.md). Runner contracts are checked with:

```sh
python3 scripts/test_scaling_evaluation.py
```

## Attribution of the 100,000-event latency

A separate read-only experiment on the retained 100,000-event store used macOS system SQLite 3.51.0, matching the native SQLite library. The preceding automatic-context lexical query's plan starts with the event project index and repeats the FTS match inside that loop. Both `MemoryStore.lexicalCandidateReferences` and `MemoryStore.search` used this join shape before the repair below. The inspected adjacency lookups use indexed queries.

The original slow query exceeded the declared 50.005-second observation window and was not retried. An FTS-first `CROSS JOIN` variant with the same filters, BM25 ordering and limit completed in 0.172 seconds. A separate completed control changed from 2.282 to 0.0098 seconds and retained the exact ordered-result digest. Forty-eight event, conversation and page lookups took 0.0092 seconds in total. The metadata-only receipt is `.build/evaluation/scaling-attribution-20261006.json`, SHA-256 `8ea5b4f12eff8712a18fe4d7cc6123278f3c49d9408f6c6e592bfc66bb3297cc`.

This isolates a SQL planning defect. The experiment does not measure the complete Swift selection path or its remaining validation and ledger costs. The subsequent native repair and measurement below remain separate from the bounded-neighborhood recall comparison.

## FTS-first native repair

Both lexical queries now use `event_fts CROSS JOIN events`, retaining the existing join equality, project/frontier/exclusion filters, BM25 ordering and limit. This fixes the outer-loop order using [SQLite's documented behavior](https://www.sqlite.org/optoverview.html#manual_control_of_query_plans_using_cross_join). Seven contracts in `scripts/test_lexical_query_plan.py` pass through macOS system SQLite 3.51.0. They exercise the actual native SELECT projections and check complete ordered-result parity with the preceding JOIN shape, scope/frontier/exclusions before limits, ties, quoted/Unicode terms, payload identity and FTS-first query plans.

The fresh optimized standalone Swift run declares only 100,000 events, warm then process restart, with the same fixture bytes and configuration as the preceding 100k diagnostic. It captures 41 dependencies before compilation. Both profiles complete: **2/2 profiles, 90/90 protocol-probe selections**, zero provider work, zero selection failures, scope violations or missing episode receipts. All eighteen raw-source probes verify returned bytes. Across both profiles, raw-source, targeted-lexical and legacy automatic-context protocols still recover all eight required spans over seven byte-feasible answerable probes; recent-only and current-prompt lexical each recover one. The oversized and absence probes remain declared.

| 100k p95 measurement | Earlier warm / restart | Repaired warm / restart |
|---|---:|---:|
| Lexical search endpoint | 3.635 / 4.018 s | **0.0133 / 0.0154 s** |
| Legacy automatic-context memory path | 111.668 / 114.097 s | **0.621 / 0.479 s** |
| Targeted lexical context memory path | 3.708 / 4.052 s | **0.0461 / 0.0454 s** |
| Literal search endpoint | 3.006 / 3.060 s | **3.001 / 3.037 s** |

The automatic-context improvement is approximately 180-fold warm and 238-fold after process restart. The native before/after source closures also differ in experimental neighborhood and default-gating dependencies, so this is not a sole-change causal experiment across the complete path. The preceding isolated SQL attribution and new parity contracts support the join repair; the native run demonstrates the captured repaired path's behavior. One synthetic history and nine fixed observations per protocol/profile provide no production latency distribution or answer-quality evidence.

Warm ingestion takes 25.137 seconds; warm and restart harness totals are 54.186 and 31.855 seconds. Restart store opening takes 2.891 seconds. Literal traversal remains bounded and about three seconds p95. The lexical endpoint passes the stated one-second diagnostic target; the remaining literal endpoint does not, and warm automatic-context preparation still exceeds 500 ms. Full selected-Qwen Send, semantic indexing, paused schedules, concurrency, independent histories, repeated runs and total turn cost remain unmeasured. N5 remains partial.

The fresh source/corpus/declaration/binary checks pass before and after both profiles. Independent metadata review confirms the fixture/configuration, denominators, recovery outcomes and reported metrics. Receipt root: `.build/evaluation/scaling-fts-first-20261006`; report SHA-256 `5f12ee9275660bbd8aa37af3d99b946ce9286cedbc4cf766262179248b438357`; declaration SHA-256 `38fdc3bb525f9befbcb9156351e8af14d2609b01e9ac6dfb3eb628e97a6be204`; binary SHA-256 `5af5b8ed27dfad8251d749ada2fa027741ca2f84c77e6cae8d99bc1514d128e5`. The native application was not rebuilt; its prior 3,887-check receipt remains unchanged.

```sh
python3 scripts/test_lexical_query_plan.py
python3 scripts/evaluate_scaling.py --execute --scales 100000 --timeout 300 \
  --output-directory /absolute/path/to/boros/.build/evaluation/fresh-fts-first-run
```

The [performance examination](reviews/PERFORMANCE-EXAMINATION-20261006.md) separates this latency repair from the proposed exchange-selection, reading and orientation/zoom comparisons.
