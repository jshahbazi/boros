# Synthetic retrieval scaling diagnostic

The new `scripts/evaluate_scaling.py` measures the current standalone native retrieval harness at declared 1,000, 10,000 and 100,000 text events. It performs no provider calls. It preserves the historical preregistration, amendments, source pins and `evaluate_retrieval.py` runner unchanged. This is an unregistered development diagnostic. Its results do not complete N5 or authorize a summary tree.

Each size contains one generated history, nine fixed probes and five retrieval protocols, with one warm profile followed by one fresh-process restart profile. The existing deterministic development generator supplies complete source text and scorer-only spans. The larger corpora extend the same synthetic event prefix and query set; the three sizes are dependent workload instances. Concurrency is one. There is one attempt per size/profile and no retries.

The runner captures 40 dependencies before compilation: 36 native dependencies and four Python inputs, including the new runner. It writes all source copies, all corpus files, hashes, corpus summaries, configuration, compile flags, fixed attempt order and all six declared profile attempts to a fresh private directory before invoking the compiler. Writes are exclusive and flushed to disk. Caller symlinks, source-tree destinations and reuse of an existing output directory are refused. The standard macOS `/var` and `/tmp` aliases remain usable; the resolved destination must stay under this checkout's `.build` directory. Source copies and corpus files use `0600`; the fresh output root uses `0700`. Intermediate subdirectories inherit the caller's umask and may be `0755`; they remain inside that private output boundary.

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
