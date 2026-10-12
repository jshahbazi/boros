# P2: persistent exchange index

Recorded October 12, 2026. This is the persistent, incrementally maintained exchange index that the [step 3 record](P2-PACKING.md) proposed after its 100,000-event measurement, part of work package P2 of the [design repair plan](DESIGN-REPAIR-PLAN.md). It measures parity with the per-turn in-memory rebuild, R1 and R2 on the [P1 harness](RETRIEVAL-HARNESS.md), and selection latency at 1,000, 10,000 and 100,000 events. No answers were generated, no judge ran, and no remote or paid request was made. The local model server was not used; the harness uses its own loopback tokenizer stand-in.

Each section states whether it describes implemented behavior, measured results, or proposed design.

## Default switch (implemented October 12, 2026)

By user decision on measured answer quality ([EXCHANGE-PACKED-ANSWERS.md](EXCHANGE-PACKED-ANSWERS.md)), `exchange_packed` is the ordinary Send default: `ContextComponentPolicy.currentSelectedQwen` is `selectedQwenExchangePacked`. Selected-Qwen GUI Send and unpinned `--answer-evaluation` runs freeze it; `selectedQwen` (v1/16) and the other policies stay selectable and valid. The rest of this record was written while the exchange policies were opt-in. Where it says "opt-in", "ordinary Send stays `lexical`" or "fails closed (`snapshotLimit`)", read this section.

What the switch changes for the index, from reading the code and the checks named below:

- **Every store creates the sidecar on its first ordinary Send.** Nothing builds it before a turn needs it, so a store that has never sent a selected-Qwen turn (or only native-profile turns) still has none. The first selected-Qwen turn whose question has at least one content term opens the sidecar with `create: true`, so the file exists from then on, and its catch-up fills it or finds it too far behind.
  - Up to 2,000 committed unindexed events in the store: the turn indexes them itself, charged to the turn as a declared source read, and reads the persistent index (`persistent_sidecar`).
  - More than 2,000: the turn is served by the in-memory rebuild with identical selection (`in_memory_fallback`), which reads and verifies every project source in the turn, and schedules the background build. Turns until the build completes take the same path. This is the first ordinary turn of every store above 2,000 events after the upgrade, and of every restored store.
  - Above the rebuild's limits (20,000 sources or 32 MiB in the project) while the index is not ready: before the switch such a turn failed with `snapshotLimit`, where the v1 default had delivered evidence. The turn now selects with the v1 lexical selection (`v1_lexical_fallback`, below) and still schedules the build.
  - A project above the persistent limit of 200,000 sources: the same fallback on every turn, with its own reason.
- **Maintenance cost moves to every store that has sent a turn.** Once the sidecar exists, every committed append in that store, in any project and from any path, is indexed after its commit: 0.25 ms per event at 1,000 events, 0.28 ms at 10,000 and 0.59 ms at 100,000 on the synthetic profile measured below. Before the switch only stores that opted in paid it. The ingest comparison (118.5 s against 27.5 s for 100,000 synthetic events) now describes any store with a sidecar.
- **Maintenance starts once the index exists**, whether the turn created it in-turn or the background build did (checked: the next append is indexed and the lag is zero).
- **Backup and restore are unchanged.** Archives exclude the sidecar; a restored store has none and takes the path above on its first ordinary turn (checked, including a restore above 2,000 events).
- **Integrity refusals still fail the turn.** A count or newest-event mismatch, or a loaded source whose store metadata differs from its indexed row, fails closed (`indexMismatch`), as before. The fallback covers only the size limits.

### The v1 lexical fallback

`ExchangeBlockQuery.lexicalFallback` (`Sources/Boros/ExchangeBlockQuery.swift`) serves a product turn whose exchange selection throws `snapshotLimit`. It runs `ChatContextPreparation.v1LexicalEvidence`: the v1/16 query (at most eight non-filler terms of the question or its declared range), the scoped any-term lexical search for 16 primaries, short-primary completion and the v1/16 exchange expansion. These are the same functions v1 ordinary Send used. The spans are assembled under the episode's frozen exchange policy, so its caps (48 spans; the v1 expansion yields at most 16), its single-span token reduction, its selection audit version and journal validation are unchanged. The retrieval audit records `"mode": "v1_lexical_fallback"` and `exchange_fallback`, which holds `version` (`exchange-v1-lexical-fallback-v1`), `reason` (`index_not_ready_project_above_rebuild_limit` or `project_above_persistent_index_limit`), `frozen_policy` and `selection_policy` (`selected-model-context-components-v1`). The status line says that archive recall used lexical search because the index is still being built, or because the project is larger than the index supports. The diagnostic in-memory source used by the parity arms still refuses (`snapshotLimit`), so parity measurements are unchanged.

Contracts. `--retrieval-strategy-self-test` adds five checks on a store with 2,061 events, nine 4 MB payloads and no sidecar: the diagnostic rebuild refuses; the default turn delivers exactly the spans and recent sources that v1/16 selects on an identical copy of the store, under the frozen default policy, with the label and no model, encoder or vector work; the background build completes with no lag; the next turn reads the persistent index with no fallback and no status notice; and the next append is maintained. The component journal suite (`--retrieval-strategy-integration-test`) adds a fourth case that freezes the default on the same kind of store, admits the fallback turn through the counted component session, records it as an invocation and passes component journal, episode journal and archive validation. The existing lifecycle checks cover the in-turn build, the rebuild fallback below the limits, restart, restore and post-commit maintenance.

Not checked: the persistent-limit fallback (a project above 200,000 sources) shares the code path and label logic but has no contract, because that limit is not injectable on the product path and a 200,001-source fixture is too large for `check.py`. Not measured: first-turn latency of the rebuild fallback or of the v1 fallback on real large stores, and how long real stores take to finish the background build. The 100,000-event build took 4.28 s on the synthetic profile below.

## Implemented

### What changed for the exchange policies

The three explicit exchange policies (`exchange_lexical`, `exchange_adjacent`, `exchange_packed`) keep their versions, caps, query, ranking formula, packers and audits. They no longer load and verify every project source each turn. They rank from a derived index kept beside the store, and they read sources only when packing touches them. Ordinary Send stays `lexical`, and the exchange policies stay opt-in (they are not selectable in the GUI). (Superseded October 12, 2026: `exchange_packed` is the ordinary Send default; see [Default switch](#default-switch-implemented-october-12-2026).)

The in-memory rebuild remains in the code. It serves a turn when the persistent index is not ready (below), and checks and the harness's two parity arms select it as a diagnostic index source (`ExchangeBlockQuery.IndexSource.inMemoryRebuild`). The audit's `index` field records which index served the turn: `persistent_sidecar`, `in_memory_fallback` (the rebuild, because the index was not built or too far behind), or `in_memory_per_turn` (the diagnostic source). The labels have the same length, so the step 3 audit byte budget, which serializes this audit, is identical whichever index served the turn. A separate fallback-reason key would have changed that size, so the reason is carried by the label; there is only one reason.

### Where the index lives, and why not in the store schema

The index is a separate SQLite file, `<store>/exchange-index/index.sqlite3` (directory 0700, files 0600), with its own `user_version` 1. The authoritative store schema is unchanged at version 10, so there is no store migration, and backup archives, their validation and restore are unchanged. This follows the existing convention for derived retrieval data: the semantic sidecar is also a separate file, is excluded from archives and is rebuilt after restore. The index is a pure function of the store's events. It holds folded terms of private text, as the FTS index does, under the same privacy rules as the store.

A store-schema table would have made maintenance atomic with insertion. It would also have required a schema-11 migration, a frozen schema-10 contract for backup recognition, archive validation of derived rows and changes to every check that asserts schema 10. The watermark design below gives the same read-side guarantee without those changes.

### What is stored

| Table | Contents |
|---|---|
| `sources` | One row per indexed event: sequence, event ID, project, conversation, role, byte count, digest, and the start sequence of its exchange block |
| `conversations` | First sequence, open (last) block, and the term IDs that block already contains |
| `projects` | Block count, source count, highest indexed sequence, block-log chunk count |
| `terms` | Per-project dictionary of NFC-normalized folded terms with block document frequency and chunk count |
| `postings` | Per term, append-only chunks of 128 (block, count) entries, zigzag-delta varints. A reply that extends an existing block appends another entry for that block; readers sum them |
| `block_log` | Per project, append-only chunks of block creation entries (conversation first sequence, bytes) and growth entries (bytes) |
| `meta` | Format, term-function identity, and the watermark: the last indexed global sequence with its event ID and digest |

Blocks are formed exactly as the rebuild forms them: within a conversation, a block starts at the conversation's first source and at every human message. Only a conversation's last block can grow, so the stored open-block term set is enough to count each term once per block. The term-function identity covers the version, a digest of the stopword list, and the operating system version, because case and diacritic folding depend on system tables.

### Maintenance

- **Incremental, after commit.** Every event insertion in the store goes through one function. When the sidecar exists, the store records each inserted event and applies it after the transaction commits, in one sidecar transaction. A rolled-back transaction applies nothing. A failure leaves the watermark behind and does not fail the append.
- **Catch-up within a turn.** Every read first indexes committed events after the watermark. A turn indexes at most 2,000 such events itself, charged to the turn as a declared source read.
- **Not ready: fallback and background build.** If more than 2,000 events are unindexed (no sidecar yet, as after an upgrade or a restore, or a build still running), the turn is served by the in-memory rebuild, which selects identically and still refuses projects above its 20,000-source cap. The same turn schedules `MemoryStore.scheduleExchangeIndexBuild()`: a build on a private utility queue, outside any episode, in owner-locked batches of 2,000 events (about 0.1 s of lock each). Later turns read the persistent index. Builds coalesce, and a failed build is retried by the next fallback turn.
- **Opt-in only (until October 12, 2026).** Nothing builds the sidecar until a turn of an exchange policy needs it, so stores whose projects never use one pay no cost. Since the default switch, that turn is every store's first ordinary selected-Qwen Send. Post-commit maintenance runs only while the index is current; a lagging index is caught up by the build, never inside an append.
- **Ingest cost for opted-in stores (trade-off).** Once the sidecar exists, every event appended to the store, in any project, is indexed after its commit: 0.25 ms per event at 1,000 events, 0.28 ms at 10,000 and 0.59 ms at 100,000 (measured below). Ingesting 100,000 synthetic events took 118.5 s with maintenance against 27.5 s without (separate processes; the directly measured maintenance share was 59 s). That is the price of keeping turns off the full-history read; a project that does not opt in does not pay it, unless another project in the same store has opted in.

### What a turn reads

Under the store owner mutex, with the episode's SQL fence installed on both connections:

1. Catch up, then compare the project's source count and highest sequence in the store with the sidecar. A mismatch fails closed (`indexMismatch`). The frontier is that highest sequence.
2. Read the query terms' rows and every chunk of their postings, and the project's block log.
3. Locate the excluded sources (the accepted request and the recent context) and, for each conversation that has any, read its sources from the block holding the earliest excluded one (from the block before it when that source starts its block) to the frontier.

Outside the mutex, the excluded conversations' trailing blocks are rebuilt in memory from their remaining sources, exactly as the rebuild forms them (their payloads are loaded and verified). Their stored statistics are subtracted from the block count and document frequencies. The matched blocks are ranked with the shared scoring code.

Packing then reads what it touches. Members and neighbors come from indexed rows in rank-ordered windows (32 blocks, doubling to 4,096). Payloads load lazily, in verified batches that start at 32 ranks and double with each miss. Every loaded source's store metadata must equal its indexed row (ID, project, conversation, role, bytes, digest), or the turn fails closed.

Refusals are errors, never partial results: the turn's view throws `ExchangeBlockQuery.Failure` (`indexUnavailable`, which the entry point turns into the rebuild fallback, `indexMismatch`, `snapshotLimit`), and the sidecar's own reads throw `ExchangeIndexError.mismatch` on malformed or inconsistent chunks. The term function and the sidecar code (`ExchangeTerms`, `ExchangeIndexStore`) depend only on store-level types, so the scripts that compile a store-only subset of sources add one file.

### Metering

Each read is declared to the episode before it runs, as the rebuild's reads were: index rows as `metadataRows`, posting and block-log chunks additionally as raw work at a declared 4,096 bytes per chunk, catch-up and the rebuilt conversations as two passes over their bytes (load and term scan), and lazily loaded payloads as one pass. A turn still creates no model, encoder or vector work.

### Fail-closed and correctness under store paths

| Path | Behavior |
|---|---|
| Append, invocation publication, recovery | Indexed after commit when the sidecar exists, else by the next catch-up |
| Restart | The sidecar is reopened; its watermark event (ID and digest) and the event count through it must match the store, else it is reset and rebuilt |
| Backup | Not archived; archive inventory unchanged |
| Restore | The restored store has no sidecar. A turn on up to 2,000 events builds it in-turn; a larger history is served by the rebuild (up to 20,000 sources) while a background build runs, after which turns read the index (both checked, with identical selection) |
| Deletion or suppression | Not implemented in the store. An event removed outside the store's API changes the count through the watermark, so the sidecar is reset at the next open (checked) |
| Source changed outside the store's API | A turn that loads it finds its metadata differs from the indexed row and fails closed (checked). A changed source that the turn does not load is not detected per turn; the rebuild verified every source each turn, which is the cost this index removes |
| Operating-system or stopword change | Term-function identity differs; the sidecar is reset |
| Project above 200,000 sources | Fails closed (`snapshotLimit`); the rebuild's cap stays 20,000. Since October 12, 2026 a product turn falls back to the labelled v1 lexical selection instead ([Default switch](#default-switch-implemented-october-12-2026)) |
| More than 2,000 unindexed events at a turn | Served by the in-memory rebuild with the `in_memory_fallback` label, and a background build is scheduled; above the rebuild's 20,000-source cap the turn failed closed (`snapshotLimit`) until October 12, 2026, and now falls back to the labelled v1 lexical selection |

### Two changes shared with the rebuild

1. **Summation order.** The step 1 to 3 score summed matched terms in the iteration order of a filtered Swift `Set`. That order is not fixed for equal contents (the likely cause is Swift's per-instance hash seeding; this is an inference), so the last bits of a score could differ between two rankings of the same contents in one process, and blocks whose scores differed only in those bits could swap. The first parity run of this work failed on exactly such last-bit differences in many query and exclusion pairs; the rebuild was affected as much as the index. Terms are now summed in sorted order. The scoring version is `idf-term-coverage-sqrt-byte-cost-v2` (same length as v1, so audit sizes are unchanged). Its effect on recall is in the measurements below.
2. **Exact cost lower bounds in the step 1 and 2 packer.** Before computing a block's exact estimated cost, the packer compares a lower bound computed from indexed metadata (page count, identifier lengths, the shortest status and capture time, no source time) with the remaining budget, and skips a block that cannot fit. The bound never exceeds the exact estimate (checked on every synthetic source, four selection versions, with and without source times), so every decision and audit count is unchanged (checked against packing without bounds). It only avoids reading sources the step 1 and 2 packer would have rejected.

### Contracts

`Sources/Boros/ExchangeIndexChecks.swift` adds 27 checks to `--retrieval-strategy-self-test` (306 in that suite):

- **Parity.** Two random synthetic corpora (220 events, interleaved conversations, leading assistant messages, same-role runs, empty and multi-page sources, canonically equivalent Unicode spellings, a second project), 10 queries with quoted anchors and 13 exclusion shapes each (suffixes, block-starting sources, middles, first sources, whole conversations, two conversations, IDs outside the project). For every pair, the two index sources must agree on frontier, source and block counts, every ranked block's members, anchor count and score bits, its neighbors, members' metadata and text, and the step 1, step 2 and step 3 packers' spans, audits and receipts at several budgets. 260 pairs.
- **Storage.** Eager maintenance and a bulk build store identical statistics; stored statistics equal a rebuild over every source across chunk boundaries (more than three chunks per term and per block log), with growing blocks.
- **Lifecycle.** Restart and later appends; bounded catch-up and its fail-closed limit; the project size limit; a view's frozen frontier; a foreign sidecar reset; an out-of-band change failing closed; an out-of-band removal resetting the sidecar; backup exclusion and restore rebuild; owner-only permissions.
- **Determinism and bounds.** Repeated rankings are bit-identical; lower bounds are valid, tight within 12 tokens a page without a source time, and change no packing decision.
- **Fallback.** A store with 2,102 events and no sidecar, and the same store restored from a backup: the first packed turn is labelled `in_memory_fallback` and selects exactly what the rebuild selects on the same recent snapshot; the background build completes with no lag; the next turn is labelled `persistent_sidecar`, selects identically, and post-commit maintenance resumes. The fallback label has the shared length. The parity checks also assert that the persistent arm was not served by a fallback.
- **Episodes.** For each exchange policy, the ordinary entry point under a lease, both index sources on the same recent snapshot: identical evidence and conversation IDs, audits identical except the label, equal delivery-audit size, metered with no model, encoder or vector work.

The existing exchange checks now expect the `persistent_sidecar` label. `scripts/test_retrieval_harness.py` and `scripts/test_retrieval_floor.py` add one contract each for the parity scorer and the floor's parity checks.

### Harness additions

- **Parity arms.** `DeliveryHarness.swift` adds `exchange_adjacent_rebuild` and `exchange_packed_rebuild`: the same policies over the in-memory rebuild. Its cached baseline store now includes the built index, so every attempt copies a maintained index, and the accepted request is indexed incrementally. `scripts/retrieval_harness.py` compares each pair per history (recent context, delivered byte ranges in order, exchange audit apart from the label, component token counts, labels) and names any differing audit keys. The store cache key now includes `ExchangeIndex.swift`.
- **Floor.** `scripts/retrieval_floor.py` (run by `check.py`) fails unless every compared regression history matches on all four measures.
- **Latency.** `scripts/exchange_latency.py` and `ExchangeLatencyHarness.swift` (version 2) add the index build for an existing store, a maintained-ingestion profile, per-stage timings of the persistent path, and the resources charged to the episode.

## Measured

### Conditions

- **Implementation.** Code at `35189a3`; the development run and the latency diagnostic ran on `4666913` (the same sources, plus the harness cache key and the backup record), clean tree. The final commit `cbb329a` only moves the term function and the sidecar's error type to store-level files (the term-function identity string is unchanged); its regression selection was re-verified by the recall floor below, and the development cohort and the latency diagnostic were not rerun on it. Development harness binary SHA-256 `84d36bba...c468`; latency binary `af9080b8...9d02`.
- **Harness.** Pinned offline tokenizer, no live parity check, four workers, one replicate, stores built cold. The `tokenizers` package came from an existing local virtual environment, because the default `python3` no longer has it; without it the recall floor in `check.py` skips.
- **Machine.** Apple M5 Max, shared with other agents' work during the runs.
- **Private reports.** `.build/evaluation/p2-index-development.json`, `.build/evaluation/p2-index-regression-35189a3.json`, `.build/evaluation/p2-index-latency-46669136/report.json`.

The regression run started on `35189a3` with a clean tree, but its report records `working_tree_modified: true`: the cache-key edit to `scripts/retrieval_harness.py` landed while it compiled. That edit changes which stores are reused, not selection. The recall floor in `check.py` reran the regression cohort on the committed tree (below).

### Parity

| Evidence | Compared | Identical |
|---|---:|---:|
| Synthetic contracts: random corpora, query and exclusion pairs, all three packers | 260 pairs | 260 |
| Synthetic contracts: ordinary entry point under a lease, per policy | 3 | 3 |
| Development cohort, `exchange_adjacent` against its rebuild arm (recent context, delivered byte ranges in order, exchange audit apart from the label, component tokens) | 100 histories | 100 on every measure |
| Development cohort, `exchange_packed` against its rebuild arm | 100 | 100 |
| Regression cohort, both pairs | 14 each | 14 on every measure |

No audit key differed in any history. Parity is now enforced: the recall floor fails if any compared regression history differs.

### Recall

| Cohort | Arm | R1 | R2 | Positive turns whole |
|---|---|---:|---:|---:|
| Development (90) | lexical | 60 | 60 | 119 |
| | hybrid | 50 | 50 | 114 |
| | exchange_lexical | 61 | 61 | 125 |
| | exchange_adjacent | 62 | 62 | 127 |
| | **exchange_packed** | **78** | **69 (76.7%)** | **137** |
| | exchange_adjacent_rebuild | 62 | 62 | 127 |
| | exchange_packed_rebuild | 78 | 69 | 137 |
| Regression (12) | lexical | 9 | 9 | 15 |
| | hybrid | 8 | 8 | 14 |
| | exchange_lexical | 10 | 10 | 16 |
| | exchange_adjacent | 10 | 10 | 16 |
| | **exchange_packed** | **12** | **11** | **17** |
| | rebuild arms | 10 and 12 | 10 and 11 | 16 and 17 |

Every exchange arm reproduces the step 3 record exactly, case by case: no development or regression case changed its candidate or delivered turn count for `exchange_lexical`, `exchange_adjacent` or `exchange_packed`. The sorted summation order therefore changed no measured case on these cohorts. The development interim target, R2 at 90 percent, is still not met.

Preparation time on development, p50 / p95 in milliseconds (loopback tokenizer, shared machine, harness histories of about 500 events, so not an L1 measurement): `exchange_packed` 679 / 1,608 against its rebuild arm's 776 / 1,763; `exchange_adjacent` 665 / 1,492 against 670 / 1,763. Prompt tokens are identical between each pair. Building the index for a cached history took 439 ms at the median (development) and 101 ms (regression).

### Latency at 1,000, 10,000 and 100,000 events

Same synthetic profile and probes as the step 3 record: `evaluation_fixtures.generate("development", scale_events=N)`, one history per size, nine probes per profile, each probe a real accepted request in an episode with the policy frozen. The added memory path over recent-only is `prepareEvidence`, timed with its lease charges, sidecar reads, payload loads and the assembler's re-read of delivered spans; token counting and admission are excluded, as before. Warm: the probes run in the process that ingested the history and built the index. Restart: a new process reopens the store and its index.

| Events | Profile | Policy | Status | Added p50 / p95 (ms) | Memory path p95 (ms) |
|---:|---|---|---|---:|---:|
| 1,000 | warm | exchange_adjacent | 9/9 selected | 54 / 418 | 506 |
| | | exchange_packed | 9/9 selected | 67 / 459 | 567 |
| | restart | exchange_adjacent | 9/9 selected | 46 / 304 | 465 |
| | | exchange_packed | 9/9 selected | 53 / 323 | 481 |
| 10,000 | warm | exchange_adjacent | 9/9 selected | 40 / 333 | 415 |
| | | exchange_packed | 9/9 selected | 40 / 310 | 390 |
| | restart | exchange_adjacent | 9/9 selected | 45 / 341 | 519 |
| | | exchange_packed | 9/9 selected | 52 / 333 | 503 |
| 100,000 | warm | exchange_adjacent | **6/9 selected, 3/9 budget exhausted** | 46 / 207 | 302 |
| | | **exchange_packed** | **9/9 selected** | **47 / 405** | **502** |
| | restart | exchange_adjacent | **6/9 selected, 3/9 budget exhausted** | 67 / 258 | 420 |
| | | **exchange_packed** | **9/9 selected** | **69 / 684** | **859** |

Against the gates (L1: added memory-path p95 at 100,000 events at most 2 s; Gate 3: 1 s):

- **`exchange_packed` passes both** at 100,000 events: added p95 0.41 s warm and 0.68 s after restart, with every probe selecting evidence. The step 3 record measured this policy refusing every 100,000-event probe (the 20,000-source cap), and 3.7 to 4.2 s with the cap lifted. In this run the replaced rebuild's uncapped stages took 4.0 / 5.1 s warm and 4.4 / 6.1 s after restart (p50 / p95).
- **`exchange_adjacent` fails closed on three probes at 100,000 events.** On the three questions whose terms match nearly every block (about 99,990 of 99,995), the step 2 packer keeps visiting ranked blocks while any budget remains, and reading the indexed rows of tens of thousands of blocks exceeds the episode's 100,000 metadata-row cap. The turn fails with the episode budget error `exhausted` and delivers no evidence, after 0.17 to 0.26 s; the timings above mix those three refusals with six selections, which took at most 0.12 s. The rebuild had the same visit pattern and could not run at this size either (20,000-source cap, and its own reads would exceed the same row cap). At 10,000 events the policy selects on every probe, at 0.33 s p95 against 1.0 s for the rebuild in the step 3 record.
- **Recent selection** took 66 / 128 ms warm and 180 / 277 ms after restart at 100,000 events (p50 / p95), common to every policy.

Where the persistent path's time goes at 100,000 events, p95 per probe for `exchange_packed`: snapshot (catch-up check, inventory, query-term postings, block log) 31 ms warm and 43 ms after restart; ranking 64 to 80 ms (about 100,000 matched blocks for the three common-term questions); member windows 7 to 8 ms; 39 sources loaded. The rest of the added time is the existing metered assembly (size probe, verified re-read of delivered spans, audit). The episode was charged at most 1,989 metadata rows for this policy.

These numbers come from one synthetic history per size whose distractors are uniform single-message blocks. They are not a production latency distribution.

### Build, maintenance and size

| Events | Index build for an existing store | Ingestion without index | Ingestion with incremental maintenance | Maintenance per event (measured directly) | Store bytes | Index bytes |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 64 ms | 0.45 s | 0.55 s | 254 µs | 6.6 MB | 2.2 MB |
| 10,000 | 422 ms | 2.8 s | 5.4 s | 277 µs | 14.9 MB | 8.4 MB |
| 100,000 | 4.28 s | 27.5 s | 118.5 s | 593 µs | 78.3 MB | 68.2 MB |

Sizes include write-ahead logs. Ingestion with and without the index ran in different processes, and at 100,000 events the gap (91 s) is larger than the measured maintenance time (59 s), so part of it is not attributable to the index alone; the per-event maintenance cost is the direct measurement. It grows with size: the term dictionary in this profile gains one unique term per distractor, about 100,000 terms. A turn's own catch-up was zero events in every probe, because each accepted request was indexed after its commit.

### check.py

`python3 scripts/check.py` passed on `a32cb4b` (the rebuild fallback and background build): **5,030 checks**, recall floor ran (63 floor checks, including the 8 parity checks). It had passed on `cbb329a` with 5,027 checks; the three added checks are the two fallback lifecycles and the fallback label length. The fallback does not change any measured selection: the harness and the latency diagnostic build the index before their turns, so every measured turn was served by the persistent index (the parity scorer checks the `persistent_sidecar` label on all 114 histories), and the persistent path's selection code is unchanged. The development cohort and the latency diagnostic were not rerun on `a32cb4b`. It was run with the virtual environment's Python so the floor had `tokenizers`; with the default `python3` the floor skips (zero checks, reported as a skip). The floor reran the regression cohort on the final sources: every arm at or above its floor (`exchange_packed` R1 12, R2 11) and 8 new parity checks (both pairs, 14 of 14 histories on evidence, audit, tokens and labels). A first run on `4666913` failed one suite, `imported-chat-evaluation`: its harness compiles a store-only subset of sources that `MemoryStore.swift` now extends. `cbb329a` moved the term function and sidecar errors to store-level types and added the sidecar file to every subset build. Nine standalone store scripts outside `check.py` (`test_memory.py`, `test_episode.py`, `test_backup.py` and others) fail identically on the base commit `b6e47c0`; `test_background_index.py` and `test_semantic_recovery.py` pass with this change.

## What did not work, and iteration disclosure

- **Summation order.** The first randomized parity run failed on last-bit score differences. The cause was in the existing ranking, not the index (see Implemented). Fixing it before any cohort measurement changed no development or regression case.
- **First latency smoke run.** With windows that loaded every member's payload and both neighbors, and without cost lower bounds, `exchange_adjacent` took 1.0 s p95 at 10,000 events on the three common-term probes and loaded about 10,000 sources each. A second iteration added the lower bounds but loaded payloads in 32-block batches; one probe then took 2.3 s, because remaining budget sat just above many blocks' bounds. The shipped version loads metadata-only windows and doubles payload batches on each miss (0.33 s p95). These runs are smoke diagnostics (`.build/evaluation/p2-index-latency-smoke*`), not records.
- **Two runs during edits.** One 100,000-event diagnostic failed to compile because sources changed under it; it produced no data.
- **Nothing was tuned on recall.** No parameter of the policies changed, and both cohorts were measured once.

## Proposed (not implemented, not measured)

- **Bounded step 2 visits.** `exchange_adjacent` still visits ranked blocks until its budget is provably full. Block-level cost bounds kept in the block log (identifier lengths, source counts) would let it skip blocks without reading their rows, which would remove the three 100,000-event budget refusals. `exchange_packed` does not need it, and it dominates `exchange_adjacent` on recall.
- **A shared ranking budget.** Ranking reads every posting of the query terms. With about 100,000 matched blocks it took 64 to 80 ms here; a question whose terms match most of a million-event project would scale linearly. The 200,000-source limit keeps the measured regime; beyond it, impact-ordered postings with a threshold algorithm would bound reads, at the cost of exact tie handling.
- **Ingest cost.** Maintenance costs 0.25 to 0.6 ms per event (one sidecar transaction per committed insertion) for every store that has opted in, which since the default switch is every store that has sent an ordinary selected-Qwen turn. Batching it off the commit path, or a cheaper term dictionary, would reduce it.
- **Deletion.** When a deletion or suppression contract exists, the sidecar is a derived copy that it must purge; today it is reset only when the store no longer matches its watermark.
- **Answer-quality checks** for `exchange_packed` remain the gate for any default change, as before. (Done: [EXCHANGE-PACKED-ANSWERS.md](EXCHANGE-PACKED-ANSWERS.md); the default changed October 12, 2026.)

## Recommendation

The persistent index removes the size refusal for the exchange policies without changing what they select. Stores whose history is too long to index in a turn, including restored ones, are served by the rebuild until a background build completes, so no history that the rebuild served before loses evidence. `exchange_packed` now delivers evidence at 100,000 events within both latency gates (0.41 s warm and 0.68 s after restart, p95), at the recall it had: development R2 69 of 90, regression 11 of 12. R2 is still below the 90 percent interim target, and there is no answer-quality evidence, so the policy stays opt-in. (Answer-quality evidence followed; the user made `exchange_packed` the ordinary Send default on October 12, 2026. See [Default switch](#default-switch-implemented-october-12-2026).) `exchange_adjacent` should not be preferred: it is lower on recall, and on common-term questions in very large projects it exhausts the episode budget.

## Running it

```bash
python3 scripts/retrieval_harness.py --cohort development --workers 4 --output .build/evaluation/p2-index-development.json
python3 scripts/exchange_latency.py --output-directory "$PWD/.build/evaluation/p2-index-latency"
```

Run the harness with a Python that has the `tokenizers` package. The development run took 2,117 s cold with four workers and eleven arms; the latency diagnostic about 15 minutes for all three sizes, most of it ingesting 100,000 events twice.
